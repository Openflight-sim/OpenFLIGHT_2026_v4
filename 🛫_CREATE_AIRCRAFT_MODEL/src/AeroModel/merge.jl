"""
    merge.jl — Merge results from multiple backends into unified schema v2.1

Strategy:
- Static coefficients: DATCOM provides the full Mach envelope; VLM/JAVL
  provide subsonic validation and higher-fidelity derivatives.
- Dynamic derivatives: VLM primary for subsonic; DATCOM for damping.
- Control effectiveness: VLM primary.
"""

"""
    merge_results(input::AircraftInput, backend_results::Dict) -> Dict

Produces the unified aerodynamic model in schema v2.1 format.
"""
function merge_results(input::AircraftInput, backend_results::Dict,
                       aircraft_json::AbstractDict=Dict{String,Any}())
    alphas = get_alpha_array(input.analysis)
    betas = get_beta_array(input.analysis)
    machs = input.analysis.mach_values
    configs = [c.id for c in input.configurations]
    if isempty(configs)
        configs = ["clean"]
    end

    model = Dict{String,Any}()

    # ---- Header ----
    model["schema_version"] = "3.0"
    model["model_name"] = isempty(input.general.aircraft_name) ? "Aircraft_Model" : input.general.aircraft_name

    model["meta"] = Dict{String,Any}(
        "aircraft_id" => uppercase(replace(model["model_name"], " " => "_")),
        "created_utc" => Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SSZ"),
        "author" => "AeroModel.jl",
        "notes" => "Generated from unified framework"
    )

    model["conventions"] = Dict(
        "angles" => "deg",
        "rates" => "rad_s",
        "forces" => "N",
        "moments" => "N_m",
        "coeff_axes" => "stability",
        "body_axes" => "x_forward_y_right_z_down",
        "coefficient_order" => ["CX", "CY", "CZ", "Cl", "Cm", "Cn"],
        "nondim_rates" => Dict(
            "p_hat" => "p*b/(2V)",
            "q_hat" => "q*c/(2V)",
            "r_hat" => "r*b/(2V)"
        )
    )

    # ---- Reference ----
    model["reference"] = Dict(
        "mass_kg" => input.general.mass_kg,
        "geometry" => Dict(
            "S_ref_m2" => input.general.Sref,
            "b_ref_m" => input.general.bref,
            "c_ref_m" => input.general.cref
        ),
        "cg_ref_m" => Dict(
            "x" => input.general.CoG[1],
            "y" => input.general.CoG[2],
            "z" => length(input.general.CoG) >= 3 ? input.general.CoG[3] : 0.0
        ),
        "inertia" => Dict(
            "principal_moments_kgm2" => input.general.inertia.principal_moments_kgm2,
            "principal_axes_rotation_deg" => input.general.inertia.principal_axes_rotation_deg
        )
    )

    # ---- Limits ----
    controls_limits = Dict{String,Any}()
    for surf in input.lifting_surfaces
        for cs in surf.control_surfaces
            abbrev = control_abbreviation(cs.type)
            controls_limits[abbrev] = [cs.deflection_range_DEG[1], cs.deflection_range_DEG[2]]
        end
    end
    model["limits"] = Dict(
        "mach" => [minimum(machs), maximum(machs)],
        "alpha_deg" => [input.analysis.alpha_range_DEG[1], input.analysis.alpha_range_DEG[2]],
        "beta_deg" => [input.analysis.beta_range_DEG[1], input.analysis.beta_range_DEG[2]],
        "controls_deg" => controls_limits
    )

    # ---- Configurations ----
    model["configurations"] = [Dict("id" => c.id, "flap_deg" => c.flap_deg, "gear" => c.gear)
                               for c in input.configurations]

    # ---- Aerodynamics ----
    aero = Dict{String,Any}()
    aero["interpolation"] = Dict("method" => "multilinear", "out_of_range" => "clip_and_warn")
    coefficient_tuning = build_coefficient_tuning_block()
    if !isempty(coefficient_tuning)
        aero["coefficient_tuning"] = coefficient_tuning
    end

    # Static coefficients (whole-aircraft — kept for legacy consumers / plot overlays)
    aero["static_coefficients"] = build_static_coefficients(
        input, backend_results, configs, machs, alphas, betas)

    # v3.0 split: wing_body + tail + interference.
    # Sourced from the envelope-extended VLM result (which is always produced).
    aero["wing_body"]    = build_wing_body_block(input, backend_results, configs, machs, alphas, betas)
    aero["tail"]         = build_tail_block(input, backend_results, configs, machs, alphas, betas)
    aero["interference"] = build_interference_block(input, backend_results, configs, machs, alphas, betas)

    # Dynamic derivatives
    aero["dynamic_derivatives"] = build_dynamic_derivatives(
        input, backend_results, configs, machs, alphas)

    # Control effectiveness (with post-stall degradation)
    aero["control_effectiveness"] = build_control_effectiveness(
        input, backend_results, configs, machs, alphas, aircraft_json)

    # Control drag increments (placeholder)
    aero["control_drag_increments"] = build_control_drag_increments(
        input, configs, machs, alphas)

    # Local flow (downwash, sidewash, tail dynamic pressure ratio)
    aero["local_flow"] = build_local_flow(input, configs, alphas, betas)

    # Post-stall model
    aero["poststall"] = build_poststall(input, configs)

    model["aerodynamics"] = aero

    # ---- Per-surface data (passthrough from VLM, uses VLM-range axes) ----
    vlm_for_psd = get(backend_results, "vlm", nothing)
    psd_alphas = !isnothing(vlm_for_psd) ? Float64.(get(vlm_for_psd, "vlm_alphas_deg", alphas)) : alphas
    psd_betas = !isnothing(vlm_for_psd) ? Float64.(get(vlm_for_psd, "vlm_betas_deg", betas)) : betas
    model["per_surface_data"] = build_per_surface_data(input, backend_results, psd_alphas, psd_betas)

    # ---- Tail aerodynamics (isolated tail surface characteristics) ----
    model["tail_aerodynamics"] = build_tail_aerodynamics(input, backend_results, psd_alphas, psd_betas)

    # ---- Runtime-specific reduced-order data ----
    model["runtime_model"] = build_runtime_model(
        input, backend_results, aero, model["tail_aerodynamics"], alphas, betas, machs, configs)

    # ---- Propulsion ----
    model["propulsion"] = build_propulsion(input, machs)

    # ---- Actuators ----
    model["actuators"] = build_actuators(input)

    # ---- Visual geometry for 3D rendering in OpenFlight ----
    model["visual_geometry"] = build_visual_geometry(input)

    # Do not move the exported CG after the aerodynamic tables have been
    # generated. A post-export CG shift makes the reference block disagree
    # with runtime scalars and component reference points, which can produce
    # misleading stability checks and simulator behavior. CG corrections must
    # happen before analysis and trigger a full regeneration pass.
    pitch_rebalance = nothing

    # ---- VLM mesh for 3D visualization ----
    vlm = get(backend_results, "vlm", nothing)
    if !isnothing(vlm)
        vlm_mesh = get(vlm, "vlm_mesh", nothing)
        if !isnothing(vlm_mesh) && !isempty(vlm_mesh)
            model["vlm_mesh"] = vlm_mesh
        end
    end

    # ---- Failures ----
    model["failures"] = Dict(
        "allow_engine_out" => length(input.engines) > 1,
        "default_failed_engines" => Any[],
        "failure_ramp_time_s" => 0.5
    )

    # ---- Quality ----
    backends_used = collect(keys(filter(kv -> !isnothing(kv.second), backend_results)))
    model["quality"] = Dict(
        "missing_term_policy" => "zero",
        "provenance" => Dict(
            "linear_core" => "vlm" in backends_used ? "VortexLattice.jl" : ("javl" in backends_used ? "JAVL" : "none"),
            "nonlinear_surfaces" => "datcom" in backends_used ? "JDATCOM" : "assumed",
            "propulsion" => "input_definition"
        ),
        "confidence" => Dict(
            "linear_core" => any(b -> b in ["vlm", "javl"], backends_used) ? "high" : "low",
            "nonlinear" => "datcom" in backends_used ? "medium" : "low",
            "poststall" => "low"
        )
    )
    if !isnothing(pitch_rebalance)
        model["quality"]["auto_rebalance"] = Dict(
            "type" => "pitch_cg_shift",
            "from_x_m" => pitch_rebalance["from_x_m"],
            "to_x_m" => pitch_rebalance["to_x_m"],
            "static_margin_before_mac" => pitch_rebalance["static_margin_before_mac"],
            "static_margin_target_mac" => pitch_rebalance["static_margin_target_mac"],
            "alpha_target_deg" => pitch_rebalance["alpha_target_deg"]
        )
    end

    return model
end

# ---- Helper: control surface abbreviation ----
function control_abbreviation(cs_type::String)
    abbrevs = Dict("elevator" => "de", "aileron" => "da", "rudder" => "dr",
        "flap" => "df", "spoiler" => "ds")
    get(abbrevs, cs_type, "d" * cs_type[1:1])
end

function _first_surface_by_role(input::AircraftInput, role::String)
    for surf in input.lifting_surfaces
        if surf.role == role
            return surf
        end
    end
    return nothing
end

function _surface_aerodynamic_center_x(surface)
    pf = wing_planform(surface)
    y_mac = pf.span / 6 * (1 + 2 * surface.TR) / (1 + surface.TR)
    x_mac_le = surface.root_LE[1] + y_mac * tan(pf.sweep_le)
    return x_mac_le + 0.25 * pf.mac
end

function _max_control_deflection_abs(input::AircraftInput, control_type::String, default_value::Float64)
    max_abs = 0.0
    for surf in input.lifting_surfaces
        for cs in surf.control_surfaces
            if lowercase(string(cs.type)) == lowercase(control_type)
                max_abs = max(max_abs, maximum(abs, Float64.(cs.deflection_range_DEG)))
            end
        end
    end
    return max_abs > 0.0 ? max_abs : default_value
end

function _isa_density_kg_m3(altitude_m::Float64)
    h = clamp(altitude_m, -500.0, 11000.0)
    T0 = 288.15
    p0 = 101325.0
    L = 0.0065
    R = 287.05
    g = 9.80665
    T = T0 - L * h
    p = p0 * (T / T0)^(g / (R * L))
    return p / (R * T)
end

function _maybe_rebalance_export_cg_for_pitch!(model::Dict, input::AircraftInput)
    wing = _first_surface_by_role(input, "wing")
    htail = _first_surface_by_role(input, "horizontal_stabilizer")
    if isnothing(wing) || isnothing(htail)
        return nothing
    end

    wing_ac_x = _surface_aerodynamic_center_x(wing)
    htail_ac_x = _surface_aerodynamic_center_x(htail)
    if htail_ac_x <= wing_ac_x + 0.35 * input.general.cref
        return nothing
    end

    ref = get(model, "reference", Dict{String,Any}())
    cg = get(ref, "cg_ref_m", Dict{String,Any}())
    geom = get(ref, "geometry", Dict{String,Any}())
    runtime_model = get(model, "runtime_model", Dict{String,Any}())

    x_ref = Float64(get(cg, "x", input.general.CoG[1]))
    c_ref = max(Float64(get(geom, "c_ref_m", input.general.cref)), 0.01)
    cl_alpha = Float64(get(runtime_model, "CL_alpha", 0.0))
    cm_alpha = Float64(get(runtime_model, "Cm_alpha", 0.0))
    cl0 = Float64(get(runtime_model, "CL_0", 0.0))
    cm0 = Float64(get(runtime_model, "Cm0", 0.0))
    cmde = Float64(get(runtime_model, "Cm_de_per_deg", 0.0))

    abs(cl_alpha) > 1e-6 || return nothing

    static_margin = -cm_alpha / cl_alpha
    alpha_target_deg = 4.0
    alpha_target_rad = deg2rad(alpha_target_deg)
    cl_target = cl0 + cl_alpha * alpha_target_rad
    cm_target = cm0 + cm_alpha * alpha_target_rad
    max_elevator_deg = _max_control_deflection_abs(input, "elevator", 25.0)
    trim_fraction = cmde < -1e-5 ? abs(-cm_target / cmde) / max(max_elevator_deg, 1.0) : 0.0

    needs_rebalance =
        static_margin > 0.28 ||
        (static_margin > 0.18 && cm0 < -0.01) ||
        trim_fraction > 0.60
    needs_rebalance || return nothing

    target_static_margin = 0.14
    min_static_margin = 0.08
    x_np = x_ref + static_margin * c_ref
    x_from_static_margin = x_np - target_static_margin * c_ref
    x_from_trim = x_ref
    if cl_target > 0.12
        desired_cm_at_target = 0.02
        x_from_trim = x_ref + (desired_cm_at_target - cm_target) * c_ref / cl_target
    end

    x_min = x_ref - 0.10 * c_ref
    x_max = min(x_np - min_static_margin * c_ref, x_ref + 0.65 * c_ref)
    if !isfinite(x_max) || x_max <= x_min
        return nothing
    end

    x_target = clamp(max(x_from_static_margin, x_from_trim), x_min, x_max)
    if !isfinite(x_target) || x_target <= x_ref + 0.05
        return nothing
    end

    x_target_rounded = round(x_target, digits=3)
    cg["x"] = x_target_rounded

    visual_geometry = get(model, "visual_geometry", nothing)
    if visual_geometry isa AbstractDict
        visual_cg = get(visual_geometry, "cg_position_m", nothing)
        if visual_cg isa AbstractDict
            visual_cg["x"] = x_target_rounded
        end
    end

    meta = get(model, "meta", Dict{String,Any}())
    existing_notes = String(get(meta, "notes", "Generated from unified framework"))
    meta["notes"] = existing_notes * "; current export CG auto-shifted aft for pitch authority"
    meta["pitch_cg_rebalance"] = Dict(
        "from_x_m" => round(x_ref, digits=3),
        "to_x_m" => x_target_rounded,
        "static_margin_before_mac" => round(static_margin, digits=3),
        "static_margin_target_mac" => target_static_margin,
        "alpha_target_deg" => alpha_target_deg,
        "trim_fraction_before" => round(trim_fraction, digits=3)
    )

    return Dict(
        "from_x_m" => round(x_ref, digits=3),
        "to_x_m" => x_target_rounded,
        "static_margin_before_mac" => round(static_margin, digits=3),
        "static_margin_target_mac" => target_static_margin,
        "alpha_target_deg" => alpha_target_deg
    )
end

function build_coefficient_tuning_block()
    tuning = Dict{String,Any}(
        "global" => 1.0,
        "groups" => Dict(
            "whole_aircraft" => 1.0,
            "wing_body" => 1.0,
            "tail" => 1.0,
            "interference" => 1.0,
            "dynamic" => 1.0,
            "control" => 1.0,
            # Propulsion group multiplies every thrust-related scalar
            # (maximum_thrust_at_sea_level, thrust_installation_angle_DEG,
            # engine_spool_up/down_speed).  Use this to correct a
            # rule-of-thumb HP→N estimate that came out too high or low
            # without having to touch individual coefficients.
            "propulsion" => 1.0
        ),
        "families" => Dict(
            "CL" => 1.0,
            "CD" => 1.0,
            "CY" => 1.0,
            "CS" => 1.0,
            "Cl" => 1.0,
            "Cm" => 1.0,
            "Cn" => 1.0
        ),
        "coefficients" => Dict(
            "CL" => 1.0,
            "CD" => 1.0,
            "CY" => 1.0,
            "CS" => 1.0,
            "Cl" => 1.0,
            "Cm" => 1.0,
            "Cn" => 1.0,
            "CL_alpha" => 1.0,
            "CL_q_hat" => 1.0,
            "CL_delta_e" => 1.0,
            "CY_beta" => 1.0,
            "CY_delta_r" => 1.0,
            "Cl_beta" => 1.0,
            "Cl_p" => 1.0,
            "Cl_r" => 1.0,
            "Cl_delta_a" => 1.0,
            "Cl_delta_r" => 1.0,
            "Cm_alpha" => 1.0,
            "Cm_q" => 1.0,
            "Cm_delta_e" => 1.0,
            "Cm_alpha_extra" => 1.0,
            "Cn_beta" => 1.0,
            "Cn_p" => 1.0,
            "Cn_r" => 1.0,
            "Cn_delta_a" => 1.0,
            "Cn_delta_r" => 1.0,
            "Cl_p_hat" => 1.0,
            "Cm_q_hat" => 1.0,
            "Cn_r_hat" => 1.0,
            "Cd_da_per_deg" => 1.0,
            "Cl_da_per_deg" => 1.0,
            "Cm_de_per_deg" => 1.0,
            "Cn_da_per_deg" => 1.0,
            "Cn_dr_per_deg" => 1.0,
            "tail_CL" => 1.0,
            "tail_CS" => 1.0,
            "tail_CL_q" => 1.0,
            "tail_CS_r" => 1.0,
            "scale_tail_forces" => 1.0,
            # --- Propulsion coefficients ---
            # Scales the sea-level static thrust used by the runtime
            # propulsion model (see 0.2.3_compute_propulsive_forces.jl).
            # For propeller aircraft whose rated power is given in
            # horsepower, the model creator converts HP → N using a
            # static-thrust rule of thumb (~12 N/HP). This factor
            # compensates when the actual prop produces more or less
            # static thrust than the rule of thumb predicts.
            "maximum_thrust_at_sea_level" => 1.0,
            # Fine-trims the installed thrust-line angle independently
            # of the raw nacelle orientation — useful when AVL / DATCOM
            # reveal a different trim needs than the nominal mount.
            "thrust_installation_angle_DEG" => 1.0,
            # Engine dynamics (bandwidth of the first-order thrust lag).
            "engine_spool_up_speed" => 1.0,
            "engine_spool_down_speed" => 1.0
        ),
        "constant_offsets" => Dict(
            "CL_0" => 0.0,
            "CD0" => 0.0,
            "Cm0" => 0.0,
            "Cm_trim" => 0.0,
            "CL_max" => 0.0,
            "Oswald_factor" => 0.0,
            "alpha_stall_positive" => 0.0,
            "alpha_stall_negative" => 0.0,
            "beta_stall" => 0.0,
            "alpha_stall_knee_deg" => 0.0,
            "beta_stall_knee_deg" => 0.0,
            "dynamic_stall_alpha_on_deg" => 0.0,
            "dynamic_stall_alpha_off_deg" => 0.0,
            "dynamic_stall_qhat_to_alpha_deg" => 0.0,
            "dynamic_stall_tau_alpha_s" => 0.0,
            "dynamic_stall_tau_sigma_rise_s" => 0.0,
            "dynamic_stall_tau_sigma_fall_s" => 0.0,
            "poststall_cl_scale" => 0.0,
            "poststall_cd90" => 0.0,
            "poststall_cd_min" => 0.0,
            "poststall_sideforce_scale" => 0.0,
            "tail_CD0" => 0.0,
            "tail_k_induced" => 0.0,
            "tail_k_side" => 0.0
        )
    )

    prune_neutral_tuning_block!(tuning)
    return tuning
