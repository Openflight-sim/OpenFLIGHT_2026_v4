"""
    vlm_backend.jl — VortexLattice.jl backend adapter

Runs steady VLM analysis over alpha/beta sweeps using VortexLattice.jl.
Produces stability and control derivatives for the subsonic linear regime.
"""

# Path to VortexLattice.jl package
const VLM_PATH = normpath(joinpath(@__DIR__, "..", "..", "VortexLattice.jl-master"))

# We'll load VortexLattice on first use
let _vlm_loaded = Ref(false)
    global function ensure_vlm_loaded()
        if !_vlm_loaded[]
            pushfirst!(LOAD_PATH, VLM_PATH)
            @eval using VortexLattice
            @eval using StaticArrays
            _vlm_loaded[] = true
        end
    end
end

"""
    naca4_camber_function(max_camber, camber_pos) -> Function

Returns a camber line function `y = f(xc)` for a NACA 4-digit airfoil,
where `xc ∈ [0,1]` is the normalised chordwise position and `y` is the
camber ordinate as a fraction of chord.

For a symmetric airfoil (max_camber ≈ 0), returns `xc -> 0.0`.
"""
function naca4_camber_function(max_camber::Float64, camber_pos::Float64)
    m = max_camber
    p = camber_pos
    if m < 1e-6 || p < 1e-6
        return xc -> 0.0
    end
    return function (xc)
        x = clamp(xc, 0.0, 1.0)
        if x <= p
            return m / p^2 * (2p * x - x^2)
        else
            return m / (1 - p)^2 * ((1 - 2p) + 2p * x - x^2)
        end
    end
end

"""
    extract_per_surface_forces(system, frame) -> Vector{Tuple}

Extract force and moment coefficients for each surface individually,
replicating the logic in VortexLattice.body_forces but returning
per-surface (CFi, CMi) instead of summing them.
"""
function extract_per_surface_forces(system, frame)
    surfaces   = system.surfaces
    properties = system.properties
    ref        = system.reference[]
    fs         = system.freestream[]
    symmetric  = system.symmetric

    n_surf = length(surfaces)
    ref_len = [ref.b, ref.c, ref.b]
    conv    = [-1.0, 1.0, -1.0]

    results = Vector{Tuple}(undef, n_surf)

    for isurf in 1:n_surf
        CFi = zeros(3)
        CMi = zeros(3)

        for i in 1:length(surfaces[isurf])
            panel = surfaces[isurf][i]
            # top bound vortex
            rc = @eval VortexLattice.top_center($panel)
            dr = rc - ref.r
            cf = properties[isurf][i].cfb
            CFi .+= cf
            CMi .+= cross(dr, cf)

            # left bound vortex
            rc = @eval VortexLattice.left_center($panel)
            dr = rc - ref.r
            cf = properties[isurf][i].cfl
            CFi .+= cf
            CMi .+= cross(dr, cf)

            # right bound vortex
            rc = @eval VortexLattice.right_center($panel)
            dr = rc - ref.r
            cf = properties[isurf][i].cfr
            CFi .+= cf
            CMi .+= cross(dr, cf)
        end

        # Account for symmetry
        if symmetric[isurf]
            CFi = [2*CFi[1], 0.0, 2*CFi[3]]
            CMi = [0.0, 2*CMi[2], 0.0]
        end

        # Normalize moments by reference lengths and apply convention
        CMi = CMi ./ ref_len .* conv

        # Transform to requested frame
        CFi_sv = @eval StaticArrays.SVector($(CFi[1]), $(CFi[2]), $(CFi[3]))
        CMi_sv = @eval StaticArrays.SVector($(CMi[1]), $(CMi[2]), $(CMi[3]))
        CFi_out, CMi_out = @eval VortexLattice.body_to_frame($CFi_sv, $CMi_sv, $ref, $fs, $frame)

        results[isurf] = (CFi_out, CMi_out)
    end

    return results
end

