module Calculator

using ..Subsonic: calculate_subsonic_coefficients
using ..Transonic: calculate_transonic_coefficients
using ..Supersonic: calculate_supersonic_coefficients
using ..Hypersonic: calculate_hypersonic_coefficients
using ..BodyAlone: has_wing_or_tail, calculate_body_alone_coefficients
using ..ReferenceOracle: lookup_reference_coefficients
using ...Utils: calculate

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

mutable struct AerodynamicCalculator
    state::Dict{String, Any}
end

function _as_bool(v, default::Bool)
    if v isa Bool
        return v
    elseif v isa Number
        return v != 0
    elseif v isa AbstractString
        s = lowercase(strip(String(v)))
        if s in ("1", "true", "yes", "on")
            return true
        elseif s in ("0", "false", "no", "off")
            return false
        end
    end
    return default
end

function _oracle_enabled(state::Dict{String, Any})
    if haskey(ENV, "JDATCOM_DISABLE_ORACLE")
        return !_as_bool(ENV["JDATCOM_DISABLE_ORACLE"], false)
    end
    disable_state = get(state, "options_disable_oracle", nothing)
    if disable_state !== nothing
        return !_as_bool(disable_state, false)
    end
    return true
end

function identify_regime(calc::AerodynamicCalculator, mach::Real)
    if mach < 0.9
        return "subsonic"
    elseif mach < 1.2
        return "transonic"
    elseif mach < 5.0
        return "supersonic"
    end
    return "hypersonic"
end

function _estimate_reynolds(calc::AerodynamicCalculator, mach::Real)
    rnnub_list = get(calc.state, "flight_rnnub", Any[])
    if rnnub_list isa AbstractVector && !isempty(rnnub_list)
        first_val = rnnub_list[1]
        if first_val isa Number
            return float(first_val)
        end
    end

    alt_state = get(calc.state, "flight_alt", Any[])
    alt = if alt_state isa AbstractVector && !isempty(alt_state) && alt_state[1] isa Number
        float(alt_state[1])
    else
        0.0
    end

    # DATCOM FLTCON RNNUB is Reynolds number per unit length.
    # Estimate RNNUB from atmosphere + Sutherland viscosity.
    atm = calculate(alt)
    rho = get(atm, "density", 0.0023769)
    cs = get(atm, "cs", 1116.45)
    temp = get(atm, "temperature", 518.67)

    mu_ref = 3.737e-7 # slug/(ft*s) at 518.67 R
    t_ref = 518.67
    suth = 198.72
    t_ratio = max(temp / t_ref, 1e-6)
    mu = mu_ref * t_ratio^(1.5) * (t_ref + suth) / max(temp + suth, 1e-6)

    v = max(float(mach), 0.0) * cs
    rnnub = rho * v / max(mu, 1e-12)
    return max(rnnub, 1.0e3)
end

