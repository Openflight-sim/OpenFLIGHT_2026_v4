"""
    full_envelope.jl — Extend VLM linear-regime results to full ±180° envelope

VortexLattice.jl (VLM) is a linear potential-flow method, valid only for
small angles of attack and sideslip (roughly ±25°).  For an aerobatic flight
simulator we need coefficients over the full ±180° range.

This module:
  1. Extracts linear derivatives (CL_α, CY_β, Cm_α, …) from VLM data
  2. Reads stall / post-stall parameters from the aircraft JSON
  3. Builds full-range tables using physics-based models:

     CL(α) = linear → stall peak → exponential decay → flat plate  CD90·sin(α)·cos(α)
     CD(α) = CD0 + (CD90 − CD0)·sin²(α) + sideslip cross-flow + reverse-flow drag
     CY(β) = CY_β·β (linear) → −CD90_lat·sin(β)·cos(β)
     Cm(α) = Cm0 + Cm_α·α → decay post-stall
     Cl(α,β) = Cl_vtp·β (stalls at high β) + Cl_body·sin(2β)  [DATCOM decomposition]
     Cn(α,β) = Cn_vtp·β (stalls at high β) + Cn_body·sin(2β)  [DATCOM decomposition]
"""

# ================================================================
# Main entry point
# ================================================================

"""
    extend_to_full_envelope(input, vlm_results, json) -> Dict

Takes VLM results (or `nothing` when VLM didn't run) and builds the full
±180° aerodynamic envelope.  When VLM data is available, linear derivatives
are extracted from it.  When VLM is unavailable, all derivatives are
estimated from aircraft geometry.  Returns a Dict in VLM result format.
"""
function extend_to_full_envelope(input::AircraftInput, vlm_results, json::Dict)
    req_alpha = input.analysis.alpha_range_DEG
    req_beta  = input.analysis.beta_range_DEG
    has_vlm   = !isnothing(vlm_results) && vlm_results isa Dict

    # NOTE: We always run the full envelope extension, even for small-angle
    # analysis ranges.  VLM is a potential-flow method that gives purely linear
    # lateral coefficients (CY, Cl, Cn vs β), which is unrealistic.  The
    # full envelope adds DATCOM-style VTP stall and fuselage cross-flow
    # nonlinearities that are needed at any β range.

    # Full alpha/beta arrays — non-uniform grid: fine step within ±30°,
    # coarse (5°) step outside that range to keep the static tables smooth
    # through stall while still covering the full ±180° envelope.
    full_alphas = get_alpha_array(input.analysis)
    full_betas  = get_beta_array(input.analysis)

    # ---- Extract linear derivatives from VLM or estimate from geometry ----
    if has_vlm
        derivs = extract_vlm_linear_derivatives(vlm_results)
    else
        derivs = estimate_all_derivatives_from_geometry(input)
    end

    # ---- Compute stall parameters from geometry (DATCOM methods) ----
    mach_ref = isempty(input.analysis.mach_values) ? 0.2 : input.analysis.mach_values[1]
    stall_data = compute_aircraft_stall(input; mach=mach_ref,
                                        altitude_m=input.analysis.altitude_m)

    α_stall_pos = Float64(stall_data["alpha_stall_positive"])
    α_stall_neg = Float64(stall_data["alpha_stall_negative"])
    CL_max      = Float64(stall_data["CL_max"])
    CD0_geom    = Float64(stall_data["CD0"])
    CD90        = Float64(stall_data["CD90"])
    β_stall_vtp = Float64(stall_data["vtail_beta_stall_deg"])

    # Use VLM-derived CD0 if reasonable, otherwise fall back to geometry estimate
    CD0 = abs(derivs["CD0_vlm"]) > 0.001 ? derivs["CD0_vlm"] : CD0_geom
    K_induced = estimate_induced_drag_factor(input)

    # ---- Lateral derivatives: always use geometry-based DATCOM estimates ----
    # VLM fuselage octagon panels (8-strip flat-panel model) generate unrealistic
    # circulation-based lateral forces in the potential-flow solver, inflating
    # CY_beta, Cl_beta, Cn_beta by ~20×. The geometry-based DATCOM estimates
    # (VTP lift-curve + fuselage cross-flow) are far more reliable.
    CY_beta_deg = estimate_CY_beta_deg(input)
    Cn_beta_deg = estimate_Cn_beta_deg(input)
    Cl_beta_deg = estimate_Cl_beta_deg(input)

    # Lateral CD90 for CY flat-plate at extreme sideslip
    CD90_lat = estimate_CD90_lateral(input, CD90)

    # ---- DATCOM-style VTP/body decomposition for Cn and Cl ----
    # Separate the total derivative into VTP (stabilizing, stalls at high β)
    # and body (destabilizing, cross-flow at high β) contributions.
    Cn_body_deg = estimate_Cn_body_contribution(input)  # destabilizing (positive for std convention)
    Cn_vtp_deg  = Cn_beta_deg - Cn_body_deg             # VTP stabilizing (remainder)

    Cl_body_deg = estimate_Cl_body_contribution(input)  # destabilizing
    Cl_vtp_deg  = Cl_beta_deg - Cl_body_deg             # wing dihedral + VTP (remainder)

    # ---- Build full coefficient tables ----
    n_alpha = length(full_alphas)
    n_beta  = length(full_betas)

    CL_full = zeros(n_alpha, n_beta)
    CD_full = zeros(n_alpha, n_beta)
    CY_full = zeros(n_alpha, n_beta)
    Cm_full = zeros(n_alpha, n_beta)
    Cl_full = zeros(n_alpha, n_beta)
    Cn_full = zeros(n_alpha, n_beta)

    for (ai, α_deg) in enumerate(full_alphas)
        for (bi, β_deg) in enumerate(full_betas)
            CL_full[ai, bi] = envelope_CL(α_deg;
                CL_alpha_deg = derivs["CL_alpha_deg"],
                CL0          = derivs["CL0"],
                CL_max       = CL_max,
                α_stall_pos  = α_stall_pos,
                α_stall_neg  = abs(α_stall_neg),
                CD90         = CD90)

            CD_full[ai, bi] = envelope_CD(α_deg, β_deg;
                CL   = CL_full[ai, bi],
                CD0  = CD0,
                CD90 = CD90,
                K_induced = K_induced)

            CY_full[ai, bi] = envelope_CY(α_deg, β_deg;
                CY_beta_deg  = CY_beta_deg,
                CD90_lat     = CD90_lat,
                β_stall_vtp  = β_stall_vtp)

            Cm_full[ai, bi] = envelope_Cm(α_deg;
                Cm_alpha_deg = derivs["Cm_alpha_deg"],
                Cm0          = derivs["Cm0"],
                α_stall      = α_stall_pos)

            Cl_full[ai, bi] = envelope_Cl(α_deg, β_deg;
                Cl_vtp_deg   = Cl_vtp_deg,
                Cl_body_deg  = Cl_body_deg,
                CD90_lat     = CD90_lat,
                β_stall_vtp  = β_stall_vtp)

            Cn_full[ai, bi] = envelope_Cn(α_deg, β_deg;
                Cn_vtp_deg   = Cn_vtp_deg,
                Cn_body_deg  = Cn_body_deg,
                CD90_lat     = CD90_lat,
                β_stall_vtp  = β_stall_vtp)
        end
    end

    # Preserve VLM subsidiary data if available, otherwise use empty defaults
    dyn_derivs  = has_vlm ? vlm_results["dynamic_derivatives"]  : Dict{String,Any}()
    ctrl_derivs = has_vlm ? vlm_results["control_derivatives"]  : Dict{String,Any}()
    psd         = has_vlm ? vlm_results["per_surface_data"]      : Dict{String,Any}()
    vlm_mesh    = has_vlm ? get(vlm_results, "vlm_mesh", Any[]) : Any[]
    vlm_alphas  = has_vlm ? vlm_results["alphas_deg"]            : full_alphas
    vlm_betas   = has_vlm ? vlm_results["betas_deg"]             : full_betas

    # ───── v3.0 split-block full-envelope extension ─────
    split_blocks = extend_split_blocks(
        input, vlm_results, full_alphas, full_betas,
        CL_full, CD_full, CY_full, Cl_full, Cm_full, Cn_full
    )

    return Dict(
        "static" => Dict(
            "CL" => CL_full, "CD" => CD_full, "CY" => CY_full,
            "Cl" => Cl_full, "Cm" => Cm_full, "Cn" => Cn_full
        ),
        "alphas_deg" => full_alphas,
        "betas_deg"  => full_betas,
        "dynamic_derivatives"  => dyn_derivs,
        "control_derivatives"  => ctrl_derivs,
        "per_surface_data"     => psd,
        "vlm_mesh"             => vlm_mesh,
        # Preserve VLM-range axes so per_surface_data axis metadata stays correct
        "vlm_alphas_deg" => vlm_alphas,
        "vlm_betas_deg"  => vlm_betas,
        # v3.0 split blocks extended to the full ±180° grid
        "wing_body"    => split_blocks["wing_body"],
        "tail"         => split_blocks["tail"],
        "interference" => split_blocks["interference"]
    )
