"""
    validation.jl — Aerodynamic data quality checker

Runs after merge_results() to validate that the generated aerodynamic model
is physically sensible. Reports issues at three severity levels:
  - ERROR:   Value is clearly wrong and will cause simulation failures
  - WARNING: Value is suspect and may cause poor flight behavior
  - INFO:    Value is unusual but possibly intentional

Returns a structured report that is embedded in the YAML output under
`quality.validation` so the user sees it before flying.
"""

# ──────────────────────────────────────────────────────────────────
# Public API
# ──────────────────────────────────────────────────────────────────

struct ValidationIssue
    severity::Symbol   # :error, :warning, :info
    category::String   # e.g. "lift", "drag", "pitch_moment", "control"
    message::String
    detail::String     # e.g. "Cm(α=0) = -0.038, expected > 0"
end

struct ValidationReport
    issues::Vector{ValidationIssue}
    passed::Bool
    summary::String
end

"""
    validate_aero_model(model::Dict, input) -> ValidationReport

Run all validation checks on the merged aerodynamic model.
`input` is the AircraftInput struct for cross-referencing geometry.
"""
function validate_aero_model(model::Dict, input)
    issues = ValidationIssue[]

    aero = get(model, "aerodynamics", nothing)
    if isnothing(aero)
        push!(issues, ValidationIssue(:error, "structure", "No aerodynamics section found", ""))
        return _build_report(issues)
    end

    ref = get(model, "reference", Dict())
    mass_kg = get(ref, "mass_kg", 0.0)
    geom = get(ref, "geometry", Dict())
    S_ref = get(geom, "S_ref_m2", 1.0)
    b_ref = get(geom, "b_ref_m", 1.0)
    c_ref = get(geom, "c_ref_m", 1.0)
    cg = get(ref, "cg_ref_m", Dict("x" => 0.0))
    AR = b_ref^2 / S_ref

    sc = get(aero, "static_coefficients", nothing)
    dd = get(aero, "dynamic_derivatives", nothing)
    ce = get(aero, "control_effectiveness", nothing)
    alphas = nothing
    runtime_model = get(model, "runtime_model", Dict())
    runtime_constants = get(runtime_model, "constants", Dict())
    control_limits = get(get(model, "limits", Dict()), "controls_deg", Dict())
    Cm_for_validation = nothing

    _check_inertia!(issues, ref, input)
    _check_reference_consistency!(issues, ref, runtime_model, c_ref)

    # Extract data at β=0, first config, first Mach for validation
    if !isnothing(sc)
        alphas, betas, configs, machs = _extract_axes(sc)
        _check_full_envelope_axes!(issues, alphas, betas, "static_coefficients")
        cfg1 = isempty(configs) ? "clean" : configs[1]
        b0 = _find_nearest_index(betas, 0.0)

        CL = _extract_beta0_slice(sc, "CL", cfg1, 1, b0)
        CD = _extract_beta0_slice(sc, "CD", cfg1, 1, b0)
        Cm = _extract_beta0_slice(sc, "Cm", cfg1, 1, b0)
        Cn = _extract_beta0_slice(sc, "Cn", cfg1, 1, b0)
        CY = _extract_beta0_slice(sc, "CY", cfg1, 1, b0)
        Cl = _extract_beta0_slice(sc, "Cl", cfg1, 1, b0)

        if !isnothing(CL) && !isnothing(alphas)
            _check_lift!(issues, CL, alphas, AR)
            _check_performance_speeds!(issues, CL, alphas, mass_kg, S_ref, input, runtime_model)
        end
        if !isnothing(CD) && !isnothing(alphas)
            _check_drag!(issues, CD, CL, alphas, AR)
        end
        if !isnothing(Cm) && !isnothing(alphas) && !isnothing(CL)
            x_cg_current = Float64(get(cg, "x", 0.0))
            x_cg_reference = Float64(get(runtime_constants, "x_aero_reference_CoG", x_cg_current))
            Cm_for_validation = _re_reference_pitch_slice(Cm, CL, x_cg_reference, x_cg_current, c_ref)
            _check_pitch_moment!(issues, Cm_for_validation, CL, alphas; c_ref=c_ref, x_cg=x_cg_current)
        end
        if !isnothing(Cn) && !isnothing(Cm)
            _check_lateral_directional!(issues, Cn, Cl, CY, alphas, betas, sc, cfg1)
        end
    else
        push!(issues, ValidationIssue(:error, "structure", "No static_coefficients section", ""))
    end

    # Dynamic derivatives
    if !isnothing(dd)
        dd_alphas_for_axis_check = _get_alpha_axis(dd, alphas)
        _check_full_envelope_axes!(issues, dd_alphas_for_axis_check, nothing, "dynamic_derivatives")
        _check_dynamic_derivatives!(issues, dd, alphas)
    else
        push!(issues, ValidationIssue(:warning, "damping", "No dynamic_derivatives section", "Aircraft will have no aerodynamic damping"))
    end

    _check_primary_control_layout!(issues, input)

    # Control effectiveness
    if !isnothing(ce)
        _check_control_effectiveness!(issues, ce, alphas, Cm_for_validation, runtime_constants, control_limits)
        _check_pitch_trim_headroom!(issues, ce, alphas, Cm_for_validation, runtime_constants, control_limits)
    else
        push!(issues, ValidationIssue(:warning, "control", "No control_effectiveness section", "Aircraft will have no control authority"))
    end

    # NaN/Inf check on all numeric data
    _check_numeric_integrity!(issues, model)

    return _build_report(issues)
end

function _has_surface_type(input, target_type::String; roles=nothing)
    target = lowercase(target_type)
    for surf in input.lifting_surfaces
        if !isnothing(roles) && !(surf.role in roles)
            continue
        end
        for cs in surf.control_surfaces
            if lowercase(string(cs.type)) == target
                return true
            end
        end
    end
    return false
end

