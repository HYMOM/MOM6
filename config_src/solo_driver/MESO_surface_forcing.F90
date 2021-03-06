module MESO_surface_forcing

! This file is part of MOM6. See LICENSE.md for the license.

!********+*********+*********+*********+*********+*********+*********+**
!*                                                                     *
!*  Rewritten by Robert Hallberg, June 2009                            *
!*                                                                     *
!*    This file contains the subroutines that a user should modify to  *
!*  to set the surface wind stresses and fluxes of buoyancy or         *
!*  temperature and fresh water.  They are called when the run-time    *
!*  parameters WIND_CONFIG or BUOY_CONFIG are set to "USER".  The      *
!*  standard version has simple examples, along with run-time error    *
!*  messages that will cause the model to abort if this code has not   *
!*  been modified.  This code is intended for use with relatively      *
!*  simple specifications of the forcing.  For more complicated forms, *
!*  it is probably a good idea to read the forcing from input files    *
!*  using "file" for WIND_CONFIG and BUOY_CONFIG.                      *
!*                                                                     *
!*    MESO_wind_forcing should set the surface wind stresses (taux and *
!*  tauy) perhaps along with the surface friction velocity (ustar).    *
!*                                                                     *
!*    MESO_buoyancy forcing is used to set the surface buoyancy        *
!*  forcing, which may include a number of fresh water flux fields     *
!*  (evap, liq_precip, froz_precip, liq_runoff, froz_runoff, and       *
!*  vprec) and the surface heat fluxes (sw, lw, latent and sens)       *
!*  if temperature and salinity are state variables, or it may simply  *
!*  be the buoyancy flux if it is not.  This routine also has coded a  *
!*  restoring to surface values of temperature and salinity.           *
!*                                                                     *
!*  Macros written all in capital letters are defined in MOM_memory.h. *
!*                                                                     *
!*     A small fragment of the grid is shown below:                    *
!*                                                                     *
!*    j+1  x ^ x ^ x   At x:  q                                        *
!*    j+1  > o > o >   At ^:  v, tauy                                  *
!*    j    x ^ x ^ x   At >:  u, taux                                  *
!*    j    > o > o >   At o:  h, fluxes.                               *
!*    j-1  x ^ x ^ x                                                   *
!*        i-1  i  i+1  At x & ^:                                       *
!*           i  i+1    At > & o:                                       *
!*                                                                     *
!*  The boundaries always run through q grid points (x).               *
!*                                                                     *
!********+*********+*********+*********+*********+*********+*********+**
use MOM_diag_mediator, only : post_data, query_averaging_enabled
use MOM_diag_mediator, only : register_diag_field, diag_ctrl, safe_alloc_ptr
use MOM_domains, only : pass_var, pass_vector, AGRID
use MOM_error_handler, only : MOM_error, FATAL, WARNING, is_root_pe
use MOM_file_parser, only : get_param, log_version, param_file_type
use MOM_forcing_type, only : forcing, mech_forcing
use MOM_forcing_type, only : allocate_forcing_type, allocate_mech_forcing
use MOM_grid, only : ocean_grid_type
use MOM_io, only : file_exists, MOM_read_data, slasher
use MOM_time_manager, only : time_type, operator(+), operator(/), get_time
use MOM_tracer_flow_control, only : call_tracer_set_forcing
use MOM_tracer_flow_control, only : tracer_flow_control_CS
use MOM_variables, only : surface

implicit none ; private

public MESO_wind_forcing, MESO_buoyancy_forcing, MESO_surface_forcing_init

type, public :: MESO_surface_forcing_CS ; private
  !   This control structure should be used to store any run-time variables
  ! associated with the user-specified forcing.  It can be readily modified
  ! for a specific case, and because it is private there will be no changes
  ! needed in other code (although they will have to be recompiled).
  !   The variables in the cannonical example are used for some common
  ! cases, but do not need to be used.

  logical :: use_temperature ! If true, temperature and salinity are used as
                             ! state variables.
  logical :: restorebuoy     ! If true, use restoring surface buoyancy forcing.
  real :: Rho0               !   The density used in the Boussinesq
                             ! approximation, in kg m-3.
  real :: G_Earth            !   The gravitational acceleration in m s-2.
  real :: Flux_const         !   The restoring rate at the surface, in m s-1.
  real :: gust_const         !   A constant unresolved background gustiness
                             ! that contributes to ustar, in Pa.
  real, dimension(:,:), pointer :: &
    T_Restore(:,:) => NULL(), & ! The temperature to restore the SST to, in C.
    S_Restore(:,:) => NULL(), & ! The salinity to restore the sea surface salnity
                                ! toward, in PSU.
    PmE(:,:) => NULL(), &       ! The prescribed precip minus evap, in  m s-1.
    Solar(:,:) => NULL(), &     ! The shortwave forcing into the ocean, in W m-2 m s-1.
    Heat(:,:) => NULL()         ! The prescribed longwave, latent and sensible
                                ! heat flux into the ocean, in W m-2.
  character(len=200) :: inputdir ! The directory where NetCDF input files are.
  character(len=200) :: salinityrestore_file, SSTrestore_file
  character(len=200) :: Solar_file, heating_file, PmE_file
  type(diag_ctrl), pointer :: diag ! A structure that is used to regulate the
                             ! timing of diagnostic output.