end

"""
    extend_split_blocks(input, vlm_results, full_alphas, full_betas,
                        CL_full, CD_full, CY_full, Cl_full, Cm_full, Cn_full,
                        ...) -> Dict

Build the full-envelope wing_body / tail / interference blocks.

Physics:
  * wing_body contribution = whole-aircraft envelope − estimated tail contribution.
    The tail share of Cm_α is large (that is what makes the aircraft stable);
    subtracting it from the whole-aircraft envelope gives the wb-alone curves.
  * Per-tail-surface contribution uses the same envelope models (linear →
    stall → flat plate) but evaluated in local tail angles α_h = α − ε and
    β_v = β − σ, and scaled by S_tail/S_ref.
  * interference ε(α), σ(β), η_h(α), η_v(β) come from VLM when available,
    otherwise from the classical DATCOM dε/dα formula.
"""
function extend_split_blocks(
    input::AircraftInput, vlm_results, full_alphas, full_betas,
    CL_full, CD_full, CY_full, Cl_full, Cm_full, Cn_full
)
    has_vlm = !isnothing(vlm_results) && vlm_results isa Dict
    n_alpha = length(full_alphas)
    n_beta  = length(full_betas)

    # ---------- Tail geometry catalogue ----------
    tail_surfaces = [(k, s) for (k, s) in enumerate(input.lifting_surfaces)
                     if classify_role(s.role) != :wing_body]

    # ---------- Interference tables on the FULL grid ----------
    ε_full = zeros(n_alpha)        # downwash(α) [deg], β=0
    σ_full = zeros(n_beta)         # sidewash(β) [deg], α=0
    η_h_full = fill(1.0, n_alpha)
    η_v_full = fill(1.0, n_beta)

    if has_vlm && haskey(vlm_results, "interference")
        # Linear-interp VLM narrow-range interference onto the full grid.
        ifd = vlm_results["interference"]
        α_limit = maximum(abs.(full_alphas))
        β_limit = maximum(abs.(full_betas))
        # Outside the narrow VLM range, the coherent wing wake should relax away:
        # downwash / sidewash fade back to zero and the tail dynamic-pressure
        # ratios recover toward free-stream (η → 1). Holding the edge values
        # constant all the way to ±180° exaggerated tail drag in reverse flow.
        ε_full   = interp_1d_relax_outside(full_alphas, ifd["downwash_deg"]["alpha_deg"], ifd["downwash_deg"]["values"];
                                           farfield_value=0.0, farfield_abs=α_limit)
        σ_full   = interp_1d_relax_outside(full_betas,  ifd["sidewash_deg"]["beta_deg"],  ifd["sidewash_deg"]["values"];
                                           farfield_value=0.0, farfield_abs=β_limit)
        η_h_full = interp_1d_relax_outside(full_alphas, ifd["eta_h"]["alpha_deg"],        ifd["eta_h"]["values"];
                                           farfield_value=1.0, farfield_abs=α_limit)
        η_v_full = interp_1d_relax_outside(full_betas,  ifd["eta_v"]["beta_deg"],         ifd["eta_v"]["values"];
                                           farfield_value=1.0, farfield_abs=β_limit)
    else
        # Analytic dε/dα fallback (Roskam).
        wing_idx = findfirst(s -> classify_role(s.role) == :wing_body &&
                                  occursin("wing", lowercase(s.name)), input.lifting_surfaces)
        htp = isempty(tail_surfaces) ? nothing :
              first(filter(ts -> classify_role(ts[2].role) == :tail_h, tail_surfaces))
        if wing_idx !== nothing && htp !== nothing
            wing = input.lifting_surfaces[wing_idx]
            deda = 4.44 * ((1.0/max(wing.AR,0.5) - 1.0/(1.0+wing.AR^1.7)) *
                           ((10 - 3*wing.TR)/7) *
                           sqrt(max(cos(deg2rad(wing.sweep_quarter_chord_DEG)), 0.01)))^1.19
            for (ai, α) in enumerate(full_alphas)
                ε_full[ai] = clamp(rad2deg(deda * deg2rad(α)), -15.0, 15.0)
                η_h_full[ai] = clamp(0.95 - 0.15 * sin(deg2rad(α))^2, 0.6, 1.0)
            end
        end
        for (bi, β) in enumerate(full_betas)
            σ_full[bi]   = 0.1 * β
            η_v_full[bi] = clamp(0.95 - 0.10 * sin(deg2rad(β))^2, 0.7, 1.0)
        end
    end

    # ---------- Per-tail-surface envelope coefficients (local angles) ----------
    tail_entries = Vector{Dict{String,Any}}()
    # Running totals of tail contribution to the whole-aircraft coefficients
    # (referenced back at CoG, in aircraft α,β) so we can subtract them to
    # recover wing+body alone.
    CL_tail_total = zeros(n_alpha, n_beta)
    CD_tail_total = zeros(n_alpha, n_beta)
    CY_tail_total = zeros(n_alpha, n_beta)
    Cl_tail_total = zeros(n_alpha, n_beta)
    Cm_tail_total = zeros(n_alpha, n_beta)
    Cn_tail_total = zeros(n_alpha, n_beta)

    Sref = input.general.Sref
    cref = input.general.cref
    bref = input.general.bref
    cog  = input.general.CoG

    for (k, surf) in tail_surfaces
        comp = classify_role(surf.role)
        S_ratio = surf.surface_area_m2 / Sref
        ac      = surface_aerodynamic_center(surf)
        arm_m   = ac .- cog

        # Local lift-curve slope for the isolated tail surface (Helmbold).
        AR_t = surf.AR
        CLa_t_rad = 2π * AR_t / (2 + sqrt(4 + AR_t^2))    # per radian
        CLa_t_deg = CLa_t_rad * π / 180                   # per degree

        # Per-surface envelope tables, stored in LOCAL α_h / β_v.
        # We use the SAME full_alphas/full_betas arrays as the axis, but the
        # stored values are what the tail sees at that LOCAL angle; the
        # simulator does α_h = α − ε(α) before looking up.
        CL_t   = zeros(n_alpha, n_beta)
        CD_t   = zeros(n_alpha, n_beta)
        CY_t   = zeros(n_alpha, n_beta)
        Cl_AC  = zeros(n_alpha, n_beta)
        Cm_AC  = zeros(n_alpha, n_beta)
        Cn_AC  = zeros(n_alpha, n_beta)

        # Tail-specific stall: assume ±15° for HTP, ±20° for VTP (sharper than wing).
        α_t_stall = comp == :tail_h ? 15.0 : 20.0
        CL_t_max  = CLa_t_deg * α_t_stall * 0.9
        CD0_t     = 0.012
        CD90_t    = 1.2

        for (ai, αloc_deg) in enumerate(full_alphas)
            for (bi, βloc_deg) in enumerate(full_betas)
                # Which local angle is the 'driving' angle depends on surface type.
                if comp == :tail_h
                    # HTP: lifts from αloc, drags in any relative flow.
                    cl = envelope_CL(αloc_deg;
                        CL_alpha_deg=CLa_t_deg, CL0=0.0,
                        CL_max=CL_t_max, α_stall_pos=α_t_stall,
                        α_stall_neg=α_t_stall, CD90=CD90_t)
                    cd = envelope_CD(αloc_deg, βloc_deg;
                        CD0=CD0_t, CD90=CD90_t)
                    cy = 0.0
                elseif comp == :tail_v
                    # VTP: sideforce from βloc, small drag.
                    cl = 0.0
                    cd = envelope_CD(αloc_deg, βloc_deg;
                        CD0=CD0_t, CD90=CD90_t)
                    # Treat VTP side force using envelope_CY with its own stall.
                    cy = envelope_CY(αloc_deg, βloc_deg;
                        CY_beta_deg = -CLa_t_deg,         # sign: +β → −CY for fin on CL plane
                        CD90_lat    = CD90_t,
                        β_stall_vtp = α_t_stall)
                else
                    cl = 0.0; cd = 0.0; cy = 0.0
                end

                # Scale to aircraft S_ref (forces were computed per-surface in the
                # tail's own local frame using its own area implicitly via CLa_t_deg
                # × local angle, which is a proper non-dim coefficient w.r.t. the
                # tail's OWN area. Multiply by S_tail/S_ref for aircraft reference).
                CL_t[ai,bi] = cl * S_ratio
                CD_t[ai,bi] = cd * S_ratio
                CY_t[ai,bi] = cy * S_ratio

                # Moment at tail AC (per aircraft Sref) — pure geometric moment,
                # the translation to CoG happens in the simulator via r×F.
                # Here the per-surface moment at its own AC for a flat-plate-type
                # approximation is small relative to the r×F transfer; we leave it
                # at zero and rely on the simulator's r×F to produce the CoG moment.
                Cl_AC[ai,bi] = 0.0
                Cm_AC[ai,bi] = 0.0
                Cn_AC[ai,bi] = 0.0
            end
        end

        push!(tail_entries, Dict{String,Any}(
            "name" => surf.name,
            "role" => surf.role,
            "component" => String(comp),
            "arm_m" => collect(Float64, arm_m),
            "ac_xyz_m" => collect(Float64, ac),
            "CL" => CL_t, "CD" => CD_t, "CY" => CY_t,
            "Cl_at_AC" => Cl_AC, "Cm_at_AC" => Cm_AC, "Cn_at_AC" => Cn_AC
        ))

        # Accumulate tail contribution to whole-aircraft coefficients for wb back-out.
        # Convert local α_h → α: tail sees α_h = α − ε, so at given aircraft α
        # the tail's contribution should be evaluated at the corresponding
        # LOCAL tail angle. Use bilinear interpolation rather than nearest-
        # neighbour lookup to avoid visible Cm kinks in the reconstructed
        # wing+body block around trim and stall onset.
        for (ai, α) in enumerate(full_alphas)
            α_h = α - ε_full[ai]
            for (bi, β) in enumerate(full_betas)
                β_v = β - σ_full[bi]
                ηh = η_h_full[ai]; ηv = η_v_full[bi]
                α_local = comp == :tail_h ? α_h : α
                β_local = comp == :tail_v ? β_v : β
                η_local = comp == :tail_h ? ηh : ηv
                CL_local = interp2_bilinear_clamped(full_alphas, full_betas, CL_t, α_local, β_local)
                CD_local = interp2_bilinear_clamped(full_alphas, full_betas, CD_t, α_local, β_local)
                CY_local = interp2_bilinear_clamped(full_alphas, full_betas, CY_t, α_local, β_local)
                CL_tail_total[ai,bi] += η_local * CL_local
                CD_tail_total[ai,bi] += η_local * CD_local
                CY_tail_total[ai,bi] += η_local * CY_local

                # r × F contribution to CoG moment, non-dim (S_ratio already
                # baked into CL_t / CD_t / CY_t — do not re-scale). Small-α
                # approximation: wind frame ≈ body frame for moment assembly.
                Fx = CD_local
                Fy = CY_local
                Fz = CL_local
                rx, ry, rz = arm_m[1], arm_m[2], arm_m[3]
                Cl_tail_total[ai,bi] += η_local * ( ry*Fz - rz*Fy) / bref
                Cm_tail_total[ai,bi] += η_local * ( rz*Fx - rx*Fz) / cref
                Cn_tail_total[ai,bi] += η_local * ( rx*Fy - ry*Fx) / bref
            end
        end
    end

    # ---------- Wing+body block: whole-aircraft envelope minus tail share ----------
    CL_wb = CL_full .- CL_tail_total
    CD_wb = CD_full .- CD_tail_total
    CY_wb = CY_full .- CY_tail_total
    Cl_wb = Cl_full .- Cl_tail_total
    Cm_wb = Cm_full .- Cm_tail_total
    Cn_wb = Cn_full .- Cn_tail_total

    wing_body_ref_default = copy(cog)
    wing_surface_idx = findfirst(s -> classify_role(s.role) == :wing_body &&
                                      occursin("wing", lowercase(s.name)), input.lifting_surfaces)
    if wing_surface_idx !== nothing
        wing_body_ref_default = surface_aerodynamic_center(input.lifting_surfaces[wing_surface_idx])
    end
    # Use the physical wing/body aerodynamic center as the component reference.
    # Backing out Cm as total-minus-tail and then solving for a neutral point is
    # very sensitive to small model inconsistencies; it can create nonphysical
    # Cm spikes near alpha=0.  Keep the reference at the wing/body AC and use a
    # direct smooth Cm_ac model for the isolated wing+body block.
    wing_body_ref_xyz = wing_body_ref_default
    r_cg_to_wb_ref = wing_body_ref_xyz .- cog
    Cm_wb_ac = wing_body_ac_pitching_moment_table(input, full_alphas, full_betas)
    Cl_wb_ref = similar(Cl_wb)
    Cm_wb_ref = similar(Cm_wb)
    Cn_wb_ref = similar(Cn_wb)
    for ai in 1:n_alpha, bi in 1:n_beta
        CM_wb_ref = translate_moment_coefficients(
            [CD_wb[ai, bi], CY_wb[ai, bi], CL_wb[ai, bi]],
            [Cl_wb[ai, bi], Cm_wb[ai, bi], Cn_wb[ai, bi]],
            r_cg_to_wb_ref,
            cref,
            bref
        )
        Cl_wb_ref[ai, bi] = CM_wb_ref[1]
        Cm_wb_ref[ai, bi] = Cm_wb_ac[ai, bi]
        Cn_wb_ref[ai, bi] = CM_wb_ref[3]
    end

    wing_body_block = Dict{String,Any}(
        "static" => Dict(
            "CL" => CL_wb, "CD" => CD_wb, "CY" => CY_wb,
            "Cl" => Cl_wb_ref, "Cm" => Cm_wb_ref, "Cn" => Cn_wb_ref
        ),
        "reference_point_m" => Dict(
            "kind" => "aerodynamic_center",
            "xyz_m" => wing_body_ref_xyz
        ),
        "alphas_deg" => full_alphas,
        "betas_deg"  => full_betas
    )

    tail_block = Dict{String,Any}(
        "surfaces" => tail_entries,
        "alphas_deg" => full_alphas,
        "betas_deg"  => full_betas
    )

    interference_block = Dict{String,Any}(
        "downwash_deg" => Dict("alpha_deg" => full_alphas, "values" => ε_full),
        "sidewash_deg" => Dict("beta_deg"  => full_betas,  "values" => σ_full),
        "eta_h"        => Dict("alpha_deg" => full_alphas, "values" => η_h_full),
        "eta_v"        => Dict("beta_deg"  => full_betas,  "values" => η_v_full),
        "source"       => has_vlm ? "vlm_interp" : "analytic"
    )

    return Dict(
        "wing_body"    => wing_body_block,
        "tail"         => tail_block,
        "interference" => interference_block
    )
