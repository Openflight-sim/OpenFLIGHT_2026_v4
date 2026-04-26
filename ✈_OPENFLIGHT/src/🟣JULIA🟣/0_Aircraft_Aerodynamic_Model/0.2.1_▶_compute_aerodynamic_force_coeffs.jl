const DYNAMIC_STALL_ALPHA_LAG_STATE_INDEX = 14
const DYNAMIC_STALL_SIGMA_STATE_INDEX = 15

function _clamp01(value::Float64)
    return clamp(value, 0.0, 1.0)
end

function _smoothstep01(value::Float64)
    x = _clamp01(value)
    return x * x * (3.0 - 2.0 * x)
end

function _configuration_from_control(control_demand_vector_attained, aircraft_data)
    if control_demand_vector_attained !== nothing && hasproperty(control_demand_vector_attained, :configuration)
        return string(getproperty(control_demand_vector_attained, :configuration))
    end
    if aircraft_data === nothing
        return "clean"
    end
    return string(get(aircraft_data, :default_configuration, "clean"))
end

function _mean_throttle_from_control(control_demand_vector_attained)
    if control_demand_vector_attained === nothing
        return 0.0
    end
    if hasproperty(control_demand_vector_attained, :throttle_attained_vector)
        throttle_vector = getproperty(control_demand_vector_attained, :throttle_attained_vector)
        if throttle_vector isa AbstractVector && !isempty(throttle_vector)
            throttle_numeric = Float64.(throttle_vector)
            return sum(throttle_numeric) / length(throttle_numeric)
        end
    end
    if hasproperty(control_demand_vector_attained, :thrust_attained)
        return Float64(getproperty(control_demand_vector_attained, :thrust_attained))
    end
    return 0.0
end

function _build_aero_lookup_parameters(
    alpha_deg::Float64,
    beta_deg::Float64,
    mach::Float64,
    control_demand_vector_attained,
    initial_flight_conditions
)
    configuration = _configuration_from_control(control_demand_vector_attained, nothing)
    throttle = _mean_throttle_from_control(control_demand_vector_attained)

    altitude_m = initial_flight_conditions === nothing ? 0.0 : Float64(initial_flight_conditions.altitude)
    p = initial_flight_conditions === nothing ? 0.0 : Float64(initial_flight_conditions.p_roll_rate)
    q = initial_flight_conditions === nothing ? 0.0 : Float64(initial_flight_conditions.q_pitch_rate)
    r = initial_flight_conditions === nothing ? 0.0 : Float64(initial_flight_conditions.r_yaw_rate)
    v_mag = initial_flight_conditions === nothing ? 0.0 : Float64(initial_flight_conditions.v_body_magnitude)
    reference_span_hint = initial_flight_conditions === nothing ? 1.0 : Float64(initial_flight_conditions.reference_span_hint)
    wing_mean_chord_hint = initial_flight_conditions === nothing ? 1.0 : Float64(initial_flight_conditions.wing_mean_chord_hint)

    return (
        mach=mach,
        Mach=mach,
        alpha=alpha_deg,
        alpha_deg=alpha_deg,
        beta=beta_deg,
        beta_deg=beta_deg,
        configuration=configuration,
        config=configuration,
        throttle=throttle,
        altitude_m=altitude_m,
        p=p,
        q=q,
        r=r,
        p_hat=p * reference_span_hint / (2.0 * v_mag + 1e-3),
        q_hat=q * wing_mean_chord_hint / (2.0 * v_mag + 1e-3),
        r_hat=r * reference_span_hint / (2.0 * v_mag + 1e-3),
    )
end

const _AERO_LOOKUP_WARN_COUNTS = Dict{String,Int}()

function _fetch_coefficient_with_default(coeff_name::String, default_value::Float64; kwargs...)
    if !has_aero_coefficient(aircraft_aero_and_propulsive_database, coeff_name)
        return default_value
    end
    try
        value = fetch_value_from_aero_database(aircraft_aero_and_propulsive_database, coeff_name; kwargs...)
        return value isa Number ? Float64(value) : default_value
    catch e
        # Log first few failures per coefficient so silent fallback to default is visible
        count = get(_AERO_LOOKUP_WARN_COUNTS, coeff_name, 0)
        if count < 3
            _AERO_LOOKUP_WARN_COUNTS[coeff_name] = count + 1
            @warn "Aero lookup failed for '$coeff_name', using default $default_value" exception=(e, catch_backtrace())
        end
        return default_value
    end
end

function compute_initial_dynamic_stall_sigma(alpha_deg::Float64, aircraft_data)
    abs_alpha_deg = abs(alpha_deg)
    if abs_alpha_deg >= aircraft_data.dynamic_stall_alpha_on_deg
        return 1.0
    elseif abs_alpha_deg <= aircraft_data.dynamic_stall_alpha_off_deg
        return 0.0
    end

    denominator = max(
        aircraft_data.dynamic_stall_alpha_on_deg - aircraft_data.dynamic_stall_alpha_off_deg,
        1e-6
    )
    return _clamp01((abs_alpha_deg - aircraft_data.dynamic_stall_alpha_off_deg) / denominator)
