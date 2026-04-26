###########################################################
# 0.2.5 — Component assembler (schema v3.0)
#
# Combines the wing_body and tail coefficient blocks with the
# interference corrections (downwash ε, sidewash σ, tail dynamic-
# pressure ratios η_h / η_v) to produce the global whole-aircraft
# coefficients the simulator consumes.
#
# Inputs per lookup:
#   α, β, Mach, config         — aircraft-frame flight condition
#   aero_data                  — AeroData struct with v3 keys loaded
#                                (wb_CL, tail_<name>_CL, interference_*)
#   tail_surfaces              — Vector of NamedTuple with arm_m / ac_xyz_m
#
# Outputs:
#   NamedTuple(CL, CD, CY, Cl, Cm, Cn) — total aircraft coefficients,
#   all referenced to aircraft CoG and Sref (cref for Cm, bref for Cl/Cn).
###########################################################

"""
    assemble_total_force_and_moment_coefficients(
        α_deg, β_deg, mach, config, aero_data, tail_surfaces, cref, bref, cg_xyz_m
    ) -> NamedTuple(CL, CD, CY, Cl, Cm, Cn)

Sum wing+body and per-tail contributions. Tail coefficients are looked up
in their LOCAL angles α_h = α − ε(α), β_v = β − σ(β); then scaled by
η_h / η_v; then their forces are transferred from each tail AC to the
aircraft CoG via r × F (non-dim by c_ref for pitch, b_ref for roll/yaw).

Returns zero for any component whose table is not present — allows a
v3 YAML with a partial split (e.g. DATCOM-only wb tables) to still fly.
"""
function _translate_component_moment_coefficients(
    CF::AbstractVector, CM::AbstractVector, r_from_to::AbstractVector,
    cref::Float64, bref::Float64
)
    Fx, Fy, Fz = CF[1], CF[2], CF[3]
    rx, ry, rz = r_from_to[1], r_from_to[2], r_from_to[3]

    τx = ry * Fz - rz * Fy
    τy = rz * Fx - rx * Fz
    τz = rx * Fy - ry * Fx

    return [
        CM[1] - τx / bref,
        CM[2] - τy / cref,
        CM[3] - τz / bref,
    ]
end

function _wing_body_reference_point_xyz(aero_data, cg_xyz_m::AbstractVector)
    ref_xyz = get(aero_data.constants, "aerodynamics.wing_body.reference_point_m.xyz_m", nothing)
    if ref_xyz isa AbstractVector && length(ref_xyz) >= 3
        return [Float64(ref_xyz[1]), Float64(ref_xyz[2]), Float64(ref_xyz[3])]
    end

    x_np = fetch_constant_from_aero_database(aero_data, "x_wing_body_neutral_point", NaN)
    y_np = fetch_constant_from_aero_database(aero_data, "y_wing_body_neutral_point", NaN)
    z_np = fetch_constant_from_aero_database(aero_data, "z_wing_body_neutral_point", NaN)
    if x_np isa Number && y_np isa Number && z_np isa Number &&
       isfinite(Float64(x_np)) && isfinite(Float64(y_np)) && isfinite(Float64(z_np))
        return [Float64(x_np), Float64(y_np), Float64(z_np)]
    end

    x_ref_cg = fetch_constant_from_aero_database(aero_data, "x_aero_reference_CoG", NaN)
    y_ref_cg = fetch_constant_from_aero_database(aero_data, "y_aero_reference_CoG", NaN)
    z_ref_cg = fetch_constant_from_aero_database(aero_data, "z_aero_reference_CoG", NaN)
    if x_ref_cg isa Number && y_ref_cg isa Number && z_ref_cg isa Number &&
       isfinite(Float64(x_ref_cg)) && isfinite(Float64(y_ref_cg)) && isfinite(Float64(z_ref_cg))
        return [Float64(x_ref_cg), Float64(y_ref_cg), Float64(z_ref_cg)]
    end

    return [Float64(cg_xyz_m[1]), Float64(cg_xyz_m[2]), Float64(cg_xyz_m[3])]
end

function _tail_reference_to_current_cg(ts, cg_xyz_m::AbstractVector)
    if hasproperty(ts, :ac_xyz_m) && length(ts.ac_xyz_m) >= 3
        return [
            Float64(cg_xyz_m[1]) - Float64(ts.ac_xyz_m[1]),
            Float64(cg_xyz_m[2]) - Float64(ts.ac_xyz_m[2]),
            Float64(cg_xyz_m[3]) - Float64(ts.ac_xyz_m[3]),
        ]
    end

    if hasproperty(ts, :arm_m) && length(ts.arm_m) >= 3
        return [
            -Float64(ts.arm_m[1]),
            -Float64(ts.arm_m[2]),
            -Float64(ts.arm_m[3]),
        ]
    end

    return [0.0, 0.0, 0.0]