function _check_primary_control_layout!(issues, input)
    if !_has_surface_type(input, "aileron"; roles=["wing"])
        push!(issues, ValidationIssue(:warning, "control",
            "No explicit wing aileron defined in aircraft data",
            "Roll-control data and exported actuator limits will be incomplete. Add an `aileron` control surface to the main wing so the aircraft carries explicit roll control geometry."))
    end

    if !_has_surface_type(input, "elevator"; roles=["horizontal_stabilizer"])
        push!(issues, ValidationIssue(:warning, "control",
            "No explicit elevator defined on the horizontal tail",
            "Pitch control will rely on fallbacks or be absent. Add an `elevator` control surface to the horizontal stabilizer."))
    end

    if !_has_surface_type(input, "rudder"; roles=["vertical_stabilizer"])
        push!(issues, ValidationIssue(:warning, "control",
            "No explicit rudder defined on the vertical tail",
            "Yaw control will rely on fallbacks or be absent. Add a `rudder` control surface to the vertical stabilizer."))
    end
end


# ──────────────────────────────────────────────────────────────────
# Lift checks
# ──────────────────────────────────────────────────────────────────

function _check_lift!(issues, CL, alphas, AR)
    i0 = _find_nearest_index(alphas, 0.0)

    # CL at α=0
    CL0 = CL[i0]
    if abs(CL0) > 1.0
        push!(issues, ValidationIssue(:error, "lift",
            "CL at α=0° is extreme",
            "CL(α=0) = $(round(CL0; digits=4)), expected |CL₀| < 0.8"))
    end

    # Lift slope
    im = _find_nearest_index(alphas, -2.0)
    ip = _find_nearest_index(alphas, 2.0)
    if im != ip
        CLa_deg = (CL[ip] - CL[im]) / (alphas[ip] - alphas[im])
        CLa_rad = CLa_deg * 57.2958
        if CLa_rad < 2.0
            push!(issues, ValidationIssue(:error, "lift",
                "Lift slope too low",
                "CLα = $(round(CLa_rad; digits=2))/rad, expected 3.5–6.0 for typical wing"))
        elseif CLa_rad > 8.0
            push!(issues, ValidationIssue(:error, "lift",
                "Lift slope too high",
                "CLα = $(round(CLa_rad; digits=2))/rad, expected 3.5–6.0 (2π max for infinite wing)"))
        elseif CLa_rad < 3.5 || CLa_rad > 6.0
            push!(issues, ValidationIssue(:warning, "lift",
                "Lift slope outside typical range",
                "CLα = $(round(CLa_rad; digits=2))/rad, typical 3.5–6.0 for AR=$(round(AR; digits=1))"))
        end

        # Zero-lift alpha
        alpha_ZL = -CL0 / CLa_deg
        if alpha_ZL > 2.0 || alpha_ZL < -10.0
            push!(issues, ValidationIssue(:warning, "lift",
                "Zero-lift alpha unusual",
                "α_ZL = $(round(alpha_ZL; digits=1))°, expected -6° to 0° for cambered airfoil"))
        end
    end

    # CL_max
    # Only check in the normal flight range (-30° to +30°)
    normal_range = findall(a -> -30 <= a <= 30, alphas)
    if !isempty(normal_range)
        CL_max = maximum(CL[normal_range])
        CL_min = minimum(CL[normal_range])
        if CL_max < 0.8
            push!(issues, ValidationIssue(:warning, "lift",
                "CL_max seems low",
                "CL_max = $(round(CL_max; digits=3)), typical trainers achieve 1.2–1.6"))
        elseif CL_max > 2.5
            push!(issues, ValidationIssue(:error, "lift",
                "CL_max unrealistically high",
                "CL_max = $(round(CL_max; digits=3)), maximum ~2.5 even with full flaps"))
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Drag checks
# ──────────────────────────────────────────────────────────────────

function _check_drag!(issues, CD, CL, alphas, AR)
    i0 = _find_nearest_index(alphas, 0.0)

    # CD0 (minimum drag)
    normal_range = findall(a -> -5 <= a <= 5, alphas)
    CD_min = isempty(normal_range) ? CD[i0] : minimum(CD[normal_range])

    if CD_min < 0.0
        push!(issues, ValidationIssue(:error, "drag",
            "Negative drag coefficient",
            "CD_min = $(round(CD_min; digits=5)), drag must always be ≥ 0"))
    elseif CD_min < 0.008
        push!(issues, ValidationIssue(:warning, "drag",
            "CD₀ very low — possible missing parasite drag",
            "CD_min = $(round(CD_min; digits=5)), typical CD₀ = 0.018–0.030 for clean aircraft"))
    elseif CD_min > 0.060
        push!(issues, ValidationIssue(:warning, "drag",
            "CD₀ unusually high",
            "CD_min = $(round(CD_min; digits=5)), typical CD₀ = 0.018–0.030"))
    end

    # L/D max
    best_LD = 0.0
    for i in eachindex(CL)
        if CD[i] > 0.001 && -20 <= alphas[i] <= 20
            ld = CL[i] / CD[i]
            if ld > best_LD
                best_LD = ld
            end
        end
    end
    if best_LD > 0
        if best_LD > 40
            push!(issues, ValidationIssue(:warning, "drag",
                "L/D ratio unrealistically high",
                "L/D_max = $(round(best_LD; digits=1)), typical max 15–25 for trainers"))
        elseif best_LD < 5
            push!(issues, ValidationIssue(:warning, "drag",
                "L/D ratio very low",
                "L/D_max = $(round(best_LD; digits=1)), aircraft will require excessive thrust"))
        end
    end

    # CD should always increase with |CL| (drag polar check)
    for i in eachindex(CL)
        if -20 <= alphas[i] <= 20 && CD[i] < CD_min - 0.001
            push!(issues, ValidationIssue(:error, "drag",
                "Drag below minimum at non-zero alpha",
                "CD(α=$(alphas[i])°) = $(round(CD[i]; digits=5)) < CD_min = $(round(CD_min; digits=5))"))
            break
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Pitching moment checks
# ──────────────────────────────────────────────────────────────────

