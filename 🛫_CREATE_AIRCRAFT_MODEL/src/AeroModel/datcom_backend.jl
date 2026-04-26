"""
    datcom_backend.jl — JDATCOM backend adapter

Converts aircraft JSON to DATCOM state dictionary, runs the
semi-empirical solver across the full Mach/alpha envelope.
"""

const JDATCOM_PATH = normpath(joinpath(@__DIR__, "..", "..", "DATCOM", "JDATCOM"))

let _datcom_loaded = Ref(false)
    global function ensure_datcom_loaded()
        if !_datcom_loaded[]
            pushfirst!(LOAD_PATH, JDATCOM_PATH)
            # Load JDATCOM modules
            jdatcom_src = joinpath(JDATCOM_PATH, "src")
            for f in ["io/state.jl", "io/parser.jl",
                "geometry/Body.jl", "geometry/Wing.jl", "geometry/Tail.jl",
                "aerodynamics/calculator.jl"]
                fpath = joinpath(jdatcom_src, f)
                if isfile(fpath)
                    @eval include($fpath)
                end
            end
            _datcom_loaded[] = true
        end
    end
end

"""
    run_datcom_backend(input::AircraftInput; progress_callback=nothing) -> Dict

Runs JDATCOM semi-empirical analysis over the full Mach/alpha envelope.
Returns CL, CD (with drag breakdown), Cm at each (Mach, alpha) point,
plus damping derivatives.
"""
function run_datcom_backend(input::AircraftInput; progress_callback=nothing)
    cb = isnothing(progress_callback) ? (s, p, m) -> nothing : progress_callback

    alphas_deg = get_alpha_array(input.analysis)
    machs = input.analysis.mach_values
    n_alpha = length(alphas_deg)
    n_mach = length(machs)

    cb("running", 5, "Building DATCOM state...")

    # Build DATCOM state dictionary from aircraft input
    state = build_datcom_state(input)

    # Result arrays: [mach_idx, alpha_idx]
    CL_arr = zeros(n_mach, n_alpha)
    CD_arr = zeros(n_mach, n_alpha)
    Cm_arr = zeros(n_mach, n_alpha)
    CD_friction = zeros(n_mach, n_alpha)
    CD_induced = zeros(n_mach, n_alpha)
    CD_wave = zeros(n_mach, n_alpha)

    # Dynamic derivatives: [mach_idx, alpha_idx]
    CMq = zeros(n_mach, n_alpha)
    Clp = zeros(n_mach, n_alpha)
    Cnr = zeros(n_mach, n_alpha)
    CLq = zeros(n_mach, n_alpha)
    CYp = zeros(n_mach, n_alpha)
    CYr = zeros(n_mach, n_alpha)
    CmAlphaDot = zeros(n_mach, n_alpha)
    CnBetaDot  = zeros(n_mach, n_alpha)

    total_points = n_mach * n_alpha
    point_count = 0

    for (mi, mach) in enumerate(machs)
        for (ai, alpha) in enumerate(alphas_deg)
            cb("running", 5 + round(Int, 85 * point_count / total_points),
                "DATCOM: M=$(mach), alpha=$(alpha)°")

            result = datcom_calculate_point(state, alpha, mach, input)

            CL_arr[mi, ai] = get(result, "cl", 0.0)
            CD_arr[mi, ai] = get(result, "cd", 0.0)
            Cm_arr[mi, ai] = get(result, "cm", 0.0)
            CD_friction[mi, ai] = get(result, "cd_friction", 0.0)
            CD_induced[mi, ai] = get(result, "cd_induced", 0.0)
            CD_wave[mi, ai] = get(result, "cd_wave", 0.0)
            CMq[mi, ai] = get(result, "cmq", 0.0)
            Clp[mi, ai] = get(result, "clp", 0.0)
            Cnr[mi, ai] = get(result, "cnr", 0.0)
            CLq[mi, ai] = get(result, "cl_q", 0.0)
            CYp[mi, ai] = get(result, "cy_p", 0.0)
            CYr[mi, ai] = get(result, "cy_r", 0.0)
            CmAlphaDot[mi, ai] = get(result, "cm_alpha_dot", 0.0)
            CnBetaDot[mi, ai]  = get(result, "cn_beta_dot",  0.0)

            point_count += 1
        end
    end

    cb("running", 95, "Packaging DATCOM results...")

    # ───── v3.0 split blocks ─────
    # DATCOM's internal CL build-up (CLa_wing + CLa_t·tail_eff) is not exposed
    # per-component in its return, so we treat the whole-aircraft result as the
    # wing_body block and emit an empty tail block. merge/envelope reconstruct
    # the tail analytically when DATCOM is the only available backend.
    wing_body_block = Dict{String,Any}(
        "static" => Dict("CL" => CL_arr, "CD" => CD_arr, "Cm" => Cm_arr),
        "alphas_deg" => alphas_deg,
        "machs" => machs
    )
    tail_block = Dict{String,Any}(
        "surfaces" => Vector{Dict{String,Any}}(),   # empty — rebuilt analytically
        "alphas_deg" => alphas_deg,
        "machs" => machs
    )

    return Dict(
        "static" => Dict(
            "CL" => CL_arr, "CD" => CD_arr, "Cm" => Cm_arr,
            "CD_friction" => CD_friction, "CD_induced" => CD_induced,
            "CD_wave" => CD_wave
        ),
        "alphas_deg" => alphas_deg,
        "machs" => machs,
        "dynamic_derivatives" => Dict(
            "Cm_q_hat" => CMq,
            "Cl_p_hat" => Clp,
            "Cn_r_hat" => Cnr,
            "CL_q_hat" => CLq,
            "CY_p_hat" => CYp,
            "CY_r_hat" => CYr,
            "Cm_alpha_dot_hat" => CmAlphaDot,
            "Cn_beta_dot_hat"  => CnBetaDot,
        ),
        # v3.0 additions — whole-aircraft treated as wing_body-equivalent.
        "wing_body" => wing_body_block,
        "tail" => tail_block
    )
