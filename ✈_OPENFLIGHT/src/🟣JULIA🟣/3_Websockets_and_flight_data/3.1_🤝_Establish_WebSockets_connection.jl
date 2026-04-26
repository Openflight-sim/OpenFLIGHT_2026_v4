# NEW: Import the MsgPack library
using MsgPack

"""
    reload_all_external_data!()

Re-read all external YAML files (mission + aircraft aerodynamic data) and rebuild
the global `aircraft_flight_physics_and_propulsive_data` NamedTuple used by the
physics engine.  Called when the frontend sends `reload_data: true`.
"""
function reload_all_external_data!()
    println("\n╔══════════════════════════════════════════════╗")
    println("║  RELOADING ALL EXTERNAL DATA FROM DISK...   ║")
    println("╚══════════════════════════════════════════════╝")

    # Use project_dir (set in OpenFLIGHT.jl) to derive stable paths
    # project_dir = <workspace>/✈_OPENFLIGHT
    workspace_root = normpath(joinpath(project_dir, ".."))

    # ── 1) Re-read mission YAML ──────────────────────────────────────
    mission_file = normpath(joinpath(workspace_root, "default_mission.yaml"))
    if isfile(mission_file)
        new_mission = YAML.load_file(mission_file)
        # Update the existing MISSION_DATA dict in-place
        empty!(MISSION_DATA)
        merge!(MISSION_DATA, new_mission)
        println("  ✓ Mission data reloaded from: $mission_file")
    else
        println("  ⚠ Mission file not found: $mission_file — keeping previous data")
    end

    # ── 2) Re-read aircraft aerodynamic YAML ─────────────────────────
    aircraft_folder_name = get(MISSION_DATA, "aircraft_name", "")
    if isempty(aircraft_folder_name)
        println("  ⚠ No aircraft_name in MISSION_DATA — skipping aero data reload")
        return false
    end

    workspace_entries = readdir(workspace_root)
    hangar_idx = findfirst(name -> occursin("HANGAR", name), workspace_entries)

    local new_aircraft_dir = ""
    if hangar_idx !== nothing
        hangar_root = joinpath(workspace_root, workspace_entries[hangar_idx])
        hangar_entries = readdir(hangar_root)
        aircraft_idx = findfirst(name -> lowercase(name) == lowercase(aircraft_folder_name), hangar_entries)
        if aircraft_idx !== nothing
            new_aircraft_dir = normpath(joinpath(hangar_root, hangar_entries[aircraft_idx]))
        end
    end

    if isempty(new_aircraft_dir) || !isdir(new_aircraft_dir)
        println("  ⚠ Aircraft folder not found for '$aircraft_folder_name' — keeping previous data")
        return false
    end

    # Find YAML file using the same mode-aware selection as the main loader.
    aircraft_files = readdir(new_aircraft_dir)
    aero_mode = lowercase(string(get(MISSION_DATA, "aerodynamic_model_mode", "table")))
    preferred_suffix = aero_mode == "linear" ? ".linearized.aero_prop.yaml" : ".tabular.aero_prop.yaml"
    yaml_idx = _find_preferred_aircraft_file(aircraft_files, preferred_suffix, aircraft_folder_name)
    if yaml_idx === nothing
        yaml_idx = _find_preferred_aircraft_file(aircraft_files, ".aero_prop.yaml", aircraft_folder_name)
    end
    if yaml_idx === nothing
        yaml_idx = _find_preferred_aircraft_file(aircraft_files, ".yaml", aircraft_folder_name)
    end
    if yaml_idx === nothing
        yaml_idx = _find_preferred_aircraft_file(aircraft_files, ".yml", aircraft_folder_name)
    end
    if yaml_idx === nothing
        println("  ⚠ No aerodynamic data file in aircraft folder: $new_aircraft_dir")
        println("    Expected *.tabular.aero_prop.yaml, *.linearized.aero_prop.yaml, *.aero_prop.yaml, or a legacy aero *.yaml/*.yml.")
        println("    render_settings.yaml is visual-only and is not valid aerodynamic data.")
        return false
    end
    yaml_path = normpath(joinpath(new_aircraft_dir, aircraft_files[yaml_idx]))
    println("  ✓ Re-reading aircraft data from: $yaml_path")

    # Update aircraft_dir global
    global aircraft_dir = new_aircraft_dir

    # Find GLB model
    glb_idx = findfirst(name -> lowercase(splitext(name)[2]) == ".glb", aircraft_files)
    global aircraft_glb_path = glb_idx !== nothing ? normpath(joinpath(new_aircraft_dir, aircraft_files[glb_idx])) : nothing
    global aircraft_glb_filename = glb_idx !== nothing ? aircraft_files[glb_idx] : nothing

    # Reload per-aircraft render_settings.yaml (if present). Same contract
    # as the initial load in 0.1_...: optional file, overrides JS defaults
    # for GLB transform / lights / propeller / cockpit & wing cameras.
    _render_settings_idx = findfirst(
        name -> lowercase(name) == "render_settings.yaml",
        aircraft_files,
    )
    global aircraft_render_settings = if _render_settings_idx !== nothing
        try
            _rs_raw = YAML.load_file(normpath(joinpath(
                new_aircraft_dir, aircraft_files[_render_settings_idx]
            )))
            println("  ✓ Reloaded render_settings.yaml")
            _deep_stringify_keys(_rs_raw)
        catch _rs_err
            println("  ⚠ Failed to parse render_settings.yaml ($(_rs_err)) — JS will use defaults")
            nothing
        end
    else
        nothing
    end

    # Parse the YAML
    raw_yaml = YAML.load_file(yaml_path)
    normalized_yaml = _deep_stringify_keys(raw_yaml)
    aero_db = parse_aero_data(raw_yaml)

    # Rebuild derived data
    default_config = extract_default_configuration(normalized_yaml)
    available_configs = extract_available_configurations(normalized_yaml, default_config)
    engines = extract_engine_models(normalized_yaml, aero_db)
    spool_ups = [e.spool_up_speed for e in engines]
    spool_downs = [e.spool_down_speed for e in engines]
    reverse_ratios = [e.reverse_thrust_ratio for e in engines]
    max_thrust = sum(e.max_thrust_newton for e in engines)
    inertia = Base.invokelatest(extract_inertia_tensor, normalized_yaml, aero_db)
    tail_surface_geometry = extract_tail_surface_geometry(normalized_yaml)
    horizontal_tail_ac_xyz_m = tail_surface_ac_xyz(
        tail_surface_geometry,
        "horizontal",
        [
            fetch_optional_constant(aero_db, "x_horizontal_tail_aerodynamic_center", 0.0),
            fetch_optional_constant(aero_db, "y_horizontal_tail_aerodynamic_center", 0.0),
            fetch_optional_constant(aero_db, "z_horizontal_tail_aerodynamic_center", 0.0),
        ],
    )
    vertical_tail_ac_xyz_m = tail_surface_ac_xyz(
        tail_surface_geometry,
        "vertical",
        [
            fetch_optional_constant(aero_db, "x_vertical_tail_aerodynamic_center", 0.0),
            fetch_optional_constant(aero_db, "y_vertical_tail_aerodynamic_center", 0.0),
            fetch_optional_constant(aero_db, "z_vertical_tail_aerodynamic_center", 0.0),
        ],
    )

    # Visual geometry. Linearized companion files may omit this section, so
    # reuse the tabular aircraft geometry when available.
    _visual_geometry_result = _visual_geometry_from_selected_or_companion(
        normalized_yaml,
        new_aircraft_dir,
        aircraft_files,
        aircraft_files[yaml_idx],
        aircraft_folder_name,
    )
    global aircraft_visual_geometry = _visual_geometry_result[1]
    global aircraft_visual_geometry_source = _visual_geometry_result[2]

    # ── 3) Rebuild the NamedTuple ────────────────────────────────────
    global aircraft_aero_and_propulsive_database = aero_db

    global aircraft_flight_physics_and_propulsive_data = (
        default_configuration=default_config,
        available_configurations=available_configs,
        engines=engines,
        engine_count=length(engines),
        engine_spool_up_speeds=spool_ups,
        engine_spool_down_speeds=spool_downs,
        engine_reverse_thrust_ratios=reverse_ratios,
        aircraft_mass=fetch_required_numeric_constant(aero_db, "aircraft_mass"; aliases=["mass_kg"]),
        x_CoG=fetch_optional_constant(aero_db, "x_CoG", 0.0; aliases=["x_cog_m", "x_cg_m", "cg_ref_m.x"]),
        y_CoG=fetch_optional_constant(aero_db, "y_CoG", 0.0; aliases=["y_cog_m", "y_cg_m", "cg_ref_m.y"]),
        z_CoG=fetch_optional_constant(aero_db, "z_CoG", 0.0; aliases=["z_cog_m", "z_cg_m", "cg_ref_m.z"]),
        x_wing_aerodynamic_center=fetch_optional_constant(aero_db, "x_wing_aerodynamic_center", 0.0; aliases=["x_wing_aerodynamic_center_m", "wing_fuselage_aero_center_x", "wing_aerodynamic_center.x"]),
        wing_lift_lever_arm_wrt_CoG_over_MAC=-1.0 * (
            fetch_optional_constant(aero_db, "x_wing_aerodynamic_center", 0.0; aliases=["x_wing_aerodynamic_center_m"]) -
            fetch_optional_constant(aero_db, "x_CoG", 0.0; aliases=["x_cog_m", "x_cg_m", "cg_ref_m.x"])
        ) / fetch_optional_constant(aero_db, "wing_mean_aerodynamic_chord", 1.0; aliases=["mean_aerodynamic_chord_m", "mac_m", "c_ref_m", "geometry.c_ref_m"]),
        reference_area=fetch_required_numeric_constant(aero_db, "reference_area"; aliases=["reference_area_m2", "s_ref_m2", "geometry.S_ref_m2"]),
        reference_span=fetch_required_numeric_constant(aero_db, "reference_span"; aliases=["reference_span_m", "b_ref_m", "geometry.b_ref_m"]),
        AR=fetch_optional_constant(aero_db, "AR",
            (fetch_optional_constant(aero_db, "reference_span", 1.0; aliases=["b_ref_m", "geometry.b_ref_m"])^2) / fetch_optional_constant(aero_db, "reference_area", 1.0; aliases=["s_ref_m2", "geometry.S_ref_m2"]);
            aliases=["aspect_ratio"]),
        Oswald_factor=fetch_optional_constant(aero_db, "Oswald_factor", 0.8; aliases=["oswald", "oswald_factor", "oswald_efficiency_factor"]),
        wing_mean_aerodynamic_chord=fetch_required_numeric_constant(aero_db, "wing_mean_aerodynamic_chord"; aliases=["mean_aerodynamic_chord_m", "mac_m", "c_ref_m", "geometry.c_ref_m"]),
        wing_fuselage_reference_area=fetch_optional_constant(aero_db, "reference_area", 1.0; aliases=["reference_area_m2", "s_ref_m2", "geometry.S_ref_m2"]),
        wing_fuselage_aero_center_x=fetch_optional_constant(
            aero_db,
            "x_wing_fuselage_aerodynamic_center",
            fetch_optional_constant(aero_db, "x_wing_body_neutral_point", 0.0);
            aliases=["wing_aerodynamic_center.x"]
        ),
        wing_fuselage_aero_center_y=fetch_optional_constant(
            aero_db,
            "y_wing_fuselage_aerodynamic_center",
            fetch_optional_constant(aero_db, "y_wing_body_neutral_point", 0.0);
            aliases=["wing_aerodynamic_center.y"]
        ),
        wing_fuselage_aero_center_z=fetch_optional_constant(
            aero_db,
            "z_wing_fuselage_aerodynamic_center",
            fetch_optional_constant(aero_db, "z_wing_body_neutral_point", 0.0);
            aliases=["wing_aerodynamic_center.z"]
        ),
        x_wing_body_neutral_point=fetch_optional_constant(
            aero_db,
            "x_wing_body_neutral_point",
            fetch_optional_constant(aero_db, "x_wing_fuselage_aerodynamic_center", 0.0)
        ),
        y_wing_body_neutral_point=fetch_optional_constant(
            aero_db,
            "y_wing_body_neutral_point",
            fetch_optional_constant(aero_db, "y_wing_fuselage_aerodynamic_center", 0.0)
        ),
        z_wing_body_neutral_point=fetch_optional_constant(
            aero_db,
            "z_wing_body_neutral_point",
            fetch_optional_constant(aero_db, "z_wing_fuselage_aerodynamic_center", 0.0)
        ),
        x_aero_reference_CoG=fetch_optional_constant(
            aero_db,
            "x_aero_reference_CoG",
            fetch_optional_constant(aero_db, "x_CoG", 0.0; aliases=["x_cog_m", "x_cg_m", "cg_ref_m.x"])
        ),
        y_aero_reference_CoG=fetch_optional_constant(
            aero_db,
            "y_aero_reference_CoG",
            fetch_optional_constant(aero_db, "y_CoG", 0.0; aliases=["y_cog_m", "y_cg_m", "cg_ref_m.y"])
        ),
        z_aero_reference_CoG=fetch_optional_constant(
            aero_db,
            "z_aero_reference_CoG",
            fetch_optional_constant(aero_db, "z_CoG", 0.0; aliases=["z_cog_m", "z_cg_m", "cg_ref_m.z"])
        ),
        tail_reference_area=fetch_optional_constant(aero_db, "tail_reference_area", 0.0),
        horizontal_tail_reference_area=fetch_optional_constant(
            aero_db,
            "horizontal_tail_reference_area",
            fetch_optional_constant(aero_db, "tail_reference_area", 0.0)
        ),
        vertical_tail_reference_area=fetch_optional_constant(aero_db, "vertical_tail_reference_area", 0.0),
        tail_aero_center_x=fetch_optional_constant(aero_db, "x_tail_aerodynamic_center", 0.0),
        tail_aero_center_y=fetch_optional_constant(aero_db, "y_tail_aerodynamic_center", 0.0),
        tail_aero_center_z=fetch_optional_constant(aero_db, "z_tail_aerodynamic_center", 0.0),
        x_horizontal_tail_aerodynamic_center=horizontal_tail_ac_xyz_m[1],
        y_horizontal_tail_aerodynamic_center=horizontal_tail_ac_xyz_m[2],
        z_horizontal_tail_aerodynamic_center=horizontal_tail_ac_xyz_m[3],
        x_vertical_tail_aerodynamic_center=vertical_tail_ac_xyz_m[1],
        y_vertical_tail_aerodynamic_center=vertical_tail_ac_xyz_m[2],
        z_vertical_tail_aerodynamic_center=vertical_tail_ac_xyz_m[3],
        tail_CL_q=fetch_optional_constant(aero_db, "tail_CL_q", 3.0),
        tail_CS_r=fetch_optional_constant(aero_db, "tail_CS_r", 0.5),
        tail_CD0=fetch_optional_constant(aero_db, "tail_CD0", 0.015),
        tail_k_induced=fetch_optional_constant(aero_db, "tail_k_induced", 0.20),
        tail_k_side=fetch_optional_constant(aero_db, "tail_k_side", 0.10),
        horizontal_tail_downwash_slope=fetch_optional_constant(aero_db, "horizontal_tail_downwash_slope", 0.35),
        horizontal_tail_downwash_max_abs_deg=fetch_optional_constant(aero_db, "horizontal_tail_downwash_max_abs_deg", 12.0),
        vertical_tail_sidewash_slope=fetch_optional_constant(aero_db, "vertical_tail_sidewash_slope", 0.20),
        vertical_tail_sidewash_max_abs_deg=fetch_optional_constant(aero_db, "vertical_tail_sidewash_max_abs_deg", 10.0),
        scale_tail_forces=fetch_optional_constant(aero_db, "scale_tail_forces", 1.0),
        max_aileron_deflection_deg=_extract_max_deflection_deg(normalized_yaml, "aileron", 25.0),
        max_elevator_deflection_deg=_extract_max_deflection_deg(normalized_yaml, "elevator", 25.0),
        max_rudder_deflection_deg=_extract_max_deflection_deg(normalized_yaml, "rudder", 30.0),
        Cl_da=fetch_optional_constant(aero_db, "Cl_da", 0.0),
        Cm_de=fetch_optional_constant(aero_db, "Cm_de", 0.0),
        Cn_dr=fetch_optional_constant(aero_db, "Cn_dr", 0.0),
        Cn_da=fetch_optional_constant(aero_db, "Cn_da", 0.0),
        Cm0=fetch_optional_constant(aero_db, "Cm0", 0.0),
        Cm_trim=fetch_optional_constant(aero_db, "Cm_trim", 0.0),
        Cn_beta=fetch_optional_constant(aero_db, "Cn_beta", 0.0),
        Cl_beta=fetch_optional_constant(aero_db, "Cl_beta", 0.0),
        Cm_alpha=fetch_optional_constant(aero_db, "Cm_alpha", 0.0),
        Cl_p=fetch_optional_constant(aero_db, "Cl_p", 0.0),
        Cm_q=fetch_optional_constant(aero_db, "Cm_q", 0.0),
        Cn_r=fetch_optional_constant(aero_db, "Cn_r", 0.0),
        Cn_p=fetch_optional_constant(aero_db, "Cn_p", 0.0),
        Cl_r=fetch_optional_constant(aero_db, "Cl_r", 0.0),
        maximum_thrust_at_sea_level=max_thrust,
        thrust_installation_angle_DEG=fetch_optional_constant(aero_db, "thrust_installation_angle_DEG", 0.0; aliases=["thrust_installation_angle_deg"]),
        # Priority: mission YAML override → aero YAML value → 4.0 /s default.
        # Exposing this in the mission lets a user tune control feel per
        # session without editing the aircraft database.
        control_actuator_speed=Float64(get(
            MISSION_DATA,
            "control_actuator_speed",
            fetch_optional_constant(aero_db, "control_actuator_speed", 4.0;
                                    aliases=["actuator_speed_per_s"])
        )),
        engine_spool_up_speed=_vector_mean(spool_ups, fetch_optional_constant(aero_db, "engine_spool_up_speed", 1.0; aliases=["engine_spool_up_per_s"])),
        engine_spool_down_speed=_vector_mean(spool_downs, fetch_optional_constant(aero_db, "engine_spool_down_speed", 1.0; aliases=["engine_spool_down_per_s"])),
        alpha_stall_positive=fetch_optional_constant(aero_db, "alpha_stall_positive", 15.0),
        alpha_stall_negative=fetch_optional_constant(aero_db, "alpha_stall_negative", -15.0),
        CL_max=fetch_optional_constant(aero_db, "CL_max", 1.2),
        stall_speed_sea_level_m_s=fetch_optional_constant(aero_db, "stall_speed_sea_level_m_s", 0.0),
        stall_speed_analysis_altitude_m_s=fetch_optional_constant(aero_db, "stall_speed_analysis_altitude_m_s", 0.0),
        recommended_initial_velocity_m_s=fetch_optional_constant(aero_db, "recommended_initial_velocity_m_s", 0.0),
        CD0=fetch_optional_constant(aero_db, "CD0", 0.013),
        dynamic_stall_alpha_on_deg=fetch_optional_constant(aero_db, "dynamic_stall_alpha_on_deg",
            max(abs(fetch_optional_constant(aero_db, "alpha_stall_positive", 15.0)),
                abs(fetch_optional_constant(aero_db, "alpha_stall_negative", -15.0)))),
        dynamic_stall_alpha_off_deg=fetch_optional_constant(aero_db, "dynamic_stall_alpha_off_deg",
            max(max(abs(fetch_optional_constant(aero_db, "alpha_stall_positive", 15.0)),
                    abs(fetch_optional_constant(aero_db, "alpha_stall_negative", -15.0))) - 4.0, 0.0)),
        dynamic_stall_tau_alpha_s=fetch_optional_constant(aero_db, "dynamic_stall_tau_alpha_s", 0.08),
        dynamic_stall_tau_sigma_rise_s=fetch_optional_constant(aero_db, "dynamic_stall_tau_sigma_rise_s", 0.12),
        dynamic_stall_tau_sigma_fall_s=fetch_optional_constant(aero_db, "dynamic_stall_tau_sigma_fall_s", 0.35),
        dynamic_stall_qhat_to_alpha_deg=fetch_optional_constant(aero_db, "dynamic_stall_qhat_to_alpha_deg", 2.0),
        poststall_cl_scale=fetch_optional_constant(aero_db, "poststall_cl_scale", 1.1),
        poststall_cd90=fetch_optional_constant(aero_db, "poststall_cd90", 1.6),
        poststall_cd_min=fetch_optional_constant(aero_db, "poststall_cd_min", 0.08),
        poststall_sideforce_scale=fetch_optional_constant(aero_db, "poststall_sideforce_scale", 0.70),
        CL_0=fetch_optional_constant(aero_db, "CL_0", 0.35; aliases=["cl_0"]),
        CL_alpha=fetch_optional_constant(aero_db, "CL_alpha", 5.50; aliases=["cl_alpha"]),
        CL_q_hat=fetch_optional_constant(aero_db, "CL_q_hat", 4.00; aliases=["cl_q_hat", "cl_q"]),
        CL_delta_e=fetch_optional_constant(aero_db, "CL_delta_e", 0.40; aliases=["cl_delta_e", "cl_de"]),
        CY_beta=fetch_optional_constant(aero_db, "CY_beta", -0.50; aliases=["cy_beta", "cs_beta"]),
        CY_delta_r=fetch_optional_constant(aero_db, "CY_delta_r", 0.15; aliases=["cy_delta_r", "cs_delta_r"]),
        # Keep reload control derivatives in the same units as startup:
        # exported *_per_deg values are converted to per-radian scalars.
        Cl_delta_a=fetch_optional_constant_with_per_degree_alias(
            aero_db,
            "Cl_delta_a",
            0.20;
            aliases=["cl_delta_a_linear", "Cl_da", "cl_da"],
            per_degree_aliases=["Cl_da_per_deg", "cl_da_per_deg"]
        ),
        Cl_delta_r=fetch_optional_constant(aero_db, "Cl_delta_r", 0.0; aliases=["Cl_dr", "cl_dr"]),
        Cm_delta_e=fetch_optional_constant_with_per_degree_alias(
            aero_db,
            "Cm_delta_e",
            -1.50;
            aliases=["cm_delta_e_linear", "Cm_de", "cm_de"],
            per_degree_aliases=["Cm_de_per_deg", "cm_de_per_deg"]
        ),
        Cm_alpha_extra=fetch_optional_constant(aero_db, "Cm_alpha_extra", 0.0),
        beta_stall=fetch_optional_constant(aero_db, "beta_stall", 20.0; aliases=["beta_stall_deg"]),
        alpha_stall_knee_deg=fetch_optional_constant(aero_db, "alpha_stall_knee_deg", 3.0),
        beta_stall_knee_deg=fetch_optional_constant(aero_db, "beta_stall_knee_deg", 5.0),
        Cn_delta_a=fetch_optional_constant(aero_db, "Cn_delta_a", 0.0; aliases=["Cn_da", "cn_da"]),
        Cn_delta_r=fetch_optional_constant_with_per_degree_alias(
            aero_db,
            "Cn_delta_r",
            0.10;
            aliases=["Cn_dr", "cn_dr"],
            per_degree_aliases=["Cn_dr_per_deg", "cn_dr_per_deg"]
        ),
        aerodynamic_model_mode=lowercase(string(get(MISSION_DATA, "aerodynamic_model_mode", "table"))),
        tail_surfaces=tail_surface_geometry,
        use_component_assembly=has_v3_split_tables(aero_db),
        I_body=inertia,
    )

    # ── 4) Reset dynamic stall state ─────────────────────────────────
    try
        reset_auto_pitch_trim_state_memory(reason="external data reloaded")
    catch e
        println("  WARNING: reset_auto_pitch_trim_state_memory failed: $e")
    end
    reset_dynamic_stall_state_memory()

    global frontend_static_payload_frames_remaining =
        isdefined(Main, :frontend_static_payload_burst_frames) ? Main.frontend_static_payload_burst_frames : 60

    println("  ✓ aircraft_flight_physics_and_propulsive_data rebuilt successfully")
    println("  ✓ All external data reloaded\n")
    return true