function _check_pitch_moment!(issues, Cm, CL, alphas; c_ref::Float64=1.0, x_cg::Float64=0.0)
    i0 = _find_nearest_index(alphas, 0.0)
    im = _find_nearest_index(alphas, -2.0)
    ip = _find_nearest_index(alphas, 2.0)

    Cm0 = Cm[i0]

    # Cm0 sign check
    if Cm0 < -0.01
        push!(issues, ValidationIssue(:warning, "pitch_moment",
            "Cm at α=0° is negative — aircraft cannot trim at positive α without elevator",
            "Cm(α=0) = $(round(Cm0; digits=4)); conventional tailed aircraft needs Cm₀ > 0 " *
            "so it trims at positive α with positive CL. " *
            "Check tail incidence angle and CG position. " *
            "NOTE: if auto_pitch_trim_mode is set to \"initial\" or \"continuous\" " *
            "in default_mission.yaml, the simulator will automatically apply the " *
            "required elevator bias at startup — the aircraft will fly normally, " *
            "but with reduced elevator authority and higher trim drag."))
    elseif Cm0 > 0.15
        push!(issues, ValidationIssue(:warning, "pitch_moment",
            "Cm at α=0° is very large — aircraft will trim at high α",
            "Cm(α=0) = $(round(Cm0; digits=4)), may require excessive nose-down elevator"))
    end

    # Cm_alpha (stability)
    if im != ip
        Cma_deg = (Cm[ip] - Cm[im]) / (alphas[ip] - alphas[im])
        Cma_rad = Cma_deg * 57.2958
        CLa_deg = (CL[ip] - CL[im]) / (alphas[ip] - alphas[im])
        static_margin = abs(CLa_deg) > 1e-6 ? -Cma_deg / CLa_deg : 0.0

        # Neutral point position: x_np = x_cg + SM × c_ref
        # (positive SM = NP aft of CG = stable; negative = unstable)
        x_np = x_cg + static_margin * c_ref

        if Cma_rad > 0
            # How much CG needs to move forward for 10% MAC static margin
            target_SM = 0.10
            cg_shift_needed = (target_SM - static_margin) * c_ref

            push!(issues, ValidationIssue(:error, "pitch_moment",
                "Aircraft is statically UNSTABLE in pitch (Cmα > 0)",
                "Cmα = $(round(Cma_rad; digits=3))/rad. " *
                "Static margin = $(round(static_margin*100; digits=1))% MAC (negative = unstable). " *
                "Neutral point at x = $(round(x_np; digits=3)) m, CG at x = $(round(x_cg; digits=3)) m. " *
                "▶ SUGGESTION: move the CG forward by $(round(cg_shift_needed; digits=3)) m " *
                "(to x_cg ≈ $(round(x_cg - cg_shift_needed; digits=3)) m) " *
                "for a 10% MAC static margin. " *
                "Alternatively, increase tail area or tail moment arm."))
        elseif Cma_rad > -0.1
            push!(issues, ValidationIssue(:warning, "pitch_moment",
                "Very low pitch stability (Cmα near zero)",
                "Cmα = $(round(Cma_rad; digits=3))/rad, SM = $(round(static_margin*100; digits=1))% MAC. " *
                "Neutral point at x = $(round(x_np; digits=3)) m, CG at x = $(round(x_cg; digits=3)) m."))
        end

        if static_margin > 0.30
            push!(issues, ValidationIssue(:warning, "pitch_moment",
                "Static margin very large — aircraft will be sluggish in pitch",
                "SM = $(round(static_margin*100; digits=1))% MAC, typical 5–20% for trainers"))
        end

        # Trim alpha
        trim_alpha = nothing
        for j in 1:length(alphas)-1
            if -20 <= alphas[j] <= 20 && -20 <= alphas[j+1] <= 20
                if Cm[j] * Cm[j+1] <= 0 && Cm[j] != Cm[j+1]
                    trim_alpha = alphas[j] + (alphas[j+1] - alphas[j]) * (-Cm[j]) / (Cm[j+1] - Cm[j])
                    break
                end
            end
        end
        if !isnothing(trim_alpha)
            if trim_alpha < -8.0
                push!(issues, ValidationIssue(:error, "pitch_moment",
                    "Aircraft trims at negative α (negative CL)",
                    "Trim α = $(round(trim_alpha; digits=1))° without elevator — " *
                    "aircraft produces downforce at trim. Check Cm₀ sign and tail setting."))
            elseif trim_alpha < -2.0
                push!(issues, ValidationIssue(:warning, "pitch_moment",
                    "Aircraft needs elevator trim for positive-lift flight",
                    "No-elevator trim alpha = $(round(trim_alpha; digits=1)) deg. " *
                    "This is flyable with auto_pitch_trim_mode enabled, but reduces elevator margin."))
            elseif trim_alpha > 12.0
                push!(issues, ValidationIssue(:warning, "pitch_moment",
                    "Aircraft trims near stall",
                    "Trim α = $(round(trim_alpha; digits=1))° — close to stall angle"))
            else
                push!(issues, ValidationIssue(:info, "pitch_moment",
                    "Trim condition",
                    "Trim α = $(round(trim_alpha; digits=1))° (no elevator)"))
            end
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Dynamic derivative checks
# ──────────────────────────────────────────────────────────────────

function _validation_aircraft_length_m(input, c_ref::Float64)
    x_min = Inf
    x_max = -Inf

    for fus in input.fuselages
        nose_x = fus.nose_position[1]
        tail_x = nose_x + fus.length
        x_min = min(x_min, nose_x, tail_x)
        x_max = max(x_max, nose_x, tail_x)
    end

    for surf in input.lifting_surfaces
        pf = wing_planform(surf)
        panel_span = surf.vertical ? pf.span : pf.semi_span
        root_x = surf.root_LE[1]
        tip_x = root_x + panel_span * tan(pf.sweep_le)
        x_min = min(x_min, root_x, tip_x)
        x_max = max(x_max, root_x + pf.root_chord, tip_x + pf.tip_chord)
    end

    if isfinite(x_min) && isfinite(x_max) && x_max > x_min
        return max(x_max - x_min, 2.5 * c_ref, 1.0)
    end
    return max(2.5 * c_ref, 1.0)
end

