! SPH_UPDATE.F90
! C. P. Batty & D. A. Hubber - 18/1/2007
! Control subroutine for calculating all SPH properties, 
! i.e. smoothing lengths, neighbour lists and densities, of all particles.
! ============================================================================

#include "macros.h"
#define PREEMPTIVE_GHOSTS 1

! ============================================================================
SUBROUTINE mpi_sph_update
   use interface_module, only : active_particle_list,all_sph,&
        &bounding_box,get_neib,h_gather,h_rho_iteration,mpi_h_gather
   use particle_module
   use neighbour_module
   use type_module
   use timing_module
   use tree_module
#if defined(OPENMP)
   use omp_lib
#endif
   use mpi_communication_module
   use domain_comparisons
   use mpi
   implicit none

   integer :: acctot                   ! No. of particles on acc. step
   integer :: acchydrotot              ! No. of active hydro particles
   integer :: i                        ! Aux. particle counter
   integer :: p                        ! particle counter
   integer :: ierr                     ! MPI error value
   integer, allocatable :: acclist(:)  ! List of particles on acc. step
   real(kind=PR), allocatable :: r(:,:) ! Temporary list of particle positions
#if defined(GRAD_H_SPH)
   real(kind=PR) :: r_max(1:NDIM)       ! ..
   real(kind=PR) :: r_min(1:NDIM)       ! ..
   real(kind=PR) :: r_ghost_max(1:NDIM) ! ..
   real(kind=PR) :: r_ghost_min(1:NDIM) ! ..
#endif
#if defined(OPENMP)
   integer :: chunksize                ! Loop chunksize for OMP
#endif
   integer :: h_not_done                  ! Number of particles who need second pass
   integer, allocatable :: h_list(:)  ! List of particles not done
   real(kind=PR), allocatable :: h_old(:)  ! List of particles not done old smoothing length
   integer, allocatable :: t_h_list(:)! Thread list of particles not done
   real(kind=PR), allocatable :: t_h_old(:)  ! List of particles not done old smoothing length
   integer :: t_h_not_done            ! Thread number of particles who need second pass
   integer :: h_chunksize             ! Chunksize for second pass of h_gather

   debug2("Calculating SPH quantities [mpi_sph_update.F90]")

   debug_timing("MPI_SPH_UPDATE")
   
! Prepare list of particles which are on an acceleration step
! ----------------------------------------------------------------------------
   allocate(acclist(1:ptot))
   call active_particle_list(acctot,acclist,sphmask)
#if defined(OPENMP)
   chunksize = int(CHUNKFRAC*real(acctot,PR)/real(omp_get_max_threads(),PR)) + 1
#endif
#if defined(TIMING)
   nsphcomp = nsphcomp + int(acctot,ILP)
#endif
   sum_acctot = sum_acctot + acctot

! Set up some variables
   h_not_done = 0           ! This is incremented if any particle requires ghosts

! Call all subroutines even if there aren't active particles (MPI)
! ============================================================================

  ! Find the size of the non-overlapped box
   call nonoverlapbox()
   debug_timing("MPI_SPH_UPDATE")
#if defined(H_RHO)
   debug2("Obtaining bounding box containing all particles")
   ! Get max and min of x,y,z coordinates
   allocate(r(1:NDIM,1:ptot))
   do p=1,ptot
      r(1:NDIM,p) = sph(p)%r(1:NDIM)
   end do
   call bounding_box(ptot,r,rmax(1:NDIM),rmin(1:NDIM))
   deallocate(r)
   WAIT_TIME_MACRO
   call MPI_ALLREDUCE(MPI_IN_PLACE,rmin,NDIM,MPI_REAL_PR,& ! this is sort of
      MPI_MIN,MPI_COMM_WORLD,ierr)                         ! optional
   call MPI_ALLREDUCE(MPI_IN_PLACE,rmax,NDIM,MPI_REAL_PR,& ! DELETE ME ???
      MPI_MAX,MPI_COMM_WORLD,ierr)
   CALC_TIME_MACRO
   rextent = maxval(rmax(1:NDIM) - rmin(1:NDIM))
