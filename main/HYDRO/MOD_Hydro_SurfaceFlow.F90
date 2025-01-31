#include <define.h>

#ifdef LATERAL_FLOW
MODULE MOD_Hydro_SurfaceFlow
   !-------------------------------------------------------------------------------------
   ! DESCRIPTION:
   !   
   !   Shallow water equation solver over hillslopes.
   !
   !   References
   !   [1] Toro EF. Shock-capturing methods for free-surface shallow flows. 
   !      Chichester: John Wiley & Sons; 2001.
   !   [2] Liang, Q., Borthwick, A. G. L. (2009). Adaptive quadtree simulation of shallow 
   !      flows with wet-dry fronts over complex topography. 
   !      Computers and Fluids, 38(2), 221–234.
   !   [3] Audusse, E., Bouchut, F., Bristeau, M.-O., Klein, R., Perthame, B. (2004). 
   !      A Fast and Stable Well-Balanced Scheme with Hydrostatic Reconstruction for 
   !      Shallow Water Flows. SIAM Journal on Scientific Computing, 25(6), 2050–2065.
   !
   ! Created by Shupeng Zhang, May 2023
   !-------------------------------------------------------------------------------------

   USE MOD_Precision
   IMPLICIT NONE

   ! -- Parameters --
   REAL(r8), parameter :: PONDMIN  = 1.e-4 
   REAL(r8), parameter :: nmanning_hslp = 0.3
   