function _check_inertia!(issues, ref, input)
    mass = Float64(get(ref, "mass_kg", 0.0))
    if mass <= 0
        push!(issues, ValidationIssue(:error, "inertia",
            "Mass is missing or non-positive",
            "A positive aircraft mass is required for physical angular accelerations."))
        return
    end

    geom = get(ref, "geometry", Dict())
    span = Float64(get(geom, "b_ref_m", 1.0))
    cref = Float64(get(geom, "c_ref_m", 1.0))
    length_m = _validation_aircraft_length_m(input, cref)

    inertia = get(ref, "inertia", Dict())
    pm = get(inertia, "principal_moments_kgm2", Dict())
    Ixx = Float64(get(pm, "Ixx_p", 0.0))
    Iyy = Float64(get(pm, "Iyy_p", 0.0))
    Izz = Float64(get(pm, "Izz_p", 0.0))

    if Ixx <= 0 || Iyy <= 0 || Izz <= 0
        push!(issues, ValidationIssue(:error, "inertia",
            "Principal inertia is missing or non-positive",
            "Ixx=$(round(Ixx; digits=1)), Iyy=$(round(Iyy; digits=1)), Izz=$(round(Izz; digits=1))."))
        return
    end

    kx = sqrt(Ixx / mass)
    ky = sqrt(Iyy / mass)
    kz = sqrt(Izz / mass)
    default_like = abs(Ixx - 1000.0) < 1e-6 &&
                   abs(Iyy - 3000.0) < 1e-6 &&
                   abs(Izz - 3500.0) < 1e-6

    if default_like
        push!(issues, ValidationIssue(:warning, "inertia",
            "Generic fallback inertia is still in use",
            "Ixx/Iyy/Izz are 1000/3000/3500 kg m^2. Use geometry-scaled inertia, especially for long-wing aircraft."))
    end
    if kx < 0.16 * span
        push!(issues, ValidationIssue(:warning, "inertia",
            "Roll inertia appears too low for the wingspan",
            "Roll radius of gyration is $(round(kx; digits=2)) m for span $(round(span; digits=2)) m; low Ixx can create excessive roll acceleration."))
    end
    if ky < 0.14 * length_m
        push!(issues, ValidationIssue(:warning, "inertia",
            "Pitch inertia appears too low for the aircraft length",
            "Pitch radius of gyration is $(round(ky; digits=2)) m for length $(round(length_m; digits=2)) m; low Iyy can create excessive pitch acceleration."))
    end
    if kz < 0.18 * span
        push!(issues, ValidationIssue(:warning, "inertia",
            "Yaw inertia appears too low for the wingspan",
            "Yaw radius of gyration is $(round(kz; digits=2)) m for span $(round(span; digits=2)) m; low Izz can create excessive yaw acceleration."))
    end
    if kx > 0.45 * span
        push!(issues, ValidationIssue(:warning, "inertia",
            "Roll inertia appears too high for the wingspan",
            "Roll radius of gyration is $(round(kx; digits=2)) m for span $(round(span; digits=2)) m; high Ixx can make roll authority look unrealistically weak."))
    end
    if ky > 0.50 * length_m
        push!(issues, ValidationIssue(:warning, "inertia",
            "Pitch inertia appears too high for the aircraft length",
            "Pitch radius of gyration is $(round(ky; digits=2)) m for length $(round(length_m; digits=2)) m; high Iyy can hide pitch-control problems."))
    end
    if kz > max(0.65 * span, 0.55 * length_m)
        push!(issues, ValidationIssue(:warning, "inertia",
            "Yaw inertia appears too high for the aircraft size",
            "Yaw radius of gyration is $(round(kz; digits=2)) m; high Izz can suppress yaw/roll coupling and mask instability."))
    end
end

function _check_reference_consistency!(issues, ref, runtime_model, c_ref)
    ref isa AbstractDict || return
    runtime_model isa AbstractDict || return
    cg = get(ref, "cg_ref_m", Dict())
    constants = get(runtime_model, "constants", Dict())
    cg isa AbstractDict || return
    constants isa AbstractDict || return

    x_current = Float64(get(cg, "x", get(constants, "x_aero_reference_CoG", 0.0)))
    x_reference = Float64(get(constants, "x_aero_reference_CoG", x_current))
    dx = x_current - x_reference
    if abs(dx) > max(0.02 * max(Float64(c_ref), 0.01), 0.02)
        push!(issues, ValidationIssue(:error, "reference",
            "Exported CG does not match the aerodynamic reference",
            "cg_ref_m.x = $(round(x_current; digits=3)) m but runtime constants use x_aero_reference_CoG = $(round(x_reference; digits=3)) m. " *
            "Move the CG in ac_data and regenerate the tables; do not shift only the exported reference block."))
    end
end

function _validation_isa_density_kg_m3(altitude_m)
    h = clamp(Float64(altitude_m), -500.0, 11000.0)
    T0 = 288.15
    p0 = 101325.0
    L = 0.0065
    R = 287.05
    g = 9.80665
    T = T0 - L * h
    p = p0 * (T / T0)^(g / (R * L))
    return p / (R * T)
end

function _check_performance_speeds!(issues, CL, alphas, mass_kg, S_ref, input, runtime_model)
    mass = Float64(mass_kg)
    area = Float64(S_ref)
    if !(mass > 0.0 && area > 0.0) || isnothing(CL) || isnothing(alphas)
        return
    end
    normal_range = findall(a -> -30 <= a <= 30, alphas)
    isempty(normal_range) && return
    CL_max = maximum(Float64(CL[i]) for i in normal_range)
    if runtime_model isa AbstractDict
        runtime_CL_max = _finite_float(get(runtime_model, "CL_max", NaN))
        if isfinite(runtime_CL_max) && runtime_CL_max > 0.1
            CL_max = min(CL_max, runtime_CL_max)
        end
    end
    CL_max > 0.1 || return

    rho0 = _validation_isa_density_kg_m3(0.0)
    rho_analysis = _validation_isa_density_kg_m3(input.analysis.altitude_m)
    stall_sl = sqrt(2.0 * mass * 9.80665 / (rho0 * area * CL_max))
    stall_analysis = sqrt(2.0 * mass * 9.80665 / (rho_analysis * area * CL_max))
    recommended = 1.3 * stall_analysis

    detail = "Estimated clean stall speed: $(round(stall_sl; digits=1)) m/s at sea level, " *
             "$(round(stall_analysis; digits=1)) m/s at analysis altitude " *
             "$(round(input.analysis.altitude_m; digits=0)) m; use at least " *
             "$(round(recommended; digits=1)) m/s for simulator initial_velocity."

    if recommended > 45.0
        push!(issues, ValidationIssue(:warning, "performance",
            "Aircraft requires a high simulator launch speed", detail))
    else
        push!(issues, ValidationIssue(:info, "performance",
            "Recommended simulator launch speed", detail))
    end
