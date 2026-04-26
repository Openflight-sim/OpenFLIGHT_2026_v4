"""
    component_split.jl — Wing+Body vs. Tail decomposition helpers

Shared utilities used by every backend (VLM, JAVL, DATCOM) and the
envelope/merge stages to group lifting surfaces into two buckets:

    :wing_body  → main wing + fuselage panels
    :tail_h     → horizontal stabilizer(s) / canard
    :tail_v     → vertical stabilizer(s) / ventral fins

Also provides:
  - tail aerodynamic-center reference points (for r×F moment transfer)
  - moment translation between reference points
  - role-weighted coefficient accumulation
"""

const TAIL_H_ROLES = ("horizontal_stabilizer", "canard", "h_tail", "stab")
const TAIL_V_ROLES = ("vertical_stabilizer", "v_tail", "fin", "ventral_fin")

"""
    classify_role(role::AbstractString) -> Symbol

Map a `LiftingSurface.role` string to one of `:wing_body`, `:tail_h`, `:tail_v`.
Anything not recognised as a stabilizer is treated as wing+body.
"""
function classify_role(role::AbstractString)
    r = lowercase(strip(role))
    if any(occursin(t, r) for t in TAIL_H_ROLES)
        return :tail_h
    elseif any(occursin(t, r) for t in TAIL_V_ROLES)
        return :tail_v
    else
        return :wing_body
    end
end

"""
    tail_component_from_roles(roles) -> Symbol

Collapse a vector of per-surface role Symbols into a single tail component
label, preferring `:tail_h` when both are present (combined horizontal+vertical
tails are not modelled; each surface contributes independently).
"""
function tail_component_from_roles(roles)
    has_h = any(r == :tail_h for r in roles)
    has_v = any(r == :tail_v for r in roles)
    return has_h ? :tail_h : (has_v ? :tail_v : :wing_body)
end

"""
    surface_aerodynamic_center(surf::LiftingSurface) -> Vector{Float64}

Quarter-chord point of the surface MAC in aircraft body coordinates
(x fwd-to-aft, y right, z down — same convention as `root_LE`).
Used as the reference point for tail moments.
"""
function surface_aerodynamic_center(surf::LiftingSurface)
    wp = wing_planform(surf)
    # Spanwise y of MAC (for non-vertical, symmetric): y_mac at 2/3*(1+2λ)/(1+λ) * semi-span * cos(Γ)
    λ = surf.TR
    y_mac_frac = (1.0 + 2.0 * λ) / (3.0 * (1.0 + λ))
    y_mac = y_mac_frac * wp.semi_span

    root = surf.root_LE
    if surf.vertical
        # Vertical: the "span" runs in -z (up). Use z for the "outboard" coord.
        x_at_mac = root[1] + y_mac * tan(wp.sweep_le)
        y_at_mac = root[2]
        z_at_mac = root[3] - y_mac  # fin tip is higher → more negative z
    else
        x_at_mac = root[1] + y_mac * tan(wp.sweep_le)
        y_at_mac = root[2]           # symmetric pair cancels; AC on centerline
        z_at_mac = root[3] + y_mac * sin(wp.dihedral)
    end

    # Quarter-chord offset at the MAC station
    chord_at_mac = (2.0 * wp.root_chord + wp.tip_chord) / 3.0 *
                   (1.0 - 0.0)   # conservative: MAC chord ≈ (2c_r + c_t)/3
    x_at_mac += 0.25 * chord_at_mac

    return [x_at_mac, y_at_mac, z_at_mac]
end

"""
    tail_arm_vector(surf::LiftingSurface, cg::AbstractVector) -> Vector{Float64}

Vector from aircraft CoG to the tail surface aerodynamic center,
expressed in body axes. Used in the simulator to perform the final
r×F moment transfer during coefficient assembly.
"""
function tail_arm_vector(surf::LiftingSurface, cg::AbstractVector)
    ac = surface_aerodynamic_center(surf)
    return ac .- cg
end

