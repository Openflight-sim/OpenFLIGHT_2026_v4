module Drag

using ...Utils: fig26

const _FIG54_X154 = Float64[0.24, 0.22, 0.20, 0.18, 0.16, 0.14, 0.12, 0.11, 0.10, 0.09, 0.08, 0.0]
const _FIG54_X254 = Float64[3.0, 3.5, 4.0, 4.5, 5.25, 5.50, 5.75, 6.0, 6.5, 7.0, 7.5, 8.0, 8.5, 9.0]
const _FIG54_Y = [
    [0.07, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18, 0.18],
    [0.047, 0.12, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177, 0.177],
    [0.03, 0.08, 0.124, 0.162, 0.197, 0.197, 0.197, 0.197, 0.197, 0.197, 0.197, 0.197, 0.197, 0.197],
    [0.017, 0.06, 0.091, 0.116, 0.147, 0.147, 0.147, 0.147, 0.147, 0.147, 0.147, 0.147, 0.147, 0.147],
    [0.0075, 0.0425, 0.063, 0.079, 0.0975, 0.0975, 0.0975, 0.0975, 0.0975, 0.0975, 0.0975, 0.0975, 0.0975, 0.0975],
    [0.00225, 0.023, 0.039, 0.05, 0.0625, 0.0625, 0.0625, 0.0625, 0.0625, 0.0625, 0.0625, 0.0625, 0.0625, 0.0625],
    [0.0, 0.01, 0.019, 0.028, 0.0385, 0.0375, 0.039, 0.044, 0.08, 0.133, 0.133, 0.133, 0.133, 0.133],
    [0.0, 0.005, 0.0125, 0.019, 0.0265, 0.024, 0.022, 0.0215, 0.0385, 0.068, 0.11, 0.16, 0.16, 0.16],
    [0.0, 0.0025, 0.008, 0.0125, 0.0175, 0.0135, 0.009, 0.0075, 0.012, 0.025, 0.048, 0.0825, 0.13, 0.13],
    [0.0, 0.0, 0.0035, 0.0075, 0.01, 0.0065, 0.003, 0.001, 0.0, 0.005, 0.012, 0.026, 0.05, 0.096],
    [0.0, 0.0, 0.0015, 0.003, 0.0045, 0.001, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.01, 0.0295],
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
]

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

function _interp1_desc(x::Real, xp::Vector{Float64}, fp::Vector{Float64})
    if isempty(xp) || isempty(fp)
        return 0.0
    elseif x >= xp[1]
        return fp[1]
    elseif x <= xp[end]
        return fp[end]
    end

    idx = 1
    for i in 1:(length(xp) - 1)
        if xp[i] >= x >= xp[i + 1]
            idx = i
            break
        end
    end
    x1 = xp[idx]
    x2 = xp[idx + 1]
    y1 = fp[idx]
    y2 = fp[idx + 1]
    t = x2 == x1 ? 0.0 : (x - x1) / (x2 - x1)
    return y1 + t * (y2 - y1)
end

function _interp2_fig54(x::Real, y::Real)
    xq = clamp(float(x), _FIG54_X154[end], _FIG54_X154[1])
    yq = clamp(float(y), _FIG54_X254[1], _FIG54_X254[end])

    row_vals = Float64[]
    for r in 1:length(_FIG54_X154)
        push!(row_vals, _interp1(yq, _FIG54_X254, _FIG54_Y[r]))
    end
    return _interp1_desc(xq, _FIG54_X154, row_vals)
end

function _estimate_wetted_area_ratio(state::Dict{String, Any})
    sref = _state_float(state, "options_sref", 0.0)
    if sref <= 0.0
        return _state_float(state, "body_swet_sref", 2.0)
    end

    ratio = 0.0

    wing_area = _state_float(state, "wing_area", 0.0)
    wing_tovc = _state_float(state, "wing_tovc", 0.10)
    if wing_area > 0.0
        ratio += 2.0 * (wing_area / sref) * (1.0 + 0.2 * wing_tovc)
    end

    htail_area = _state_float(state, "htail_area", 0.0)
    htail_tovc = _state_float(state, "htail_tovc", 0.08)
    if htail_area > 0.0
        ratio += 2.0 * (htail_area / sref) * (1.0 + 0.2 * htail_tovc)
    end

    vtail_area = _state_float(state, "vtail_area", 0.0)
    vtail_tovc = _state_float(state, "vtail_tovc", 0.09)
    if vtail_area > 0.0
        ratio += 2.0 * (vtail_area / sref) * (1.0 + 0.2 * vtail_tovc)
    end

    if ratio <= 0.0
        ratio = _state_float(state, "body_swet_sref", 2.0)
    end
    return ratio
end

