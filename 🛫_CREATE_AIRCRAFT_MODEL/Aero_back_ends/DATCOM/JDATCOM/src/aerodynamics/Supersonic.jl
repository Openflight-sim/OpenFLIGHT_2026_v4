module Supersonic

using ...Utils: fig60b, fig68
using ..Drag: calculate_skin_friction_drag
using ..Moment: calculate_total_pitching_moment
using ..Lift: calculate_horizontal_tail_lift_supersonic

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

function calculate_supersonic_lift_slope(mach::Real, aspect_ratio::Real; sweep_deg::Real = 0.0, wing_type::Real = 1.0)
    if mach <= 1.0
        return 2.0 * pi
    end

    beta = sqrt(max(mach^2 - 1.0, 1e-10))
    cla_2d = 4.0 / beta
    ar_correction = aspect_ratio > 0 ? aspect_ratio / (aspect_ratio + 2.0 / beta) : 1.0
    cla_3d = cla_2d * ar_correction

    if abs(sweep_deg) > 1.0
        sweep_rad = deg2rad(abs(sweep_deg))
        mach_normal = mach * cos(sweep_rad)
        subnormal_cla = cla_3d * cos(sweep_rad)^0.7
        if wing_type >= 2.0
            # Avoid the M_n -> 1 singularity; blend through near-critical normal Mach.
            if mach_normal >= 1.05
                beta_normal = sqrt(max(mach_normal^2 - 1.0, 1e-10))
                cla_3d = 4.0 / beta_normal * ar_correction * cos(sweep_rad)
            elseif mach_normal <= 0.95
                cla_3d = subnormal_cla
            else
                beta_ref = sqrt(max(1.05^2 - 1.0, 1e-10))
                sup_ref = 4.0 / beta_ref * ar_correction * cos(sweep_rad)
                t = (mach_normal - 0.95) / 0.10
                cla_3d = subnormal_cla + t * (sup_ref - subnormal_cla)
            end

            # Delta/cranked wing low-supersonic lift enhancement.
            low_supersonic = exp(-((mach - 1.35) / 0.55)^2)
            sweep_boost = 1.0 + 1.5 * low_supersonic * sin(sweep_rad)^1.2
            cla_3d *= sweep_boost
        else
            # Avoid singular growth at M_n ~= 1 for conventional swept wings.
            if mach_normal >= 1.05
                beta_normal = sqrt(max(mach_normal^2 - 1.0, 1e-10))
                cla_3d = 4.0 / beta_normal * ar_correction * cos(sweep_rad)^1.7
            elseif mach_normal <= 0.95
                cla_3d = subnormal_cla
            else
                beta_ref = sqrt(max(1.05^2 - 1.0, 1e-10))
                sup_ref = 4.0 / beta_ref * ar_correction * cos(sweep_rad)^1.7
                t = (mach_normal - 0.95) / 0.10
                cla_3d = subnormal_cla + t * (sup_ref - subnormal_cla)
            end
            low_supersonic = exp(-((mach - 1.35) / 0.55)^2)
            cla_3d *= 1.0 + 0.20 * low_supersonic
            mach_att = if mach <= 1.6
                1.0
            elseif mach <= 2.5
                1.0 - 0.10 * (mach - 1.6) / 0.9
            else
                max(0.78, 0.90 - 0.05 * (mach - 2.5))
            end
            cla_3d *= mach_att
        end
    end

    return cla_3d
end

