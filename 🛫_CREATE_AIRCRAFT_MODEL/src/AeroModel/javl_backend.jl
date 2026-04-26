"""
    javl_backend.jl — Julia AVL backend adapter

Converts aircraft JSON to AVL format, runs JAVL solver,
and extracts stability/control derivatives.
"""

const JAVL_PATH = normpath(joinpath(@__DIR__, "..", "..", "Aero_back_ends", "JAVL.jl"))

let _javl_loaded = Ref(false)
    global function ensure_javl_loaded()
        if !_javl_loaded[]
            pushfirst!(LOAD_PATH, JAVL_PATH)
            @eval include(joinpath($JAVL_PATH, "src", "AVL.jl"))
            _javl_loaded[] = true
        end
    end
end

"""
    run_javl_backend(input::AircraftInput; progress_callback=nothing) -> Dict

Converts aircraft definition to AVL format, runs the solver
over the alpha sweep, and returns forces/derivatives.
"""
function run_javl_backend(input::AircraftInput; progress_callback=nothing)
    cb = isnothing(progress_callback) ? (s, p, m) -> nothing : progress_callback

    ensure_javl_loaded()

    alphas_deg = get_alpha_array(input.analysis)
    betas_deg = get_beta_array(input.analysis)
    n_alpha = length(alphas_deg)

    cb("running", 5, "Generating AVL geometry...")

    # Generate AVL input string
    avl_str = generate_avl_string(input)

    # Write to temp file
    avl_tmpfile = tempname() * ".avl"
    open(avl_tmpfile, "w") do io
        write(io, avl_str)
    end

    cb("running", 10, "Building vortex lattice...")

    # Parse and build lattice
    config = @eval AVL.read_avl($avl_tmpfile)
    vl = @eval AVL.build_lattice($config)

    # Setup AIC
    cb("running", 20, "Computing AIC matrix...")
    aic = @eval AVL.setup_aic($vl, $config)

    # Solve unit RHS
    gam_u0, gam_u_d = @eval AVL.solve_unit_rhs($vl, $config, $aic)

    # Result arrays
    CL_arr = zeros(n_alpha)
    CD_arr = zeros(n_alpha)
    CY_arr = zeros(n_alpha)
    Cl_arr = zeros(n_alpha)
    Cm_arr = zeros(n_alpha)
    Cn_arr = zeros(n_alpha)

    # Derivative arrays
    deriv_names = ["cl_u", "cd_u", "cy_u", "cmx_u", "cmy_u", "cmz_u"]
    derivs_raw = Dict{String,Vector{Vector{Float64}}}()
    for name in deriv_names
        derivs_raw[name] = Vector{Vector{Float64}}()
    end

    # Control derivative storage: one vector per control, per coefficient
    n_controls = @eval $vl.ncontrol
    control_names = n_controls > 0 ? (@eval collect($vl.control_names)) : String[]
    ctrl_deriv_fields = ["cl_d", "cd_d", "cy_d", "cmx_d", "cmy_d", "cmz_d"]
    ctrl_derivs_raw = Dict{String,Vector{Vector{Float64}}}()
    for name in ctrl_deriv_fields
        ctrl_derivs_raw[name] = Vector{Vector{Float64}}()
    end

    # Per-surface force storage
    n_surfaces = @eval $vl.nsurf
    surf_names = n_surfaces > 0 ? (@eval collect($vl.surf_names)) : String[]
    surf_jfrst = n_surfaces > 0 ? (@eval collect($vl.surf_jfrst)) : Int[]
    surf_nj    = n_surfaces > 0 ? (@eval collect($vl.surf_nj))    : Int[]
    sref = @eval $config.sref

    # Per-surface CL arrays [surface_idx][alpha_idx]
    per_surf_CL = [zeros(n_alpha) for _ in 1:n_surfaces]

    for (ai, alpha) in enumerate(alphas_deg)
        cb("running", 20 + round(Int, 70 * ai / n_alpha), "JAVL: alpha=$(alpha)°")

        # Create run case for this alpha
        rc = @eval begin
            rc = AVL.RunCase($vl.ncontrol)
            rc.icon[AVL.IVALFA] = AVL.ICALFA
            rc.conval[AVL.ICALFA] = deg2rad($alpha)
            rc
        end

        # Execute
        sol = @eval begin
            sol = AVL.AVLSolution($vl.nvor, $vl.ncontrol, $vl.nstrip)
            AVL.exec_case!(sol, $vl, $config, $aic, $gam_u0, $gam_u_d, $rc)
            sol
        end

        CL_arr[ai] = @eval $sol.cl
        CD_arr[ai] = @eval $sol.cd
        CY_arr[ai] = @eval $sol.cy
        Cl_arr[ai] = @eval $sol.cmx
        Cm_arr[ai] = @eval $sol.cmy
        Cn_arr[ai] = @eval $sol.cmz

        # Store raw derivatives (6-element vectors: u,v,w,p,q,r sensitivities)
        for name in deriv_names
            push!(derivs_raw[name], @eval collect(getfield($sol, Symbol($name))))
        end

        # Extract control derivatives: dCL/dδ, dCm/dδ etc. per control surface.
        # JAVL's control-normal perturbation is scaled by one degree, so these
        # arrays are per degree of control deflection.
        for name in ctrl_deriv_fields
            push!(ctrl_derivs_raw[name], @eval collect(getfield($sol, Symbol($name))))
        end

        # Aggregate per-surface CL from strip data
        # strip_cl[j] is section CL referenced to strip area; convert to Sref
        strip_cl_vec = @eval collect($sol.strip_cl)
        for is in 1:n_surfaces
            jf = surf_jfrst[is]
            nj = surf_nj[is]
            cl_surf = 0.0
            for j in jf:(jf + nj - 1)
                if j >= 1 && j <= length(strip_cl_vec)
                    wstrip = @eval $vl.strips[$j].wstrip
                    chord  = @eval $vl.strips[$j].chord
                    cl_surf += strip_cl_vec[j] * wstrip * chord / sref
                end
            end
            per_surf_CL[is][ai] = cl_surf
        end
    end

    # Clean up temp file
    rm(avl_tmpfile, force=true)

    cb("running", 95, "Packaging JAVL results...")

    # Extract nondimensional rate derivatives
    # Index mapping: 1=u, 2=v, 3=w, 4=p, 5=q, 6=r
    dynamic_derivs = Dict{String,Vector{Float64}}()
    if !isempty(derivs_raw["cmx_u"])
        dynamic_derivs["Cl_p_hat"] = [v[4] for v in derivs_raw["cmx_u"]]
        dynamic_derivs["Cm_q_hat"] = [v[5] for v in derivs_raw["cmy_u"]]
        dynamic_derivs["Cn_r_hat"] = [v[6] for v in derivs_raw["cmz_u"]]
        dynamic_derivs["CL_q_hat"] = [v[5] for v in derivs_raw["cl_u"]]
        dynamic_derivs["CY_p_hat"] = [v[4] for v in derivs_raw["cy_u"]]
        dynamic_derivs["CY_r_hat"] = [v[6] for v in derivs_raw["cy_u"]]
    end

    # Package control derivatives keyed by control surface name
    # Each derivative is a vector over alpha, per degree of control deflection.
    control_derivs = Dict{String,Any}()
    for (n, cname) in enumerate(control_names)
        control_derivs[cname] = Dict{String,Any}(
            "cl_d"  => [v[n] for v in ctrl_derivs_raw["cl_d"]],    # dCL/dδ [per deg]
            "cd_d"  => [v[n] for v in ctrl_derivs_raw["cd_d"]],    # dCD/dδ [per deg]
            "cy_d"  => [v[n] for v in ctrl_derivs_raw["cy_d"]],    # dCY/dδ [per deg]
            "cmx_d" => [v[n] for v in ctrl_derivs_raw["cmx_d"]],   # dCl/dδ [per deg]
            "cmy_d" => [v[n] for v in ctrl_derivs_raw["cmy_d"]],   # dCm/dδ [per deg]
            "cmz_d" => [v[n] for v in ctrl_derivs_raw["cmz_d"]]    # dCn/dδ [per deg]
        )
    end

    # Package per-surface forces keyed by AVL surface name, and resolve role.
    per_surface_data = Dict{String,Any}()
    surf_roles = Vector{Symbol}(undef, n_surfaces)
    surf_input_idx = zeros(Int, n_surfaces)   # back-reference into input.lifting_surfaces
    for (is, sname) in enumerate(surf_names)
        role = "unknown"
        iidx = 0
        for (k, surf) in enumerate(input.lifting_surfaces)
            if lowercase(surf.name) == lowercase(sname) ||
               lowercase(sname) == lowercase(surf.name) * " (ydup)"
                role = surf.role
                iidx = k
                break
            end
        end
        surf_input_idx[is] = iidx
        surf_roles[is] = iidx == 0 ? :wing_body : classify_role(role)
        per_surface_data[sname] = Dict(
            "role" => role,
            "CL"   => per_surf_CL[is]
        )
    end

    # ───── v3.0 split aggregation (JAVL, CL only — richest JAVL signal) ─────
    CL_wb_arr = zeros(n_alpha)
    for is in 1:n_surfaces
        if surf_roles[is] == :wing_body
            CL_wb_arr .+= per_surf_CL[is]
        end
    end
    # Fuselage CL unavailable from JAVL (no body solver wired) → already zero, ok.

    # Per-tail-surface entries — JAVL gives us CL only; other coefficients
    # are left nothing so merge/envelope can fall back to analytic or VLM data.
    tail_entries = Vector{Dict{String,Any}}()
    for is in 1:n_surfaces
        if surf_roles[is] != :wing_body && surf_input_idx[is] != 0
            surf = input.lifting_surfaces[surf_input_idx[is]]
            push!(tail_entries, Dict{String,Any}(
                "name" => surf.name,
                "role" => surf.role,
                "component" => String(classify_role(surf.role)),
                "arm_m" => tail_arm_vector(surf, input.general.CoG),
                "ac_xyz_m" => surface_aerodynamic_center(surf),
                "CL" => per_surf_CL[is]
                # CD, CY, Cl_at_AC, Cm_at_AC, Cn_at_AC intentionally omitted
            ))
        end
    end

    wing_body_block = Dict{String,Any}(
        "static" => Dict("CL" => CL_wb_arr),
        "alphas_deg" => alphas_deg,
        "betas_deg" => [0.0]
    )
    tail_block = Dict{String,Any}(
        "surfaces" => tail_entries,
        "alphas_deg" => alphas_deg,
        "betas_deg" => [0.0]
    )

    return Dict(
        "static" => Dict(
            "CL" => CL_arr, "CD" => CD_arr, "CY" => CY_arr,
            "Cl" => Cl_arr, "Cm" => Cm_arr, "Cn" => Cn_arr
        ),
        "alphas_deg" => alphas_deg,
        "betas_deg" => [0.0],
        "dynamic_derivatives" => dynamic_derivs,
        "control_derivatives" => control_derivs,
        "per_surface" => per_surface_data,
        # v3.0 additions — partial (CL only); consumed by merge.jl.
        "wing_body" => wing_body_block,
        "tail" => tail_block
    )