end

function prune_neutral_tuning_block!(tuning::Dict{String,Any})
    for (section_name, neutral_value) in (
        ("groups", 1.0),
        ("families", 1.0),
        ("coefficients", 1.0),
        ("constant_offsets", 0.0),
    )
        section = get(tuning, section_name, nothing)
        if !(section isa AbstractDict)
            continue
        end

        keys_to_delete = String[]
        for (raw_key, raw_value) in section
            if raw_value isa Number && isapprox(Float64(raw_value), neutral_value; atol=1e-12)
                push!(keys_to_delete, string(raw_key))
            end
        end

        for key in keys_to_delete
            delete!(section, key)
        end

        isempty(section) && delete!(tuning, section_name)
    end

    if haskey(tuning, "global")
        global_value = tuning["global"]
        if global_value isa Number && isapprox(Float64(global_value), 1.0; atol=1e-12)
            delete!(tuning, "global")
        end
    end

    return tuning
end

# ---- Build static coefficient tables ----
function build_static_coefficients(input, results, configs, machs, alphas, betas)
    sc = Dict{String,Any}()
    sc["axis_order"] = ["config", "mach", "alpha_deg", "beta_deg"]
    sc["axes"] = Dict(
        "config" => configs,
        "mach" => machs,
        "alpha_deg" => alphas,
        "beta_deg" => betas
    )

    coeff_names = ["CL", "CD", "CY", "Cl", "Cm", "Cn"]

    for cname in coeff_names
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (mi, mach) in enumerate(machs)
                mach_data = []
                for (ai, alpha) in enumerate(alphas)
                    beta_data = Float64[]
                    for (bi, beta) in enumerate(betas)
                        val = get_merged_coefficient(cname, mi, ai, bi, results, length(machs))
                        push!(beta_data, round(val, digits=4))
                    end
                    push!(mach_data, beta_data)
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        sc[cname] = Dict("values" => values)
    end

    return sc
end

"""
Get a merged coefficient value from available backends.
Priority: VLM first (includes full-envelope physics for ±180°),
then DATCOM (semi-empirical, no beta dependence), then JAVL.
"""
function get_merged_coefficient(name, mi, ai, bi, results, n_mach)
    val = 0.0

    # Try VLM first (has full-envelope physics + beta dependence)
    vlm = get(results, "vlm", nothing)
    if !isnothing(vlm)
        static = get(vlm, "static", Dict())
        arr = get(static, name, nothing)
        if !isnothing(arr)
            if ndims(arr) == 2  # [alpha, beta]
                if ai <= size(arr, 1) && bi <= size(arr, 2)
                    val = arr[ai, bi]
                end
            elseif ndims(arr) == 1
                if ai <= length(arr)
                    val = arr[ai]
                end
            end
            return val
        end
    end

    # Fall back to DATCOM (has Mach coverage but no beta)
    datcom = get(results, "datcom", nothing)
    if !isnothing(datcom)
        static = get(datcom, "static", Dict())
        arr = get(static, name, nothing)
        if !isnothing(arr)
            if ndims(arr) == 2  # [mach, alpha]
                if mi <= size(arr, 1) && ai <= size(arr, 2)
                    val = arr[mi, ai]
                end
            elseif ndims(arr) == 1  # [alpha] only
                if ai <= length(arr)
                    val = arr[ai]
                end
            end
            return val
        end
    end

    # Fall back to JAVL
    javl = get(results, "javl", nothing)
    if !isnothing(javl)
        static = get(javl, "static", Dict())
        arr = get(static, name, nothing)
        if !isnothing(arr) && ndims(arr) == 1 && ai <= length(arr)
            val = arr[ai]
        end
    end

    return val
end

# =================================================================
# Schema v3.0 — wing_body / tail / interference block builders
# =================================================================

"""
Pick the VLM → DATCOM → JAVL priority block that supplies split data.
The envelope-extended VLM result is always the primary source because
full_envelope.jl always attaches `wing_body`, `tail`, `interference`.
"""
function pick_split_source(results::Dict)
    for key in ("vlm", "datcom", "javl")
        src = get(results, key, nothing)
        if !isnothing(src) && haskey(src, "wing_body") && haskey(src, "tail")
            return (src, key)
        end
    end
    return (nothing, "none")
end

"""
Emit the same (config, mach, alpha, beta) nested-array shape used by
`build_static_coefficients`, reading values from a 2-D matrix of size
(n_alpha, n_beta). Same α/β grid assumption as the whole-aircraft block.
"""
function _expand_over_config_mach(matrix::AbstractMatrix, configs, machs, alphas, betas)
    values = Dict{String,Any}()
    na, nb = size(matrix)
    for cfg in configs
        cfg_data = []
        for _ in machs
            mach_data = []
            for ai in 1:length(alphas)
                row = Float64[]
                for bi in 1:length(betas)
                    if ai <= na && bi <= nb
                        push!(row, round(matrix[ai, bi], digits=4))
                    else
                        push!(row, 0.0)
                    end
                end
                push!(mach_data, row)
            end
            push!(cfg_data, mach_data)
        end
        values[cfg] = cfg_data
    end
    return values
end

function build_wing_body_block(input, results, configs, machs, alphas, betas)
    wb = Dict{String,Any}()
    wb["axis_order"] = ["config", "mach", "alpha_deg", "beta_deg"]
    wb["axes"] = Dict("config" => configs, "mach" => machs,
                      "alpha_deg" => alphas, "beta_deg" => betas)

    src, _ = pick_split_source(results)
    if isnothing(src) || !haskey(src, "wing_body")
        return wb    # axis-only skeleton when nothing was produced
    end

    wb_src = src["wing_body"]
    if haskey(wb_src, "reference_point_m")
        wb["reference_point_m"] = wb_src["reference_point_m"]
    end
    static = get(wb_src, "static", Dict())
    for cname in ("CL", "CD", "CY", "Cl", "Cm", "Cn")
        if haskey(static, cname)
            mat = static[cname]
            if mat isa AbstractMatrix
                wb[cname] = Dict("values" => _expand_over_config_mach(mat, configs, machs, alphas, betas))
            elseif mat isa AbstractVector
                # 1-D (α-only): broadcast across β.
                n_alpha, n_beta = length(alphas), length(betas)
                expanded = zeros(n_alpha, n_beta)
                for ai in 1:min(length(mat), n_alpha), bi in 1:n_beta
                    expanded[ai, bi] = mat[ai]
                end
                wb[cname] = Dict("values" => _expand_over_config_mach(expanded, configs, machs, alphas, betas))
            end
        end
    end
    return wb
end

function build_tail_block(input, results, configs, machs, alphas, betas)
    tail = Dict{String,Any}()
    tail["axis_order_per_surface"] = ["config", "mach", "alpha_h_deg", "beta_v_deg"]
    tail["axes"] = Dict("config" => configs, "mach" => machs,
                        "alpha_h_deg" => alphas, "beta_v_deg" => betas)

    src, _ = pick_split_source(results)
    tail["surfaces"] = Vector{Dict{String,Any}}()
    if isnothing(src) || !haskey(src, "tail")
        return tail
    end

    for entry in get(src["tail"], "surfaces", [])
        surf_out = Dict{String,Any}(
            "name" => get(entry, "name", "tail"),
            "role" => get(entry, "role", "tail"),
            "component" => get(entry, "component", "tail_h"),
            "arm_m" => get(entry, "arm_m", [0.0, 0.0, 0.0]),
            "ac_xyz_m" => get(entry, "ac_xyz_m", [0.0, 0.0, 0.0])
        )
        for cname in ("CL", "CD", "CY", "Cl_at_AC", "Cm_at_AC", "Cn_at_AC")
            if haskey(entry, cname) && entry[cname] isa AbstractMatrix
                surf_out[cname] = Dict("values" => _expand_over_config_mach(entry[cname], configs, machs, alphas, betas))
            end
        end
        push!(tail["surfaces"], surf_out)
    end
    return tail
end

function build_interference_block(input, results, configs, machs, alphas, betas)
    ifb = Dict{String,Any}()

    # Interference tables (downwash ε(α), sidewash σ(β), η_h(α), η_v(β)) are
    # smooth tanh/Gaussian functions, so we store them on the coarse α/β grid
    # instead of the fine grid the static coefficients need.  Source values
    # (computed on the fine grid by full_envelope.jl) are linear-interpolated
    # onto the coarse grid at storage time.
    coarse_alphas = get_coarse_alpha_array(input.analysis)
    coarse_betas  = get_coarse_beta_array(input.analysis)

    ifb["axis_order_alpha"] = ["config", "mach", "alpha_deg"]
    ifb["axis_order_beta"]  = ["config", "mach", "beta_deg"]
    ifb["axes"] = Dict("config" => configs, "mach" => machs,
                       "alpha_deg" => coarse_alphas, "beta_deg" => coarse_betas)

    src, _ = pick_split_source(results)
    if isnothing(src) || !haskey(src, "interference")
        ifb["source"] = "unavailable"
        return ifb
    end

    ifd = src["interference"]
    ifb["source"] = get(ifd, "source", "unknown")

    # α-dimension tables: interpolate from source's native α-grid onto coarse_alphas.
    for key in ("downwash_deg", "eta_h")
        if haskey(ifd, key)
            src_tbl = ifd[key]
            src_alphas = collect(Float64, get(src_tbl, "alpha_deg", alphas))
            src_values = collect(Float64, get(src_tbl, "values", Float64[]))
            values = Dict{String,Any}()
            for cfg in configs
                cfg_data = []
                for _ in machs
                    mach_data = Float64[round(interp1_linear(src_alphas, src_values, Float64(α)),
                                              digits=5) for α in coarse_alphas]
                    push!(cfg_data, mach_data)
                end
                values[cfg] = cfg_data
            end
            ifb[key] = Dict("values" => values)
        end
    end

    # β-dimension tables: interpolate from source's native β-grid onto coarse_betas.
    for key in ("sidewash_deg", "eta_v")
        if haskey(ifd, key)
            src_tbl = ifd[key]
            src_betas = collect(Float64, get(src_tbl, "beta_deg", betas))
            src_values = collect(Float64, get(src_tbl, "values", Float64[]))
            values = Dict{String,Any}()
            for cfg in configs
                cfg_data = []
                for _ in machs
                    mach_data = Float64[round(interp1_linear(src_betas, src_values, Float64(β)),
                                              digits=5) for β in coarse_betas]
                    push!(cfg_data, mach_data)
                end
                values[cfg] = cfg_data
            end
            ifb[key] = Dict("values" => values)
        end
    end

    return ifb
end

# ---- Build dynamic derivative tables ----
#
# Storage strategy: all dynamic derivatives share a single coarse α-grid
# (10° step within ±30°, 15° outside).  Their α-dependence is smooth enough
# (tanh/cos α damping envelopes) that the fine 2° grid used by the static
# coefficients is wasteful — a 10° step captures the stall transitions and
# the reversed-flow transition without loss of flight-sim fidelity.  The
# Cl_p autorotation lobe, centred on ±(α_stall + 5°) with ~6° Gaussian
# width, is also handled well: its peak lands on a sample point (α_stall
# rounds near 15°, sample at 20° catches the peak), and linear interp
# across the lobe reproduces the positive-value window that matters for
# spin-departure dynamics.
#
# Net effect: ~35 % fewer points per derivative, ~35 % faster simulator
# interpolation on the dynamic-derivative axis, no schema change — the
# group-level `axis_order`/`axes` contract is preserved for downstream
# consumers (JS results viewer, YAML exporter, validation).
function build_dynamic_derivatives(input, results, configs, machs, alphas)
    dd = Dict{String,Any}()

    coarse_alphas = get_coarse_alpha_array(input.analysis)
    dd["axis_order"] = ["config", "mach", "alpha_deg"]
    dd["axes"] = Dict("config" => configs, "mach" => machs,
                      "alpha_deg" => coarse_alphas)

    deriv_names = ["Cl_p_hat", "Cm_q_hat", "Cn_r_hat", "CL_q_hat", "CY_p_hat", "CY_r_hat",
                   "Cm_alpha_dot_hat", "Cn_beta_dot_hat"]

    for dname in deriv_names
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (mi, _) in enumerate(machs)
                # Sample on the backend-native fine grid first (get_merged_derivative's
                # DATCOM branch indexes by `ai`, which must align with `alphas`).
                fine_data = Float64[]
                for (ai, α_deg) in enumerate(alphas)
                    v = get_merged_derivative(dname, mi, ai, α_deg, results, length(machs))
                    push!(fine_data, v)
                end
                mach_data = Float64[round(interp1_linear(alphas, fine_data, Float64(α)),
                                          digits=4) for α in coarse_alphas]
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        dd[dname] = Dict("values" => values)
    end

    # ---- Cross-damping derivatives (geometry-estimated from CL(α)) ----
    # These inherit the CL(α) stall shape.
    #   Cn_p_hat ≈ −CL/8  (yaw from roll rate: induced drag asymmetry)
    #   Cl_r_hat ≈  CL/4  (roll from yaw rate: velocity differential across span)
    vlm = get(results, "vlm", nothing)
    CL_at_fine_alphas = nothing       # CL(α) at β=0, sampled on `alphas`
    if !isnothing(vlm)
        st = get(vlm, "static", nothing)
        if !isnothing(st)
            CL_table = get(st, "CL", nothing)
            vlm_betas = get(vlm, "betas_deg", Float64[0.0])
            beta0_idx = argmin(abs.(vlm_betas))
            if !isnothing(CL_table) && beta0_idx <= size(CL_table, 2) &&
               size(CL_table, 1) == length(alphas)
                CL_at_fine_alphas = Float64[CL_table[i, beta0_idx]
                                             for i in 1:size(CL_table, 1)]
            end
        end
    end

    for (cross_name, cl_scale) in [("Cn_p_hat", -1.0/8.0), ("Cl_r_hat", 1.0/4.0)]
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for _ in machs
                mach_data = Float64[]
                for α_deg in coarse_alphas
                    CL_at_α = isnothing(CL_at_fine_alphas) ? 0.0 :
                              interp1_linear(alphas, CL_at_fine_alphas, Float64(α_deg))
                    push!(mach_data, round(CL_at_α * cl_scale, digits=4))
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        dd[cross_name] = Dict("values" => values)
    end

    return dd
end

"""
    interp1_linear(xs, ys, x) -> Float64

Simple 1-D linear interpolation.  Returns ys[1] or ys[end] for
out-of-range queries (clamp extrapolation).
"""
function interp1_linear(xs::AbstractVector, ys::AbstractVector, x::Float64)
    n = length(xs)
    n == 0 && return 0.0
    n == 1 && return Float64(ys[1])
    x <= xs[1] && return Float64(ys[1])
    x >= xs[n] && return Float64(ys[n])
    for i in 1:n-1
        if xs[i] <= x <= xs[i+1]
            t = (x - xs[i]) / (xs[i+1] - xs[i])
            return Float64(ys[i] + t * (ys[i+1] - ys[i]))
        end
    end
    return Float64(ys[argmin(abs.(xs .- x))])
end

