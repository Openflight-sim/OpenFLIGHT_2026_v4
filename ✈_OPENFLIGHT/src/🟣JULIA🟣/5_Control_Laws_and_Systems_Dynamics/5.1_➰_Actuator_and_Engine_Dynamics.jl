function convert_control_demanded_to_attained(
    aircraft_model_data,
    control_demand_vector,
    deltaTime
)
    local function vector_mean(values::Vector{Float64}, default_value::Float64)
        return isempty(values) ? default_value : sum(values) / length(values)
    end

    # Defensive fallback only — the aircraft/mission loaders (0.1 and 3.1)
    # already default to 4.0 when neither the aero YAML nor the mission YAML
    # specifies the key.  Kept here so a direct call that bypasses the
    # loaders still gets a realistic actuator speed rather than the old 1.0.
    actuator_speed = get(aircraft_model_data, :control_actuator_speed, 4.0)
    engine_count = Int(get(aircraft_model_data, :engine_count, 1))
    engine_count = max(engine_count, 1)

    scalar_spool_up = get(aircraft_model_data, :engine_spool_up_speed, 1.0)
    scalar_spool_down = get(aircraft_model_data, :engine_spool_down_speed, 1.0)

    spool_up_speeds = get(aircraft_model_data, :engine_spool_up_speeds, fill(scalar_spool_up, engine_count))
    spool_down_speeds = get(aircraft_model_data, :engine_spool_down_speeds, fill(scalar_spool_down, engine_count))

    if length(spool_up_speeds) < engine_count
        spool_up_speeds = vcat(spool_up_speeds, fill(scalar_spool_up, engine_count - length(spool_up_speeds)))
    elseif length(spool_up_speeds) > engine_count
        spool_up_speeds = spool_up_speeds[1:engine_count]
    end

    if length(spool_down_speeds) < engine_count
        spool_down_speeds = vcat(spool_down_speeds, fill(scalar_spool_down, engine_count - length(spool_down_speeds)))
    elseif length(spool_down_speeds) > engine_count
        spool_down_speeds = spool_down_speeds[1:engine_count]
    end

    function compute_attained(demanded, current, speed, local_delta_time)
        max_delta = speed * local_delta_time
        command_error = demanded - current
        if isapprox(max_delta, 0.0; atol=1e-12)
            return current
        end
        if abs(command_error) <= max_delta
            return demanded
        end
        return current + sign(command_error) * max_delta
    end

    function compute_thrust_attained(demanded, current, spool_up_speed, spool_down_speed, local_delta_time)
        if demanded > current
            return compute_attained(demanded, current, spool_up_speed, local_delta_time)
        elseif demanded < current
            return compute_attained(demanded, current, spool_down_speed, local_delta_time)
        end
        return current
    end

    scalar_thrust_demand = get(control_demand_vector, :thrust_setting_demand, 0.0)
    scalar_thrust_attained_previous = get(control_demand_vector, :thrust_attained, scalar_thrust_demand)

    throttle_demand_vector = if hasproperty(control_demand_vector, :throttle_demand_vector) &&
                                getproperty(control_demand_vector, :throttle_demand_vector) isa AbstractVector &&
                                !isempty(getproperty(control_demand_vector, :throttle_demand_vector))
        [Float64(v) for v in getproperty(control_demand_vector, :throttle_demand_vector)]
    else
        fill(Float64(scalar_thrust_demand), engine_count)
    end

    throttle_attained_previous_vector = if hasproperty(control_demand_vector, :throttle_attained_vector) &&
                                           getproperty(control_demand_vector, :throttle_attained_vector) isa AbstractVector &&
                                           !isempty(getproperty(control_demand_vector, :throttle_attained_vector))
        [Float64(v) for v in getproperty(control_demand_vector, :throttle_attained_vector)]
    else
        fill(Float64(scalar_thrust_attained_previous), engine_count)
    end

    if length(throttle_demand_vector) < engine_count
        append!(throttle_demand_vector, fill(throttle_demand_vector[end], engine_count - length(throttle_demand_vector)))
    elseif length(throttle_demand_vector) > engine_count
        throttle_demand_vector = throttle_demand_vector[1:engine_count]
    end

    if length(throttle_attained_previous_vector) < engine_count
        append!(throttle_attained_previous_vector, fill(throttle_attained_previous_vector[end], engine_count - length(throttle_attained_previous_vector)))
    elseif length(throttle_attained_previous_vector) > engine_count
        throttle_attained_previous_vector = throttle_attained_previous_vector[1:engine_count]
    end

    throttle_attained_vector = Float64[]
    for engine_index in 1:engine_count
        push!(
            throttle_attained_vector,
            compute_thrust_attained(
                throttle_demand_vector[engine_index],
                throttle_attained_previous_vector[engine_index],
                Float64(spool_up_speeds[engine_index]),
                Float64(spool_down_speeds[engine_index]),
                deltaTime
            )
        )
    end

    thrust_attained = vector_mean(throttle_attained_vector, Float64(scalar_thrust_attained_previous))
    thrust_setting_demand = vector_mean(throttle_demand_vector, Float64(scalar_thrust_demand))

    roll_attained = compute_attained(
        control_demand_vector.roll_demand,
        control_demand_vector.roll_demand_attained,
        actuator_speed,
        deltaTime
    )

    pitch_attained = compute_attained(
        control_demand_vector.pitch_demand,
        control_demand_vector.pitch_demand_attained,
        actuator_speed,
        deltaTime
    )

    yaw_attained = compute_attained(
        control_demand_vector.yaw_demand,
        control_demand_vector.yaw_demand_attained,
        actuator_speed,
        deltaTime
    )

    configuration = hasproperty(control_demand_vector, :configuration) ?
                    string(getproperty(control_demand_vector, :configuration)) :
                    string(get(aircraft_model_data, :default_configuration, "clean"))

    control_demand_vector_attained = (
        fx=get(control_demand_vector, :fx, get(control_demand_vector, :x, 0.0)),
        fy=get(control_demand_vector, :fy, get(control_demand_vector, :y, 0.0)),
        x=get(control_demand_vector, :x, get(control_demand_vector, :fx, 0.0)),
        y=get(control_demand_vector, :y, get(control_demand_vector, :fy, 0.0)),

        roll_demand=control_demand_vector.roll_demand,
        pitch_demand=control_demand_vector.pitch_demand,
        yaw_demand=control_demand_vector.yaw_demand,
        thrust_setting_demand=thrust_setting_demand,
        throttle_demand_vector=throttle_demand_vector,
        configuration=configuration,

        roll_demand_attained=roll_attained,
        pitch_demand_attained=pitch_attained,
        yaw_demand_attained=yaw_attained,
        thrust_attained=thrust_attained,
        throttle_attained_vector=throttle_attained_vector
    )

    return control_demand_vector_attained
end