end

function assemble_total_force_and_moment_coefficients(
    α_deg::Float64, β_deg::Float64, mach::Float64, config::String,
    aero_data, tail_surfaces, cref::Float64, bref::Float64, cg_xyz_m::AbstractVector
)
    wb_lookup_state = make_fast_lookup_state(aero_data, α_deg, β_deg, mach, config)

    # ───── wing+body static coefficients (aircraft α, β) ─────
    CL_wb = _fetch_component_coeff(aero_data, "wb_CL"; lookup_state=wb_lookup_state)
    CD_wb = _fetch_component_coeff(aero_data, "wb_CD"; lookup_state=wb_lookup_state)
    CY_wb = _fetch_component_coeff(aero_data, "wb_CY"; lookup_state=wb_lookup_state)
    Cl_wb_ref = _fetch_component_coeff(aero_data, "wb_Cl"; lookup_state=wb_lookup_state)
    Cm_wb_ref = _fetch_component_coeff(aero_data, "wb_Cm"; lookup_state=wb_lookup_state)
    Cn_wb_ref = _fetch_component_coeff(aero_data, "wb_Cn"; lookup_state=wb_lookup_state)

    wb_ref_xyz = _wing_body_reference_point_xyz(aero_data, cg_xyz_m)
    r_wb_ref_to_cg = [
        Float64(cg_xyz_m[1]) - wb_ref_xyz[1],
        Float64(cg_xyz_m[2]) - wb_ref_xyz[2],
        Float64(cg_xyz_m[3]) - wb_ref_xyz[3],
    ]
    CM_wb_cg = _translate_component_moment_coefficients(
        [CD_wb, CY_wb, CL_wb],
        [Cl_wb_ref, Cm_wb_ref, Cn_wb_ref],
        r_wb_ref_to_cg,
        cref,
        bref
    )
    Cl_wb = CM_wb_cg[1]
    Cm_wb = CM_wb_cg[2]
    Cn_wb = CM_wb_cg[3]

    # ───── interference quantities ─────
    ε_deg = _fetch_component_coeff(aero_data, "interference_downwash_deg"; lookup_state=wb_lookup_state, default=0.0)
    σ_deg = _fetch_component_coeff(aero_data, "interference_sidewash_deg"; lookup_state=wb_lookup_state, default=0.0)
    η_h   = _fetch_component_coeff(aero_data, "interference_eta_h"; lookup_state=wb_lookup_state, default=1.0)
    η_v   = _fetch_component_coeff(aero_data, "interference_eta_v"; lookup_state=wb_lookup_state, default=1.0)

    α_h_deg = α_deg - ε_deg
    β_v_deg = β_deg - σ_deg

    # ───── tail contributions, per surface ─────
    CL_tail_total = 0.0; CD_tail_total = 0.0; CY_tail_total = 0.0
    Cl_tail_total = 0.0; Cm_tail_total = 0.0; Cn_tail_total = 0.0

    for ts in tail_surfaces
        name = ts.name
        # η depends on which component this surface is.
        is_h = ts.component == "tail_h"
        q_ratio = is_h ? η_h : η_v
        tail_lookup_state = make_fast_lookup_state(aero_data, α_h_deg, β_v_deg, mach, config)
        # The tail YAML is tabulated in local α_h/β_v; ask the database
        # for those values under the canonical keys it reindexed onto.
        CL_t = _fetch_component_coeff(aero_data, "tail_" * name * "_CL"; lookup_state=tail_lookup_state, default=0.0)
        CD_t = _fetch_component_coeff(aero_data, "tail_" * name * "_CD"; lookup_state=tail_lookup_state, default=0.0)
        CY_t = _fetch_component_coeff(aero_data, "tail_" * name * "_CY"; lookup_state=tail_lookup_state, default=0.0)
        Cl_AC = _fetch_component_coeff(aero_data, "tail_" * name * "_Cl_at_AC"; lookup_state=tail_lookup_state, default=0.0)
        Cm_AC = _fetch_component_coeff(aero_data, "tail_" * name * "_Cm_at_AC"; lookup_state=tail_lookup_state, default=0.0)
        Cn_AC = _fetch_component_coeff(aero_data, "tail_" * name * "_Cn_at_AC"; lookup_state=tail_lookup_state, default=0.0)

        # η-scaled forces
        CL_t_eff = q_ratio * CL_t
        CD_t_eff = q_ratio * CD_t
        CY_t_eff = q_ratio * CY_t

        # Accumulate tail forces directly.
        CL_tail_total += CL_t_eff
        CD_tail_total += CD_t_eff
        CY_tail_total += CY_t_eff

        CM_tail_cg = _translate_component_moment_coefficients(
            [CD_t_eff, CY_t_eff, CL_t_eff],
            q_ratio .* [Cl_AC, Cm_AC, Cn_AC],
            _tail_reference_to_current_cg(ts, cg_xyz_m),
            cref,
            bref
        )

        Cl_tail_total += CM_tail_cg[1]
        Cm_tail_total += CM_tail_cg[2]
        Cn_tail_total += CM_tail_cg[3]
    end

    # Apply whole-aircraft family/coefficient tuning to the assembled totals
    # after the component r×F bookkeeping. This makes knobs like `Cm` and
    # `Cl` scale the final aircraft coefficients the pilot actually feels,
    # rather than only the raw component AC moment tables.
    CL_wb_out = _apply_tuned_lookup_value(aero_data, "CL", CL_wb)
    CD_wb_out = _apply_tuned_lookup_value(aero_data, "CD", CD_wb)
    CY_wb_out = _apply_tuned_lookup_value(aero_data, "CY", CY_wb)
    Cl_wb_out = _apply_tuned_lookup_value(aero_data, "Cl", Cl_wb)
    Cm_wb_out = _apply_tuned_lookup_value(aero_data, "Cm", Cm_wb)
    Cn_wb_out = _apply_tuned_lookup_value(aero_data, "Cn", Cn_wb)

    CL_tail_out = _apply_tuned_lookup_value(aero_data, "CL", CL_tail_total)
    CD_tail_out = _apply_tuned_lookup_value(aero_data, "CD", CD_tail_total)
    CY_tail_out = _apply_tuned_lookup_value(aero_data, "CY", CY_tail_total)
    Cl_tail_out = _apply_tuned_lookup_value(aero_data, "Cl", Cl_tail_total)
    Cm_tail_out = _apply_tuned_lookup_value(aero_data, "Cm", Cm_tail_total)
    Cn_tail_out = _apply_tuned_lookup_value(aero_data, "Cn", Cn_tail_total)

    return (
        CL = CL_wb_out + CL_tail_out,
        CD = CD_wb_out + CD_tail_out,
        CY = CY_wb_out + CY_tail_out,
        Cl = Cl_wb_out + Cl_tail_out,
        Cm = Cm_wb_out + Cm_tail_out,
        Cn = Cn_wb_out + Cn_tail_out,
        wb = (CL=CL_wb_out, CD=CD_wb_out, CY=CY_wb_out, Cl=Cl_wb_out, Cm=Cm_wb_out, Cn=Cn_wb_out),
        tail = (CL=CL_tail_out, CD=CD_tail_out, CY=CY_tail_out,
                Cl=Cl_tail_out, Cm=Cm_tail_out, Cn=Cn_tail_out),
        interference = (ε_deg=ε_deg, σ_deg=σ_deg, η_h=η_h, η_v=η_v,
                        α_h_deg=α_h_deg, β_v_deg=β_v_deg)
    )
