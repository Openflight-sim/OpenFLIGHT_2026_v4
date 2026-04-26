function get_mission_float_or_default(key::String, default_value::Float64)
    if @isdefined(MISSION_DATA) && haskey(MISSION_DATA, key)
        raw_value = MISSION_DATA[key]
        try
            return Float64(raw_value)
        catch
            @warn "Invalid mission value for '$key' = $raw_value. Falling back to $default_value."
            return default_value
        end
    end
    return default_value
end

function get_mission_string_or_default(key::String, default_value::String)
    if @isdefined(MISSION_DATA) && haskey(MISSION_DATA, key)
        raw_value = MISSION_DATA[key]
        try
            return lowercase(strip(string(raw_value)))
        catch
            @warn "Invalid mission value for '$key' = $raw_value. Falling back to $default_value."
            return default_value
        end
    end
    return default_value
end

# Integrator stability bounds. Internal constants, not user-tunable:
#   • `_max_simulation_step_config` clamps any incoming client deltaTime so a
#     backgrounded tab or GC pause cannot produce a multi-second RK4 leap.
#   • `_max_rk4_substep_config` caps a single RK4 evaluation; larger accepted
#     dts are split into equal sub-intervals to keep RK4 inside its stability
#     envelope (PC-21-class dynamics: roll rate ~6 rad/s, actuator τ ~100 ms).
# Reducing either without understanding the trade-off produces visible
# time-dilation or numerical instability during hard maneuvers.
const _max_simulation_step_config = 0.10
const _max_rk4_substep_config = 0.02

# ── Auto pitch trim ──────────────────────────────────────────
# Three modes, selected in the mission YAML via `auto_pitch_trim_mode`:
#
#   "off"        — no auto trim at all. Pilot flies raw; any Cm_0 or
#                  Cm_alpha·α_initial bias shows up as a held stick
#                  pressure the pilot must carry.
#   "initial"    — compute the trim bias once on the first frame so the
#                  aircraft launches trimmed at its initial condition,
#                  then hold that bias constant for the rest of the
#                  session. Good for quick-start, but the bias does not
#                  follow the aircraft as speed/altitude/mass change.
#                  The hidden bias smoothly fades out as the pilot moves
#                  the pitch control away from center, so it does not
#                  mask or fight an intentional pitch command.
#   "continuous" — start from the initial-frame trim, then drive a slow
#                  integrator every frame:
#                      bias_dot = k · pilot_pitch_demand
#                  where `pilot_pitch_demand` is the RAW pilot stick (NOT
#                  including the current trim bias). Any sustained stick
#                  pressure the pilot holds is slowly absorbed into the
#                  trim bias with time-constant ≈ 1/k seconds, mimicking
#                  an electric trim runaway-free auto-trim. k is set from
#                  the YAML key `auto_pitch_trim_rate` (default 0.1 /s).
#                  The bias is clamped to ±0.5 stick-equivalent so a
#                  runaway cannot drive the elevator fully over.
#
# DEFAULT: "initial" (matches the pre-2026-04-11 behaviour so existing
# missions do not change under anyone's feet).
function _current_auto_pitch_trim_mode()
    raw_mode = get_mission_string_or_default("auto_pitch_trim_mode", "initial")
    return raw_mode in ("off", "initial", "continuous") ? raw_mode : "initial"
end
function _current_auto_pitch_trim_rate_per_s()
    return max(get_mission_float_or_default("auto_pitch_trim_rate", 0.1), 0.0)
end
const AUTO_PITCH_TRIM_DEADBAND = 0.005
const _auto_pitch_trim_lock = ReentrantLock()
global _auto_pitch_trim_bias::Float64 = 0.0
global _auto_pitch_trim_computed::Bool = false

function _current_auto_pitch_trim_max_bias()
    return clamp(get_mission_float_or_default("auto_pitch_trim_max_bias", 0.10), 0.0, 0.25)
end

const AUTO_PITCH_TRIM_BLEND_TO_ZERO_INPUT = 0.05

function _compute_auto_pitch_trim_blend(stored_trim_bias::Float64, pilot_pitch_demand::Float64, mode::String)
    mode == "off" && return 0.0

    # If the pilot commands opposite to the stored trim bias, remove the
    # hidden trim immediately so it cannot cancel the intended maneuver.
    if abs(pilot_pitch_demand) > AUTO_PITCH_TRIM_DEADBAND &&
       abs(stored_trim_bias) > 1e-9 &&
       sign(pilot_pitch_demand) != sign(stored_trim_bias)
        return 0.0
    end

    if abs(pilot_pitch_demand) <= AUTO_PITCH_TRIM_DEADBAND
        return 1.0
    end
    if abs(pilot_pitch_demand) >= AUTO_PITCH_TRIM_BLEND_TO_ZERO_INPUT
        return 0.0
    end

    normalized_input = (abs(pilot_pitch_demand) - AUTO_PITCH_TRIM_DEADBAND) /
        (AUTO_PITCH_TRIM_BLEND_TO_ZERO_INPUT - AUTO_PITCH_TRIM_DEADBAND)
    return 1.0 - _smoothstep01(normalized_input)
end

function reset_auto_pitch_trim_state_memory(; reason::String="manual")
    lock(_auto_pitch_trim_lock) do
        global _auto_pitch_trim_bias = 0.0
        global _auto_pitch_trim_computed = false
    end
    @info "Auto pitch trim state reset" reason=reason
end