#endif
   allocate(h_list(1:acctot))
   allocate(h_old(1:acctot))

#if defined(PERIODIC) && defined(PREEMPTIVE_GHOSTS)
   ! Perform a preemptive search for ghost particles using old smoothing lengths
   call maxmin_hydro_filter(bbmax(1:NDIM,rank),bbmin(1:NDIM,rank),&
      & acclist(1:acctot),acctot,.TRUE.)
   debug_timing("BROADCAST_BOUNDING_BOXES 0")
   call broadcastboundingboxes(bbmin,bbmax)
   
! Use bounding boxes to import ghosts
   call mpi_search_ghost_particles(.TRUE.)
   debug_timing("GHOSTS 0")
   call get_ghosts(.FALSE.)
   debug_timing("GHOST_TREE 0")
   ! (Re)build neighbour tree of ghost particles
   if (pghost > pperiodic) then
      call BHghost_build
      call BHhydro_stock(cmax_ghost,ctot_ghost,&
         &ltot_ghost,first_cell_ghost,last_cell_ghost,BHghost)
   end if
#endif

   ! h_gather pass 1
   ! -----------------------------------------------------------------------

   ! Set initial bounding box so that it is 'negative'
   ! and no particle will fall within it
   bbmin(1:NDIM,rank) = BIG_NUMBER
   bbmax(1:NDIM,rank) = -BIG_NUMBER
   
   debug_timing("MPI_SPH_UPD. PASS 1")
   !$OMP PARALLEL PRIVATE(i, p, t_h_not_done, t_h_list, t_h_old)
   allocate(t_h_list(1:acctot))
   allocate(t_h_old(1:acctot))
   t_h_not_done = 0
   !$OMP DO SCHEDULE(DYNAMIC,chunksize)
   do i=1,acctot
      p = acclist(i)
      call mpi_h_gather(p,acctot,t_h_not_done,t_h_list,t_h_old,typeinfo(sph(p)%ptype)%h)
   end do
   !$OMP END DO NOWAIT
   !$OMP CRITICAL
   h_list(h_not_done+1:h_not_done+t_h_not_done) = t_h_list(1:t_h_not_done)
   h_old(h_not_done+1:h_not_done+t_h_not_done) = t_h_old(1:t_h_not_done)
   h_not_done = h_not_done + t_h_not_done
   !$OMP END CRITICAL
   deallocate(t_h_list)
   deallocate(t_h_old)
   !$OMP END PARALLEL
   if (h_not_done > 0) then
      call maxmin_hydro_filter(bbmax(1:NDIM,rank),bbmin(1:NDIM,rank),&
         & h_list(1:h_not_done),h_not_done,.TRUE.)
   end if
   debug_timing("MPI_SPH_UPD. PASS 1")
#if defined(OPENMP)
   h_chunksize = int(CHUNKFRAC*real(h_not_done,PR)) + 1
#endif
   sum_second_h = sum_second_h + h_not_done

   debug_timing("BROADCAST_BOUNDING_BOXES 1")
   call broadcastboundingboxes(bbmin,bbmax)

   ! obtain ghosts
   ! -----------------------------------------------------------------------

! Find periodic local ghosts, and mark periodic ghosts for export
#if defined(PERIODIC)
   call mpi_search_ghost_particles(.FALSE.)
#endif

! Use bounding boxes to import ghosts
   debug_timing("GHOSTS 1")
   call get_ghosts(.FALSE.)
   ! Save the current number of ghosts (local periodic and MPI ghosts)
   ! to be used to estimate memory requirements in transfer_particles
   last_pghost = pghost