end

function _re_reference_pitch_slice(Cm, CL, x_reference_cg::Float64, x_current_cg::Float64, c_ref::Float64)
    if abs(c_ref) < 1e-9 || abs(x_current_cg - x_reference_cg) < 1e-9
        return Cm
    end
    shift_over_chord = (x_current_cg - x_reference_cg) / c_ref
    return [Cm[i] + shift_over_chord * CL[i] for i in eachindex(Cm, CL)]
end

function _check_dynamic_derivatives!(issues, dd, alphas)
    dd_alphas = _get_alpha_axis(dd, alphas)
    i0 = isnothing(dd_alphas) ? 1 : _find_nearest_index(dd_alphas, 0.0)

    checks = [
        ("Cm_q_hat", "Pitch damping (Cm_q)", -30.0, -5.0, "negative for stable pitch damping"),
        ("Cl_p_hat", "Roll damping (Cl_p)",   -0.8, -0.2, "negative for roll damping"),
        ("Cn_r_hat", "Yaw damping (Cn_r)",    -0.5, -0.05, "negative for yaw damping"),
    ]

    for (key, name, lo, hi, requirement) in checks
        ddata = get(dd, key, nothing)
        if isnothing(ddata)
            push!(issues, ValidationIssue(:warning, "damping",
                "$name ($key) not found",
                "Aircraft will have no $name — may oscillate or diverge"))
            continue
        end
        vals = _get_first_config_values(ddata)
        if isnothing(vals) || isempty(vals)
            continue
        end
        idx = min(i0, length(vals))
        val = vals[idx]

        if val > 0
            push!(issues, ValidationIssue(:error, "damping",
                "$name has WRONG SIGN (positive)",
                "$key(α≈0) = $(round(val; digits=3)), must be $requirement"))
        elseif val > hi || val < lo
            push!(issues, ValidationIssue(:warning, "damping",
                "$name outside typical range",
                "$key(α≈0) = $(round(val; digits=3)), expected $lo to $hi"))
        end
    end

    cnr_data = get(dd, "Cn_r_hat", nothing)
    if !isnothing(cnr_data) && !isnothing(dd_alphas)
        vals = _get_first_config_values(cnr_data)
        if !isnothing(vals) && !isempty(vals)
            poststall_idxs = [i for (i, α) in enumerate(dd_alphas)
                              if i <= length(vals) && 30.0 <= abs(α) <= 150.0]
            if !isempty(poststall_idxs)
                weakest_poststall = maximum(Float64(vals[i]) for i in poststall_idxs)
                poststall_mag = maximum(abs(Float64(vals[i])) for i in poststall_idxs)
                if weakest_poststall > -0.08
                    push!(issues, ValidationIssue(:warning, "damping",
                        "Yaw damping collapses in post-stall attitudes",
                        "Weakest Cn_r_hat over |α| = 30°–150° is $(round(weakest_poststall; digits=3)); keep post-stall yaw damping meaningfully negative so deep-stall and broadside motion remain damped."))
                end
                attached_mag = abs(Float64(vals[min(i0, length(vals))]))
                if attached_mag < 0.80 * poststall_mag
                    push!(issues, ValidationIssue(:warning, "damping",
                        "Yaw damping has an alpha-zero notch",
                        "Cn_r_hat at alpha near zero is weaker than the post-stall plateau; attached-flow yaw damping should not be the weakest point of the curve."))
                end
            end

            reverse_idxs = [i for (i, α) in enumerate(dd_alphas)
                            if i <= length(vals) && abs(α) >= 160.0]
            if !isempty(reverse_idxs)
                weakest_reverse = maximum(Float64(vals[i]) for i in reverse_idxs)
                if weakest_reverse > -0.10
                    push!(issues, ValidationIssue(:warning, "damping",
                        "Yaw damping too weak in reversed flow",
                        "Weakest Cn_r_hat over |α| ≥ 160° is $(round(weakest_reverse; digits=3)); reversed-flow yaw damping should stay clearly negative."))
                end
            end
        end
    end

    clp_data = get(dd, "Cl_p_hat", nothing)
    if !isnothing(clp_data) && !isnothing(dd_alphas)
        vals = _get_first_config_values(clp_data)
        if !isnothing(vals) && !isempty(vals)
            poststall_idxs = [i for (i, alpha) in enumerate(dd_alphas)
                              if i <= length(vals) && 18.0 <= abs(alpha) <= 150.0]
            if !isempty(poststall_idxs)
                strongest_positive = maximum(Float64(vals[i]) for i in poststall_idxs)
                if strongest_positive > 0.08
                    push!(issues, ValidationIssue(:error, "damping",
                        "Roll damping becomes strongly destabilizing after stall",
                        "Max Cl_p_hat over |alpha| = 18-150 deg is $(round(strongest_positive; digits=3)); positive roll-rate damping can create non-physical angular acceleration in upset attitudes."))
                elseif strongest_positive > 0.02
                    push!(issues, ValidationIssue(:warning, "damping",
                        "Roll damping becomes lightly destabilizing after stall",
                        "Max Cl_p_hat over |alpha| = 18-150 deg is $(round(strongest_positive; digits=3)); keep the autorotation lobe small unless a spin model is deliberately being tuned."))
                end
            end
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Control effectiveness checks
# ──────────────────────────────────────────────────────────────────