end

function reset_dynamic_stall_state_memory()
    global dynamic_stall_alpha_lag_deg_state = 0.0
    global dynamic_stall_sigma_state = 0.0
    global dynamic_stall_state_initialized = false
    println("Dynamic-stall memory reset for new client session.")
end

# Function to reset flight data recording state
function reset_flight_data_recording()
    # Define the DataFrame structure with NEW valid identifier names
    global df = DataFrame(
        # --- Original Columns ---
        time=Float64[],
        LATITUDE_m=Float64[],  # Renamed from x
        ALTITUDE_m=Float64[],  # Renamed from y
        LONGITUDE_m=Float64[], # Renamed from z
        vx=Float64[],
        VSI_ms=Float64[],    # Renamed from vy
        vz=Float64[],
        qx=Float64[],
        qy=Float64[],
        qz=Float64[],
        qw=Float64[],
        wx=Float64[],
        wy=Float64[],
        wz=Float64[],
        fx_global=Float64[],
        fy_global=Float64[],
        fz_global=Float64[],
        alpha_DEG=Float64[],
        beta_DEG=Float64[],
        pitch_demand=Float64[],
        roll_demand=Float64[],
        yaw_demand=Float64[],
        pitch_demand_attained=Float64[],
        roll_demand_attained=Float64[],
        yaw_demand_attained=Float64[],
        thrust_setting_demand=Float64[],
        thrust_attained=Float64[],

        # --- New Columns Added ---
        CL=Float64[],
        CD=Float64[],
        CL_CD_ratio=Float64[], # Renamed from CL/CD
        CS=Float64[],
        nx=Float64[],
        nz=Float64[],
        ny=Float64[],
        CM_roll_from_aero_forces=Float64[],
        CM_yaw_from_aero_forces=Float64[],
        CM_pitch_from_aero_forces=Float64[],
        CM_roll_from_control=Float64[],
        CM_yaw_from_control=Float64[],
        CM_pitch_from_control=Float64[],
        CM_roll_from_aero_stiffness=Float64[],
        CM_yaw_from_aero_stiffness=Float64[],
        CM_pitch_from_aero_stiffness=Float64[],
        CM_roll_from_aero_damping=Float64[],
        CM_yaw_from_aero_damping=Float64[],
        CM_pitch_from_aero_damping=Float64[],
        q_pitch_rate=Float64[],
        p_roll_rate=Float64[],
        r_yaw_rate=Float64[],

        TAS =Float64[],
        EAS =Float64[],
        Mach =Float64[],
        dynamic_pressure =Float64[]
    )

    global has_written_to_csv = false
    global csv_write_in_progress = false
    global csv_write_task = nothing

    # Generate a new timestamp and CSV filename for this session
    timestamp = Dates.format(now(), "yyyy-mm-dd_@_HHh-MM-SS")
    global csv_file = joinpath(project_dir, "📊_Flight_Test_Data",
        "simulation_data_" * timestamp * ".csv")

    println("Flight data recording reset with new CSV target: $csv_file")