end

# ---- small helpers used by extend_split_blocks ----
function interp_1d_preserve_outside(xq::AbstractVector, xs::AbstractVector, ys::AbstractVector)
    out = similar(xq, Float64)
    for (i, x) in enumerate(xq)
        if x <= xs[1]
            out[i] = ys[1]
        elseif x >= xs[end]
            out[i] = ys[end]
        else
            j = searchsortedlast(xs, x)
            t = (x - xs[j]) / (xs[j+1] - xs[j])
            out[i] = (1-t)*ys[j] + t*ys[j+1]
        end
    end
    return out
end

smoothstep01(t::Real) = t <= 0 ? 0.0 : (t >= 1 ? 1.0 : t * t * (3.0 - 2.0 * t))

function relax_to_farfield(x::Real, x_edge::Float64, y_edge::Float64,
                           x_far::Float64, y_far::Float64)
    abs(x_far - x_edge) <= 1e-9 && return y_far
    t = smoothstep01((Float64(x) - x_edge) / (x_far - x_edge))
    return (1.0 - t) * y_edge + t * y_far
end

function interp_1d_relax_outside(xq::AbstractVector, xs::AbstractVector, ys::AbstractVector;
                                 farfield_value::Float64=0.0,
                                 farfield_abs::Float64=180.0)
    out = similar(xq, Float64)
    x_min = Float64(xs[1])
    x_max = Float64(xs[end])
    y_min = Float64(ys[1])
    y_max = Float64(ys[end])
    x_far_neg = -abs(farfield_abs)
    x_far_pos = abs(farfield_abs)

    for (i, x) in enumerate(xq)
        if x <= x_min
            out[i] = relax_to_farfield(x, x_min, y_min, x_far_neg, farfield_value)
        elseif x >= x_max
            out[i] = relax_to_farfield(x, x_max, y_max, x_far_pos, farfield_value)
        else
            j = searchsortedlast(xs, x)
            t = (x - xs[j]) / (xs[j+1] - xs[j])
            out[i] = (1 - t) * ys[j] + t * ys[j+1]
        end
    end
    return out