end

function _read_dynamic_stall_states(aircraft_state, alpha_deg::Float64, aircraft_data)
    if length(aircraft_state) >= DYNAMIC_STALL_SIGMA_STATE_INDEX
        alpha_lag_state_deg = Float64(aircraft_state[DYNAMIC_STALL_ALPHA_LAG_STATE_INDEX])
        stall_sigma_state = _clamp01(Float64(aircraft_state[DYNAMIC_STALL_SIGMA_STATE_INDEX]))
        return alpha_lag_state_deg, stall_sigma_state
    end

    return alpha_deg, compute_initial_dynamic_stall_sigma(alpha_deg, aircraft_data)
end

function _compute_dynamic_stall_sigma_target(alpha_lag_deg::Float64, stall_sigma_state::Float64, aircraft_data)
    abs_alpha_lag_deg = abs(alpha_lag_deg)
    if abs_alpha_lag_deg >= aircraft_data.dynamic_stall_alpha_on_deg
        return 1.0
    elseif abs_alpha_lag_deg <= aircraft_data.dynamic_stall_alpha_off_deg
        return 0.0
    end
    return _clamp01(stall_sigma_state)
end

function compute_dynamic_stall_state_derivatives(
    alpha_deg::Float64,
    q_pitch_rate_rad_s::Float64,
    true_airspeed_m_s::Float64,
    alpha_lag_state_deg::Float64,
    stall_sigma_state::Float64,
    aircraft_data
)
    q_hat = q_pitch_rate_rad_s * aircraft_data.wing_mean_aerodynamic_chord / (2.0 * true_airspeed_m_s + 1e-3)
    alpha_command_deg = alpha_deg + aircraft_data.dynamic_stall_qhat_to_alpha_deg * q_hat

    alpha_lag_tau = max(aircraft_data.dynamic_stall_tau_alpha_s, 1e-4)
    d_alpha_lag_deg_per_s = (alpha_command_deg - alpha_lag_state_deg) / alpha_lag_tau

    sigma_target = _compute_dynamic_stall_sigma_target(alpha_lag_state_deg, stall_sigma_state, aircraft_data)
    sigma_tau = sigma_target >= stall_sigma_state ?
                max(aircraft_data.dynamic_stall_tau_sigma_rise_s, 1e-4) :
                max(aircraft_data.dynamic_stall_tau_sigma_fall_s, 1e-4)
    d_stall_sigma_per_s = (sigma_target - stall_sigma_state) / sigma_tau

    return d_alpha_lag_deg_per_s, d_stall_sigma_per_s, q_hat, alpha_command_deg
end

function _compute_poststall_lift_coefficient(alpha_effective_deg::Float64, aircraft_data)
    alpha_rad = deg2rad(alpha_effective_deg)
    return aircraft_data.poststall_cl_scale * sin(2.0 * alpha_rad)
end

function _compute_poststall_drag_coefficient(alpha_effective_deg::Float64, aircraft_data)
    alpha_rad = deg2rad(alpha_effective_deg)
    cd_floor = max(0.0, aircraft_data.poststall_cd_min)
    cd_peak = max(cd_floor, aircraft_data.poststall_cd90)
    return cd_floor + (cd_peak - cd_floor) * (sin(alpha_rad)^2)
end

