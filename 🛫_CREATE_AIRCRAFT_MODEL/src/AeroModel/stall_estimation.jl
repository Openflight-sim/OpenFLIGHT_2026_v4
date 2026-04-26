"""
    stall_estimation.jl — DATCOM-based stall angle and CL_max estimation

Computes stall characteristics from airfoil and wing geometry using
DATCOM semi-empirical correlations.  This replaces hardcoded stall
parameters with physics-based estimates for each lifting surface.

References:
  - USAF Stability & Control DATCOM, Sections 4.1.1.4, 4.1.3.4
  - Raymer, "Aircraft Design: A Conceptual Approach", Ch. 12
  - Roskam, "Airplane Design" Part VI, Sections 8.1–8.3

Note: parse_naca_geometry() is defined in input.jl (loaded before this file).
"""

# ================================================================
# DATCOM section CL_max estimation
# ================================================================

"""
    datcom_section_clmax(t_over_c, max_camber, Re; mach=0.0)

Estimate 2D section maximum lift coefficient using DATCOM correlations.

The DATCOM method (Section 4.1.1.4) relates section CL_max to:
  - Airfoil thickness ratio (primary driver)
  - Camber (additive increment)
  - Reynolds number (correction factor)
  - Mach number (compressibility correction)

For NACA 4/5-digit airfoils, the base cl_max depends on the stall type:
  - Thin airfoils (t/c < 0.09): leading-edge stall, abrupt, low cl_max
  - Medium (0.09 ≤ t/c ≤ 0.15): combined LE/TE stall, moderate cl_max
  - Thick (t/c > 0.15): trailing-edge stall, gradual, high cl_max
"""
function datcom_section_clmax(t_over_c::Float64, max_camber::Float64, Re::Float64;
                              mach::Float64=0.0)
    # ---- Base section cl_max from thickness (DATCOM Fig 4.1.1.4-5) ----
    # Piecewise fit to DATCOM data for NACA-series airfoils at Re ≈ 6×10⁶
    tc = clamp(t_over_c, 0.04, 0.25)

    if tc < 0.06
        # Very thin — leading edge stall dominates
        cl_max_base = 0.85 + 3.0 * (tc - 0.04)
    elseif tc < 0.10
        # Thin — transition from LE to combined stall
        cl_max_base = 0.91 + 4.5 * (tc - 0.06)
    elseif tc < 0.15
        # Medium — peak cl_max region
        cl_max_base = 1.09 + 3.6 * (tc - 0.10)
    elseif tc < 0.21
        # Moderately thick — trailing-edge stall, still high
        cl_max_base = 1.27 + 1.0 * (tc - 0.15)
    else
        # Very thick — TE stall, cl_max plateaus then decreases
        cl_max_base = 1.33 - 1.0 * (tc - 0.21)
    end

    # ---- Camber increment (DATCOM Section 4.1.1.4) ----
    # Δcl_max ≈ 10 × max_camber for conventional camber distributions
    # Capped to avoid unrealistic values for extreme camber
    dcl_camber = clamp(10.0 * max_camber, 0.0, 0.5)

    # ---- Reynolds number correction (DATCOM Fig 4.1.1.4-7) ----
    # Reference Re = 6×10⁶; correction scales as (Re/Re_ref)^0.1
    Re_ref = 6.0e6
    Re_factor = (clamp(Re, 1e5, 5e7) / Re_ref)^0.1

    # ---- Mach correction (Prandtl-Glauert for cl_max) ----
    # At low Mach, cl_max increases slightly due to compressibility
    # At higher Mach, shock-induced separation reduces cl_max
    if mach < 0.3
        mach_factor = 1.0
    elseif mach < 0.6
        mach_factor = 1.0 + 0.15 * (mach - 0.3) / 0.3   # slight increase
    else
        mach_factor = 1.15 - 0.8 * (mach - 0.6)          # decrease
    end
    mach_factor = clamp(mach_factor, 0.6, 1.2)

    return (cl_max_base + dcl_camber) * Re_factor * mach_factor