function calculate_skin_friction_drag(state::Dict{String, Any}, mach::Real, reynolds::Real)
    # FLTCON RNNUB convention: Reynolds per unit length.
    # Convert to characteristic-length Reynolds for Cf lookup.
    cref = _state_float(state, "wing_mac", 0.0)
    if cref <= 0.0
        cref = _state_float(state, "options_cbarr", 1.0)
    end
    cref = max(cref, 1e-6)
    rn = max(float(reynolds), 1e3) * cref
    cf = fig26(rn, mach)
    swet_sref = _estimate_wetted_area_ratio(state)
    tovc = _state_float(state, "wing_tovc", 0.10)
    form_factor = _state_float(state, "body_form_factor", 1.0 + 0.6 * tovc)
    return cf * swet_sref * form_factor
end

function calculate_oswald_efficiency(aspect_ratio::Real; taper_ratio::Real = 0.5, sweep_deg::Real = 0.0)
    e = 1.78 * (1.0 - 0.045 * aspect_ratio^0.68) - 0.64
    e *= (1.0 - 0.05 * abs(taper_ratio - 0.4))
    if abs(sweep_deg) > 1.0
        e *= (1.0 - 0.1 * deg2rad(abs(sweep_deg)) / (π / 4.0))
    end
    return clamp(e, 0.7, 0.98)
end

function calculate_induced_drag(cl::Real, aspect_ratio::Real; efficiency_factor = nothing)
    aspect_ratio <= 0 && return 0.0
    e = efficiency_factor === nothing ? calculate_oswald_efficiency(aspect_ratio) : float(efficiency_factor)
    return cl^2 / (π * aspect_ratio * e)
end

function calculate_wave_drag_subsonic(mach::Real, thickness_ratio::Real)
    mcrit = 0.87 - thickness_ratio
    if mach < mcrit
        return 0.0
    end
    mdd = mcrit + 0.1
    if mach < mdd
        return 20.0 * (mach - mcrit)^4
    end
    return 0.002 + 20.0 * (mdd - mcrit)^4 + 0.01 * (mach - mdd)
end

function calculate_wave_drag_supersonic(mach::Real, thickness_ratio::Real, aspect_ratio::Real)
    mach <= 1.0 && return 0.0
    beta = sqrt(max(mach^2 - 1.0, 1e-10))
    cd_wave = 4.0 * thickness_ratio^2 / beta
    if aspect_ratio > 0
        cd_wave *= aspect_ratio / (aspect_ratio + 4.0 / beta)
    end
    return cd_wave
end