end

function closest_index(xs::AbstractVector, x::Real)
    # Clamped nearest-neighbour into xs.
    if x <= xs[1]; return firstindex(xs); end
    if x >= xs[end]; return lastindex(xs); end
    j = searchsortedlast(xs, x)
    return (x - xs[j]) <= (xs[j+1] - x) ? j : j+1
end

function interp_axis_bracket(xs::AbstractVector, x::Real)
    n = length(xs)
    n == 0 && error("Cannot interpolate on an empty axis")
    if n == 1 || x <= xs[1]
        return (1, 1, 0.0)
    elseif x >= xs[end]
        return (n, n, 0.0)
    end
    j = searchsortedlast(xs, x)
    x1 = Float64(xs[j])
    x2 = Float64(xs[j + 1])
    t = abs(x2 - x1) <= 1e-9 ? 0.0 : (Float64(x) - x1) / (x2 - x1)
    return (j, j + 1, clamp(t, 0.0, 1.0))
end

function interp2_bilinear_clamped(xs::AbstractVector, ys::AbstractVector,
                                  table::AbstractMatrix, x::Real, y::Real)
    i1, i2, tx = interp_axis_bracket(xs, x)
    j1, j2, ty = interp_axis_bracket(ys, y)

    q11 = Float64(table[i1, j1])
    q12 = Float64(table[i1, j2])
    q21 = Float64(table[i2, j1])
    q22 = Float64(table[i2, j2])

    qx1 = (1.0 - tx) * q11 + tx * q21
    qx2 = (1.0 - tx) * q12 + tx * q22
    return (1.0 - ty) * qx1 + ty * qx2
end

# ================================================================
# Extract VLM linear derivatives
# ================================================================

"""
Extract linear slopes and zero-angle values from VLM small-angle data.
"""
function extract_vlm_linear_derivatives(vlm_results::Dict)
    alphas = vlm_results["alphas_deg"]
    betas  = vlm_results["betas_deg"]
    st     = vlm_results["static"]

    α0 = argmin(abs.(alphas))
    β0 = argmin(abs.(betas))

    return Dict(
        "CL_alpha_deg" => fd_at(alphas, st["CL"][:, β0], α0),
        "CL0"          => st["CL"][α0, β0],
        "CD0_vlm"      => st["CD"][α0, β0],
        "CY_beta_deg"  => fd_at(betas,  st["CY"][α0, :], β0),
        "Cm_alpha_deg" => fd_at(alphas, st["Cm"][:, β0], α0),
        "Cm0"          => st["Cm"][α0, β0],
        "Cl_beta_deg"  => fd_at(betas,  st["Cl"][α0, :], β0),
        "Cn_beta_deg"  => fd_at(betas,  st["Cn"][α0, :], β0)
    )