end

# Main WebSocket connection handler function that processes incoming messages.
# Works with both HTTP.WebSockets (modern) and WebSockets.jl (legacy) ws objects.
function websocket_handler(ws)
    # Reset simulation time when a new connection is established
    global sim_time = 0.0
    global frontend_static_payload_frames_remaining =
        isdefined(Main, :frontend_static_payload_burst_frames) ? Main.frontend_static_payload_burst_frames : 60
    println("\n=== New WebSocket connection established ===")
    println("  Simulation time reset to 0.0")

    # Re-read mission + aircraft YAML on every fresh browser session so a
    # simple browser refresh picks up aerodynamic-model edits without
    # requiring a full Julia restart. The explicit reload_data / respawn path
    # still exists; this just makes a new client session consistent with it.
    try
        println("  Reloading external mission/aircraft data for new client session...")
        reload_ok = reload_all_external_data!()
        if reload_ok
            println("  External data reload on connect OK.")
        else
            println("  External data reload on connect reported warnings; continuing with current session state.")
        end
    catch e
        println("  WARNING: external data reload on connect failed: $e")
    end

    try
        reset_auto_pitch_trim_state_memory(reason="new websocket client session")
    catch e
        println("  WARNING: reset_auto_pitch_trim_state_memory failed: $e")
    end

    try
        reset_dynamic_stall_state_memory()
    catch e
        println("  WARNING: reset_dynamic_stall_state_memory failed: $e")
    end

    try
        # Reset flight data recording
        println("  Resetting flight data recording...")
        reset_flight_data_recording()
        println("  Flight data recording reset OK.")

        frame_count = 0

        # Keep processing messages while the socket connection is open
        while true
            # Read data from WebSocket connection using HTTP.WebSockets API
            local aircraft_state_data
            try
                aircraft_state_data = HTTP.WebSockets.receive(ws)
            catch e
                # Connection closed or error — exit loop
                if frame_count > 0
                    println("  Client disconnected after $frame_count frames.")
                else
                    println("  Client disconnected before any frames were processed.")
                end
                break
            end

            # Convert String data to bytes if needed (binary frames arrive as Vector{UInt8})
            if aircraft_state_data isa String
                aircraft_state_data = Vector{UInt8}(aircraft_state_data)
            end

            if isempty(aircraft_state_data)
                continue
            end

            # Process valid, non-empty data
            try
                # Unpack the MsgPack data, which creates a Dict{Any, Any}
                unpacked_data = MsgPack.unpack(aircraft_state_data)
                if !(unpacked_data isa AbstractDict)
                    @warn "Received non-dictionary websocket payload; skipping frame."
                    continue
                end

                # Explicitly construct a Dict{String, Any}
                current_aircraft_state_dict = Dict{String, Any}(String(k) => v for (k, v) in unpacked_data)

                # ── Check for reload_data request ────────────────────
                if haskey(current_aircraft_state_dict, "reload_data") && _is_truthy_reset_signal(current_aircraft_state_dict["reload_data"])
                    reload_ok = false
                    try
                        reload_ok = reload_all_external_data!()
                    catch reload_err
                        println("  ERROR during data reload: $reload_err")
                    end

                    # If the message ALSO contains flight state (respawn), process
                    # it normally so the aircraft resets. Otherwise send just an ack.
                    has_flight_state = haskey(current_aircraft_state_dict, "x") || haskey(current_aircraft_state_dict, "respawn")
                    if !has_flight_state
                        ack = Dict{String, Any}(
                            "reload_ack" => true,
                            "reload_success" => reload_ok
                        )
                        try
                            HTTP.WebSockets.send(ws, MsgPack.pack(ack))
                        catch e
                            println("  WebSocket write failed sending reload ack: $e")
                        end
                        continue  # Skip normal physics processing for this frame
                    end
                    # Fall through to update_aircraft_state with the respawn state
                end

                # Update aircraft state using physics simulation
                updated_aircraft_state_dict = update_aircraft_state(current_aircraft_state_dict, aircraft_flight_physics_and_propulsive_data)

                # Send updated state back to client if available
                if updated_aircraft_state_dict !== nothing
                    packed_response = MsgPack.pack(updated_aircraft_state_dict)
                    try
                        HTTP.WebSockets.send(ws, packed_response)
                    catch e
                        println("  WebSocket write failed after $frame_count frames: $e")
                        break
                    end
                    frame_count += 1
                    if frame_count == 1
                        println("  First frame processed and sent successfully ($(length(packed_response)) bytes).")
                    end
                else
                    println("  WARNING: update_aircraft_state returned nothing on frame $frame_count; skipping.")
                end
            catch e
                # Keep session alive even if one frame fails.
                println("  ERROR processing frame $frame_count: $e")
                bt = catch_backtrace()
                for line in stacktrace(bt)[1:min(5, end)]
                    println("    at $line")
                end
            end
        end
    catch e
        # Ignore BrokenPipeError which commonly happens when the client disconnects
        if e isa Base.IOError
            println("  IOError (client disconnected)")
        elseif e isa EOFError
            println("  Client disconnected (EOF).")
        else
            println("  UNEXPECTED ERROR in websocket_handler:")
            println("    Type: $(typeof(e))")
            println("    Message: $e")
            bt = catch_backtrace()
            for line in stacktrace(bt)[1:min(8, end)]
                println("    at $line")
            end
        end
    finally
         println("=== WebSocket connection closed ===\n")
    end