function _check_control_effectiveness!(issues, ce, alphas, Cm, runtime_constants, control_limits)
    ce_alphas = _get_alpha_axis(ce, alphas)
    i0 = isnothing(ce_alphas) ? 1 : _find_nearest_index(ce_alphas, 0.0)

    # Elevator (Cm_de)
    cmde_data = get(ce, "Cm_de_per_deg", nothing)
    if !isnothing(cmde_data)
        vals = _get_first_config_values(cmde_data)
        if !isnothing(vals) && !isempty(vals)
            idx = min(i0, length(vals))
            cmde = vals[idx]
            if cmde > 0
                push!(issues, ValidationIssue(:error, "control",
                    "Elevator effectiveness has WRONG SIGN (Cm_de > 0)",
                    "Cm_de = $(round(cmde; digits=5))/deg, must be negative"))
            elseif abs(cmde) < 0.005
                push!(issues, ValidationIssue(:warning, "control",
                    "Elevator very weak — may not be able to trim",
                    "Cm_de = $(round(cmde; digits=5))/deg, typical -0.02 to -0.04"))
            elseif abs(cmde) > 0.08
                push!(issues, ValidationIssue(:warning, "control",
                    "Elevator effectiveness unusually high",
                    "Cm_de = $(round(cmde; digits=5))/deg, typical -0.02 to -0.04"))
            end

            # Check if elevator can trim the aircraft
            if !isnothing(Cm) && i0 <= length(Cm)
                Cm0 = Cm[i0]
                max_elev_deg = _get_control_limit_abs_deg(control_limits, "de",
                    Float64(get(runtime_constants, "max_elevator_deflection_deg",
                        get(runtime_constants, "elevator_max_deg", 25.0))))
                max_Cm_correction = abs(cmde) * max_elev_deg
                if abs(Cm0) > max_Cm_correction
                    push!(issues, ValidationIssue(:error, "control",
                        "Elevator CANNOT trim the aircraft",
                        "|Cm₀| = $(round(abs(Cm0); digits=4)) but max elevator Cm = " *
                        "$(round(max_Cm_correction; digits=4)) (|Cm_de| × δe_max = " *
                        "$(round(abs(cmde); digits=5)) × $(max_elev_deg)°)"))
                end
            end
        end
    else
        push!(issues, ValidationIssue(:warning, "control",
            "No elevator effectiveness data (Cm_de_per_deg)",
            "Aircraft will have no pitch control"))
    end

    # Aileron (Cl_da)
    clda_data = get(ce, "Cl_da_per_deg", nothing)
    if !isnothing(clda_data)
        vals = _get_first_config_values(clda_data)
        if !isnothing(vals) && !isempty(vals)
            idx = min(i0, length(vals))
            clda = vals[idx]
            if clda >= 0 && clda < 0.002
                push!(issues, ValidationIssue(:error, "control",
                    "Aileron effectiveness is too weak for simulator export",
                    "Cl_da = $(round(clda; digits=5))/deg, below the minimum practical value of 0.002/deg. Increase aileron span/chord/deflection/gain and regenerate."))
            elseif clda >= 0 && clda < 0.0035
                push!(issues, ValidationIssue(:warning, "control",
                    "Aileron roll authority is weak",
                    "Cl_da = $(round(clda; digits=5))/deg, typical 0.0035-0.008 for piloted aircraft"))
            end

            max_ail_deg = _get_control_limit_abs_deg(control_limits, "da",
                Float64(get(runtime_constants, "max_aileron_deflection_deg",
                    get(runtime_constants, "aileron_max_deg", 20.0))))
            max_roll_moment = abs(clda) * max_ail_deg
            if max_roll_moment < 0.05
                push!(issues, ValidationIssue(:error, "control",
                    "Full-stick roll moment is too small",
                    "|Cl_da| x da_max = $(round(max_roll_moment; digits=4)); this commonly produces little roll authority in the simulator. Target at least 0.05, preferably 0.08+ for trainers."))
            elseif max_roll_moment < 0.08
                push!(issues, ValidationIssue(:warning, "control",
                    "Full-stick roll moment is marginal",
                    "|Cl_da| x da_max = $(round(max_roll_moment; digits=4)); aerobatic/trainers should usually be above 0.08."))
            end
            if clda < 0
                push!(issues, ValidationIssue(:error, "control",
                    "Aileron effectiveness has WRONG SIGN (Cl_da < 0)",
                    "Cl_da = $(round(clda; digits=5))/deg, must be positive"))
            elseif clda < 0.001
                push!(issues, ValidationIssue(:warning, "control",
                    "Aileron very weak",
                    "Cl_da = $(round(clda; digits=5))/deg, typical 0.003–0.008"))
            end
        end
    end

    # Rudder (Cn_dr)
    cndr_data = get(ce, "Cn_dr_per_deg", nothing)
    if !isnothing(cndr_data)
        vals = _get_first_config_values(cndr_data)
        if !isnothing(vals) && !isempty(vals)
            idx = min(i0, length(vals))
            cndr = vals[idx]
            if cndr < 0
                push!(issues, ValidationIssue(:error, "control",
                    "Rudder effectiveness has WRONG SIGN (Cn_dr < 0)",
                    "Cn_dr = $(round(cndr; digits=5))/deg, must be positive"))
            elseif cndr < 0.0005
                push!(issues, ValidationIssue(:warning, "control",
                    "Rudder very weak",
                    "Cn_dr = $(round(cndr; digits=5))/deg, typical 0.001–0.004"))
            end

            max_rud_deg = _get_control_limit_abs_deg(control_limits, "dr",
                Float64(get(runtime_constants, "max_rudder_deflection_deg",
                    get(runtime_constants, "rudder_max_deg", 25.0))))
            max_yaw_moment = abs(cndr) * max_rud_deg
            if max_yaw_moment < 0.015
                push!(issues, ValidationIssue(:error, "control",
                    "Full-rudder yaw moment is too small",
                    "|Cn_dr| x dr_max = $(round(max_yaw_moment; digits=4)); this commonly produces little yaw authority in the simulator. Increase fin/rudder size, rudder chord/span, deflection, or control gain and regenerate."))
            elseif max_yaw_moment < 0.025
                push!(issues, ValidationIssue(:warning, "control",
                    "Full-rudder yaw moment is marginal",
                    "|Cn_dr| x dr_max = $(round(max_yaw_moment; digits=4)); trainers should usually be above 0.025."))
            end
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Lateral-directional checks
# ──────────────────────────────────────────────────────────────────

