
"""
    dmrg(H::MPO,psi0::MPS,sweeps::Sweeps;kwargs...)
                    
Use the density matrix renormalization group (DMRG) algorithm
to optimize a matrix product state (MPS) such that it is the
eigenvector of lowest eigenvalue of a Hermitian matrix H,
represented as a matrix product operator (MPO).
The MPS `psi0` is used to initialize the MPS to be optimized,
and the `sweeps` object determines the parameters used to 
control the DMRG algorithm.

Returns:
* `energy::Float64` - eigenvalue of the optimized MPS
* `psi::MPS` - optimized MPS
"""
function dmrg(H::MPO,
              psi0::MPS,
              sweeps::Sweeps;
              kwargs...)
  PH = ProjMPO(H)
  return dmrg(PH,psi0,sweeps;kwargs...)
end

"""
    dmrg(Hs::Vector{MPO},psi0::MPS,sweeps::Sweeps;kwargs...)
                    
Use the density matrix renormalization group (DMRG) algorithm
to optimize a matrix product state (MPS) such that it is the
eigenvector of lowest eigenvalue of a Hermitian matrix H.
The MPS `psi0` is used to initialize the MPS to be optimized,
and the `sweeps` object determines the parameters used to 
control the DMRG algorithm.

This version of `dmrg` accepts a representation of H as a
Vector of MPOs, Hs = [H1,H2,H3,...] such that H is defined
as H = H1+H2+H3+...
Note that this sum of MPOs is not actually computed; rather
the set of MPOs [H1,H2,H3,..] is efficiently looped over at 
each step of the DMRG algorithm when optimizing the MPS.

Returns:
* `energy::Float64` - eigenvalue of the optimized MPS
* `psi::MPS` - optimized MPS
"""
function dmrg(Hs::Vector{MPO},
              psi0::MPS,
              sweeps::Sweeps;
              kwargs...)
  PHS = ProjMPOSum(Hs)
  return dmrg(PHS,psi0,sweeps;kwargs...)
end

"""
    dmrg(H::MPO,Ms::Vector{MPS},psi0::MPS,sweeps::Sweeps;kwargs...)
                    
Use the density matrix renormalization group (DMRG) algorithm
to optimize a matrix product state (MPS) such that it is the
eigenvector of lowest eigenvalue of a Hermitian matrix H,
subject to the constraint that the MPS is orthogonal to each
of the MPS provided in the Vector `Ms`. The orthogonality
constraint is approximately enforced by adding to H terms of 
the form w|M1><M1| + w|M2><M2| + ... where Ms=[M1,M2,...] and
w is the "weight" parameter, which can be adjusted through the
optional `weight` keyword argument.
The MPS `psi0` is used to initialize the MPS to be optimized,
and the `sweeps` object determines the parameters used to 
control the DMRG algorithm.

Returns:
* `energy::Float64` - eigenvalue of the optimized MPS
* `psi::MPS` - optimized MPS
"""
function dmrg(H::MPO,
              Ms::Vector{MPS},
              psi0::MPS,
              sweeps::Sweeps;
              kwargs...)
  weight = get(kwargs,:weight,1.0)
  PMM = ProjMPO_MPS(H,Ms;weight=weight)
  return dmrg(PMM,psi0,sweeps;kwargs...)
end


function dmrg(PH,
              psi0::MPS,
              sweeps::Sweeps;
              kwargs...)
  which_decomp::String = get(kwargs, :which_decomp, "automatic")
  obs = get(kwargs, :observer, NoObserver())
  quiet::Bool = get(kwargs, :quiet, false)

  # eigsolve kwargs
  eigsolve_tol::Float64   = get(kwargs, :eigsolve_tol, 1e-14)
  eigsolve_krylovdim::Int = get(kwargs, :eigsolve_krylovdim, 3)
  eigsolve_maxiter::Int   = get(kwargs, :eigsolve_maxiter, 1)
  eigsolve_verbosity::Int = get(kwargs, :eigsolve_verbosity, 0)

  # TODO: add support for non-Hermitian DMRG
  # get(kwargs, :ishermitian, true)
  ishermitian::Bool = true

  # TODO: add support for targeting other states with DMRG
  # (such as the state with the largest eigenvalue)
  # get(kwargs, :eigsolve_which_eigenvalue, :SR)
  eigsolve_which_eigenvalue::Symbol = :SR

  # Keyword argument deprecations
  if haskey(kwargs, :maxiter)
    error("""maxiter keyword has been replace by eigsolve_krylovdim.
             Note: compared to the C++ version of ITensor,
             setting eigsolve_krylovdim 3 is the same as setting
             a maxiter of 2.""")
  end

  if haskey(kwargs, :errgoal)
    error("errgoal keyword has been replace by eigsolve_tol.")
  end

  psi = copy(psi0)
  N = length(psi)

  position!(PH, psi0, 1)
  energy = 0.0

  for sw=1:nsweep(sweeps)
    sw_time = @elapsed begin

    for (b, ha) in sweepnext(N)

@timeit_debug GLOBAL_TIMER "position!" begin
      position!(PH, psi, b)
end

@timeit_debug GLOBAL_TIMER "psi[b]*psi[b+1]" begin
      phi = psi[b] * psi[b+1]
end

@timeit_debug GLOBAL_TIMER "eigsolve" begin
      vals, vecs = eigsolve(PH, phi, 1, eigsolve_which_eigenvalue;
                            ishermitian = ishermitian,
                            tol = eigsolve_tol,
                            krylovdim = eigsolve_krylovdim,
                            maxiter = eigsolve_maxiter)
end
      energy, phi = vals[1], vecs[1]

      ortho = ha == 1 ? "left" : "right"

      drho = nothing
      if noise(sweeps, sw) > 0.0
        # Use noise term when determining new MPS basis
        drho = noise(sweeps, sw) * noiseterm(PH, phi, b, ortho)
      end

@timeit_debug GLOBAL_TIMER "replacebond!" begin
        spec = replacebond!(psi, b, phi; maxdim = maxdim(sweeps, sw),
                                         mindim = mindim(sweeps, sw),
                                         cutoff = cutoff(sweeps, sw),
                                         eigen_perturbation = drho,
                                         ortho = ortho,
                                         which_decomp = which_decomp)
end

      measure!(obs; energy = energy,
                    psi = psi,
                    bond = b,
                    sweep = sw,
                    half_sweep = ha,
                    spec = spec,
                    quiet = quiet)
    end
    end
    if !quiet
      @printf("After sweep %d energy=%.12f maxlinkdim=%d time=%.3f\n",
              sw, energy, maxlinkdim(psi), sw_time)
    end
    checkdone!(obs; quiet = quiet) && break
  end
  return (energy, psi)
end