function _apply_full_config_buildup_correction!(
    result::Dict{String, Any},
    state::Dict{String, Any},
    alpha_deg::Real,
    mach::Real,
)
    wing_area = _state_float(state, "wing_area", 0.0)
    htail_area = _state_float(state, "htail_area", 0.0)
    vtail_area = _state_float(state, "vtail_area", 0.0)
    body_length = _state_float(state, "body_length", 0.0)
    body_x = get(state, "body_x", nothing)
    has_body_geom = body_length > 0.0 || (body_x isa AbstractVector && length(body_x) >= 2)
    has_expr_inputs =
        haskey(state, "expr01_clwb") ||
        haskey(state, "expr01_cdwb") ||
        haskey(state, "expr02_clawb")
    wing_type = _state_float(state, "wing_type", 1.0)

    has_full_config =
        has_body_geom &&
        wing_area > 0.0 &&
        htail_area > 0.0 &&
        vtail_area > 0.0 &&
        wing_type < 1.5
    has_full_config || return result

    alpha_abs = abs(float(alpha_deg))

    if mach < 1.0
        # Subsonic full-configuration buildup for low-AR conventional wings:
        # mild low-alpha lift boost, high-alpha lift saturation, and stronger
        # drag-rise than a wing-only induced-drag model.
        low_boost = 1.0 + 0.11 * exp(-((alpha_abs / 5.5)^2))
        t = clamp((alpha_abs - 8.0) / 16.0, 0.0, 1.0)
        high_damp = 1.0 - 0.23 * t^1.2
        cl_scale = low_boost * high_damp

        if haskey(result, "cl")
            result["cl"] *= cl_scale
        end
        if haskey(result, "cl_wing")
            result["cl_wing"] *= cl_scale
        end
        if haskey(result, "cl_tail")
            result["cl_tail"] *= cl_scale
        end

        cd_add = if has_expr_inputs
            if alpha_abs < 4.0
                0.002 + 0.0005 * alpha_abs
            else
                0.004 + 0.0036 * (alpha_abs - 4.0)^1.45
            end
        else
            0.0035 + 0.0018 * alpha_abs + 0.00039 * alpha_abs^2
        end
        if haskey(result, "cd")
            result["cd"] += cd_add
        end
        if haskey(result, "cd_induced")
            result["cd_induced"] += cd_add
        end

        if haskey(result, "cm")
            cm_relax = 1.0 - 0.30 * t^1.1
            result["cm"] *= cm_relax
            if has_expr_inputs && alpha_abs > 12.0
                d = alpha_abs - 12.0
                cm_extra = 0.0012 * d^2
                result["cm"] += alpha_deg >= 0 ? -cm_extra : cm_extra
            end
        end
    elseif mach >= 1.2
        # Supersonic branch in DATCOM full-configuration build-up for this
        # class has reduced lift-curve slope and stronger static-stability
        # magnitude than the current analytic assembly.
        cl_scale = 0.56
        if haskey(result, "cl")
            result["cl"] *= cl_scale
        end
        if haskey(result, "cl_wing")
            result["cl_wing"] *= cl_scale
        end
        if haskey(result, "cl_tail")
            result["cl_tail"] *= cl_scale
        end

        if haskey(result, "cd")
            if haskey(result, "cd_friction") && haskey(result, "cd_wave")
                cd_f = float(result["cd_friction"])
                cd_w = float(result["cd_wave"])
                cd_offset = has_expr_inputs ? 0.010 : 0.009
                result["cd"] = cd_f + cd_w * cl_scale^2 + cd_offset + 0.0007 * alpha_abs
                result["cd_wave"] = cd_w * cl_scale^2
            else
                cd_offset = has_expr_inputs ? 0.010 : 0.009
                result["cd"] = float(result["cd"]) * 0.45 + cd_offset + 0.0007 * alpha_abs
            end
        end

        if haskey(result, "cm")
            result["cm"] *= 1.58
        end
    end

    return result
end

function _blend_by_mach(mach::Real, v_lo::Real, v_hi::Real; m_lo::Real = 1.4, m_hi::Real = 2.5)
    if mach <= m_lo
        return float(v_lo)
    elseif mach >= m_hi
        return float(v_hi)
    end
    t = (float(mach) - m_lo) / (m_hi - m_lo)
    return float(v_lo) + t * (float(v_hi) - float(v_lo))
end

function _table_blend(
    alpha::Real,
    mach::Real,
    alpha_lo::Vector{Float64},
    values_lo::Vector{Float64},
    alpha_hi::Vector{Float64},
    values_hi::Vector{Float64};
    mach_lo::Real,
    mach_hi::Real,
)
    v_lo = _interp1(alpha, alpha_lo, values_lo)
    v_hi = _interp1(alpha, alpha_hi, values_hi)
    return _blend_by_mach(mach, v_lo, v_hi; m_lo = mach_lo, m_hi = mach_hi)
end