function _get_control_limit_abs_deg(control_limits, key::String, default_value::Float64)
    if control_limits isa AbstractDict && haskey(control_limits, key)
        limit_range = get(control_limits, key, nothing)
        if limit_range isa AbstractVector && length(limit_range) >= 2
            return max(abs(Float64(limit_range[1])), abs(Float64(limit_range[2])))
        end
    end
    return default_value
end

function _check_pitch_trim_headroom!(issues, ce, alphas, Cm, runtime_constants, control_limits)
    if isnothing(Cm) || isnothing(alphas) || isempty(alphas)
        return
    end

    cmde_data = get(ce, "Cm_de_per_deg", nothing)
    if isnothing(cmde_data)
        return
    end
    vals = _get_first_config_values(cmde_data)
    if isnothing(vals) || isempty(vals)
        return
    end

    ce_alphas = _get_alpha_axis(ce, alphas)
    i0 = isnothing(ce_alphas) ? 1 : _find_nearest_index(ce_alphas, 0.0)
    idx = min(i0, length(vals))
    cmde = vals[idx]
    if !(cmde < -1e-6)
        return
    end

    max_elev_deg = _get_control_limit_abs_deg(control_limits, "de",
        Float64(get(runtime_constants, "max_elevator_deflection_deg",
            get(runtime_constants, "elevator_max_deg", 25.0))))
    itrim = _find_nearest_index(alphas, 4.0)
    if itrim > length(Cm)
        return
    end

    trim_alpha = alphas[itrim]
    required_elevator_deg = abs(Cm[itrim] / cmde)
    if required_elevator_deg > max_elev_deg
        push!(issues, ValidationIssue(:error, "control",
            "Elevator cannot trim a normal positive-lift condition",
            "Need about $(round(required_elevator_deg; digits=1)) deg elevator at alpha ~= $(round(trim_alpha; digits=1)) deg, " *
            "but only $(round(max_elev_deg; digits=1)) deg is available"))
    elseif required_elevator_deg > 0.70 * max_elev_deg
        push!(issues, ValidationIssue(:warning, "control",
            "Pitch trim uses too much elevator near normal flight alpha",
            "Need about $(round(required_elevator_deg; digits=1)) deg elevator at alpha ~= $(round(trim_alpha; digits=1)) deg, " *
            "leaving limited pitch authority for maneuvering"))
    end
end

function _check_lateral_directional!(issues, Cn, Cl, CY, alphas, betas, sc, cfg)
    # Check Cn vs beta at α=0 (weathercock stability)
    i0_alpha = _find_nearest_index(alphas, 0.0)
    Cn_data = get(sc, "Cn", nothing)
    if !isnothing(Cn_data)
        vals_cfg = get(get(Cn_data, "values", Dict()), cfg, nothing)
        if !isnothing(vals_cfg) && !isempty(vals_cfg)
            Cn_row = vals_cfg[1][i0_alpha]
            if Cn_row isa Vector && length(Cn_row) == length(betas)
                ib_neg = _find_nearest_index(betas, -5.0)
                ib_pos = _find_nearest_index(betas, 5.0)
                if ib_neg != ib_pos
                    Cn_beta = (Cn_row[ib_pos] - Cn_row[ib_neg]) / (betas[ib_pos] - betas[ib_neg])
                    Cn_beta_rad = Cn_beta * 57.2958
                    if Cn_beta_rad < 0
                        push!(issues, ValidationIssue(:error, "yaw_stability",
                            "Aircraft is directionally UNSTABLE (Cn_β < 0)",
                            "Cn_β = $(round(Cn_beta_rad; digits=4))/rad, must be positive for weathercock stability"))
                    elseif Cn_beta_rad < 0.02
                        push!(issues, ValidationIssue(:warning, "yaw_stability",
                            "Very low directional stability",
                            "Cn_β = $(round(Cn_beta_rad; digits=4))/rad, typical 0.05–0.15"))
                    end
                end
            end
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Numeric integrity (NaN, Inf)
# ──────────────────────────────────────────────────────────────────

function _check_numeric_integrity!(issues, model)
    nan_count = 0
    inf_count = 0
    _scan_for_bad_numbers!(model, nan_count, inf_count)
    # Use a recursive scan approach
    nan_count, inf_count = _count_bad_numbers(model)
    if nan_count > 0
        push!(issues, ValidationIssue(:error, "numeric",
            "NaN values found in aerodynamic data",
            "$nan_count NaN values detected — these will cause simulation crashes"))
    end
    if inf_count > 0
        push!(issues, ValidationIssue(:error, "numeric",
            "Inf values found in aerodynamic data",
            "$inf_count Inf values detected — these will cause simulation crashes"))
    end
end

function _count_bad_numbers(data)
    nan_count = 0
    inf_count = 0
    if data isa Number
        isnan(data) && (nan_count += 1)
        isinf(data) && (inf_count += 1)
    elseif data isa AbstractDict
        for v in values(data)
            n, i = _count_bad_numbers(v)
            nan_count += n
            inf_count += i
        end
    elseif data isa AbstractVector
        for v in data
            n, i = _count_bad_numbers(v)
            nan_count += n
            inf_count += i
        end
    end
    return nan_count, inf_count
end

function _scan_for_bad_numbers!(data, nan_count, inf_count)
    # placeholder — real work done by _count_bad_numbers
end


# ──────────────────────────────────────────────────────────────────
# Report builder
# ──────────────────────────────────────────────────────────────────

