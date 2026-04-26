function fetch_aero_curve_value_or_default(coeff_name::String, default_value::Float64; kwargs...)
    return _fetch_coefficient_with_default(coeff_name, default_value; kwargs...)
end

function _coefficient_has_parameter(aero_data, coeff_name::String, parameter_name::String)
    has_aero_coefficient(aero_data, coeff_name) || return false
    resolved_coeff_name = _resolve_coefficient_name(aero_data, coeff_name)
    metadata = aero_data.metadata[resolved_coeff_name]
    canonical_parameter = _canonicalize_parameter_name(parameter_name)
    return haskey(metadata.parameter_lookup, canonical_parameter)
end

function _aerodynamic_force_body_sim_from_coeffs(
    D_force::Float64,
    Y_force::Float64,
    L_force::Float64,
    alpha_rad::Float64,
    beta_rad::Float64,
)
    Fxb_std, Fyb_std, Fzb_std = transform_aerodynamic_forces_from_wind_to_body_frame(
        D_force,
        Y_force,
        L_force,
        alpha_rad,
        beta_rad
    )
    return [Fxb_std, -Fzb_std, -Fyb_std]
end

function _linear_visual_tail_forces(
    initial_flight_conditions,
    control_demand_vector_attained,
    aircraft_data,
)
    current_configuration = _configuration_from_control(control_demand_vector_attained, aircraft_data)
    current_throttle = _mean_throttle_from_control(control_demand_vector_attained)

    alpha_deg = rad2deg(initial_flight_conditions.alpha_rad)
    beta_deg = rad2deg(initial_flight_conditions.beta_rad)

    alpha_tail_local_deg, beta_tail_local_deg = compute_tail_local_flow_angles_deg(
        alpha_deg,
        beta_deg,
        initial_flight_conditions.Mach_number,
        initial_flight_conditions.altitude,
        current_throttle,
        current_configuration,
        aircraft_data
    )

    x_cog = linear_aero_constant(aircraft_data, :x_CoG, 0.0)
    y_cog = linear_aero_constant(aircraft_data, :y_CoG, 0.0)
    z_cog = linear_aero_constant(aircraft_data, :z_CoG, 0.0)
    x_htail = linear_aero_constant(aircraft_data, :x_horizontal_tail_aerodynamic_center, x_cog)
    y_htail = linear_aero_constant(aircraft_data, :y_horizontal_tail_aerodynamic_center, y_cog)
    z_htail = linear_aero_constant(aircraft_data, :z_horizontal_tail_aerodynamic_center, z_cog)
    x_vtail = linear_aero_constant(aircraft_data, :x_vertical_tail_aerodynamic_center, x_cog)
    y_vtail = linear_aero_constant(aircraft_data, :y_vertical_tail_aerodynamic_center, y_cog)
    z_vtail = linear_aero_constant(aircraft_data, :z_vertical_tail_aerodynamic_center, z_cog)

    l_htp = max(abs(x_htail - x_cog), 0.1)
    l_vtp = max(abs(x_vtail - x_cog), 0.1)
    V_safe = initial_flight_conditions.v_body_magnitude + 1.0e-3

    alpha_tail_local_deg += -rad2deg(initial_flight_conditions.q_pitch_rate * l_htp / V_safe)
    beta_tail_local_deg += rad2deg(initial_flight_conditions.r_yaw_rate * l_vtp / V_safe)

    alpha_tail_local_rad = deg2rad(alpha_tail_local_deg)
    beta_tail_local_rad = deg2rad(beta_tail_local_deg)

    tail_dynamic_pressure_ratio = compute_tail_dynamic_pressure_ratio_from_alpha_deg(
        alpha_deg,
        initial_flight_conditions.Mach_number,
        initial_flight_conditions.altitude,
        current_throttle,
        current_configuration
    )
    tail_dynamic_pressure = initial_flight_conditions.dynamic_pressure * tail_dynamic_pressure_ratio

    S_ref = max(linear_aero_constant(aircraft_data, :reference_area, 1.0), 1.0e-6)
    b_ref = max(linear_aero_constant(aircraft_data, :reference_span, 1.0), 1.0e-6)
    c_ref = max(linear_aero_constant(aircraft_data, :wing_mean_aerodynamic_chord, 1.0), 1.0e-6)
    S_h = max(
        linear_aero_constant(
            aircraft_data,
            :horizontal_tail_reference_area,
            linear_aero_constant(aircraft_data, :tail_reference_area, 0.0)
        ),
        0.0
    )
    S_v = max(linear_aero_constant(aircraft_data, :vertical_tail_reference_area, 0.0), 0.0)

    elevator_deg = -control_demand_vector_attained.pitch_demand_attained * aircraft_data.max_elevator_deflection_deg
    rudder_deg = control_demand_vector_attained.yaw_demand_attained * aircraft_data.max_rudder_deflection_deg
    elevator_rad = deg2rad(elevator_deg)
    rudder_rad = deg2rad(rudder_deg)

    two_V_safe = 2.0 * initial_flight_conditions.v_body_magnitude + 1.0e-3
    q_hat = initial_flight_conditions.q_pitch_rate * c_ref / two_V_safe
    r_hat = initial_flight_conditions.r_yaw_rate * b_ref / two_V_safe

    Cm_alpha = linear_aero_constant(aircraft_data, :Cm_alpha, -1.50)
    Cm_q = linear_aero_constant(aircraft_data, :Cm_q, -18.0)
    Cm_delta_e = linear_aero_constant(aircraft_data, :Cm_delta_e, -2.50)
    Cn_beta = linear_aero_constant(aircraft_data, :Cn_beta, 0.12)
    Cn_r = linear_aero_constant(aircraft_data, :Cn_r, -0.20)
    Cn_delta_r = linear_aero_constant(aircraft_data, :Cn_delta_r, 0.10)

    tail_CD0 = linear_aero_constant(aircraft_data, :tail_CD0, 0.015)
    tail_k_induced = linear_aero_constant(aircraft_data, :tail_k_induced, 0.20)
    tail_k_side = linear_aero_constant(aircraft_data, :tail_k_side, 0.10)

    horizontal_tail_force_body_N = [0.0, 0.0, 0.0]
    vertical_tail_force_body_N = [0.0, 0.0, 0.0]

    if tail_dynamic_pressure > 0.0 && S_h > 1.0e-6
        cm_to_cl_htp = (S_ref * c_ref) / max(S_h * l_htp, 1.0e-6)
        CL_tail_visual = -cm_to_cl_htp * (
            Cm_alpha * alpha_tail_local_rad +
            Cm_q * q_hat +
            Cm_delta_e * elevator_rad
        )
        CD_tail_horizontal = tail_CD0 + tail_k_induced * CL_tail_visual^2
        D_tail_h = tail_dynamic_pressure * S_h * CD_tail_horizontal
        L_tail_h = tail_dynamic_pressure * S_h * CL_tail_visual
        horizontal_tail_force_body_N = _aerodynamic_force_body_sim_from_coeffs(
            D_tail_h,
            0.0,
            L_tail_h,
            alpha_tail_local_rad,
            0.0
        )
    end

    if tail_dynamic_pressure > 0.0 && S_v > 1.0e-6
        cn_to_cs_vtp = (S_ref * b_ref) / max(S_v * l_vtp, 1.0e-6)
        CS_tail_visual = cn_to_cs_vtp * (
            Cn_beta * beta_tail_local_rad +
            Cn_r * r_hat +
            Cn_delta_r * rudder_rad
        )
        CD_tail_vertical = tail_CD0 + tail_k_side * CS_tail_visual^2
        D_tail_v = tail_dynamic_pressure * S_v * CD_tail_vertical
        Y_tail_v = tail_dynamic_pressure * S_v * CS_tail_visual
        vertical_tail_force_body_N = _aerodynamic_force_body_sim_from_coeffs(
            D_tail_v,
            Y_tail_v,
            0.0,
            0.0,
            beta_tail_local_rad
        )
    end

    horizontal_tail_application_offset_body = [x_cog - x_htail, -(z_cog - z_htail), -(y_cog - y_htail)]
    vertical_tail_application_offset_body = [x_cog - x_vtail, -(z_cog - z_vtail), -(y_cog - y_vtail)]

    return (
        horizontal_tail_force_body_N = horizontal_tail_force_body_N,
        vertical_tail_force_body_N = vertical_tail_force_body_N,
        horizontal_tail_application_offset_body = horizontal_tail_application_offset_body,
        vertical_tail_application_offset_body = vertical_tail_application_offset_body,
    )
end