end

"""
    _fetch_component_coeff(aero_data, name; α_deg, β_deg, mach, config, default=0.0)

Wrapper around fetch_value_from_aero_database that silently returns `default`
when the coefficient is not present. Only the kwargs relevant to the requested
coefficient's axis_order are forwarded (axis names the engine doesn't know are
harmless; unused ones are ignored by the resolver).
"""
function _fetch_component_coeff(aero_data, name::String; lookup_state=nothing,
                                  α_deg=nothing, β_deg=nothing,
                                  mach=nothing, config=nothing, default::Float64=0.0)
    if !has_aero_coefficient(aero_data, name)
        return default
    end
    try
        val = if lookup_state !== nothing
            fetch_value_from_aero_database(aero_data, name, lookup_state)
        else
            kwargs = Dict{Symbol,Any}()
            if α_deg !== nothing; kwargs[:alpha_deg] = Float64(α_deg); end
            if β_deg !== nothing; kwargs[:beta_deg]  = Float64(β_deg); end
            if mach  !== nothing; kwargs[:mach]      = Float64(mach);  end
            if config !== nothing; kwargs[:config]   = String(config); end
            fetch_value_from_aero_database(aero_data, name; kwargs...)
        end
        return val isa Number ? Float64(val) : default
    catch
        return default
    end
end

"""
    has_v3_split_tables(aero_data) -> Bool

True iff the v3 `wb_*` block is present in the database — used to decide
whether the simulator should dispatch to the assembler or to the legacy
whole-aircraft coefficient path.
"""
function has_v3_split_tables(aero_data)
    return has_aero_coefficient(aero_data, "wb_CL") ||
           has_aero_coefficient(aero_data, "wb_Cm")
end