#if defined(H_RHO)
   ! This part is also sort of optional
   debug2("Obtaining bounding box containing ghost particles")
   ! Get max and min of x,y,z coordinates
   allocate(r(1:NDIM,1:pghost))
   do i=1,pghost
      p = ptot + i
      r(1:NDIM,i) = sph(p)%r(1:NDIM)
   end do
   call bounding_box(pghost,r,r_ghost_max(1:NDIM),r_ghost_min(1:NDIM))
   rmin = min(rmin, r_ghost_min)
   rmax = max(rmax, r_ghost_max)
   deallocate(r)
   WAIT_TIME_MACRO
   call MPI_ALLREDUCE(MPI_IN_PLACE,rmin,NDIM,MPI_REAL_PR,& ! this is sort of
      MPI_MIN,MPI_COMM_WORLD,ierr)                         ! optional
   call MPI_ALLREDUCE(MPI_IN_PLACE,rmax,NDIM,MPI_REAL_PR,& ! DELETE ME ???
      MPI_MAX,MPI_COMM_WORLD,ierr)
   CALC_TIME_MACRO
   rextent = maxval(rmax(1:NDIM) - rmin(1:NDIM))
#endif
   
   debug_timing("GHOST_TREE 1")

#if defined(BH_TREE)
   ! (Re)build neighbour tree of ghost particles
   if (pghost > pperiodic) then
      call BHghost_build
      call BHhydro_stock(cmax_ghost,ctot_ghost,&
         &ltot_ghost,first_cell_ghost,last_cell_ghost,BHghost)
   end if
#endif

   ! h_gather pass 2
   ! -----------------------------------------------------------------------
   
   debug_timing("MPI_SPH_UPD. PASS 2")

! Calculate smoothing lengths for all overlapping particles
   if (h_not_done > 0) then
      !$OMP PARALLEL DO SCHEDULE(DYNAMIC,h_chunksize) PRIVATE(p)
      do i=1,h_not_done
         p = h_list(i)
         sph(p)%h = h_old(i)
#if defined(H_RHO)
         call h_rho_iteration(p,sph(p)%h,typeinfo(sph(p)%ptype)%h)
#elif defined(HGATHER) || defined(HMASS)
         call h_gather(p,sph(p)%h,sph(p)%r(1:NDIM),typeinfo(sph(p)%ptype)%h)
#endif
      end do
      !$OMP END PARALLEL DO
   end if

   deallocate(h_list)
   deallocate(h_old)

   ! Calculate all SPH gather quantities
   ! -----------------------------------------------------------------------
   debug2("Calculating SPH quantities for all particles")
   debug_timing("ALL_SPH")

   !$OMP PARALLEL DO SCHEDULE(DYNAMIC,chunksize) DEFAULT(SHARED) PRIVATE(p)
   do i=1,acctot
      p = acclist(i)
      call all_sph(p,typeinfo(sph(p)%ptype)%h)
   end do
   !$OMP END PARALLEL DO

   ! Update hmax in hydro cells now smoothing lengths have been calculated
   ! -----------------------------------------------------------------------
#ifdef BH_TREE
   debug_timing("BH_TREE")
   call BHhydro_update_hmax(cmax_hydro,ctot_hydro,&
      &ltot_hydro,first_cell_hydro,last_cell_hydro,BHhydro)
#endif
! 
!      ! Update (periodic) ghost particle properties
!      ! -----------------------------------------------------------------------
! #if defined(GHOST_PARTICLES) && defined(PERIODIC)
!      if (pperiodic > 0) then
!         call copy_data_to_ghosts
! #if defined(BH_TREE)
!         call BHhydro_update_hmax(cmax_ghost,ctot_ghost,&
!              &ltot_ghost,first_cell_ghost,last_cell_ghost,BHghost)
! #endif
!      end if
! #endif

! ============================================================================

   if (allocated(acclist)) deallocate(acclist)

  return
END SUBROUTINE mpi_sph_update