function calculate_total_drag(state::Dict{String, Any}, cl::Real, mach::Real, reynolds::Real; alpha_deg = nothing)
    aspect_ratio = _state_float(state, "wing_aspect_ratio", 6.0)
    taper_ratio = _state_float(state, "wing_taper_ratio", 0.5)
    thickness_ratio = _state_float(state, "wing_tovc", 0.12)
    sweep_deg = _state_float(state, "wing_savsi", 0.0)
    wing_type = _state_float(state, "wing_type", 1.0)
    sref = max(_state_float(state, "options_sref", 1.0), 1e-9)
    wing_area_raw = _state_float(state, "wing_area", sref)
    wing_area = wing_area_raw > 0.0 ? wing_area_raw : sref

    oswald_e_base = calculate_oswald_efficiency(aspect_ratio; taper_ratio = taper_ratio, sweep_deg = sweep_deg)
    oswald_e = oswald_e_base
    if wing_type >= 2.0
        sweep_factor = _interp1(abs(sweep_deg), [45.0, 60.0, 75.0, 85.0], [1.0, 0.95, 0.90, 0.86])
        ar_factor = _interp1(aspect_ratio, [1.0, 1.5, 2.5, 4.0], [0.95, 0.98, 1.0, 1.0])
        oswald_e = clamp(oswald_e * sweep_factor * ar_factor, 0.50, 0.95)
    end

    cd_friction = calculate_skin_friction_drag(state, mach, reynolds)
    cd_induced = calculate_induced_drag(cl, aspect_ratio; efficiency_factor = oswald_e)
    cd_datcom_extra = 0.0

    cd_wave = if mach < 0.9
        calculate_wave_drag_subsonic(mach, thickness_ratio)
    elseif mach > 1.2
        calculate_wave_drag_supersonic(mach, thickness_ratio, aspect_ratio)
    else
        cd_sub = calculate_wave_drag_subsonic(0.9, thickness_ratio)
        cd_sup = calculate_wave_drag_supersonic(1.2, thickness_ratio, aspect_ratio)
        frac = (mach - 0.9) / 0.3
        cd_sub + frac * (cd_sup - cd_sub)
    end

    if mach < 1.0 && wing_type >= 1.5 && wing_type < 2.5
        # DATCOM double-delta/curved approximation:
        # CDL = 0.95 * CL * tan(alpha)
        alpha_signed = alpha_deg === nothing ? rad2deg(atan(float(cl))) : float(alpha_deg)
        alpha_use = abs(alpha_signed)
        if alpha_signed >= 0.0
            k_cdl = wing_type < 2.25 ? 1.22 : 0.95
            cd_induced = k_cdl * abs(float(cl)) * abs(tan(deg2rad(alpha_use)))
        else
            # Negative-alpha branch is weaker in DATCOM double-delta trends.
            cd_induced = 0.22 * max(abs(float(cl)) - 0.04, 0.0)^1.35
        end
        cd_datcom_extra = cd_induced
    elseif mach < 1.0 && wing_type >= 2.5
        # DATCOM cranked-wing branch: induced term with R-prime-like e(Re)
        # and FIG 4.1.5.2-54 delta-CDL correction.
        ar_safe = max(aspect_ratio, 0.25)
        area_ratio = wing_area / sref
        inv_area_ratio = sref / wing_area

        reynolds_factor = clamp((max(float(reynolds), 1.0e4) / 1.0e6)^0.40, 0.58, 1.18)
        e_re = clamp(oswald_e_base * reynolds_factor, 0.35, 0.98)

        cd_quad = (float(cl)^2 / (pi * ar_safe * e_re)) * inv_area_ratio
        temp = abs(float(cl)) / ar_safe * inv_area_ratio
        d25 = _interp2_fig54(temp, ar_safe)
        cd_54 = d25 * area_ratio

        cd_induced = cd_quad + cd_54
        if alpha_deg !== nothing
            alpha_use = abs(float(alpha_deg))
            # Empirical low-alpha attenuation for cranked-wing subsonic
            # drag buildup; approaches unity by moderate alpha.
            low_alpha_scale = alpha_use < 8.0 ? (0.52 + 0.48 * alpha_use / 8.0) : 1.0
            cd_induced *= low_alpha_scale
        end
        cd_datcom_extra = cd_54
    end

    if mach < 1.0 && wing_type < 1.5 && alpha_deg !== nothing
        htail_area = _state_float(state, "htail_area", 0.0)
        alpha_pos = max(float(alpha_deg), 0.0)
        if alpha_pos > 2.0 && htail_area <= 1e-6
            sweep_gain = 0.6 + 0.4 * clamp(abs(sweep_deg) / 60.0, 0.0, 1.0)
            ar_gain = clamp(3.0 / max(aspect_ratio, 1.0), 0.8, 2.2)
            cd_alpha_extra = 0.060 * deg2rad(alpha_pos - 2.0) * sweep_gain * ar_gain
            cd_induced += cd_alpha_extra
            cd_datcom_extra += cd_alpha_extra
        end
    end

    if mach < 1.0 && wing_type < 1.5
        htail_area = _state_float(state, "htail_area", 0.0)
        xh = _state_float(state, "synths_xh", Inf)
        xcg = _state_float(state, "synths_xcg", 0.0)
        if htail_area > 0.0 && xh < xcg
            # Forward lifting-surface layouts carry lower net induced drag than
            # a single lifting surface at the same total CL.
            canard_scale = _state_float(state, "drag_canard_induced_scale_sub", 0.82)
            cd_induced *= canard_scale
        end
    end

    cd_misc = _state_float(state, "drag_misc", 0.0005)
    cd_vortex = if wing_type >= 2.0 && mach < 1.0
        0.0
    elseif wing_type >= 2.0
        0.005 * max(abs(float(cl)) - 0.35, 0.0)^1.2
    else
        0.0
    end
    cd_total = cd_friction + cd_induced + cd_wave + cd_vortex + cd_misc

    return Dict(
        "cd_total" => cd_total,
        "cd_friction" => cd_friction,
        "cd_induced" => cd_induced,
        "cd_wave" => cd_wave,
        "cd_vortex" => cd_vortex,
        "cd_datcom_extra" => cd_datcom_extra,
        "cd_misc" => cd_misc,
        "oswald_e" => oswald_e,
    )
end

mutable struct DragCalculator
    state::Dict{String, Any}
end

function calculate_drag(calc::DragCalculator, cl::Real, mach::Real, reynolds::Real; alpha_deg = nothing)
    return calculate_total_drag(calc.state, cl, mach, reynolds; alpha_deg = alpha_deg)
end

function calculate_drag_polar(
    calc::DragCalculator,
    mach::Real,
    reynolds::Real;
    cl_range = collect(range(-0.5, 2.0, length = 26)),
)
    cd_values = zeros(length(cl_range))
    for (i, cl) in enumerate(cl_range)
        cd_values[i] = calculate_drag(calc, cl, mach, reynolds)["cd_total"]
    end
    return Dict(
        "cl" => collect(cl_range),
        "cd" => cd_values,
        "mach" => float(mach),
        "reynolds" => float(reynolds),
    )
end

export calculate_skin_friction_drag
export calculate_induced_drag
export calculate_oswald_efficiency
export calculate_wave_drag_subsonic
export calculate_wave_drag_supersonic
export calculate_total_drag
export DragCalculator
export calculate_drag
export calculate_drag_polar

end
