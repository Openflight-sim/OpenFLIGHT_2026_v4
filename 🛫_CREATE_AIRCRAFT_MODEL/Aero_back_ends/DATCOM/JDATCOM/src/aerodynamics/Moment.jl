module Moment

using ..Lift: calculate_lift_curve_slope_compressible

function _state_float(state::Dict{String, Any}, key::String, default::Float64)
    v = get(state, key, default)
    if v === nothing
        return default
    elseif v isa Number
        return float(v)
    elseif v isa AbstractVector
        isempty(v) && return default
        item = v[1]
        if item isa Number
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

function _interp1(x::Real, xp::Vector{Float64}, fp::Vector{Float64})
    if isempty(xp) || isempty(fp)
        return 0.0
    elseif x <= xp[1]
        return fp[1]
    elseif x >= xp[end]
        return fp[end]
    end
    idx = clamp(searchsortedlast(xp, x), 1, length(xp) - 1)
    x1 = xp[idx]
    x2 = xp[idx + 1]
    y1 = fp[idx]
    y2 = fp[idx + 1]
    t = x2 == x1 ? 0.0 : (x - x1) / (x2 - x1)
    return y1 + t * (y2 - y1)
end

function calculate_wing_moment_coefficient(cl::Real, xac::Real, xcg::Real, mac::Real, cbar::Real)
    moment_arm = cbar > 0 ? (xac - xcg) / cbar : 0.0
    cm0 = 0.0
    return cm0 + cl * moment_arm
end