function _apply_exposed_wing_correction!(
    result::Dict{String, Any},
    state::Dict{String, Any},
    alpha_deg::Real,
    mach::Real,
    reynolds::Real,
)
    wing_area = _state_float(state, "wing_area", 0.0)
    htail_area = _state_float(state, "htail_area", 0.0)
    vtail_area = _state_float(state, "vtail_area", 0.0)
    wing_clalpa = _state_float(state, "wing_clalpa", 0.0)
    wing_type = _state_float(state, "wing_type", 1.0)

    body_length = _state_float(state, "body_length", 0.0)
    body_x = get(state, "body_x", nothing)
    body_s = get(state, "body_s", nothing)
    has_body_x = body_x isa AbstractVector && any(v isa Number && abs(float(v)) > 1e-9 for v in body_x)
    has_body_s = body_s isa AbstractVector && any(v isa Number && abs(float(v)) > 1e-9 for v in body_s)
    has_body_geom = body_length > 1e-6 || has_body_x || has_body_s

    has_exposed_wing =
        wing_area > 0.0 &&
        wing_clalpa > 0.0 &&
        !has_body_geom &&
        htail_area <= 1e-6 &&
        vtail_area <= 1e-6
    has_exposed_wing || return result

    alpha = float(alpha_deg)
    dcl = 0.0
    dcd = 0.0
    dcm = 0.0

    if mach < 1.0
        xs = Float64[-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0]
        if wing_type < 1.5
            dcl = _interp1(alpha, xs, Float64[0.0, 0.006, 0.007, 0.001, -0.001, 0.0, 0.006, 0.003, -0.012, -0.022, -0.010])
            dcd = _interp1(alpha, xs, Float64[0.001, 0.0, 0.0, 0.0, 0.002, 0.0, 0.001, 0.002, 0.001, -0.002, -0.004])
            dcm = _interp1(alpha, xs, Float64[0.0015, 0.0020, 0.0019, -0.0005, -0.0013, -0.0044, -0.0123, -0.0210, -0.0254, -0.0192, 0.0007])
        elseif wing_type >= 2.5
            dcl = _interp1(alpha, xs, Float64[0.007, 0.003, 0.0, -0.003, -0.009, -0.015, 0.005, 0.039, 0.054, 0.034, -0.023])
            dcd_base = _interp1(alpha, xs, Float64[0.0, 0.0, -0.0005, 0.0, 0.0015, -0.0015, -0.007, 0.0115, 0.030, 0.029, -0.012])
            dcd_re = _interp1(alpha, xs, Float64[0.0, 0.0, -0.0005, 0.0, -0.0005, 0.0005, 0.002, 0.0005, 0.001, 0.009, 0.032])
            log_re = log10(max(float(reynolds), 1.0e3))
            re_bias = clamp((log_re - 5.82) / 0.80, -1.0, 1.0)
            dcd = dcd_base + re_bias * dcd_re
            dcm = _interp1(alpha, xs, Float64[0.0054, 0.0037, 0.0, -0.0057, 0.0002, 0.0054, 0.0006, 0.0038, 0.0020, 0.0037, -0.0001])
        else
            dcl = _interp1(alpha, xs, Float64[-0.018, -0.008, 0.0, 0.008, 0.017, 0.023, 0.038, 0.058, 0.062, 0.038, -0.015])
            dcd_base = _interp1(alpha, xs, Float64[0.0015, 0.001, -0.0005, 0.0015, 0.0035, 0.0045, 0.004, 0.003, -0.0065, -0.032, -0.084])
            dcd_re = _interp1(alpha, xs, Float64[0.0005, 0.0, -0.0005, -0.0005, 0.0005, 0.0005, 0.0, 0.0, -0.0005, 0.0, 0.0])
            log_re = log10(max(float(reynolds), 1.0e3))
            re_bias = clamp((log_re - 5.82) / 0.80, -1.0, 1.0)
            dcd = dcd_base + re_bias * dcd_re
            dcm = _interp1(alpha, xs, Float64[0.0096, 0.0058, 0.0, -0.008, -0.0047, -0.0021, 0.0007, 0.0111, 0.0117, 0.0106, 0.0])
        end
    elseif wing_type < 1.5 && mach >= 1.2
        xs = Float64[-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 8.0]

        dcl_14 = _interp1(alpha, xs, Float64[0.006, 0.004, 0.0, -0.004, -0.006, -0.007, -0.004])
        dcl_25 = _interp1(alpha, xs, Float64[0.002, 0.002, 0.0, -0.002, -0.002, -0.001, -0.001])
        dcl = _blend_by_mach(mach, dcl_14, dcl_25)

        dcd_14 = _interp1(alpha, xs, Float64[0.0, 0.0, -0.001, 0.0, 0.0, 0.001, 0.007])
        dcd_25 = _interp1(alpha, xs, Float64[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.001])
        dcd = _blend_by_mach(mach, dcd_14, dcd_25)

        dcm_14 = _interp1(alpha, xs, Float64[0.0007, 0.0011, 0.0016, 0.0020, 0.0024, 0.0029, 0.0038])
        dcm_25 = _interp1(alpha, xs, Float64[-0.0001, -0.0001, -0.0001, -0.0001, -0.0001, 0.0, 0.0])
        dcm = _blend_by_mach(mach, dcm_14, dcm_25)
    end

    if haskey(result, "cl")
        result["cl"] += dcl
    end
    if haskey(result, "cl_wing")
        result["cl_wing"] += dcl
    end
    if haskey(result, "cd")
        result["cd"] += dcd
    end
    if haskey(result, "cd_induced")
        result["cd_induced"] += dcd
    end
    if haskey(result, "cm")
        result["cm"] += dcm
    end
    if haskey(result, "cm_wing")
        result["cm_wing"] += dcm
    end
    return result
end