function get_merged_derivative(name, mi, ai, alpha_deg, results, n_mach)
    # Priority: DATCOM → JAVL → VLM
    #
    # VLM stability_derivatives() is a total-aircraft computation that includes
    # contributions from crude fuselage octagon panels. These flat panels produce
    # unrealistic circulation-based forces/moments in the potential-flow solver,
    # corrupting ALL dynamic derivatives (wrong signs and inflated magnitudes).
    # DATCOM semi-empirical formulas are validated and geometry-based, so they
    # are the preferred source.

    # Try DATCOM first (validated semi-empirical, uses same alpha grid as merge)
    datcom = get(results, "datcom", nothing)
    if !isnothing(datcom)
        dd = get(datcom, "dynamic_derivatives", Dict())
        arr = get(dd, name, nothing)
        if !isnothing(arr)
            if ndims(arr) == 2 && mi <= size(arr, 1) && ai <= size(arr, 2)
                return arr[mi, ai]
            elseif ndims(arr) == 1 && ai <= length(arr)
                return arr[ai]
            end
        end
    end

    # Try JAVL (alpha-based lookup)
    javl = get(results, "javl", nothing)
    if !isnothing(javl)
        dd = get(javl, "dynamic_derivatives", Dict())
        arr = get(dd, name, nothing)
        if !isnothing(arr) && arr isa Vector && !isempty(arr)
            javl_alphas = get(javl, "alphas_deg", nothing)
            if !isnothing(javl_alphas) && length(javl_alphas) == length(arr)
                if alpha_deg >= javl_alphas[1] && alpha_deg <= javl_alphas[end]
                    return interp1_linear(collect(Float64, javl_alphas), arr, Float64(alpha_deg))
                end
            elseif ai <= length(arr)
                return arr[ai]
            end
        end
    end

    # Fallback: VLM (only used if DATCOM and JAVL both unavailable)
    vlm = get(results, "vlm", nothing)
    if !isnothing(vlm)
        dd = get(vlm, "dynamic_derivatives", Dict())
        arr = get(dd, name, nothing)
        if !isnothing(arr) && arr isa Vector && !isempty(arr)
            vlm_alphas = get(vlm, "vlm_alphas_deg", nothing)
            if isnothing(vlm_alphas)
                vlm_alphas = get(vlm, "alphas_deg", nothing)
            end
            if !isnothing(vlm_alphas) && length(vlm_alphas) == length(arr)
                if alpha_deg >= vlm_alphas[1] && alpha_deg <= vlm_alphas[end]
                    return interp1_linear(collect(Float64, vlm_alphas), arr, Float64(alpha_deg))
                end
            elseif ai <= length(arr)
                return arr[ai]
            end
        end
    end

    return 0.0
end

# ---- Build control effectiveness tables ----
function build_control_effectiveness(input, results, configs, machs, alphas,
                                     aircraft_json::AbstractDict=Dict{String,Any}())
    ce = Dict{String,Any}()
    ce["axis_order"] = ["config", "mach", "alpha_deg"]
    ce["axes"] = Dict("config" => configs, "mach" => machs, "alpha_deg" => alphas)

    # Compute stall parameters from geometry (DATCOM methods)
    mach_ref = isempty(machs) ? 0.2 : machs[1]
    stall_data = compute_aircraft_stall(input; mach=mach_ref,
                                        altitude_m=input.analysis.altitude_m)
    α_stall_pos = Float64(stall_data["alpha_stall_positive"])
    α_stall_neg = Float64(stall_data["alpha_stall_negative"])
    aileron_surf, aileron_cs = find_control_surface(input, "aileron"; role="wing")

    # Collect all control surfaces — primary derivatives
    for surf in input.lifting_surfaces
        for cs in surf.control_surfaces
            key = get_control_derivative_name(cs.type)
            if !haskey(ce, key)
                values = Dict{String,Any}()
                for cfg in configs
                    cfg_data = []
                    for (mi, _) in enumerate(machs)
                        mach_data = Float64[]
                        for (ai, α_deg) in enumerate(alphas)
                            val = get_control_deriv_value(input, surf, cs, ai, results)
                            val *= control_stall_factor(α_deg, α_stall_pos, α_stall_neg)
                            push!(mach_data, round(val, digits=5))
                        end
                        push!(cfg_data, mach_data)
                    end
                    values[cfg] = cfg_data
                end
                ce[key] = Dict("values" => values)
            end
        end
    end

    if !haskey(ce, "Cl_da_per_deg") && !isnothing(aileron_surf) && !isnothing(aileron_cs)
        raw_clda = get_control_deriv_value(input, aileron_surf, aileron_cs,
                                           argmin(abs.(alphas)), results)
        Cl_da_ref = abs(raw_clda)

        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (_, _) in enumerate(machs)
                mach_data = Float64[]
                for α_deg in alphas
                    val = Cl_da_ref * control_stall_factor(α_deg, α_stall_pos, α_stall_neg)
                    push!(mach_data, round(val, digits=5))
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        ce["Cl_da_per_deg"] = Dict("values" => values)
    end

    # ---- Cross-coupling control derivatives (geometry-estimated) ----
    # Cn_da_per_deg: adverse yaw from aileron — induced drag differential.
    #   Cn_da ≈ −CL(α) × Cl_da / (π × AR) per degree.
    # Cl_dr_per_deg: roll from rudder — VTP above roll axis.
    #   Cl_dr ≈ Cn_dr × (z_vtp / l_vtp) per degree.

    AR = isempty(input.lifting_surfaces) ? 6.0 : input.lifting_surfaces[1].AR
    Cl_da_ref = 0.005
    Cd_da_ref = 3.5e-5
    Cn_dr_ref = 0.003
    z_vtp_over_lvtp = 0.0
    aileron_y_eff_over_b = 0.35

    if !isnothing(aileron_surf) && !isnothing(aileron_cs)
        raw_clda = get_control_deriv_value(input, aileron_surf, aileron_cs,
                                           argmin(abs.(alphas)), results)
        Cl_da_ref = abs(raw_clda)
        Cd_da_ref = estimate_surface_control_drag_derivative_per_deg(input, aileron_surf, aileron_cs)
        aileron_y_eff_over_b = 0.5 * control_surface_eta_mid(aileron_cs)
    end

    rudder_surf, rudder_cs = find_control_surface(input, "rudder"; role="vertical_stabilizer")
    if !isnothing(rudder_surf) && !isnothing(rudder_cs)
        raw_cndr = abs(get_control_deriv_value(input, rudder_surf, rudder_cs,
                                               argmin(abs.(alphas)), results))
        Cn_dr_ref = raw_cndr
    end

    if !haskey(ce, "Cd_da_per_deg") && !isnothing(aileron_surf) && !isnothing(aileron_cs)
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (_, _) in enumerate(machs)
                mach_data = Float64[]
                for α_deg in alphas
                    eff = control_stall_factor(α_deg, α_stall_pos, α_stall_neg)
                    val = Cd_da_ref * (0.35 + 0.65 * eff)
                    push!(mach_data, round(val, digits=6))
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        ce["Cd_da_per_deg"] = Dict("values" => values)
    end

    # Estimate VTP z-arm / x-arm ratio from geometry
    cg_x = input.general.CoG[1]
    cg_z = length(input.general.CoG) >= 3 ? input.general.CoG[3] : 0.0
    for surf in input.lifting_surfaces
        if surf.role == "vertical_stabilizer" || surf.vertical
            vtp_x = surf.root_LE[1] + 0.25 * surf.mean_aerodynamic_chord_m
            vtp_span = sqrt(surf.AR * surf.surface_area_m2)
            vtp_z = surf.root_LE[3] + vtp_span * 0.4  # approximate centroid height
            l_vtp = max(abs(vtp_x - cg_x), 0.1)
            z_arm = vtp_z - cg_z
            z_vtp_over_lvtp = z_arm / l_vtp
            break
        end
    end

    # Get CL(alpha) at beta=0 from full-envelope data
    vlm = get(results, "vlm", nothing)
    CL_vs_alpha = nothing
    if !isnothing(vlm)
        st = get(vlm, "static", nothing)
        if !isnothing(st)
            CL_2d = get(st, "CL", nothing)
            if !isnothing(CL_2d)
                vlm_betas = get(vlm, "betas_deg", Float64[0.0])
                β0 = argmin(abs.(vlm_betas))
                CL_vs_alpha = CL_2d[:, β0]
            end
        end
    end

    # Cn_da_per_deg
    if !haskey(ce, "Cn_da_per_deg") && !isnothing(aileron_surf) && !isnothing(aileron_cs)
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (mi, _) in enumerate(machs)
                mach_data = Float64[]
                for (ai, α_deg) in enumerate(alphas)
                    eff = control_stall_factor(α_deg, α_stall_pos, α_stall_neg)
                    CL_at_alpha = !isnothing(CL_vs_alpha) && ai <= length(CL_vs_alpha) ? CL_vs_alpha[ai] : 0.0
                    lift_term = abs(CL_at_alpha) * abs(Cl_da_ref) / (π * AR)
                    drag_term = 2.2 * aileron_y_eff_over_b * Cd_da_ref * (0.35 + 0.65 * eff)
                    val = -(drag_term + lift_term * eff)
                    push!(mach_data, round(val, digits=6))
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        ce["Cn_da_per_deg"] = Dict("values" => values)
    end

    # Cl_dr_per_deg
    if !haskey(ce, "Cl_dr_per_deg")
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (mi, _) in enumerate(machs)
                mach_data = Float64[]
                for (ai, α_deg) in enumerate(alphas)
                    val = Cn_dr_ref * z_vtp_over_lvtp
                    val *= control_stall_factor(α_deg, α_stall_pos, α_stall_neg)
                    push!(mach_data, round(val, digits=6))
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        ce["Cl_dr_per_deg"] = Dict("values" => values)
    end

    return ce
end

"""
    control_stall_factor(α_deg, α_stall_pos, α_stall_neg) -> Float64

Returns a [0,1] degradation factor for control effectiveness.
Full effectiveness (1.0) within the pre-stall regime; exponential
decay beyond stall with a 20° e-folding distance, matching the
aerodynamic envelope model in full_envelope.jl.
"""
function control_stall_factor(α_deg::Float64, α_stall_pos::Float64, α_stall_neg::Float64)
    α_abs = abs(α_deg)
    α_stall = max(abs(α_stall_pos), abs(α_stall_neg), 10.0)

    if α_abs <= α_stall
        return 1.0
    elseif α_abs <= 90.0
        Δ = α_abs - α_stall
        return max(0.08, exp(-Δ / 22.0))
    end

    blend = clamp((α_abs - 90.0) / 90.0, 0.0, 1.0)
    return 0.08 * (1.0 - blend) + 0.20 * blend
end

function get_control_derivative_name(cs_type::String)
    names = Dict("elevator" => "Cm_de_per_deg", "aileron" => "Cl_da_per_deg",
        "rudder" => "Cn_dr_per_deg", "flap" => "CL_df_per_deg",
        "spoiler" => "CL_ds_per_deg")
    get(names, cs_type, "C_d" * cs_type[1:1] * "_per_deg")
end

function get_control_deriv_value(input::AircraftInput, surf::LiftingSurface,
                                 cs::ControlSurface, ai::Int, results::Dict)
    # Priority 1: JAVL control derivatives — actual linear potential-flow result.
    # JAVL stores these derivatives per degree of control deflection, matching
    # the control_effectiveness tables.
    javl = get(results, "javl", nothing)
    if !isnothing(javl)
        javl_cds = get(javl, "control_derivatives", Dict())
        cs_data = get(javl_cds, cs.name, nothing)
        if !isnothing(cs_data)
            # Map control type to the appropriate derivative field
            field = if cs.type == "elevator"
                "cmy_d"   # dCm/dδ for elevator
            elseif cs.type == "aileron"
                "cmx_d"   # dCl/dδ for aileron
            elseif cs.type == "rudder"
                "cmz_d"   # dCn/dδ for rudder
            else
                nothing
            end
            if !isnothing(field)
                vals = get(cs_data, field, nothing)
                if !isnothing(vals) && vals isa Vector && ai <= length(vals)
                    sample = Float64(vals[ai])
                    if lowercase(cs.type) == "rudder"
                        sample = -sample
                    end
                    if isfinite(sample)
                        return sample
                    end
                end
            end
        end
    end

    # Priority 2: VLM control derivatives (may be placeholder values)
    vlm = get(results, "vlm", nothing)
    if !isnothing(vlm)
        cd = get(vlm, "control_derivatives", Dict())
        cs_data = get(cd, cs.name, nothing)
        if !isnothing(cs_data)
            vals = get(cs_data, "values", nothing)
            if !isnothing(vals) && vals isa Vector && ai <= length(vals)
                sample = Float64(vals[ai])
                if isfinite(sample) && abs(sample) > 1e-9
                    return sample
                end
            end
        end
    end

    # Fallback: geometry-based estimate. This is only used when no backend
    # supplied a usable value, rather than to reshape valid solver output.
    return estimate_primary_control_derivative_per_deg(input, surf, cs)
end

# ---- Build control drag increment tables ----
function build_control_drag_increments(input, configs, machs, alphas)
    cdi = Dict{String,Any}()
    defl_abs = [0.0, 10.0, 20.0]
    cdi["axis_order"] = ["config", "mach", "alpha_deg", "abs_deflection_deg"]
    cdi["axes"] = Dict("config" => configs, "mach" => machs,
        "alpha_deg" => alphas, "abs_deflection_deg" => defl_abs)

    # Simple parabolic drag increment model
    for surf in input.lifting_surfaces
        for cs in surf.control_surfaces
            key = "delta_CD_from_" * control_abbreviation(cs.type) * "_abs"
            if !haskey(cdi, key)
                values = Dict{String,Any}()
                for cfg in configs
                    cfg_data = []
                    for (mi, _) in enumerate(machs)
                        mach_data = []
                        for (ai, _) in enumerate(alphas)
                            defl_data = Float64[]
                            for d in defl_abs
                                # Parabolic: CD ~ k * delta^2
                                k = cs.chord_fraction * 0.00015
                                push!(defl_data, round(k * d^2, digits=5))
                            end
                            push!(mach_data, defl_data)
                        end
                        push!(cfg_data, mach_data)
                    end
                    values[cfg] = cfg_data
                end
                cdi[key] = Dict("values" => values)
            end
        end
    end

    aileron_surf, aileron_cs = find_control_surface(input, "aileron"; role="wing")
    if !haskey(cdi, "delta_CD_from_da_abs") && !isnothing(aileron_surf) && !isnothing(aileron_cs)
        cd_da_ref = estimate_surface_control_drag_derivative_per_deg(input, aileron_surf, aileron_cs)
        values = Dict{String,Any}()
        for cfg in configs
            cfg_data = []
            for (_, _) in enumerate(machs)
                mach_data = []
                for (_, _) in enumerate(alphas)
                    defl_data = Float64[]
                    for d in defl_abs
                        push!(defl_data, round(cd_da_ref * d, digits=5))
                    end
                    push!(mach_data, defl_data)
                end
                push!(cfg_data, mach_data)
            end
            values[cfg] = cfg_data
        end
        cdi["delta_CD_from_da_abs"] = Dict("values" => values)
    end

    return cdi
end

# ---- Post-stall model ----
function build_poststall(input, configs)
    ps = Dict{String,Any}()
    ps["model"] = "sin2alpha"

    alpha_on = Dict{String,Any}()
    alpha_off = Dict{String,Any}()
    sf_scale = Dict{String,Any}()
    drag_floor = Dict{String,Any}()
    drag_90 = Dict{String,Any}()

    # Compute stall angle from geometry (DATCOM methods)
    mach_ref = isempty(input.analysis.mach_values) ? 0.2 : input.analysis.mach_values[1]
    stall_data = compute_aircraft_stall(input; mach=mach_ref,
                                        altitude_m=input.analysis.altitude_m)
    α_stall_base = Float64(stall_data["alpha_stall_positive"])
    CD90_computed = Float64(stall_data["CD90"])

    for cfg in configs
        flap = 0.0
        for c in input.configurations
            if c.id == cfg
                flap = c.flap_deg
            end
        end
        # Stall onset from geometry + flap correction
        alpha_on[cfg] = round(α_stall_base - 2.0 + flap * 0.15, digits=1)
        alpha_off[cfg] = round(α_stall_base - 6.0 + flap * 0.15, digits=1)
        # Sideforce scale depends on stall type: TE stall retains more
        # lateral force effectiveness; LE stall disrupts flow more abruptly
        stype = get(stall_data, "wing_stall_type", "combined")
        sf_scale[cfg] = stype == "trailing_edge" ? 0.85 :
                        (stype == "combined" ? 0.75 : 0.60)
        drag_floor[cfg] = round(Float64(stall_data["CD0"]) + flap * 0.002, digits=4)
        drag_90[cfg] = CD90_computed
    end

    ps["alpha_on_deg"] = alpha_on
    ps["alpha_off_deg"] = alpha_off
    ps["sideforce_scale"] = sf_scale
    ps["drag_floor"] = drag_floor
    ps["drag_90deg"] = drag_90

    return ps
end