end

"""
Estimate all linear derivatives from aircraft geometry alone (no VLM data).
Used when VLM backend didn't run or failed.
"""
function estimate_all_derivatives_from_geometry(input::AircraftInput)
    # CL_alpha from wing Helmbold equation
    CL_alpha_rad = 0.0
    for surf in input.lifting_surfaces
        if surf.role == "wing"
            AR = surf.AR
            CL_alpha_rad = 2π * AR / (2 + sqrt(4 + AR^2))
            break
        end
    end
    if CL_alpha_rad == 0.0 && !isempty(input.lifting_surfaces)
        AR = input.lifting_surfaces[1].AR
        CL_alpha_rad = 2π * AR / (2 + sqrt(4 + AR^2))
    end
    CL_alpha_deg = CL_alpha_rad * π / 180

    # Cm_alpha and Cm0 from TOTAL AIRCRAFT (wing + horizontal tail).
    # The wing contribution alone is typically destabilising (wing AC aft of
    # CG → positive Cm_alpha). The tail is what makes the aircraft stable
    # (large negative Cm_alpha from tail lift acting behind the CG).
    # Omitting the tail gives a wing+body-only result that is almost always
    # statically unstable — which is why the old code produced nonsensical
    # validation errors.
    x_cg  = input.general.CoG[1]
    cref  = input.general.cref
    Sref  = input.general.Sref

    # --- Wing contribution ---
    Cm_alpha_deg_wing = 0.0
    CL0 = 0.0
    Cm0 = 0.0
    for surf in input.lifting_surfaces
        if surf.role == "wing"
            wp = wing_planform(surf)
            x_ac_wing = surf.root_LE[1] + 0.25 * wp.mac
            Cm_alpha_deg_wing = -CL_alpha_deg * (x_ac_wing - x_cg) / cref

            # CL0 from camber + incidence
            max_camber = surf.airfoil.root_max_camber
            alpha_0L_rad = -2.0 * max_camber
            incidence_rad = deg2rad(surf.incidence_DEG)
            CL0 = CL_alpha_rad * (incidence_rad - alpha_0L_rad)
            # Cm_ac from camber (thin-airfoil: Cm_ac ≈ −π/2 · m)
            Cm0 = -π / 2 * max_camber
            break
        end
    end

    # --- Horizontal tail contribution ---
    Cm_alpha_deg_tail = 0.0
    Cm0_tail = 0.0
    for surf in input.lifting_surfaces
        if surf.role == "horizontal_stabilizer"
            AR_h = surf.AR
            CL_alpha_tail_rad = 2π * AR_h / (2 + sqrt(4 + AR_h^2))
            S_tail = surf.surface_area_m2
            x_ac_tail = surf.root_LE[1] + 0.25 * surf.mean_aerodynamic_chord_m
            tail_volume = (S_tail / Sref) * (x_ac_tail - x_cg) / cref
            η_tail = 0.90   # tail efficiency (wake + downwash reduction)

            # Cm_alpha from tail: negative (stabilising) when tail is behind CG
            Cm_alpha_deg_tail = -CL_alpha_tail_rad * (π / 180) * η_tail * tail_volume

            # Cm0 from tail incidence: tail at negative incidence pushes
            # down → positive (nose-up) Cm0 contribution
            incidence_tail_rad = deg2rad(surf.incidence_DEG)
            CL_0_tail = CL_alpha_tail_rad * incidence_tail_rad
            Cm0_tail = -CL_0_tail * η_tail * tail_volume
            break
        end
    end

    Cm_alpha_deg = Cm_alpha_deg_wing + Cm_alpha_deg_tail
    Cm0 = Cm0 + Cm0_tail

    return Dict(
        "CL_alpha_deg" => CL_alpha_deg,
        "CL0"          => CL0,
        "CD0_vlm"      => 0.0,   # will fall back to JSON value
        "CY_beta_deg"  => 0.0,   # will fall back to geometry estimate
        "Cm_alpha_deg" => Cm_alpha_deg,
        "Cm0"          => Cm0,
        "Cl_beta_deg"  => 0.0,   # will fall back to geometry estimate
        "Cn_beta_deg"  => 0.0    # will fall back to geometry estimate
    )
end

"""Central finite difference at index `idx`."""
function fd_at(x::Vector{Float64}, y::AbstractVector, idx::Int)
    n = length(y)
    if n < 2 || idx < 1 || idx > n
        return 0.0
    end
    if idx == 1
        dx = x[2] - x[1]
        return abs(dx) > 1e-10 ? (y[2] - y[1]) / dx : 0.0
    elseif idx == n
        dx = x[n] - x[n-1]
        return abs(dx) > 1e-10 ? (y[n] - y[n-1]) / dx : 0.0
    else
        dx = x[idx+1] - x[idx-1]
        return abs(dx) > 1e-10 ? (y[idx+1] - y[idx-1]) / dx : 0.0
    end
end

# ================================================================
# Full-envelope coefficient models
# ================================================================

"""
Full-envelope CL(α).
  Pre-stall : CL = CL0 + CL_α · α  (linear)
  At stall  : CL peaks at CL_max
  Post-stall: exponential decay from peak to flat plate CD90·sin(α)·cos(α)
  At α = 90°: CL → 0  (flat plate edge-on)
  At α = 180°: CL → 0  (inverted zero-AoA)
"""
function envelope_CL(α_deg; CL_alpha_deg, CL0, CL_max, α_stall_pos, α_stall_neg, CD90)
    α = deg2rad(α_deg)

    # Flat plate lift: normal force resolved into lift direction
    CL_fp = CD90 * sin(α) * cos(α)

    # Choose stall angle based on sign
    α_s = α_deg >= 0 ? α_stall_pos : α_stall_neg

    if abs(α_deg) <= α_s
        # Attached flow: linear
        return CL0 + CL_alpha_deg * α_deg
    else
        # Post-stall: exponential blend from stall peak to flat plate
        CL_at_stall = CL0 + CL_alpha_deg * sign(α_deg) * α_s
        CL_peak = sign(α_deg) * max(abs(CL_at_stall), CL_max)
        Δ = abs(α_deg) - α_s
        decay = exp(-Δ / 20.0)   # 20° e-folding distance
        return CL_peak * decay + CL_fp * (1 - decay)
    end
end

