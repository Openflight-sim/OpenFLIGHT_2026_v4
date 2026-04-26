# ──────────────────────────────────────────────────────────────
# driver.jl — Main solver driver
# ──────────────────────────────────────────────────────────────

"""
    solve_case(avl_file; alpha=0.0, beta=0.0, mach=nothing,
               cl_target=nothing, verbose=true) → AVLSolution

High-level solver: reads an AVL input file and solves for forces.

# Arguments
- `avl_file`: path to .avl geometry file
- `alpha`: angle of attack in degrees (used if cl_target is nothing)
- `beta`: sideslip angle in degrees
- `mach`: override Mach number (uses file value if nothing)
- `cl_target`: if set, trim alpha to achieve this CL
- `verbose`: print results to stdout

# Returns
- `AVLSolution` with all computed forces, moments, and derivatives
"""
function solve_case(avl_file::AbstractString;
                    alpha::Float64=0.0,
                    beta::Float64=0.0,
                    mach::Union{Nothing,Float64}=nothing,
                    cl_target::Union{Nothing,Float64}=nothing,
                    verbose::Bool=true)
    # read configuration
    config = read_avl(avl_file)
    if mach !== nothing
        config.mach = mach
    end

    verbose && println("Configuration: ", config.title)
    verbose && @printf("  Surfaces: %d,  Mach: %.4f\n", length(config.surfaces), config.mach)
    verbose && @printf("  Sref=%.4f  Cref=%.4f  Bref=%.4f\n", config.sref, config.cref, config.bref)

    # build vortex lattice
    verbose && print("Building vortex lattice... ")
    vl = build_lattice(config)
    verbose && @printf("%d vortices, %d strips, %d surfaces\n", vl.nvor, vl.nstrip, vl.nsurf)

    # build body source model (if bodies present)
    src_u = zeros(0, 6)
    dbl_u = zeros(3, 0, 6)
    wcsrd_u = nothing
    if !isempty(config.bodies)
        verbose && print("Building body model... ")
        src_u, dbl_u, wcsrd_u_arr = setup_body!(vl, config)
        wcsrd_u = size(wcsrd_u_arr, 2) > 0 ? wcsrd_u_arr : nothing
        verbose && @printf("%d bodies, %d total nodes\n",
                           vl.nbody, sum(length.(vl.body_nodes)))
    end

    # build and factor AIC matrix
    verbose && print("Building AIC matrix... ")
    aic = setup_aic(vl, config)
    verbose && println("done")

    # solve unit RHS (with body velocity influence)
    verbose && print("Solving unit RHS... ")
    gam_u0, gam_u_d = solve_unit_rhs(vl, config, aic; wcsrd_u=wcsrd_u)
    verbose && println("done")

    # set up run case
    nc = vl.ncontrol
    rc = RunCase(nc)

    if cl_target !== nothing
        # trim alpha to achieve target CL
        rc.icon[IVALFA] = ICCL  # alpha → CL
        rc.conval[ICCL] = cl_target
    else
        rc.icon[IVALFA] = ICALFA  # alpha → alpha
        rc.conval[ICALFA] = deg2rad(alpha)
    end
    rc.icon[IVBETA] = ICBETA
    rc.conval[ICBETA] = deg2rad(beta)

    # rotation rates: constrain to zero by default
    rc.icon[IVROTX] = ICROTX; rc.conval[ICROTX] = 0.0
    rc.icon[IVROTY] = ICROTY; rc.conval[ICROTY] = 0.0
    rc.icon[IVROTZ] = ICROTZ; rc.conval[ICROTZ] = 0.0

    # control surfaces: constrain to zero deflection
    for n in 1:nc
        rc.icon[IVTOT+n] = ICTOT + n
        rc.conval[ICTOT+n] = 0.0
    end

    rc.parval[IPMACH] = config.mach
    rc.parval[IPALFA] = deg2rad(alpha)
    rc.parval[IPBETA] = deg2rad(beta)

    # create solution
    sol = AVLSolution(vl.nvor, nc, vl.nstrip)

    # execute trim
    verbose && print("Solving... ")
    exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc;
               src_u = size(src_u, 1) > 0 ? src_u : nothing)
    if sol.converged
        verbose && @printf("converged in %d iterations\n", sol.iterations)
    else
        verbose && @printf("did NOT converge after %d iterations\n", sol.iterations)
    end

    # output results
    if verbose
        print_total_forces(stdout, sol, vl, config)
    end

    return sol
end

