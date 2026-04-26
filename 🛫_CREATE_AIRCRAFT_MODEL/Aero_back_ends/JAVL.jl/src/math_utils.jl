# ──────────────────────────────────────────────────────────────
# math_utils.jl — Linear algebra and geometric helpers
# ──────────────────────────────────────────────────────────────

"""Cross product of two 3-vectors stored as tuples or SVectors."""
@inline function cross3(a, b)
    (a[2]*b[3] - a[3]*b[2],
     a[3]*b[1] - a[1]*b[3],
     a[1]*b[2] - a[2]*b[1])
end

@inline function dot3(a, b)
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
end

@inline norm3(a) = sqrt(a[1]^2 + a[2]^2 + a[3]^2)

@inline function normalize3(a)
    n = norm3(a)
    n < 1e-30 && return (0.0, 0.0, 0.0)
    (a[1]/n, a[2]/n, a[3]/n)
end

"""Invert a 3×3 matrix. Returns zeros for singular rows (mass=∞)."""
function inv3x3(A::Matrix{Float64})
    det = A[1,1]*(A[2,2]*A[3,3]-A[2,3]*A[3,2]) -
          A[1,2]*(A[2,1]*A[3,3]-A[2,3]*A[3,1]) +
          A[1,3]*(A[2,1]*A[3,2]-A[2,2]*A[3,1])
    if abs(det) < 1e-30
        return zeros(3,3)
    end
    Ainv = zeros(3,3)
    Ainv[1,1] =  (A[2,2]*A[3,3]-A[2,3]*A[3,2]) / det
    Ainv[1,2] = -(A[1,2]*A[3,3]-A[1,3]*A[3,2]) / det
    Ainv[1,3] =  (A[1,2]*A[2,3]-A[1,3]*A[2,2]) / det
    Ainv[2,1] = -(A[2,1]*A[3,3]-A[2,3]*A[3,1]) / det
    Ainv[2,2] =  (A[1,1]*A[3,3]-A[1,3]*A[3,1]) / det
    Ainv[2,3] = -(A[1,1]*A[2,3]-A[1,3]*A[2,1]) / det
    Ainv[3,1] =  (A[2,1]*A[3,2]-A[2,2]*A[3,1]) / det
    Ainv[3,2] = -(A[1,1]*A[3,2]-A[1,2]*A[3,1]) / det
    Ainv[3,3] =  (A[1,1]*A[2,2]-A[1,2]*A[2,1]) / det
    return Ainv
end

"""
    rotation_matrix_321(phi, theta, psi)

3-2-1 Euler rotation matrix (yaw-pitch-roll).
Maps body-frame vector to inertial frame: x_inertial = T * x_body
"""
function rotation_matrix_321(phi, theta, psi)
    cphi = cos(phi);  sphi = sin(phi)
    cthe = cos(theta); sthe = sin(theta)
    cpsi = cos(psi);  spsi = sin(psi)
    T = zeros(3,3)
    T[1,1] =  cthe*cpsi
    T[1,2] =  sphi*sthe*cpsi - cphi*spsi
    T[1,3] =  cphi*sthe*cpsi + sphi*spsi
    T[2,1] =  cthe*spsi
    T[2,2] =  sphi*sthe*spsi + cphi*cpsi
    T[2,3] =  cphi*sthe*spsi - sphi*cpsi
    T[3,1] = -sthe
    T[3,2] =  sphi*cthe
    T[3,3] =  cphi*cthe
    return T
end