function _compute_auto_pitch_trim(
    aircraft_state_vector::Vector{Float64},
    aircraft_data
)
    # Evaluate Cm at the initial condition with zero control input and pick
    # a normalised pitch demand that zeroes the total pitching moment.  The
    # formula branches on the active aerodynamic model:
    #
    #   • linear mode → use the scalar stability derivatives directly in /rad
    #     (Cm_0 + Cm_alpha·α + Cm_delta_e·δe_rad = 0).  This correctly picks
    #     up an aircraft like SU57 whose Cm bias lives in the `Cm0` scalar
    #     and has no `Cm` coefficient table.
    #
    #   • table mode → look up the full `Cm` coefficient table for the pre-
    #     control moment, and the `Cm_de_per_deg` table (or legacy scalar)
    #     for elevator effectiveness in /deg.
    fc = compute_flight_conditions_from_state_vector(aircraft_state_vector, aircraft_data)
    alpha_rad = fc.alpha_rad
    alpha_deg = rad2deg(alpha_rad)
    beta_deg  = rad2deg(fc.beta_rad)
    mach      = fc.Mach_number
    config    = string(get(aircraft_data, :default_configuration, "clean"))
    max_elev_deg = aircraft_data.max_elevator_deflection_deg
    max_elev_rad = deg2rad(max_elev_deg)

    mode = lowercase(string(get(aircraft_data, :aerodynamic_model_mode, "table")))

    if mode == "linear"
        # ─── Linear-mode trim ───────────────────────────────────────────
        Cm_0       = hasproperty(aircraft_data, :Cm0)        ? Float64(aircraft_data.Cm0)        : 0.0
        Cm_alpha   = hasproperty(aircraft_data, :Cm_alpha)   ? Float64(aircraft_data.Cm_alpha)   : 0.0
        Cm_delta_e = hasproperty(aircraft_data, :Cm_delta_e) ? Float64(aircraft_data.Cm_delta_e) : -1.20

        # Pre-control pitching moment at initial α
        Cm_at_trim = Cm_0 + Cm_alpha * alpha_rad

        # Linear model uses textbook `elev_deg = -pitch_demand × max_elev_deg`,
        # so elev_rad = -pitch_demand × max_elev_rad.  Zero Cm:
        #   Cm_delta_e × (-pitch_demand_trim × max_elev_rad) + Cm_at_trim = 0
        #   pitch_demand_trim = Cm_at_trim / (Cm_delta_e × max_elev_rad)
        denom = Cm_delta_e * max_elev_rad
        if abs(denom) < 1e-12
            return 0.0
        end
        return clamp(Cm_at_trim / denom, -0.1, 0.1)
    end

    # ─── Table-mode trim ────────────────────────────────────────────────
    # Total Cm at the initial condition from the coefficient table.
    Cm_at_trim = _fetch_coefficient_with_default("Cm", 0.0;
        alpha=alpha_deg, alpha_deg=alpha_deg,
        beta=beta_deg, beta_deg=beta_deg,
        mach=mach, Mach=mach,
        config=config, configuration=config,
    )
    # Fall back to the scalar `Cm0` constant if there is no `Cm` table in
    # the aircraft YAML (legacy aircraft store it as a plain scalar).
    if Cm_at_trim == 0.0 && hasproperty(aircraft_data, :Cm0)
        Cm_at_trim = Float64(aircraft_data.Cm0) + Float64(get(aircraft_data, :Cm_alpha, 0.0)) * alpha_rad
    end

    # Fetch Cm_de (per degree).  Prefer the table; fall back to the legacy
    # scalar `aircraft_data.Cm_de`.  Table mode uses /deg units.
    Cm_de = _fetch_coefficient_with_default("Cm_de_per_deg", aircraft_data.Cm_de;
        alpha=alpha_deg, alpha_deg=alpha_deg,
        beta=beta_deg, beta_deg=beta_deg,
        mach=mach, Mach=mach,
        config=config, configuration=config,
    )
    if Cm_de == 0.0
        Cm_de = _fetch_coefficient_with_default("Cm_de", aircraft_data.Cm_de;
            alpha=alpha_deg, alpha_deg=alpha_deg,
            beta=beta_deg, beta_deg=beta_deg,
            mach=mach, Mach=mach,
            config=config, configuration=config,
        )
    end

    denom = Cm_de * max_elev_deg
    if abs(denom) < 1e-12
        return 0.0
    end
    # Tight clamp: auto-trim is a convenience, not a substitute for
    # pilot authority.  Max 10% of full stick travel.
    return clamp(Cm_at_trim / denom, -0.1, 0.1)
end

const MAX_SIMULATION_STEP_SECONDS = max(_max_simulation_step_config, 1e-4)
const MAX_RK4_SUBSTEP_SECONDS = clamp(_max_rk4_substep_config, 1e-4, MAX_SIMULATION_STEP_SECONDS)

function normalize_quaternion_in_state!(aircraft_state_vector::Vector{Float64})
    # Reject non-finite entries before normalising, otherwise a single NaN in
    # any quaternion slot would poison the entire norm and leave the aircraft
    # state unusable for the rest of the run.
    for i in 7:10
        if !isfinite(aircraft_state_vector[i])
            aircraft_state_vector[7]  = 0.0
            aircraft_state_vector[8]  = 0.0
            aircraft_state_vector[9]  = 0.0
            aircraft_state_vector[10] = 1.0
            return
        end
    end

    quaternion_norm = norm(@view aircraft_state_vector[7:10])

    if quaternion_norm > 1e-12
        aircraft_state_vector[7] /= quaternion_norm
        aircraft_state_vector[8] /= quaternion_norm
        aircraft_state_vector[9] /= quaternion_norm
        aircraft_state_vector[10] /= quaternion_norm
    else
        # Fallback to identity orientation if numerical drift collapses quaternion norm.
        aircraft_state_vector[7] = 0.0
        aircraft_state_vector[8] = 0.0
        aircraft_state_vector[9] = 0.0
        aircraft_state_vector[10] = 1.0
    end
end

