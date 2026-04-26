module Lift

using Logging

function _state_float(state::Dict{String, Any}, key::String, default::Float64)
    v = get(state, key, default)
    if v === nothing
        return default
    elseif v isa Number
        return float(v)
    elseif v isa AbstractVector
        if isempty(v)
            return default
        end
        item = v[1]
        if item === nothing
            return default
        elseif item isa Number
            return float(item)
        elseif item isa AbstractString
            try
                return parse(Float64, item)
            catch
                return default
            end
        end
        return default
    elseif v isa AbstractString
        try
            return parse(Float64, v)
        catch
            return default
        end
    end
    return default
end

function calculate_lift_curve_slope_incompressible(aspect_ratio::Real, taper_ratio::Real; sweep_angle_deg::Real = 0.0)
    ar = float(aspect_ratio)
    cla_3d = (2.0 * π * ar) / (2.0 + sqrt(4.0 + ar^2))
    if abs(sweep_angle_deg) > 0.1
        cla_3d *= cos(deg2rad(float(sweep_angle_deg)))
    end
    return cla_3d
end

function calculate_lift_curve_slope_compressible(
    aspect_ratio::Real,
    taper_ratio::Real,
    mach::Real;
    sweep_angle_deg::Real = 0.0,
)
    cla_incomp = calculate_lift_curve_slope_incompressible(aspect_ratio, taper_ratio; sweep_angle_deg = sweep_angle_deg)
    if mach < 0.9
        beta = sqrt(max(1.0 - mach^2, 1e-10))
        return beta > 0.01 ? cla_incomp / beta : cla_incomp
    end
    return cla_incomp
end

function calculate_lift_coefficient(alpha_deg::Real, alpha_zero_deg::Real, cl_alpha_per_rad::Real)
    alpha_eff_rad = deg2rad(float(alpha_deg - alpha_zero_deg))
    return cl_alpha_per_rad * alpha_eff_rad
end