function compute_wing_force_coefficients_with_dynamic_stall(
    alpha_RAD,
    beta_RAD,
    Mach,
    aircraft_data,
    aircraft_state,
    control_demand_vector_attained=nothing,
    initial_flight_conditions=nothing
)
    alpha_deg = rad2deg(alpha_RAD)
    beta_deg = rad2deg(beta_RAD)

    alpha_lag_state_deg, stall_sigma_state = _read_dynamic_stall_states(aircraft_state, alpha_deg, aircraft_data)
    stall_blend_weight = _smoothstep01(stall_sigma_state)
    alpha_effective_deg = alpha_lag_state_deg

    lookup_context = (
        reference_span_hint=Float64(get(aircraft_data, :reference_span, 1.0)),
        wing_mean_chord_hint=Float64(get(aircraft_data, :wing_mean_aerodynamic_chord, 1.0))
    )

    lookup_inputs = _build_aero_lookup_parameters(
        alpha_effective_deg,
        beta_deg,
        Float64(Mach),
        control_demand_vector_attained,
        initial_flight_conditions === nothing ? nothing : merge(initial_flight_conditions, lookup_context)
    )

    # ───── Schema v3.0: assemble wing_body + tail with interference ─────
    # When the v3 split tables are present, CL, CS(=CY), CD come directly from
    # the component assembler (already includes η, downwash, sidewash, and
    # r×F transfer). Dynamic-stall blending further below still applies.
    use_v3 = get(aircraft_data, :use_component_assembly, false)
    v3_assembled = nothing
    if use_v3
        cref_v3 = aircraft_data.wing_mean_aerodynamic_chord
        bref_v3 = aircraft_data.reference_span
        tail_list_v3 = get(aircraft_data, :tail_surfaces, NamedTuple[])
        cfg_v3 = control_demand_vector_attained === nothing ? "clean" :
                 string(get(control_demand_vector_attained, :configuration, "clean"))
        cg_v3 = [Float64(aircraft_data.x_CoG), Float64(aircraft_data.y_CoG), Float64(aircraft_data.z_CoG)]
        assembled = assemble_total_force_and_moment_coefficients(
            alpha_effective_deg, beta_deg, Float64(Mach), cfg_v3,
            aircraft_aero_and_propulsive_database,
            tail_list_v3, cref_v3, bref_v3, cg_v3
        )
        v3_assembled = assembled
        CL_pre = assembled.CL
        CS_pre = assembled.CY
        CD_pre = assembled.CD
    else
        CL_pre = _fetch_coefficient_with_default("CL", 0.0; lookup_inputs...)
        CS_pre = _fetch_coefficient_with_default("CS", 0.0; lookup_inputs...)
        CD0_pre = _fetch_coefficient_with_default("CD0", max(0.0, get(aircraft_data, :CD0, 0.02)); lookup_inputs...)

        induced_drag_factor = max(pi * aircraft_data.AR * aircraft_data.Oswald_factor, 1e-6)
        CDi_lift = CL_pre^2 / induced_drag_factor
        sideslip_drag_factor = _fetch_coefficient_with_default("Sideslip_drag_K_factor", 2.0; lookup_inputs...)
        CDi_sideslip = abs(CS_pre^2) * sideslip_drag_factor
        CD_pre = CD0_pre + CDi_lift + CDi_sideslip
    end

    CL_post = _compute_poststall_lift_coefficient(alpha_effective_deg, aircraft_data)
    CD_post = _compute_poststall_drag_coefficient(alpha_effective_deg, aircraft_data)

    CL = (1.0 - stall_blend_weight) * CL_pre + stall_blend_weight * CL_post
    CD = (1.0 - stall_blend_weight) * CD_pre + stall_blend_weight * CD_post

    sideforce_scale = clamp(aircraft_data.poststall_sideforce_scale, 0.0, 2.0)
    CS = ((1.0 - stall_blend_weight) + stall_blend_weight * sideforce_scale) * CS_pre

    if initial_flight_conditions === nothing
        d_alpha_lag_deg_per_s = 0.0
        d_stall_sigma_per_s = 0.0
        q_hat = 0.0
        alpha_command_deg = alpha_deg
    else
        d_alpha_lag_deg_per_s, d_stall_sigma_per_s, q_hat, alpha_command_deg =
            compute_dynamic_stall_state_derivatives(
                alpha_deg,
                initial_flight_conditions.q_pitch_rate,
                initial_flight_conditions.v_body_magnitude,
                alpha_lag_state_deg,
                stall_sigma_state,
                aircraft_data
            )
    end

    return (
        CL=CL,
        CS=CS,
        CD=CD,
        CL_pre=CL_pre,
        CS_pre=CS_pre,
        CD_pre=CD_pre,
        CL_post=CL_post,
        CD_post=CD_post,
        stall_blend_weight=stall_blend_weight,
        dynamic_stall_alpha_lag_deg=alpha_lag_state_deg,
        dynamic_stall_sigma=stall_sigma_state,
        dynamic_stall_alpha_command_deg=alpha_command_deg,
        dynamic_stall_q_hat=q_hat,
        dynamic_stall_alpha_lag_derivative_deg_per_s=d_alpha_lag_deg_per_s,
        dynamic_stall_sigma_derivative_per_s=d_stall_sigma_per_s,
        v3_assembled=v3_assembled
    )
end

function 🟩_compute_lift_coefficient(alpha_RAD, beta_RAD, Mach, aircraft_flight_physics_and_propulsive_data, aircraft_state, control_demand_vector_attained)
    return compute_wing_force_coefficients_with_dynamic_stall(
        alpha_RAD,
        beta_RAD,
        Mach,
        aircraft_flight_physics_and_propulsive_data,
        aircraft_state,
        control_demand_vector_attained
    ).CL
end

function 🟩_compute_sideforce_coefficient(alpha_RAD, beta_RAD, Mach, aircraft_flight_physics_and_propulsive_data, aircraft_state, control_demand_vector_attained)
    return compute_wing_force_coefficients_with_dynamic_stall(
        alpha_RAD,
        beta_RAD,
        Mach,
        aircraft_flight_physics_and_propulsive_data,
        aircraft_state,
        control_demand_vector_attained
    ).CS
end

function 🟩_compute_drag_coefficient(alpha_RAD, beta_RAD, Mach, aircraft_flight_physics_and_propulsive_data, CL, CS, aircraft_state, control_demand_vector_attained)
    return compute_wing_force_coefficients_with_dynamic_stall(
        alpha_RAD,
        beta_RAD,
        Mach,
        aircraft_flight_physics_and_propulsive_data,
        aircraft_state,
        control_demand_vector_attained
    ).CD
end
