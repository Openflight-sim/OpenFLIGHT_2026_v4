function _extract_throttle_attained_vector(control_demand_vector_attained, aircraft_data)
    engine_count = Int(get(aircraft_data, :engine_count, 1))
    if engine_count <= 0
        engine_count = 1
    end

    if hasproperty(control_demand_vector_attained, :throttle_attained_vector)
        raw_vector = getproperty(control_demand_vector_attained, :throttle_attained_vector)
        if raw_vector isa AbstractVector && !isempty(raw_vector)
            throttles = [Float64(v) for v in raw_vector]
            if length(throttles) < engine_count
                append!(throttles, fill(throttles[end], engine_count - length(throttles)))
            elseif length(throttles) > engine_count
                throttles = throttles[1:engine_count]
            end
            return throttles
        end
    end

    scalar_throttle = hasproperty(control_demand_vector_attained, :thrust_attained) ?
                      Float64(getproperty(control_demand_vector_attained, :thrust_attained)) :
                      0.0
    return fill(scalar_throttle, engine_count)
end

function _fallback_engine_models(aircraft_data)
    installation_angle_rad = deg2rad(get(aircraft_data, :thrust_installation_angle_DEG, 0.0))
    return [(
        id="engine_1",
        max_thrust_newton=Float64(get(aircraft_data, :maximum_thrust_at_sea_level, 0.0)),
        reverse_thrust_ratio=0.3,
        position_body_m=[0.0, 0.0, 0.0],
        direction_body=[cos(installation_angle_rad), sin(installation_angle_rad), 0.0],
        throttle_channel=1
    )]
end

function compute_propulsion_force_and_moment_body(
    altitude_m,
    Mach,
    aircraft_flight_physics_and_propulsive_data,
    aircraft_state,
    control_demand_vector_attained
)
    engines = get(aircraft_flight_physics_and_propulsive_data, :engines, nothing)
    if engines === nothing || isempty(engines)
        engines = _fallback_engine_models(aircraft_flight_physics_and_propulsive_data)
    end

    throttle_vector = _extract_throttle_attained_vector(
        control_demand_vector_attained,
        aircraft_flight_physics_and_propulsive_data
    )

    total_force_body = [0.0, 0.0, 0.0]
    total_moment_body = [0.0, 0.0, 0.0]
    engine_thrusts_newton = Float64[]

    for (engine_index, engine) in enumerate(engines)
        throttle_channel = Int(get(engine, :throttle_channel, engine_index))
        throttle_channel = clamp(throttle_channel, 1, length(throttle_vector))
        throttle_raw = throttle_vector[throttle_channel]

        reverse_ratio = Float64(get(engine, :reverse_thrust_ratio, 0.3))
        thrust_ratio = throttle_raw >= 0.0 ? throttle_raw : throttle_raw * reverse_ratio

        max_thrust_newton = Float64(get(engine, :max_thrust_newton, 0.0))
        thrust_newton = thrust_ratio * max_thrust_newton
        push!(engine_thrusts_newton, thrust_newton)

        direction_body = [Float64(v) for v in get(engine, :direction_body, [1.0, 0.0, 0.0])]
        direction_norm = norm(direction_body)
        if direction_norm <= 1e-9
            direction_body = [1.0, 0.0, 0.0]
        else
            direction_body = direction_body ./ direction_norm
        end

        engine_force_body = thrust_newton .* direction_body
        total_force_body .+= engine_force_body

        position_body = [Float64(v) for v in get(engine, :position_body_m, [0.0, 0.0, 0.0])]
        total_moment_body .+= cross(position_body, engine_force_body)
    end

    return (
        force_body_N=total_force_body,
        moment_body_Nm=total_moment_body,
        engine_thrusts_N=engine_thrusts_newton,
        throttle_attained_vector=throttle_vector
    )
end

function 🔺_compute_net_thrust_force_vector_body(
    altitude_m,
    Mach,
    aircraft_flight_physics_and_propulsive_data,
    aircraft_state,
    control_demand_vector_attained
)
    return compute_propulsion_force_and_moment_body(
        altitude_m,
        Mach,
        aircraft_flight_physics_and_propulsive_data,
        aircraft_state,
        control_demand_vector_attained
    ).force_body_N
end