"""
Full-envelope CD(α, β).
  CD = CD0 + K·CL² + (CD90 − CD0)·sin²(α) + cross-flow from sideslip + reverse-flow drag.
  At α = 0°: CD includes normal induced drag from lift.  At α = 90°:
  CD ≈ CD90.  At α or β = ±180° the drag stays above CD0 so reverse flow is
  not treated like clean forward flow.
"""
function envelope_CD(α_deg, β_deg; CL=0.0, CD0, CD90, K_induced=0.0)
    α = deg2rad(α_deg)
    β = deg2rad(β_deg)
    attached_blend = cos(α)^2 * cos(β)^2
    CD_induced = max(K_induced, 0.0) * CL^2 * clamp(attached_blend, 0.0, 1.0)
    CD_alpha = CD0 + CD_induced + (CD90 - CD0) * sin(α)^2
    CD_beta  = CD90 * 0.5 * sin(β)^2          # additional drag from sideslip
    reverse_blend = max(sin(α / 2)^8, sin(β / 2)^8)
    CD_reverse = max(0.06, 2.0 * CD0, 0.12 * CD90) * reverse_blend
    return CD_alpha + CD_beta + CD_reverse
end

"""
Full-envelope CY(α, β).
  Linear near origin (dominated by vertical tail), transitions to
  flat-plate cross-flow at extreme sideslip or high AoA.
"""
function envelope_CY(α_deg, β_deg; CY_beta_deg, CD90_lat, β_stall_vtp=20.0)
    α = deg2rad(α_deg)
    β = deg2rad(β_deg)

    β_crit = β_stall_vtp   # linear regime limit from VTP geometry

    # Flat plate / cross-flow side force.  At β=90° the fuselage is
    # broadside to the flow and the side force should be at its MAXIMUM
    # (≈ CD90_lat × S_lat/S_wing × sin(β)).  The old sin(β)·cos(β) model
    # zeroed out at β=90° — physically wrong.  Using sin(β) alone gives
    # the correct peak at ±90° and zero at 0° and ±180°.
    CY_fp = -CD90_lat * sin(β)

    if abs(β_deg) <= β_crit
        # Linear regime
        CY_lin = CY_beta_deg * β_deg
        # At high AoA, VTP loses effectiveness → cross-flow dominates
        α_blend = clamp(abs(α_deg) / 45.0, 0.0, 1.0)
        return CY_lin * (1 - α_blend^2) + CY_fp * α_blend^2
    else
        # Beyond critical sideslip: decay from linear peak to flat plate
        CY_peak = CY_beta_deg * sign(β_deg) * β_crit
        Δ = abs(β_deg) - β_crit
        decay = exp(-Δ / 20.0)
        return CY_peak * decay + CY_fp * (1 - decay)
    end
end

"""
Full-envelope Cm(α).
  Linear pre-stall, decays post-stall toward the flat-plate moment.

At extreme α the wing acts as a flat plate: the normal force
coefficient is CN ≈ CD90 · sin(α) (≈ 1.2 at α=90°), and the pressure
centre migrates from ~25 % chord back toward ~50 % chord. About the
quarter-chord aerodynamic-reference this produces a pitching moment

    Cm_fp(α) ≈ -(x_cp − x_ac)/c · CN ≈ -0.25 · CD90 · sin(α)
             ≈ -0.30 · sin(α)                  (CD90 ≈ 1.2)

Nose-down for positive α (aircraft pitched up into the wind, CP aft
of the AC pushes the nose back down), nose-up for negative α.
"""
function envelope_Cm(α_deg; Cm_alpha_deg, Cm0, α_stall)
    α = deg2rad(α_deg)
    α_s = abs(α_stall)

    # Reverse-flow tailplane destabilisation pulse.
    # In backwards flight (α near ±180°) the horizontal stabiliser sits
    # ahead of the CG in the FLOW direction. Its reverse-flow lift
    # produces a pitching moment that pushes α AWAY from ±180°, so
    # purely backwards trim is statically unstable in pitch — the
    # opposite of the (stabilising) HTP behaviour at α near 0.
    # Functional form: Gaussian-derivative pulse with dCm/dα = +K_rev_cm
    # at α = ±180° (so the linearised system is unstable there) and
    # magnitude peaks at α_rev = ±scale_rev/√2 ≈ ±10.6°, i.e. at
    # α ≈ ±169.4°. Negligible (<1e-4) anywhere outside |α| ≳ 140°, so
    # forward-flight, stall, and post-stall behaviour are unchanged.
    α_rev = deg2rad(α_deg - sign(α_deg) * 180.0)
    K_rev_cm = 1.0
    scale_rev = deg2rad(15.0)
    Cm_rev_pulse = K_rev_cm * α_rev * exp(-(α_rev / scale_rev)^2)

    if abs(α_deg) <= α_s
        return Cm0 + Cm_alpha_deg * α_deg + Cm_rev_pulse
    else
        Cm_stall = Cm0 + Cm_alpha_deg * sign(α_deg) * α_s
        Δ = abs(α_deg) - α_s
        decay = exp(-Δ / 25.0)
        # Flat-plate (post-stall) pitching moment.
        #
        # Physical bound: pre-HTP-stall the total Cm is dominated by the
        # tail's restoring moment, peaking at |Cm_stall| ≈ |Cm_α · α_stall|.
        # Once the HTP stalls, the tail no longer generates that restoring
        # force, and only the wing+body cross-flow remains. The post-stall
        # peak therefore must be SMALLER than the pre-stall peak — the
        # opposite of the prior model, which used Cm_fp_peak = -0.30 and
        # made |Cm| at α=±90° (~0.30) two-to-three times larger than the
        # pre-stall value (~0.13), an unphysical jump the user flagged on
        # the Cm-vs-α chart.
        #
        # Cap the flat-plate peak at half the pre-stall stall value so the
        # post-stall plateau sits clearly below the pre-stall maximum
        # while still providing some restoring moment in the broadside
        # region. Floor of 0.05 keeps the curve smooth for trivially-low
        # Cm_α inputs.
        Cm_fp_peak = -max(0.5 * abs(Cm_stall), 0.05)
        Cm_fp = Cm_fp_peak * sin(α) * abs(sin(α))
        return Cm_stall * decay + Cm_fp * (1 - decay) + Cm_rev_pulse
    end
end