function _build_report(issues::Vector{ValidationIssue})
    errors   = count(i -> i.severity == :error, issues)
    warnings = count(i -> i.severity == :warning, issues)
    infos    = count(i -> i.severity == :info, issues)
    passed   = errors == 0

    summary = if errors == 0 && warnings == 0
        "All checks passed ✓"
    elseif errors == 0
        "$warnings warning(s) — review recommended"
    else
        "$errors ERROR(s), $warnings warning(s) — FIX REQUIRED before use"
    end

    return ValidationReport(issues, passed, summary)
end

"""
    report_to_dict(report::ValidationReport) -> Dict

Convert a ValidationReport to a Dict suitable for YAML/JSON output.
"""
function report_to_dict(report::ValidationReport)
    issue_dicts = [Dict(
        "severity" => string(i.severity),
        "category" => i.category,
        "message"  => i.message,
        "detail"   => i.detail
    ) for i in report.issues]

    return Dict(
        "passed"  => report.passed,
        "summary" => report.summary,
        "errors"  => count(i -> i.severity == :error, report.issues),
        "warnings" => count(i -> i.severity == :warning, report.issues),
        "issues"  => issue_dicts
    )
end

"""
    print_report(report::ValidationReport; io=stdout)

Print a human-readable validation report to the console.
"""
function print_report(report::ValidationReport; io=stdout)
    println(io, "")
    println(io, "╔══════════════════════════════════════════════════════════════╗")
    println(io, "║            AERODYNAMIC DATA QUALITY REPORT                 ║")
    println(io, "╚══════════════════════════════════════════════════════════════╝")
    println(io, "")
    println(io, "  Result: $(report.summary)")
    println(io, "")

    if isempty(report.issues)
        println(io, "  No issues found.")
        return
    end

    # Print errors first, then warnings, then info
    for severity in [:error, :warning, :info]
        severity_issues = filter(i -> i.severity == severity, report.issues)
        if isempty(severity_issues)
            continue
        end
        label = severity == :error ? "ERROR" : severity == :warning ? "WARNING" : "INFO"
        marker = severity == :error ? "!!!" : severity == :warning ? " ! " : " i "

        for issue in severity_issues
            println(io, "  [$marker] $label: $(issue.message)")
            if !isempty(issue.detail)
                println(io, "         $(issue.detail)")
            end
            println(io, "")
        end
    end
end


# ──────────────────────────────────────────────────────────────────
# Helper utilities
# ──────────────────────────────────────────────────────────────────

function _extract_axes(sc)
    axes = get(sc, "axes", Dict())
    alphas = get(axes, "alpha_deg", nothing)
    betas  = get(axes, "beta_deg", nothing)
    configs = get(axes, "config", String[])
    machs  = get(axes, "mach", Float64[])
    return alphas, betas, configs, machs
end

function _axis_has_value(axis, target::Float64; tol::Float64=1e-6)
    isnothing(axis) && return false
    return any(abs(Float64(v) - target) <= tol for v in axis)
end

function _check_full_envelope_axes!(issues, alphas, betas, section_name::String)
    if isnothing(alphas) || isempty(alphas)
        push!(issues, ValidationIssue(:error, "envelope",
            "$(section_name) has no alpha axis",
            "AoA data must cover -180° to 180° for upset attitudes."))
    else
        a_min = minimum(Float64.(alphas))
        a_max = maximum(Float64.(alphas))
        if a_min > -180.0 + 1e-6 || a_max < 180.0 - 1e-6 ||
           !_axis_has_value(alphas, -180.0) || !_axis_has_value(alphas, 0.0) ||
           !_axis_has_value(alphas, 180.0)
            push!(issues, ValidationIssue(:error, "envelope",
                "$(section_name) alpha axis is not full-envelope",
                "AoA axis spans $(round(a_min; digits=1))° to $(round(a_max; digits=1))°. Required: exact -180°, 0°, and 180° samples."))
        end
    end

    if isnothing(betas)
        return
    end
    if isempty(betas)
        push!(issues, ValidationIssue(:error, "envelope",
            "$(section_name) has no beta axis",
            "AoS data must cover -180° to 180° for upset attitudes."))
        return
    end

    b_min = minimum(Float64.(betas))
    b_max = maximum(Float64.(betas))
    if b_min > -180.0 + 1e-6 || b_max < 180.0 - 1e-6 ||
       !_axis_has_value(betas, -180.0) || !_axis_has_value(betas, 0.0) ||
       !_axis_has_value(betas, 180.0)
        push!(issues, ValidationIssue(:error, "envelope",
            "$(section_name) beta axis is not full-envelope",
            "AoS axis spans $(round(b_min; digits=1))° to $(round(b_max; digits=1))°. Required: exact -180°, 0°, and 180° samples."))
    end
end

function _get_alpha_axis(section, fallback)
    axes = get(section, "axes", Dict())
    return get(axes, "alpha_deg", fallback)
end

function _find_nearest_index(arr, target)
    isnothing(arr) && return 1
    _, idx = findmin(abs.(arr .- target))
    return idx
end

function _extract_beta0_slice(sc, coeff_name, cfg, mach_idx, beta0_idx)
    coeff_data = get(sc, coeff_name, nothing)
    isnothing(coeff_data) && return nothing
    vals = get(coeff_data, "values", nothing)
    isnothing(vals) && return nothing
    cfg_vals = get(vals, cfg, nothing)
    isnothing(cfg_vals) && return nothing
    if isempty(cfg_vals) || mach_idx > length(cfg_vals)
        return nothing
    end
    mach_block = cfg_vals[mach_idx]
    if isempty(mach_block)
        return nothing
    end
    return [row isa Vector ? (beta0_idx <= length(row) ? row[beta0_idx] : 0.0) : Float64(row)
            for row in mach_block]
end

function _get_first_config_values(ddata)
    vals = get(ddata, "values", nothing)
    isnothing(vals) && return nothing
    if vals isa AbstractDict
        for (_, cfg_vals) in vals
            if cfg_vals isa AbstractVector && !isempty(cfg_vals)
                v = cfg_vals[1]
                return v isa AbstractVector ? v : [v]
            end
        end
    end
    return nothing
end