# ---- Local flow ----
function build_local_flow(input, configs, alphas, betas)
    lf = Dict{String,Any}()

    # ── Extract geometry from aircraft definition ──
    wing = nothing
    htail = nothing
    vtail = nothing
    for s in input.lifting_surfaces
        if s.role == "wing" && isnothing(wing)
            wing = s
        elseif s.role == "horizontal_stabilizer" && isnothing(htail)
            htail = s
        elseif (s.role == "vertical_stabilizer" || s.vertical) && isnothing(vtail)
            vtail = s
        end
    end

    AR     = isnothing(wing) ? 8.0 : wing.AR
    cref   = input.general.cref
    bref   = input.general.bref
    Sref   = input.general.Sref
    x_cg   = input.general.CoG[1]
    z_cg   = length(input.general.CoG) >= 3 ? input.general.CoG[3] : 0.0

    # Wing lift-curve slope (subsonic, thin-airfoil)
    sweep_rad = isnothing(wing) ? 0.0 : deg2rad(wing.sweep_quarter_chord_DEG)
    CLa_wing  = 2π * AR / (2 + sqrt(4 + AR^2 * (1 + tan(sweep_rad)^2)))

    # Stall data from DATCOM estimation
    mach_ref   = isempty(input.analysis.mach_values) ? 0.2 : input.analysis.mach_values[1]
    stall_data = compute_aircraft_stall(input; mach=mach_ref,
                                        altitude_m=input.analysis.altitude_m)
    α_stall_pos = Float64(get(stall_data, "alpha_stall_positive", 15.0))

    # Tail geometry
    z_wing  = isnothing(wing)  ? 0.0 : (length(wing.root_LE) >= 3 ? wing.root_LE[3] : 0.0)
    z_htail = isnothing(htail) ? z_wing : (length(htail.root_LE) >= 3 ? htail.root_LE[3] : z_wing)
    x_htail = isnothing(htail) ? x_cg + 5.0 * cref : htail.root_LE[1]
    l_t     = x_htail - x_cg          # tail arm
    dz_ht   = z_htail - z_wing        # vertical offset (z-down: negative = tail above wing)

    # VTP stall angle for sidewash saturation
    β_stall_vtp = Float64(get(stall_data, "vtail_beta_stall_deg", 20.0))

    # Fuselage cross-section drives sidewash strength
    fus_diam = isempty(input.fuselages) ? bref * 0.1 : input.fuselages[1].diameter
    # Sidewash slope: σ/β depends on body diameter relative to span
    # σ ≈ −k_σ × β where k_σ ≈ 0.4 × (D/b) for a circular fuselage (ESDU 82010)
    k_sw = -clamp(0.4 * fus_diam / bref, 0.05, 0.35)

    # ══════════════════════════════════════════════════════════════
    # Downwash ε(α)
    # ══════════════════════════════════════════════════════════════
    # dε/dα ≈ 2·CLα/(π·AR) from lifting-line theory
    # ε in degrees per degree of α, so scale by rad→deg: × (180/π) then /α_deg
    # Net: k_dw (deg ε / deg α) = 2·CLα_wing·(180/π) / (π·AR · (180/π)) = 2·CLα_wing/(π·AR)
    # But CLα is in 1/rad, and α in deg → ε(deg) = CLα(1/rad) × α_rad × (2/(πAR)) × (180/π)
    # Simplify: k_dw = CLa_wing × 2 / (π * AR) per radian, convert to per degree
    deda_rad = 2.0 * CLa_wing / (π * AR)   # dε/dα in rad/rad
    k_dw     = deda_rad                      # applied to α in deg → ε in deg (same ratio)

    dw = Dict{String,Any}()
    dw["axis_order"] = ["config", "alpha_deg"]
    dw["axes"] = Dict("config" => configs, "alpha_deg" => alphas)
    dw_vals = Dict{String,Any}()
    for cfg in configs
        # Flap offset: increased downwash from flap lift increment
        # Δε ≈ dε/dCL × ΔCL_flap, where ΔCL_flap ≈ 0.05 per deg flap (DATCOM)
        flap_deg = 0.0
        for c in input.configurations
            if c.id == cfg
                flap_deg = c.flap_deg
            end
        end
        flap_offset = deda_rad * 0.05 * flap_deg / max(CLa_wing, 0.1) * (180.0 / π)

        dw_vals[cfg] = Float64[]
        for a in alphas
            # Saturating core: tanh models CL saturation at stall
            ε_sat = k_dw * α_stall_pos * tanh(a / α_stall_pos)
            # Post-stall decay: separated wake loses coherence
            excess = max(0.0, abs(a) - 1.5 * α_stall_pos)
            decay  = 1.0 / (1.0 + (excess / (2.5 * α_stall_pos))^2)
            push!(dw_vals[cfg], round(ε_sat * decay + flap_offset, digits=2))
        end
    end
    dw["values"] = dw_vals
    lf["downwash_deg"] = dw

    # ══════════════════════════════════════════════════════════════
    # Sidewash σ(β)
    # ══════════════════════════════════════════════════════════════
    sw = Dict{String,Any}()
    sw["axis_order"] = ["config", "beta_deg"]
    sw["axes"] = Dict("config" => configs, "beta_deg" => betas)
    sw_vals = Dict{String,Any}()
    for cfg in configs
        sw_vals[cfg] = Float64[]
        for b in betas
            # Saturates at VTP stall angle (fin/body flow separation)
            σ_sat = k_sw * β_stall_vtp * tanh(b / β_stall_vtp)
            # Post-separation decay
            excess = max(0.0, abs(b) - 1.5 * β_stall_vtp)
            decay  = 1.0 / (1.0 + (excess / (2.0 * β_stall_vtp))^2)
            push!(sw_vals[cfg], round(σ_sat * decay, digits=2))
        end
    end
    sw["values"] = sw_vals
    lf["sidewash_deg"] = sw

    # ══════════════════════════════════════════════════════════════
    # Tail dynamic pressure ratio η_t(α)
    # ══════════════════════════════════════════════════════════════
    # The wing wake deflects downward by ε(α).  At the tail location the
    # wake centre is at:  z_wake = z_wing + l_t × tan(ε)  (small angle ≈ l_t × ε_rad)
    # The tail is at z_htail.  When the tail is inside the wake, η_t is low.
    # Wake half-thickness at the tail ≈ 12% of wing chord (ESDU / Raymer).
    wake_ht = 0.12 * cref
    # The maximum deficit when the tail is centred in the wake:
    #   clean: thinner BL → ~8% loss;  flapped: thicker wake → ~12% loss
    # These scale with wing t/c (thicker wing → thicker wake)
    wing_tovc = isnothing(wing) ? 0.12 : (0.7 * wing.airfoil.root_thickness_ratio +
                                           0.3 * wing.airfoil.tip_thickness_ratio)
    base_deficit_clean = clamp(0.06 + 0.5 * wing_tovc, 0.05, 0.15)

    tdpr = Dict{String,Any}()
    tdpr["axis_order"] = ["config", "alpha_deg"]
    tdpr["axes"] = Dict("config" => configs, "alpha_deg" => alphas)
    tdpr_vals = Dict{String,Any}()
    for cfg in configs
        flap_deg = 0.0
        for c in input.configurations
            if c.id == cfg
                flap_deg = c.flap_deg
            end
        end
        # Flap increases wake deficit
        max_deficit = base_deficit_clean + 0.001 * flap_deg

        tdpr_vals[cfg] = Float64[]
        for a in alphas
            # Downwash at this α (small-angle, pre-stall) deflects wake downward
            ε_rad = deda_rad * clamp(a, -α_stall_pos, α_stall_pos) * (π / 180.0)
            # Wake centre vertical position at tail (z-down convention)
            z_wake = z_wing + l_t * ε_rad
            # Vertical distance between tail and wake centre
            Δz = z_htail - z_wake
            # Gaussian immersion factor
            deficit = max_deficit * exp(-(Δz / max(wake_ht, 0.01))^2)
            push!(tdpr_vals[cfg], round(clamp(1.0 - deficit, 0.0, 1.0), digits=3))
        end
    end
    tdpr["values"] = tdpr_vals
    lf["tail_dynamic_pressure_ratio"] = tdpr

    return lf
end

# ---- Propulsion ----
function build_propulsion(input, machs)
    prop = Dict{String,Any}()
    prop["engine_count"] = length(input.engines)
    prop["throttle_input_mode"] = length(input.engines) > 1 ? "per_engine" : "single_lever"

    engines = []
    for eng in input.engines
        push!(engines, Dict(
            "id" => eng.id,
            "position_m" => Dict("x" => eng.position_m[1], "y" => eng.position_m[2],
                "z" => length(eng.position_m) >= 3 ? eng.position_m[3] : 0.0),
            "orientation_deg" => eng.orientation_deg,
            "thrust_scale" => eng.thrust_scale,
            "max_thrust_n" => eng.max_thrust_n,
            "reverse_thrust_ratio" => eng.reverse_thrust_ratio,
            "throttle_channel" => eng.throttle_channel,
            "spool_up_1_s" => eng.spool_up_1_s,
            "spool_down_1_s" => eng.spool_down_1_s
        ))
    end
    prop["engines"] = engines

    # Thrust map (shared across all engines)
    base_thrust = isempty(input.engines) ? 35000.0 : input.engines[1].max_thrust_n
    prop["thrust_map_shared"] = build_thrust_map(machs, base_thrust)

    # Aero-propulsion coupling
    if !isempty(input.engines)
        prop["aero_propulsion_coupling"] = build_aero_prop_coupling(input, machs)
    end

    return prop
end

# ---- Thrust map ----
function build_thrust_map(machs, base_thrust::Float64=35000.0)
    # Use the analysis Mach values as the thrust map Mach axis
    thrust_machs = isempty(machs) ? [0.0, 0.4, 0.7] : machs
    altitudes = [0.0, 5000.0, 10000.0]
    throttles = [0.0, 0.5, 1.0]

    tmap = Dict{String,Any}()
    tmap["axis_order"] = ["mach", "altitude_m", "throttle"]
    tmap["axes"] = Dict(
        "mach" => thrust_machs,
        "altitude_m" => altitudes,
        "throttle" => throttles
    )

    # values[mach_idx][altitude_idx][throttle_idx]
    vals = []
    for mach in thrust_machs
        mach_factor = 1.0 - 0.3 * mach  # thrust lapse with Mach
        mach_data = []
        for alt in altitudes
            alt_factor = exp(-alt / 10000.0)  # density ratio approximation
            alt_data = Float64[]
            for thr in throttles
                thrust = round(base_thrust * mach_factor * alt_factor * thr, digits=0)
                push!(alt_data, thrust)
            end
            push!(mach_data, alt_data)
        end
        push!(vals, mach_data)
    end
    tmap["values"] = vals

    return tmap
end

# ---- Aero-propulsion coupling ----
function build_aero_prop_coupling_legacy_tensor(input, machs)
    configs = [c.id for c in input.configurations]
    if isempty(configs)
        configs = ["clean"]
    end
    alphas = get_alpha_array(input.analysis)
    ct_values = [0.0, 0.2, 0.4]

    coupling = Dict{String,Any}()
    dCX = Dict{String,Any}()
    dCX["axis_order"] = ["config", "mach", "alpha_deg", "ct_total"]
    dCX["axes"] = Dict(
        "config" => configs,
        "mach" => machs,
        "alpha_deg" => alphas,
        "ct_total" => ct_values
    )

    # Small interference drag: ΔCX ~ -k * CT * (1 + α/20)
    vals = Dict{String,Any}()
    for cfg in configs
        cfg_data = []
        for _ in machs
            mach_data = []
            for alpha in alphas
                ct_data = Float64[]
                for ct in ct_values
                    dCx = round(-0.01 * ct * (1.0 + abs(alpha) / 20.0), digits=4)
                    push!(ct_data, dCx)
                end
                push!(mach_data, ct_data)
            end
            push!(cfg_data, mach_data)
        end
        vals[cfg] = cfg_data
    end
    dCX["values"] = vals

    coupling["delta_CX_from_total_CT"] = dCX
    return coupling
end

# Compact override: keep the same behavior, but export the coupling as a
# parametric scalar block instead of an expanded lookup tensor.
function build_aero_prop_coupling(input, machs)
    coupling = Dict{String,Any}()

    # Small interference drag:
    #   delta_CX = ct_total * (a0 + a_abs_alpha * abs(alpha_deg))
    coupling["delta_CX_from_total_CT"] = Dict(
        "model" => "ct_total_times_affine_abs_alpha_deg",
        "dCX_dCT_at_alpha0" => -0.01,
        "dCX_dCT_abs_alpha_slope_per_deg" => -0.0005
    )
    return coupling
end

# ---- Actuators ----
function build_actuators(input)
    rate_limits = Dict{String,Any}()
    pos_limits = Dict{String,Any}()

    for surf in input.lifting_surfaces
        for cs in surf.control_surfaces
            rate_limits[cs.name] = 60.0  # Default 60 deg/s
            pos_limits[cs.name] = [cs.deflection_range_DEG[1], cs.deflection_range_DEG[2]]
        end
    end

    return Dict(
        "surface_rate_limit_deg_s" => rate_limits,
        "position_limit_deg" => pos_limits
    )
end

# ================================================================
# Per-surface data passthrough from VLM
# ================================================================

"""
    build_per_surface_data(input, results, alphas, betas) -> Dict

Collects per-surface CL/CY/CD arrays from VLM results, keyed by surface name.
The JS export module uses this to build separate tail coefficient tables.
"""
function build_per_surface_data(input::AircraftInput, results::Dict,
    alphas::Vector{Float64}, betas::Vector{Float64})
    psd = Dict{String,Any}()

    vlm = get(results, "vlm", nothing)
    if isnothing(vlm)
        return psd
    end

    vlm_psd = get(vlm, "per_surface_data", nothing)
    if isnothing(vlm_psd)
        return psd
    end

    for surf in input.lifting_surfaces
        sd = get(vlm_psd, surf.name, nothing)
        if isnothing(sd)
            continue
        end

        CL_mat = get(sd, "CL", nothing)
        CY_mat = get(sd, "CY", nothing)
        CD_mat = get(sd, "CD", nothing)

        surf_dict = Dict{String,Any}(
            "role" => surf.role,
            "alphas_deg" => alphas,
            "betas_deg" => betas
        )

        # Convert matrices to nested arrays [alpha_idx][beta_idx]
        if !isnothing(CL_mat) && ndims(CL_mat) == 2
            surf_dict["CL"] = [round.(CL_mat[ai, :], digits=5) for ai in 1:size(CL_mat, 1)]
        end
        if !isnothing(CY_mat) && ndims(CY_mat) == 2
            surf_dict["CY"] = [round.(CY_mat[ai, :], digits=5) for ai in 1:size(CY_mat, 1)]
        end
        if !isnothing(CD_mat) && ndims(CD_mat) == 2
            surf_dict["CD"] = [round.(CD_mat[ai, :], digits=5) for ai in 1:size(CD_mat, 1)]
        end

        psd[surf.name] = surf_dict
    end

    return psd
end

# ================================================================
# Tail aerodynamics — isolated tail surface characteristics
# ================================================================

"""
    datcom_flap_tau(cf_over_c) -> Float64

DATCOM plain-flap effectiveness factor τ (Ames & Sears, thin-airfoil theory).
τ = 1 − (θ − sin θ cos θ)/π  where θ = arccos(1 − 2 cf/c).
Gives τ ≈ 0.60 for cf/c = 0.25, τ ≈ 0.42 for cf/c = 0.35.
"""
function datcom_flap_tau(cf_over_c::Float64)
    cf = clamp(cf_over_c, 0.05, 0.50)
    θ = acos(1.0 - 2.0 * cf)
    return 1.0 - (θ - sin(θ) * cos(θ)) / π
end

function find_surface_by_role(input::AircraftInput, role::String)
    for surf in input.lifting_surfaces
        if surf.role == role
            return surf
        end
        if role == "vertical_stabilizer" && surf.vertical
            return surf
        end
    end
    return nothing
end

function surface_lift_curve_slope_rad(surf::LiftingSurface)
    AR = max(surf.AR, 0.1)
    sweep = deg2rad(surf.sweep_quarter_chord_DEG)
    return 2π * AR / (2 + sqrt(4 + AR^2 * (1 + tan(sweep)^2)))
end

function control_surface_span_fraction(cs::ControlSurface)
    return clamp(cs.eta_end - cs.eta_start, 0.15, 1.0)
end

function control_surface_eta_mid(cs::ControlSurface)
    return clamp(0.5 * (cs.eta_start + cs.eta_end), 0.05, 0.98)
end

function find_control_surface(input::AircraftInput, cs_type::String;
                              role::Union{Nothing,String}=nothing)
    wanted_type = lowercase(cs_type)

    for surf in input.lifting_surfaces
        if !isnothing(role)
            role_match = surf.role == role || (role == "vertical_stabilizer" && surf.vertical)
            role_match || continue
        end

        for cs in surf.control_surfaces
            if lowercase(cs.type) == wanted_type
                return surf, cs
            end
        end
    end

    return nothing, nothing
end

function estimate_surface_control_force_derivative_per_rad(input::AircraftInput,
                                                           surf::LiftingSurface,
                                                           cs::ControlSurface)
    area_ratio = surf.surface_area_m2 / max(input.general.Sref, 1e-3)
    τ = datcom_flap_tau(cs.chord_fraction)
    span_fraction = control_surface_span_fraction(cs)
    gain = clamp(cs.gain, 0.25, 2.0)
    magnitude = surface_lift_curve_slope_rad(surf) *
                area_ratio * τ * span_fraction * gain * 0.85

    if lowercase(cs.type) == "rudder"
        return -magnitude
    end
    return magnitude
end

function estimate_surface_control_drag_derivative_per_deg(input::AircraftInput,
                                                          surf::LiftingSurface,
                                                          cs::ControlSurface)
    area_ratio = clamp(surf.surface_area_m2 / max(input.general.Sref, 1e-3), 0.25, 1.50)
    span_fraction = control_surface_span_fraction(cs)
    gain = clamp(cs.gain, 0.25, 2.0)
    tau = datcom_flap_tau(cs.chord_fraction)

    base = 0.00015 * cs.chord_fraction *
           (0.70 + 0.60 * span_fraction) *
           gain *
           max(0.80, area_ratio^0.25) *
           (0.55 + 0.45 * tau)

    return clamp(base, 1.0e-5, 2.5e-4)
end