end type MESO_surface_forcing_CS

logical :: first_call = .true.

contains

!###   This subroutine sets zero surface wind stresses, but it is not even
!### used by the MESO experimeents.  This subroutine can be deleted. -RWH
subroutine MESO_wind_forcing(sfc_state, forces, day, G, CS)
  type(surface),                 intent(inout) :: sfc_state !< A structure containing fields that
                                                    !! describe the surface state of the ocean.
  type(mech_forcing),            intent(inout) :: forces !< A structure with the driving mechanical forces
  type(time_type),               intent(in)    :: day  !< The time of the fluxes
  type(ocean_grid_type),         intent(inout) :: G    !< The ocean's grid structure
  type(MESO_surface_forcing_CS), pointer       :: CS   !< A pointer to the control structure returned by a previous
                                                       !! call to MESO_surface_forcing_init

!   This subroutine sets the surface wind stresses, forces%taux and forces%tauy.
! These are the stresses in the direction of the model grid (i.e. the same
! direction as the u- and v- velocities.)  They are both in Pa.
!   In addition, this subroutine can be used to set the surface friction
! velocity, forces%ustar, in m s-1. This is needed with a bulk mixed layer.
!
! Arguments: state - A structure containing fields that describe the
!                    surface state of the ocean.
!  (out)     fluxes - A structure containing pointers to any possible
!                     forcing fields.  Unused fields have NULL ptrs.
!  (in)      day - Time of the fluxes.
!  (in)      G - The ocean's grid structure.
!  (in)      CS - A pointer to the control structure returned by a previous
!                 call to MESO_surface_forcing_init

  integer :: i, j, is, ie, js, je, Isq, Ieq, Jsq, Jeq
  integer :: isd, ied, jsd, jed, IsdB, IedB, JsdB, JedB

  !   When modifying the code, comment out this error message.  It is here
  ! so that the original (unmodified) version is not accidentally used.
  call MOM_error(FATAL, "MESO_wind_surface_forcing: " // &
     "User forcing routine called without modification." )

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec
  Isq = G%IscB ; Ieq = G%IecB ; Jsq = G%JscB ; Jeq = G%JecB
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  IsdB = G%IsdB ; IedB = G%IedB ; JsdB = G%JsdB ; JedB = G%JedB

  ! Allocate the forcing arrays, if necessary.
  call allocate_mech_forcing(G, forces, stress=.true., ustar=.true.)

  !  Set the surface wind stresses, in units of Pa.  A positive taux
  !  accelerates the ocean to the (pseudo-)east.

  !  The i-loop extends to is-1 so that taux can be used later in the
  ! calculation of ustar - otherwise the lower bound would be Isq.
  do j=js,je ; do I=is-1,Ieq
    forces%taux(I,j) = G%mask2dCu(I,j) * 0.0  ! Change this to the desired expression.
  enddo ; enddo
  do J=js-1,Jeq ; do i=is,ie
    forces%tauy(i,J) = G%mask2dCv(i,J) * 0.0  ! Change this to the desired expression.
  enddo ; enddo

  !    Set the surface friction velocity, in units of m s-1.  ustar
  !  is always positive.
  if (associated(forces%ustar)) then ; do j=js,je ; do i=is,ie
    !  This expression can be changed if desired, but need not be.
    forces%ustar(i,j) = G%mask2dT(i,j) * sqrt(CS%gust_const/CS%Rho0 + &
       sqrt(0.5*(forces%taux(I-1,j)**2 + forces%taux(I,j)**2) + &
            0.5*(forces%tauy(i,J-1)**2 + forces%tauy(i,J)**2))/CS%Rho0)
  enddo ; enddo ; endif