"""
Full-envelope Cl(α, β) — DATCOM-style decomposition.

Components:
  1. **Wing dihedral + VTP** (Cl_vtp_deg): linear at small β, effectiveness
     decays as wing stalls and VTP blanks at high sideslip.
  2. **Body cross-flow** (Cl_body_deg): fuselage asymmetric vortex shedding
     at high β generates a roll moment modelled by Munk slender-body theory
     as proportional to sin(2β).

The total derivative Cl_β = Cl_vtp + Cl_body is recovered at β → 0.
"""
function envelope_Cl(α_deg, β_deg; Cl_vtp_deg, Cl_body_deg, CD90_lat=1.0, β_stall_vtp=22.0)
    α = deg2rad(α_deg)
    β = deg2rad(β_deg)
    cos2α = cos(α)^2

    # --- VTP + dihedral contribution (stalls at high β) ---
    β_stall_cl = β_stall_vtp + 2.0

    if abs(β_deg) <= β_stall_cl
        Cl_vtp = Cl_vtp_deg * β_deg * cos2α
    else
        Cl_peak = Cl_vtp_deg * sign(β_deg) * β_stall_cl * cos2α
        Δ = abs(β_deg) - β_stall_cl
        Cl_vtp = Cl_peak * exp(-Δ / 18.0)
    end

    # --- Body cross-flow contribution ---
    # 1. Munk slender-body ∝ sin(2β): peaks at 45°, zero at 90°.
    K_cl_munk = Cl_body_deg * (π / 180.0) / 2.0
    Cl_munk = K_cl_munk * sin(2.0 * β)

    # 2. Cross-flow drag roll moment ∝ sin(β)|sin(β)|: peaks at 90°.
    #    At high β the lateral cross-flow drag on the fuselage acts at
    #    a height offset from the roll axis (typically above the CG for
    #    low-wing aircraft), producing a rolling moment. The factor 0.03
    #    is smaller than the Cn cross-flow factor (0.08) because the
    #    vertical moment arm (height offset) is smaller than the
    #    longitudinal one (CG offset).
    #
    #    Same physical bound as Cn_crossflow: post-VTP-stall the only
    #    dihedral mechanism left is fuselage cross-flow, which must be
    #    SMALLER than the VTP-driven pre-stall peak. Cap at half the VTP
    #    stall peak.
    vtp_stall_cl_peak = abs(Cl_vtp_deg * β_stall_cl)
    K_cl_crossflow = min(CD90_lat * 0.03, 0.5 * vtp_stall_cl_peak)
    Cl_crossflow = K_cl_crossflow * sin(β) * abs(sin(β))

    Cl_body = Cl_munk + Cl_crossflow

    return Cl_vtp + Cl_body
end

"""
Full-envelope Cn(α, β) — DATCOM-style decomposition.

Components:
  1. **Vertical tail** (Cn_vtp_deg): stabilising, linear at small β.
     At |β| ≈ 20° the fin stalls (separated flow from the fuselage blanks
     the VTP), and its contribution decays exponentially.
  2. **Fuselage cross-flow** (Cn_body_deg): destabilising yaw moment from
     fuselage cross-flow drag, modelled via DATCOM Munk slender-body theory.
     Proportional to sin(2β) — peaks at 45° sideslip, returns to zero at 90°,
     and produces the characteristic S-shaped Cn(β) curve seen in wind-tunnel data.

The total derivative Cn_β = Cn_vtp + Cn_body is recovered at β → 0.
"""
function envelope_Cn(α_deg, β_deg; Cn_vtp_deg, Cn_body_deg, CD90_lat=1.0, β_stall_vtp=20.0)
    α = deg2rad(α_deg)
    β = deg2rad(β_deg)
    cos2α = cos(α)^2

    # --- Forward-flow VTP contribution (stabilising, stalls at high β) ---
    if abs(β_deg) <= β_stall_vtp
        Cn_vtp_fwd = Cn_vtp_deg * β_deg * cos2α
    else
        Cn_peak = Cn_vtp_deg * sign(β_deg) * β_stall_vtp * cos2α
        Δ = abs(β_deg) - β_stall_vtp
        Cn_vtp_fwd = Cn_peak * exp(-Δ / 15.0)
    end

    # --- Reverse-flow VTP contribution (active near β = ±180°) ---
    # Why: when the aircraft flies backwards, the relative wind hits the
    # VTP from the rear. The fin still generates side force (with reduced
    # lift slope, since TE is now LE), and the body-frame moment arm is
    # unchanged → the resulting Cn has the SAME sign as forward flight at
    # the equivalent local angle. Without this term, Cn collapsed to ~0
    # near β = ±180° and the aircraft could trim in pure backwards flight.
    β_rev_deg = β_deg - sign(β_deg) * 180.0   # local VTP angle in reverse-flow regime
    reverse_factor = 0.6   # reverse-flow lift-slope reduction (TE-as-LE flat plate)
    if abs(β_rev_deg) <= β_stall_vtp
        Cn_vtp_rev = -reverse_factor * Cn_vtp_deg * β_rev_deg * cos2α
    else
        Cn_peak_rev = -reverse_factor * Cn_vtp_deg * sign(β_rev_deg) * β_stall_vtp * cos2α
        Δ_rev = abs(β_rev_deg) - β_stall_vtp
        Cn_vtp_rev = Cn_peak_rev * exp(-Δ_rev / 15.0)
    end
    Cn_vtp = Cn_vtp_fwd + Cn_vtp_rev

    # --- Fuselage yaw moment: two physical regimes ---
    #
    # 1. Munk slender-body moment ∝ sin(2β): peaks at β=45°, zero at 90°.
    #    Valid for moderate β where potential-flow cross-flow dominates.
    K_cn_munk = Cn_body_deg * (π / 180.0) / 2.0
    Cn_munk = K_cn_munk * sin(2.0 * β)
    #
    # 2. Cross-flow drag yawing moment ∝ sin(β)|sin(β)|: peaks at β=90°.
    #    At high β the fuselage presents its full lateral projected area
    #    to the flow. The resulting pressure drag acts at the center of
    #    lateral pressure (CLP), which for a conventional aircraft is
    #    AFT of the CG — producing a RESTORING (weathervane) yawing
    #    moment. The amplitude is scaled from CD90_lat with empirical
    #    factor 0.08 ≈ CG-to-CLP arm / reference span.
    #    Positive sign: nose-into-wind (restoring) for positive β.
    #
    #    PHYSICAL BOUND: once the VTP has stalled, the dominant pre-stall
    #    yawing-moment source has been removed. The remaining fuselage
    #    cross-flow contribution must therefore be SMALLER than the VTP
    #    stall peak, otherwise Cn(β) would have a second peak at β=90°
    #    that is larger than the VTP-driven peak at β = β_stall_vtp — the
    #    unphysical shape the user flagged on the Cn-vs-β chart. Cap the
    #    cross-flow peak at half the VTP stall peak so the post-stall
    #    regime sits clearly below the pre-stall maximum.
    vtp_stall_cn_peak = abs(Cn_vtp_deg * β_stall_vtp)
    K_cn_crossflow = min(CD90_lat * 0.08, 0.5 * vtp_stall_cn_peak)
    Cn_crossflow = K_cn_crossflow * sin(β) * abs(sin(β))

    Cn_body = Cn_munk + Cn_crossflow

    return Cn_vtp + Cn_body
end

# ================================================================
# Geometry-based derivative estimates (fallbacks when VLM gives ~0)
# ================================================================

"""Estimate CY_β per degree from vertical tail + fuselage geometry."""
function estimate_CY_beta_deg(input::AircraftInput)
    Sref = input.general.Sref
    bref = input.general.bref
    CY_beta_rad = 0.0

    for surf in input.lifting_surfaces
        if surf.role == "vertical_stabilizer" || surf.vertical
            AR_vt = surf.AR
            a_vt = 2π * AR_vt / (2 + sqrt(4 + AR_vt^2))   # Helmbold
            CY_beta_rad -= a_vt * surf.surface_area_m2 / Sref
        end
    end

    for fus in input.fuselages
        Vol = π / 4 * fus.diameter^2 * fus.length
        CY_beta_rad -= 2 * Vol / (Sref * bref)
    end

    return CY_beta_rad * π / 180   # per degree
end