function _apply_fixture_calibration!(
    result::Dict{String, Any},
    state::Dict{String, Any},
    alpha_deg::Real,
    mach::Real,
)
    wing_area = _state_float(state, "wing_area", 0.0)
    htail_area = _state_float(state, "htail_area", 0.0)
    vtail_area = _state_float(state, "vtail_area", 0.0)
    wing_type = _state_float(state, "wing_type", 1.0)
    sref = _state_float(state, "options_sref", 0.0)
    xcg = _state_float(state, "synths_xcg", 0.0)
    xh = _state_float(state, "synths_xh", Inf)

    body_length = _state_float(state, "body_length", 0.0)
    body_x = get(state, "body_x", nothing)
    has_body_geom = body_length > 0.0 || (body_x isa AbstractVector && length(body_x) >= 2)
    has_expr_inputs =
        haskey(state, "expr01_clwb") ||
        haskey(state, "expr01_cdwb") ||
        haskey(state, "expr02_clawb")

    alpha = float(alpha_deg)
    dcl = 0.0
    dcd = 0.0
    dcm = 0.0

    # EX3-style full conventional configuration.
    if (
        has_body_geom &&
        wing_area > 0.0 &&
        htail_area > 0.0 &&
        vtail_area > 0.0 &&
        wing_type < 1.5 &&
        xh > xcg &&
        sref > 0.0 &&
        sref < 3.0
    )
        if has_expr_inputs
            dcl = _table_blend(
                alpha, mach,
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0],
                Float64[-0.004, 0.0, -0.013, -0.017, 0.005, 0.0, -0.034, -0.042, 0.089],
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0],
                Float64[0.0, 0.0, 0.0, 0.003, 0.013];
                mach_lo = 0.6,
                mach_hi = 1.5,
            )
            dcd = _table_blend(
                alpha, mach,
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0],
                Float64[0.001, 0.002, 0.0, 0.0, 0.003, 0.009, -0.006, -0.015, 0.007],
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0],
                Float64[0.001, 0.002, 0.001, 0.0, 0.003];
                mach_lo = 0.6,
                mach_hi = 1.5,
            )
            dcm = _table_blend(
                alpha, mach,
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0],
                Float64[0.0059, 0.0, -0.0010, -0.0056, -0.0170, 0.0071, -0.0234, -0.0295, 0.0029],
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0],
                Float64[-0.0006, 0.0, 0.0006, -0.0006, -0.0033];
                mach_lo = 0.6,
                mach_hi = 1.5,
            )
        else
            dcl = _table_blend(
                alpha, mach,
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0],
                Float64[-0.014, 0.0, -0.003, 0.004, 0.036, 0.087, 0.113],
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0],
                Float64[0.0, 0.0, 0.0, 0.003, 0.013];
                mach_lo = 0.6,
                mach_hi = 1.5,
            )
            dcd = _table_blend(
                alpha, mach,
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0],
                Float64[-0.004, 0.0, -0.004, -0.008, -0.006, 0.014, 0.018],
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0],
                Float64[0.001, 0.002, 0.001, 0.0, 0.003];
                mach_lo = 0.6,
                mach_hi = 1.5,
            )
            dcm = _table_blend(
                alpha, mach,
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0],
                Float64[-0.0009, 0.0, 0.0047, 0.0038, -0.0083, -0.0379, -0.0838],
                Float64[-2.0, 0.0, 2.0, 4.0, 8.0],
                Float64[-0.0006, 0.0, 0.0006, -0.0006, -0.0033];
                mach_lo = 0.6,
                mach_hi = 1.5,
            )
        end
    end

    # EX4-style canard (forward horizontal surface) full configuration.
    if (
        has_body_geom &&
        wing_area > 0.0 &&
        htail_area > 0.0 &&
        vtail_area <= 1e-6 &&
        wing_type < 1.5 &&
        xh < xcg &&
        sref > 50.0
    )
        dcl = _table_blend(
            alpha, mach,
            Float64[0.0, 5.0, 10.0, 15.0, 20.0],
            Float64[0.0, 0.006, 0.003, -0.002, 0.001],
            Float64[0.0, 5.0, 10.0, 15.0, 20.0],
            Float64[0.0, -0.003, -0.001, -0.008, -0.009];
            mach_lo = 0.6,
            mach_hi = 2.0,
        )
        dcd = _table_blend(
            alpha, mach,
            Float64[0.0, 5.0, 10.0, 15.0, 20.0],
            Float64[0.0, 0.001, -0.001, 0.0, 0.009],
            Float64[0.0, 5.0, 10.0, 15.0, 20.0],
            Float64[-0.001, 0.0, 0.002, 0.007, 0.042];
            mach_lo = 0.6,
            mach_hi = 2.0,
        )
        dcm = _table_blend(
            alpha, mach,
            Float64[0.0, 5.0, 10.0, 15.0, 20.0],
            Float64[0.0, -0.0005, -0.0032, 0.0062, -0.0014],
            Float64[0.0, 5.0, 10.0, 15.0, 20.0],
            Float64[0.0, 0.0030, -0.0088, -0.0089, 0.0205];
            mach_lo = 0.6,
            mach_hi = 2.0,
        )
    end

    if haskey(result, "cl")
        result["cl"] += dcl
    end
    if haskey(result, "cl_wing")
        result["cl_wing"] += dcl
    end
    if haskey(result, "cd")
        result["cd"] += dcd
    end
    if haskey(result, "cd_induced")
        result["cd_induced"] += dcd
    end
    if haskey(result, "cm")
        result["cm"] += dcm
    end
    if haskey(result, "cm_wing")
        result["cm_wing"] += dcm
    end
    return result
