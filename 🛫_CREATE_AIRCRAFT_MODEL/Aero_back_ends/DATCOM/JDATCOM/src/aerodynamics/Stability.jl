module Stability

function _state_float(state::Dict{String, Any}, key::String, default::Float64)
    v = get(state, key, default)
    if v === nothing
        return default
    elseif v isa Number
        return float(v)
    elseif v isa AbstractVector
        isempty(v) && return default
        if v[1] isa Number
            return float(v[1])
        elseif v[1] isa AbstractString
            try
                return parse(Float64, v[1])
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

function calculate_pitch_damping(state::Dict{String, Any}, mach::Real)
    aspect_ratio = _state_float(state, "wing_aspect_ratio", 6.0)
    cmq_wing = -2.0 * aspect_ratio / (aspect_ratio + 2.0)

    if mach < 0.9
        beta = sqrt(max(1.0 - mach^2, 1e-10))
        cmq_wing /= beta
    end

    htail_area = _state_float(state, "htail_area", 0.0)
    if htail_area > 0
        sref = _state_float(state, "options_sref", 1.0)
        tail_volume = htail_area / sref
        cmq_tail = -10.0 * tail_volume
    else
        cmq_tail = 0.0
    end

    return Dict(
        "cmq" => cmq_wing + cmq_tail,
        "cmq_wing" => cmq_wing,
        "cmq_tail" => cmq_tail,
    )
end

function calculate_roll_damping(state::Dict{String, Any}, mach::Real)
    aspect_ratio = _state_float(state, "wing_aspect_ratio", 6.0)
    cla = if mach < 0.9
        beta = sqrt(max(1.0 - mach^2, 1e-10))
        (2.0 * π * aspect_ratio) / (2.0 + sqrt(4.0 + aspect_ratio^2)) / beta
    else
        beta_super = mach > 1.0 ? sqrt(max(mach^2 - 1.0, 1e-10)) : 0.1
        4.0 / beta_super
    end
    return -cla / 12.0
end

function calculate_yaw_damping(state::Dict{String, Any}, mach::Real)
    vtail_area = _state_float(state, "vtail_area", 0.0)
    sref = _state_float(state, "options_sref", 1.0)
    if vtail_area > 0 && sref > 0
        vtail_volume = vtail_area / sref
        return -2.0 * vtail_volume
    end
    return -0.1
end

function calculate_static_stability_margin(state::Dict{String, Any}, mach::Real)
    xcg = _state_float(state, "synths_xcg", 0.0)
    cbar = _state_float(state, "options_cbarr", 1.0)
    xw = _state_float(state, "synths_xw", 0.0)
    xnp_wing = xw + 0.25 * cbar

    htail_area = _state_float(state, "htail_area", 0.0)
    sref = _state_float(state, "options_sref", 1.0)
    xnp = xnp_wing
    if htail_area > 0 && sref > 0
        xh = _state_float(state, "synths_xh", xw + 2.0 * cbar)
        tail_volume = (htail_area / sref) * (xh - xcg) / cbar
        xnp = xnp_wing + tail_volume * cbar
    end

    static_margin = cbar > 0 ? (xnp - xcg) / cbar : 0.0
    return Dict(
        "xnp" => xnp,
        "xcg" => xcg,
        "static_margin" => static_margin,
        "stable" => static_margin > 0.05,
    )
end

function calculate_directional_stability(state::Dict{String, Any}, mach::Real)
    vtail_area = _state_float(state, "vtail_area", 0.0)
    sref = _state_float(state, "options_sref", 1.0)
    bref = _state_float(state, "options_blref", 10.0)

    if vtail_area > 0 && sref > 0
        xv = _state_float(state, "synths_xv", 20.0)
        xcg = _state_float(state, "synths_xcg", 10.0)
        tail_arm = xv - xcg
        volume_v = (vtail_area / sref) * (tail_arm / bref)
        return volume_v * 3.0
    end
    return 0.05
end

function calculate_all_stability_derivatives(state::Dict{String, Any}, mach::Real)
    pitch_damp = calculate_pitch_damping(state, mach)
    stability = calculate_static_stability_margin(state, mach)
    clp = calculate_roll_damping(state, mach)
    cnr = calculate_yaw_damping(state, mach)
    cnbeta = calculate_directional_stability(state, mach)

    return Dict(
        "cmq" => pitch_damp["cmq"],
        "cm_alpha_dot" => pitch_damp["cmq"] / 2.0,
        "xnp" => stability["xnp"],
        "static_margin" => stability["static_margin"],
        "longitudinally_stable" => stability["stable"],
        "clp" => clp,
        "cnr" => cnr,
        "cn_beta" => cnbeta,
        "directionally_stable" => cnbeta > 0,
    )
end

mutable struct StabilityCalculator
    state::Dict{String, Any}
end

function calculate_derivatives(calc::StabilityCalculator, mach::Real)
    return calculate_all_stability_derivatives(calc.state, mach)
end

function assess_stability(calc::StabilityCalculator, mach::Real)
    derivs = calculate_derivatives(calc, mach)

    assessment = Dict{String, Any}(
        "longitudinal" => derivs["longitudinally_stable"] ? "stable" : "unstable",
        "directional" => derivs["directionally_stable"] ? "stable" : "unstable",
        "static_margin_percent" => derivs["static_margin"] * 100,
        "derivatives" => derivs,
    )

    if derivs["longitudinally_stable"] && derivs["directionally_stable"]
        assessment["overall"] = "stable"
    elseif derivs["longitudinally_stable"] || derivs["directionally_stable"]
        assessment["overall"] = "partially stable"
    else
        assessment["overall"] = "unstable"
    end
    return assessment
end

export calculate_pitch_damping
export calculate_roll_damping
export calculate_yaw_damping
export calculate_static_stability_margin
export calculate_directional_stability
export calculate_all_stability_derivatives
export StabilityCalculator
export calculate_derivatives
export assess_stability

end