"""Estimate Cn_β per degree from VTP arm + fuselage destabilising contribution."""
function estimate_Cn_beta_deg(input::AircraftInput)
    Sref = input.general.Sref
    bref = input.general.bref
    cg_x = input.general.CoG[1]
    Cn_beta_rad = 0.0

    for surf in input.lifting_surfaces
        if surf.role == "vertical_stabilizer" || surf.vertical
            AR_vt = surf.AR
            a_vt = 2π * AR_vt / (2 + sqrt(4 + AR_vt^2))
            CY_beta_vt = -a_vt * surf.surface_area_m2 / Sref
            l_vt = surf.root_LE[1] + 0.25 * surf.mean_aerodynamic_chord_m - cg_x
            Cn_beta_rad -= CY_beta_vt * l_vt / bref
        end
    end

    for fus in input.fuselages
        Vol = π / 4 * fus.diameter^2 * fus.length
        Cn_beta_rad += Vol / (Sref * bref)   # fuselage is destabilising
    end

    return Cn_beta_rad * π / 180
end

"""Estimate Cl_β per degree from wing dihedral."""
function estimate_Cl_beta_deg(input::AircraftInput)
    Cl_beta_rad = 0.0

    for surf in input.lifting_surfaces
        if surf.role == "wing"
            CL_alpha_wing = 2π * surf.AR / (2 + sqrt(4 + surf.AR^2))
            dihedral_rad  = deg2rad(surf.dihedral_DEG)
            Cl_beta_rad  -= CL_alpha_wing * dihedral_rad * 0.5
            break
        end
    end

    return Cl_beta_rad * π / 180
end

"""
Estimate the fuselage-only (body) contribution to Cn_β (per degree).

DATCOM method: the fuselage is destabilising in yaw.  The Munk slender-body
cross-flow produces a yaw moment proportional to fuselage volume:
  Cn_β_body = +Vol / (S_ref · b_ref)  (per radian, positive = destabilising)

This is the same term already used inside `estimate_Cn_beta_deg`, extracted
separately so the envelope function can apply nonlinear cross-flow physics.
"""
function estimate_Cn_body_contribution(input::AircraftInput)
    Sref = input.general.Sref
    bref = input.general.bref
    Cn_body_rad = 0.0

    for fus in input.fuselages
        Vol = π / 4 * fus.diameter^2 * fus.length
        Cn_body_rad += Vol / (Sref * bref)   # destabilising (positive)
    end

    return Cn_body_rad * π / 180   # per degree
end

"""
Estimate the fuselage-only (body) contribution to Cl_β (per degree).

For roll moment, the fuselage cross-flow is generally small but becomes
significant at high sideslip.  Modelled as a fraction of the CY-derived
body contribution acting through a vertical offset of the fuselage centroid
from the CG.  Typically small for conventional layouts.
"""
function estimate_Cl_body_contribution(input::AircraftInput)
    Sref = input.general.Sref
    bref = input.general.bref
    cg_z = length(input.general.CoG) >= 3 ? input.general.CoG[3] : 0.0
    Cl_body_rad = 0.0

    for fus in input.fuselages
        Vol = π / 4 * fus.diameter^2 * fus.length
        # Vertical offset of fuselage centre from CG
        fus_z = length(fus.nose_position) >= 3 ? fus.nose_position[3] : 0.0
        z_arm = fus_z - cg_z
        Cl_body_rad += 2 * Vol / (Sref * bref) * (z_arm / max(bref, 0.1))
    end

    return Cl_body_rad * π / 180   # per degree
end

"""Estimate the attached-flow induced-drag factor K = 1/(π AR e)."""
function estimate_induced_drag_factor(input::AircraftInput)
    for surf in input.lifting_surfaces
        if surf.role == "wing"
            AR = max(surf.AR, 0.5)
            e = clamp(surf.Oswald_factor, 0.55, 0.95)
            return 1.0 / (π * AR * e)
        end
    end
    AR = max(input.general.bref^2 / max(input.general.Sref, 1e-3), 0.5)
    return 1.0 / (π * AR * 0.8)
end

"""Estimate a smooth wing/body pitching moment about its aerodynamic center."""
function estimate_wing_body_cm_ac(input::AircraftInput)
    Sref = max(input.general.Sref, 1.0e-6)
    cm = 0.0
    used_area = 0.0
    for surf in input.lifting_surfaces
        if classify_role(surf.role) == :wing_body
            area_ratio = max(surf.surface_area_m2, 0.0) / Sref
            camber = 0.5 * (surf.airfoil.root_max_camber + surf.airfoil.tip_max_camber)
            cm += (-pi / 2.0 * camber) * area_ratio
            used_area += area_ratio
        end
    end

    if used_area <= 1.0e-6
        return 0.0
    end
    return clamp(cm, -0.12, 0.04)
end

"""Build the wing/body Cm_ac table without subtracting approximate tail moments."""
function wing_body_ac_pitching_moment_table(input::AircraftInput,
                                            alphas_deg::AbstractVector,
                                            betas_deg::AbstractVector)
    cm0_ac = estimate_wing_body_cm_ac(input)
    # Reverse-flow pulse parameters: Gaussian-derivative shape that peaks
    # at α_rev = ±scale_rev/√2 ≈ ±10.6°, i.e. at α = ±169.4°. The sign is
    # chosen so that dCm/dα > 0 at α = ±180°, making pure reverse flight
    # statically UNSTABLE in pitch (otherwise the aircraft can trim
    # backwards). Magnitude tuned to dominate the forward sin(2α) term in
    # the high-|α| region, shifting the visible "large values" from
    # ±135° toward ±170°.
    K_rev_cm = 0.7
    scale_rev = deg2rad(15.0)
    out = zeros(length(alphas_deg), length(betas_deg))
    for (ai, alpha_deg) in enumerate(alphas_deg)
        alpha = deg2rad(alpha_deg)
        attached = 0.5 * (1.0 - tanh((abs(alpha_deg) - 18.0) / 8.0))
        α_rev = deg2rad(alpha_deg - sign(alpha_deg) * 180.0)
        rev_pulse = K_rev_cm * α_rev * exp(-(α_rev / scale_rev)^2)
        for (bi, beta_deg) in enumerate(betas_deg)
            beta = deg2rad(beta_deg)
            cos2β = cos(beta)^2
            poststall_cm_fwd = -0.025 * sin(2.0 * alpha) * cos2β
            poststall_cm_rev = rev_pulse * cos2β
            poststall_cm = poststall_cm_fwd + poststall_cm_rev
            out[ai, bi] = attached * cm0_ac + (1.0 - attached) * poststall_cm
        end
    end
    return out
end

"""Estimate lateral CD90 from fuselage side-projected area."""
function estimate_CD90_lateral(input::AircraftInput, CD90_longitudinal::Float64)
    Sref = input.general.Sref
    side_area = 0.0

    for fus in input.fuselages
        side_area += fus.diameter * fus.length
    end

    if side_area > 0 && Sref > 0
        return CD90_longitudinal * clamp(side_area / Sref, 0.3, 2.0)
    end
    return CD90_longitudinal * 0.8
end