end

"""
Build a DATCOM-style state dictionary from AircraftInput.

Extracts all geometric parameters needed by the semi-empirical methods,
including component wetted areas, form factors, and derived quantities
so that datcom_calculate_point() has no hardcoded geometry assumptions.
"""
function build_datcom_state(input::AircraftInput)
    state = Dict{String,Any}()

    Sref = input.general.Sref

    # Reference dimensions
    state["options_sref"] = Sref
    state["options_cbarr"] = input.general.cref
    state["options_blref"] = input.general.bref
    state["altitude_m"] = input.analysis.altitude_m

    # CG location
    state["synths_xcg"] = input.general.CoG[1]
    state["synths_zcg"] = length(input.general.CoG) >= 3 ? input.general.CoG[3] : 0.0

    # ── Wing (first non-vertical, non-tail surface) ──
    wing_idx = findfirst(s -> s.role == "wing" ||
                              (!s.vertical &&
                               s.role != "horizontal_stabilizer" &&
                               s.role != "vertical_stabilizer"),
                         input.lifting_surfaces)
    if !isnothing(wing_idx)
        ws = input.lifting_surfaces[wing_idx]
        wp = wing_planform(ws)
        state["synths_xw"] = ws.root_LE[1]
        state["synths_zw"] = length(ws.root_LE) >= 3 ? ws.root_LE[3] : 0.0
        state["wing_area"] = ws.surface_area_m2
        state["wing_span"] = wp.span
        state["wing_aspect_ratio"] = ws.AR
        state["wing_taper_ratio"] = ws.TR
        state["wing_sweep_deg"] = ws.sweep_quarter_chord_DEG
        state["wing_dihedral_deg"] = ws.dihedral_DEG
        state["wing_root_chord"] = wp.root_chord
        state["wing_tip_chord"] = wp.tip_chord
        state["wing_mac"] = wp.mac

        t_c_w = 0.7 * ws.airfoil.root_thickness_ratio + 0.3 * ws.airfoil.tip_thickness_ratio
        state["wing_tovc"] = t_c_w
        state["wing_camber"] = 0.7 * ws.airfoil.root_max_camber + 0.3 * ws.airfoil.tip_max_camber
        state["wing_camber_position"] = 0.7 * ws.airfoil.root_camber_position +
                                        0.3 * ws.airfoil.tip_camber_position
        state["wing_incidence_deg"] = ws.incidence_DEG
        state["wing_twist_deg"] = ws.twist_tip_DEG

        # Wetted area: Swet ≈ 2 × S_exposed × (1 + 0.25·t/c)  (Raymer Ch. 12)
        state["wing_wetted_area"] = 2.0 * ws.surface_area_m2 * (1.0 + 0.25 * t_c_w)

        # Form factor (Raymer eq. 12.30, simplified for x_cm ≈ 0.3c)
        state["wing_form_factor"] = 1.0 + 2.0 * t_c_w + 100.0 * t_c_w^4

        # Stall type from thickness (DATCOM Sections 4.1.1.4)
        state["stall_type"] = t_c_w < 0.09 ? "leading_edge" :
                              (t_c_w < 0.15 ? "combined" : "trailing_edge")

        # CD90 from AR — Hoerner flat-plate normal force
        state["CD90"] = 1.98 * (1.0 - 0.5 / max(ws.AR, 1.0))
    end

    # ── Horizontal tail ──
    ht_idx = findfirst(s -> s.role == "horizontal_stabilizer" ||
                            (!s.vertical && (lowercase(s.name) == "htp" ||
                                             lowercase(s.name) == "htail" ||
                                             lowercase(s.name) == "horizontal_tail" ||
                                             lowercase(s.name) == "horizontal_stabilizer")),
                       input.lifting_surfaces)
    if !isnothing(ht_idx)
        hs = input.lifting_surfaces[ht_idx]
        hp = wing_planform(hs)
        state["synths_xh"] = hs.root_LE[1] + 0.25 * hp.mac
        state["synths_zh"] = length(hs.root_LE) >= 3 ? hs.root_LE[3] : 0.0
        state["htail_area"] = hs.surface_area_m2
        state["htail_span"] = hp.span
        state["htail_aspect_ratio"] = hs.AR
        state["htail_taper_ratio"] = hs.TR
        state["htail_sweep_deg"] = hs.sweep_quarter_chord_DEG

        t_c_h = 0.7 * hs.airfoil.root_thickness_ratio + 0.3 * hs.airfoil.tip_thickness_ratio
        state["htail_tovc"] = t_c_h
        state["htail_wetted_area"] = 2.0 * hs.surface_area_m2 * (1.0 + 0.25 * t_c_h)
        state["htail_form_factor"] = 1.0 + 2.0 * t_c_h + 100.0 * t_c_h^4
    end

    # ── Vertical tail ──
    vt_idx = findfirst(s -> s.vertical || s.role == "vertical_stabilizer",
                       input.lifting_surfaces)
    if !isnothing(vt_idx)
        vs = input.lifting_surfaces[vt_idx]
        vp = wing_planform(vs)
        state["synths_xv"] = vs.root_LE[1] + 0.25 * vp.mac
        state["synths_zv"] = length(vs.root_LE) >= 3 ? vs.root_LE[3] : 0.0
        state["vtail_area"] = vs.surface_area_m2
        state["vtail_span"] = vp.span
        state["vtail_aspect_ratio"] = vs.AR
        state["vtail_taper_ratio"] = vs.TR
        state["vtail_sweep_deg"] = vs.sweep_quarter_chord_DEG

        t_c_v = 0.7 * vs.airfoil.root_thickness_ratio + 0.3 * vs.airfoil.tip_thickness_ratio
        state["vtail_tovc"] = t_c_v
        state["vtail_wetted_area"] = 2.0 * vs.surface_area_m2 * (1.0 + 0.25 * t_c_v)
        state["vtail_form_factor"] = 1.0 + 2.0 * t_c_v + 100.0 * t_c_v^4
    end

    # ── Body ──
    if !isempty(input.fuselages)
        fus = input.fuselages[1]
        state["body_length"] = fus.length
        state["body_max_radius"] = fus.diameter / 2
        state["body_max_area"] = π * (fus.diameter / 2)^2

        # Fineness ratio
        f_ratio = fus.length / max(fus.diameter, 0.1)
        state["body_fineness_ratio"] = f_ratio

        # Wetted area (Raymer): accounts for non-cylindrical nose/tail
        state["body_wetted_area"] = π * fus.diameter *
            max(fus.length - 1.3 * fus.diameter, 0.5 * fus.length)

        # Form factor (Raymer eq. 12.31)
        state["body_form_factor"] = 1.0 + 60.0 / max(f_ratio, 1.0)^3 + f_ratio / 400.0
    end

    # ── Total wetted area (component buildup) ──
    Swet_total = get(state, "wing_wetted_area", 0.0) +
                 get(state, "htail_wetted_area", 0.0) +
                 get(state, "vtail_wetted_area", 0.0) +
                 get(state, "body_wetted_area", 0.0)
    # 5% addition for interference, fairings, antennas, small items
    state["total_wetted_area"] = Swet_total > 0.0 ? Swet_total * 1.05 : 4.0 * Sref

    # ── Tail vertical offset from wing (for η_t and local flow) ──
    state["htail_z_offset"] = get(state, "synths_zh", 0.0) - get(state, "synths_zw", 0.0)

    return state