end

# ================================================================
# DATCOM 3D wing CL_max
# ================================================================

"""
    datcom_wing_clmax(input::AircraftInput, surf::LiftingSurface;
                      mach=0.2, altitude_m=0.0) -> NamedTuple

Compute the 3D wing maximum lift coefficient and stall angle using
DATCOM methods (Sections 4.1.3.4 and 4.1.3.6).

Returns (CL_max, alpha_stall_pos_deg, alpha_stall_neg_deg, CL_alpha_rad,
         section_clmax, stall_type).
"""
function datcom_wing_clmax(input::AircraftInput, surf::LiftingSurface;
                           mach::Float64=0.2, altitude_m::Float64=0.0)
    # ---- Parse airfoil geometry ----
    root_geom = parse_naca_geometry(surf.airfoil.root)
    tip_geom  = parse_naca_geometry(surf.airfoil.tip)

    # Average thickness and camber across span (weighted toward root)
    t_over_c = 0.7 * root_geom.thickness_ratio + 0.3 * tip_geom.thickness_ratio
    max_camber = 0.7 * root_geom.max_camber + 0.3 * tip_geom.max_camber

    # ---- Estimate Reynolds number ----
    # ISA atmosphere at given altitude
    T = 288.15 - 0.0065 * altitude_m
    p = 101325.0 * (T / 288.15)^5.2561
    rho = p / (287.05 * T)
    mu = 1.458e-6 * T^1.5 / (T + 110.4)    # Sutherland's law
    a = sqrt(1.4 * 287.05 * T)               # speed of sound
    V = mach * a
    Re = rho * V * surf.mean_aerodynamic_chord_m / mu

    # ---- Section cl_max ----
    cl_max_section = datcom_section_clmax(t_over_c, max_camber, Re; mach=mach)

    # ---- 3D correction: DATCOM wing CL_max from section cl_max ----
    # CL_max_wing / cl_max_section depends on:
    #   - Aspect ratio
    #   - Taper ratio
    #   - Sweep angle
    #   - Twist
    # DATCOM Fig 4.1.3.4-21: ratio ≈ 0.90 for unswept, AR>6, TR~0.4-0.6

    AR = surf.AR
    TR = surf.TR
    sweep_rad = deg2rad(surf.sweep_quarter_chord_DEG)

    # Taper ratio effect (DATCOM): higher taper → more uniform lift → higher ratio
    # Empirical fit to DATCOM charts
    k_taper = 0.80 + 0.20 * TR   # ranges from 0.80 (pointed tip) to 1.0 (rectangular)

    # Aspect ratio effect: higher AR → tip stall at lower fraction of cl_max
    k_AR = clamp(0.95 - 0.01 * max(AR - 6.0, 0.0), 0.85, 0.98)

    # Sweep effect (DATCOM): CL_max reduces with sweep
    # CL_max/cl_max ∝ cos(Λ_LE)
    k_sweep = cos(sweep_rad)^0.5   # moderate correction

    # Twist effect: washout reduces effective cl_max (tip unloaded)
    k_twist = 1.0 + 0.005 * surf.twist_tip_DEG   # washout (negative twist) → slight increase

    ratio_3d = k_taper * k_AR * k_sweep * k_twist
    ratio_3d = clamp(ratio_3d, 0.70, 1.0)

    CL_max_wing = cl_max_section * ratio_3d

    # ---- Lift curve slope (3D, Helmbold with compressibility) ----
    beta_pg = sqrt(abs(1.0 - mach^2))
    beta_pg = max(beta_pg, 0.1)
    CLa_2d = 2π
    kappa = 1.0   # section lift curve slope correction
    CLa_wing = CLa_2d * AR / (2 + sqrt(4 + (AR * beta_pg / kappa)^2 *
                                         (1 + tan(sweep_rad)^2 / beta_pg^2)))

    # ---- Stall angle ----
    # α_stall = CL_max / CL_alpha + α_zero_lift
    # Zero-lift angle from camber: α_0L ≈ -2 × max_camber (radians, thin-airfoil theory)
    alpha_0L_rad = -2.0 * max_camber
    alpha_0L_deg = rad2deg(alpha_0L_rad)

    alpha_stall_pos = rad2deg(CL_max_wing / CLa_wing) + alpha_0L_deg
    # Negative stall: typically 2-3° less magnitude due to camber asymmetry
    alpha_stall_neg = -(alpha_stall_pos - 2 * alpha_0L_deg) + 2.0 * alpha_0L_deg

    # ---- Stall type classification ----
    stall_type = if t_over_c < 0.09
        "leading_edge"    # abrupt, sharp break
    elseif t_over_c < 0.15
        "combined"        # moderate break
    else
        "trailing_edge"   # gradual, gentle
    end

    return (CL_max = CL_max_wing,
            alpha_stall_pos_deg = alpha_stall_pos,
            alpha_stall_neg_deg = alpha_stall_neg,
            CL_alpha_rad = CLa_wing,
            section_clmax = cl_max_section,
            stall_type = stall_type,
            t_over_c = t_over_c,
            max_camber = max_camber)