"""
    run_vlm_backend(input::AircraftInput; progress_callback=nothing) -> Dict

Runs VortexLattice.jl over the requested alpha/beta/Mach envelope.
Returns a Dict with:
  - "static": CL/CD/CY/Cl/Cm/Cn arrays indexed [alpha_idx][beta_idx]
  - "derivatives": stability derivatives at each alpha
  - "control_derivatives": per-control-surface derivatives
"""
function run_vlm_backend(input::AircraftInput; progress_callback=nothing)
    cb = isnothing(progress_callback) ? (s, p, m) -> nothing : progress_callback

    ensure_vlm_loaded()

    # Clamp analysis range to VLM validity (±25°).
    # VLM is a linear potential-flow method — results are unreliable beyond this.
    # The full_envelope.jl module extends to ±180° after VLM completes.
    vlm_alpha_lo = max(input.analysis.alpha_range_DEG[1], -25.0)
    vlm_alpha_hi = min(input.analysis.alpha_range_DEG[2], 25.0)
    vlm_beta_lo = max(input.analysis.beta_range_DEG[1], -25.0)
    vlm_beta_hi = min(input.analysis.beta_range_DEG[2], 25.0)

    alphas_deg = collect(vlm_alpha_lo:input.analysis.alpha_step_DEG:vlm_alpha_hi)
    betas_deg = collect(vlm_beta_lo:input.analysis.beta_step_DEG:vlm_beta_hi)

    # Ensure we have at least a minimal range even if user requested only extreme angles
    if isempty(alphas_deg)
        alphas_deg = collect(-20.0:5.0:20.0)
    end
    if isempty(betas_deg)
        betas_deg = collect(-15.0:5.0:15.0)
    end

    machs = input.analysis.mach_values

    # For VLM, Mach effects are limited; we use the first (lowest) Mach
    # and note that VLM is incompressible by default
    mach_ref = isempty(machs) ? 0.2 : machs[1]

    # Build reference
    wing_surf = findfirst(s -> lowercase(s.name) == "wing", input.lifting_surfaces)
    if isnothing(wing_surf)
        wing_surf = 1
    end
    ws = input.lifting_surfaces[wing_surf]
    wp = wing_planform(ws)

    Sref = input.general.Sref
    cref = input.general.cref
    bref = input.general.bref
    cog = input.general.CoG

    n_alpha = length(alphas_deg)
    n_beta = length(betas_deg)
    n_lifting = length(input.lifting_surfaces)
    total_points = n_alpha * n_beta

    # Result arrays
    CL_arr = zeros(n_alpha, n_beta)
    CD_arr = zeros(n_alpha, n_beta)
    CY_arr = zeros(n_alpha, n_beta)
    Cl_arr = zeros(n_alpha, n_beta)
    Cm_arr = zeros(n_alpha, n_beta)
    Cn_arr = zeros(n_alpha, n_beta)

    # Per-surface force arrays (one CL/CY/CD per lifting surface)
    per_surf_CL = [zeros(n_alpha, n_beta) for _ in 1:n_lifting]
    per_surf_CY = [zeros(n_alpha, n_beta) for _ in 1:n_lifting]
    per_surf_CD = [zeros(n_alpha, n_beta) for _ in 1:n_lifting]

    # ───── Component-split storage (schema v3.0) ─────
    # Wing+body bucket: all non-tail lifting surfaces + fuselage panels (summed).
    # Moments referenced to aircraft CoG.
    CL_wb = zeros(n_alpha, n_beta); CD_wb = zeros(n_alpha, n_beta); CY_wb = zeros(n_alpha, n_beta)
    Cl_wb = zeros(n_alpha, n_beta); Cm_wb = zeros(n_alpha, n_beta); Cn_wb = zeros(n_alpha, n_beta)

    # Per-tail-surface bucket. Moments referenced to that surface's own AC.
    # Tables are indexed by AIRCRAFT α,β here; local-angle rebinning happens
    # in full_envelope.jl after downwash/sidewash are known.
    n_tail = count(s -> classify_role(s.role) != :wing_body, input.lifting_surfaces)
    tail_blocks = Dict{Int,Dict{String,Any}}()   # surface index → block
    for (si, surf) in enumerate(input.lifting_surfaces)
        if classify_role(surf.role) != :wing_body
            tail_blocks[si] = Dict{String,Any}(
                "name" => surf.name,
                "role" => surf.role,
                "component" => String(classify_role(surf.role)),
                "arm_m" => tail_arm_vector(surf, cog),
                "ac_xyz_m" => surface_aerodynamic_center(surf),
                "CL" => zeros(n_alpha, n_beta), "CD" => zeros(n_alpha, n_beta),
                "CY" => zeros(n_alpha, n_beta),
                "Cl_at_AC" => zeros(n_alpha, n_beta),
                "Cm_at_AC" => zeros(n_alpha, n_beta),
                "Cn_at_AC" => zeros(n_alpha, n_beta)
            )
        end
    end

    # Interference tables sampled at β=0 for downwash/η_h, at α=0 for sidewash/η_v.
    # Indexed by α (or β) only in this first-cut; full_envelope broadens them.
    downwash_deg_arr = zeros(n_alpha)          # ε(α)
    eta_h_arr = fill(1.0, n_alpha)             # q_h/q_∞(α)
    sidewash_deg_arr = zeros(n_beta)           # σ(β)
    eta_v_arr = fill(1.0, n_beta)              # q_v/q_∞(β)

    # Derivative arrays (at beta=0 only)
    beta0_idx = findfirst(b -> abs(b) < 0.01, betas_deg)
    if isnothing(beta0_idx)
        beta0_idx = div(n_beta, 2) + 1
    end

    deriv_names = ["Cl_p_hat", "Cm_q_hat", "Cn_r_hat", "CL_q_hat", "CY_p_hat", "CY_r_hat"]
    derivs = Dict(name => zeros(n_alpha) for name in deriv_names)

    # Build geometry once (at beta=0, alpha=0)
    cb("running", 5, "Building VLM geometry...")
    grids, ratios, sym_flags, surf_ids = build_vlm_geometry(input)

    # Create system
    system = @eval VortexLattice.System($grids; ratios=$ratios)

    point_count = 0
    for (ai, alpha) in enumerate(alphas_deg)
        for (bi, beta) in enumerate(betas_deg)
            alpha_rad = deg2rad(alpha)
            beta_rad = deg2rad(beta)

            ref = @eval VortexLattice.Reference($Sref, $cref, $bref, $cog, 1.0)
            fs = @eval VortexLattice.Freestream(1.0, $alpha_rad, $beta_rad, zeros(3))

            @eval VortexLattice.steady_analysis!($system, $ref, $fs;
                symmetric=$sym_flags, surface_id=$surf_ids)

            CF, CM = @eval VortexLattice.body_forces($system; frame=VortexLattice.Wind())
            CX, CYv, CZ = CF
            Clv, Cmv, Cnv = CM

            CL_arr[ai, bi] = CZ   # CL
            CD_arr[ai, bi] = CX   # CD
            CY_arr[ai, bi] = CYv  # CY
            Cl_arr[ai, bi] = Clv  # Cl (roll)
            Cm_arr[ai, bi] = Cmv  # Cm (pitch)
            Cn_arr[ai, bi] = Cnv  # Cn (yaw)

            # Per-surface force+moment extraction (all surfaces, including fuselage).
            # Moments returned by extract_per_surface_forces are taken about ref.r
            # (the aircraft CoG), expressed in the Wind frame.
            try
                wind_frame = @eval VortexLattice.Wind()
                surf_forces = extract_per_surface_forces(system, wind_frame)

                n_surf_total = length(surf_forces)
                CF_wb_sum = zeros(3); CM_wb_sum = zeros(3)

                for si in 1:n_surf_total
                    CF_s, CM_s = surf_forces[si]

                    is_lifting = si <= n_lifting
                    role = is_lifting ? classify_role(input.lifting_surfaces[si].role) : :wing_body

                    if is_lifting
                        per_surf_CL[si][ai, bi] = CF_s[3]
                        per_surf_CY[si][ai, bi] = CF_s[2]
                        per_surf_CD[si][ai, bi] = CF_s[1]
                    end

                    if role == :wing_body
                        CF_wb_sum .+= [CF_s[1], CF_s[2], CF_s[3]]
                        CM_wb_sum .+= [CM_s[1], CM_s[2], CM_s[3]]
                    else
                        # Tail surface — store raw (at CoG) then translate to its AC.
                        blk = tail_blocks[si]
                        CF_tail = [CF_s[1], CF_s[2], CF_s[3]]
                        CM_tail_at_CoG = [CM_s[1], CM_s[2], CM_s[3]]
                        r_cg_to_ac = blk["arm_m"]
                        CM_tail_at_AC = translate_moment_coefficients(
                            CF_tail, CM_tail_at_CoG, r_cg_to_ac, cref, bref
                        )
                        blk["CD"][ai, bi] = CF_tail[1]
                        blk["CY"][ai, bi] = CF_tail[2]
                        blk["CL"][ai, bi] = CF_tail[3]
                        blk["Cl_at_AC"][ai, bi] = CM_tail_at_AC[1]
                        blk["Cm_at_AC"][ai, bi] = CM_tail_at_AC[2]
                        blk["Cn_at_AC"][ai, bi] = CM_tail_at_AC[3]
                    end
                end

                CD_wb[ai, bi] = CF_wb_sum[1]
                CY_wb[ai, bi] = CF_wb_sum[2]
                CL_wb[ai, bi] = CF_wb_sum[3]
                Cl_wb[ai, bi] = CM_wb_sum[1]
                Cm_wb[ai, bi] = CM_wb_sum[2]
                Cn_wb[ai, bi] = CM_wb_sum[3]
            catch e
                @debug "Per-surface force/moment extraction failed" exception=e
            end

            # Get stability derivatives at beta=0
            # VortexLattice.stability_derivatives() returns derivatives in the
            # stability frame using standard aero convention:
            #   dCF = (alpha, beta, p, q, r) of (CD, CY, CL)
            #   dCM = (alpha, beta, p, q, r) of (Cl, Cm, Cn)
            # Signs follow standard convention (verified against AVL test cases):
            #   Cl_p < 0 (roll damping), Cm_q < 0 (pitch damping),
            #   Cn_r < 0 (yaw damping), CL_q > 0 (tail lift from pitch rate)
            if bi == beta0_idx
                try
                    dCF, dCM = @eval VortexLattice.stability_derivatives($system)

                    # Unpack: dCF.x = (dCD/dx̂, dCY/dx̂, dCL/dx̂)
                    #         dCM.x = (dCl/dx̂, dCm/dx̂, dCn/dx̂)
                    dpCl, _dpCm, _dpCn = dCM.p
                    _dpCD, dpCY, _dpCL = dCF.p
                    _dqCD, _dqCY, dqCL = dCF.q
                    _dqCl, dqCm, _dqCn = dCM.q
                    _drCD, drCY, _drCL = dCF.r
                    _drCl, _drCm, drCn = dCM.r

                    # p-hat derivatives (roll rate)
                    derivs["Cl_p_hat"][ai] = dpCl   # dCl/dp̂ — roll damping
                    derivs["CY_p_hat"][ai] = dpCY   # dCY/dp̂ — VTP side force from roll
                    # q-hat derivatives (pitch rate)
                    derivs["CL_q_hat"][ai] = dqCL   # dCL/dq̂ — tail lift from pitch rate
                    derivs["Cm_q_hat"][ai] = dqCm   # dCm/dq̂ — pitch damping
                    # r-hat derivatives (yaw rate)
                    derivs["CY_r_hat"][ai] = drCY   # dCY/dr̂ — VTP side force from yaw
                    derivs["Cn_r_hat"][ai] = drCn   # dCn/dr̂ — yaw damping
                catch e
                    @warn "VLM derivatives failed at alpha=$alpha: $e"
                end
            end

            point_count += 1
            pct = round(Int, 10 + 85 * point_count / total_points)
            cb("running", pct, "Alpha=$(alpha)°, Beta=$(beta)°")
        end
    end

    # ───── Interference tables (ε, σ, η_h, η_v) ─────
    # Phase 1a placeholder: horseshoe-vortex downwash at the HTP quarter-chord,
    # taking the VLM-computed wing-alone CL to drive the far-field estimate.
    # NOTE: upgrade path (Phase 1a-part-2) is to sample induced velocity at each
    # tail panel control point directly from system.properties — replace the
    # body of compute_interference_from_vlm! below without changing its signature.
    compute_interference_from_vlm!(
        downwash_deg_arr, sidewash_deg_arr, eta_h_arr, eta_v_arr,
        input, alphas_deg, betas_deg, CL_wb, CY_wb, beta0_idx
    )

    # Collect control effectiveness (from derivatives at beta=0)
    control_derivs = compute_vlm_control_derivatives(input, system, alphas_deg, Sref, cref, bref, cog)

    cb("running", 98, "Packaging VLM results...")

    # Build per-surface data dictionary keyed by surface name and role
    per_surface_data = Dict{String,Any}()
    for (si, surf) in enumerate(input.lifting_surfaces)
        per_surface_data[surf.name] = Dict(
            "role" => surf.role,
            "CL" => per_surf_CL[si],
            "CY" => per_surf_CY[si],
            "CD" => per_surf_CD[si]
        )
    end

    # Export VLM panel mesh for 3D visualization
    vlm_mesh = export_vlm_mesh(grids, surf_ids, input)

    # ───── Package v3.0 split blocks ─────
    # Move wing+body moments from the generation-time CoG to the wing+body
    # neutral point so the simulator can later re-reference them to any user-
    # selected CG.
    wing_body_ref_default = copy(cog)
    wing_surface_idx = findfirst(s -> classify_role(s.role) == :wing_body &&
                                      occursin("wing", lowercase(s.name)), input.lifting_surfaces)
    if wing_surface_idx !== nothing
        wing_body_ref_default = surface_aerodynamic_center(input.lifting_surfaces[wing_surface_idx])
    end
    wing_body_ref_xyz = wing_body_neutral_point_xyz(
        cog, cref, alphas_deg, betas_deg, CL_wb, Cm_wb, wing_body_ref_default
    )
    r_cg_to_wb_ref = wing_body_ref_xyz .- cog
    Cl_wb_ref = similar(Cl_wb)
    Cm_wb_ref = similar(Cm_wb)
    Cn_wb_ref = similar(Cn_wb)
    for ai in 1:n_alpha, bi in 1:n_beta
        CM_wb_ref = translate_moment_coefficients(
            [CD_wb[ai, bi], CY_wb[ai, bi], CL_wb[ai, bi]],
            [Cl_wb[ai, bi], Cm_wb[ai, bi], Cn_wb[ai, bi]],
            r_cg_to_wb_ref,
            cref, bref
        )
        Cl_wb_ref[ai, bi] = CM_wb_ref[1]
        Cm_wb_ref[ai, bi] = CM_wb_ref[2]
        Cn_wb_ref[ai, bi] = CM_wb_ref[3]
    end

    # Wing+body: what the simulator will add to tail contributions.
    wing_body_block = Dict{String,Any}(
        "static" => Dict(
            "CL" => CL_wb, "CD" => CD_wb, "CY" => CY_wb,
            "Cl" => Cl_wb_ref, "Cm" => Cm_wb_ref, "Cn" => Cn_wb_ref
        ),
        "reference_point_m" => Dict(
            "kind" => "neutral_point",
            "xyz_m" => wing_body_ref_xyz
        ),
        "alphas_deg" => alphas_deg,
        "betas_deg" => betas_deg
    )

    # Tail block: one entry per tail surface, moments taken about that
    # surface's own AC, forces non-dim by aircraft S_ref.
    tail_block = Dict{String,Any}(
        "surfaces" => [tail_blocks[si] for si in sort(collect(keys(tail_blocks)))],
        "alphas_deg" => alphas_deg,
        "betas_deg" => betas_deg
    )

    # Interference block — 1-D tables (to be broadened to (config, mach) in merge/envelope).
    interference_block = Dict{String,Any}(
        "downwash_deg"   => Dict("alpha_deg" => alphas_deg, "values" => downwash_deg_arr),
        "sidewash_deg"   => Dict("beta_deg"  => betas_deg,  "values" => sidewash_deg_arr),
        "eta_h"          => Dict("alpha_deg" => alphas_deg, "values" => eta_h_arr),
        "eta_v"          => Dict("beta_deg"  => betas_deg,  "values" => eta_v_arr),
        "source"         => "vlm_analytic_placeholder"
    )

    return Dict(
        "static" => Dict(
            "CL" => CL_arr, "CD" => CD_arr, "CY" => CY_arr,
            "Cl" => Cl_arr, "Cm" => Cm_arr, "Cn" => Cn_arr
        ),
        "alphas_deg" => alphas_deg,
        "betas_deg" => betas_deg,
        "dynamic_derivatives" => derivs,
        "control_derivatives" => control_derivs,
        "per_surface_data" => per_surface_data,
        "vlm_mesh" => vlm_mesh,
        # v3.0 additions — consumed by merge.jl in Phase 1e.
        "wing_body" => wing_body_block,
        "tail" => tail_block,
        "interference" => interference_block
    )