function estimate_primary_control_derivative_per_deg(input::AircraftInput,
                                                     surf::LiftingSurface,
                                                     cs::ControlSurface)
    cs_type = lowercase(cs.type)

    if cs_type == "elevator"
        wp = wing_planform(surf)
        arm = abs((surf.root_LE[1] + 0.25 * wp.mac) - input.general.CoG[1]) /
              max(input.general.cref, 1e-3)
        dCL_dδ_rad = estimate_surface_control_force_derivative_per_rad(input, surf, cs)
        return -dCL_dδ_rad * arm * π / 180
    elseif cs_type == "rudder"
        wp = wing_planform(surf)
        arm = abs((surf.root_LE[1] + 0.25 * wp.mac) - input.general.CoG[1]) /
              max(input.general.bref, 1e-3)
        dCY_dδ_rad = estimate_surface_control_force_derivative_per_rad(input, surf, cs)
        return -dCY_dδ_rad * arm * π / 180
    elseif cs_type == "aileron"
        tau_ref = datcom_flap_tau(0.25)
        tau = datcom_flap_tau(cs.chord_fraction)
        gain = clamp(cs.gain, 0.25, 2.0)
        span_fraction = control_surface_span_fraction(cs)
        eta_mid = control_surface_eta_mid(cs)

        # Aileron rolling moment is dominated by outboard leverage.  The old
        # fallback scaled almost linearly with span fraction and under-predicted
        # conventional outboard ailerons, leaving trainers with poor roll power
        # whenever a backend did not return control derivatives.
        coverage_factor = clamp(span_fraction / 0.35, 0.55, 1.55)
        lever_factor = clamp(eta_mid / 0.75, 0.70, 1.30)
        ref = 0.0046 * (tau / tau_ref) * coverage_factor * lever_factor * gain
        return clamp(ref, 0.0015, 0.012)
    elseif cs_type == "flap"
        return 0.015
    elseif cs_type == "spoiler"
        return -0.008
    end

    return 0.0
end

"""
    tail_stall_CL(alpha_eff_rad, CLa_rad, CL_max, alpha_stall_rad, CD90) -> Float64

Full-envelope lift model for an isolated tail surface.
Pre-stall: linear.  Post-stall: exponential decay to flat-plate sin·cos.
"""
function tail_stall_CL(α_eff_rad::Float64, CLa_rad::Float64,
                        CL_max::Float64, α_stall_rad::Float64, CD90::Float64)
    CL_fp = CD90 * sin(α_eff_rad) * cos(α_eff_rad)
    if abs(α_eff_rad) <= α_stall_rad
        return CLa_rad * α_eff_rad
    else
        CL_peak = sign(α_eff_rad) * CL_max
        Δ = abs(α_eff_rad) - α_stall_rad
        decay = exp(-Δ / deg2rad(20.0))   # 20° e-folding
        return CL_peak * decay + CL_fp * (1.0 - decay)
    end
end

"""
    tail_stall_sideforce(beta_eff_rad, CY_beta_rad, CY_max, beta_stall_rad, CD90_lat) -> Float64

Full-envelope side-force model for an isolated vertical tail.
Pre-stall: linear. Post-stall: exponential decay to a flat-plate cross-flow
term proportional to sin(beta), which peaks at 90 deg and stays restoring in
the rear quadrants instead of changing sign past 90 deg.
"""
function tail_stall_sideforce(β_eff_rad::Float64, CY_beta_rad::Float64,
                              CY_max::Float64, β_stall_rad::Float64, CD90_lat::Float64)
    sign_ref = CY_beta_rad >= 0.0 ? 1.0 : -1.0
    CY_fp = sign_ref * CD90_lat * sin(β_eff_rad)
    if abs(β_eff_rad) <= β_stall_rad
        return CY_beta_rad * β_eff_rad
    else
        CY_peak = sign_ref * sign(β_eff_rad) * abs(CY_max)
        Δ = abs(β_eff_rad) - β_stall_rad
        decay = exp(-Δ / deg2rad(20.0))   # 20 deg e-folding
        return CY_peak * decay + CY_fp * (1.0 - decay)
    end
end

function build_tail_aerodynamics(input::AircraftInput, results::Dict,
    alphas::Vector{Float64}, betas::Vector{Float64})
    ta = Dict{String,Any}()

    Sref = input.general.Sref
    cref = input.general.cref
    bref = input.general.bref
    cg_x = input.general.CoG[1]
    mach_ref = input.analysis.mach_values[1]
    alt_m    = input.analysis.altitude_m

    # ---- HTP ----
    htp = Dict{String,Any}()
    htail = nothing
    for s in input.lifting_surfaces
        if s.role == "horizontal_stabilizer"
            htail = s
            break
        end
    end

    if !isnothing(htail)
        wp_h = wing_planform(htail)
        AR_h = htail.AR
        Sh   = htail.surface_area_m2
        eta_h = Sh / Sref

        # Isolated HTP lift-curve slope (Helmbold, per radian)
        a_h_rad = 2π * AR_h / (2 + sqrt(4 + AR_h^2))
        CLh_alpha_rad = a_h_rad * eta_h
        CLh_alpha_deg = CLh_alpha_rad * π / 180

        # HTP stall from DATCOM
        h_stall = datcom_wing_clmax(input, htail; mach=mach_ref, altitude_m=alt_m)
        α_stall_h_rad = deg2rad(h_stall.alpha_stall_pos_deg)
        CL_max_h = h_stall.CL_max * eta_h   # referenced to Sref
        CD90_h = 1.98 * eta_h   # flat plate at 90° for HTP

        # Zero-lift angle from HTP camber + incidence
        max_camber_h = htail.airfoil.root_max_camber
        alpha_0L_h_rad = -2.0 * max_camber_h
        incidence_h_rad = deg2rad(htail.incidence_DEG)
        α_offset_h = -alpha_0L_h_rad + incidence_h_rad

        # CLh(α) with stall
        CLh = Float64[]
        for α in alphas
            α_eff = deg2rad(α) + α_offset_h
            cl = tail_stall_CL(α_eff, CLh_alpha_rad, CL_max_h, α_stall_h_rad, CD90_h)
            push!(CLh, round(cl, digits=6))
        end
        htp["alphas_deg"]       = collect(Float64, alphas)
        htp["CLh"]              = CLh
        htp["CLh_alpha_per_deg"] = round(CLh_alpha_deg, digits=6)
        htp["alpha_stall_deg"]  = round(h_stall.alpha_stall_pos_deg, digits=2)
        htp["CLh_max"]          = round(CL_max_h, digits=4)
        htp["reference_area_kind"] = "aircraft_Sref"
        htp["reference_area_m2"] = round(Sref, digits=4)
        htp["surface_area_m2"] = round(Sh, digits=4)
        htp["area_ratio_to_sref"] = round(eta_h, digits=4)

        # Moment arm: HTP AC to CG
        x_htail_ac = htail.root_LE[1] + 0.25 * wp_h.mac
        arm_h = (x_htail_ac - cg_x) / cref
        htp["moment_arm_over_cref"] = round(arm_h, digits=4)

        # Cm_HTP(α) = −CLh(α) × arm_h
        Cm_HTP = [round(-CLh[i] * arm_h, digits=6) for i in eachindex(CLh)]
        htp["Cm_due_to_HTP"] = Cm_HTP

        # ---- Elevator control derivative ----
        # Source priority: AVL (JAVL) control derivatives → DATCOM flap τ fallback
        # Case-insensitive match on `type` so inputs written as "Elevator",
        # "ELEVATOR", or "elevator" all resolve the same way — a missed
        # match here is the most common reason the Full View's elevator
        # effectiveness charts come up blank.
        elevator = nothing
        for cs in htail.control_surfaces
            if lowercase(string(cs.type)) == "elevator"
                elevator = cs
                break
            end
        end
        if !isnothing(elevator)
            τ_e = datcom_flap_tau(elevator.chord_fraction)
            # Deflection sweep from actuator limits
            δ_min = elevator.deflection_range_DEG[1]
            δ_max = elevator.deflection_range_DEG[2]
            δ_step = 1.0
            delta_degs = collect(Float64, δ_min:δ_step:δ_max)

            # DATCOM flow-separation angle for plain flaps (DATCOM Figure 6.1.1.1-25).
            # This is the deflection at which the flap boundary layer separates and
            # effectiveness begins to roll off.  Typical range: 12°-18° for cf/c 0-0.5.
            δ_sep_deg = 12.0 + 12.0 * clamp(elevator.chord_fraction, 0.0, 0.5)
            δ_sep_rad = deg2rad(δ_sep_deg)

            # Try to get JAVL linear derivative dCL/dδ (per degree) at each alpha.
            # JAVL stores these in results["javl"]["control_derivatives"][name]["cl_d"]
            javl = get(results, "javl", nothing)
            javl_cd = nothing
            if !isnothing(javl)
                javl_cds = get(javl, "control_derivatives", Dict())
                javl_cd = get(javl_cds, elevator.name, nothing)
            end

            ΔCLh = Vector{Float64}[]   # [alpha_idx][delta_idx]
            ΔCm_e = Vector{Float64}[]
            ΔCDh = Vector{Float64}[]
            e_h = clamp(htail.Oswald_factor, 0.55, 0.95)
            k_induced_h = 1.0 / (π * max(AR_h, 0.3) * e_h * max(eta_h, 1e-3))
            profile_drag_gain_h = 1.2e-5 * elevator.chord_fraction *
                                  max(1.0, control_surface_span_fraction(elevator) / 0.35)
            for (ai, α_deg) in enumerate(alphas)
                # dCL/dδ per degree at this alpha: JAVL value or DATCOM τ fallback
                if !isnothing(javl_cd) && haskey(javl_cd, "cl_d") && ai <= length(javl_cd["cl_d"])
                    dCLh_dde_deg = javl_cd["cl_d"][ai]
                else
                    dCLh_dde_deg = CLh_alpha_deg * τ_e
                end

                if isnothing(javl_cd) || !haskey(javl_cd, "cl_d") || ai > length(javl_cd["cl_d"])
                    dCLh_dde_deg = estimate_surface_control_force_derivative_per_rad(
                        input, htail, elevator) * π / 180
                end

                CLh_base = ai <= length(CLh) ? CLh[ai] : 0.0
                row_cl = Float64[]
                row_cm = Float64[]
                row_cd = Float64[]
                for δ in delta_degs
                    # Smooth saturation using DATCOM separation angle as scale.
                    # ΔCL = (dCL/dδ) × δ_sep × (2/π) × atan(δ/δ_sep)
                    # Properties: exact linear slope dCL/dδ near δ=0, smooth rolloff
                    # around δ_sep, bounded at large deflections.  Uses only the AVL
                    # linear derivative and the DATCOM separation angle — no ad-hoc
                    # parameters.
                    dcl = dCLh_dde_deg * δ_sep_deg * (2.0 / π) * atan(δ / δ_sep_deg)
                    dcd = k_induced_h * (((CLh_base + dcl)^2) - CLh_base^2) +
                          profile_drag_gain_h * abs(δ)
                    push!(row_cl, round(dcl, digits=6))
                    push!(row_cm, round(-dcl * arm_h, digits=6))
                    push!(row_cd, round(dcd, digits=6))
                end
                push!(ΔCLh, row_cl)
                push!(ΔCm_e, row_cm)
                push!(ΔCDh, row_cd)
            end
            htp["elevator_name"]    = elevator.name
            htp["elevator_tau"]     = round(τ_e, digits=4)
            htp["delta_e_deg"]      = delta_degs
            htp["dCLh_de"]          = ΔCLh       # now 2D: [alpha][delta]
            htp["dCm_de"]           = ΔCm_e      # now 2D: [alpha][delta]
            htp["dCDh_de"]          = ΔCDh       # now 2D: [alpha][delta]
            # Linear-regime per-degree derivative at alpha≈0
            dCLh_lin = !isnothing(javl_cd) && haskey(javl_cd, "cl_d") && !isempty(javl_cd["cl_d"]) ?
                       javl_cd["cl_d"][argmin(abs.(alphas))] :
                       CLh_alpha_deg * τ_e
            if false && (isnothing(javl_cd) || !haskey(javl_cd, "cl_d") || isempty(javl_cd["cl_d"]))
                dCLh_lin = estimate_surface_control_force_derivative_per_rad(
                    input, htail, elevator) * Ï€ / 180
            end
            htp["dCLh_de_per_deg"]  = round(
                (isnothing(javl_cd) || !haskey(javl_cd, "cl_d") || isempty(javl_cd["cl_d"])) ?
                estimate_surface_control_force_derivative_per_rad(
                    input, htail, elevator) * π / 180 : dCLh_lin,
                digits=6)
            htp["dCm_de_per_deg"]   = round(
                -((isnothing(javl_cd) || !haskey(javl_cd, "cl_d") || isempty(javl_cd["cl_d"])) ?
                  estimate_surface_control_force_derivative_per_rad(
                      input, htail, elevator) * π / 180 : dCLh_lin) * arm_h,
                digits=6)
            alpha0_idx = argmin(abs.(alphas))
            delta0_idx = argmin(abs.(delta_degs))
            delta_pos_idx = findfirst(d -> d > delta_degs[delta0_idx], delta_degs)
            htp["dCDh_de_per_deg"] = if !isnothing(delta_pos_idx)
                round((ΔCDh[alpha0_idx][delta_pos_idx] - ΔCDh[alpha0_idx][delta0_idx]) /
                      abs(delta_degs[delta_pos_idx] - delta_degs[delta0_idx]), digits=6)
            else
                0.0
            end
        end
    end
    ta["HTP"] = htp

    # ---- VTP ----
    vtp = Dict{String,Any}()
    vtail = nothing
    for s in input.lifting_surfaces
        if s.role == "vertical_stabilizer"
            vtail = s
            break
        end
    end

    if !isnothing(vtail)
        wp_v = wing_planform(vtail)
        AR_v = vtail.AR
        Sv   = vtail.surface_area_m2
        eta_v = Sv / Sref

        # Isolated VTP side-force slope (Helmbold, per radian)
        a_v_rad = 2π * AR_v / (2 + sqrt(4 + AR_v^2))
        CYv_beta_rad = -a_v_rad * eta_v   # negative: +β → leftward force
        CYv_beta_deg = CYv_beta_rad * π / 180

        # VTP stall from DATCOM (treating β as VTP's effective AoA)
        v_stall = datcom_wing_clmax(input, vtail; mach=mach_ref, altitude_m=alt_m)
        β_stall_rad = deg2rad(v_stall.alpha_stall_pos_deg)
        CY_max_v = v_stall.CL_max * eta_v   # referenced to Sref
        CD90_v = 1.98 * eta_v

        # CYv(β) with stall / cross-flow
        CYv = Float64[]
        for β in betas
            β_rad = deg2rad(β)
            # VTP side force must remain restoring in the rear quadrants.
            cy = tail_stall_sideforce(β_rad, CYv_beta_rad, CY_max_v, β_stall_rad, CD90_v)
            push!(CYv, round(cy, digits=6))
        end
        vtp["betas_deg"]         = collect(Float64, betas)
        vtp["CYv"]               = CYv
        vtp["CYv_beta_per_deg"]  = round(CYv_beta_deg, digits=6)
        vtp["beta_stall_deg"]    = round(v_stall.alpha_stall_pos_deg, digits=2)
        vtp["CYv_max"]           = round(CY_max_v, digits=4)
        vtp["reference_area_kind"] = "aircraft_Sref"
        vtp["reference_area_m2"] = round(Sref, digits=4)
        vtp["surface_area_m2"] = round(Sv, digits=4)
        vtp["area_ratio_to_sref"] = round(eta_v, digits=4)

        # Moment arm: VTP AC to CG
        x_vtail_ac = vtail.root_LE[1] + 0.25 * wp_v.mac
        arm_v = (x_vtail_ac - cg_x) / bref
        vtp["moment_arm_over_bref"] = round(arm_v, digits=4)

        # Cn_VTP(β) = −CYv(β) × arm_v
        Cn_VTP = [round(-CYv[i] * arm_v, digits=6) for i in eachindex(CYv)]
        vtp["Cn_due_to_VTP"] = Cn_VTP

        # ---- Rudder control derivative ----
        # Source priority: AVL (JAVL) control derivatives → DATCOM flap τ fallback
        # Case-insensitive match on `type` (see elevator loop above for why).
        rudder = nothing
        for cs in vtail.control_surfaces
            if lowercase(string(cs.type)) == "rudder"
                rudder = cs
                break
            end
        end
        if !isnothing(rudder)
            τ_r = datcom_flap_tau(rudder.chord_fraction)
            δ_min = rudder.deflection_range_DEG[1]
            δ_max = rudder.deflection_range_DEG[2]
            δ_step = 1.0
            delta_degs = collect(Float64, δ_min:δ_step:δ_max)

            # DATCOM flow-separation angle for the rudder plain flap
            δ_sep_deg = 12.0 + 12.0 * clamp(rudder.chord_fraction, 0.0, 0.5)
            δ_sep_rad = deg2rad(δ_sep_deg)

            # Try JAVL linear derivative dCY/dδ (per degree)
            # JAVL runs at β=0 so this gives the rudder effectiveness at zero sideslip;
            # the rate is approximately constant with β in the linear regime.
            javl = get(results, "javl", nothing)
            javl_cd = nothing
            if !isnothing(javl)
                javl_cds = get(javl, "control_derivatives", Dict())
                javl_cd = get(javl_cds, rudder.name, nothing)
            end

            CYv_dr_lin = estimate_surface_control_force_derivative_per_rad(
                input, vtail, rudder) * π / 180

            ΔCYv = Float64[]
            ΔCn_r = Float64[]
            ΔCDv = Float64[]
            e_v = clamp(vtail.Oswald_factor, 0.55, 0.95)
            k_side_v = 1.0 / (π * max(AR_v, 0.3) * e_v * max(eta_v, 1e-3))
            profile_drag_gain_v = 1.2e-5 * rudder.chord_fraction *
                                  max(1.0, control_surface_span_fraction(rudder) / 0.35)
            for δ in delta_degs
                # JAVL gives dCY/dδ per degree at alpha≈0 (single value, weak alpha dependence for VTP)
                if !isnothing(javl_cd) && haskey(javl_cd, "cy_d") && !isempty(javl_cd["cy_d"])
                    dCYv_ddr_deg = javl_cd["cy_d"][argmin(abs.(alphas))]
                else
                    dCYv_ddr_deg = CYv_dr_lin
                end
                # Smooth saturation: linear near δ=0, rolls off around δ_sep
                dcy = dCYv_ddr_deg * δ_sep_deg * (2.0 / π) * atan(δ / δ_sep_deg)
                dcd = k_side_v * dcy^2 + profile_drag_gain_v * abs(δ)
                push!(ΔCYv, round(dcy, digits=6))
                push!(ΔCn_r, round(-dcy * arm_v, digits=6))
                push!(ΔCDv, round(dcd, digits=6))
            end
            vtp["rudder_name"]      = rudder.name
            vtp["rudder_tau"]       = round(τ_r, digits=4)
            vtp["delta_r_deg"]      = delta_degs
            vtp["dCYv_dr"]          = ΔCYv
            vtp["dCn_dr"]           = ΔCn_r
            vtp["dCDv_dr"]          = ΔCDv
            # Linear-regime per-degree derivative
            dCYv_lin = !isnothing(javl_cd) && haskey(javl_cd, "cy_d") && !isempty(javl_cd["cy_d"]) ?
                       javl_cd["cy_d"][argmin(abs.(alphas))] :
                       CYv_dr_lin
            vtp["dCYv_dr_per_deg"]  = round(dCYv_lin, digits=6)
            vtp["dCn_dr_per_deg"]   = round(-dCYv_lin * arm_v, digits=6)
            delta0_idx = argmin(abs.(delta_degs))
            delta_pos_idx = findfirst(d -> d > delta_degs[delta0_idx], delta_degs)
            vtp["dCDv_dr_per_deg"] = if !isnothing(delta_pos_idx)
                round((ΔCDv[delta_pos_idx] - ΔCDv[delta0_idx]) /
                      abs(delta_degs[delta_pos_idx] - delta_degs[delta0_idx]), digits=6)
            else
                0.0
            end
        end
    end
    ta["VTP"] = vtp

    return ta