end

"""
Generate an AVL-format string from AircraftInput.
"""
function generate_avl_string(input::AircraftInput)
    io = IOBuffer()

    name = isempty(input.general.aircraft_name) ? "Aircraft" : input.general.aircraft_name
    println(io, name)
    println(io, "#Mach")
    println(io, " 0.0")
    println(io, "#IYsym   IZsym   Zsym")
    println(io, " 0       0       0.0")
    println(io, "#Sref    Cref    Bref")
    @printf(io, " %.4f  %.4f  %.4f\n", input.general.Sref, input.general.cref, input.general.bref)
    println(io, "#Xref    Yref    Zref")
    @printf(io, " %.4f  %.4f  %.4f\n", input.general.CoG...)
    println(io)

    # Surfaces
    for surf in input.lifting_surfaces
        wp = wing_planform(surf)
        println(io, "#" * "="^60)
        println(io, "SURFACE")
        println(io, surf.name)
        # Nchord  Cspace  Nspan  Sspace
        nc = 8
        ns = 16
        @printf(io, "%d  1.0  %d  1.0\n", nc, ns)

        if surf.symmetric && !surf.vertical
            println(io, "YDUPLICATE")
            println(io, "0.0")
        end

        panel_span = surf.vertical ? wp.span : wp.semi_span

        control_breaks = Float64[0.0, 1.0]
        for cs in surf.control_surfaces
            push!(control_breaks, clamp(cs.eta_start, 0.0, 1.0))
            push!(control_breaks, clamp(cs.eta_end, 0.0, 1.0))
        end
        section_etas = unique(sort(control_breaks))

        function emit_section(η::Float64)
            println(io, "#" * "-"^40)
            println(io, "SECTION")
            x = surf.root_LE[1] + η * panel_span * tan(wp.sweep_le)
            y = surf.vertical ? surf.root_LE[2] :
                surf.root_LE[2] + η * panel_span * cos(wp.dihedral)
            z = surf.vertical ? surf.root_LE[3] + η * panel_span :
                surf.root_LE[3] + η * panel_span * sin(wp.dihedral)
            chord = wp.root_chord + η * (wp.tip_chord - wp.root_chord)
            incidence = surf.incidence_DEG + η * surf.twist_tip_DEG

            @printf(io, "%.4f  %.4f  %.4f  %.4f  %.2f\n",
                x, y, z, chord, incidence)

            if surf.airfoil.type == "NACA"
                code = η < 0.5 ? surf.airfoil.root : surf.airfoil.tip
                if !isempty(code)
                    println(io, "NACA")
                    println(io, code)
                end
            end

            for cs in surf.control_surfaces
                η0 = min(cs.eta_start, cs.eta_end)
                η1 = max(cs.eta_start, cs.eta_end)
                if η >= η0 - 1e-6 && η <= η1 + 1e-6
                    hinge_x_over_chord = cs.chord_fraction > 0 ? (1.0 - cs.chord_fraction) : 0.75
                    # JAVL mirrors the hinge axis for YDUPLICATE sections. With
                    # that convention, elevators need -1 for symmetric pitch,
                    # while ailerons use +1 for antisymmetric roll.
                    sign_duplicate = lowercase(cs.type) == "elevator" ? -1.0 : 1.0
                    println(io, "CONTROL")
                    @printf(io, "%s  %.2f  %.2f  %.2f  %.2f  %.2f  %.1f\n",
                        cs.name, cs.gain, hinge_x_over_chord,
                        0.0, 0.0, 0.0, sign_duplicate)
                end
            end
        end

        # CONTROL sections must be present at the spanwise start/end of a
        # partial-span surface. Otherwise JAVL treats the aircraft as if that
        # aileron/elevator/rudder does not exist and downstream code falls back
        # to rough estimates.
        for η in section_etas
            emit_section(η)
        end

        println(io)
    end

    # Bodies — skipped for now.  The JAVL solver pipeline does not call
    # setup_body!(), so including BODY sections causes dimension mismatches
    # or singular AIC matrices.  Fuselage interference effects are minor
    # and can be added later once setup_body!() is integrated.
    # (See JAVL.jl/src/body.jl and driver.jl for reference.)

    return String(take!(io))
end