function calculate_body_pitching_moment(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    length_body = _state_float(state, "body_length", 0.0)
    max_area = _state_float(state, "body_max_area", 0.0)
    centroid = _state_float(state, "body_centroid", length_body / 2.0)

    sref = _state_float(state, "options_sref", 1.0)
    cbar = _state_float(state, "options_cbarr", 1.0)
    xcg = _state_float(state, "synths_xcg", length_body > 0 ? length_body / 2.0 : 0.0)
    if sref <= 0 || cbar <= 0
        return 0.0
    end

    alpha_rad = deg2rad(alpha_deg)
    cn_body = max_area > 0 ? (max_area / sref) * sin(2.0 * alpha_rad) : 0.0
    moment_arm = (centroid - xcg) / cbar
    return -cn_body * moment_arm
end

function calculate_tail_moment_contribution(state::Dict{String, Any}, cl_tail::Real; tail_type::String = "htail")
    area_tail = _state_float(state, "$(tail_type)_area", 0.0)
    x_tail = tail_type == "htail" ? _state_float(state, "synths_xh", 0.0) : _state_float(state, "synths_xv", 0.0)
    sref = _state_float(state, "options_sref", 1.0)
    cbar = _state_float(state, "options_cbarr", 1.0)
    xcg = _state_float(state, "synths_xcg", 0.0)

    if sref <= 0 || cbar <= 0
        return 0.0
    end
    if area_tail > 0 && x_tail > xcg
        moment_arm = (x_tail - xcg) / cbar
        volume_coef = (area_tail / sref) * moment_arm
        return -cl_tail * volume_coef
    end
    return 0.0
end

function calculate_total_pitching_moment(state::Dict{String, Any}, cl_wing::Real, alpha_deg::Real, mach::Real)
    xac_wing = _state_float(state, "wing_xac", 0.25)
    xcg = _state_float(state, "synths_xcg", 0.0)
    xw = _state_float(state, "synths_xw", 0.0)
    cbar = _state_float(state, "options_cbarr", 1.0)
    xac_abs = xw + xac_wing * cbar
    htail_area = _state_float(state, "htail_area", 0.0)

    wing_cmo = _state_float(state, "wing_cmo", 0.0)
    wing_clalpa = _state_float(state, "wing_clalpa", 0.0)
    wing_type = _state_float(state, "wing_type", 1.0)
    if wing_clalpa > 0.0
        # DATCOM-like empirical Cm(alpha): CMO + CMA*alpha, tuned by wing class
        # and Mach regime to better track low-AR swept-wing trends.
        cma_scale_default = wing_type >= 2.0 ? 0.11 : 0.09
        cma_scale = _state_float(state, "moment_cma_scale", cma_scale_default)
        cma_mach_factor = if mach < 1.2
            _interp1(mach, [0.0, 0.6, 1.0], [1.0, 1.0, 0.95])
        elseif wing_type < 2.0
            _interp1(mach, [1.2, 1.6, 2.5, 4.0], [1.05, 1.0, 0.66, 0.55])
        else
            _interp1(mach, [1.2, 2.5, 4.0], [0.90, 0.66, 0.55])
        end
        cm_alpha_per_deg = -cma_scale * wing_clalpa * cma_mach_factor
        alpha_for_cma = if alpha_deg < 0.0
            if wing_type >= 2.0
                0.55 * float(alpha_deg)
            elseif mach < 1.2
                0.82 * float(alpha_deg)
            else
                float(alpha_deg)
            end
        else
            float(alpha_deg)
        end

        cmo_mach_factor = if mach < 1.2
            wing_type < 2.0 ? 1.30 : 0.74
        elseif wing_type < 2.0
            _interp1(mach, [1.2, 1.6, 2.5, 4.0], [1.05, 0.95, 0.60, 0.50])
        else
            _interp1(mach, [1.2, 2.5, 4.0], [0.90, 0.60, 0.50])
        end
        cmo_eff = wing_cmo * cmo_mach_factor

        static_margin = cbar > 0 ? (xcg - xac_abs) / cbar : 0.0
        geometric_term = -0.05 * cl_wing * static_margin

        cm_wing = cmo_eff + cm_alpha_per_deg * alpha_for_cma + geometric_term
        if mach < 1.0 && wing_type >= 2.0 && alpha_deg > 6.0
            alpha_excess = float(alpha_deg) - 6.0
            k_alpha2_default = wing_type >= 2.5 ? 2.9e-4 : 1.1e-4
            k_alpha2 = _state_float(state, "moment_alpha2_gain", k_alpha2_default)
            cm_wing -= k_alpha2 * alpha_excess^2
        end
    else
        moment_arm = cbar > 0 ? (xac_abs - xcg) / cbar : 0.0
        xh = _state_float(state, "synths_xh", Inf)
        has_forward_canard = htail_area > 0.0 && xh < xcg
        if mach < 1.0
            base_gain_default = has_forward_canard ? 0.115 : 0.08
            base_gain = _state_float(state, "moment_arm_gain_sub", base_gain_default)
            alpha_abs = abs(float(alpha_deg))
            taper = alpha_abs <= 5.0 ? 1.0 : max(0.35, 1.0 - 0.03 * (alpha_abs - 5.0))
            arm_gain = base_gain * taper
        else
            arm_gain_default = has_forward_canard ? 0.58 : 0.65
            arm_gain = _state_float(state, "moment_arm_gain_sup", arm_gain_default)
        end
        cm_wing = wing_cmo + cl_wing * moment_arm * arm_gain
        if mach < 1.0 && htail_area > 0.0
            if xh < xcg && alpha_deg > 12.0
                # Forward-surface pitch-up seen in canard-like layouts at high alpha.
                k_pitchup = _state_float(state, "moment_canard_pitchup_k", 0.0010)
                cm_wing += k_pitchup * (alpha_deg - 12.0)^2
            end
        elseif mach >= 1.0 && has_forward_canard
            if alpha_deg > 10.0
                # Supersonic forward-surface layouts develop stronger nose-up
                # normal force ahead of CG at high alpha; add nonlinear Cm drop.
                k_sup = _state_float(state, "moment_canard_sup_alpha2", 0.0016)
                cm_wing -= k_sup * (alpha_deg - 10.0)^2
            end
        end
    end

    cm_body = calculate_body_pitching_moment(state, alpha_deg, mach)
    cm_tail = 0.0
    if htail_area > 0.0 && wing_clalpa <= 0.0
        htail_ar = _state_float(state, "htail_aspect_ratio", 4.0)
        htail_taper = _state_float(state, "htail_taper_ratio", 0.5)
        htail_sweep = _state_float(state, "htail_savsi", 0.0)
        htail_alphai = _state_float(state, "htail_alphai", 0.0)
        alih = _state_float(state, "synths_alih", 0.0)
        cla_h = calculate_lift_curve_slope_compressible(htail_ar, htail_taper, mach; sweep_angle_deg = htail_sweep)
        cl_tail_local = cla_h * deg2rad(alpha_deg + alih - htail_alphai)
        cm_tail = calculate_tail_moment_contribution(state, cl_tail_local; tail_type = "htail")
    end
    cm_total = cm_wing + cm_body + cm_tail

    return Dict(
        "cm_total" => cm_total,
        "cm_wing" => cm_wing,
        "cm_body" => cm_body,
        "cm_tail" => cm_tail,
        "xcg" => xcg,
        "xac" => xac_abs,
    )
end

function calculate_normal_force_coefficient(cl::Real, cd::Real, alpha_deg::Real)
    alpha_rad = deg2rad(alpha_deg)
    return cl * cos(alpha_rad) + cd * sin(alpha_rad)
end

function calculate_axial_force_coefficient(cl::Real, cd::Real, alpha_deg::Real)
    alpha_rad = deg2rad(alpha_deg)
    return cd * cos(alpha_rad) - cl * sin(alpha_rad)
end

mutable struct MomentCalculator
    state::Dict{String, Any}
end

function calculate_moment(calc::MomentCalculator, cl::Real, alpha_deg::Real, mach::Real)
    return calculate_total_pitching_moment(calc.state, cl, alpha_deg, mach)
end

function calculate_moment_curve_slope(calc::MomentCalculator, mach::Real)
    xcg = _state_float(calc.state, "synths_xcg", 0.0)
    xnp = _state_float(calc.state, "wing_xnp", xcg + 0.1)
    cbar = _state_float(calc.state, "options_cbarr", 1.0)
    aspect_ratio = _state_float(calc.state, "wing_aspect_ratio", 6.0)
    taper_ratio = _state_float(calc.state, "wing_taper_ratio", 0.5)
    cla = calculate_lift_curve_slope_compressible(aspect_ratio, taper_ratio, mach)
    return cbar > 0 ? -cla * (xnp - xcg) / cbar : 0.0
end

export calculate_wing_moment_coefficient
export calculate_body_pitching_moment
export calculate_tail_moment_contribution
export calculate_total_pitching_moment
export calculate_normal_force_coefficient
export calculate_axial_force_coefficient
export MomentCalculator
export calculate_moment
export calculate_moment_curve_slope

end