"""
    translate_moment_coefficients(CF, CM, r_from_to, cref, bref) -> Vector{Float64}

Given force coefficients `CF = [CX, CY, CZ]` (non-dim by q·S_ref) and moment
coefficients `CM = [Cl, Cm, Cn]` (non-dim by q·S_ref·b, q·S_ref·c, q·S_ref·b)
taken about point A, return moment coefficients about point B where
`r_from_to = r_B − r_A` (body axes, metres).

Formula (dimensional):  M_B = M_A − r × F
Non-dim form is the same once each moment component is scaled by its proper
reference length. `cref` is used for Cm, `bref` for Cl and Cn.
"""
function translate_moment_coefficients(CF::AbstractVector, CM::AbstractVector,
                                       r_from_to::AbstractVector,
                                       cref::Real, bref::Real)
    # Dimensional F (per unit q·S_ref):
    Fx, Fy, Fz = CF[1], CF[2], CF[3]
    rx, ry, rz = r_from_to[1], r_from_to[2], r_from_to[3]

    # r × F (per unit q·S_ref)
    τx = ry * Fz - rz * Fy
    τy = rz * Fx - rx * Fz
    τz = rx * Fy - ry * Fx

    # Subtract, with each component scaled by its reference length
    Cl_B = CM[1] - τx / bref
    Cm_B = CM[2] - τy / cref
    Cn_B = CM[3] - τz / bref

    return [Cl_B, Cm_B, Cn_B]
end

"""
    finite_difference_at_zero(values, abscissa) -> Float64

Central-difference slope near zero for a 1-D coefficient slice. Falls back to a
one-sided estimate when zero is at the edge of the sampled range.
"""
function finite_difference_at_zero(values::AbstractVector, abscissa::AbstractVector)
    n = min(length(values), length(abscissa))
    n < 2 && return 0.0

    i0 = 1
    best = abs(abscissa[1])
    for i in 2:n
        here = abs(abscissa[i])
        if here < best
            best = here
            i0 = i
        end
    end

    if 1 < i0 < n
        denom = abscissa[i0 + 1] - abscissa[i0 - 1]
        return abs(denom) > 1.0e-9 ? (values[i0 + 1] - values[i0 - 1]) / denom : 0.0
    elseif i0 == 1
        denom = abscissa[2] - abscissa[1]
        return abs(denom) > 1.0e-9 ? (values[2] - values[1]) / denom : 0.0
    else
        denom = abscissa[n] - abscissa[n - 1]
        return abs(denom) > 1.0e-9 ? (values[n] - values[n - 1]) / denom : 0.0
    end
end

"""
    wing_body_neutral_point_xyz(cg, cref, alphas_deg, betas_deg, CL_wb, Cm_wb, default_xyz)
        -> Vector{Float64}

Estimate the wing+body neutral-point location from the wing+body CL and Cm
tables currently referenced to the aircraft CoG. The neutral point is placed at
the same y/z station as `default_xyz`; only the longitudinal x-coordinate is
shifted based on the static-margin relation x_np - x_cg = -(Cm_alpha/CL_alpha)c.
"""
function wing_body_neutral_point_xyz(cg::AbstractVector,
                                     cref::Real,
                                     alphas_deg::AbstractVector,
                                     betas_deg::AbstractVector,
                                     CL_wb::AbstractMatrix,
                                     Cm_wb::AbstractMatrix,
                                     default_xyz::AbstractVector)
    beta0_idx = 1
    best_beta = abs(betas_deg[1])
    for i in 2:length(betas_deg)
        here = abs(betas_deg[i])
        if here < best_beta
            best_beta = here
            beta0_idx = i
        end
    end

    cl_slice = CL_wb[:, beta0_idx]
    cm_slice = Cm_wb[:, beta0_idx]
    cla_deg = finite_difference_at_zero(cl_slice, alphas_deg)
    cma_deg = finite_difference_at_zero(cm_slice, alphas_deg)
    static_margin = abs(cla_deg) > 1.0e-9 ? -cma_deg / cla_deg : 0.0

    x_np = cg[1] + static_margin * Float64(cref)
    y_np = length(default_xyz) >= 2 ? Float64(default_xyz[2]) : (length(cg) >= 2 ? Float64(cg[2]) : 0.0)
    z_np = length(default_xyz) >= 3 ? Float64(default_xyz[3]) : (length(cg) >= 3 ? Float64(cg[3]) : 0.0)
    return [x_np, y_np, z_np]
end

"""
    accumulate_per_role!(sums, role, CF, CM)

Add CF/CM to the bucket identified by `role` in the `sums` dict.
`sums` has keys `:wing_body`, `:tail_h`, `:tail_v`, each holding a tuple
of running-sum vectors `(CF_sum::Vector{Float64}, CM_sum::Vector{Float64})`.
"""
function accumulate_per_role!(sums::Dict{Symbol,Tuple{Vector{Float64},Vector{Float64}}},
                              role::Symbol,
                              CF::AbstractVector, CM::AbstractVector)
    bucket = get!(sums, role) do
        (zeros(3), zeros(3))
    end
    bucket[1] .+= CF
    bucket[2] .+= CM
    return sums
end