"""
    _compute_linear_6dof(state, controls, aircraft_data, flight_conditions,
                        propulsive_force_body_N, propulsive_moment_body_Nm)

Assemble the full 6-DOF state derivatives using the scalar linear aero model
(see 0.3_🧮_linear_aerodynamic_model.jl) plus the already-computed
propulsive contribution.  Returns the same 4-tuple shape as the main
table-mode path so the integrator is agnostic of which model is active.
"""
function _compute_linear_6dof(
    aircraft_state_vector,
    control_demand_vector_attained,
    aircraft_data,
    initial_flight_conditions,
    propulsive_force_vector_body_N,
    propulsive_moment_body_Nm,
)
    linear_result = compute_linear_aerodynamic_forces_and_moments(
        initial_flight_conditions,
        control_demand_vector_attained,
        aircraft_data,
    )

    aerodynamic_force_vector_body_N  = linear_result.aero_force_body_sim_N
    aerodynamic_moment_body_Nm       = linear_result.aero_moment_body_sim_Nm

    # --- Linear accelerations (body → global, add gravity) ---
    total_body_force_N = propulsive_force_vector_body_N .+ aerodynamic_force_vector_body_N
    load_factors_body_axis = total_body_force_N ./ (initial_flight_conditions.aircraft_mass * GRAVITY_ACCEL)

    total_force_global_N_minus_weight = rotate_vector_body_to_global(
        total_body_force_N,
        initial_flight_conditions.global_orientation_quaternion,
    )

    weight_force_global_N = SVector(0.0, -initial_flight_conditions.aircraft_mass * GRAVITY_ACCEL, 0.0)
    force_total_global_N  = total_force_global_N_minus_weight .+ weight_force_global_N
    aircraft_CoG_acceleration_global = force_total_global_N ./ initial_flight_conditions.aircraft_mass

    # --- Angular accelerations via Euler's equation ---
    total_moment_body_Nm = aerodynamic_moment_body_Nm .+ propulsive_moment_body_Nm
    omega_body = initial_flight_conditions.omega_body
    angular_acceleration_body = initial_flight_conditions.I_body_inverse *
        (total_moment_body_Nm - cross(omega_body, initial_flight_conditions.I_body * omega_body))

    # --- Assemble state derivative vector ---
    new_aircraft_state_vector = [
        aircraft_state_vector[4],  # dx/dt = vx
        aircraft_state_vector[5],  # dy/dt = vy
        aircraft_state_vector[6],  # dz/dt = vz
        aircraft_CoG_acceleration_global[1],
        aircraft_CoG_acceleration_global[2],
        aircraft_CoG_acceleration_global[3],
        initial_flight_conditions.q_dot[2],  # dqx
        initial_flight_conditions.q_dot[3],  # dqy
        initial_flight_conditions.q_dot[4],  # dqz
        initial_flight_conditions.q_dot[1],  # dqw
        angular_acceleration_body[1],        # dp/dt (roll)
        angular_acceleration_body[2],        # dr/dt (yaw, sim)
        angular_acceleration_body[3],        # dq/dt (pitch, sim)
    ]

    # Dynamic-stall internal states are not used by the linear model; hold them.
    if length(aircraft_state_vector) >= DYNAMIC_STALL_SIGMA_STATE_INDEX
        push!(new_aircraft_state_vector, 0.0)
        push!(new_aircraft_state_vector, 0.0)
    end

    # --- Telemetry vector (same layout as the table-mode path) ---
    CL = linear_result.CL_total
    CD = linear_result.CD_total
    CS = linear_result.CS_total

    flight_data_for_telemetry = [
        CL,
        CD,
        (abs(CD) > 1e-9 ? CL / CD : 0.0),
        CS,
        load_factors_body_axis[1],
        load_factors_body_axis[2],
        load_factors_body_axis[3],
        0.0, 0.0, 0.0,                    # Cl/Cn/Cm from r×F (not decomposed in linear)
        linear_result.Cl_control,
        linear_result.Cn_control,
        linear_result.Cm_control,
        linear_result.Cl_total,
        linear_result.Cn_total,
        linear_result.Cm_total,
        0.0, 0.0, 0.0,                    # damping-only Cl/Cn/Cm (merged into totals)
        initial_flight_conditions.q_pitch_rate,
        initial_flight_conditions.p_roll_rate,
        initial_flight_conditions.r_yaw_rate,
        initial_flight_conditions.TAS,
        initial_flight_conditions.EAS,
        initial_flight_conditions.Mach_number,
        initial_flight_conditions.dynamic_pressure,
    ]

    # --- Component forces for visualisation ---
    aircraft_position_global = [aircraft_state_vector[1], aircraft_state_vector[2], aircraft_state_vector[3]]

    tail_visual = _linear_visual_tail_forces(
        initial_flight_conditions,
        control_demand_vector_attained,
        aircraft_data
    )
    horizontal_tail_force_body_N = tail_visual.horizontal_tail_force_body_N
    vertical_tail_force_body_N = tail_visual.vertical_tail_force_body_N
    tail_force_body_N = horizontal_tail_force_body_N .+ vertical_tail_force_body_N
    wing_force_body_N = aerodynamic_force_vector_body_N .- tail_force_body_N

    wing_application_offset_body = [
        aircraft_data.x_CoG - aircraft_data.wing_fuselage_aero_center_x,
        -(aircraft_data.z_CoG - aircraft_data.wing_fuselage_aero_center_z),
        -(aircraft_data.y_CoG - aircraft_data.wing_fuselage_aero_center_y),
    ]
    horizontal_tail_application_offset_body = tail_visual.horizontal_tail_application_offset_body
    vertical_tail_application_offset_body = tail_visual.vertical_tail_application_offset_body

    wing_force_global_N = rotate_vector_body_to_global(
        wing_force_body_N,
        initial_flight_conditions.global_orientation_quaternion,
    )
    horizontal_tail_force_global_N = rotate_vector_body_to_global(
        horizontal_tail_force_body_N,
        initial_flight_conditions.global_orientation_quaternion,
    )
    vertical_tail_force_global_N = rotate_vector_body_to_global(
        vertical_tail_force_body_N,
        initial_flight_conditions.global_orientation_quaternion,
    )
    horizontal_tail_local_velocity_body = _tail_surface_velocity_body(
        initial_flight_conditions.v_body,
        initial_flight_conditions.omega_body,
        horizontal_tail_application_offset_body,
    )
    vertical_tail_local_velocity_body = _tail_surface_velocity_body(
        initial_flight_conditions.v_body,
        initial_flight_conditions.omega_body,
        vertical_tail_application_offset_body,
    )
    horizontal_tail_local_velocity_global = rotate_vector_body_to_global(
        horizontal_tail_local_velocity_body,
        initial_flight_conditions.global_orientation_quaternion,
    )
    vertical_tail_local_velocity_global = rotate_vector_body_to_global(
        vertical_tail_local_velocity_body,
        initial_flight_conditions.global_orientation_quaternion,
    )
    tail_force_global_N = rotate_vector_body_to_global(
        tail_force_body_N,
        initial_flight_conditions.global_orientation_quaternion,
    )

    wing_force_origin_global = aircraft_position_global + rotate_vector_body_to_global(
        wing_application_offset_body,
        initial_flight_conditions.global_orientation_quaternion,
    )
    horizontal_tail_lift_origin_global = aircraft_position_global + rotate_vector_body_to_global(
        horizontal_tail_application_offset_body,
        initial_flight_conditions.global_orientation_quaternion,
    )
    vertical_tail_lift_origin_global = aircraft_position_global + rotate_vector_body_to_global(
        vertical_tail_application_offset_body,
        initial_flight_conditions.global_orientation_quaternion,
    )

    component_forces_for_visualization = (
        wing_lift_vector_global_N            = wing_force_global_N,
        horizontal_tail_lift_vector_global_N = horizontal_tail_force_global_N,
        vertical_tail_lift_vector_global_N   = vertical_tail_force_global_N,
        horizontal_tail_force_vector_global_N = horizontal_tail_force_global_N,
        vertical_tail_force_vector_global_N   = vertical_tail_force_global_N,
        horizontal_tail_local_velocity_global = horizontal_tail_local_velocity_global,
        vertical_tail_local_velocity_global   = vertical_tail_local_velocity_global,
        weight_force_vector_global_N         = [weight_force_global_N[1], weight_force_global_N[2], weight_force_global_N[3]],
        wing_lift_origin_global              = wing_force_origin_global,
        horizontal_tail_lift_origin_global   = horizontal_tail_lift_origin_global,
        vertical_tail_lift_origin_global     = vertical_tail_lift_origin_global,
        weight_force_origin_global           = aircraft_position_global,

        wing_force_vector_global_N = wing_force_global_N,
        tail_force_vector_global_N = tail_force_global_N,
        tail_lift_vector_global_N  = horizontal_tail_force_global_N,
        wing_force_origin_global   = wing_force_origin_global,
        tail_force_origin_global   = horizontal_tail_lift_origin_global,

        wing_offset_body  = wing_application_offset_body,
        htail_offset_body = horizontal_tail_application_offset_body,
        vtail_offset_body = vertical_tail_application_offset_body,
    )

    return (
        new_aircraft_state_vector,
        total_force_global_N_minus_weight,
        flight_data_for_telemetry,
        component_forces_for_visualization,
    )
end

function compute_tail_dynamic_pressure_ratio_fallback(alpha_deg::Float64)
    if alpha_deg < 0.0
        return 1.0
    elseif alpha_deg <= 10.0
        # 5% loss at alpha=0 (ratio 0.95), 10% loss at alpha=10 (ratio 0.90)
        return 0.95 - 0.005 * alpha_deg
    elseif alpha_deg <= 20.0
        # Recover linearly from 0.90 at alpha=10 to 1.0 at alpha=20
        return 0.90 + 0.01 * (alpha_deg - 10.0)
    else
        return 1.0
    end
end