end

# ================================================================
# Runtime Model Export Data
# ================================================================

"""
    build_runtime_model(input, results, aero, tail_aero, alphas, betas, machs, configs) -> Dict

Builds the `runtime_model` section containing the reduced-order scalars,
reference points, and helper tables that the simulator consumes directly.
- `CD0_table`: parasite drag (total CD minus induced drag)
- `tail_CL`: 1D tail CL vs alpha (from htail per-surface data or geometry estimate)
- `tail_CS`: 1D tail CS vs beta (from vtail per-surface data or geometry estimate)
- scalar derivatives at alpha ≈ 0° for the linear runtime path
"""
function build_runtime_model(input::AircraftInput, results::Dict, aero::Dict,
    tail_aero::Dict{String,Any},
    alphas::Vector{Float64}, betas::Vector{Float64},
    machs::Vector{Float64}, configs::Vector{String})
    runtime_model = Dict{String,Any}()

    # ---- CD0 table: CD_total - CL²/(π·AR·e) ----
    runtime_model["CD0_table"] = build_CD0_table(input, aero, alphas, betas, machs, configs)

    # ---- Tail coefficient tables from per-surface data ----
    # Use VLM-range axes (per_surface_data hasn't been extended to full envelope)
    vlm_psd = nothing
    vlm = get(results, "vlm", nothing)
    if !isnothing(vlm)
        vlm_psd = get(vlm, "per_surface_data", nothing)
    end
    psd_alphas = !isnothing(vlm) ? Float64.(get(vlm, "vlm_alphas_deg", alphas)) : alphas
    psd_betas = !isnothing(vlm) ? Float64.(get(vlm, "vlm_betas_deg", betas)) : betas

    # Build tail coefficient tables, incorporating control deflection axes
    # when elevator/rudder data is available from the isolated-tail model.
    runtime_model["tail_CL"] = build_tail_CL_from_surfaces(input, vlm_psd, psd_alphas, psd_betas, tail_aero)
    runtime_model["tail_CS"] = build_tail_CS_from_surfaces(input, vlm_psd, psd_alphas, psd_betas, tail_aero)

    # Scalar stability derivatives for the LINEAR aero model.
    # These are finite-difference slopes of the full-envelope tables at
    # α ≈ 0, β ≈ 0, M = first Mach. The table-mode path never sees them
    # because they live under `runtime_model` which the coefficient
    # lookup engine does NOT search for table data.
    # The simulator's 0.1 data loader reads them via `fetch_optional_constant`
    # which does search this section for plain scalars.
    scalars = extract_scalar_derivatives(input, aero, alphas, betas)
    for (k, v) in scalars
        runtime_model[k] = v
    end

    # ---- Computed Stall Parameters ----
    # These were previously user-provided in ac_data.yaml; now computed from
    # geometry by compute_aircraft_stall() so ac_data stays geometry-only.
    mach_ref_leg = isempty(machs) ? 0.2 : machs[1]
    stall_leg = compute_aircraft_stall(input; mach=mach_ref_leg,
                                       altitude_m=input.analysis.altitude_m)
    runtime_model["alpha_stall_positive"] = Float64(stall_leg["alpha_stall_positive"])
    runtime_model["alpha_stall_negative"] = Float64(stall_leg["alpha_stall_negative"])
    runtime_model["CL_max"]              = Float64(stall_leg["CL_max"])
    if input.general.mass_kg > 0.0 && input.general.Sref > 0.0 && runtime_model["CL_max"] > 0.1
        rho_sl = _isa_density_kg_m3(0.0)
        rho_analysis = _isa_density_kg_m3(input.analysis.altitude_m)
        stall_sl = sqrt(2.0 * input.general.mass_kg * 9.80665 /
                        (rho_sl * input.general.Sref * runtime_model["CL_max"]))
        stall_analysis = sqrt(2.0 * input.general.mass_kg * 9.80665 /
                              (rho_analysis * input.general.Sref * runtime_model["CL_max"]))
        runtime_model["stall_speed_sea_level_m_s"] = round(stall_sl, digits=2)
        runtime_model["stall_speed_analysis_altitude_m_s"] = round(stall_analysis, digits=2)
        runtime_model["recommended_initial_velocity_m_s"] = round(1.3 * stall_analysis, digits=2)
    end
    # CD0 already set by extract_scalar_derivatives from tables; use stall
    # estimate only as fallback when tables didn't produce one.
    if !haskey(runtime_model, "CD0")
        runtime_model["CD0"] = Float64(stall_leg["CD0"])
    end

    # ---- Computed Dynamic Stall Parameters ----
    α_stall_abs = max(abs(runtime_model["alpha_stall_positive"]),
                      abs(runtime_model["alpha_stall_negative"]))
    runtime_model["dynamic_stall_alpha_on_deg"]      = round(α_stall_abs, digits=1)
    runtime_model["dynamic_stall_alpha_off_deg"]      = round(max(α_stall_abs - 4.0, 0.0), digits=1)
    runtime_model["dynamic_stall_tau_alpha_s"]        = 0.08
    runtime_model["dynamic_stall_tau_sigma_rise_s"]   = 0.12
    runtime_model["dynamic_stall_tau_sigma_fall_s"]   = 0.35
    runtime_model["dynamic_stall_qhat_to_alpha_deg"]  = 2.0
    runtime_model["poststall_cl_scale"]               = 1.1
    runtime_model["poststall_cd90"]                   = Float64(get(stall_leg, "CD90", 1.6))
    runtime_model["poststall_cd_min"]                 = Float64(get(stall_leg, "CD0", 0.08))
    runtime_model["poststall_sideforce_scale"]        = begin
        stype = get(stall_leg, "wing_stall_type", "combined")
        stype == "trailing_edge" ? 0.85 : (stype == "combined" ? 0.75 : 0.60)
    end

    # ---- Computed Tail Aerodynamic Properties ----
    # Derived from tail geometry so the user doesn't have to supply them.
    htail_leg = nothing
    vtail_leg = nothing
    wing_leg  = nothing
    for s in input.lifting_surfaces
        s.role == "wing" && isnothing(wing_leg) && (wing_leg = s)
        s.role == "horizontal_stabilizer" && isnothing(htail_leg) && (htail_leg = s)
        (s.role == "vertical_stabilizer" || s.vertical) && isnothing(vtail_leg) && (vtail_leg = s)
    end
    Sref_leg = input.general.Sref
    cref_leg = input.general.cref
    bref_leg = input.general.bref

    # tail_CL_q: legacy scalar reference for HTP pitch damping.
    # Table-mode OpenFlight now gets tail damping from local tail flow
    # (delta alpha ≈ q*l/V) plus the current CG lever arm in r × F, so this
    # export is kept mainly for backward compatibility and linearized-data
    # inspection.
    if !isnothing(htail_leg)
        wp_h = wing_planform(htail_leg)
        sweep_h = deg2rad(htail_leg.sweep_quarter_chord_DEG)
        CLa_h = 2π * htail_leg.AR / (2 + sqrt(4 + htail_leg.AR^2 * (1 + tan(sweep_h)^2)))
        l_h = htail_leg.root_LE[1] - input.general.CoG[1]  # moment arm
        eta_h = htail_leg.surface_area_m2 / Sref_leg
        runtime_model["tail_CL_q"] = round(CLa_h * eta_h * l_h / cref_leg, digits=3)
    else
        runtime_model["tail_CL_q"] = 3.0
    end

    # tail_CS_r: legacy scalar reference for VTP yaw damping.
    # Table-mode OpenFlight now gets tail damping from local tail flow
    # (delta beta ≈ r*l/V) plus the current CG lever arm in r × F, so this
    # export is kept mainly for backward compatibility and linearized-data
    # inspection.
    if !isnothing(vtail_leg)
        sweep_v = deg2rad(vtail_leg.sweep_quarter_chord_DEG)
        CLa_v = 2π * vtail_leg.AR / (2 + sqrt(4 + vtail_leg.AR^2 * (1 + tan(sweep_v)^2)))
        l_v = vtail_leg.root_LE[1] - input.general.CoG[1]
        eta_v = vtail_leg.surface_area_m2 / Sref_leg
        runtime_model["tail_CS_r"] = round(CLa_v * eta_v * l_v / bref_leg, digits=3)
    else
        runtime_model["tail_CS_r"] = 0.5
    end

    # tail_CD0, tail_k_induced, tail_k_side: estimated from tail geometry
    tail_Swet = 0.0
    if !isnothing(htail_leg); tail_Swet += htail_leg.surface_area_m2 * 2.0; end
    if !isnothing(vtail_leg); tail_Swet += vtail_leg.surface_area_m2 * 2.0; end
    # Cf ≈ 0.003 for typical Re, form factor ≈ 1.1
    runtime_model["tail_CD0"]       = round(0.003 * 1.1 * tail_Swet / max(Sref_leg, 0.01), digits=4)
    runtime_model["tail_k_induced"] = 0.2   # typical induced drag factor
    runtime_model["tail_k_side"]    = 0.1   # typical lateral drag factor

    # Tail-only static stability contributions, used by the simulator's
    # linear aero model to keep ELEVATOR / RUDDER authority physically
    # proportional to TAIL stability. Without this, an aircraft whose
    # CG sits aft of the wing AC has its wing+body destabilising
    # contribution cancel most of the tail's stabilising contribution
    # — leaving a TOTAL Cm_α much weaker than the tail's own Cm_α
    # while Cm_δe still reflects the FULL tail authority. The pilot
    # then trivially overcomes static stiffness with a stick input.
    #
    # These derivatives are GEOMETRIC (no VLM dependence): they capture
    # what the isolated tail surface would contribute if mounted at the
    # current CG. Cm_α_tail · α_max_useful tells the simulator the
    # ceiling on how much pitching moment the elevator can ever produce
    # before its underlying physical mechanism (HTP lift) saturates.
    #
    # Reference: Etkin & Reid §6.3 (tail volume coefficient form).
    if !isnothing(htail_leg)
        sweep_h = deg2rad(htail_leg.sweep_quarter_chord_DEG)
        CLa_h_rad = 2π * htail_leg.AR / (2 + sqrt(4 + htail_leg.AR^2 * (1 + tan(sweep_h)^2)))
        eta_h_area = htail_leg.surface_area_m2 / Sref_leg
        # HTP arm at the current CG, in chord units
        wp_h_local = wing_planform(htail_leg)
        y_mac_h = wp_h_local.span / 6 * (1 + 2 * htail_leg.TR) / (1 + htail_leg.TR)
        x_mac_le_h = htail_leg.root_LE[1] + y_mac_h * tan(wp_h_local.sweep_le)
        x_ac_h = x_mac_le_h + 0.25 * wp_h_local.mac
        arm_h_over_c = (x_ac_h - input.general.CoG[1]) / cref_leg
        # Downwash damping factor: the wing wake reduces the effective
        # angle the tail sees by ~30% for a conventional layout. Use
        # 0.70 as a conservative default; backends may override later.
        eta_dynamic_pressure_h = 0.90
        one_minus_deps_dalpha = 0.70
        runtime_model["Cm_alpha_tail_only"] = round(
            -CLa_h_rad * eta_h_area * arm_h_over_c *
            eta_dynamic_pressure_h * one_minus_deps_dalpha,
            digits=4)
    else
        runtime_model["Cm_alpha_tail_only"] = -1.0   # conservative default
    end

    if !isnothing(vtail_leg)
        sweep_v = deg2rad(vtail_leg.sweep_quarter_chord_DEG)
        CLa_v_rad = 2π * vtail_leg.AR / (2 + sqrt(4 + vtail_leg.AR^2 * (1 + tan(sweep_v)^2)))
        eta_v_area = vtail_leg.surface_area_m2 / Sref_leg
        wp_v_local = wing_planform(vtail_leg)
        y_mac_v = wp_v_local.span / 6 * (1 + 2 * vtail_leg.TR) / (1 + vtail_leg.TR)
        x_mac_le_v = vtail_leg.root_LE[1] + y_mac_v * tan(wp_v_local.sweep_le)
        x_ac_v = x_mac_le_v + 0.25 * wp_v_local.mac
        arm_v_over_b = (x_ac_v - input.general.CoG[1]) / bref_leg
        eta_dynamic_pressure_v = 0.95
        one_minus_dsigma_dbeta = 0.85
        runtime_model["Cn_beta_vtp_only"] = round(
            CLa_v_rad * eta_v_area * arm_v_over_b *
            eta_dynamic_pressure_v * one_minus_dsigma_dbeta,
            digits=4)
    else
        runtime_model["Cn_beta_vtp_only"] = 0.10   # conservative default
    end

    # ---- Runtime reference points and scalar constants ----
    constants = Dict{String,Any}()

    # Base wing geometric properties
    wing = isempty(input.lifting_surfaces) ? nothing : nothing
    for s in input.lifting_surfaces
        if s.role == "wing"
            wing = s
            break
        end
    end

    if !isnothing(wing)
        constants["Oswald_factor"] = wing.Oswald_factor
        # Wing AC at 25% MAC, accounting for taper-induced sweep of the MAC LE
        wp_wing = wing_planform(wing)
        y_mac = wp_wing.span / 6 * (1 + 2 * wing.TR) / (1 + wing.TR)
        x_mac_le = wing.root_LE[1] + y_mac * tan(wp_wing.sweep_le)
        constants["x_wing_aerodynamic_center"] = x_mac_le + 0.25 * wp_wing.mac
        constants["y_wing_aerodynamic_center"] = wing.root_LE[2]
        constants["z_wing_aerodynamic_center"] = wing.root_LE[3]
        constants["x_wing_fuselage_aerodynamic_center"] = constants["x_wing_aerodynamic_center"] - 0.1 # slightly ahead
        constants["y_wing_fuselage_aerodynamic_center"] = 0.0
        constants["z_wing_fuselage_aerodynamic_center"] = constants["z_wing_aerodynamic_center"]
    else
        constants["Oswald_factor"] = 0.8
        constants["x_wing_aerodynamic_center"] = input.general.CoG[1]
        constants["y_wing_aerodynamic_center"] = 0.0
        constants["z_wing_aerodynamic_center"] = 0.0
        constants["x_wing_fuselage_aerodynamic_center"] = input.general.CoG[1]
        constants["y_wing_fuselage_aerodynamic_center"] = 0.0
        constants["z_wing_fuselage_aerodynamic_center"] = 0.0
    end

    split_src, _ = pick_split_source(results)
    wing_body_ref_xyz = copy(input.general.CoG)
    if !isnothing(split_src) && haskey(split_src, "wing_body")
        wb_ref = get(split_src["wing_body"], "reference_point_m", nothing)
        if wb_ref isa AbstractDict
            xyz = get(wb_ref, "xyz_m", nothing)
            if xyz isa AbstractVector && length(xyz) >= 3
                wing_body_ref_xyz = [Float64(xyz[1]), Float64(xyz[2]), Float64(xyz[3])]
            end
        end
    end
    constants["x_wing_body_neutral_point"] = wing_body_ref_xyz[1]
    constants["y_wing_body_neutral_point"] = wing_body_ref_xyz[2]
    constants["z_wing_body_neutral_point"] = wing_body_ref_xyz[3]
    constants["x_wing_fuselage_aerodynamic_center"] = wing_body_ref_xyz[1]
    constants["y_wing_fuselage_aerodynamic_center"] = wing_body_ref_xyz[2]
    constants["z_wing_fuselage_aerodynamic_center"] = wing_body_ref_xyz[3]
    constants["x_aero_reference_CoG"] = input.general.CoG[1]
    constants["y_aero_reference_CoG"] = input.general.CoG[2]
    constants["z_aero_reference_CoG"] = input.general.CoG[3]

    # Tail geometric properties
    htail = nothing
    vtail = nothing
    for s in input.lifting_surfaces
        if s.role == "horizontal_stabilizer"
            htail = s
        elseif s.role == "vertical_stabilizer"
            vtail = s
        end
    end

    htail_area = isnothing(htail) ? 0.0 : htail.surface_area_m2
    vtail_area = isnothing(vtail) ? 0.0 : vtail.surface_area_m2
    total_tail_area = htail_area + vtail_area
    constants["horizontal_tail_reference_area"] = htail_area
    constants["vertical_tail_reference_area"] = vtail_area

    if !isnothing(htail)
        constants["tail_reference_area"] = total_tail_area > 0.01 ? total_tail_area : htail_area
        constants["x_tail_aerodynamic_center"] = htail.root_LE[1] + wing_planform(htail).root_chord * 0.25
        constants["y_tail_aerodynamic_center"] = htail.root_LE[2]
        constants["z_tail_aerodynamic_center"] = htail.root_LE[3]
        constants["x_horizontal_tail_aerodynamic_center"] = constants["x_tail_aerodynamic_center"]
        constants["y_horizontal_tail_aerodynamic_center"] = constants["y_tail_aerodynamic_center"]
        constants["z_horizontal_tail_aerodynamic_center"] = constants["z_tail_aerodynamic_center"]
    else
        constants["tail_reference_area"] = total_tail_area > 0.01 ? total_tail_area : input.general.Sref * 0.2
        constants["x_tail_aerodynamic_center"] = input.general.CoG[1] + 3.0
        constants["y_tail_aerodynamic_center"] = 0.0
        constants["z_tail_aerodynamic_center"] = 0.0
        constants["x_horizontal_tail_aerodynamic_center"] = constants["x_tail_aerodynamic_center"]
        constants["y_horizontal_tail_aerodynamic_center"] = 0.0
        constants["z_horizontal_tail_aerodynamic_center"] = 0.0
    end

    if !isnothing(vtail)
        constants["x_vertical_tail_aerodynamic_center"] = vtail.root_LE[1] + wing_planform(vtail).root_chord * 0.25
        constants["y_vertical_tail_aerodynamic_center"] = vtail.root_LE[2]
        constants["z_vertical_tail_aerodynamic_center"] = vtail.root_LE[3]
    else
        constants["x_vertical_tail_aerodynamic_center"] = constants["x_tail_aerodynamic_center"]
        constants["y_vertical_tail_aerodynamic_center"] = 0.0
        constants["z_vertical_tail_aerodynamic_center"] = 0.0
    end

    runtime_model["constants"] = constants

    return runtime_model