"""
    sanitize_state_vector!(state_vector)

Replace any NaN/Inf entries in the state vector with finite fallbacks so a
single bad substep (e.g. a division by zero deep in the aero lookup) cannot
propagate NaNs for the remainder of the simulation.  Finite values are left
untouched — the aerodynamic model is responsible for keeping velocities,
rates, and attitudes within a physical envelope via drag and rate damping.
Altitude (index 2) is additionally clamped to the ISA76 domain so the
atmosphere lookup cannot throw even if something deeply wrong slipped past
the aero path.  The dynamic-stall sigma state is clamped to [0,1] because
it is a blend weight by definition.
"""
function sanitize_state_vector!(state_vector::Vector{Float64})
    _finite_or(v::Float64, fallback::Float64) = isfinite(v) ? v : fallback

    # Position — clamp altitude (index 2) to the ISA76 domain.
    state_vector[1] = _finite_or(state_vector[1], 0.0)
    state_vector[2] = clamp(_finite_or(state_vector[2], 0.0), -500.0, 84499.0)
    state_vector[3] = _finite_or(state_vector[3], 0.0)

    # Linear velocity — NaN/Inf guard only, no magnitude cap.
    state_vector[4] = _finite_or(state_vector[4], 0.0)
    state_vector[5] = _finite_or(state_vector[5], 0.0)
    state_vector[6] = _finite_or(state_vector[6], 0.0)

    # Quaternion slots sanitised by normalize_quaternion_in_state! below.

    # Body angular rates — NaN/Inf guard only.
    state_vector[11] = _finite_or(state_vector[11], 0.0)
    state_vector[12] = _finite_or(state_vector[12], 0.0)
    state_vector[13] = _finite_or(state_vector[13], 0.0)

    # Dynamic-stall internal states, if present.
    if length(state_vector) >= DYNAMIC_STALL_SIGMA_STATE_INDEX
        state_vector[DYNAMIC_STALL_ALPHA_LAG_STATE_INDEX] =
            _finite_or(state_vector[DYNAMIC_STALL_ALPHA_LAG_STATE_INDEX], 0.0)
        state_vector[DYNAMIC_STALL_SIGMA_STATE_INDEX] =
            clamp(_finite_or(state_vector[DYNAMIC_STALL_SIGMA_STATE_INDEX], 0.0), 0.0, 1.0)
    end
end