end

"""
    compute_interference_from_vlm!(ε, σ, η_h, η_v, input, alphas, betas,
                                   CL_wb, CY_wb, beta0_idx)

Fill in-place the downwash angle ε(α), sidewash angle σ(β), and the tail
dynamic-pressure ratios η_h(α), η_v(β) for Phase 1a.

Current implementation (placeholder): classical trailing-vortex horseshoe
downwash with the wing-alone CL from the VLM sweep as forcing. η is modelled
as a mild (1 − 0.15·sin²α) wake-loss term capped at 0.8. These curves are
physically sensible but not VLM-sampled — upgrade path is to average the
panel induced velocities at the HTP/VTP control points (system.properties)
and return ε = atan(w_ind/V), σ = atan(v_ind/V), η = |V_local|²/V_∞².
"""
function compute_interference_from_vlm!(
    downwash_deg::Vector{Float64},
    sidewash_deg::Vector{Float64},
    eta_h::Vector{Float64},
    eta_v::Vector{Float64},
    input::AircraftInput,
    alphas_deg::Vector{Float64},
    betas_deg::Vector{Float64},
    CL_wb::Matrix{Float64},
    _CY_wb::Matrix{Float64},   # reserved for proper VLM σ extraction (Phase 1a-part-2)
    beta0_idx::Int
)
    # Find the wing and the horizontal tail (first of each); canards flip sign.
    wing_idx = findfirst(s -> classify_role(s.role) == :wing_body &&
                              occursin("wing", lowercase(s.name)), input.lifting_surfaces)
    htp_idx  = findfirst(s -> classify_role(s.role) == :tail_h, input.lifting_surfaces)
    vtp_idx  = findfirst(s -> classify_role(s.role) == :tail_v, input.lifting_surfaces)

    if wing_idx === nothing || htp_idx === nothing
        # No tail → ε = 0, η_h = 1 (no interference effect to apply)
        fill!(downwash_deg, 0.0); fill!(eta_h, 1.0)
    else
        wing = input.lifting_surfaces[wing_idx]
        htp  = input.lifting_surfaces[htp_idx]
        wp   = wing_planform(wing)

        # Geometric position of the HTP AC relative to wing AC.
        wing_ac = surface_aerodynamic_center(wing)
        htp_ac  = surface_aerodynamic_center(htp)
        x_tail = htp_ac[1] - wing_ac[1]            # longitudinal arm (m)
        z_tail = htp_ac[3] - wing_ac[3]            # vertical offset  (m)

        # Classical dε/dα (Roskam / DATCOM equivalent), per radian.
        # deda = 4.44 · [k_A·k_λ·k_h · √cos(Λ_{c/4})]^1.19
        k_A  = 1.0/AR_like_safe(wing) - 1.0/(1.0 + wing.AR^1.7)
        k_λ  = (10.0 - 3.0*wing.TR) / 7.0
        k_h  = (1.0 - abs(z_tail)/max(wp.span, 1e-3)) /
               cbrt(max(2.0*x_tail/max(wp.span, 1e-3), 1e-3))
        deda = 4.44 * (k_A * k_λ * k_h * sqrt(max(cos(deg2rad(wing.sweep_quarter_chord_DEG)), 0.01)))^1.19

        # ε(α) ≈ (2·CL_wb)/(π·AR_wing)  (far-field horseshoe estimate),
        # blended with dε/dα·α near the wing.
        for (ai, α) in enumerate(alphas_deg)
            CL_here = CL_wb[ai, beta0_idx]
            ε_far = 2.0 * CL_here / (π * max(wing.AR, 0.5))
            ε_near = deda * deg2rad(α)
            # Blend: 60% near-field (α-driven), 40% far-field (CL-driven)
            ε = 0.6*ε_near + 0.4*ε_far
            downwash_deg[ai] = clamp(rad2deg(ε), -15.0, 15.0)

            # Tail dynamic-pressure ratio: mild wake loss with α.
            eta_h[ai] = clamp(0.95 - 0.15 * sin(deg2rad(α))^2, 0.6, 1.0)
        end
    end

    # Sidewash σ(β): slender-body cross-flow induces small σ at the VTP.
    # σ ≈ 0.1·β (empirical) with mild η_v loss.
    if vtp_idx === nothing
        fill!(sidewash_deg, 0.0); fill!(eta_v, 1.0)
    else
        for (bi, β) in enumerate(betas_deg)
            sidewash_deg[bi] = 0.1 * β
            eta_v[bi] = clamp(0.95 - 0.1 * sin(deg2rad(β))^2, 0.7, 1.0)
        end
    end
    return nothing
