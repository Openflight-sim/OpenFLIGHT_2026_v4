#!/usr/bin/env julia

using Logging
using Dates

global sim_time = 0.0
global dynamic_stall_alpha_lag_deg_state = 0.0
global dynamic_stall_sigma_state = 0.0
global dynamic_stall_state_initialized = false
global frontend_static_payload_burst_frames = 60
global frontend_static_payload_frames_remaining = frontend_static_payload_burst_frames

const global_state_dict = Dict{String, Any}()

function _to_float_or_default(source::Dict{String, Any}, key::String, default_value::Float64)
    if !haskey(source, key)
        return default_value
    end
    value = source[key]
    if value isa Number
        return Float64(value)
    elseif value isa AbstractString
        try
            return parse(Float64, strip(value))
        catch
            return default_value
        end
    end
    return default_value
end

function _to_string_or_default(source::Dict{String, Any}, key::String, default_value::String)
    if !haskey(source, key)
        return default_value
    end
    return string(source[key])
end

function _extract_float_vector_or_default(value, fallback::Vector{Float64})
    if value isa AbstractVector && !isempty(value)
        output = Float64[]
        for element in value
            if element isa Number
                push!(output, Float64(element))
            elseif element isa AbstractString
                try
                    push!(output, parse(Float64, strip(element)))
                catch
                end
            end
        end
        if !isempty(output)
            return output
        end
    end
    return copy(fallback)
end

function _round_value_for_transport(value)
    if value isa Number
        return round(Float64(value), digits=4)
    elseif value isa AbstractVector
        return [_round_value_for_transport(v) for v in value]
    elseif value isa AbstractDict
        rounded_dict = Dict{String, Any}()
        for (key, nested_value) in value
            rounded_dict[string(key)] = _round_value_for_transport(nested_value)
        end
        return rounded_dict
    end
    return value
end

function _is_truthy_reset_signal(value)
    if value isa Bool
        return value
    elseif value isa Number
        return Float64(value) != 0.0
    elseif value isa AbstractString
        normalized = lowercase(strip(String(value)))
        return normalized in ("1", "true", "yes", "y", "on")
    end
    return false
end

function _should_reset_dynamic_stall_from_message(aircraft_state_data::Dict{String, Any})
    candidate_keys = (
        "reset_dynamic_stall",
        "reset_state",
        "respawn",
        "respawn_requested",
        "restart",
        "reset"
    )
    for key in candidate_keys
        if haskey(aircraft_state_data, key) && _is_truthy_reset_signal(aircraft_state_data[key])
            return true
        end
    end
    return false
end