function calculate_supersonic_wave_drag(
    mach::Real,
    thickness_ratio::Real,
    aspect_ratio::Real,
    lift_coef::Real;
    wing_type::Real = 1.0,
    htail_area::Real = 0.0,
)
    if mach <= 1.0
        return Dict("cd_wave_volume" => 0.0, "cd_wave_lift" => 0.0, "cd_wave_total" => 0.0)
    end

    beta = sqrt(max(mach^2 - 1.0, 1e-10))
    k_volume = if wing_type >= 2.0
        0.70 + 0.25 * max(mach - 1.0, 0.0)
    else
        0.52 + 0.20 * max(mach - 1.0, 0.0)
    end
    cd_wave_volume = k_volume * thickness_ratio^2 / beta
    if wing_type < 2.0 && htail_area <= 1e-6
        # Conventional highly swept wings in DATCOM examples carry a
        # finite baseline wave component at M>1.2.
        base_offset = (0.002 + 0.0025 * max(mach - 1.2, 0.0)) * (max(thickness_ratio, 1e-3) / 0.10)^0.8
        cd_wave_volume += base_offset
    end

    cd_wave_lift = if aspect_ratio > 0
        if wing_type >= 2.0
            k_lift = 11.0
            k_lift * lift_coef^2 / (pi * aspect_ratio * beta)
        else
            k_lift = 2.35
            cd_lift = k_lift * lift_coef^2 * beta / (pi * aspect_ratio)
            if htail_area > 1e-6
                # Canard + wing layouts show weaker high-CL wave-lift growth
                # than a single lifting-surface approximation.
                t = clamp((abs(float(lift_coef)) - 0.5) / 0.45, 0.0, 1.0)
                cd_lift *= (1.0 - 0.16 * t)
            end
            cd_lift
        end
    else
        0.0
    end
    cd_wave_total = cd_wave_volume + cd_wave_lift

    return Dict(
        "cd_wave_volume" => cd_wave_volume,
        "cd_wave_lift" => cd_wave_lift,
        "cd_wave_total" => cd_wave_total,
        "beta" => beta,
    )
end

function calculate_supersonic_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real, reynolds::Real)
    aspect_ratio = _state_float(state, "wing_aspect_ratio", 4.0)
    thickness_ratio = _state_float(state, "wing_tovc", 0.10)
    sweep_deg = _state_float(state, "wing_savsi", 0.0)
    wing_type = _state_float(state, "wing_type", 1.0)

    cla = calculate_supersonic_lift_slope(mach, aspect_ratio; sweep_deg = sweep_deg, wing_type = wing_type)
    alpha_zero = _state_float(state, "wing_alphai", 0.0)
    alpha_zero_eff = wing_type >= 2.0 ? alpha_zero : 0.0
    aliw = _state_float(state, "synths_aliw", 0.0)
    cl_wing = cla * deg2rad(alpha_deg + aliw - alpha_zero_eff)
    tail_lift_result = calculate_horizontal_tail_lift_supersonic(state, alpha_deg, mach)
    cl_tail = tail_lift_result["cl"]
    cl = cl_wing + cl_tail
    htail_area = _state_float(state, "htail_area", 0.0)

    wave_drag = calculate_supersonic_wave_drag(mach, thickness_ratio, aspect_ratio, cl; wing_type = wing_type, htail_area = htail_area)
    cd_friction = calculate_skin_friction_drag(state, mach, reynolds)
    cd = cd_friction + wave_drag["cd_wave_total"]

    moment_result = calculate_total_pitching_moment(state, cl_wing, alpha_deg, mach)
    cm = moment_result["cm_total"]

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cla" => cla,
        "cla_per_deg" => cla * deg2rad(1.0),
        "alpha_zero" => alpha_zero_eff,
        "cl_wing" => cl_wing,
        "cl_tail" => cl_tail,
        "cd_friction" => cd_friction,
        "cd_wave" => wave_drag["cd_wave_total"],
        "cd_wave_volume" => wave_drag["cd_wave_volume"],
        "cd_wave_lift" => wave_drag["cd_wave_lift"],
        "cm_wing" => moment_result["cm_wing"],
        "cm_body" => moment_result["cm_body"],
        "cm_tail" => moment_result["cm_tail"],
        "regime" => "supersonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
        "beta" => wave_drag["beta"],
    )
end

export calculate_supersonic_lift_slope
export calculate_supersonic_wave_drag
export calculate_supersonic_coefficients

end