function compute_tail_dynamic_pressure_ratio_from_alpha_deg(
    alpha_deg::Float64,
    mach::Float64,
    altitude_m::Float64,
    throttle::Float64,
    configuration::String
)
    fallback_ratio = compute_tail_dynamic_pressure_ratio_fallback(alpha_deg)
    interference_ratio = fetch_aero_curve_value_or_default(
        "interference_eta_h",
        fallback_ratio,
        alpha=alpha_deg,
        mach=mach,
        altitude_m=altitude_m,
        throttle=throttle,
        configuration=configuration
    )
    ratio = fetch_aero_curve_value_or_default(
        "tail_dynamic_pressure_ratio",
        interference_ratio,
        alpha=alpha_deg,
        mach=mach,
        altitude_m=altitude_m,
        throttle=throttle,
        configuration=configuration
    )
    return clamp(ratio, 0.0, 1.0)
end

function compute_tail_local_flow_angles_deg(
    alpha_deg::Float64,
    beta_deg::Float64,
    mach::Float64,
    altitude_m::Float64,
    throttle::Float64,
    configuration::String,
    aircraft_data
)
    horizontal_tail_downwash_deg_default = clamp(
        aircraft_data.horizontal_tail_downwash_slope * alpha_deg,
        -aircraft_data.horizontal_tail_downwash_max_abs_deg,
        aircraft_data.horizontal_tail_downwash_max_abs_deg
    )
    vertical_tail_sidewash_deg_default = clamp(
        aircraft_data.vertical_tail_sidewash_slope * beta_deg,
        -aircraft_data.vertical_tail_sidewash_max_abs_deg,
        aircraft_data.vertical_tail_sidewash_max_abs_deg
    )

    horizontal_tail_downwash_deg = fetch_aero_curve_value_or_default(
        "downwash_deg",
        horizontal_tail_downwash_deg_default,
        alpha=alpha_deg,
        mach=mach,
        altitude_m=altitude_m,
        throttle=throttle,
        configuration=configuration
    )
    vertical_tail_sidewash_deg = fetch_aero_curve_value_or_default(
        "sidewash_deg",
        vertical_tail_sidewash_deg_default,
        beta=beta_deg,
        mach=mach,
        altitude_m=altitude_m,
        throttle=throttle,
        configuration=configuration
    )

    alpha_tail_local_deg = alpha_deg - horizontal_tail_downwash_deg
    beta_tail_local_deg = beta_deg - vertical_tail_sidewash_deg

    return alpha_tail_local_deg, beta_tail_local_deg
end

function _tail_freestream_velocity_body_from_angles(
    alpha_deg::Float64,
    beta_deg::Float64,
    speed_m_s::Float64,
)
    speed = max(Float64(speed_m_s), 0.0)
    if speed <= 1.0e-9
        return [0.0, 0.0, 0.0]
    end

    flow_axis_std = _flow_unit_vector_from_alpha_beta(deg2rad(alpha_deg), deg2rad(beta_deg))
    return speed .* [flow_axis_std[1], -flow_axis_std[3], -flow_axis_std[2]]
end

function _tail_surface_velocity_body(
    local_freestream_velocity_body,
    omega_body,
    surface_offset_body_m,
)
    omega = [Float64(omega_body[1]), Float64(omega_body[2]), Float64(omega_body[3])]
    offset = [Float64(surface_offset_body_m[1]), Float64(surface_offset_body_m[2]), Float64(surface_offset_body_m[3])]

    # Velocity of a point fixed on the aircraft is V_CG + omega x r.  This
    # makes drag on the tail do negative work on the angular motion even when
    # the freestream speed is zero.
    return local_freestream_velocity_body .+ cross(omega, offset)
end

function _tail_flow_from_velocity_body(local_velocity_body, rho::Float64)
    u_std = Float64(local_velocity_body[1])
    v_std = -Float64(local_velocity_body[3])
    w_std = -Float64(local_velocity_body[2])
    speed = sqrt(u_std^2 + v_std^2 + w_std^2)
    alpha_deg = speed > 1.0e-9 ? rad2deg(atan(w_std, u_std)) : 0.0
    beta_deg = speed > 1.0e-9 ? rad2deg(atan(v_std, u_std)) : 0.0
    return alpha_deg, beta_deg, 0.5 * rho * speed^2
end

function _fetch_tail_surface_cd_local(
    surface_name::String,
    local_fallback::Float64,
    surface_area::Float64,
    reference_area::Float64;
    kwargs...
)
    coeff_name = "tail_" * surface_name * "_CD"
    if surface_area <= 1.0e-9 || reference_area <= 1.0e-9 ||
       !has_aero_coefficient(aircraft_aero_and_propulsive_database, coeff_name)
        return local_fallback
    end

    component_fallback = local_fallback * surface_area / reference_area
    component_cd = fetch_aero_curve_value_or_default(coeff_name, component_fallback; kwargs...)
    return component_cd * reference_area / surface_area
end