function update_aircraft_state(
    aircraft_state_data::Dict{String, Any},
    aircraft_flight_physics_and_propulsive_data
)
    try
        aircraft_current_state_vector_13 = [
            _to_float_or_default(aircraft_state_data, "x", 0.0),
            _to_float_or_default(aircraft_state_data, "y", 0.0),
            _to_float_or_default(aircraft_state_data, "z", 0.0),
            _to_float_or_default(aircraft_state_data, "vx", 0.0),
            _to_float_or_default(aircraft_state_data, "vy", 0.0),
            _to_float_or_default(aircraft_state_data, "vz", 0.0),
            _to_float_or_default(aircraft_state_data, "qx", 0.0),
            _to_float_or_default(aircraft_state_data, "qy", 0.0),
            _to_float_or_default(aircraft_state_data, "qz", 0.0),
            _to_float_or_default(aircraft_state_data, "qw", 1.0),
            _to_float_or_default(aircraft_state_data, "wx", 0.0),
            _to_float_or_default(aircraft_state_data, "wy", 0.0),
            _to_float_or_default(aircraft_state_data, "wz", 0.0)
        ]

        global dynamic_stall_alpha_lag_deg_state
        global dynamic_stall_sigma_state
        global dynamic_stall_state_initialized
        reset_requested = _should_reset_dynamic_stall_from_message(aircraft_state_data)
        if reset_requested
            dynamic_stall_state_initialized = false
            if isdefined(Main, :reset_auto_pitch_trim_state_memory)
                reset_auto_pitch_trim_state_memory(reason="respawn/reset request")
            end
        end
        if !dynamic_stall_state_initialized
            initial_conditions_for_dynamic_stall = compute_flight_conditions_from_state_vector(
                aircraft_current_state_vector_13,
                aircraft_flight_physics_and_propulsive_data
            )
            dynamic_stall_alpha_lag_deg_state = rad2deg(initial_conditions_for_dynamic_stall.alpha_rad)
            dynamic_stall_sigma_state = compute_initial_dynamic_stall_sigma(
                dynamic_stall_alpha_lag_deg_state,
                aircraft_flight_physics_and_propulsive_data
            )
            dynamic_stall_state_initialized = true
        end

        aircraft_current_state_vector = [
            aircraft_current_state_vector_13...,
            dynamic_stall_alpha_lag_deg_state,
            dynamic_stall_sigma_state
        ]

        engine_count = Int(get(aircraft_flight_physics_and_propulsive_data, :engine_count, 1))
        engine_count = max(engine_count, 1)
        default_throttle_demand = _to_float_or_default(aircraft_state_data, "thrust_setting_demand", 0.0)
        default_throttle_attained = _to_float_or_default(aircraft_state_data, "thrust_attained", default_throttle_demand)

        incoming_throttle_demand_vector = haskey(aircraft_state_data, "throttle_demand_vector") ?
            _extract_float_vector_or_default(aircraft_state_data["throttle_demand_vector"], fill(default_throttle_demand, engine_count)) :
            fill(default_throttle_demand, engine_count)
        incoming_throttle_attained_vector = haskey(aircraft_state_data, "throttle_attained_vector") ?
            _extract_float_vector_or_default(aircraft_state_data["throttle_attained_vector"], fill(default_throttle_attained, engine_count)) :
            fill(default_throttle_attained, engine_count)

        if length(incoming_throttle_demand_vector) < engine_count
            append!(incoming_throttle_demand_vector, fill(incoming_throttle_demand_vector[end], engine_count - length(incoming_throttle_demand_vector)))
        elseif length(incoming_throttle_demand_vector) > engine_count
            incoming_throttle_demand_vector = incoming_throttle_demand_vector[1:engine_count]
        end

        if length(incoming_throttle_attained_vector) < engine_count
            append!(incoming_throttle_attained_vector, fill(incoming_throttle_attained_vector[end], engine_count - length(incoming_throttle_attained_vector)))
        elseif length(incoming_throttle_attained_vector) > engine_count
            incoming_throttle_attained_vector = incoming_throttle_attained_vector[1:engine_count]
        end

        control_demand_vector = (
            fx=_to_float_or_default(aircraft_state_data, "fx", 0.0),
            fy=_to_float_or_default(aircraft_state_data, "fy", 0.0),
            roll_demand=_to_float_or_default(aircraft_state_data, "roll_demand", 0.0),
            pitch_demand=_to_float_or_default(aircraft_state_data, "pitch_demand", 0.0),
            yaw_demand=_to_float_or_default(aircraft_state_data, "yaw_demand", 0.0),
            thrust_setting_demand=default_throttle_demand,
            throttle_demand_vector=incoming_throttle_demand_vector,
            configuration=_to_string_or_default(
                aircraft_state_data,
                "configuration",
                string(get(aircraft_flight_physics_and_propulsive_data, :default_configuration, "clean"))
            ),
            roll_demand_attained=_to_float_or_default(aircraft_state_data, "roll_demand_attained", 0.0),
            pitch_demand_attained=_to_float_or_default(aircraft_state_data, "pitch_demand_attained", 0.0),
            yaw_demand_attained=_to_float_or_default(aircraft_state_data, "yaw_demand_attained", 0.0),
            thrust_attained=default_throttle_attained,
            throttle_attained_vector=incoming_throttle_attained_vector
        )

        deltaTime = _to_float_or_default(aircraft_state_data, "deltaTime", 0.0)
        global sim_time
        sim_time += deltaTime

        integrator_result_dict = Runge_Kutta_4_integrator(
            aircraft_current_state_vector,
            control_demand_vector,
            deltaTime,
            aircraft_flight_physics_and_propulsive_data
        )

        if haskey(integrator_result_dict, "dynamic_stall_alpha_lag_deg_state")
            dynamic_stall_alpha_lag_deg_state = Float64(integrator_result_dict["dynamic_stall_alpha_lag_deg_state"])
        end
        if haskey(integrator_result_dict, "dynamic_stall_sigma_state")
            dynamic_stall_sigma_state = clamp(Float64(integrator_result_dict["dynamic_stall_sigma_state"]), 0.0, 1.0)
        end

        empty!(global_state_dict)
        for (key, value) in integrator_result_dict
            global_state_dict[string(key)] = _round_value_for_transport(value)
        end

        gather_flight_data(global_state_dict, sim_time, df)

        global_state_dict["server_time"] = round(Float64(sim_time), digits=2)
        global_state_dict["aircraft_mass"] = round(Float64(aircraft_flight_physics_and_propulsive_data.aircraft_mass), digits=4)
        global_state_dict["reference_area"] = round(Float64(aircraft_flight_physics_and_propulsive_data.reference_area), digits=4)
        global_state_dict["reference_span"] = round(Float64(aircraft_flight_physics_and_propulsive_data.reference_span), digits=4)
        global_state_dict["wing_mean_aerodynamic_chord"] = round(Float64(aircraft_flight_physics_and_propulsive_data.wing_mean_aerodynamic_chord), digits=4)
        global_state_dict["AR"] = round(Float64(aircraft_flight_physics_and_propulsive_data.AR), digits=4)
        global_state_dict["Oswald_factor"] = round(Float64(aircraft_flight_physics_and_propulsive_data.Oswald_factor), digits=4)
        global_state_dict["CD0"] = round(Float64(aircraft_flight_physics_and_propulsive_data.CD0), digits=4)
        global_state_dict["CL_max"] = round(Float64(aircraft_flight_physics_and_propulsive_data.CL_max), digits=4)
        global_state_dict["stall_speed_sea_level_m_s"] = round(Float64(get(aircraft_flight_physics_and_propulsive_data, :stall_speed_sea_level_m_s, 0.0)), digits=4)
        global_state_dict["stall_speed_analysis_altitude_m_s"] = round(Float64(get(aircraft_flight_physics_and_propulsive_data, :stall_speed_analysis_altitude_m_s, 0.0)), digits=4)
        global_state_dict["recommended_initial_velocity_m_s"] = round(Float64(get(aircraft_flight_physics_and_propulsive_data, :recommended_initial_velocity_m_s, 0.0)), digits=4)
        global_state_dict["alpha_stall_positive"] = round(Float64(aircraft_flight_physics_and_propulsive_data.alpha_stall_positive), digits=4)
        global_state_dict["alpha_stall_negative"] = round(Float64(aircraft_flight_physics_and_propulsive_data.alpha_stall_negative), digits=4)
        global_state_dict["configuration"] = string(get(global_state_dict, "configuration", string(get(aircraft_flight_physics_and_propulsive_data, :default_configuration, "clean"))))
        global_state_dict["available_configurations"] = collect(get(aircraft_flight_physics_and_propulsive_data, :available_configurations, String[]))
        global_state_dict["engine_count"] = Int(get(aircraft_flight_physics_and_propulsive_data, :engine_count, 1))

        global frontend_static_payload_frames_remaining
        if frontend_static_payload_frames_remaining > 0
            # Static frontend payload burst: send visual/model/render metadata
            # after connect or reload, then keep normal physics frames lean.
            if isdefined(Main, :aircraft_visual_geometry) && Main.aircraft_visual_geometry !== nothing
                global_state_dict["visual_geometry"] = Main.aircraft_visual_geometry
            end

            # Send GLB model URL if a .glb file exists in the aircraft folder
            if isdefined(Main, :aircraft_glb_filename) && Main.aircraft_glb_filename !== nothing
                global_state_dict["glb_url"] = "/aircraft/" * Main.aircraft_glb_filename
            end

            # Send per-aircraft render overrides (glb_transform, lights,
            # propeller pivot, camera_positions). Optional: set from a
            # `render_settings.yaml` that may sit next to the .glb inside the
            # aircraft folder.  When absent the JS side falls back to its
            # built-in defaults, so sending `nothing` simply means "client,
        # use your defaults."  Static per-session data — JS caches after
            # the first frame it arrives in.
            if isdefined(Main, :aircraft_render_settings) && Main.aircraft_render_settings !== nothing
                global_state_dict["render_settings"] = Main.aircraft_render_settings
            end
            frontend_static_payload_frames_remaining = max(frontend_static_payload_frames_remaining - 1, 0)
        end

        return global_state_dict
    catch e
        @error "Error processing state" exception = (e, catch_backtrace())
        return nothing
    end
end
