function compute_flight_conditions_from_state_vector(initial_aircraft_state_vector, aircraft_data)

    # Defensive sanitation: replace any NaN/Inf that has propagated through the
    # integrator with finite fallbacks so a single bad substep cannot destroy
    # the entire simulation.  No magnitude clamping is applied to velocities
    # or rates — the aerodynamic model is responsible for keeping the state
    # within a physical envelope via quadratic drag and rate damping.
    _finite_or(v, fallback::Float64) = isfinite(v) ? Float64(v) : fallback

    # === 1) UNPACK THE AIRCRAFT STATE ===
    # Note: The order (lat, alt, lon) is inherited from babylon.js or other external constraints.
    latitude  = _finite_or(initial_aircraft_state_vector[1], 0.0)
    altitude  = clamp(
        _finite_or(initial_aircraft_state_vector[2], 0.0),
        -500.0,
        84499.0,
    )
    longitude = _finite_or(initial_aircraft_state_vector[3], 0.0)

    T, p, rho, speed_of_sound, density_ratio = atmosphere_isa(altitude)

    vx = _finite_or(initial_aircraft_state_vector[4], 0.0)
    vy = _finite_or(initial_aircraft_state_vector[5], 0.0)
    vz = _finite_or(initial_aircraft_state_vector[6], 0.0)

    # Quaternion: [qx, qy, qz, qw]
    qx = _finite_or(initial_aircraft_state_vector[7],  0.0)
    qy = _finite_or(initial_aircraft_state_vector[8],  0.0)
    qz = _finite_or(initial_aircraft_state_vector[9],  0.0)
    qw = _finite_or(initial_aircraft_state_vector[10], 1.0)

    # Body angular rates: p, r, q (roll, yaw, pitch rates)
    p_roll_rate  = _finite_or(initial_aircraft_state_vector[11], 0.0)
    r_yaw_rate   = _finite_or(initial_aircraft_state_vector[12], 0.0)
    q_pitch_rate = _finite_or(initial_aircraft_state_vector[13], 0.0)

    # Normalize the orientation quaternion to avoid numerical drift
    global_orientation_quaternion = quat_normalize([qw, qx, qy, qz])

    # Body angular velocity vector
    omega_body = SVector(p_roll_rate, r_yaw_rate, q_pitch_rate)

    # Angular velocity as a quaternion
    omega_body_quaternion = [0.0, p_roll_rate, r_yaw_rate, q_pitch_rate]

    # Quaternion derivative 
    # q_dot = 0.5 * (global_orientation_quaternion ⨂ ω_body)
    q_dot = 0.5 * quat_multiply(global_orientation_quaternion, omega_body_quaternion)

    # === 2) FORCES & LINEAR ACCELERATIONS ===

    # Global velocity vector
    v_global = SVector(vx, vy, vz)

    # Velocity in the body frame
    v_body = rotate_vector_global_to_body(v_global, global_orientation_quaternion)
    v_body_magnitude = norm(v_body) + 1e-6  # Avoid division by zero

    # Dynamic pressure
    dynamic_pressure = .5 * v_body_magnitude ^2 * rho

    # Mach number
    Mach_number = v_body_magnitude / speed_of_sound

    # Angles of attack (alpha) and sideslip (beta) in radians.
    #
    # Sim body axes are [x_fwd, y_up, z_left].  Standard flight-dynamics body
    # axes are [x_fwd, y_right, z_down], so:
    #     u_std = +v_body[1]
    #     v_std = -v_body[3]   (right = -left)
    #     w_std = -v_body[2]   (down  = -up)
    #
    # α = atan2(w_std, u_std), clamped to [-π/2, π/2] so we never try to look
    # up aero coefficients for "tail-first" flight — the tables are only
    # physically meaningful for forward flight.  β = asin(v_std / |V|), which
    # correctly stays in [-π/2, π/2] even when u_std is near zero (vertical
    # flight), unlike the old atan2(v_std, u_std) approximation that was
    # producing β values of ±180° and driving the whole state machine insane.
    u_std =  v_body[1]
    v_std = -v_body[3]
    w_std = -v_body[2]

    # Full-envelope models are generated over [-180°, 180°]. Use signed
    # pitch-plane and yaw-plane angles so tail-first and broadside attitudes
    # reach those table regions instead of being folded into ±90°.
    alpha_rad = atan(w_std, u_std)
    beta_rad = atan(v_std, u_std)

    aircraft_mass = aircraft_data.aircraft_mass  # this and the inertia could change due to fuel burn

    # The inertia tensor is stored in standard aero axes [x_fwd, y_right, z_down].
    # The simulator body frame is [x_fwd, y_up, z_left] with omega = [p, r, q].
    # Convert via I_sim = R * I_std * R' where R maps y→-z, z→-y.
    I_std = aircraft_data.I_body
    I_body = [
         I_std[1,1]  -I_std[1,3]  -I_std[1,2];
        -I_std[1,3]   I_std[3,3]   I_std[2,3];
        -I_std[1,2]   I_std[2,3]   I_std[2,2]
    ]

    # Pre-compute the inverse of the inertia tensor matrix
    I_body_inverse = inv(I_body)

    return ( # named tuple with current flight conditions derived from the state vector
        # Unpacked variables
        latitude  = latitude,
        altitude  = altitude,
        longitude = longitude,
        
        vx = vx,
        vy = vy,
        vz = vz,

        TAS = v_body_magnitude, 
        EAS = v_body_magnitude * sqrt(density_ratio),

        qx = qx,
        qy = qy,
        qz = qz,
        qw = qw,

        p_roll_rate  = p_roll_rate,
        r_yaw_rate   = r_yaw_rate,
        q_pitch_rate = q_pitch_rate,

        # Derived variables
        global_orientation_quaternion = global_orientation_quaternion,
        v_global            = v_global,
        v_body              = v_body,
        v_body_magnitude    = v_body_magnitude,
        air_density         = rho,
        dynamic_pressure    = dynamic_pressure,
        Mach_number         = Mach_number,
        alpha_rad           = alpha_rad,
        beta_rad            = beta_rad,
    
        omega_body = omega_body, 

        # Angular velocity as a quaternion
        omega_body_quaternion = omega_body_quaternion,
    
        # Quaternion derivative 
        # q_dot = 0.5 * (global_orientation_quaternion ⨂ ω_body)
        q_dot = q_dot,

        aircraft_mass = aircraft_mass,  # this and the inertia could change due to fuel burn

        I_body = I_body,
        # Pre-compute the inverse of the inertia tensor matrix
        I_body_inverse = I_body_inverse     # pre-compute 3×3 inverse inertia tensor matrix to save time in RK4 evaluations
    )
end