CONTAINS
   
   ! ----------
   SUBROUTINE surface_flow (dt)

      USE MOD_SPMD_Task
      USE MOD_Mesh
      USE MOD_LandElm
      USE MOD_LandPatch
      USE MOD_Vars_TimeVariables
      USE MOD_Vars_1DFluxes
      USE MOD_Hydro_Vars_1DFluxes
      USE MOD_Hydro_SurfaceNetwork
      USE MOD_Hydro_RiverNetwork
      USE MOD_Const_Physical, only : grav

      IMPLICIT NONE
      
      REAL(r8), intent(in) :: dt

      ! Local Variables
      INTEGER :: numbasin, nhru, istt, iend, ibasin, i, j

      TYPE(surface_network_info_type), pointer :: hrus

      REAL(r8), allocatable :: wdsrf_h (:) ! [m]
      REAL(r8), allocatable :: momtm_h (:) ! [m^2/s]
      REAL(r8), allocatable :: veloc_h (:) ! [m/s]

      REAL(r8), allocatable :: sum_hflux_h (:) 
      REAL(r8), allocatable :: sum_mflux_h (:) 
      REAL(r8), allocatable :: sum_zgrad_h (:) 
      
      REAL(r8) :: wdsrf_fc, veloc_fc, hflux_fc, mflux_fc
      REAL(r8) :: wdsrf_up, wdsrf_dn, vwave_up, vwave_dn
      REAL(r8) :: hflux_up, hflux_dn, mflux_up, mflux_dn
      
      REAL(r8), allocatable :: rsurf_h (:) ! [m/s]

      REAL(r8) :: friction, ac
      REAL(r8) :: dt_res, dt_this

      IF (p_is_worker) THEN

         numbasin = numelm

         DO ibasin = 1, numbasin

            hrus => surface_network(ibasin)

            nhru = hrus%nhru
            IF (nhru <= 1) THEN
               istt = hru_patch%substt(hrus%ihru(1))
               iend = hru_patch%subend(hrus%ihru(1))

               wdsrf_hru(hrus%ihru(1)) = sum(wdsrf(istt:iend) * hru_patch%subfrc(istt:iend)) / 1.0e3
               veloc_hru(hrus%ihru(1)) = 0. 

               wdsrf_hru_ta(hrus%ihru(1)) = wdsrf_hru_ta(hrus%ihru(1)) + wdsrf_hru(hrus%ihru(1)) * dt
               momtm_hru_ta(hrus%ihru(1)) = 0.
               
               cycle
            ENDIF

            allocate (wdsrf_h (nhru))
            allocate (veloc_h (nhru))
            allocate (momtm_h (nhru))

            allocate (sum_hflux_h (nhru))
            allocate (sum_mflux_h (nhru))
            allocate (sum_zgrad_h (nhru))
               
            allocate (rsurf_h (nhru))

            ! patch to hydrounit 
            DO i = 1, nhru
               istt = hru_patch%substt(hrus%ihru(i))
               iend = hru_patch%subend(hrus%ihru(i))
              
               wdsrf_h(i) = sum(wdsrf(istt:iend) * hru_patch%subfrc(istt:iend))
               wdsrf_h(i) = wdsrf_h(i) / 1.0e3 ! mm to m
            ENDDO

            DO i = 1, nhru

               veloc_h(i) = veloc_hru (hrus%ihru(i))

               IF (wdsrf_hru(hrus%ihru(i)) > wdsrf_h(i)) THEN
                  ! IF surface water is decreased, momentum is also decreased.
                  momtm_h(i) = wdsrf_h(i) * veloc_h(i)
               ELSE
                  ! IF surface water is increased, momentum is not increased.
                  momtm_h(i) = wdsrf_hru(hrus%ihru(i)) * veloc_h(i)
               ENDIF
            ENDDO
               
            dt_res = dt 
            DO WHILE (dt_res > 0)

               DO i = 1, nhru
                  sum_hflux_h(i) = 0.
                  sum_mflux_h(i) = 0.
                  sum_zgrad_h(i) = 0.
               ENDDO 

               dt_this = dt_res

               DO i = 2, nhru

                  j = hrus%inext(i)

                  IF ((wdsrf_h(i) < PONDMIN) .and. (wdsrf_h(j) < PONDMIN)) THEN
                     cycle
                  ENDIF

                  ! reconstruction of height of water near interface
                  wdsrf_up = wdsrf_h(i)
                  wdsrf_dn = wdsrf_h(j) - hrus%hand(j) - hrus%hand(i)
                  wdsrf_dn = max(0., wdsrf_dn)

                  ! velocity at hydrounit downstream face
                  veloc_fc = 0.5 * (veloc_h(i) + veloc_h(j)) &
                     + sqrt(grav * wdsrf_up) - sqrt(grav * wdsrf_dn)

                  ! depth of water at downstream face
                  wdsrf_fc = 1/grav * (0.5*(sqrt(grav*wdsrf_up) + sqrt(grav*wdsrf_dn)) &
                     + 0.25 * (veloc_h(i) - veloc_h(j)))**2.0

                  IF (wdsrf_up > 0) THEN
                     vwave_up = min(veloc_h(i)-sqrt(grav*wdsrf_up), veloc_fc-sqrt(grav*wdsrf_fc))
                  ELSE
                     vwave_up = veloc_h(j) - 2.0 * sqrt(grav*wdsrf_dn)
                  ENDIF

                  IF (wdsrf_dn > 0) THEN
                     vwave_dn = max(veloc_h(j)+sqrt(grav*wdsrf_dn), veloc_fc+sqrt(grav*wdsrf_fc))
                  ELSE
                     vwave_dn = veloc_h(i) + 2.0 * sqrt(grav*wdsrf_up)
                  ENDIF

                  hflux_up = veloc_h(i) * wdsrf_up
                  hflux_dn = veloc_h(j) * wdsrf_dn
                  mflux_up = veloc_h(i)**2 * wdsrf_up + 0.5*grav * wdsrf_up**2
                  mflux_dn = veloc_h(j)**2 * wdsrf_dn + 0.5*grav * wdsrf_dn**2

                  IF (vwave_up >= 0.) THEN
                     hflux_fc = hrus%flen(i) * hflux_up
                     mflux_fc = hrus%flen(i) * mflux_up
                  ELSEIF (vwave_dn <= 0.) THEN
                     hflux_fc = hrus%flen(i) * hflux_dn
                     mflux_fc = hrus%flen(i) * mflux_dn
                  ELSE
                     hflux_fc = hrus%flen(i) * (vwave_dn*hflux_up - vwave_up*hflux_dn &
                        + vwave_up*vwave_dn*(wdsrf_dn-wdsrf_up)) / (vwave_dn-vwave_up)
                     mflux_fc = hrus%flen(i) * (vwave_dn*mflux_up - vwave_up*mflux_dn &
                        + vwave_up*vwave_dn*(hflux_dn-hflux_up)) / (vwave_dn-vwave_up)
                  ENDIF
                  
                  sum_hflux_h(i) = sum_hflux_h(i) + hflux_fc
                  sum_hflux_h(j) = sum_hflux_h(j) - hflux_fc

                  sum_mflux_h(i) = sum_mflux_h(i) + mflux_fc
                  sum_mflux_h(j) = sum_mflux_h(j) - mflux_fc
                  
                  sum_zgrad_h(i) = sum_zgrad_h(i) + hrus%flen(i) * 0.5*grav * wdsrf_up**2
                  sum_zgrad_h(j) = sum_zgrad_h(j) - hrus%flen(i) * 0.5*grav * wdsrf_dn**2 

               ENDDO

               DO i = 1, nhru
                  ! constraint 1: CFL condition
                  IF (i > 1) then
                     IF ((veloc_h(i) /= 0.) .or. (wdsrf_h(i) > 0.)) THEN
                        dt_this = min(dt_this, hrus%plen(i)/(abs(veloc_h(i)) + sqrt(grav*wdsrf_h(i)))*0.8)
                     ENDIF
                  ENDIF

                  ! IF (i > 1) THEN
                  !    j = hrus%inext(i)
                  !    ac = hrus%area(j) / (hrus%area(i)+hrus%area(j))
                  ! ELSE
                  !    ac = 1.
                  ! ENDIF 
                  ac = 1. 

                  ! constraint 2: Avoid negative values of water
                  rsurf_h(i) = sum_hflux_h(i) / hrus%area(i)
                  IF (rsurf_h(i) > 0) THEN
                     dt_this = min(dt_this, ac * wdsrf_h(i) / rsurf_h(i))
                  ENDIF
                     
                  ! constraint 3: Avoid change of flow direction
                  IF ((abs(veloc_h(i)) > 0.1) &
                     .and. (veloc_h(i) * (sum_mflux_h(i) - sum_zgrad_h(i)) > 0)) THEN
                     dt_this = min(dt_this, ac * &
                        abs(momtm_h(i) * hrus%area(i) / (sum_mflux_h(i) - sum_zgrad_h(i))))
                  ENDIF
               ENDDO 

               DO i = 1, nhru

                  wdsrf_h(i) = max(0., wdsrf_h(i) - rsurf_h(i) * dt_this)

                  IF (wdsrf_h(i) < PONDMIN) THEN
                     momtm_h(i) = 0
                     veloc_h(i) = 0
                  ELSE
                     friction = grav * nmanning_hslp**2 * abs(momtm_h(i)) / wdsrf_h(i)**(7.0/3.0) 
                     momtm_h(i) = (momtm_h(i) - (sum_mflux_h(i) - sum_zgrad_h(i)) / hrus%area(i) * dt_this) &
                        / (1 + friction * dt_this) 
                     veloc_h(i) = momtm_h(i) / wdsrf_h(i)

                     IF (i == 1) THEN
                        veloc_h(i) = min(veloc_h(i), 0.)
                        momtm_h(i) = min(momtm_h(i), 0.)
                     ENDIF

                     IF (all(hrus%inext /= i)) THEN
                        veloc_h(i) = max(veloc_h(i), 0.)
                        momtm_h(i) = max(momtm_h(i), 0.)
                     ENDIF
                  ENDIF

                  wdsrf_hru_ta(hrus%ihru(i)) = wdsrf_hru_ta(hrus%ihru(i)) + wdsrf_h(i) * dt_this
                  momtm_hru_ta(hrus%ihru(i)) = momtm_hru_ta(hrus%ihru(i)) + momtm_h(i) * dt_this
               ENDDO

               dt_res = dt_res - dt_this
               
            ENDDO

            ! SAVE depth of surface water
            DO i = 1, nhru
               wdsrf_hru(hrus%ihru(i)) = wdsrf_h(i)
               veloc_hru(hrus%ihru(i)) = veloc_h(i)
            ENDDO

            ! hydrounit to patch
            DO i = 1, nhru
               istt = hru_patch%substt(hrus%ihru(i))
               iend = hru_patch%subend(hrus%ihru(i))
               wdsrf(istt:iend) = wdsrf_h(i) * 1.0e3 ! m to mm
            ENDDO

            deallocate (wdsrf_h)
            deallocate (veloc_h)
            deallocate (momtm_h)

            deallocate (sum_hflux_h)
            deallocate (sum_mflux_h)
            deallocate (sum_zgrad_h)

            deallocate (rsurf_h)

         ENDDO

      ENDIF

   END SUBROUTINE surface_flow

END MODULE MOD_Hydro_SurfaceFlow
#endif