end

# Minor helper — planform aspect ratio with safety floor.
@inline AR_like_safe(s) = max(s.AR, 0.5)

"""
Build VLM grid arrays from aircraft input.
Returns (grids, ratios, symmetric_flags, surface_ids).
"""
function build_vlm_geometry(input::AircraftInput)
    grids = Vector{Array{Float64,3}}()
    ratios = Vector{Array{Float64,3}}()
    sym_flags = Bool[]
    surf_ids = Int[]

    for (i, surf) in enumerate(input.lifting_surfaces)
        wp = wing_planform(surf)
        offset = surf.root_LE

        if surf.vertical
            xle = [0.0 + offset[1], wp.semi_span * tan(wp.sweep_le) + offset[1]]
            yle = [0.0 + offset[2], 0.0 + offset[2]]
            zle = [0.0 + offset[3], wp.semi_span + offset[3]]
        else
            xle = [0.0 + offset[1], wp.semi_span * tan(wp.sweep_le) + offset[1]]
            yle = [0.0 + offset[2], wp.semi_span * cos(wp.dihedral) + offset[2]]
            zle = [0.0 + offset[3], wp.semi_span * sin(wp.dihedral) + offset[3]]
        end

        chord = [wp.root_chord, wp.tip_chord]
        theta = [deg2rad(surf.incidence_DEG), deg2rad(surf.incidence_DEG + surf.twist_tip_DEG)]
        phi = [0.0, 0.0]

        # Build camber line functions from airfoil data
        fc_root = naca4_camber_function(Float64(surf.airfoil.root_max_camber),
                                         Float64(surf.airfoil.root_camber_position))
        fc_tip  = naca4_camber_function(Float64(surf.airfoil.tip_max_camber),
                                         Float64(surf.airfoil.tip_camber_position))
        fc_vec = [fc_root, fc_tip]

        # Panel counts based on aspect ratio
        p1 = [xle[1], yle[1], zle[1]]
        p2 = [xle[2], yle[2], zle[2]]
        L_span = norm(p2 .- p1)
        avg_chord = (chord[1] + chord[2]) / 2
        ratio_ = L_span / max(avg_chord, 0.01)

        min_span = 7
        min_chord = 5
        if ratio_ >= 1
            nc = min_chord
            ns = max(min_span, round(Int, ratio_ * nc))
        else
            ns = min_span
            nc = max(min_chord, round(Int, ns / max(ratio_, 0.01)))
        end

        # For symmetric surfaces, force mirror=true so both halves are modeled
        # explicitly. Never use the VLM symmetry boundary condition, because it
        # forces CY=0 at all sideslip angles (the symmetric BC mirrors the flow
        # solution, cancelling all lateral forces).
        vlm_mirror = surf.symmetric ? true : surf.mirror

        # Use VortexLattice.wing_to_grid
        grid, ratio_arr = @eval VortexLattice.wing_to_grid(
            $xle, $yle, $zle, $chord, $theta, $phi,
            $ns, $nc;
            mirror=$vlm_mirror,
            fc=$fc_vec,
            spacing_s=VortexLattice.Uniform(),
            spacing_c=VortexLattice.Uniform()
        )

        push!(grids, grid)
        push!(ratios, ratio_arr)
        push!(sym_flags, false)   # always false — full model, no symmetry BC
        push!(surf_ids, i)
    end

    # Build fuselage octagon surfaces
    base_id = length(surf_ids)
    for fus in input.fuselages
        R = fus.diameter / 2
        s_oct = R * sin(π / 8)
        nChord = max(2, round(Int, fus.length / max(s_oct, 0.01)))
        nSpan = 1
        nosepos = fus.nose_position

        angles = [deg2rad(45 * (k - 1)) for k in 1:9]
        for iSide in 1:8
            α1 = angles[iSide]
            α2 = angles[iSide+1]

            ycorner1 = nosepos[2] + R * cos(α1)
            zcorner1 = nosepos[3] + R * sin(α1)
            ycorner2 = nosepos[2] + R * cos(α2)
            zcorner2 = nosepos[3] + R * sin(α2)

            grid = Array{Float64,3}(undef, 3, nChord + 1, nSpan + 1)
            for iC in 0:nChord, jS in 0:nSpan
                chordFrac = iC / nChord
                lerpFrac = jS / nSpan
                grid[1, iC+1, jS+1] = nosepos[1] + chordFrac * fus.length
                grid[2, iC+1, jS+1] = (1 - lerpFrac) * ycorner1 + lerpFrac * ycorner2
                grid[3, iC+1, jS+1] = (1 - lerpFrac) * zcorner1 + lerpFrac * zcorner2
            end

            ratio_arr = fill(0.0, 2, nChord, nSpan)
            for iC in 1:nChord, jS in 1:nSpan
                ratio_arr[1, iC, jS] = 0.55
                ratio_arr[2, iC, jS] = 0.50
            end

            push!(grids, grid)
            push!(ratios, ratio_arr)
            push!(sym_flags, false)
            push!(surf_ids, base_id + iSide)
        end
        base_id += 8
    end

    return grids, ratios, sym_flags, surf_ids