"""
    solve_case(config::AVLConfig, rc::RunCase; verbose=true) → AVLSolution

Lower-level solver: takes pre-built config and run case.
"""
function solve_case(config::AVLConfig, rc::RunCase; verbose::Bool=true)
    vl = build_lattice(config)

    # body model
    src_u = zeros(0, 6)
    wcsrd_u = nothing
    if !isempty(config.bodies)
        src_u, _dbl_u, wcsrd_u_arr = setup_body!(vl, config)
        wcsrd_u = size(wcsrd_u_arr, 2) > 0 ? wcsrd_u_arr : nothing
    end

    aic = setup_aic(vl, config)
    gam_u0, gam_u_d = solve_unit_rhs(vl, config, aic; wcsrd_u=wcsrd_u)

    nc = vl.ncontrol
    sol = AVLSolution(vl.nvor, nc, vl.nstrip)

    exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc;
               src_u = size(src_u, 1) > 0 ? src_u : nothing)

    if verbose
        print_total_forces(stdout, sol, vl, config)
    end

    return sol
end

"""
    solve_multiple(avl_file, run_file; verbose=true) → Vector{AVLSolution}

Solve all run cases from a .run file.
"""
function solve_multiple(avl_file::AbstractString, run_file::AbstractString;
                         verbose::Bool=true)
    config = read_avl(avl_file)
    vl = build_lattice(config)

    # body model
    src_u = zeros(0, 6)
    wcsrd_u = nothing
    if !isempty(config.bodies)
        src_u, _dbl_u, wcsrd_u_arr = setup_body!(vl, config)
        wcsrd_u = size(wcsrd_u_arr, 2) > 0 ? wcsrd_u_arr : nothing
    end

    aic = setup_aic(vl, config)
    gam_u0, gam_u_d = solve_unit_rhs(vl, config, aic; wcsrd_u=wcsrd_u)

    nc = vl.ncontrol
    cases = read_runfile(run_file, nc)

    src_kw = size(src_u, 1) > 0 ? src_u : nothing
    solutions = AVLSolution[]
    for rc in cases
        sol = AVLSolution(vl.nvor, nc, vl.nstrip)
        exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc; src_u=src_kw)
        if verbose
            print_total_forces(stdout, sol, vl, config)
        end
        push!(solutions, sol)
    end

    return solutions
end

"""
    get_lattice(avl_file) → (AVLConfig, VortexLattice)

Read config and build lattice without solving — useful for inspection.
"""
function get_lattice(avl_file::AbstractString)
    config = read_avl(avl_file)
    vl = build_lattice(config)
    return config, vl
end

"""
    get_nodal_forces(sol, vl, config; qinf=1.0) → DataFrame-like structure

Extract nodal forces suitable for FEM coupling.
Returns a vector of (x, y, z, Fx, Fy, Fz) tuples for each vortex element.
"""
function get_nodal_forces(sol::AVLSolution, vl::VortexLattice, config::AVLConfig;
                           qinf::Float64=1.0)
    forces = Vector{NTuple{6,Float64}}()
    sref = config.sref

    for ie in 1:vl.nvor
        elem = vl.elements[ie]
        strip = vl.strips[elem.istrip]

        gam_i = sol.gam[ie]

        # bound leg vector
        gx = elem.rv2[1] - elem.rv1[1]
        gy = elem.rv2[2] - elem.rv1[2]
        gz = elem.rv2[3] - elem.rv1[3]

        # effective velocity
        veff_x = sol.vinf[1] + sol.wv[1, ie]
        veff_y = sol.vinf[2] + sol.wv[2, ie]
        veff_z = sol.vinf[3] + sol.wv[3, ie]

        # add rotation
        xyzref = config.xyzref
        rx = elem.rv[1] - xyzref[1]
        ry = elem.rv[2] - xyzref[2]
        rz = elem.rv[3] - xyzref[3]
        veff_x += sol.wrot[2]*rz - sol.wrot[3]*ry
        veff_y += sol.wrot[3]*rx - sol.wrot[1]*rz
        veff_z += sol.wrot[1]*ry - sol.wrot[2]*rx

        # Kutta-Joukowski force (dimensional: multiply by q_inf * Sref)
        fx = 2.0 * qinf * gam_i * (veff_y*gz - veff_z*gy)
        fy = 2.0 * qinf * gam_i * (veff_z*gx - veff_x*gz)
        fz = 2.0 * qinf * gam_i * (veff_x*gy - veff_y*gx)

        push!(forces, (elem.rv[1], elem.rv[2], elem.rv[3], fx, fy, fz))
    end

    return forces
end