end

# ── MIME type lookup for static file serving ──────────────────────────
const _MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8",
    ".js"   => "application/javascript; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif"  => "image/gif",
    ".svg"  => "image/svg+xml",
    ".ico"  => "image/x-icon",
    ".woff" => "font/woff",
    ".woff2"=> "font/woff2",
    ".glb"  => "model/gltf-binary",
    ".gltf" => "model/gltf+json",
    ".map"  => "application/json",
    ".yaml" => "text/yaml; charset=utf-8",
    ".csv"  => "text/csv; charset=utf-8",
)

function _mime_for(path::String)
    ext = lowercase(splitext(path)[2])
    return get(_MIME_TYPES, ext, "application/octet-stream")
end

# ── Static file serving handler ───────────────────────────────────────
# Serves files from the JavaScript root directory.
# The global `_js_root` is set in `establish_websockets_connection`.
global _js_root = ""

function serve_static(request::HTTP.Request)
    uri = HTTP.URI(request.target)
    path = HTTP.URIs.unescapeuri(uri.path)

    # Default to the main HTML file
    if path == "/" || path == ""
        path = "/✅_front_end_and_client.html"
    end

    # ── /aero_model_data: JSON dump of every aero coefficient currently in use ──
    # Consumed by aero_model_viewer.html.  Serves whichever model mode is
    # active (linear or table), exactly as the simulator will consume it.
    if path == "/aero_model_data" || path == "/aero_model_data/"
        try
            query_str = something(uri.query, "")
            range_mode = any(p -> p == "range=wide", split(query_str, '&')) ? "wide" : "normal"
            return aero_inspector_json_response(; range=range_mode)
        catch e
            return HTTP.Response(500, ["Content-Type" => "application/json"],
                                 "{\"error\":\"" * replace(string(e), "\"" => "'") * "\"}")
        end
    end

    # ── /mission_info: raw default_mission.yaml text + aircraft folder name ──
    # The client polls this on page load to fill the loading overlay so the
    # user knows which aircraft is being loaded and which mission settings
    # are active, instead of staring at a blank "Loading…" screen for
    # several seconds while the GLB and aero database stream in.
    if path == "/mission_info" || path == "/mission_info/"
        try
            workspace_root = normpath(joinpath(project_dir, ".."))
            mission_path = normpath(joinpath(workspace_root, "default_mission.yaml"))
            mission_text = isfile(mission_path) ? read(mission_path, String) : "(default_mission.yaml not found)"
            aircraft_name = get(MISSION_DATA, "aircraft_name", "(unknown)")
            headers = ["Content-Type" => "text/plain; charset=utf-8",
                       "Cache-Control" => "no-cache",
                       "X-Aircraft-Name" => string(aircraft_name)]
            return HTTP.Response(200, headers, mission_text)
        catch e
            return HTTP.Response(500, ["Content-Type" => "text/plain"],
                                 "Error reading mission info: " * string(e))
        end
    end

    # ── /aircraft/ route: serve files from the aircraft folder in HANGAR ──
    if startswith(path, "/aircraft/")
        if !isdefined(Main, :aircraft_dir) || isempty(Main.aircraft_dir)
            println("  [HTTP 404] /aircraft/ route: aircraft_dir not configured")
            return HTTP.Response(404, "No aircraft folder configured")
        end
        rel_path = lstrip(path[length("/aircraft/")+1:end], '/')
        file_path = normpath(joinpath(Main.aircraft_dir, rel_path))
        # Security: ensure resolved path stays inside the aircraft folder
        if !startswith(file_path, normpath(Main.aircraft_dir))
            return HTTP.Response(403, "Forbidden")
        end
        if !isfile(file_path)
            println("  [HTTP 404] Aircraft file not found: $file_path")
            return HTTP.Response(404, "Not found: $path")
        end
        println("  [HTTP 200] Serving aircraft file: $rel_path ($(filesize(file_path)) bytes)")
        body = read(file_path)
        headers = ["Content-Type" => _mime_for(file_path),
                   "Cache-Control" => "no-cache"]
        return HTTP.Response(200, headers, body)
    end

    # Resolve to a file on disk (JS root)
    file_path = normpath(joinpath(_js_root, lstrip(path, '/')))

    # Security: ensure the resolved path is inside the JS root
    if !startswith(file_path, _js_root)
        return HTTP.Response(403, "Forbidden")
    end

    if !isfile(file_path)
        return HTTP.Response(404, "Not found: $path")
    end

    body = read(file_path)
    headers = ["Content-Type" => _mime_for(file_path),
               "Cache-Control" => "no-cache"]
    return HTTP.Response(200, headers, body)