end

"""
Compute control surface derivatives by finite differences.
"""
function compute_vlm_control_derivatives(input, system, alphas_deg, Sref, cref, bref, cog)
    # Collect all control surface names across all lifting surfaces
    all_controls = Dict{String,Dict}()

    for surf in input.lifting_surfaces
        for cs in surf.control_surfaces
            if !haskey(all_controls, cs.name)
                all_controls[cs.name] = Dict(
                    "type" => cs.type,
                    "values" => zeros(length(alphas_deg))
                )
            end
        end
    end

    # VLM control derivatives are not computed here — the JAVL (AVL) backend
    # provides actual linear potential-flow control derivatives via sol.cl_d,
    # sol.cmy_d etc.  The values vector remains zeroed; merge.jl will prefer
    # JAVL control_derivatives when available and fall back to DATCOM flap τ.
    # No placeholder values are inserted to ensure full traceability.

    return all_controls
end

"""
    export_vlm_mesh(grids, surf_ids, input) -> Vector{Dict}

Exports the VLM panel grid coordinates for 3D visualization.
Each grid is [3, nc+1, ns+1] — we convert to nested arrays of [x,y,z] points.
Lifting surface grids get their name/role; fuselage octagon grids are labelled.
"""
function export_vlm_mesh(grids::Vector{Array{Float64,3}},
    surf_ids::Vector{Int},
    input::AircraftInput)
    n_lifting = length(input.lifting_surfaces)
    mesh_data = Vector{Dict{String,Any}}()

    for (gi, grid) in enumerate(grids)
        nc = size(grid, 2) - 1   # chordwise panels
        ns = size(grid, 3) - 1   # spanwise panels

        # Convert 3D array to nested list: points[chordwise_idx][spanwise_idx] = [x,y,z]
        points = Vector{Vector{Vector{Float64}}}()
        for ic in 1:size(grid, 2)
            row = Vector{Vector{Float64}}()
            for is in 1:size(grid, 3)
                push!(row, [round(grid[1, ic, is], digits=4),
                    round(grid[2, ic, is], digits=4),
                    round(grid[3, ic, is], digits=4)])
            end
            push!(points, row)
        end

        # Determine surface label
        sid = gi <= length(surf_ids) ? surf_ids[gi] : 0
        if sid >= 1 && sid <= n_lifting
            sname = input.lifting_surfaces[sid].name
            srole = input.lifting_surfaces[sid].role
        else
            sname = "Fuselage_panel_$(gi - n_lifting)"
            srole = "fuselage"
        end

        push!(mesh_data, Dict(
            "name" => sname,
            "role" => srole,
            "nc" => nc,
            "ns" => ns,
            "points" => points
        ))
    end

    return mesh_data
end