end subroutine MESO_wind_forcing

!> This subroutine sets up the MESO buoyancy forcing, which uses control-theory style
!! specification restorative buoyancy fluxes at large scales.
subroutine MESO_buoyancy_forcing(sfc_state, fluxes, day, dt, G, CS)
  type(surface),                 intent(inout) :: sfc_state !< A structure containing fields that
                                                    !! describe the surface state of the ocean.
  type(forcing),                 intent(inout) :: fluxes !< A structure containing thermodynamic forcing fields
  type(time_type),               intent(in)    :: day  !< The time of the fluxes
  real,                          intent(in)    :: dt   !< The amount of time over which
                                                       !! the fluxes apply, in s
  type(ocean_grid_type),         intent(in)    :: G    !< The ocean's grid structure
  type(MESO_surface_forcing_CS), pointer       :: CS   !< A pointer to the control structure returned by
                                                       !! a previous call to MESO_surface_forcing_init

!    This subroutine specifies the current surface fluxes of buoyancy or
!  temperature and fresh water.  It may also be modified to add
!  surface fluxes of user provided tracers.

!    When temperature is used, there are long list of fluxes that need to be
!  set - essentially the same as for a full coupled model, but most of these
!  can be simply set to zero.  The net fresh water flux should probably be
!  set in fluxes%evap and fluxes%lprec, with any salinity restoring
!  appearing in fluxes%vprec, and the other water flux components
!  (fprec, lrunoff and frunoff) left as arrays full of zeros.
!  Evap is usually negative and precip is usually positive.  All heat fluxes
!  are in W m-2 and positive for heat going into the ocean.  All fresh water
!  fluxes are in kg m-2 s-1 and positive for water moving into the ocean.

! Arguments: state - A structure containing fields that describe the
!                    surface state of the ocean.
!  (out)     fluxes - A structure containing pointers to any possible
!                     forcing fields.  Unused fields have NULL ptrs.
!  (in)      day_start - Start time of the fluxes.
!  (in)      day_interval - Length of time over which these fluxes
!                           will be applied.
!  (in)      G - The ocean's grid structure.
!  (in)      CS - A pointer to the control structure returned by a previous
!                 call to MESO_surface_forcing_init

  real :: Temp_restore   ! The temperature that is being restored toward, in C.
  real :: Salin_restore  ! The salinity that is being restored toward, in PSU.
  real :: density_restore  ! The potential density that is being restored
                         ! toward, in kg m-3.
  real :: rhoXcp ! The mean density times the heat capacity, in J m-3 K-1.
  real :: buoy_rest_const  ! A constant relating density anomalies to the
                           ! restoring buoyancy flux, in m5 s-3 kg-1.

  integer :: i, j, is, ie, js, je
  integer :: isd, ied, jsd, jed

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed

  !   When modifying the code, comment out this error message.  It is here
  ! so that the original (unmodified) version is not accidentally used.

  ! Allocate and zero out the forcing arrays, as necessary.  This portion is
  ! usually not changed.
  if (CS%use_temperature) then
    call safe_alloc_ptr(fluxes%evap, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%lprec, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%fprec, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%lrunoff, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%frunoff, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%vprec, isd, ied, jsd, jed)

    call safe_alloc_ptr(fluxes%sw, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%lw, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%latent, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%sens, isd, ied, jsd, jed)
    call safe_alloc_ptr(fluxes%heat_content_lprec, isd, ied, jsd, jed)
  else ! This is the buoyancy only mode.
    call safe_alloc_ptr(fluxes%buoy, isd, ied, jsd, jed)
  endif


  ! MODIFY THE CODE IN THE FOLLOWING LOOPS TO SET THE BUOYANCY FORCING TERMS.
  if (CS%restorebuoy .and. first_call) then !### .or. associated(CS%ctrl_forcing_CSp)) then
    call safe_alloc_ptr(CS%T_Restore, isd, ied, jsd, jed)
    call safe_alloc_ptr(CS%S_Restore, isd, ied, jsd, jed)
    call safe_alloc_ptr(CS%Heat, isd, ied, jsd, jed)
    call safe_alloc_ptr(CS%PmE, isd, ied, jsd, jed)
    call safe_alloc_ptr(CS%Solar, isd, ied, jsd, jed)

    call MOM_read_data(trim(CS%inputdir)//trim(CS%SSTrestore_file), "SST", &
             CS%T_Restore(:,:), G%Domain)
    call MOM_read_data(trim(CS%inputdir)//trim(CS%salinityrestore_file), "SAL", &
             CS%S_Restore(:,:), G%Domain)
    call MOM_read_data(trim(CS%inputdir)//trim(CS%heating_file), "Heat", &
             CS%Heat(:,:), G%Domain)
    call MOM_read_data(trim(CS%inputdir)//trim(CS%PmE_file), "PmE", &
             CS%PmE(:,:), G%Domain)
    call MOM_read_data(trim(CS%inputdir)//trim(CS%Solar_file), "NET_SOL", &
             CS%Solar(:,:), G%Domain)
    first_call = .false.
  endif

  if ( CS%use_temperature ) then
    ! Set whichever fluxes are to be used here.  Any fluxes that
    ! are always zero do not need to be changed here.
    do j=js,je ; do i=is,ie
      ! Fluxes of fresh water through the surface are in units of kg m-2 s-1
      ! and are positive downward - i.e. evaporation should be negative.
      fluxes%evap(i,j) = -0.0 * G%mask2dT(i,j)
      fluxes%lprec(i,j) = CS%PmE(i,j) * CS%Rho0 * G%mask2dT(i,j)

      ! vprec will be set later, if it is needed for salinity restoring.
      fluxes%vprec(i,j) = 0.0

      !   Heat fluxes are in units of W m-2 and are positive into the ocean.
      fluxes%lw(i,j)                 = 0.0 * G%mask2dT(i,j)
      fluxes%latent(i,j)             = 0.0 * G%mask2dT(i,j)
      fluxes%sens(i,j)               = CS%Heat(i,j) * G%mask2dT(i,j)
      fluxes%sw(i,j)                 = CS%Solar(i,j) * G%mask2dT(i,j)
    enddo ; enddo
  else ! This is the buoyancy only mode.
    do j=js,je ; do i=is,ie
      !   fluxes%buoy is the buoyancy flux into the ocean in m2 s-3.  A positive
      ! buoyancy flux is of the same sign as heating the ocean.
      fluxes%buoy(i,j) = 0.0 * G%mask2dT(i,j)
    enddo ; enddo
  endif

  if (CS%restorebuoy) then
    if (CS%use_temperature) then
      call safe_alloc_ptr(fluxes%heat_added, isd, ied, jsd, jed)
      !   When modifying the code, comment out this error message.  It is here
      ! so that the original (unmodified) version is not accidentally used.