"""
    compute_6DOF_equations_of_motion(
        aircraft_state_vector,
        control_demand_vector_attained,
        aircraft_data::NamedTuple,
        initial_flight_conditions::NamedTuple # Added type hint for clarity
    )

Compute the 6-DOF equations of motion for the aircraft. This function is typically
called by the Runge-Kutta integrator to update the aircraft state.

# Arguments
- `aircraft_state_vector`          : The current aircraft state (position, orientation, velocity, angular rates).
- `control_demand_vector_attained` : Actual/attained control demands (thrust, control surface deflections, etc.).
- `aircraft_data`                  : A named tuple containing fixed aircraft parameters (mass, inertia, aero data, etc.).
- `initial_flight_conditions`      : A named tuple containing pre-calculated conditions (alpha, beta, Mach, dynamic pressure, etc.).

# Returns
A tuple containing:
1) `new_aircraft_state_vector`: Vector of time derivatives of the 13-dimensional state vector.
2) `total_propulsive_plus_aerodynamic_force_vector_global_N`: Total external force (excluding gravity) in Global Frame [N].
3) `flight_data_for_telemetry`: Vector of various flight parameters for logging/display.
"""
function compute_6DOF_equations_of_motion(
    aircraft_state_vector,
    control_demand_vector_attained,
    aircraft_data, # Keep flexible if not always NamedTuple, though preferred
    initial_flight_conditions) # Keep flexible if not always NamedTuple

    # === 1) PREPARE (Already done in initial_flight_conditions) ===
    # Unpacking state, calculating atmospheric properties, alpha, beta, Mach, q_inf etc.
    # is assumed to be done when creating `initial_flight_conditions`.

    # === 2) COMPUTE FORCES & LINEAR ACCELERATIONS ===
    current_configuration = _configuration_from_control(control_demand_vector_attained, aircraft_data)
    current_throttle = _mean_throttle_from_control(control_demand_vector_attained)

    # ── Aerodynamic model mode dispatch ─────────────────────────────────
    # `aerodynamic_model_mode == "linear"` routes every aero force/moment
    # computation through the scalar-derivative path in
    # 0.3_🧮_linear_aerodynamic_model.jl.  This is the recommended choice for
    # aircraft whose YAML table data has not been fully validated.
    _aero_mode = lowercase(string(get(aircraft_data, :aerodynamic_model_mode, "table")))
    _use_linear_aero = _aero_mode == "linear"

    propulsion_result = compute_propulsion_force_and_moment_body(
        initial_flight_conditions.altitude,
        initial_flight_conditions.Mach_number,
        aircraft_data,
        aircraft_state_vector,
        control_demand_vector_attained
    )
    propulsive_force_vector_body_N = propulsion_result.force_body_N
    propulsive_moment_body_Nm = propulsion_result.moment_body_Nm

    if _use_linear_aero
        return _compute_linear_6dof(
            aircraft_state_vector,
            control_demand_vector_attained,
            aircraft_data,
            initial_flight_conditions,
            propulsive_force_vector_body_N,
            propulsive_moment_body_Nm,
        )
    end

    # Compute wing+fuselage aerodynamic force coefficients using
    # pre-stall/post-stall blend with hysteresis and dynamic-stall lag.
    wing_force_coeffs = compute_wing_force_coefficients_with_dynamic_stall(
        initial_flight_conditions.alpha_rad,
        initial_flight_conditions.beta_rad,
        initial_flight_conditions.Mach_number,
        aircraft_data,
        aircraft_state_vector,
        control_demand_vector_attained,
        initial_flight_conditions
    )
    CL_wing_fuselage = wing_force_coeffs.CL
    CS_wing_fuselage = wing_force_coeffs.CS
    CD_wing_fuselage = wing_force_coeffs.CD
    _has_moment_tables = has_aero_coefficient(aircraft_aero_and_propulsive_database, "Cl") &&
                         has_aero_coefficient(aircraft_aero_and_propulsive_database, "Cm") &&
                         has_aero_coefficient(aircraft_aero_and_propulsive_database, "Cn")
    _tail_cl_has_elevator_axis = has_aero_coefficient(aircraft_aero_and_propulsive_database, "tail_CL") &&
                                 _coefficient_has_parameter(aircraft_aero_and_propulsive_database, "tail_CL", "elevator_deg")
    _tail_cs_has_rudder_axis = has_aero_coefficient(aircraft_aero_and_propulsive_database, "tail_CS") &&
                               _coefficient_has_parameter(aircraft_aero_and_propulsive_database, "tail_CS", "rudder_deg")

    # Tail aerodynamic force coefficients (local-flow model)
    alpha_deg = rad2deg(initial_flight_conditions.alpha_rad)
    beta_deg = rad2deg(initial_flight_conditions.beta_rad)

    # STATIC tail angles: downwash/sidewash only (no rate or control perturbation).
    # These represent the freestream condition matching the static coefficient tables.
    alpha_tail_static_deg, beta_tail_static_deg = compute_tail_local_flow_angles_deg(
        alpha_deg,
        beta_deg,
        initial_flight_conditions.Mach_number,
        initial_flight_conditions.altitude,
        current_throttle,
        current_configuration,
        aircraft_data
    )

    # Dynamic tail angles are rebuilt below from each tail AC's local velocity.
    alpha_tail_local_deg = alpha_tail_static_deg
    beta_tail_local_deg  = beta_tail_static_deg

    # --- Control surface deflections passed to DATCOM tail coefficient tables ---
    # Elevator: stick back (+1) → trailing-edge UP → negative δe in standard convention
    elevator_deflection_deg = -control_demand_vector_attained.pitch_demand_attained * aircraft_data.max_elevator_deflection_deg
    # Rudder: right pedal (+1) → positive δr
    rudder_deflection_deg = control_demand_vector_attained.yaw_demand_attained * aircraft_data.max_rudder_deflection_deg

    tail_dynamic_pressure_ratio = compute_tail_dynamic_pressure_ratio_from_alpha_deg(
        alpha_deg,
        initial_flight_conditions.Mach_number,
        initial_flight_conditions.altitude,
        current_throttle,
        current_configuration
    )
    tail_static_dynamic_pressure = initial_flight_conditions.dynamic_pressure * tail_dynamic_pressure_ratio

    r_horizontal_tail_aero = [
        aircraft_data.x_CoG - aircraft_data.x_horizontal_tail_aerodynamic_center,
        aircraft_data.y_CoG - aircraft_data.y_horizontal_tail_aerodynamic_center,
        aircraft_data.z_CoG - aircraft_data.z_horizontal_tail_aerodynamic_center
    ]
    r_horizontal_tail_wrt_CoG_body_m = [r_horizontal_tail_aero[1], -r_horizontal_tail_aero[3], -r_horizontal_tail_aero[2]]
    r_vertical_tail_aero = [
        aircraft_data.x_CoG - aircraft_data.x_vertical_tail_aerodynamic_center,
        aircraft_data.y_CoG - aircraft_data.y_vertical_tail_aerodynamic_center,
        aircraft_data.z_CoG - aircraft_data.z_vertical_tail_aerodynamic_center
    ]
    r_vertical_tail_wrt_CoG_body_m = [r_vertical_tail_aero[1], -r_vertical_tail_aero[3], -r_vertical_tail_aero[2]]

    rho_local = hasproperty(initial_flight_conditions, :air_density) ?
                Float64(initial_flight_conditions.air_density) :
                2.0 * initial_flight_conditions.dynamic_pressure /
                max(initial_flight_conditions.v_body_magnitude^2, 1.0e-6)
    tail_static_speed = initial_flight_conditions.v_body_magnitude * sqrt(tail_dynamic_pressure_ratio)

    tail_static_velocity_body = _tail_freestream_velocity_body_from_angles(
        alpha_tail_static_deg,
        beta_tail_static_deg,
        tail_static_speed
    )
    horizontal_tail_static_velocity_body = tail_static_velocity_body
    vertical_tail_static_velocity_body = tail_static_velocity_body

    horizontal_tail_local_velocity_body = _tail_surface_velocity_body(
        horizontal_tail_static_velocity_body,
        initial_flight_conditions.omega_body,
        r_horizontal_tail_wrt_CoG_body_m
    )
    vertical_tail_local_velocity_body = _tail_surface_velocity_body(
        vertical_tail_static_velocity_body,
        initial_flight_conditions.omega_body,
        r_vertical_tail_wrt_CoG_body_m
    )

    alpha_tail_local_deg, beta_tail_horizontal_force_deg, horizontal_tail_dynamic_pressure =
        _tail_flow_from_velocity_body(horizontal_tail_local_velocity_body, rho_local)
    alpha_tail_vertical_force_deg, beta_tail_local_deg, vertical_tail_dynamic_pressure =
        _tail_flow_from_velocity_body(vertical_tail_local_velocity_body, rho_local)
    alpha_tail_static_horizontal_force_deg, beta_tail_static_horizontal_force_deg, _ =
        _tail_flow_from_velocity_body(horizontal_tail_static_velocity_body, rho_local)
    alpha_tail_static_vertical_force_deg, beta_tail_static_vertical_force_deg, _ =
        _tail_flow_from_velocity_body(vertical_tail_static_velocity_body, rho_local)

    # --- DYNAMIC tail lookup (with rate perturbations + control deflections) ---
    # Tail force coefficients depend on the effective flow angles AND the
    # control surface deflections. DATCOM tables provide tail_CL(α, δe) and
    # tail_CS(β, δr) so the effect of elevator/rudder is captured directly
    # in the coefficient lookup rather than via an angle-of-attack modification.
    CL_tail = fetch_aero_curve_value_or_default(
        "tail_CL",
        0.0,
        alpha=alpha_tail_local_deg,
        elevator_deg=elevator_deflection_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    CS_tail = fetch_aero_curve_value_or_default(
        "tail_CS",
        0.0,
        beta=beta_tail_local_deg,
        rudder_deg=rudder_deflection_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    tail_CD0_horizontal = fetch_aero_curve_value_or_default(
        "tail_CD0",
        aircraft_data.tail_CD0,
        alpha=alpha_tail_local_deg,
        beta=beta_tail_horizontal_force_deg,
        elevator_deg=elevator_deflection_deg,
        rudder_deg=0.0,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    tail_CD0_vertical = fetch_aero_curve_value_or_default(
        "tail_CD0",
        aircraft_data.tail_CD0,
        alpha=alpha_tail_vertical_force_deg,
        beta=beta_tail_local_deg,
        elevator_deg=0.0,
        rudder_deg=rudder_deflection_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    # --- STATIC tail lookup (downwash only, no rate/control) ---
    # These are subtracted from the total-aircraft static coefficient tables
    # to recover wing+body-only coefficients. Using STATIC angles and zero
    # control deflections here ensures the delta between dynamic and static
    # r×F correctly captures both physical damping and control effectiveness.
    CL_tail_static = fetch_aero_curve_value_or_default(
        "tail_CL",
        0.0,
        alpha=alpha_tail_static_deg,
        elevator_deg=0.0,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    CS_tail_static = fetch_aero_curve_value_or_default(
        "tail_CS",
        0.0,
        beta=beta_tail_static_deg,
        rudder_deg=0.0,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    tail_CD0_horizontal_static = fetch_aero_curve_value_or_default(
        "tail_CD0",
        aircraft_data.tail_CD0,
        alpha=alpha_tail_static_horizontal_force_deg,
        beta=beta_tail_static_horizontal_force_deg,
        elevator_deg=0.0,
        rudder_deg=0.0,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    tail_CD0_vertical_static = fetch_aero_curve_value_or_default(
        "tail_CD0",
        aircraft_data.tail_CD0,
        alpha=alpha_tail_static_vertical_force_deg,
        beta=beta_tail_static_vertical_force_deg,
        elevator_deg=0.0,
        rudder_deg=0.0,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    horizontal_tail_area = max(get(aircraft_data, :horizontal_tail_reference_area, aircraft_data.tail_reference_area), 0.0)
    vertical_tail_area = max(get(aircraft_data, :vertical_tail_reference_area, 0.0), 0.0)
    if horizontal_tail_area + vertical_tail_area <= 1.0e-6
        horizontal_tail_area = aircraft_data.tail_reference_area
        vertical_tail_area = 0.0
    end

    alpha_horizontal_tail_force_rad = deg2rad(alpha_tail_local_deg)
    beta_horizontal_tail_force_rad = deg2rad(beta_tail_horizontal_force_deg)
    alpha_vertical_tail_force_rad = deg2rad(alpha_tail_vertical_force_deg)
    beta_vertical_tail_force_rad = deg2rad(beta_tail_local_deg)

    CL_tail_force = CL_tail
    CS_tail_force = CS_tail
    CD_tail_horizontal_fallback = tail_CD0_horizontal + aircraft_data.tail_k_induced * CL_tail_force^2
    CD_tail_vertical_fallback = tail_CD0_vertical + aircraft_data.tail_k_side * CS_tail_force^2
    CD_tail_horizontal_static_fallback = tail_CD0_horizontal_static + aircraft_data.tail_k_induced * CL_tail_static^2
    CD_tail_vertical_static_fallback = tail_CD0_vertical_static + aircraft_data.tail_k_side * CS_tail_static^2
    CD_tail_horizontal = _fetch_tail_surface_cd_local(
        "HTP",
        CD_tail_horizontal_fallback,
        horizontal_tail_area,
        aircraft_data.reference_area;
        alpha=alpha_tail_local_deg,
        beta=beta_tail_horizontal_force_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    CD_tail_vertical = _fetch_tail_surface_cd_local(
        "VTP",
        CD_tail_vertical_fallback,
        vertical_tail_area,
        aircraft_data.reference_area;
        alpha=alpha_tail_vertical_force_deg,
        beta=beta_tail_local_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    CD_tail_horizontal_static = _fetch_tail_surface_cd_local(
        "HTP",
        CD_tail_horizontal_static_fallback,
        horizontal_tail_area,
        aircraft_data.reference_area;
        alpha=alpha_tail_static_horizontal_force_deg,
        beta=beta_tail_static_horizontal_force_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )
    CD_tail_vertical_static = _fetch_tail_surface_cd_local(
        "VTP",
        CD_tail_vertical_static_fallback,
        vertical_tail_area,
        aircraft_data.reference_area;
        alpha=alpha_tail_static_vertical_force_deg,
        beta=beta_tail_static_vertical_force_deg,
        mach=initial_flight_conditions.Mach_number,
        altitude_m=initial_flight_conditions.altitude,
        throttle=current_throttle,
        configuration=current_configuration
    )


    function aerodynamic_force_body_from_coeffs(D_force, Y_force, L_force, alpha_rad, beta_rad)
        Fxb_std, Fyb_std, Fzb_std = transform_aerodynamic_forces_from_wind_to_body_frame(
            D_force,
            Y_force,
            L_force,
            alpha_rad,
            beta_rad
        )
        # Simulator body-axis convention: Xfwd, Yup, Zleft
        return [Fxb_std, -Fzb_std, -Fyb_std]
    end

    # === SPLIT-BODY FORCE MODEL ===
    # The static_coefficients tables (CL, CD, CS/CY) from full_envelope.jl
    # contain TOTAL AIRCRAFT coefficients (wing+body+tails combined).
    # To apply forces at the correct aerodynamic centres we split them:
    #
    #   Wing+body forces  = (total − tail contribution), applied at wing+body AC
    #   HTP forces         = tail_CL / tail_CD,           applied at HTP AC
    #   VTP forces         = tail_CS,                      applied at VTP AC
    #
    # This ensures r×F moments naturally capture pitch stability (wing lift
    # ahead/behind CG), yaw stability (VTP side force behind CG), and
    # avoids double-counting tail effects.

    # DYNAMIC tail dimensional forces (with rate + control perturbations)
    # These are the actual physical forces at the tail ACs.
    D_tail_h = horizontal_tail_dynamic_pressure * horizontal_tail_area * CD_tail_horizontal
    D_tail_v = vertical_tail_dynamic_pressure * vertical_tail_area * CD_tail_vertical
    Y_tail = vertical_tail_dynamic_pressure * vertical_tail_area * CS_tail_force
    L_tail = horizontal_tail_dynamic_pressure * horizontal_tail_area * CL_tail_force

    # STATIC tail fractions for the force split (using downwash-only angles).
    # The static coefficient tables contain total-aircraft values at freestream
    # alpha/beta. To recover wing+body-only coefficients, we subtract the
    # STATIC (freestream) tail contribution — not the dynamic one.
    _S_area_safe = max(aircraft_data.reference_area, 1e-6)
    tail_CL_fraction = tail_dynamic_pressure_ratio * horizontal_tail_area *
                        CL_tail_static / _S_area_safe
    tail_CS_fraction = tail_dynamic_pressure_ratio * vertical_tail_area *
                        CS_tail_static / _S_area_safe
    tail_CD_fraction = tail_dynamic_pressure_ratio *
                        (horizontal_tail_area * CD_tail_horizontal_static +
                         vertical_tail_area * CD_tail_vertical_static) / _S_area_safe

    # Wing+body coefficients = total − tail contribution
    CL_wb = CL_wing_fuselage - tail_CL_fraction
    CS_wb = CS_wing_fuselage - tail_CS_fraction
    CD_wb = CD_wing_fuselage - tail_CD_fraction

    # Wing+body dimensional forces (applied at wing+body neutral point)
    D_wb = initial_flight_conditions.dynamic_pressure * aircraft_data.reference_area * CD_wb
    Y_wb = initial_flight_conditions.dynamic_pressure * aircraft_data.reference_area * CS_wb
    L_wb = initial_flight_conditions.dynamic_pressure * aircraft_data.reference_area * CL_wb

    # Forces in body frame
    aerodynamic_force_vector_body_wing_fuselage_N = aerodynamic_force_body_from_coeffs(
        D_wb, Y_wb, L_wb,
        initial_flight_conditions.alpha_rad,
        initial_flight_conditions.beta_rad
    )
    aerodynamic_force_vector_body_horizontal_tail_N = aerodynamic_force_body_from_coeffs(
        D_tail_h, 0.0, L_tail,
        alpha_horizontal_tail_force_rad, beta_horizontal_tail_force_rad
    )
    aerodynamic_force_vector_body_vertical_tail_N = aerodynamic_force_body_from_coeffs(
        D_tail_v, Y_tail, 0.0,
        alpha_vertical_tail_force_rad, beta_vertical_tail_force_rad
    )
    aerodynamic_force_vector_body_tail_N = aerodynamic_force_vector_body_horizontal_tail_N +
                                           aerodynamic_force_vector_body_vertical_tail_N
    aerodynamic_tail_lift_vector_body_N = aerodynamic_force_body_from_coeffs(
        0.0, 0.0, L_tail,
        alpha_horizontal_tail_force_rad, beta_horizontal_tail_force_rad
    )
    aerodynamic_vertical_tail_lift_vector_body_N = aerodynamic_force_body_from_coeffs(
        0.0, Y_tail, 0.0,
        alpha_vertical_tail_force_rad, beta_vertical_tail_force_rad
    )

    # Total aerodynamic force = wing+body + tail (no double-counting)
    aerodynamic_force_vector_body_N = aerodynamic_force_vector_body_wing_fuselage_N +
                                      aerodynamic_force_vector_body_tail_N

    # Equivalent total coefficients for telemetry
    CL = CL_wing_fuselage   # total aircraft CL from static_coefficients table
    CS = CS_wing_fuselage
    CD = CD_wing_fuselage

    # Sum propulsive + aerodynamic forces in body axes (simulator convention)
    total_propulsive_plus_aerodynamic_force_vector_body_N = propulsive_force_vector_body_N + aerodynamic_force_vector_body_N

    # Calculate load factors in body axes (simulator convention)
    load_factors_body_axis = total_propulsive_plus_aerodynamic_force_vector_body_N ./ (initial_flight_conditions.aircraft_mass * GRAVITY_ACCEL)

    # Rotate sum back to the global frame (NED or ENU based on gravity vector)
    total_propulsive_plus_aerodynamic_force_vector_global_N = rotate_vector_body_to_global( # Use correct function name if different
        total_propulsive_plus_aerodynamic_force_vector_body_N,
        initial_flight_conditions.global_orientation_quaternion
    )

    # Weight force in global axes (Y-axis assumed vertical, negative is down)
    weight_force_global_N = SVector(0.0, -initial_flight_conditions.aircraft_mass * GRAVITY_ACCEL, 0.0) # Ensure SVector is available or use standard vector

    # Total force in global frame
    force_total_global_N = total_propulsive_plus_aerodynamic_force_vector_global_N + weight_force_global_N

    # Linear acceleration in global axes
    aircraft_CoG_acceleration_global = force_total_global_N / initial_flight_conditions.aircraft_mass


    # === 3) MOMENTS & ANGULAR ACCELERATIONS ===

    # --- Calculate Non-Dimensional Moment Coefficients ---
    # Note: Functions return coefficients in the order [Roll, Yaw, Pitch]

    # Aerodynamic moment from force application points (wing+fuselage and tails), both resolved at CoG.
    # Moment arms computed in aero frame (x_fwd, y_right, z_down) then converted to simulator body
    # frame (x_fwd, y_up, z_left) via [x, -z, -y] to match the force vectors' frame.
    r_wing_aero = [
        aircraft_data.x_CoG - aircraft_data.wing_fuselage_aero_center_x,
        aircraft_data.y_CoG - aircraft_data.wing_fuselage_aero_center_y,
        aircraft_data.z_CoG - aircraft_data.wing_fuselage_aero_center_z
    ]
    r_wing_fuselage_wrt_CoG_body_m = [r_wing_aero[1], -r_wing_aero[3], -r_wing_aero[2]]

    r_horizontal_tail_aero = [
        aircraft_data.x_CoG - aircraft_data.x_horizontal_tail_aerodynamic_center,
        aircraft_data.y_CoG - aircraft_data.y_horizontal_tail_aerodynamic_center,
        aircraft_data.z_CoG - aircraft_data.z_horizontal_tail_aerodynamic_center
    ]
    r_horizontal_tail_wrt_CoG_body_m = [r_horizontal_tail_aero[1], -r_horizontal_tail_aero[3], -r_horizontal_tail_aero[2]]
    r_vertical_tail_aero = [
        aircraft_data.x_CoG - aircraft_data.x_vertical_tail_aerodynamic_center,
        aircraft_data.y_CoG - aircraft_data.y_vertical_tail_aerodynamic_center,
        aircraft_data.z_CoG - aircraft_data.z_vertical_tail_aerodynamic_center
    ]
    r_vertical_tail_wrt_CoG_body_m = [r_vertical_tail_aero[1], -r_vertical_tail_aero[3], -r_vertical_tail_aero[2]]

    # DYNAMIC r×F moment — standard right-handed cross product, no flips.
    # The sim uses the same sign convention as textbook aero, so slot
    # mapping is [L_std, N_std, M_std] throughout.
    _rF_raw =
        cross(r_wing_fuselage_wrt_CoG_body_m, aerodynamic_force_vector_body_wing_fuselage_N) +
        cross(r_horizontal_tail_wrt_CoG_body_m, aerodynamic_force_vector_body_horizontal_tail_N) +
        cross(r_vertical_tail_wrt_CoG_body_m, aerodynamic_force_vector_body_vertical_tail_N)
    aerodynamic_moment_from_forces_body_Nm = [_rF_raw[1], _rF_raw[2], _rF_raw[3]]

    ref_lengths = [aircraft_data.reference_span, aircraft_data.reference_span, aircraft_data.wing_mean_aerodynamic_chord]
    base_moment_factor = initial_flight_conditions.dynamic_pressure * aircraft_data.reference_area
    denominator = max(base_moment_factor, 1e-6)

    # STATIC r×F coefficients for the table correction path.
    # The moment tables (Cl, Cm, Cn) contain total-aircraft static moments at
    # freestream alpha/beta. To avoid cancelling the physical tail damping and
    # elevator/rudder effects, we subtract only the STATIC tail r×F (at
    # downwash-only angles). The delta between dynamic and static r×F then
    # naturally provides the physical damping and control surface moments.
    _alpha_tail_static_horizontal_rad = deg2rad(alpha_tail_static_horizontal_force_deg)
    _beta_tail_static_horizontal_rad = deg2rad(beta_tail_static_horizontal_force_deg)
    _alpha_tail_static_vertical_rad = deg2rad(alpha_tail_static_vertical_force_deg)
    _beta_tail_static_vertical_rad  = deg2rad(beta_tail_static_vertical_force_deg)
    _D_tail_static_h = tail_static_dynamic_pressure * horizontal_tail_area * CD_tail_horizontal_static
    _D_tail_static_v = tail_static_dynamic_pressure * vertical_tail_area * CD_tail_vertical_static
    _Y_tail_static = tail_static_dynamic_pressure * vertical_tail_area * CS_tail_static
    _L_tail_static = tail_static_dynamic_pressure * horizontal_tail_area * CL_tail_static
    _F_horizontal_tail_static_body = aerodynamic_force_body_from_coeffs(
        _D_tail_static_h, 0.0, _L_tail_static,
        _alpha_tail_static_horizontal_rad, _beta_tail_static_horizontal_rad
    )
    _F_vertical_tail_static_body = aerodynamic_force_body_from_coeffs(
        _D_tail_static_v, _Y_tail_static, 0.0,
        _alpha_tail_static_vertical_rad, _beta_tail_static_vertical_rad
    )
    _rF_static_raw =
        cross(r_wing_fuselage_wrt_CoG_body_m, aerodynamic_force_vector_body_wing_fuselage_N) +
        cross(r_horizontal_tail_wrt_CoG_body_m, _F_horizontal_tail_static_body) +
        cross(r_vertical_tail_wrt_CoG_body_m, _F_vertical_tail_static_body)
    _rF_static_Nm = [_rF_static_raw[1], _rF_static_raw[2], _rF_static_raw[3]]
    static_force_moment_coefficients_body = _rF_static_Nm ./ (denominator .* ref_lengths)
    vector_of_moment_coefficients_due_to_aero_forces_body =
        aerodynamic_moment_from_forces_body_Nm ./ (denominator .* ref_lengths)

    # Tail-control r×F contribution [Cl, Cn, Cm].
    #
    # The YAML control_effectiveness tables are total-aircraft derivatives.
    # The tail_CL/tail_CS lookup tables are local tail-force tables used for
    # force placement and visualisation.  When those local tables include
    # elevator/rudder axes, the physical r×F path already contributes part of
    # the total control moment.  We subtract that portion from the non-force
    # control coefficient below so the final aircraft response matches the
    # generated total derivative instead of being silently weakened.
    tail_control_moment_coefficients_body = [0.0, 0.0, 0.0]
    if _tail_cl_has_elevator_axis || _tail_cs_has_rudder_axis
        CL_tail_control_only = _tail_cl_has_elevator_axis ? fetch_aero_curve_value_or_default(
            "tail_CL",
            CL_tail_static,
            alpha=alpha_tail_static_deg,
            elevator_deg=elevator_deflection_deg,
            mach=initial_flight_conditions.Mach_number,
            altitude_m=initial_flight_conditions.altitude,
            throttle=current_throttle,
            configuration=current_configuration
        ) : CL_tail_static

        CS_tail_control_only = _tail_cs_has_rudder_axis ? fetch_aero_curve_value_or_default(
            "tail_CS",
            CS_tail_static,
            beta=beta_tail_static_deg,
            rudder_deg=rudder_deflection_deg,
            mach=initial_flight_conditions.Mach_number,
            altitude_m=initial_flight_conditions.altitude,
            throttle=current_throttle,
            configuration=current_configuration
        ) : CS_tail_static

        CD_tail_horizontal_control_only =
            tail_CD0_horizontal_static + aircraft_data.tail_k_induced * CL_tail_control_only^2
        CD_tail_vertical_control_only =
            tail_CD0_vertical_static + aircraft_data.tail_k_side * CS_tail_control_only^2

        _D_tail_control_h = tail_static_dynamic_pressure * horizontal_tail_area * CD_tail_horizontal_control_only
        _D_tail_control_v = tail_static_dynamic_pressure * vertical_tail_area * CD_tail_vertical_control_only
        _Y_tail_control = tail_static_dynamic_pressure * vertical_tail_area * CS_tail_control_only
        _L_tail_control = tail_static_dynamic_pressure * horizontal_tail_area * CL_tail_control_only

        _F_horizontal_tail_control_body = aerodynamic_force_body_from_coeffs(
            _D_tail_control_h, 0.0, _L_tail_control,
            _alpha_tail_static_horizontal_rad, _beta_tail_static_horizontal_rad
        )
        _F_vertical_tail_control_body = aerodynamic_force_body_from_coeffs(
            _D_tail_control_v, _Y_tail_control, 0.0,
            _alpha_tail_static_vertical_rad, _beta_tail_static_vertical_rad
        )

        _tail_control_delta_Nm =
            cross(r_horizontal_tail_wrt_CoG_body_m,
                  _F_horizontal_tail_control_body - _F_horizontal_tail_static_body) +
            cross(r_vertical_tail_wrt_CoG_body_m,
                  _F_vertical_tail_control_body - _F_vertical_tail_static_body)

        tail_control_moment_coefficients_body =
            [_tail_control_delta_Nm[1], _tail_control_delta_Nm[2], _tail_control_delta_Nm[3]] ./
            (denominator .* ref_lengths)
    end

    # Control moment coefficients [Cl_control, Cn_control, Cm_control].
    # Start from the generated total-aircraft derivatives, then subtract any
    # control moment already carried by local tail r×F.
    roll_control_total_coeff = 🟢_rolling_moment_coefficient_due_to_control_attained(
        initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
        aircraft_data, aircraft_state_vector, control_demand_vector_attained
    )
    rudder_roll_control_total_coeff = 🟢_rolling_moment_coefficient_due_to_yaw_control_attained(
        initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
        aircraft_data, aircraft_state_vector, control_demand_vector_attained
    )
    yaw_control_total_coeff = 🟢_yawing_moment_coefficient_due_to_yaw_control_attained(
        initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
        aircraft_data, aircraft_state_vector, control_demand_vector_attained
    )
    adverse_yaw_coeff = 🟢_yawing_moment_coefficient_due_to_roll_control_attained(
        initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
        aircraft_data, aircraft_state_vector, control_demand_vector_attained
    )
    pitch_control_total_coeff = 🟢_pitching_moment_coefficient_due_to_control_attained(
        initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
        aircraft_data, aircraft_state_vector, control_demand_vector_attained
    )

    roll_control_coeff =
        roll_control_total_coeff + rudder_roll_control_total_coeff -
        (_tail_cs_has_rudder_axis ? tail_control_moment_coefficients_body[1] : 0.0)
    yaw_control_coeff =
        yaw_control_total_coeff -
        (_tail_cs_has_rudder_axis ? tail_control_moment_coefficients_body[2] : 0.0)
    pitch_control_coeff =
        pitch_control_total_coeff -
        (_tail_cl_has_elevator_axis ? tail_control_moment_coefficients_body[3] : 0.0)

    vector_of_moment_coefficients_of_control_body =
        [
            roll_control_coeff,
            yaw_control_coeff + adverse_yaw_coeff,
            pitch_control_coeff
        ]

    # Static stability moment coefficients [Cl_static, Cn_static, Cm_static]
    # When full-aircraft moment tables (Cl, Cm, Cn vs alpha/beta) are available
    # in the YAML, use them as the definitive static moment source. These tables
    # already contain complete stability information (Cn_beta, Cm_alpha, Cl_beta,
    # Cm0, Cm_trim, and all nonlinear effects). The force-position contribution
    # (r×F) is subtracted so the net total equals table + control + damping.
    # When tables are NOT available, fall back to the decomposed model.
    _v3_force_assembly = hasproperty(wing_force_coeffs, :v3_assembled) ? wing_force_coeffs.v3_assembled : nothing
    _v3_static = _v3_force_assembly === nothing ? _v3_static_moments(
        initial_flight_conditions.alpha_rad,
        initial_flight_conditions.beta_rad,
        initial_flight_conditions.Mach_number,
        aircraft_data,
        control_demand_vector_attained
    ) : (Cl=_v3_force_assembly.Cl, Cm=_v3_force_assembly.Cm, Cn=_v3_force_assembly.Cn)
    if _v3_static !== nothing
        vector_of_moment_coefficients_of_static_stability_body = [
            _v3_static.Cl - static_force_moment_coefficients_body[1],
            _v3_static.Cn - static_force_moment_coefficients_body[2],
            _v3_static.Cm - static_force_moment_coefficients_body[3]
        ]
    elseif _has_moment_tables
        _moment_lookup = Dict{Symbol,Any}(
            :alpha => alpha_deg, :alpha_deg => alpha_deg,
            :beta => beta_deg, :beta_deg => beta_deg,
            :mach => initial_flight_conditions.Mach_number,
            :Mach => initial_flight_conditions.Mach_number,
            :config => current_configuration, :configuration => current_configuration
        )
        Cl_table = _fetch_coefficient_with_default("Cl", 0.0; pairs(_moment_lookup)...)
        Cm_table = _fetch_coefficient_with_default("Cm", 0.0; pairs(_moment_lookup)...)
        Cn_table = _fetch_coefficient_with_default("Cn", 0.0; pairs(_moment_lookup)...)

        # Post-stall moment correction.
        # Some aerodynamic databases (e.g. the PC-21 JDATCOM post-stall extension)
        # contain a Cm curve that loses its restoring slope past the stall and
        # even becomes POSITIVE at high |α|, which creates a spurious "trim"
        # point at ~45° α and drives the aircraft into an unphysical runaway
        # pitch-up.  Lateral moments (Cl, Cn) similarly retain their pre-stall
        # β-dependence well into the fully separated regime where the physical
        # mechanism generating those coefficients (attached flow over the wing)
        # no longer exists.
        #
        # We blend the table values with a simple parametric post-stall model
        # using the same dynamic-stall blend weight that drives the wing force
        # coefficients, so the moment and force behaviour stay consistent.
        #   - Cm_post = −poststall_cm_scale · sin(2α)  → always restoring
        #     (nose-down for α>0 up to 90°, nose-up for α<0 down to −90°).
        #   - Cl_post = 0, Cn_post = 0 (no attached-flow lateral stability).
        _stall_weight = clamp(wing_force_coeffs.stall_blend_weight, 0.0, 1.0)
        # Restoring Cm amplitude for the sin(2α) model.  It is derived from
        # the generated effective Cm_alpha; no artificial lower bound is
        # applied, so a bad aerodynamic model remains visible to QC instead of
        # being hidden by the simulator.
        _effective_Cm_alpha = (hasproperty(aircraft_data, :Cm_alpha) ? Float64(aircraft_data.Cm_alpha) : 0.0) +
                              (hasproperty(aircraft_data, :Cm_alpha_extra) ? Float64(aircraft_data.Cm_alpha_extra) : 0.0)
        _poststall_cm_scale = max(-_effective_Cm_alpha / 2.0, 0.0)
        _two_alpha_rad = 2.0 * initial_flight_conditions.alpha_rad
        Cm_post = -_poststall_cm_scale * sin(_two_alpha_rad)
        Cl_post = 0.0
        Cn_post = 0.0

        # Extra pitch-stiffness augmentation.
        # Some aerodynamic databases (PC-21 JDATCOM among them) have a
        # genuine but physically weak Cm_alpha — the slope of the pre-stall
        # Cm curve is only a fraction of what a geometric static-margin
        # analysis predicts, and the short-period response comes out mushy.
        # The Cm_alpha_extra scalar is added linearly on top of the table
        # value so both model modes ("linear" and "table") inherit the
        # same effective Cm_alpha.  It fades out in the post-stall region
        # because the table is already replaced there by the restoring
        # sin(2α) model.
        _Cm_alpha_extra = hasproperty(aircraft_data, :Cm_alpha_extra) ? Float64(aircraft_data.Cm_alpha_extra) : 0.0
        _Cm_alpha_boost = (1.0 - _stall_weight) * _Cm_alpha_extra * initial_flight_conditions.alpha_rad

        Cl_effective = (1.0 - _stall_weight) * Cl_table + _stall_weight * Cl_post
        Cm_effective = (1.0 - _stall_weight) * Cm_table + _stall_weight * Cm_post + _Cm_alpha_boost
        Cn_effective = (1.0 - _stall_weight) * Cn_table + _stall_weight * Cn_post

        # Table values are in standard (L, N, M) convention; sim slots agree
        # with standard so no flips needed.
        vector_of_moment_coefficients_of_static_stability_body = [
            Cl_effective - static_force_moment_coefficients_body[1],
            Cn_effective - static_force_moment_coefficients_body[2],
            Cm_effective - static_force_moment_coefficients_body[3]
        ]

        # The table Cm already includes Cm0 and Cm_trim at the reference condition,
        # so remove them from the control contribution to avoid double-counting.
        # (Applied before the sign flip below.)
        vector_of_moment_coefficients_of_control_body[3] -= (aircraft_data.Cm0 + aircraft_data.Cm_trim)
    else
        vector_of_moment_coefficients_of_static_stability_body = [
            🟢_rolling_moment_coefficient_due_to_sideslip(
                initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, control_demand_vector_attained
            ),
            0.0,  # Cn_beta×β handled by VTP side-force at tail AC (r×F)
            0.0   # Cm_alpha×α handled by wing/tail lift at their ACs (r×F)
        ]
    end

    # Telemetry should show the actual full control contribution, including
    # any local tail-force r×F portion that was subtracted from the residual
    # non-force control vector to avoid double counting in the dynamics.
    vector_of_moment_coefficients_of_control_telemetry_body =
        vector_of_moment_coefficients_of_control_body + tail_control_moment_coefficients_body

    # Control moment coefficients are in standard (L, N, M) convention,
    # sim slots match standard, so no flips needed.

    # Aerodynamic damping — standard (L, N, M) convention, all additive.
    # Primary damping (Cl_p·p, Cn_r·r, Cm_q·q) and cross-damping (Cl_r·r,
    # Cn_p·p) add into the total moment with their natural signs.
    vector_of_moment_coefficients_of_aerodynamic_damping_body =
        [
            🟢_rolling_moment_coefficient_due_to_aerodynamic_damping(
                initial_flight_conditions.p_roll_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            ) +
            🟢_rolling_moment_coefficient_due_to_yaw_rate(
                initial_flight_conditions.r_yaw_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            ),
            🟢_yawing_moment_coefficient_due_to_aerodynamic_damping(
                initial_flight_conditions.r_yaw_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            ) +
            🟢_yawing_moment_coefficient_due_to_roll_rate(
                initial_flight_conditions.p_roll_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            ) +
            🟢_yawing_moment_coefficient_due_to_beta_dot(
                initial_flight_conditions.r_yaw_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            ),
            🟢_pitching_moment_coefficient_due_to_aerodynamic_damping(
                initial_flight_conditions.q_pitch_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            ) +
            🟢_pitching_moment_coefficient_due_to_alpha_dot(
                initial_flight_conditions.q_pitch_rate, initial_flight_conditions.alpha_rad, initial_flight_conditions.beta_rad, initial_flight_conditions.Mach_number,
                aircraft_data, initial_flight_conditions.v_body_magnitude, current_configuration
            )
        ]

    # NOTE: Damping decomposition (subtracting estimated tail portion from the
    # parametric Cm_q/Cn_r) has been removed. The physical tail model provides
    # tail damping via the delta between dynamic and static r×F, while the
    # parametric damping provides the full-aircraft values. This means tail
    # damping is somewhat double-counted (resulting in slight over-damping),
    # but this is safe and stable. A correct decomposition requires separate
    # HTP and VTP reference areas which are not yet available in the data model.

    # Sum the non-dimensional moment coefficients [Cl, Cn, Cm]
    sum_of_coeffs = (
        vector_of_moment_coefficients_due_to_aero_forces_body +
        vector_of_moment_coefficients_of_control_body +
        vector_of_moment_coefficients_of_static_stability_body +
        vector_of_moment_coefficients_of_aerodynamic_damping_body
    )

    # Total dimensional moment = aerodynamic moment from r×F + coeff-based control/stability/damping moments
    coefficients_without_force_moment =
        vector_of_moment_coefficients_of_control_body +
        vector_of_moment_coefficients_of_static_stability_body +
        vector_of_moment_coefficients_of_aerodynamic_damping_body
    non_force_moments_in_body_frame = base_moment_factor .* ref_lengths .* coefficients_without_force_moment
    total_moment_in_body_frame = aerodynamic_moment_from_forces_body_Nm + non_force_moments_in_body_frame + propulsive_moment_body_Nm
    # The resulting vector total_moment_in_body_frame now represents [L_roll, N_yaw, M_pitch]

    # --- Angular Acceleration Calculation ---
    # Inverse dynamics for angular acceleration in body frame using Euler's equation:
    # α_body = I_body⁻¹ * [ M_external - ω_body × (I_body * ω_body) ]
    # Ensure omega_body = [p, r, q] matches the moment vector order [L, N, M] and inertia tensor structure.
    angular_acceleration_body = initial_flight_conditions.I_body_inverse * (total_moment_in_body_frame - cross(initial_flight_conditions.omega_body, initial_flight_conditions.I_body * initial_flight_conditions.omega_body))


    # === 4) RETURN THE STATE DERIVATIVES + FLIGHT CONDITIONS ===

    # State derivatives vector (order matters for the integrator)
    # [dx/dt, dy/dt, dz/dt, dvx/dt, dvy/dt, dvz/dt, dqx/dt, dqy/dt, dqz/dt, dqw/dt, dwx/dt, dwy/dt, dwz/dt, ...internal states]
    new_aircraft_state_vector = [
        # Linear Velocities (derivative of position)
        aircraft_state_vector[4],  # dx/dt = vx
        aircraft_state_vector[5],  # dy/dt = vy
        aircraft_state_vector[6],  # dz/dt = vz

        # Linear Accelerations (derivative of velocity) - in Global Frame
        aircraft_CoG_acceleration_global[1],  # dvx/dt
        aircraft_CoG_acceleration_global[2],  # dvy/dt
        aircraft_CoG_acceleration_global[3],  # dvz/dt

        # Quaternion Derivatives (derivative of orientation)
        initial_flight_conditions.q_dot[2],  # dqx/dt
        initial_flight_conditions.q_dot[3],  # dqy/dt
        initial_flight_conditions.q_dot[4],  # dqz/dt
        initial_flight_conditions.q_dot[1],  # dqw/dt (Note: scalar part often first in q_dot)

        # Angular Accelerations (derivative of angular velocity) - in Body Frame [p_dot, r_dot, q_dot]
        angular_acceleration_body[1],  # dwx/dt = dp/dt (roll acceleration)
        angular_acceleration_body[2],  # dwy/dt = dr/dt (yaw acceleration)
        angular_acceleration_body[3]   # dwz/dt = dq/dt (pitch acceleration)
    ]

    # Integrate dynamic-stall internal states only when present in the state vector.
    if length(aircraft_state_vector) >= DYNAMIC_STALL_SIGMA_STATE_INDEX
        push!(new_aircraft_state_vector, wing_force_coeffs.dynamic_stall_alpha_lag_derivative_deg_per_s)
        push!(new_aircraft_state_vector, wing_force_coeffs.dynamic_stall_sigma_derivative_per_s)
    end

    # Prepare telemetry data vector (ensure order matches definition in reset_flight_data_recording)
    flight_data_for_telemetry = [
        CL,
        CD,
        (abs(CD) > 1e-9 ? CL / CD : 0.0), # Avoid division by zero/inf
        CS, load_factors_body_axis[1], # nx_body
        load_factors_body_axis[2], # ny_body (Sim axes: Side force component load)
        load_factors_body_axis[3], # nz_body (Sim axes: Lift component load, usually negative)
        vector_of_moment_coefficients_due_to_aero_forces_body[1], # Cl_forces
        vector_of_moment_coefficients_due_to_aero_forces_body[2], # Cn_forces
        vector_of_moment_coefficients_due_to_aero_forces_body[3], # Cm_forces
        vector_of_moment_coefficients_of_control_telemetry_body[1], # Cl_control
        vector_of_moment_coefficients_of_control_telemetry_body[2], # Cn_control
        vector_of_moment_coefficients_of_control_telemetry_body[3], # Cm_control
        vector_of_moment_coefficients_of_static_stability_body[1], # Cl_static
        vector_of_moment_coefficients_of_static_stability_body[2], # Cn_static
        vector_of_moment_coefficients_of_static_stability_body[3], # Cm_static
        vector_of_moment_coefficients_of_aerodynamic_damping_body[1], # Cl_damping
        vector_of_moment_coefficients_of_aerodynamic_damping_body[2], # Cn_damping
        vector_of_moment_coefficients_of_aerodynamic_damping_body[3], # Cm_damping
        initial_flight_conditions.q_pitch_rate, # q
        initial_flight_conditions.p_roll_rate,  # p
        initial_flight_conditions.r_yaw_rate,   # r
        initial_flight_conditions.TAS,
        initial_flight_conditions.EAS,
        initial_flight_conditions.Mach_number,
        initial_flight_conditions.dynamic_pressure,
    ]

    # Component forces and their application points in global axes for 3D visualization
    aircraft_position_global = [aircraft_state_vector[1], aircraft_state_vector[2], aircraft_state_vector[3]]
    # Offset from CoG to force application point.
    # Computed in aero convention (x_fwd, y_right, z_down), then converted to simulator body
    # convention (x_fwd, y_up, z_left) using the same mapping as forces: [x, -z, -y].
    # This ensures rotate_vector_body_to_global produces correct global origins AND
    # that the offsets sent to JavaScript are already in BabylonJS-compatible coordinates.
    wing_aero_offset = [
        aircraft_data.x_CoG - aircraft_data.wing_fuselage_aero_center_x,
        aircraft_data.y_CoG - aircraft_data.wing_fuselage_aero_center_y,
        aircraft_data.z_CoG - aircraft_data.wing_fuselage_aero_center_z
    ]
    wing_application_offset_body = [wing_aero_offset[1], -wing_aero_offset[3], -wing_aero_offset[2]]

    htail_aero_offset = [
        aircraft_data.x_CoG - aircraft_data.x_horizontal_tail_aerodynamic_center,
        aircraft_data.y_CoG - aircraft_data.y_horizontal_tail_aerodynamic_center,
        aircraft_data.z_CoG - aircraft_data.z_horizontal_tail_aerodynamic_center
    ]
    horizontal_tail_application_offset_body = [htail_aero_offset[1], -htail_aero_offset[3], -htail_aero_offset[2]]

    vtail_aero_offset = [
        aircraft_data.x_CoG - aircraft_data.x_vertical_tail_aerodynamic_center,
        aircraft_data.y_CoG - aircraft_data.y_vertical_tail_aerodynamic_center,
        aircraft_data.z_CoG - aircraft_data.z_vertical_tail_aerodynamic_center
    ]
    vertical_tail_application_offset_body = [vtail_aero_offset[1], -vtail_aero_offset[3], -vtail_aero_offset[2]]

    wing_force_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_force_vector_body_wing_fuselage_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    tail_force_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_force_vector_body_tail_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    tail_lift_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_tail_lift_vector_body_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    horizontal_tail_force_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_force_vector_body_horizontal_tail_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    vertical_tail_force_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_force_vector_body_vertical_tail_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    wing_lift_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_force_vector_body_wing_fuselage_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    horizontal_tail_lift_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_tail_lift_vector_body_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    vertical_tail_lift_vector_global_N = rotate_vector_body_to_global(
        aerodynamic_vertical_tail_lift_vector_body_N,
        initial_flight_conditions.global_orientation_quaternion
    )
    horizontal_tail_local_velocity_global = rotate_vector_body_to_global(
        horizontal_tail_local_velocity_body,
        initial_flight_conditions.global_orientation_quaternion
    )
    vertical_tail_local_velocity_global = rotate_vector_body_to_global(
        vertical_tail_local_velocity_body,
        initial_flight_conditions.global_orientation_quaternion
    )

    wing_force_origin_global = aircraft_position_global + rotate_vector_body_to_global(
        wing_application_offset_body,
        initial_flight_conditions.global_orientation_quaternion
    )
    horizontal_tail_lift_origin_global = aircraft_position_global + rotate_vector_body_to_global(
        horizontal_tail_application_offset_body,
        initial_flight_conditions.global_orientation_quaternion
    )
    vertical_tail_lift_origin_global = aircraft_position_global + rotate_vector_body_to_global(
        vertical_tail_application_offset_body,
        initial_flight_conditions.global_orientation_quaternion
    )
    weight_force_origin_global = aircraft_position_global
    weight_force_vector_global_for_visualization = [weight_force_global_N[1], weight_force_global_N[2], weight_force_global_N[3]]

    component_forces_for_visualization = (
        wing_lift_vector_global_N=wing_lift_vector_global_N,
        horizontal_tail_lift_vector_global_N=horizontal_tail_lift_vector_global_N,
        vertical_tail_lift_vector_global_N=vertical_tail_lift_vector_global_N,
        horizontal_tail_force_vector_global_N=horizontal_tail_force_vector_global_N,
        vertical_tail_force_vector_global_N=vertical_tail_force_vector_global_N,
        horizontal_tail_local_velocity_global=horizontal_tail_local_velocity_global,
        vertical_tail_local_velocity_global=vertical_tail_local_velocity_global,
        weight_force_vector_global_N=weight_force_vector_global_for_visualization,
        wing_lift_origin_global=wing_force_origin_global,
        horizontal_tail_lift_origin_global=horizontal_tail_lift_origin_global,
        vertical_tail_lift_origin_global=vertical_tail_lift_origin_global,
        weight_force_origin_global=weight_force_origin_global,

        # Legacy fields kept for compatibility with any existing consumers:
        wing_force_vector_global_N=wing_force_vector_global_N,
        tail_force_vector_global_N=tail_force_vector_global_N,
        tail_lift_vector_global_N=tail_lift_vector_global_N,
        wing_force_origin_global=wing_force_origin_global,
        tail_force_origin_global=horizontal_tail_lift_origin_global,

        # Constant body offsets purely for visualizing aerodynamic centers correctly across frameworks
        wing_offset_body=wing_application_offset_body,
        htail_offset_body=horizontal_tail_application_offset_body,
        vtail_offset_body=vertical_tail_application_offset_body
    )

    # Return state derivatives, global forces (excluding gravity), telemetry data and aero component vectors
    return (
        new_aircraft_state_vector,
        total_propulsive_plus_aerodynamic_force_vector_global_N,
        flight_data_for_telemetry,
        component_forces_for_visualization
    )

end