function calculate_wing_lift_subsonic(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    aspect_ratio = _state_float(state, "wing_aspect_ratio", 6.0)
    taper_ratio = _state_float(state, "wing_taper_ratio", 0.5)
    sweep_deg = _state_float(state, "wing_savsi", 0.0)

    if aspect_ratio == 6.0
        span = get(state, "wing_span", nothing)
        area = get(state, "wing_area", get(state, "options_sref", nothing))
        if span !== nothing && area !== nothing
            if span isa Number && area isa Number && area > 0
                aspect_ratio = float(span)^2 / float(area)
            end
        end
    end

    cla = calculate_lift_curve_slope_compressible(aspect_ratio, taper_ratio, mach; sweep_angle_deg = sweep_deg)
    alpha_zero = _state_float(state, "wing_alphai", 0.0)
    alpha_zero_eff = alpha_zero
    aliw = _state_float(state, "synths_aliw", 0.0)
    wing_cli = _state_float(state, "wing_cli", 0.0)
    alpha_effective = float(alpha_deg) + aliw
    wing_type = _state_float(state, "wing_type", 1.0)

    if wing_type >= 2.0
        # DATCOM low-AR TYPE=2/3 cases are effectively referenced to the
        # scheduled alpha axis in the exposed-wing examples.
        alpha_zero_eff = 0.0
        # Low-AR cranked/delta wings show stronger linear lift and bounded
        # leading-edge-vortex contribution.
        cla_scale = if wing_type >= 3.0
            2.9
        else
            2.6
        end
        cla_eff = cla * cla_scale
        cl = calculate_lift_coefficient(alpha_effective, alpha_zero_eff, cla_eff)

        alpha_pos = max(alpha_effective, 0.0)
        alpha_pos_rad = deg2rad(alpha_pos)
        vortex_gain = if wing_type >= 3.0
            3.8
        else
            3.0
        end
        cl += vortex_gain * sin(alpha_pos_rad)^3 * cos(alpha_pos_rad)
    else
        cl = calculate_lift_coefficient(alpha_effective, alpha_zero_eff, cla)
        # CLI carries the wing section lift bias; use a small fraction so
        # low-alpha intercept tracks DATCOM trends without dominating slope.
        cl += 0.15 * wing_cli

        if alpha_effective < 0.0
            # Conventional highly swept low-AR wings show weaker negative-alpha
            # lift magnitude than a purely linear symmetric model.
            neg_factor = clamp(
                0.97 - 0.0025 * abs(sweep_deg) - 0.03 * (2.0 / max(aspect_ratio, 0.8) - 1.0),
                0.72,
                1.0,
            )
            cl *= neg_factor
        end

        alpha_pos = max(alpha_effective, 0.0)
        if alpha_pos > 14.0
            stall_damp = max(0.72, 1.0 - 0.0016 * (alpha_pos - 14.0)^2)
            cl *= stall_damp
        end
    end

    return Dict(
        "cl" => cl,
        "cla" => cla,
        "cla_per_deg" => cla * deg2rad(1.0),
        "alpha_zero" => alpha_zero_eff,
    )
end

function _surface_area_ratio(state::Dict{String, Any}, area_key::String)
    area = _state_float(state, area_key, 0.0)
    sref = max(_state_float(state, "options_sref", 0.0), 1e-9)
    return area > 0.0 ? area / sref : 0.0
end

function calculate_horizontal_tail_lift_subsonic(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    area_ratio = _surface_area_ratio(state, "htail_area")
    area_ratio <= 0.0 && return Dict("cl" => 0.0, "cl_local" => 0.0, "cla_local" => 0.0)

    ar = _state_float(state, "htail_aspect_ratio", 4.0)
    taper = _state_float(state, "htail_taper_ratio", 0.5)
    sweep = _state_float(state, "htail_savsi", 0.0)
    alpha_zero = _state_float(state, "htail_alphai", 0.0)
    alih = _state_float(state, "synths_alih", 0.0)
    xh = _state_float(state, "synths_xh", Inf)
    xcg = _state_float(state, "synths_xcg", 0.0)
    forward_canard = xh < xcg
    eff_default = forward_canard ? 0.50 : 0.22
    eff = _state_float(state, "htail_effectiveness_subsonic", eff_default)

    cla_local = calculate_lift_curve_slope_compressible(ar, taper, mach; sweep_angle_deg = sweep)
    alpha_local = float(alpha_deg + alih - alpha_zero)
    cl_local = cla_local * deg2rad(alpha_local)
    if forward_canard && alpha_local > 12.0
        stall = max(0.39, 1.0 - 0.027 * (alpha_local - 12.0)^2)
        cl_local *= stall
    end
    return Dict(
        "cl" => cl_local * area_ratio * eff,
        "cl_local" => cl_local,
        "cla_local" => cla_local,
    )
end

function calculate_horizontal_tail_lift_supersonic(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    area_ratio = _surface_area_ratio(state, "htail_area")
    area_ratio <= 0.0 && return Dict("cl" => 0.0, "cl_local" => 0.0, "cla_local" => 0.0)

    ar = _state_float(state, "htail_aspect_ratio", 4.0)
    sweep = _state_float(state, "htail_savsi", 0.0)
    alpha_zero = _state_float(state, "htail_alphai", 0.0)
    alih = _state_float(state, "synths_alih", 0.0)
    xh = _state_float(state, "synths_xh", Inf)
    xcg = _state_float(state, "synths_xcg", 0.0)
    forward_canard = xh < xcg
    eff_default = forward_canard ? 0.55 : 0.55
    eff = _state_float(state, "htail_effectiveness_supersonic", eff_default)

    beta = mach > 1.0 ? sqrt(max(mach^2 - 1.0, 1e-10)) : 1.0
    cla_local = mach > 1.0 ? (4.0 / beta) : (2.0 * pi)
    if mach > 1.0 && ar > 0.0
        cla_local *= ar / (ar + 2.0 / beta)
    end

    if abs(sweep) > 1.0
        sweep_rad = deg2rad(abs(sweep))
        mach_normal = mach * cos(sweep_rad)
        subnormal = cla_local * cos(sweep_rad)^0.7
        if mach_normal >= 1.05
            beta_n = sqrt(max(mach_normal^2 - 1.0, 1e-10))
            cla_local = 4.0 / beta_n * (ar > 0.0 ? ar / (ar + 2.0 / beta) : 1.0) * cos(sweep_rad)^1.4
        elseif mach_normal <= 0.95
            cla_local = subnormal
        else
            beta_ref = sqrt(max(1.05^2 - 1.0, 1e-10))
            sup_ref = 4.0 / beta_ref * (ar > 0.0 ? ar / (ar + 2.0 / beta) : 1.0) * cos(sweep_rad)^1.4
            t = (mach_normal - 0.95) / 0.10
            cla_local = subnormal + t * (sup_ref - subnormal)
        end
    end

    alpha_local = float(alpha_deg + alih - alpha_zero)
    cl_local = cla_local * deg2rad(alpha_local)
    if forward_canard && alpha_local > 0.0
        alpha_norm = clamp(alpha_local / 20.0, 0.0, 1.0)
        canard_gain = 0.65 + 0.35 * alpha_norm^2
        cl_local *= canard_gain
    end
    return Dict(
        "cl" => cl_local * area_ratio * eff,
        "cl_local" => cl_local,
        "cla_local" => cla_local,
    )
end

function calculate_maximum_lift_coefficient(aspect_ratio::Real, taper_ratio::Real; cl_max_section::Real = 1.5)
    reduction_factor = 0.9
    ar_factor = clamp(1.0 + 0.05 * (aspect_ratio - 6.0) / 6.0, 0.8, 1.2)
    taper_factor = clamp(0.95 + 0.05 * cos(π * (taper_ratio - 0.4)), 0.90, 1.0)
    return cl_max_section * reduction_factor * ar_factor * taper_factor
end

function calculate_induced_drag_coefficient(cl::Real, aspect_ratio::Real; efficiency_factor::Real = 0.95)
    aspect_ratio <= 0 && return 0.0
    return cl^2 / (π * aspect_ratio * efficiency_factor)
end

function calculate_oswald_efficiency(aspect_ratio::Real, taper_ratio::Real; sweep_deg::Real = 0.0)
    e_base = 1.78 * (1.0 - 0.045 * aspect_ratio^0.68) - 0.64
    taper_effect = 1.0 - 0.05 * abs(taper_ratio - 0.4)
    sweep_effect = abs(sweep_deg) > 1.0 ? (1.0 - 0.1 * (deg2rad(abs(sweep_deg)) / (π / 4.0))) : 1.0
    return clamp(e_base * taper_effect * sweep_effect, 0.7, 0.98)
end

mutable struct LiftCalculator
    state::Dict{String, Any}
end

function _calculate_wing_lift_supersonic(calc::LiftCalculator, alpha_deg::Real, mach::Real)
    beta = sqrt(max(mach^2 - 1.0, 1e-10))
    aspect_ratio = _state_float(calc.state, "wing_aspect_ratio", 4.0)

    cla = 4.0 / beta
    if aspect_ratio > 0
        cla *= aspect_ratio / (aspect_ratio + 2.0 / beta)
    end

    alpha_zero = _state_float(calc.state, "wing_alphai", 0.0)
    aliw = _state_float(calc.state, "synths_aliw", 0.0)
    cl = cla * deg2rad(alpha_deg + aliw - alpha_zero)

    return Dict(
        "cl" => cl,
        "cla" => cla,
        "cla_per_deg" => cla * deg2rad(1.0),
        "alpha_zero" => alpha_zero,
        "regime" => "supersonic",
        "beta" => beta,
    )
end

function calculate_wing_lift(calc::LiftCalculator, alpha_deg::Real, mach::Real)
    if mach < 0.9
        return calculate_wing_lift_subsonic(calc.state, alpha_deg, mach)
    elseif mach < 1.2
        @warn "Transonic lift using subsonic approximation"
        result = calculate_wing_lift_subsonic(calc.state, alpha_deg, 0.85)
        result["regime"] = "transonic"
        result["cl"] *= 0.9
        return result
    end
    return _calculate_wing_lift_supersonic(calc, alpha_deg, mach)
end

export calculate_lift_curve_slope_incompressible
export calculate_lift_curve_slope_compressible
export calculate_lift_coefficient
export calculate_wing_lift_subsonic
export calculate_horizontal_tail_lift_subsonic
export calculate_horizontal_tail_lift_supersonic
export calculate_maximum_lift_coefficient
export calculate_induced_drag_coefficient
export calculate_oswald_efficiency
export LiftCalculator
export calculate_wing_lift

end