end

"""
Separate parasite drag: CD0 = CD - CL²/(π·AR·e)
"""
function build_CD0_table(input::AircraftInput, aero::Dict, alphas, betas, machs, configs)
    sc = get(aero, "static_coefficients", Dict())
    CL_data = get(get(sc, "CL", Dict()), "values", nothing)
    CD_data = get(get(sc, "CD", Dict()), "values", nothing)

    if isnothing(CL_data) || isnothing(CD_data)
        return Dict("alphas_deg" => alphas, "betas_deg" => betas, "values" => nothing)
    end

    # Use first wing's AR and Oswald, or reference geometry
    AR = input.general.bref^2 / max(input.general.Sref, 0.01)
    e = 0.8
    for surf in input.lifting_surfaces
        if surf.role == "wing"
            AR = surf.AR
            e = surf.Oswald_factor
            break
        end
    end

    cfg = isempty(configs) ? "clean" : configs[1]
    CL_cfg = get(CL_data, cfg, nothing)
    CD_cfg = get(CD_data, cfg, nothing)

    if isnothing(CL_cfg) || isnothing(CD_cfg)
        return Dict("alphas_deg" => alphas, "betas_deg" => betas, "values" => nothing)
    end

    # CL_cfg and CD_cfg are nested: [mach_idx][alpha_idx][beta_idx]
    # Use first Mach for the CD0 table
    mi = 1
    CL_mach = length(CL_cfg) >= mi ? CL_cfg[mi] : nothing
    CD_mach = length(CD_cfg) >= mi ? CD_cfg[mi] : nothing

    if isnothing(CL_mach) || isnothing(CD_mach)
        return Dict("alphas_deg" => alphas, "betas_deg" => betas, "values" => nothing)
    end

    # Build CD0[alpha][beta] array
    CD0_arr = []
    for (ai, _) in enumerate(alphas)
        beta_row = Float64[]
        CL_row = ai <= length(CL_mach) ? CL_mach[ai] : zeros(length(betas))
        CD_row = ai <= length(CD_mach) ? CD_mach[ai] : zeros(length(betas))
        for (bi, _) in enumerate(betas)
            cl = bi <= length(CL_row) ? CL_row[bi] : 0.0
            cd = bi <= length(CD_row) ? CD_row[bi] : 0.0
            cd0 = cd - cl^2 / (π * AR * e)
            push!(beta_row, round(max(cd0, 0.001), digits=5))  # floor at small positive
        end
        push!(CD0_arr, beta_row)
    end

    return Dict("alphas_deg" => alphas, "betas_deg" => betas, "values" => CD0_arr)
end

"""
Build tail_CL table (CL vs alpha, optionally vs elevator_deg) from horizontal stabilizer.
When elevator deflection data is available from tail_aerodynamics (AVL+DATCOM),
produces a 2D table tail_CL(alpha, elevator_deg). Otherwise 1D tail_CL(alpha).
IMPORTANT: Coefficients referenced to combined tail_reference_area (HTP + VTP),
scaled by S_htail / S_tail_total so simulator force = q × S_tail_total × tail_CL is correct.
"""
function build_tail_CL_from_surfaces(input::AircraftInput, vlm_psd, alphas, betas,
                                     tail_aero::Dict{String,Any}=Dict{String,Any}())
    htail_area = 0.0
    for surf in input.lifting_surfaces
        if surf.role == "horizontal_stabilizer"
            htail_area += surf.surface_area_m2
        end
    end

    # Find beta ≈ 0 index
    beta0_idx = 1
    for (bi, b) in enumerate(betas)
        if abs(b) < abs(betas[beta0_idx])
            beta0_idx = bi
        end
    end

    # ---- Step 1: Build 1D baseline tail_cl(alpha) at zero deflection ----
    tail_cl_1d = nothing
    source = "none"

    # Try VLM per-surface data first
    if !isnothing(vlm_psd)
        for surf in input.lifting_surfaces
            surf.role != "horizontal_stabilizer" && continue
            sd = get(vlm_psd, surf.name, nothing)
            isnothing(sd) && continue
            CL_mat = get(sd, "CL", nothing)
            if !isnothing(CL_mat) && ndims(CL_mat) == 2
                tail_cl_1d = Float64[]
                scale_to_surface = input.general.Sref / max(surf.surface_area_m2, 1e-3)
                for ai in 1:size(CL_mat, 1)
                    bi = min(beta0_idx, size(CL_mat, 2))
                    push!(tail_cl_1d, CL_mat[ai, bi] * scale_to_surface)
                end
                source = "vlm_per_surface"
                break
            end
        end
    end

    # Fallback: DATCOM-based HTP lift with stall
    if isnothing(tail_cl_1d)
        mach_ref = isempty(input.analysis.mach_values) ? 0.2 : input.analysis.mach_values[1]
        alt_m    = input.analysis.altitude_m
        for surf in input.lifting_surfaces
            surf.role != "horizontal_stabilizer" && continue
            AR_h = surf.AR
            CL_alpha_rad = 2π * AR_h / (2 + sqrt(4 + AR_h^2))   # Helmbold (DATCOM)
            h_stall = datcom_wing_clmax(input, surf; mach=mach_ref, altitude_m=alt_m)
            α_stall_rad = deg2rad(h_stall.alpha_stall_pos_deg)
            CL_max_h = h_stall.CL_max
            CD90_h = 1.98
            max_camber = surf.airfoil.root_max_camber
            α_offset = -2.0 * max_camber + deg2rad(surf.incidence_DEG)
            tail_cl_1d = Float64[]
            for a in alphas
                α_eff = deg2rad(a) + α_offset
                cl = tail_stall_CL(α_eff, CL_alpha_rad, CL_max_h, α_stall_rad, CD90_h)
                push!(tail_cl_1d, cl)
            end
            source = "datcom_estimate"
            break
        end
    end

    if isnothing(tail_cl_1d)
        tail_cl_1d = zeros(length(alphas))
    end

    # ---- Step 2: Add elevator deflection axis if data available ----
    htp_data = get(tail_aero, "HTP", Dict{String,Any}())
    delta_e_degs = get(htp_data, "delta_e_deg", nothing)
    dCLh_de_2d   = get(htp_data, "dCLh_de", nothing)

    if !isnothing(delta_e_degs) && !isnothing(dCLh_de_2d) && !isempty(delta_e_degs)
        sref = input.general.Sref
        scale_to_surface = sref / max(htail_area, 1e-3)

        values_2d = Vector{Vector{Float64}}()
        for (ai, _) in enumerate(alphas)
            row = Float64[]
            for (di, _) in enumerate(delta_e_degs)
                # Baseline + increment
                base = tail_cl_1d[ai]
                # dCLh_de_2d may be 2D [alpha][delta] or 1D [delta] (legacy)
                if dCLh_de_2d isa Vector{<:Vector} && ai <= length(dCLh_de_2d) && di <= length(dCLh_de_2d[ai])
                    delta_cl = dCLh_de_2d[ai][di] * scale_to_surface
                elseif dCLh_de_2d isa Vector{<:Number} && di <= length(dCLh_de_2d)
                    delta_cl = dCLh_de_2d[di] * scale_to_surface
                else
                    delta_cl = 0.0
                end
                push!(row, round(base + delta_cl, digits=5))
            end
            push!(values_2d, row)
        end
        return Dict(
            "alphas_deg" => alphas,
            "delta_e_deg" => collect(Float64, delta_e_degs),
            "axis_order" => ["alpha_deg", "elevator_deg"],
            "axes" => Dict("alpha_deg" => alphas, "elevator_deg" => collect(Float64, delta_e_degs)),
            "values" => values_2d,
            "source" => source * "+avl_elevator",
            "reference_area_kind" => "surface_area"
        )
    end

    # No elevator data — return 1D table
    return Dict(
        "alphas_deg" => alphas,
        "axis_order" => ["alpha_deg"],
        "axes" => Dict("alpha_deg" => alphas),
        "values" => [round(v, digits=5) for v in tail_cl_1d],
        "source" => source,
        "reference_area_kind" => "surface_area"
    )
end

"""
Build tail_CS table (side-force coeff vs beta, optionally vs rudder_deg) from vertical stabilizer.
When rudder deflection data is available from tail_aerodynamics (AVL+DATCOM),
produces a 2D table tail_CS(beta, rudder_deg). Otherwise 1D tail_CS(beta).
IMPORTANT: Coefficients referenced to combined tail_reference_area (HTP + VTP),
scaled by S_vtail / S_tail_total so simulator force = q × S_tail_total × CS is correct.
"""
function build_tail_CS_from_surfaces(input::AircraftInput, vlm_psd, alphas, betas,
                                     tail_aero::Dict{String,Any}=Dict{String,Any}())
    vtail_area = 0.0
    for surf in input.lifting_surfaces
        if surf.role == "vertical_stabilizer"
            vtail_area += surf.surface_area_m2
        end
    end

    # Find alpha ≈ 0 index
    alpha0_idx = 1
    for (ai, a) in enumerate(alphas)
        if abs(a) < abs(alphas[alpha0_idx])
            alpha0_idx = ai
        end
    end

    # ---- Step 1: Build 1D baseline tail_cs(beta) at zero deflection ----
    tail_cs_1d = nothing
    source = "none"

    # Try VLM per-surface data first
    if !isnothing(vlm_psd)
        for surf in input.lifting_surfaces
            surf.role != "vertical_stabilizer" && continue
            sd = get(vlm_psd, surf.name, nothing)
            isnothing(sd) && continue
            CY_mat = get(sd, "CY", nothing)
            if !isnothing(CY_mat) && ndims(CY_mat) == 2
                tail_cs_1d = Float64[]
                ai = min(alpha0_idx, size(CY_mat, 1))
                scale_to_surface = input.general.Sref / max(surf.surface_area_m2, 1e-3)
                for bi in 1:size(CY_mat, 2)
                    push!(tail_cs_1d, CY_mat[ai, bi] * scale_to_surface)
                end
                source = "vlm_per_surface"
                break
            end
        end
    end

    # Fallback: DATCOM-based VTP side-force with stall, scaled to tail_reference_area
    if isnothing(tail_cs_1d)
        mach_ref = isempty(input.analysis.mach_values) ? 0.2 : input.analysis.mach_values[1]
        alt_m    = input.analysis.altitude_m
        for surf in input.lifting_surfaces
            surf.role != "vertical_stabilizer" && continue
            AR_v = surf.AR
            CY_beta_rad = -2π * AR_v / (2 + sqrt(4 + AR_v^2))   # +β -> restoring (negative CY)
            v_stall = datcom_wing_clmax(input, surf; mach=mach_ref, altitude_m=alt_m)
            β_stall_rad = deg2rad(v_stall.alpha_stall_pos_deg)
            CY_max_v = abs(v_stall.CL_max)
            CD90_v = 1.98
            tail_cs_1d = Float64[]
            for b in betas
                β_rad = deg2rad(b)
                cy = tail_stall_sideforce(β_rad, CY_beta_rad, CY_max_v, β_stall_rad, CD90_v)
                push!(tail_cs_1d, cy)
            end
            source = "datcom_estimate"
            break
        end
    end

    if isnothing(tail_cs_1d)
        tail_cs_1d = zeros(length(betas))
    end

    # ---- Step 2: Add rudder deflection axis if data available ----
    vtp_data = get(tail_aero, "VTP", Dict{String,Any}())
    delta_r_degs = get(vtp_data, "delta_r_deg", nothing)
    dCYv_dr      = get(vtp_data, "dCYv_dr", nothing)

    if !isnothing(delta_r_degs) && !isnothing(dCYv_dr) && !isempty(delta_r_degs)
        sref = input.general.Sref
        scale_to_surface = sref / max(vtail_area, 1e-3)

        values_2d = Vector{Vector{Float64}}()
        for (bi, _) in enumerate(betas)
            row = Float64[]
            for (di, _) in enumerate(delta_r_degs)
                base = tail_cs_1d[bi]
                delta_cy = di <= length(dCYv_dr) ? dCYv_dr[di] * scale_to_surface : 0.0
                push!(row, round(base + delta_cy, digits=5))
            end
            push!(values_2d, row)
        end
        return Dict(
            "betas_deg" => betas,
            "delta_r_deg" => collect(Float64, delta_r_degs),
            "axis_order" => ["beta_deg", "rudder_deg"],
            "axes" => Dict("beta_deg" => betas, "rudder_deg" => collect(Float64, delta_r_degs)),
            "values" => values_2d,
            "source" => source * "+avl_rudder",
            "reference_area_kind" => "surface_area"
        )
    end

    # No rudder data — return 1D table
    return Dict(
        "betas_deg" => betas,
        "axis_order" => ["beta_deg"],
        "axes" => Dict("beta_deg" => betas),
        "values" => [round(v, digits=5) for v in tail_cs_1d],
        "source" => source,
        "reference_area_kind" => "surface_area"
    )
end