end

"""
Calculate aerodynamic coefficients at a single (alpha, Mach) point
using DATCOM semi-empirical methods.

All geometry-dependent quantities are drawn from the `state` dictionary
(built by build_datcom_state) and the `input` struct.  No hardcoded
geometry assumptions remain — only method constants (thin-airfoil 2π,
Schoenherr exponents, etc.) that are universal.
"""
function datcom_calculate_point(state::Dict, alpha_deg::Float64, mach::Float64,
    input::AircraftInput)
    result = Dict{String,Float64}()

    alpha_rad = deg2rad(alpha_deg)
    Sref = get(state, "options_sref", 10.0)
    cref = get(state, "options_cbarr", 2.0)
    bref = get(state, "options_blref", 10.0)

    # ── Reynolds number from ISA atmosphere ──
    altitude_m = get(state, "altitude_m", input.analysis.altitude_m)
    T_isa = 288.15 - 0.0065 * altitude_m
    p_isa = 101325.0 * (T_isa / 288.15)^5.2561
    rho   = p_isa / (287.05 * T_isa)
    mu    = 1.458e-6 * T_isa^1.5 / (T_isa + 110.4)
    a_snd = sqrt(1.4 * 287.05 * T_isa)
    V_inf = mach * a_snd
    Re = max(rho * V_inf * cref / mu, 1e4)

    # ── Wing geometry ──
    wing_AR    = get(state, "wing_aspect_ratio", 8.0)
    wing_sweep = deg2rad(get(state, "wing_sweep_deg", 0.0))
    wing_TR    = get(state, "wing_taper_ratio", 0.5)
    wing_tovc  = get(state, "wing_tovc", 0.12)
    wing_camber = get(state, "wing_camber", 0.0)

    # Prandtl-Glauert compressibility factor
    beta_pg = max(sqrt(abs(1.0 - mach^2)), 0.1)

    # ── Lift curve slope — Helmbold equation with compressibility ──
    CLa_2d = 2π
    kappa  = 1.0
    CLa_wing = CLa_2d * wing_AR / (2 + sqrt(4 + (wing_AR * beta_pg / kappa)^2 *
                                              (1 + tan(wing_sweep)^2 / beta_pg^2)))

    # ── Tail dynamic pressure ratio from geometry ──
    # η_t depends on how deeply the HTP is immersed in the wing wake.
    # Wake half-thickness at the tail ≈ 12% of wing chord (empirical, Raymer/ESDU).
    z_offset = get(state, "htail_z_offset", 0.0)
    wake_ht  = 0.12 * cref
    eta_t    = clamp(1.0 - 0.12 * exp(-(z_offset / max(wake_ht, 0.01))^2), 0.80, 1.0)

    # ── Tail contribution to lift ──
    ht_area  = get(state, "htail_area", 0.0)
    tail_eff = 0.0
    CLa_t    = 0.0
    deda     = 0.0
    if ht_area > 0
        ht_AR    = get(state, "htail_aspect_ratio", 4.0)
        ht_sweep = deg2rad(get(state, "htail_sweep_deg", 0.0))
        CLa_t    = CLa_2d * ht_AR / (2 + sqrt(4 + (ht_AR * beta_pg)^2 *
                                                (1 + tan(ht_sweep)^2 / beta_pg^2)))
        deda     = 2 * CLa_wing / (π * wing_AR)
        tail_eff = ht_area / Sref * (1 - deda) * eta_t
    end
    CLa = CLa_wing + CLa_t * tail_eff

    CL_linear = CLa * alpha_rad

    # ── Stall model ──
    cl_max_section = datcom_section_clmax(wing_tovc, wing_camber, Re; mach=mach)

    k_3d = clamp((0.80 + 0.20 * wing_TR) *
                 clamp(0.95 - 0.01 * max(wing_AR - 6.0, 0.0), 0.85, 0.98) *
                 cos(wing_sweep)^0.5, 0.70, 1.0)
    CL_max = cl_max_section * k_3d
    alpha_stall = CL_max / max(CLa, 0.01)

    # Post-stall decay rate tied to stall type (LE = sharp, TE = gradual)
    stall_type = get(state, "stall_type", "combined")
    CL_efold_deg = stall_type == "leading_edge" ? 12.0 :
                   (stall_type == "combined" ? 18.0 : 25.0)

    # CD90 from aspect ratio (Hoerner flat-plate normal force)
    CD90 = get(state, "CD90", 1.98 * (1.0 - 0.5 / max(wing_AR, 1.0)))

    if abs(alpha_rad) <= alpha_stall
        CL = CL_linear
    else
        CL_peak = sign(alpha_rad) * CL_max
        CL_fp   = CD90 * sin(alpha_rad) * cos(alpha_rad)
        delta   = abs(alpha_rad) - alpha_stall
        decay   = exp(-delta / deg2rad(CL_efold_deg))
        CL = CL_peak * decay + CL_fp * (1 - decay)
    end
    result["cl"] = CL

    # ── Drag — component buildup (DATCOM / Raymer method) ──
    Cf = 0.455 / (log10(Re))^2.58      # Schoenherr turbulent flat-plate

    # Per-component: CD_f = Cf × Σ(FF_i × Swet_i) / Sref
    Swet_w  = get(state, "wing_wetted_area", 0.0)
    FF_w    = get(state, "wing_form_factor", 1.3)
    Swet_ht = get(state, "htail_wetted_area", 0.0)
    FF_ht   = get(state, "htail_form_factor", 1.2)
    Swet_vt = get(state, "vtail_wetted_area", 0.0)
    FF_vt   = get(state, "vtail_form_factor", 1.2)
    Swet_b  = get(state, "body_wetted_area", 0.0)
    FF_b    = get(state, "body_form_factor", 1.1)

    CD_f = Cf / Sref * (Swet_w * FF_w + Swet_ht * FF_ht +
                         Swet_vt * FF_vt + Swet_b * FF_b)
    CD_f *= 1.08   # +8% for interference, leakage, protuberances (Raymer Ch. 12)
    if CD_f < 1e-6
        CD_f = Cf * get(state, "total_wetted_area", 4.0 * Sref) / Sref
    end
    result["cd_friction"] = CD_f

    # Induced drag
    e_oswald = 0.8
    for surf in input.lifting_surfaces
        if !surf.vertical && lowercase(surf.name) != "htp"
            e_oswald = surf.Oswald_factor
            break
        end
    end
    CL_for_CDi = abs(alpha_rad) <= alpha_stall ? CL : sign(CL) * min(abs(CL), CL_max)
    CD_i = CL_for_CDi^2 / (π * wing_AR * e_oswald)

    # Deep-stall / flat-plate drag: CD = CD0 + (CD90 − CD0)·sin²α
    CD_extreme = CD_f + (CD90 - CD_f) * sin(alpha_rad)^2
    if abs(alpha_deg) > 30.0
        blend = clamp((abs(alpha_deg) - 30.0) / 15.0, 0.0, 1.0)
        CD_total = (1 - blend) * (CD_f + CD_i) + blend * CD_extreme
    else
        CD_total = CD_f + CD_i
    end
    result["cd_induced"] = CD_i

    # Wave drag (transonic/supersonic)
    CD_w = 0.0
    if mach > 0.7
        M_crit = 0.7 + 0.1 * cos(wing_sweep)
        if mach > M_crit
            CD_w = 0.002 * ((mach - M_crit) / 0.1)^2
        end
    end
    result["cd_wave"] = CD_w
    result["cd"] = CD_total + CD_w

    # ── Pitching moment ──
    xcg = get(state, "synths_xcg", 0.0)
    xw  = get(state, "synths_xw", 0.0)
    wing_mac = get(state, "wing_mac", cref)

    # AC location (quarter-chord + sweep effect)
    x_ac_wing = xw + 0.25 * wing_mac + 0.1 * wing_mac * tan(wing_sweep)

    # Cm0 from airfoil camber (thin-airfoil theory + 3D correction)
    # Section: Cm_ac ≈ −π·m·(1−2p) − 1.5·m  (fitted to DATCOM Section 4.1.2)
    # 3D:     Cm0  ≈ Cm_ac_2D × AR/(AR+2) × cos²Λ  (lifting-line correction)
    cam_pos = get(state, "wing_camber_position", 0.3)
    if wing_camber > 0.001
        Cm0_2d = -π * wing_camber * (1.0 - 2.0 * clamp(cam_pos, 0.1, 0.9)) -
                  1.5 * wing_camber
        Cm0 = Cm0_2d * wing_AR / (wing_AR + 2.0) * cos(wing_sweep)^2
    else
        Cm0 = 0.0
    end

    Cm_alpha = -CLa * (x_ac_wing - xcg) / cref

    # Tail pitching moment
    xh = get(state, "synths_xh", xw + 5.0)
    Cm_tail_eff = ht_area > 0 ? -(xh - xcg) / cref * CLa * tail_eff : 0.0

    Cm_alpha_total = Cm_alpha + Cm_tail_eff

    # Post-stall Cm decay from stall type
    Cm_efold_deg = stall_type == "leading_edge" ? 15.0 :
                   (stall_type == "combined" ? 22.0 : 30.0)

    if abs(alpha_rad) <= alpha_stall
        Cm_result = Cm0 + Cm_alpha_total * alpha_rad
    else
        Cm_at_stall = Cm0 + Cm_alpha_total * sign(alpha_rad) * alpha_stall
        delta_cm = abs(alpha_rad) - alpha_stall
        decay_cm = exp(-delta_cm / deg2rad(Cm_efold_deg))
        Cm_fp = -0.01 * sin(2 * alpha_rad)
        Cm_result = Cm_at_stall * decay_cm + Cm_fp * (1 - decay_cm)
    end
    result["cm"] = Cm_result

    # ══════════════════════════════════════════════════════════════
    # Dynamic stability derivatives (6 components)
    #
    # Each derivative is computed at its reference (α=0) value, then scaled
    # by α-dependent correction factors:
    #
    #   cos(α)  — geometric projection of rate-induced velocity onto the
    #             effective flow direction.  Naturally reverses sign for
    #             inverted flight (cos 180° = −1).
    #
    #   η_wing(α)  — wing effectiveness: degrades post-stall as lift curve
    #                slope → 0.  Recovers partially in flat-plate regime.
    #
    #   η_tail(α)  — horizontal tail effectiveness: degrades from wake
    #                immersion (≈ 15° onset), near-zero in deep stall,
    #                partial recovery in separated regime.
    #
    #   η_vtp(α)   — vertical tail effectiveness: less affected than HTP
    #                (not in wing wake plane), but degrades from fuselage
    #                vortex interaction at high α.
    #
    # References: DATCOM Sections 7.1–7.3, NASA TP-1538, Etkin ch. 5.
    # ══════════════════════════════════════════════════════════════

    # ── α-dependent effectiveness functions ──
    α_eff = acos(clamp(abs(cos(alpha_rad)), 0.0, 1.0))  # fold ±180° → 0–90°
    α_eff_deg = rad2deg(α_eff)
    cos_alpha = cos(alpha_rad)

    # Wing effectiveness: scales with CL_α(α)/CL_α(0)
    # Pre-stall ≈ 1, post-stall degrades to k_min ≈ 0.15
    α_stall_w = 15.0   # typical wing stall onset (deg)
    α_sep_w   = 40.0   # fully separated (deg)
    k_min_w   = 0.15   # flat-plate residual effectiveness
    if α_eff_deg <= α_stall_w
        η_wing = 1.0
    elseif α_eff_deg <= α_sep_w
        t = (α_eff_deg - α_stall_w) / (α_sep_w - α_stall_w)
        η_wing = 1.0 + t * (k_min_w - 1.0)
    else
        η_wing = k_min_w
    end

    # Horizontal tail effectiveness: degrades from wake immersion
    α_wake    = 15.0   # wake immersion onset (deg)
    α_deep    = 40.0   # deep stall (tail blanked)
    α_recover = 70.0   # partial recovery in separated regime
    k_deep    = 0.1    # residual in deep stall
    k_recover = 0.4    # recovery in flat-plate regime
    if α_eff_deg <= α_wake
        η_tail = 1.0
    elseif α_eff_deg <= α_deep
        t = (α_eff_deg - α_wake) / (α_deep - α_wake)
        η_tail = 1.0 + t * (k_deep - 1.0)
    elseif α_eff_deg <= α_recover
        t = (α_eff_deg - α_deep) / (α_recover - α_deep)
        η_tail = k_deep + t * (k_recover - k_deep)
    else
        η_tail = k_recover
    end

    # Vertical tail effectiveness: less affected (not in wing wake plane)
    α_vtp_onset = 20.0  # fuselage vortex onset
    α_vtp_deep  = 50.0  # degraded regime
    k_vtp_min   = 0.3   # residual
    if α_eff_deg <= α_vtp_onset
        η_vtp = 1.0
    elseif α_eff_deg <= α_vtp_deep
        t = (α_eff_deg - α_vtp_onset) / (α_vtp_deep - α_vtp_onset)
        η_vtp = 1.0 + t * (k_vtp_min - 1.0)
    else
        η_vtp = k_vtp_min
    end

    # ── Common full-envelope activation functions (shared by Cm_q, Cl_p, Cn_r) ──
    # linear_activation: 1 in attached flow, fades through stall via tanh (~3° width)
    # rev_activation:    0 in attached flow, 1 near |α|=180° (reversed flow regime)
    # These are the engine behind the "damping returns at reduced magnitude in
    # reversed flight" behaviour — the sign stays consistent with the forward
    # value (no spurious cos α sign flip at ±180°).
    α_stall_deg       = rad2deg(alpha_stall)
    α_abs_deg         = abs(alpha_deg)
    linear_activation = 0.5 * (1.0 - tanh((α_abs_deg - α_stall_deg) / 3.0))
    α_rev_onset_deg   = 180.0 - α_stall_deg
    rev_activation    = 0.5 * (1.0 + tanh((α_abs_deg - α_rev_onset_deg) / 3.0))

    # ── Pitch damping  Cm_q ── (DATCOM 7.2 extended to full ±180° envelope)
    #
    # Physical regimes (Wing+Body interpretation):
    #   1. Attached flow (|α| < α_stall):  Cm_q ≈ cmq_ref (negative, damping).
    #      Dominated by HTP through −2 CLα_t η_t V_H l_t/c; wing+body adds a small
    #      additional negative term when x_ac_wing is behind the CG.
    #   2. Stall / post-stall:  damping fades smoothly as the HTP is blanked
    #      by wing wake and separated flow.  No pitch-autorotation analogue
    #      exists — unlike roll, the pitch axis has no two-surface differential
    #      mechanism that reverses sign past stall.
    #   3. Broadside (|α| ≈ 60°–120°):  Cm_q ≈ 0, no coherent damping.
    #   4. Reversed flow (|α| → 180°):  Cm_q negative, ~20% of forward magnitude.
    #      In reversed flight the HTP is in front of the CG and deep-stalled,
    #      so near useless.  The residual damping is wing+body-dominated —
    #      left-right AND (approximately) fore-aft symmetric for the mechanism,
    #      so the sign does NOT flip; only the reversed-airfoil efficiency
    #      reduces the magnitude.
    if ht_area > 0
        l_t     = xh - xcg
        V_H     = ht_area * l_t / (Sref * cref)
        cmq_ref = -2 * CLa_t * eta_t * V_H * l_t / cref
    else
        cmq_ref = -5.0
    end
    poststall_pitch_activation = 0.5 * (1.0 + tanh((abs(alpha_deg) - (rad2deg(alpha_stall) + 6.0)) / 8.0))
    broadside_activation_pitch = sin(alpha_rad)^2
    pitch_crossflow_scale = 0.08 * poststall_pitch_activation *
                            broadside_activation_pitch * (1.0 - rev_activation)
    result["cmq"] = cmq_ref * (linear_activation + pitch_crossflow_scale + 0.20 * rev_activation)

    # ── α̇ damping  Cm_α̇ (downwash-lag) ──
    # Same full-envelope shape as Cm_q, scaled by dε/dα.
    if ht_area > 0
        result["cm_alpha_dot"] = cmq_ref * deda *
                                  (linear_activation + pitch_crossflow_scale + 0.20 * rev_activation)
    else
        result["cm_alpha_dot"] = 0.0
    end

    # ── Roll damping  Cl_p ── (DATCOM 7.1.2.2 extended to full ±180° envelope)
    #
    # Physical regimes, in order:
    #   1. Attached flow (|α| < α_stall):  Cl_p = clp_ref  (negative, damping).
    #      Down-going wing sees higher α_local → more lift → opposes roll.
    #   2. Autorotation (|α| just past stall):  Cl_p swings POSITIVE.
    #      Down-going wing past CL_max loses lift while up-going wing still on
    #      the linear slope gains lift → differential reinforces roll.  This is
    #      the aerodynamic basis of spin entry / autorotation.
    #   3. Broadside (|α| ≈ 40°–140°):  Cl_p ≈ 0.  Both halves fully separated,
    #      no coherent circulation-based roll response.
    #   4. Reversed flow (|α| → 180°):  Cl_p negative again, ~65% magnitude.
    #      The wing is left-right symmetric, so its damping geometry is
    #      direction-invariant — sign does NOT flip.  Magnitude is reduced
    #      because the reversed airfoil (sharp TE now leading) has lower
    #      dCl_sect/dα and earlier separation.
    clp_ref = -CLa_wing / 12 * (1 + 3 * wing_TR) / (1 + wing_TR) *
               cos(wing_sweep)

    # Autorotation: positive Gaussian lobes just past ±α_stall.
    # Peak amplitude ≈ 0.5·|clp_ref| and width ~6° are consistent with
    # rotation-balance data (NACA / Bihrle).  The lobes sit where only the
    # down-going wing is post-stall — the self-sustaining autorotation window.
    # Keep the autorotation lobe deliberately modest. A large positive Cl_p
    # is negative roll damping; in the real aircraft it may support spin entry,
    # but in the simulator it can create explosive angular accelerations when
    # an upset starts below stall speed.
    autorot_amp   = 0.22 * abs(clp_ref)
    α_autorot_ctr = α_stall_deg + 5.0
    α_autorot_wid = 6.0
    autorot_lobe  = autorot_amp * (
        exp(-((alpha_deg - α_autorot_ctr) / α_autorot_wid)^2) +
        exp(-((alpha_deg + α_autorot_ctr) / α_autorot_wid)^2)
    )

    # Reversed-flow damping is 65% of forward (reversed airfoil has reduced
    # but still-positive dCl_sect/dα; the wing's damping geometry is
    # left-right symmetric, so the sign is preserved).
    poststall_roll_damping = -0.12 * abs(clp_ref) * poststall_pitch_activation *
                             broadside_activation_pitch * (1.0 - rev_activation)
    clp_raw = clp_ref * (linear_activation + 0.65 * rev_activation) +
              autorot_lobe + poststall_roll_damping
    # Keep the default autorotation lobe below the validation warning
    # threshold.  Positive Cl_p is negative roll damping; it is physically
    # possible just past stall, but a default flight-sim export should not
    # create self-accelerating upset behavior unless a spin model is tuned on
    # purpose.
    positive_roll_damping_cap = min(0.018, 0.025 * abs(clp_ref))
    result["clp"] = min(clp_raw, positive_roll_damping_cap)

    # ── Yaw damping  Cn_r ── (DATCOM 7.3 extended to full ±180° envelope)
    #
    # Physical regimes (whole-aircraft interpretation):
    #   1. Attached flow (|α| < α_stall):  Cn_r ≈ cnr_ref (negative, damping).
    #      Dominated by VTP through −2 CLα_v η_v (S_v/S)(l_v/b)².
    #   2. Post-stall: the VTP contribution degrades, but whole-aircraft yaw
    #      damping does NOT vanish. Separated cross-flow on the fuselage/aft body
    #      still produces a restoring yawing moment when the aircraft yaws.
    #   3. Broadside (|α| ≈ 60°–120°):  circulation-based VTP damping is weak,
    #      but bluff-body cross-flow keeps a meaningful negative residual.
    #   4. Reversed flow (|α| → 180°):  damping remains negative. The VTP is
    #      strongly degraded, yet the body/wing cross-flow mechanism is largely
    #      fore-aft symmetric, so the sign is preserved and the magnitude stays
    #      non-trivial instead of collapsing to zero.
    vt_area = get(state, "vtail_area", 0.0)
    if vt_area > 0
        xv  = get(state, "synths_xv", xw + 5.0)
        l_v = xv - xcg
        vt_AR     = get(state, "vtail_aspect_ratio", 1.5)
        vt_sweep  = deg2rad(get(state, "vtail_sweep_deg", 30.0))
        vt_AR_eff = vt_AR * 1.6
        CLa_v = CLa_2d * vt_AR_eff / (2 + sqrt(4 + (vt_AR_eff * beta_pg)^2 *
                                                 (1 + tan(vt_sweep)^2 / beta_pg^2)))
        eta_v = 0.95
        cnr_ref = -2 * CLa_v * eta_v * (vt_area / Sref) * (l_v / bref)^2
    else
        cnr_ref = -0.1
    end

    body_length = get(state, "body_length", 0.0)
    body_radius = get(state, "body_max_radius", 0.0)
    body_side_area = body_length > 0.0 && body_radius > 0.0 ?
                     body_length * (2.0 * body_radius) : 0.0
    body_geom_factor = body_side_area > 0.0 ?
                       (body_side_area / max(Sref, 1e-3)) *
                       clamp(body_length / max(bref, 1e-3), 0.4, 2.0) :
                       0.0

    # Residual yaw damping from fuselage/body cross-flow. This must not be
    # capped by the attached-flow VTP damping: in deep stall and broadside
    # attitudes the bluff fuselage/wing cross-flow is the mechanism that keeps
    # yaw rate from running away.
    cnr_body_mag = clamp(0.06 + 0.12 * body_geom_factor + 0.20 * abs(cnr_ref),
                         0.08, 0.24)
    cnr_body_ref = -cnr_body_mag

    # Tail contribution: strong in attached flow, reduced but not annihilated
    # in deep stall, with a smaller reversed-flow residual.
    tail_deep_scale = 0.35 * η_vtp * (0.25 + 0.75 * cos_alpha^2)
    tail_reverse_scale = 0.12
    tail_scale = linear_activation + (1.0 - linear_activation) *
                 ((1.0 - rev_activation) * tail_deep_scale +
                  rev_activation * tail_reverse_scale)

    # Body contribution: ramps in after stall, is strongest near broadside,
    # and stays largely intact in reversed flow.
    poststall_activation = 0.5 * (1.0 + tanh((α_abs_deg - (α_stall_deg + 8.0)) / 8.0))
    broadside_activation = sin(α_eff)^2
    body_scale = poststall_activation *
                 (0.75 + 0.25 * broadside_activation) *
                 (1.0 + 0.25 * rev_activation)
    poststall_onset_deg = max(rad2deg(alpha_stall) + 12.0, 28.0)
    poststall_activation = 0.5 * (1.0 + tanh((abs(alpha_deg) - poststall_onset_deg) / 10.0))
    broadside_activation = sin(alpha_rad)^2
    body_scale = poststall_activation *
                 (0.45 + 0.40 * broadside_activation + 0.20 * rev_activation)

    cnr_raw = cnr_ref * tail_scale + cnr_body_ref * body_scale
    cnr_attached_floor = max(abs(cnr_ref), 0.055)
    cnr_poststall_floor = clamp(0.08 + 0.10 * body_geom_factor + 0.15 * abs(cnr_ref),
                                0.08, 0.22)
    cnr_reverse_floor = clamp(0.10 + 0.08 * body_geom_factor + 0.15 * abs(cnr_ref),
                              0.10, 0.24)
    # Avoid a nonphysical alpha=0 "hole" in yaw damping. If the post-stall
    # residual floor is stronger than the attached-flow estimate, raise the
    # attached floor too and keep the separated/reversed residual slightly
    # below the attached-flow value.
    cnr_attached_floor = max(cnr_attached_floor,
                             cnr_poststall_floor / 0.90,
                             cnr_reverse_floor / 0.92)
    cnr_poststall_floor = min(cnr_poststall_floor, 0.90 * cnr_attached_floor)
    cnr_reverse_floor = min(cnr_reverse_floor, 0.92 * cnr_attached_floor)
    cnr_floor = linear_activation * cnr_attached_floor +
                (1.0 - linear_activation) *
                ((1.0 - rev_activation) * cnr_poststall_floor +
                 rev_activation * cnr_reverse_floor)
    result["cnr"] = min(cnr_raw, -cnr_floor)

    # ── β̇ damping  Cn_β̇ (sidewash-lag) ──
    # Remains primarily a tail/sidewash-lag effect, so it follows the degraded
    # VTP term rather than the full body-crossflow yaw-damping floor above.
    if vt_area > 0
        dsdbeta = 0.10
        beta_dot_scale = linear_activation + (1.0 - linear_activation) *
                         ((1.0 - rev_activation) * (0.30 * η_vtp) +
                          rev_activation * 0.08)
        result["cn_beta_dot"] = cnr_ref * dsdbeta * beta_dot_scale
    else
        result["cn_beta_dot"] = 0.0
    end

    # ── Lift due to pitch rate  CL_q ──
    # CL_q = 2 CLα_t η_t (S_t/S) (l_t/c) × cos(α) × η_tail(α)
    # (DATCOM Section 7.2)
    if ht_area > 0
        l_t = xh - xcg
        clq_ref = 2 * CLa_t * eta_t * (ht_area / Sref) * (l_t / cref)
        result["cl_q"] = clq_ref * cos_alpha * η_tail
    else
        result["cl_q"] = 0.0
    end

    # ── Side force due to roll rate  CY_p ──
    # VTP contribution: CY_p_VT = 2 CLα_v (S_v/S) (z_v/b) × cos(α)
    # Wing contribution: CY_p_wing ∝ CL(α) — scales with actual lift
    # Combined: CY_p(α=0) × cos(α) × η_wing(α)
    if vt_area > 0
        zv_root  = get(state, "synths_zv", 0.0)
        z_cg     = get(state, "synths_zcg", 0.0)
        vt_span  = get(state, "vtail_span", 1.0)
        z_vtp_ac = zv_root - 0.4 * vt_span
        dz_v     = z_vtp_ac - z_cg
        vt_AR_eff2 = get(state, "vtail_aspect_ratio", 1.5) * 1.6
        CLa_v2 = CLa_2d * vt_AR_eff2 / (2 + sqrt(4 + (vt_AR_eff2 * beta_pg)^2))
        cyp_ref = 2 * CLa_v2 * (vt_area / Sref) * (dz_v / bref)
        result["cy_p"] = cyp_ref * cos_alpha * η_wing
    else
        result["cy_p"] = 0.0
    end

    # ── Side force due to yaw rate  CY_r ──
    # CY_r = 2 CLα_v η_v (S_v/S) (l_v/b) × cos(α) × η_vtp(α)
    # (DATCOM Section 7.3)
    if vt_area > 0
        xv  = get(state, "synths_xv", xw + 5.0)
        l_v = xv - xcg
        vt_AR_eff3 = get(state, "vtail_aspect_ratio", 1.5) * 1.6
        vt_sweep3  = deg2rad(get(state, "vtail_sweep_deg", 30.0))
        CLa_v3 = CLa_2d * vt_AR_eff3 / (2 + sqrt(4 + (vt_AR_eff3 * beta_pg)^2 *
                                                   (1 + tan(vt_sweep3)^2 / beta_pg^2)))
        cyr_ref = 2 * CLa_v3 * 0.95 * (vt_area / Sref) * (l_v / bref)
        result["cy_r"] = cyr_ref * cos_alpha * η_vtp
    else
        result["cy_r"] = 0.0
    end

    return result
end