end

# ================================================================
# Compute stall for all surfaces
# ================================================================

"""
    compute_aircraft_stall(input::AircraftInput; mach=0.2, altitude_m=0.0) -> Dict

Compute stall parameters for all lifting surfaces using DATCOM methods.
Returns a Dict with per-surface stall data and the overall aircraft values
(driven by the wing).

The returned Dict can be used directly by full_envelope.jl and merge.jl
instead of reading hardcoded values from JSON.
"""
function compute_aircraft_stall(input::AircraftInput; mach::Float64=0.2,
                                altitude_m::Float64=0.0)
    stall = Dict{String,Any}()
    surfaces = Dict{String,Any}()

    wing_stall = nothing
    htail_stall = nothing
    vtail_stall = nothing

    for surf in input.lifting_surfaces
        s = datcom_wing_clmax(input, surf; mach=mach, altitude_m=altitude_m)

        surfaces[surf.name] = Dict(
            "role" => surf.role,
            "CL_max" => round(s.CL_max, digits=4),
            "alpha_stall_pos_deg" => round(s.alpha_stall_pos_deg, digits=2),
            "alpha_stall_neg_deg" => round(s.alpha_stall_neg_deg, digits=2),
            "CL_alpha_rad" => round(s.CL_alpha_rad, digits=4),
            "section_clmax" => round(s.section_clmax, digits=4),
            "stall_type" => s.stall_type,
            "t_over_c" => round(s.t_over_c, digits=4),
            "max_camber" => round(s.max_camber, digits=4)
        )

        if surf.role == "wing" && isnothing(wing_stall)
            wing_stall = s
        elseif surf.role == "horizontal_stabilizer" && isnothing(htail_stall)
            htail_stall = s
        elseif (surf.role == "vertical_stabilizer" || surf.vertical) && isnothing(vtail_stall)
            vtail_stall = s
        end
    end

    stall["per_surface"] = surfaces

    # ---- Aircraft-level stall (driven by wing) ----
    if !isnothing(wing_stall)
        stall["alpha_stall_positive"] = round(wing_stall.alpha_stall_pos_deg, digits=2)
        stall["alpha_stall_negative"] = round(wing_stall.alpha_stall_neg_deg, digits=2)
        stall["CL_max"] = round(wing_stall.CL_max, digits=4)
        stall["wing_stall_type"] = wing_stall.stall_type
    else
        # Fallback if no wing found — estimate from first surface or defaults
        if !isempty(input.lifting_surfaces)
            s = datcom_wing_clmax(input, input.lifting_surfaces[1]; mach=mach)
            stall["alpha_stall_positive"] = round(s.alpha_stall_pos_deg, digits=2)
            stall["alpha_stall_negative"] = round(s.alpha_stall_neg_deg, digits=2)
            stall["CL_max"] = round(s.CL_max, digits=4)
            stall["wing_stall_type"] = s.stall_type
        else
            stall["alpha_stall_positive"] = 15.0
            stall["alpha_stall_negative"] = -13.0
            stall["CL_max"] = 1.2
            stall["wing_stall_type"] = "combined"
        end
    end

    # ---- Tail stall angles (for VTP/HTP sideslip stall in envelope) ----
    if !isnothing(htail_stall)
        stall["htail_alpha_stall_deg"] = round(htail_stall.alpha_stall_pos_deg, digits=2)
    end
    if !isnothing(vtail_stall)
        # VTP stall angle is the sideslip angle at which the fin stalls
        stall["vtail_beta_stall_deg"] = round(vtail_stall.alpha_stall_pos_deg, digits=2)
    else
        stall["vtail_beta_stall_deg"] = 20.0   # conservative default
    end

    # ---- Post-stall parameters (DATCOM-derived) ----
    # CD90: flat-plate normal force coefficient at 90° AoA
    # Depends on aspect ratio (finite-span flat plate)
    if !isnothing(wing_stall)
        wing = nothing
        for surf in input.lifting_surfaces
            if surf.role == "wing"
                wing = surf
                break
            end
        end
        if !isnothing(wing)
            # Flat plate CD90 from AR (Hoerner): CD90 ≈ 1.98 × (1 - 0.5/AR) for AR > 1
            AR = wing.AR
            stall["CD90"] = round(1.98 * (1.0 - 0.5 / max(AR, 1.0)), digits=3)
        else
            stall["CD90"] = 1.6
        end
    else
        stall["CD90"] = 1.6
    end

    # CD0: zero-lift drag from component buildup (Raymer / DATCOM method)
    # CD0 = Cf × Σ(FF_i × Swet_i) / Sref × 1.08 (interference)
    Sref = input.general.Sref
    cref = input.general.cref

    # ISA atmosphere for Reynolds number
    T = 288.15 - 0.0065 * altitude_m
    rho = 101325.0 * (T / 288.15)^5.2561 / (287.05 * T)
    mu = 1.458e-6 * T^1.5 / (T + 110.4)
    a = sqrt(1.4 * 287.05 * T)
    V = mach * a
    Re_ref = max(rho * V * cref / mu, 1e4)

    Cf = 0.455 / (log10(Re_ref))^2.58

    # Component wetted areas and form factors
    FF_Swet_sum = 0.0
    for surf in input.lifting_surfaces
        t_c = 0.7 * surf.airfoil.root_thickness_ratio + 0.3 * surf.airfoil.tip_thickness_ratio
        Swet_s = 2.0 * surf.surface_area_m2 * (1.0 + 0.25 * t_c)
        FF_s   = 1.0 + 2.0 * t_c + 100.0 * t_c^4
        FF_Swet_sum += FF_s * Swet_s
    end
    for fus in input.fuselages
        f_ratio = fus.length / max(fus.diameter, 0.1)
        Swet_f = π * fus.diameter * max(fus.length - 1.3 * fus.diameter, 0.5 * fus.length)
        FF_f   = 1.0 + 60.0 / max(f_ratio, 1.0)^3 + f_ratio / 400.0
        FF_Swet_sum += FF_f * Swet_f
    end

    if FF_Swet_sum > 0.0
        CD0 = Cf * FF_Swet_sum / Sref * 1.08   # 8% for interference/misc
    else
        CD0 = Cf * 4.0   # fallback if no geometry
    end
    stall["CD0"] = round(CD0, digits=5)

    return stall
end