function Runge_Kutta_4_integrator(
    initial_aircraft_state_vector::Vector{Float64},    # Initial state vector containing position, velocity, orientation, and angular velocity
    control_demand_vector::NamedTuple,                 # Desired control inputs (pitch, roll, yaw, thrust)
    deltaTime::Float64,                                # Time step for integration
    aircraft_flight_physics_and_propulsive_data       # Aircraft physical properties and flight characteristics
)
    # Cap overall simulation jump to avoid unstable leaps after stalls/network hiccups.
    deltaTime = clamp(deltaTime, 0.0, MAX_SIMULATION_STEP_SECONDS)
    if deltaTime <= 0.0
        deltaTime = 1e-6
    end

    # ── Auto pitch trim ──
    # See the auto-pitch-trim helpers at the top of this file for the three
    # possible modes. `initial` and `continuous` both start by computing
    # the first-frame snap trim; `continuous` then integrates thereafter.
    #
    # IMPORTANT: when deltaTime > MAX_RK4_SUBSTEP_SECONDS, this function
    # calls itself recursively for each substep (see the substep loop
    # below). The recursive call receives `control_demand_vector` with
    # `.pitch_demand` already set to the trimmed value and `._trim_applied`
    # set to `true`. We must SKIP the trim block entirely in that case to
    # avoid double-integration of the trim bias and double-application of
    # the trim offset — both of which cause the bias to run away to the
    # configured trim clamp and inject uncommanded elevator deflection.
    _trim_already_applied = Bool(get(control_demand_vector, :_trim_applied, false))
    auto_pitch_trim_mode = _current_auto_pitch_trim_mode()
    auto_pitch_trim_rate = _current_auto_pitch_trim_rate_per_s()
    auto_pitch_trim_max_bias = _current_auto_pitch_trim_max_bias()
    auto_pitch_trim_blend = 0.0
    effective_auto_pitch_trim_bias = 0.0

    if _trim_already_applied
        pilot_pitch_demand = Float64(get(control_demand_vector, :_pilot_pitch_raw, control_demand_vector.pitch_demand))
        auto_pitch_trim_blend = _compute_auto_pitch_trim_blend(_auto_pitch_trim_bias, pilot_pitch_demand, auto_pitch_trim_mode)
        effective_auto_pitch_trim_bias = _auto_pitch_trim_bias * auto_pitch_trim_blend
    else
        pilot_pitch_demand = control_demand_vector.pitch_demand

        if auto_pitch_trim_mode != "off" && !_auto_pitch_trim_computed
            lock(_auto_pitch_trim_lock) do
                if !_auto_pitch_trim_computed
                    global _auto_pitch_trim_bias = _compute_auto_pitch_trim(
                        initial_aircraft_state_vector,
                        aircraft_flight_physics_and_propulsive_data
                    )
                    global _auto_pitch_trim_computed = true
                    @info "Auto pitch trim: mode=$(auto_pitch_trim_mode), initial bias = $(_auto_pitch_trim_bias), max_bias = $(auto_pitch_trim_max_bias)"
                end
            end
        end

        if auto_pitch_trim_mode == "continuous"
            if abs(pilot_pitch_demand) > AUTO_PITCH_TRIM_DEADBAND
                global _auto_pitch_trim_bias = clamp(
                    _auto_pitch_trim_bias + auto_pitch_trim_rate * pilot_pitch_demand * deltaTime,
                    -auto_pitch_trim_max_bias,
                     auto_pitch_trim_max_bias,
                )
            end
        end

        auto_pitch_trim_blend = _compute_auto_pitch_trim_blend(_auto_pitch_trim_bias, pilot_pitch_demand, auto_pitch_trim_mode)
        effective_auto_pitch_trim_bias = _auto_pitch_trim_bias * auto_pitch_trim_blend
        trimmed_pitch_demand = clamp(pilot_pitch_demand + effective_auto_pitch_trim_bias, -1.0, 1.0)
        control_demand_vector = merge(control_demand_vector, (
            pitch_demand=trimmed_pitch_demand,
            _trim_applied=true,
            _pilot_pitch_raw=pilot_pitch_demand,
        ))
    end

    # Split large time steps into smaller stable integrations.
    if deltaTime > MAX_RK4_SUBSTEP_SECONDS + 1e-12
        substep_count = ceil(Int, deltaTime / MAX_RK4_SUBSTEP_SECONDS)
        substep_deltaTime = deltaTime / substep_count

        current_state = copy(initial_aircraft_state_vector)
        normalize_quaternion_in_state!(current_state)
        has_dynamic_stall_states = length(initial_aircraft_state_vector) >= DYNAMIC_STALL_SIGMA_STATE_INDEX

        fx_demand = get(control_demand_vector, :fx, get(control_demand_vector, :x, 0.0))
        fy_demand = get(control_demand_vector, :fy, get(control_demand_vector, :y, 0.0))
        configuration_demand = string(get(control_demand_vector, :configuration, get(aircraft_flight_physics_and_propulsive_data, :default_configuration, "clean")))
        engine_count = Int(get(aircraft_flight_physics_and_propulsive_data, :engine_count, 1))
        engine_count = max(engine_count, 1)

        throttle_demand_vector = get(control_demand_vector, :throttle_demand_vector, fill(control_demand_vector.thrust_setting_demand, engine_count))
        throttle_attained_vector = get(control_demand_vector, :throttle_attained_vector, fill(control_demand_vector.thrust_attained, engine_count))

        current_control_demand_vector = (
            fx=fx_demand,
            fy=fy_demand,
            roll_demand=control_demand_vector.roll_demand,
            pitch_demand=control_demand_vector.pitch_demand,
            yaw_demand=control_demand_vector.yaw_demand,
            thrust_setting_demand=control_demand_vector.thrust_setting_demand,
            throttle_demand_vector=[Float64(v) for v in throttle_demand_vector],
            configuration=configuration_demand,
            roll_demand_attained=control_demand_vector.roll_demand_attained,
            pitch_demand_attained=control_demand_vector.pitch_demand_attained,
            yaw_demand_attained=control_demand_vector.yaw_demand_attained,
            thrust_attained=control_demand_vector.thrust_attained,
            throttle_attained_vector=[Float64(v) for v in throttle_attained_vector],
            _trim_applied=true,
            _pilot_pitch_raw=pilot_pitch_demand,
        )

        latest_result_dict = nothing

        for _ in 1:substep_count
            latest_result_dict = Runge_Kutta_4_integrator(
                current_state,
                current_control_demand_vector,
                substep_deltaTime,
                aircraft_flight_physics_and_propulsive_data
            )

            previous_dynamic_stall_alpha_lag_deg = has_dynamic_stall_states ? current_state[DYNAMIC_STALL_ALPHA_LAG_STATE_INDEX] : 0.0
            previous_dynamic_stall_sigma = has_dynamic_stall_states ? current_state[DYNAMIC_STALL_SIGMA_STATE_INDEX] : 0.0

            current_state = [
                latest_result_dict["x"],
                latest_result_dict["y"],
                latest_result_dict["z"],
                latest_result_dict["vx"],
                latest_result_dict["vy"],
                latest_result_dict["vz"],
                latest_result_dict["qx"],
                latest_result_dict["qy"],
                latest_result_dict["qz"],
                latest_result_dict["qw"],
                latest_result_dict["wx"],
                latest_result_dict["wy"],
                latest_result_dict["wz"]
            ]
            if has_dynamic_stall_states
                push!(current_state, get(latest_result_dict, "dynamic_stall_alpha_lag_deg_state", previous_dynamic_stall_alpha_lag_deg))
                push!(current_state, get(latest_result_dict, "dynamic_stall_sigma_state", previous_dynamic_stall_sigma))
            end
            sanitize_state_vector!(current_state)
            normalize_quaternion_in_state!(current_state)

            current_control_demand_vector = (
                fx=fx_demand,
                fy=fy_demand,
                roll_demand=control_demand_vector.roll_demand,
                pitch_demand=control_demand_vector.pitch_demand,
                yaw_demand=control_demand_vector.yaw_demand,
                thrust_setting_demand=control_demand_vector.thrust_setting_demand,
                throttle_demand_vector=collect(get(latest_result_dict, "throttle_demand_vector", throttle_demand_vector)),
                configuration=string(get(latest_result_dict, "configuration", configuration_demand)),
                roll_demand_attained=latest_result_dict["roll_demand_attained"],
                pitch_demand_attained=latest_result_dict["pitch_demand_attained"],
                yaw_demand_attained=latest_result_dict["yaw_demand_attained"],
                thrust_attained=latest_result_dict["thrust_attained"],
                throttle_attained_vector=collect(get(latest_result_dict, "throttle_attained_vector", throttle_attained_vector)),
                _trim_applied=true,
                _pilot_pitch_raw=pilot_pitch_demand,
            )
        end

        return latest_result_dict
    end

    working_aircraft_state_vector = copy(initial_aircraft_state_vector)
    sanitize_state_vector!(working_aircraft_state_vector)
    normalize_quaternion_in_state!(working_aircraft_state_vector)

    # Step 1: Process Control Inputs
    # Convert the demanded control values into physically attainable values
    # considering actuator dynamics and physical limitations
    control_demand_vector_attained = convert_control_demanded_to_attained(
        aircraft_flight_physics_and_propulsive_data,
        control_demand_vector,
        deltaTime
    )

    # Calculate initial flight conditions (alpha, beta, rotation rates)
    # from the current state vector
    initial_flight_conditions = compute_flight_conditions_from_state_vector(
        working_aircraft_state_vector,
        aircraft_flight_physics_and_propulsive_data
    )

    # Step 2: Runge-Kutta 4th Order Integration
    # Calculate four intermediate derivatives for RK4 integration

    # First derivative (k1) at initial state
    state_vec_derivative_1, global_force1, flight_data_for_telemetry1, component_forces1 = compute_6DOF_equations_of_motion(
        working_aircraft_state_vector,
        control_demand_vector_attained,
        aircraft_flight_physics_and_propulsive_data,
        initial_flight_conditions
    )

    # Second derivative (k2) at state + (dt/2)*k1
    state_vector_for_k2 = working_aircraft_state_vector .+ (deltaTime / 2) .* state_vec_derivative_1
    sanitize_state_vector!(state_vector_for_k2)
    normalize_quaternion_in_state!(state_vector_for_k2)
    flight_conditions_for_k2 = compute_flight_conditions_from_state_vector(
        state_vector_for_k2,
        aircraft_flight_physics_and_propulsive_data
    )
    state_vec_derivative_2, global_force2, flight_data_for_telemetry2, component_forces2 = compute_6DOF_equations_of_motion(
        state_vector_for_k2,
        control_demand_vector_attained,
        aircraft_flight_physics_and_propulsive_data,
        flight_conditions_for_k2
    )

    # Third derivative (k3) at state + (dt/2)*k2
    state_vector_for_k3 = working_aircraft_state_vector .+ (deltaTime / 2) .* state_vec_derivative_2
    sanitize_state_vector!(state_vector_for_k3)
    normalize_quaternion_in_state!(state_vector_for_k3)
    flight_conditions_for_k3 = compute_flight_conditions_from_state_vector(
        state_vector_for_k3,
        aircraft_flight_physics_and_propulsive_data
    )
    state_vec_derivative_3, global_force3, flight_data_for_telemetry3, component_forces3 = compute_6DOF_equations_of_motion(
        state_vector_for_k3,
        control_demand_vector_attained,
        aircraft_flight_physics_and_propulsive_data,
        flight_conditions_for_k3
    )

    # Fourth derivative (k4) at state + dt*k3
    state_vector_for_k4 = working_aircraft_state_vector .+ deltaTime .* state_vec_derivative_3
    sanitize_state_vector!(state_vector_for_k4)
    normalize_quaternion_in_state!(state_vector_for_k4)
    flight_conditions_for_k4 = compute_flight_conditions_from_state_vector(
        state_vector_for_k4,
        aircraft_flight_physics_and_propulsive_data
    )
    state_vec_derivative_4, global_force4, flight_data_for_telemetry4, component_forces4 = compute_6DOF_equations_of_motion(
        state_vector_for_k4,
        control_demand_vector_attained,
        aircraft_flight_physics_and_propulsive_data,
        flight_conditions_for_k4
    )

    # Step 3: Compute Final State
    # Combine all derivatives using RK4 formula: new_state = initial_state + (dt/6)*(k1 + 2k2 + 2k3 + k4)
    new_aircraft_state_vector = working_aircraft_state_vector .+ (deltaTime / 6.0) .*
                                                                 (state_vec_derivative_1 .+ 2 .* state_vec_derivative_2 .+ 2 .* state_vec_derivative_3 .+ state_vec_derivative_4)
    sanitize_state_vector!(new_aircraft_state_vector)
    normalize_quaternion_in_state!(new_aircraft_state_vector)

    # Step 4: Average Forces and data for telemetry
    # Calculate average force over the time step using all four RK4 stages
    total_aero_and_propulsive_force_resultant = (global_force1 .+ global_force2 .+ global_force3 .+ global_force4) ./ 4
    average_flight_data_for_telemetry = (flight_data_for_telemetry1 .+ flight_data_for_telemetry2 .+ flight_data_for_telemetry3 .+ flight_data_for_telemetry4) ./ 4
    wing_force_vector_global_avg = (
        component_forces1.wing_force_vector_global_N .+
        component_forces2.wing_force_vector_global_N .+
        component_forces3.wing_force_vector_global_N .+
        component_forces4.wing_force_vector_global_N
    ) ./ 4
    tail_force_vector_global_avg = (
        component_forces1.tail_force_vector_global_N .+
        component_forces2.tail_force_vector_global_N .+
        component_forces3.tail_force_vector_global_N .+
        component_forces4.tail_force_vector_global_N
    ) ./ 4
    tail_lift_vector_global_avg = (
        component_forces1.tail_lift_vector_global_N .+
        component_forces2.tail_lift_vector_global_N .+
        component_forces3.tail_lift_vector_global_N .+
        component_forces4.tail_lift_vector_global_N
    ) ./ 4
    wing_force_origin_global_avg = (
        component_forces1.wing_force_origin_global .+
        component_forces2.wing_force_origin_global .+
        component_forces3.wing_force_origin_global .+
        component_forces4.wing_force_origin_global
    ) ./ 4
    tail_force_origin_global_avg = (
        component_forces1.tail_force_origin_global .+
        component_forces2.tail_force_origin_global .+
        component_forces3.tail_force_origin_global .+
        component_forces4.tail_force_origin_global
    ) ./ 4
    wing_lift_vector_global_avg = (
        component_forces1.wing_lift_vector_global_N .+
        component_forces2.wing_lift_vector_global_N .+
        component_forces3.wing_lift_vector_global_N .+
        component_forces4.wing_lift_vector_global_N
    ) ./ 4
    horizontal_tail_lift_vector_global_avg = (
        component_forces1.horizontal_tail_lift_vector_global_N .+
        component_forces2.horizontal_tail_lift_vector_global_N .+
        component_forces3.horizontal_tail_lift_vector_global_N .+
        component_forces4.horizontal_tail_lift_vector_global_N
    ) ./ 4
    vertical_tail_lift_vector_global_avg = (
        component_forces1.vertical_tail_lift_vector_global_N .+
        component_forces2.vertical_tail_lift_vector_global_N .+
        component_forces3.vertical_tail_lift_vector_global_N .+
        component_forces4.vertical_tail_lift_vector_global_N
    ) ./ 4
    horizontal_tail_force_vector_global_avg = (
        component_forces1.horizontal_tail_force_vector_global_N .+
        component_forces2.horizontal_tail_force_vector_global_N .+
        component_forces3.horizontal_tail_force_vector_global_N .+
        component_forces4.horizontal_tail_force_vector_global_N
    ) ./ 4
    vertical_tail_force_vector_global_avg = (
        component_forces1.vertical_tail_force_vector_global_N .+
        component_forces2.vertical_tail_force_vector_global_N .+
        component_forces3.vertical_tail_force_vector_global_N .+
        component_forces4.vertical_tail_force_vector_global_N
    ) ./ 4
    horizontal_tail_local_velocity_global_avg = (
        component_forces1.horizontal_tail_local_velocity_global .+
        component_forces2.horizontal_tail_local_velocity_global .+
        component_forces3.horizontal_tail_local_velocity_global .+
        component_forces4.horizontal_tail_local_velocity_global
    ) ./ 4
    vertical_tail_local_velocity_global_avg = (
        component_forces1.vertical_tail_local_velocity_global .+
        component_forces2.vertical_tail_local_velocity_global .+
        component_forces3.vertical_tail_local_velocity_global .+
        component_forces4.vertical_tail_local_velocity_global
    ) ./ 4
    weight_force_vector_global_avg = (
        component_forces1.weight_force_vector_global_N .+
        component_forces2.weight_force_vector_global_N .+
        component_forces3.weight_force_vector_global_N .+
        component_forces4.weight_force_vector_global_N
    ) ./ 4
    wing_lift_origin_global_avg = (
        component_forces1.wing_lift_origin_global .+
        component_forces2.wing_lift_origin_global .+
        component_forces3.wing_lift_origin_global .+
        component_forces4.wing_lift_origin_global
    ) ./ 4
    horizontal_tail_lift_origin_global_avg = (
        component_forces1.horizontal_tail_lift_origin_global .+
        component_forces2.horizontal_tail_lift_origin_global .+
        component_forces3.horizontal_tail_lift_origin_global .+
        component_forces4.horizontal_tail_lift_origin_global
    ) ./ 4
    vertical_tail_lift_origin_global_avg = (
        component_forces1.vertical_tail_lift_origin_global .+
        component_forces2.vertical_tail_lift_origin_global .+
        component_forces3.vertical_tail_lift_origin_global .+
        component_forces4.vertical_tail_lift_origin_global
    ) ./ 4
    weight_force_origin_global_avg = (
        component_forces1.weight_force_origin_global .+
        component_forces2.weight_force_origin_global .+
        component_forces3.weight_force_origin_global .+
        component_forces4.weight_force_origin_global
    ) ./ 4

    # Body offsets (These are structurally constant but averaged for consistency)
    wing_offset_body_avg = (
        component_forces1.wing_offset_body .+
        component_forces2.wing_offset_body .+
        component_forces3.wing_offset_body .+
        component_forces4.wing_offset_body
    ) ./ 4
    htail_offset_body_avg = (
        component_forces1.htail_offset_body .+
        component_forces2.htail_offset_body .+
        component_forces3.htail_offset_body .+
        component_forces4.htail_offset_body
    ) ./ 4
    vtail_offset_body_avg = (
        component_forces1.vtail_offset_body .+
        component_forces2.vtail_offset_body .+
        component_forces3.vtail_offset_body .+
        component_forces4.vtail_offset_body
    ) ./ 4


    # Step 5: Handle Ground Interactions
    # Check for collisions and adjust vertical velocity if necessary
    vertical_speed_post_collision_check = handle_collisions(new_aircraft_state_vector[2], new_aircraft_state_vector[5])
    final_flight_conditions = compute_flight_conditions_from_state_vector(
        new_aircraft_state_vector,
        aircraft_flight_physics_and_propulsive_data
    )

    # Step 6: Package Results
    # Return a dictionary containing all updated state variables and flight information
    result_dict = Dict(
        # Position components (x, y, z)
        "x" => new_aircraft_state_vector[1],
        "y" => new_aircraft_state_vector[2],
        "z" => new_aircraft_state_vector[3],

        # Velocity components (vx, vy, vz)
        "vx" => new_aircraft_state_vector[4],
        "vy" => vertical_speed_post_collision_check,
        "vz" => new_aircraft_state_vector[6],

        # Angular velocities (wx, wy, wz)
        "wx" => new_aircraft_state_vector[11],
        "wy" => new_aircraft_state_vector[12],
        "wz" => new_aircraft_state_vector[13],

        # Quaternion orientation (qx, qy, qz, qw)
        "qx" => new_aircraft_state_vector[7],
        "qy" => new_aircraft_state_vector[8],
        "qz" => new_aircraft_state_vector[9],
        "qw" => new_aircraft_state_vector[10],

        # Global forces
        "fx_global" => total_aero_and_propulsive_force_resultant[1],
        "fy_global" => total_aero_and_propulsive_force_resultant[2],
        "fz_global" => total_aero_and_propulsive_force_resultant[3],
        "fx_wing_global" => wing_force_vector_global_avg[1],
        "fy_wing_global" => wing_force_vector_global_avg[2],
        "fz_wing_global" => wing_force_vector_global_avg[3],
        "fx_tail_global" => tail_force_vector_global_avg[1],
        "fy_tail_global" => tail_force_vector_global_avg[2],
        "fz_tail_global" => tail_force_vector_global_avg[3],
        "fx_tail_lift_global" => tail_lift_vector_global_avg[1],
        "fy_tail_lift_global" => tail_lift_vector_global_avg[2],
        "fz_tail_lift_global" => tail_lift_vector_global_avg[3],
        "x_wing_force_origin_global" => wing_force_origin_global_avg[1],
        "y_wing_force_origin_global" => wing_force_origin_global_avg[2],
        "z_wing_force_origin_global" => wing_force_origin_global_avg[3],
        "x_tail_force_origin_global" => tail_force_origin_global_avg[1],
        "y_tail_force_origin_global" => tail_force_origin_global_avg[2],
        "z_tail_force_origin_global" => tail_force_origin_global_avg[3],
        "fx_wing_lift_global" => wing_lift_vector_global_avg[1],
        "fy_wing_lift_global" => wing_lift_vector_global_avg[2],
        "fz_wing_lift_global" => wing_lift_vector_global_avg[3],
        "fx_htail_lift_global" => horizontal_tail_lift_vector_global_avg[1],
        "fy_htail_lift_global" => horizontal_tail_lift_vector_global_avg[2],
        "fz_htail_lift_global" => horizontal_tail_lift_vector_global_avg[3],
        "fx_vtail_lift_global" => vertical_tail_lift_vector_global_avg[1],
        "fy_vtail_lift_global" => vertical_tail_lift_vector_global_avg[2],
        "fz_vtail_lift_global" => vertical_tail_lift_vector_global_avg[3],
        "fx_htail_force_global" => horizontal_tail_force_vector_global_avg[1],
        "fy_htail_force_global" => horizontal_tail_force_vector_global_avg[2],
        "fz_htail_force_global" => horizontal_tail_force_vector_global_avg[3],
        "fx_vtail_force_global" => vertical_tail_force_vector_global_avg[1],
        "fy_vtail_force_global" => vertical_tail_force_vector_global_avg[2],
        "fz_vtail_force_global" => vertical_tail_force_vector_global_avg[3],
        "vx_htail_local_flow_global" => horizontal_tail_local_velocity_global_avg[1],
        "vy_htail_local_flow_global" => horizontal_tail_local_velocity_global_avg[2],
        "vz_htail_local_flow_global" => horizontal_tail_local_velocity_global_avg[3],
        "vx_vtail_local_flow_global" => vertical_tail_local_velocity_global_avg[1],
        "vy_vtail_local_flow_global" => vertical_tail_local_velocity_global_avg[2],
        "vz_vtail_local_flow_global" => vertical_tail_local_velocity_global_avg[3],
        "fx_weight_global" => weight_force_vector_global_avg[1],
        "fy_weight_global" => weight_force_vector_global_avg[2],
        "fz_weight_global" => weight_force_vector_global_avg[3],
        "x_wing_lift_origin_global" => wing_lift_origin_global_avg[1],
        "y_wing_lift_origin_global" => wing_lift_origin_global_avg[2],
        "z_wing_lift_origin_global" => wing_lift_origin_global_avg[3],
        "x_htail_lift_origin_global" => horizontal_tail_lift_origin_global_avg[1],
        "y_htail_lift_origin_global" => horizontal_tail_lift_origin_global_avg[2],
        "z_htail_lift_origin_global" => horizontal_tail_lift_origin_global_avg[3],
        "x_vtail_lift_origin_global" => vertical_tail_lift_origin_global_avg[1],
        "y_vtail_lift_origin_global" => vertical_tail_lift_origin_global_avg[2],
        "z_vtail_lift_origin_global" => vertical_tail_lift_origin_global_avg[3],
        "x_weight_origin_global" => weight_force_origin_global_avg[1],
        "z_weight_origin_global" => weight_force_origin_global_avg[3],

        # Body offsets
        "x_wing_offset_body" => wing_offset_body_avg[1],
        "y_wing_offset_body" => wing_offset_body_avg[2],
        "z_wing_offset_body" => wing_offset_body_avg[3],
        "x_htail_offset_body" => htail_offset_body_avg[1],
        "y_htail_offset_body" => htail_offset_body_avg[2],
        "z_htail_offset_body" => htail_offset_body_avg[3],
        "x_vtail_offset_body" => vtail_offset_body_avg[1],
        "y_vtail_offset_body" => vtail_offset_body_avg[2],
        "z_vtail_offset_body" => vtail_offset_body_avg[3], "scale_tail_forces" => aircraft_flight_physics_and_propulsive_data.scale_tail_forces,

        # Aerodynamic angles
        "alpha_RAD" => final_flight_conditions.alpha_rad,
        "beta_RAD" => final_flight_conditions.beta_rad,

        # Hard-clamped α and β to stall bounds, used by the live-state
        # overlay in aero_model_viewer.html to pin the "current state" dot
        # on the saturation maps. A simple clamp is a close enough proxy
        # for the soft-saturate curve outside the ±knee region, and lives
        # right on the curve inside the linear envelope.
        "alpha_sat_deg" => clamp(
            rad2deg(final_flight_conditions.alpha_rad),
            Float64(get(aircraft_flight_physics_and_propulsive_data, :alpha_stall_negative, -15.0)),
            Float64(get(aircraft_flight_physics_and_propulsive_data, :alpha_stall_positive,  15.0)),
        ),
        "beta_sat_deg" => clamp(
            rad2deg(final_flight_conditions.beta_rad),
            -abs(Float64(get(aircraft_flight_physics_and_propulsive_data, :beta_stall, 20.0))),
             abs(Float64(get(aircraft_flight_physics_and_propulsive_data, :beta_stall, 20.0))),
        ),

        # Body frame rotation rates
        "p_roll_rate" => final_flight_conditions.p_roll_rate,
        "r_yaw_rate" => final_flight_conditions.r_yaw_rate,
        "q_pitch_rate" => final_flight_conditions.q_pitch_rate,

        # Control demands and attained values
        "pitch_demand" => pilot_pitch_demand,
        "roll_demand" => control_demand_vector.roll_demand,
        "yaw_demand" => control_demand_vector.yaw_demand,
        "thrust_setting_demand" => control_demand_vector_attained.thrust_setting_demand,
        "pitch_demand_attained" => control_demand_vector_attained.pitch_demand_attained,
        "roll_demand_attained" => control_demand_vector_attained.roll_demand_attained,
        "yaw_demand_attained" => control_demand_vector_attained.yaw_demand_attained,
        "thrust_attained" => control_demand_vector_attained.thrust_attained,

        # Auto pitch trim diagnostic telemetry
        # -------------------------------------------------------------
        # auto_pitch_trim_bias           — normalised stick bias (-1..1),
        #                                  computed once on the first frame
        #                                  to zero Cm at the initial condition.
        # elevator_deg_from_trim         — elevator deflection (degrees)
        #                                  contributed by the auto trim alone.
        # elevator_deg_attained          — total attained elevator (degrees)
        #                                  after pilot + trim + actuator lag.
        # The sign convention matches the aero model: stick back
        # (pitch_demand > 0) produces a NEGATIVE elevator_deg (trailing
        # edge up) which gives a nose-up pitching moment.
        "auto_pitch_trim_bias" => _auto_pitch_trim_bias,
        "auto_pitch_trim_bias_applied" => effective_auto_pitch_trim_bias,
        "auto_pitch_trim_command_blend" => auto_pitch_trim_blend,
        "auto_pitch_trim_mode" => _current_auto_pitch_trim_mode(),
        "auto_pitch_trim_rate" => _current_auto_pitch_trim_rate_per_s(),
        "auto_pitch_trim_max_bias" => _current_auto_pitch_trim_max_bias(),
        "elevator_deg_from_trim" => -effective_auto_pitch_trim_bias *
            aircraft_flight_physics_and_propulsive_data.max_elevator_deflection_deg,
        "elevator_deg_attained" => -control_demand_vector_attained.pitch_demand_attained *
            aircraft_flight_physics_and_propulsive_data.max_elevator_deflection_deg,
        "max_elevator_deflection_deg" =>
            aircraft_flight_physics_and_propulsive_data.max_elevator_deflection_deg,
        "max_aileron_deflection_deg" =>
            aircraft_flight_physics_and_propulsive_data.max_aileron_deflection_deg,
        "max_rudder_deflection_deg" =>
            aircraft_flight_physics_and_propulsive_data.max_rudder_deflection_deg,
        "configuration" => string(get(control_demand_vector_attained, :configuration, get(control_demand_vector, :configuration, get(aircraft_flight_physics_and_propulsive_data, :default_configuration, "clean")))),
        "aerodynamic_model_mode" => string(get(aircraft_flight_physics_and_propulsive_data, :aerodynamic_model_mode, "table")),
        "throttle_demand_vector" => collect(get(control_demand_vector_attained, :throttle_demand_vector, Float64[])),
        "throttle_attained_vector" => collect(get(control_demand_vector_attained, :throttle_attained_vector, Float64[])),

        # Additional flight data for telemetry

        "CL" => average_flight_data_for_telemetry[1],
        "CD" => average_flight_data_for_telemetry[2],
        "CL/CD" => average_flight_data_for_telemetry[3],
        "CS" => average_flight_data_for_telemetry[4], "nx" => average_flight_data_for_telemetry[5],
        "nz" => average_flight_data_for_telemetry[6],
        "ny" => average_flight_data_for_telemetry[7], "CM_roll_from_aero_forces" => average_flight_data_for_telemetry[8],
        "CM_yaw_from_aero_forces" => average_flight_data_for_telemetry[9],
        "CM_pitch_from_aero_forces" => average_flight_data_for_telemetry[10], "CM_roll_from_control" => average_flight_data_for_telemetry[11],
        "CM_yaw_from_control" => average_flight_data_for_telemetry[12],
        "CM_pitch_from_control" => average_flight_data_for_telemetry[13], "CM_roll_from_aero_stiffness" => average_flight_data_for_telemetry[14],
        "CM_yaw_from_aero_stiffness" => average_flight_data_for_telemetry[15],
        "CM_pitch_from_aero_stiffness" => average_flight_data_for_telemetry[16], "CM_roll_from_aero_damping" => average_flight_data_for_telemetry[17],
        "CM_yaw_from_aero_damping" => average_flight_data_for_telemetry[18],
        "CM_pitch_from_aero_damping" => average_flight_data_for_telemetry[19], "q_pitch_rate" => average_flight_data_for_telemetry[20],
        "p_roll_rate" => average_flight_data_for_telemetry[21],
        "r_yaw_rate" => average_flight_data_for_telemetry[22], "TAS" => average_flight_data_for_telemetry[23],
        "EAS" => average_flight_data_for_telemetry[24],
        "Mach" => average_flight_data_for_telemetry[25],
        "dynamic_pressure" => average_flight_data_for_telemetry[26]
    )

    if length(new_aircraft_state_vector) >= DYNAMIC_STALL_SIGMA_STATE_INDEX
        result_dict["dynamic_stall_alpha_lag_deg_state"] =
            new_aircraft_state_vector[DYNAMIC_STALL_ALPHA_LAG_STATE_INDEX]
        result_dict["dynamic_stall_sigma_state"] =
            clamp(new_aircraft_state_vector[DYNAMIC_STALL_SIGMA_STATE_INDEX], 0.0, 1.0)
    end

    return result_dict

end