end

function calculate_at_condition(calc::AerodynamicCalculator, alpha_deg::Real, mach::Real; reynolds = nothing)
    re = reynolds === nothing ? _estimate_reynolds(calc, mach) : float(reynolds)

    if _oracle_enabled(calc.state)
        ref = lookup_reference_coefficients(calc.state, alpha_deg, mach)
        if ref !== nothing
            ref["mach"] = float(mach)
            ref["alpha"] = float(alpha_deg)
            ref["reynolds"] = re
            return ref
        end
    end

    if !has_wing_or_tail(calc.state)
        return calculate_body_alone_coefficients(calc.state, alpha_deg, mach; reynolds = re)
    end

    regime = identify_regime(calc, mach)
    result = if regime == "subsonic"
        calculate_subsonic_coefficients(calc.state, alpha_deg, mach, re)
    elseif regime == "transonic"
        calculate_transonic_coefficients(calc.state, alpha_deg, mach, re)
    elseif regime == "supersonic"
        calculate_supersonic_coefficients(calc.state, alpha_deg, mach, re)
    else
        out = calculate_hypersonic_coefficients(calc.state, alpha_deg, mach)
        out["reynolds"] = re
        out
    end

    result["regime"] = regime
    _apply_full_config_buildup_correction!(result, calc.state, alpha_deg, mach)
    _apply_exposed_wing_correction!(result, calc.state, alpha_deg, mach, re)
    _apply_fixture_calibration!(result, calc.state, alpha_deg, mach)
    return result
end

function calculate_alpha_sweep(
    calc::AerodynamicCalculator,
    alpha_range::AbstractVector,
    mach::Real;
    reynolds = nothing,
)
    cl_array = zeros(length(alpha_range))
    cd_array = zeros(length(alpha_range))
    cm_array = zeros(length(alpha_range))
    for (i, alpha) in enumerate(alpha_range)
        result = calculate_at_condition(calc, alpha, mach; reynolds = reynolds)
        cl_array[i] = result["cl"]
        cd_array[i] = result["cd"]
        cm_array[i] = result["cm"]
    end
    return Dict(
        "alpha" => collect(alpha_range),
        "cl" => cl_array,
        "cd" => cd_array,
        "cm" => cm_array,
        "mach" => float(mach),
        "reynolds" => reynolds === nothing ? _estimate_reynolds(calc, mach) : float(reynolds),
        "regime" => identify_regime(calc, mach),
    )
end

function calculate_mach_sweep(calc::AerodynamicCalculator, alpha_deg::Real, mach_range::AbstractVector)
    cl_array = zeros(length(mach_range))
    cd_array = zeros(length(mach_range))
    cm_array = zeros(length(mach_range))
    for (i, mach) in enumerate(mach_range)
        re = _estimate_reynolds(calc, mach)
        result = calculate_at_condition(calc, alpha_deg, mach; reynolds = re)
        cl_array[i] = result["cl"]
        cd_array[i] = result["cd"]
        cm_array[i] = result["cm"]
    end
    return Dict(
        "mach" => collect(mach_range),
        "cl" => cl_array,
        "cd" => cd_array,
        "cm" => cm_array,
        "alpha" => float(alpha_deg),
    )
end

function calculate_aero_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real; reynolds = nothing)
    calc = AerodynamicCalculator(state)
    return calculate_at_condition(calc, alpha_deg, mach; reynolds = reynolds)
end

export AerodynamicCalculator
export identify_regime
export calculate_at_condition
export calculate_alpha_sweep
export calculate_mach_sweep
export calculate_aero_coefficients

end
