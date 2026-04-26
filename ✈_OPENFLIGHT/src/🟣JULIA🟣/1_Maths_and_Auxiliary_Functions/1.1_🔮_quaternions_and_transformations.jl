############## Quaternion Algebra ##############
# Quaternion multiplication
function quat_multiply(q1::Vector{Float64}, q2::Vector{Float64})
    w1, x1, y1, z1 = q1
    w2, x2, y2, z2 = q2

    w = w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2
    x = w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2
    y = w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2
    z = w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2

    return [w, x, y, z]
end

# Quaternion conjugate (inverse for unit quaternions)
function quat_conjugate(q::Vector{Float64})
    w, x, y, z = q
    return [w, -x, -y, -z]
end

# Normalize a quaternion
function quat_normalize(q::Vector{Float64})
    norm_q = norm(q)
    return q / norm_q
end

function rotate_vector_by_quaternion(vec, quat)
    # Ensure the quaternion is normalized
    quat = quat_normalize(quat)

    # Extract scalar and vector parts
    qw = quat[1]
    qv = quat[2:4]

    # Compute the rotated vector
    t = 2.0 * cross(qv, vec)
    rotated_vec = vec + qw * t + cross(qv, t)
    return rotated_vec
end

# Rotation functions without axis inversions
function rotate_vector_body_to_global(vec_body, quaternion)
    vec_global = rotate_vector_by_quaternion(vec_body, quaternion)
    return vec_global
end

function rotate_vector_global_to_body(vec_global, quaternion)
    vec_body = rotate_vector_by_quaternion(vec_global, quat_conjugate(quaternion))
    return vec_body
end

const AERO_FORCE_BASIS_EPS = 1.0e-10

function _unit_or_fallback(vec::Vector{Float64}, fallback::Vector{Float64})
    vec_norm = norm(vec)
    if isfinite(vec_norm) && vec_norm > AERO_FORCE_BASIS_EPS
        return vec ./ vec_norm
    end

    fallback_norm = norm(fallback)
    if isfinite(fallback_norm) && fallback_norm > AERO_FORCE_BASIS_EPS
        return fallback ./ fallback_norm
    end

    return [1.0, 0.0, 0.0]
end

function _flow_unit_vector_from_alpha_beta(alpha_RAD, beta_RAD)
    sin_alpha = sin(alpha_RAD)
    cos_alpha = cos(alpha_RAD)
    sin_beta = sin(beta_RAD)
    cos_beta = cos(beta_RAD)

    # The simulator defines alpha = atan2(w, u) and beta = atan2(v, u) in
    # standard aero body axes [x_forward, y_right, z_down]. Because both
    # angles carry the same u-quadrant, tail-first flow must keep u < 0.
    # Reconstruct [u, v, w] from the tangent relations v/u = tan(beta) and
    # w/u = tan(alpha), choosing the u sign from the angle whose cosine is
    # furthest from zero. This avoids the common but wrong cos(alpha)*cos(beta)
    # product, which flips u positive again when both angles are near 180 deg.
    u_sign_source = abs(cos_alpha) >= abs(cos_beta) ? cos_alpha : cos_beta
    u_sign = abs(u_sign_source) > AERO_FORCE_BASIS_EPS ? sign(u_sign_source) : 1.0
    u_component = u_sign
    v_component = abs(cos_beta) > AERO_FORCE_BASIS_EPS ?
                  u_component * sin_beta / cos_beta :
                  sign(sin_beta == 0.0 ? 1.0 : sin_beta) / AERO_FORCE_BASIS_EPS
    w_component = abs(cos_alpha) > AERO_FORCE_BASIS_EPS ?
                  u_component * sin_alpha / cos_alpha :
                  sign(sin_alpha == 0.0 ? 1.0 : sin_alpha) / AERO_FORCE_BASIS_EPS
    flow = [u_component, v_component, w_component]

    fallback = [
        u_sign,
        sin_beta == 0.0 ? 0.0 : sign(sin_beta),
        sin_alpha == 0.0 ? 0.0 : sign(sin_alpha),
    ]
    return _unit_or_fallback(flow, fallback)
end

function _projected_unit_axis(reference_axis::Vector{Float64},
                              normal_axis::Vector{Float64},
                              fallback_axis::Vector{Float64})
    projected = reference_axis .- dot(reference_axis, normal_axis) .* normal_axis
    fallback_projected = fallback_axis .- dot(fallback_axis, normal_axis) .* normal_axis
    return _unit_or_fallback(projected, fallback_projected)
end

function transform_aerodynamic_forces_from_wind_to_body_frame(D, Y, L, alpha_RAD, beta_RAD)
    # Build the wind-force basis directly from the simulator's alpha/beta
    # definitions. Drag is exactly opposite the relative wind; side force and
    # lift are perpendicular to it. Therefore, with positive drag, the aero
    # force cannot add translational kinetic energy through the transform.
    flow_axis = _flow_unit_vector_from_alpha_beta(alpha_RAD, beta_RAD)

    body_right_axis = [0.0, 1.0, 0.0]
    body_up_axis = [0.0, 0.0, -1.0]

    side_axis = _projected_unit_axis(
        body_right_axis,
        flow_axis,
        cross(flow_axis, body_up_axis)
    )
    lift_axis = _unit_or_fallback(
        cross(side_axis, flow_axis),
        _projected_unit_axis(body_up_axis, flow_axis, [1.0, 0.0, 0.0])
    )

    F_body = (-D .* flow_axis) .+ (Y .* side_axis) .+ (L .* lift_axis)

    Fxb, Fyb, Fzb = F_body
    return Fxb, Fyb, Fzb
end