!      call MOM_error(FATAL, "MESO_buoyancy_surface_forcing: " // &
!        "Temperature and salinity restoring used without modification." )

      rhoXcp = CS%Rho0 * fluxes%C_p
      do j=js,je ; do i=is,ie
        !   Set Temp_restore and Salin_restore to the temperature (in C) and
        ! salinity (in PSU) that are being restored toward.
        if (G%mask2dT(i,j) > 0) then
          fluxes%heat_added(i,j) = G%mask2dT(i,j) * &
              ((CS%T_Restore(i,j) - sfc_state%SST(i,j)) * rhoXcp * CS%Flux_const)
          fluxes%vprec(i,j) = - (CS%Rho0*CS%Flux_const) * &
              (CS%S_Restore(i,j) - sfc_state%SSS(i,j)) / &
              (0.5*(sfc_state%SSS(i,j) + CS%S_Restore(i,j)))
        else
          fluxes%heat_added(i,j) = 0.0
          fluxes%vprec(i,j) = 0.0
        endif
      enddo ; enddo
    else
      !   When modifying the code, comment out this error message.  It is here
      ! so that the original (unmodified) version is not accidentally used.
      call MOM_error(FATAL, "MESO_buoyancy_surface_forcing: " // &
        "Buoyancy restoring used without modification." )

      ! The -1 is because density has the opposite sign to buoyancy.
      buoy_rest_const = -1.0 * (CS%G_Earth * CS%Flux_const) / CS%Rho0
      do j=js,je ; do i=is,ie
       !   Set density_restore to an expression for the surface potential
       ! density in kg m-3 that is being restored toward.
        density_restore = 1030.0

        fluxes%buoy(i,j) = G%mask2dT(i,j) * buoy_rest_const * &
                          (density_restore - sfc_state%sfc_density(i,j))
      enddo ; enddo
    endif
  endif                                             ! end RESTOREBUOY