end

# ── Server initialization (HTTP + WebSocket on same port) ─────────────

# Start the HTTP + WebSocket server asynchronously (non-blocking).
# Call this BEFORE launch_client so the server is ready when the browser connects.
function start_server()
    port = WebSockets_port  # Port number found by 🔌_Find_free_port.jl
    println("Starting HTTP + WebSocket server on port $port...")

    # Set the static file root to the JavaScript folder
    js_root = find_javascript_root(project_dir)
    global _js_root = normpath(js_root)
    println("  Serving static files from: $_js_root")

    # Single HTTP server that handles both WebSocket upgrades and static files.
    @async HTTP.listen("0.0.0.0", port) do http::HTTP.Stream
        request = http.message
        # Check if this is a WebSocket upgrade request
        if HTTP.WebSockets.isupgrade(request)
            HTTP.WebSockets.upgrade(http) do ws
                websocket_handler(ws)
            end
        else
            # Serve static files
            request_obj = HTTP.Request(request.method, request.target, request.headers, read(http))
            response = serve_static(request_obj)
            HTTP.setstatus(http, response.status)
            for (name, value) in response.headers
                HTTP.setheader(http, name => value)
            end
            HTTP.startwrite(http)
            write(http, response.body)
        end
    end

    # Give the async server a moment to bind the port
    sleep(0.5)
    println("Server running at http://localhost:$port")
end

# Block the main thread to keep the server alive.
# Call this AFTER launch_client.
function wait_for_server()
    println("Press Ctrl+C to stop.")
    try
        while true
            sleep(1)
        end
    catch e
        if e isa InterruptException
            println("\nCtrl+C detected. Shutting down server...")
        else
            @error "Server loop error" exception=e
        end
    finally
        println("Server stopped.")
    end
end