"""
Extract scalar stability derivatives at alpha ≈ 0° from the v2.1 aero tables.
These are used by the JS export module to populate legacy `constants` values.
"""
function extract_scalar_derivatives(input::AircraftInput, aero::Dict, alphas, betas)
    scalars = Dict{String,Float64}()

    # Find index closest to alpha = 0
    alpha0_idx = argmin(abs.(alphas))
    # Find index closest to beta = 0
    beta0_idx = argmin(abs.(betas))

    sc = get(aero, "static_coefficients", Dict())
    dd = get(aero, "dynamic_derivatives", Dict())
    dd_alphas = Float64.(get(get(dd, "axes", Dict()), "alpha_deg", alphas))
    dd_alpha0_idx = isempty(dd_alphas) ? alpha0_idx : argmin(abs.(dd_alphas))

    cfg = "clean"
    mi = 1  # first Mach index

    # ---- Static slope derivatives via finite difference ----
    # These scalars populate the LINEAR aero model (0.3_🧮_linear_aerodynamic_
    # model.jl) when no explicit scalar constants exist in the YAML. The TABLE
    # path never uses them — it reads the full coefficient tables directly.
    # Note: the old comment "set Cm_alpha/Cn_beta to 0 to avoid double-counting
    # with r×F" was correct for TABLE mode, but LINEAR mode NEEDS non-zero
    # values because it has no r×F mechanism. Since these scalars are stored
    # under `runtime_model` (which the table lookup engine does not search
    # for coefficient tables), there is no double-counting risk.

    # CL(α): lift slope and zero-α lift
    CL_vs_alpha = extract_1d_at_beta0(sc, "CL", cfg, mi, beta0_idx)
    if !isnothing(CL_vs_alpha) && length(CL_vs_alpha) > 1
        scalars["CL_0"] = alpha0_idx <= length(CL_vs_alpha) ? CL_vs_alpha[alpha0_idx] : 0.0
        scalars["CL_alpha"] = finite_diff_at(CL_vs_alpha, alphas, alpha0_idx) * (180.0 / π)
    end

    # CD0
    CD_vs_alpha = extract_1d_at_beta0(sc, "CD", cfg, mi, beta0_idx)
    if !isnothing(CD_vs_alpha) && length(CD_vs_alpha) > 1
        scalars["CD0"] = alpha0_idx <= length(CD_vs_alpha) ? CD_vs_alpha[alpha0_idx] : 0.025
    end

    # Cm(α): pitch stability slope and zero-α offset
    Cm_vals = extract_1d_at_beta0(sc, "Cm", cfg, mi, beta0_idx)
    if !isnothing(Cm_vals) && length(Cm_vals) > 1
        scalars["Cm0"] = alpha0_idx <= length(Cm_vals) ? Cm_vals[alpha0_idx] : 0.0
        scalars["Cm_alpha"] = finite_diff_at(Cm_vals, alphas, alpha0_idx) * (180.0 / π)
    end

    # CY(β): sideforce slope
    CY_vs_beta = extract_1d_at_alpha0(sc, "CY", cfg, mi, alpha0_idx)
    if !isnothing(CY_vs_beta) && length(CY_vs_beta) > 1
        scalars["CY_beta"] = finite_diff_at(CY_vs_beta, betas, beta0_idx) * (180.0 / π)
    end

    # Cl(β): dihedral effect (roll from sideslip)
    Cl_vs_beta = extract_1d_at_alpha0(sc, "Cl", cfg, mi, alpha0_idx)
    if !isnothing(Cl_vs_beta) && length(Cl_vs_beta) > 1
        scalars["Cl_beta"] = finite_diff_at(Cl_vs_beta, betas, beta0_idx) * (180.0 / π)
    end

    # Cn(β): weathercock stability (yaw from sideslip)
    Cn_vs_beta = extract_1d_at_alpha0(sc, "Cn", cfg, mi, alpha0_idx)
    if !isnothing(Cn_vs_beta) && length(Cn_vs_beta) > 1
        scalars["Cn_beta"] = finite_diff_at(Cn_vs_beta, betas, beta0_idx) * (180.0 / π)
    end

    # ---- Dynamic derivatives at alpha≈0 ----
    for dname in ["Cl_p_hat", "Cm_q_hat", "Cn_r_hat"]
        ddata = get(dd, dname, nothing)
        if isnothing(ddata)
            continue
        end
        vals_dict = get(ddata, "values", nothing)
        if isnothing(vals_dict)
            continue
        end
        cfg_vals = get(vals_dict, cfg, nothing)
        if isnothing(cfg_vals) || isempty(cfg_vals)
            continue
        end
        mach_vals = mi <= length(cfg_vals) ? cfg_vals[mi] : nothing
        if isnothing(mach_vals)
            continue
        end
        if dd_alpha0_idx <= length(mach_vals)
            scalars[dname] = mach_vals[dd_alpha0_idx]
        end
    end

    # ---- Control effectiveness at alpha≈0 ----
    ce = get(aero, "control_effectiveness", Dict())
    ce_alphas = Float64.(get(get(ce, "axes", Dict()), "alpha_deg", alphas))
    ce_alpha0_idx = isempty(ce_alphas) ? alpha0_idx : argmin(abs.(ce_alphas))
    for key in ["Cm_de_per_deg", "Cl_da_per_deg", "Cn_dr_per_deg"]
        cdata = get(ce, key, nothing)
        if isnothing(cdata)
            continue
        end
        vals_dict = get(cdata, "values", nothing)
        if isnothing(vals_dict)
            continue
        end
        cfg_vals = get(vals_dict, cfg, nothing)
        if isnothing(cfg_vals) || isempty(cfg_vals)
            continue
        end
        mach_vals = mi <= length(cfg_vals) ? cfg_vals[mi] : nothing
        if isnothing(mach_vals)
            continue
        end
        if ce_alpha0_idx <= length(mach_vals)
            scalars[key] = mach_vals[ce_alpha0_idx]
        end
    end

    return scalars
end

# ---- Helpers for scalar derivative extraction ----

"""Extract 1D coefficient array vs alpha at beta≈0 from static coefficients."""
function extract_1d_at_beta0(sc, coeff_name, cfg, mi, beta0_idx)
    cdata = get(sc, coeff_name, nothing)
    if isnothing(cdata)
        return nothing
    end
    vals_dict = get(cdata, "values", nothing)
    if isnothing(vals_dict)
        return nothing
    end
    cfg_vals = get(vals_dict, cfg, nothing)
    if isnothing(cfg_vals) || isempty(cfg_vals)
        return nothing
    end
    mach_vals = mi <= length(cfg_vals) ? cfg_vals[mi] : nothing
    if isnothing(mach_vals)
        return nothing
    end

    # mach_vals[alpha_idx][beta_idx] → extract at beta0_idx
    result = Float64[]
    for alpha_row in mach_vals
        if beta0_idx <= length(alpha_row)
            push!(result, Float64(alpha_row[beta0_idx]))
        end
    end
    return result
end

"""Extract 1D coefficient array vs beta at alpha≈0 from static coefficients."""
function extract_1d_at_alpha0(sc, coeff_name, cfg, mi, alpha0_idx)
    cdata = get(sc, coeff_name, nothing)
    if isnothing(cdata)
        return nothing
    end
    vals_dict = get(cdata, "values", nothing)
    if isnothing(vals_dict)
        return nothing
    end
    cfg_vals = get(vals_dict, cfg, nothing)
    if isnothing(cfg_vals) || isempty(cfg_vals)
        return nothing
    end
    mach_vals = mi <= length(cfg_vals) ? cfg_vals[mi] : nothing
    if isnothing(mach_vals)
        return nothing
    end

    if alpha0_idx <= length(mach_vals)
        return Float64.(mach_vals[alpha0_idx])
    end
    return nothing
end

"""Compute derivative via central finite difference at a given index."""
function finite_diff_at(values::Vector{Float64}, axis::Vector{Float64}, idx::Int)
    n = length(values)
    if n < 2 || idx < 1 || idx > n
        return 0.0
    end
    if idx == 1
        # Forward difference
        dx = axis[2] - axis[1]
        return abs(dx) > 1e-10 ? (values[2] - values[1]) / dx : 0.0
    elseif idx == n
        # Backward difference
        dx = axis[n] - axis[n-1]
        return abs(dx) > 1e-10 ? (values[n] - values[n-1]) / dx : 0.0
    else
        # Central difference
        dx = axis[idx+1] - axis[idx-1]
        return abs(dx) > 1e-10 ? (values[idx+1] - values[idx-1]) / dx : 0.0
    end
end

# ================================================================
# Visual Geometry for OpenFlight 3D Rendering
# ================================================================

"""
    build_visual_geometry(input::AircraftInput) -> Dict

Builds the `visual_geometry` section containing detailed geometric
information for each aircraft component. OpenFlight uses this data
to construct a parametric 3D model that matches the aerodynamic model,
ensuring forces are applied at the correct locations.

Coordinate system (body axes): x aft from nose, y right, z up.
All positions are relative to the aircraft origin (typically nose or CoG).
"""
function build_visual_geometry(input::AircraftInput)
    vg = Dict{String,Any}()

    # ---- Coordinate system and reference ----
    # Model Creator geometry uses x increasing from nose toward tail and z up.
    # Emit that explicitly so runtime visualizers can convert it to their
    # local forward-positive convention without relying on heuristics.
    vg["coordinate_system"] = "x_aft_y_right_z_up"
    vg["cg_position_m"] = Dict(
        "x" => input.general.CoG[1],
        "y" => input.general.CoG[2],
        "z" => length(input.general.CoG) >= 3 ? input.general.CoG[3] : 0.0
    )
    vg["reference_span_m"] = input.general.bref
    vg["reference_chord_m"] = input.general.cref

    # ---- Lifting surfaces ----
    surfaces = []
    for surf in input.lifting_surfaces
        pf = wing_planform(surf)
        panel_span = surf.vertical ? pf.span : pf.semi_span
        root_x = surf.root_LE[1]
        root_y = surf.root_LE[2]
        root_z = length(surf.root_LE) >= 3 ? surf.root_LE[3] : 0.0
        sd = Dict{String,Any}()
        sd["name"] = surf.name
        sd["role"] = surf.role
        sd["root_LE_m"] = Dict(
            "x" => root_x,
            "y" => root_y,
            "z" => root_z
        )
        sd["root_chord_m"] = round(pf.root_chord, digits=4)
        sd["tip_chord_m"] = round(pf.tip_chord, digits=4)
        sd["semi_span_m"] = round(panel_span, digits=4)
        sd["span_m"] = round(surf.vertical ? panel_span : pf.span, digits=4)
        sd["sweep_LE_rad"] = round(pf.sweep_le, digits=4)
        sd["sweep_quarter_chord_deg"] = surf.sweep_quarter_chord_DEG
        sd["dihedral_deg"] = surf.dihedral_DEG
        sd["incidence_deg"] = surf.incidence_DEG
        sd["twist_tip_deg"] = surf.twist_tip_DEG
        sd["mirror"] = surf.symmetric ? true : surf.mirror
        sd["symmetric"] = surf.symmetric
        sd["vertical"] = surf.vertical
        sd["surface_area_m2"] = surf.surface_area_m2
        sd["AR"] = surf.AR
        sd["TR"] = surf.TR
        sd["mean_aerodynamic_chord_m"] = round(pf.mac, digits=4)

        # Aerodynamic center position (quarter-chord of MAC). For vertical
        # surfaces, the planform span is a height measured in +z.
        eta_mac = (1.0 + 2.0 * surf.TR) / (3.0 * (1.0 + surf.TR))
        local_chord_mac = pf.root_chord + eta_mac * (pf.tip_chord - pf.root_chord)
        x_le_mac = root_x + eta_mac * panel_span * tan(pf.sweep_le)
        ac_x = x_le_mac + 0.25 * local_chord_mac
        ac_y = root_y
        ac_z = root_z + (surf.vertical ? eta_mac * panel_span : eta_mac * panel_span * sin(pf.dihedral))
        sd["aerodynamic_center_m"] = Dict(
            "x" => round(ac_x, digits=4),
            "y" => round(ac_y, digits=4),
            "z" => round(ac_z, digits=4)
        )

        # Tip LE position (computed from root LE + sweep + span)
        tip_x = root_x + panel_span * tan(pf.sweep_le)
        tip_y = root_y + (surf.vertical ? 0.0 : panel_span)
        tip_z = root_z + (surf.vertical ? panel_span : panel_span * sin(pf.dihedral))
        sd["tip_LE_m"] = Dict(
            "x" => round(tip_x, digits=4),
            "y" => round(tip_y, digits=4),
            "z" => round(tip_z, digits=4)
        )

        # Airfoil info
        sd["airfoil"] = Dict(
            "type" => surf.airfoil.type,
            "root" => surf.airfoil.root,
            "tip" => surf.airfoil.tip
        )

        # Control surfaces on this lifting surface
        if !isempty(surf.control_surfaces)
            cs_list = []
            for cs in surf.control_surfaces
                push!(cs_list, Dict(
                    "name" => cs.name,
                    "type" => cs.type,
                    "eta_start" => cs.eta_start,
                    "eta_end" => cs.eta_end,
                    "chord_fraction" => cs.chord_fraction
                ))
            end
            sd["control_surfaces"] = cs_list
        end

        push!(surfaces, sd)
    end
    vg["lifting_surfaces"] = surfaces

    # ---- Fuselages ----
    fuselages = []
    for fus in input.fuselages
        fd = Dict{String,Any}()
        fd["name"] = fus.name
        fd["diameter_m"] = fus.diameter
        fd["length_m"] = fus.length
        fd["nose_position_m"] = Dict(
            "x" => fus.nose_position[1],
            "y" => fus.nose_position[2],
            "z" => length(fus.nose_position) >= 3 ? fus.nose_position[3] : 0.0
        )
        push!(fuselages, fd)
    end
    vg["fuselages"] = fuselages

    # ---- Engines / propellers ----
    engines_vis = []
    for eng in input.engines
        ed = Dict{String,Any}()
        ed["id"] = eng.id
        ed["position_m"] = Dict(
            "x" => eng.position_m[1],
            "y" => eng.position_m[2],
            "z" => length(eng.position_m) >= 3 ? eng.position_m[3] : 0.0
        )
        ed["orientation_deg"] = eng.orientation_deg
        push!(engines_vis, ed)
    end
    vg["engines"] = engines_vis

    # ---- Suggested light positions (derived from geometry) ----
    vg["lights"] = build_light_positions(input)

    # ---- Suggested propeller (from first engine near nose) ----
    vg["propeller"] = build_propeller_info(input)

    return vg
end

"""
Compute suggested navigation light positions from the aircraft geometry.
Wing lights at wingtips, tailcone light at rear of fuselage, strobe on vtail.
"""
function build_light_positions(input::AircraftInput)
    lights = Dict{String,Any}()

    # Find wing for wingtip lights
    wing = nothing
    htail = nothing
    vtail = nothing
    for s in input.lifting_surfaces
        if s.role == "wing" && isnothing(wing)
            wing = s
        elseif s.role == "horizontal_stabilizer" && isnothing(htail)
            htail = s
        elseif s.role == "vertical_stabilizer" && isnothing(vtail)
            vtail = s
        end
    end

    if !isnothing(wing)
        pf = wing_planform(wing)
        tip_x = wing.root_LE[1] + pf.semi_span * tan(pf.sweep_le) + pf.tip_chord * 0.5
        tip_y = wing.root_LE[2] + pf.semi_span
        tip_z_base = length(wing.root_LE) >= 3 ? wing.root_LE[3] : 0.0
        wing_tip_z = tip_z_base + pf.semi_span * sin(pf.dihedral)
        lights["wing_tip_position_m"] = Dict(
            "x" => round(tip_x, digits=3),
            "y" => round(tip_y, digits=3),
            "z" => round(wing_tip_z, digits=3)
        )
    end

    # Tailcone light: behind the last surface or rear of fuselage
    tail_x = input.general.CoG[1] + 3.0  # default fallback in x-aft convention
    tail_y = 0.0
    tail_z = 0.0
    if !isnothing(htail)
        pf_ht = wing_planform(htail)
        tail_x = htail.root_LE[1] + pf_ht.root_chord
        tail_y = htail.root_LE[2]
        tail_z = length(htail.root_LE) >= 3 ? htail.root_LE[3] : 0.0
    elseif !isempty(input.fuselages)
        fus = input.fuselages[1]
        tail_x = fus.nose_position[1] + fus.length
        tail_y = fus.nose_position[2]
        tail_z = length(fus.nose_position) >= 3 ? fus.nose_position[3] : 0.0
    end
    lights["tailcone_position_m"] = Dict(
        "x" => round(tail_x, digits=3),
        "y" => round(tail_y, digits=3),
        "z" => round(tail_z, digits=3)
    )

    # Strobe light: top of vertical tail
    if !isnothing(vtail)
        pf_vt = wing_planform(vtail)
        panel_span = pf_vt.span
        strobe_x = vtail.root_LE[1] + panel_span * tan(pf_vt.sweep_le) + pf_vt.tip_chord * 0.5
        strobe_y = vtail.root_LE[2]
        strobe_z = (length(vtail.root_LE) >= 3 ? vtail.root_LE[3] : 0.0) + panel_span
        lights["strobe_position_m"] = Dict(
            "x" => round(strobe_x, digits=3),
            "y" => round(strobe_y, digits=3),
            "z" => round(strobe_z, digits=3)
        )
    end

    return lights
end

"""
Build propeller rendering info from engine positions.
Assumes the forward-most engine drives a propeller (for prop aircraft).
"""
function build_propeller_info(input::AircraftInput)
    prop = Dict{String,Any}()
    if isempty(input.engines)
        return prop
    end

    # Use the engine with the smallest x (most forward in x-aft convention)
    eng = input.engines[1]
    for e in input.engines
        if e.position_m[1] < eng.position_m[1]
            eng = e
        end
    end

    prop["position_m"] = Dict(
        "x" => eng.position_m[1],
        "y" => eng.position_m[2],
        "z" => length(eng.position_m) >= 3 ? eng.position_m[3] : 0.0
    )

    # Estimate propeller diameter from engine thrust (empirical: D ≈ 0.6 * sqrt(T_max / 500))
    # For a ~12kN turboprop ≈ 2.4m diameter, for a ~1kN piston ≈ 0.85m
    est_diameter = 0.6 * sqrt(eng.max_thrust_n / 500.0)
    prop["diameter_m"] = round(clamp(est_diameter, 0.5, 4.0), digits=2)

    return prop
end