end subroutine MESO_buoyancy_forcing

!> Initialize the MESO surface forcing module
subroutine MESO_surface_forcing_init(Time, G, param_file, diag, CS)

  type(time_type),               intent(in)    :: Time !< The current model time
  type(ocean_grid_type),         intent(in)    :: G    !< The ocean's grid structure
  type(param_file_type),         intent(in)    :: param_file !< A structure to parse for run-time parameters
  type(diag_ctrl), target,       intent(inout) :: diag !< structure used to regulate diagnostic output
  type(MESO_surface_forcing_CS), pointer       :: CS   !< A pointer that is set to point to the
                                                       !! control structure for this module

! Arguments: Time - The current model time.
!  (in)      G - The ocean's grid structure.
!  (in)      param_file - A structure indicating the open file to parse for
!                         model parameter values.
!  (in)      diag - A structure that is used to regulate diagnostic output.
!  (in/out)  CS - A pointer that is set to point to the control structure
!                 for this module

! This include declares and sets the variable "version".
#include "version_variable.h"
  character(len=40)  :: mdl = "MESO_surface_forcing" ! This module's name.

  if (associated(CS)) then
    call MOM_error(WARNING, "MESO_surface_forcing_init called with an associated "// &
                             "control structure.")
    return
  endif
  allocate(CS)
  CS%diag => diag

  ! Read all relevant parameters and write them to the model log.
  call log_version(param_file, mdl, version, "")
  call get_param(param_file, mdl, "ENABLE_THERMODYNAMICS", CS%use_temperature, &
                 "If true, Temperature and salinity are used as state \n"//&
                 "variables.", default=.true.)

  call get_param(param_file, mdl, "G_EARTH", CS%G_Earth, &
                 "The gravitational acceleration of the Earth.", &
                 units="m s-2", default = 9.80)
  call get_param(param_file, mdl, "RHO_0", CS%Rho0, &
                 "The mean ocean density used with BOUSSINESQ true to \n"//&
                 "calculate accelerations and the mass for conservation \n"//&
                 "properties, or with BOUSSINSEQ false to convert some \n"//&
                 "parameters from vertical units of m to kg m-2.", &
                 units="kg m-3", default=1035.0)
  call get_param(param_file, mdl, "GUST_CONST", CS%gust_const, &
                 "The background gustiness in the winds.", units="Pa", &
                 default=0.02)

  call get_param(param_file, mdl, "RESTOREBUOY", CS%restorebuoy, &
                 "If true, the buoyancy fluxes drive the model back \n"//&
                 "toward some specified surface state with a rate \n"//&
                 "given by FLUXCONST.", default= .false.)

  if (CS%restorebuoy) then
    call get_param(param_file, mdl, "FLUXCONST", CS%Flux_const, &
                 "The constant that relates the restoring surface fluxes \n"//&
                 "to the relative surface anomalies (akin to a piston \n"//&
                 "velocity).  Note the non-MKS units.", units="m day-1", &
                 fail_if_missing=.true.)
    ! Convert CS%Flux_const from m day-1 to m s-1.
    CS%Flux_const = CS%Flux_const / 86400.0

    call get_param(param_file, mdl, "SSTRESTORE_FILE", CS%SSTrestore_file, &
                 "The file with the SST toward which to restore in \n"//&
                 "variable TEMP.", fail_if_missing=.true.)
    call get_param(param_file, mdl, "SALINITYRESTORE_FILE", CS%salinityrestore_file, &
                 "The file with the surface salinity toward which to \n"//&
                 "restore in variable SALT.", fail_if_missing=.true.)
    call get_param(param_file, mdl, "SENSIBLEHEAT_FILE", CS%heating_file, &
                 "The file with the non-shortwave heat flux in \n"//&
                 "variable Heat.", fail_if_missing=.true.)
    call get_param(param_file, mdl, "PRECIP_FILE", CS%PmE_file, &
                 "The file with the net precipiation minus evaporation \n"//&
                 "in variable PmE.", fail_if_missing=.true.)
    call get_param(param_file, mdl, "SHORTWAVE_FILE", CS%Solar_file, &
                 "The file with the shortwave heat flux in \n"//&
                 "variable NET_SOL.", fail_if_missing=.true.)
    call get_param(param_file, mdl, "INPUTDIR", CS%inputdir, default=".")
    CS%inputdir = slasher(CS%inputdir)

   endif

end subroutine MESO_surface_forcing_init

end module MESO_surface_forcing
