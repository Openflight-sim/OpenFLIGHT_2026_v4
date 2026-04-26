###########################################
# Aircraft aerodynamic and propulsive model loading
###########################################

cd(@__DIR__)

if !@isdefined(MISSION_DATA)
    error("MISSION_DATA dictionary not found. Ensure mission sync is included before aircraft model loading.")
elseif !haskey(MISSION_DATA, "aircraft_name")
    error("Mission configuration is missing required key 'aircraft_name'.")
end

aircraft_folder_name = MISSION_DATA["aircraft_name"]
println("INFO: Looking for aircraft folder: $aircraft_folder_name")

openflight_root = normpath(joinpath(@__DIR__, "..", "..", ".."))
workspace_root = normpath(joinpath(openflight_root, ".."))

# ── Locate the aircraft folder inside the HANGAR directory ──────────
workspace_entries = readdir(workspace_root)
hangar_idx = findfirst(name -> occursin("HANGAR", name), workspace_entries)

global aircraft_dir = ""
if hangar_idx !== nothing
    hangar_root = joinpath(workspace_root, workspace_entries[hangar_idx])
    # Look for a subfolder matching the aircraft name
    hangar_entries = readdir(hangar_root)
    aircraft_idx = findfirst(name -> lowercase(name) == lowercase(aircraft_folder_name), hangar_entries)
    if aircraft_idx !== nothing
        aircraft_dir = normpath(joinpath(hangar_root, hangar_entries[aircraft_idx]))
    end
end

if isempty(aircraft_dir) || !isdir(aircraft_dir)
    error(
        "Aircraft folder not found.\n" *
        "aircraft_name = $aircraft_folder_name\n" *
        "Expected structure: <workspace>/🏭_HANGAR/$aircraft_folder_name/"
    )
end
println("INFO: Aircraft folder found at: $aircraft_dir")

# ── Find the YAML aerodynamic data file inside the aircraft folder ──
# The model creator exports two files per aircraft:
#   name.tabular.aero_prop.yaml    — full coefficient tables (table mode)
#   name.linearized.aero_prop.yaml — scalar derivatives only (linear mode)
# The simulator picks the one matching `aerodynamic_model_mode` from the
# mission YAML. Falls back to *.aero_prop.yaml for legacy single-file
# aircraft, then to non-reserved *.yaml / *.yml as a last resort.
aircraft_files = readdir(aircraft_dir)
_aero_mode = lowercase(string(get(MISSION_DATA, "aerodynamic_model_mode", "table")))
_preferred_suffix = _aero_mode == "linear" ? ".linearized.aero_prop.yaml" : ".tabular.aero_prop.yaml"

function _is_reserved_non_aero_yaml(name::AbstractString)
    lower_name = lowercase(basename(name))
    return lower_name in (
        "render_settings.yaml",
        "render_settings.yml",
    )
end

function _aircraft_identity_token(name::AbstractString)
    base = lowercase(basename(name))
    for suffix in (".tabular.aero_prop.yaml", ".linearized.aero_prop.yaml", ".aero_prop.yaml", ".ac_data.yaml", ".yaml", ".yml")
        if endswith(base, suffix)
            base = base[1:end-length(suffix)]
            break
        end
    end
    return replace(base, r"[^a-z0-9]" => "")
end

function _find_preferred_aircraft_file(files, suffix::String, aircraft_name::AbstractString)
    candidates = findall(
        name -> endswith(lowercase(name), suffix) && !_is_reserved_non_aero_yaml(name),
        files,
    )
    isempty(candidates) && return nothing
    aircraft_token = _aircraft_identity_token(aircraft_name)
    exact_idx = findfirst(i -> _aircraft_identity_token(files[i]) == aircraft_token, candidates)
    exact_idx !== nothing && return candidates[exact_idx]
    related_idx = findfirst(i -> begin
        token = _aircraft_identity_token(files[i])
        !isempty(token) && !isempty(aircraft_token) &&
            (occursin(aircraft_token, token) || occursin(token, aircraft_token))
    end, candidates)
    related_idx !== nothing && return candidates[related_idx]
    return first(candidates)
end

function _visual_geometry_from_selected_or_companion(
    normalized_yaml::Dict{String,Any},
    aircraft_dir::AbstractString,
    aircraft_files,
    selected_file::AbstractString,
    aircraft_name::AbstractString,
)
    visual_geometry = get(normalized_yaml, "visual_geometry", nothing)
    if visual_geometry !== nothing
        return visual_geometry, selected_file
    end

    selected_path = normpath(joinpath(aircraft_dir, selected_file))
    for suffix in (".tabular.aero_prop.yaml", ".aero_prop.yaml", ".ac_data.yaml", ".yaml", ".yml")
        companion_idx = _find_preferred_aircraft_file(aircraft_files, suffix, aircraft_name)
        companion_idx === nothing && continue
        companion_name = aircraft_files[companion_idx]
        companion_path = normpath(joinpath(aircraft_dir, companion_name))
        companion_path == selected_path && continue
        try
            companion_yaml = _deep_stringify_keys(YAML.load_file(companion_path))
            companion_visual_geometry = get(companion_yaml, "visual_geometry", nothing)
            if companion_visual_geometry !== nothing
                return companion_visual_geometry, companion_name
            end
        catch err
            @warn "Could not inspect companion aircraft YAML for visual geometry" file=companion_name exception=(err, catch_backtrace())
        end
    end

    return nothing, nothing
end

yaml_idx = _find_preferred_aircraft_file(aircraft_files, _preferred_suffix, aircraft_folder_name)
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
    error(
        "No aerodynamic data file found in aircraft folder: $aircraft_dir\n" *
        "Expected one of: *.tabular.aero_prop.yaml, *.linearized.aero_prop.yaml, *.aero_prop.yaml, or a legacy aero *.yaml/*.yml.\n" *
        "Note: render_settings.yaml only controls GLB/camera rendering and is intentionally not accepted as aerodynamic data."
    )
end
filename = normpath(joinpath(aircraft_dir, aircraft_files[yaml_idx]))
if _aircraft_identity_token(aircraft_files[yaml_idx]) != _aircraft_identity_token(aircraft_folder_name)
    @warn "Aerodynamic file name does not match aircraft folder; the simulator may be flying the wrong model" aircraft_folder_name selected_file=aircraft_files[yaml_idx]
end
println("INFO: aerodynamic_model_mode = $_aero_mode → using: $(aircraft_files[yaml_idx])")

# ── Find GLB 3D model file (if any) inside the aircraft folder ──────
glb_idx = findfirst(name -> lowercase(splitext(name)[2]) == ".glb", aircraft_files)
global aircraft_glb_path = glb_idx !== nothing ? normpath(joinpath(aircraft_dir, aircraft_files[glb_idx])) : nothing
global aircraft_glb_filename = glb_idx !== nothing ? aircraft_files[glb_idx] : nothing
if aircraft_glb_path !== nothing
    println("INFO: GLB 3D model found: $aircraft_glb_filename")
else
    println("INFO: No .glb 3D model in aircraft folder — will use default/YAML geometry")
end

# ── Load per-aircraft render_settings.yaml (if present) ─────────────
# This file lives alongside the .glb in the aircraft folder and overrides
# hardcoded defaults for GLB orientation/translation/scale, position
# lights, propeller pivot, and cockpit/wing camera placement. If absent,
# the client falls back to the defaults baked into the JS (which are
# chosen to make the PC21 baseline aircraft look right out of the box).
_render_settings_idx = findfirst(
    name -> lowercase(name) == "render_settings.yaml",
    aircraft_files,
)
global aircraft_render_settings = if _render_settings_idx !== nothing
    try
        _rs_raw = YAML.load_file(normpath(joinpath(
            aircraft_dir, aircraft_files[_render_settings_idx]
        )))
        println("INFO: Loaded render_settings.yaml — per-aircraft GLB & camera overrides active")
        _deep_stringify_keys(_rs_raw)
    catch _rs_err
        println("WARNING: Failed to parse render_settings.yaml ($(_rs_err)) — falling back to defaults")
        nothing
    end
else
    nothing
end

raw_aircraft_yaml = YAML.load_file(filename)
normalized_aircraft_yaml = _deep_stringify_keys(raw_aircraft_yaml)
aircraft_aero_and_propulsive_database = parse_aero_data(raw_aircraft_yaml)

function compute_inertial_tensor_body_frame(
    aircraft_mass,
    radius_of_giration_pitch,
    radius_of_giration_roll,
    radius_of_giration_yaw,
    principal_axis_pitch_up_DEG
)
    # Standard aero ordering: [x_roll, y_pitch, z_yaw] = [Ixx, Iyy, Izz]
    I_body_principal_axes = [
        aircraft_mass*radius_of_giration_roll^2 0.0 0.0;
        0.0 aircraft_mass*radius_of_giration_pitch^2 0.0;
        0.0 0.0 aircraft_mass*radius_of_giration_yaw^2
    ]

    theta_rad = deg2rad(principal_axis_pitch_up_DEG)
    # Rotation about y-axis (pitch axis in standard ordering)
    rotation_matrix = [
        cos(theta_rad) 0.0 sin(theta_rad);
        0.0 1.0 0.0;
        -sin(theta_rad) 0.0 cos(theta_rad)
    ]
    return rotation_matrix * I_body_principal_axes * transpose(rotation_matrix)
end

function _try_fetch_numeric_constant(aero_data::AeroData, candidate_keys::Vector{String})
    for key in candidate_keys
        try
            value = fetch_constant_from_aero_database(aero_data, key)
            if value isa Number
                return Float64(value)
            end
        catch
        end
    end
    return nothing
end

function fetch_required_numeric_constant(
    aero_data::AeroData,
    key::String;
    aliases::Vector{String}=String[],
)
    value = _try_fetch_numeric_constant(aero_data, [key; aliases])
    if value === nothing
        throw(ArgumentError("Required numeric aerodynamic constant '$key' not found in aircraft model"))
    end
    return value
end

function fetch_optional_constant(
    aero_data::AeroData,
    key::String,
    default_value::Float64;
    aliases::Vector{String}=String[],
)
    value = _try_fetch_numeric_constant(aero_data, [key; aliases])
    return value === nothing ? default_value : value
end

function fetch_optional_constant_with_per_degree_alias(
    aero_data::AeroData,
    key::String,
    default_value::Float64;
    aliases::Vector{String}=String[],
    per_degree_aliases::Vector{String}=String[],
)
    for candidate in [key; aliases; per_degree_aliases]
        try
            resolved_key = _resolve_constant_name(aero_data, candidate)
            value = fetch_constant_from_aero_database(aero_data, resolved_key)
            if value isa Number
                numeric_value = Float64(value)
                if endswith(lowercase(resolved_key), "_per_deg")
                    return numeric_value * rad2deg(1.0)
                end
                return numeric_value
            end
        catch
        end
    end

    return default_value
end

function extract_default_configuration(raw_data::Dict{String,Any})
    if haskey(raw_data, "configuration_default")
        return string(raw_data["configuration_default"])
    end

    if haskey(raw_data, "aerodynamics") && raw_data["aerodynamics"] isa AbstractDict
        aerodynamics_data = raw_data["aerodynamics"]
        if haskey(aerodynamics_data, "configuration_default")
            return string(aerodynamics_data["configuration_default"])
        end
    end

    if haskey(raw_data, "configurations") && raw_data["configurations"] isa AbstractDict
        config_keys = sort([string(k) for k in keys(raw_data["configurations"])])
        if !isempty(config_keys)
            if "clean" in config_keys
                return "clean"
            end
            return config_keys[1]
        end
    end

    return "clean"
end

function extract_available_configurations(raw_data::Dict{String,Any}, default_configuration::String)
    if haskey(raw_data, "configurations") && raw_data["configurations"] isa AbstractDict
        config_keys = sort(unique([string(k) for k in keys(raw_data["configurations"])]))
        if !isempty(config_keys)
            ordered_configs = [default_configuration]
            for config_name in config_keys
                if config_name != default_configuration
                    push!(ordered_configs, config_name)
                end
            end
            return ordered_configs
        end
    end
    return [default_configuration]
end

function _vector3_or_default(value, default_vector::Vector{Float64})
    if value isa Vector && length(value) >= 3
        return [Float64(value[1]), Float64(value[2]), Float64(value[3])]
    end
    return copy(default_vector)
end

function _normalize_direction(direction::Vector{Float64})
    direction_norm = norm(direction)
    if direction_norm <= 1e-9
        return [1.0, 0.0, 0.0]
    end
    return direction ./ direction_norm
end

function _direction_from_installation_angle_deg(angle_deg::Float64)
    return _normalize_direction([cosd(angle_deg), sind(angle_deg), 0.0])
end

function extract_engine_models(raw_data::Dict{String,Any}, aero_data::AeroData)
    propulsion_data = haskey(raw_data, "propulsion") && raw_data["propulsion"] isa AbstractDict ? raw_data["propulsion"] : Dict{String,Any}()

    base_max_thrust = fetch_optional_constant(aero_data, "maximum_thrust_at_sea_level", 0.0; aliases=["maximum_thrust_n", "max_thrust_n"])
    if base_max_thrust == 0.0
        # Try to infer it from thrust map if available
        if haskey(propulsion_data, "thrust_map_shared") && haskey(propulsion_data["thrust_map_shared"], "values")
            vals = propulsion_data["thrust_map_shared"]["values"]
            _get_max(val) = val isa Number ? Float64(val) : (val isa Vector ? maximum(_get_max, val) : 0.0)
            base_max_thrust = _get_max(vals)
        else
            base_max_thrust = 10000.0 # fallback
        end
    end

    base_installation_angle = fetch_optional_constant(aero_data, "thrust_installation_angle_DEG", 0.0; aliases=["thrust_installation_angle_deg"])
    base_spool_up = fetch_optional_constant(aero_data, "engine_spool_up_speed", 1.0; aliases=["engine_spool_up_per_s"])
    base_spool_down = fetch_optional_constant(aero_data, "engine_spool_down_speed", 1.0; aliases=["engine_spool_down_per_s"])
    base_reverse_ratio = fetch_optional_constant(aero_data, "reverse_thrust_ratio", 0.3)

    default_direction = _direction_from_installation_angle_deg(base_installation_angle)
    default_position = [0.0, 0.0, 0.0]
    engines = NamedTuple[]

    raw_engines = haskey(propulsion_data, "engines") && propulsion_data["engines"] isa Vector ? propulsion_data["engines"] : Any[]

    if isempty(raw_engines)
        push!(engines, (
            id="engine_1",
            max_thrust_newton=base_max_thrust,
            reverse_thrust_ratio=base_reverse_ratio,
            position_body_m=default_position,
            direction_body=default_direction,
            spool_up_speed=base_spool_up,
            spool_down_speed=base_spool_down,
            throttle_channel=1
        ))
        return engines
    end

    for (engine_index, raw_engine) in enumerate(raw_engines)
        if !(raw_engine isa AbstractDict)
            continue
        end
        engine_data = Dict{String,Any}(string(k) => v for (k, v) in raw_engine)

        max_thrust = Float64(get(engine_data, "max_thrust_n", get(engine_data, "maximum_thrust_n", base_max_thrust)))
        reverse_ratio = Float64(get(engine_data, "reverse_thrust_ratio", base_reverse_ratio))
        spool_up = Float64(get(engine_data, "spool_up_speed", get(engine_data, "spool_up_per_s", base_spool_up)))
        spool_down = Float64(get(engine_data, "spool_down_speed", get(engine_data, "spool_down_per_s", base_spool_down)))
        throttle_channel = Int(get(engine_data, "throttle_channel", engine_index))

        position_body = if haskey(engine_data, "position_body_m")
            _vector3_or_default(engine_data["position_body_m"], default_position)
        else
            [
                Float64(get(engine_data, "x_m", default_position[1])),
                Float64(get(engine_data, "y_m", default_position[2])),
                Float64(get(engine_data, "z_m", default_position[3]))
            ]
        end

        direction_body = if haskey(engine_data, "direction_body")
            _normalize_direction(_vector3_or_default(engine_data["direction_body"], default_direction))
        elseif haskey(engine_data, "thrust_installation_angle_deg")
            _direction_from_installation_angle_deg(Float64(engine_data["thrust_installation_angle_deg"]))
        else
            copy(default_direction)
        end

        push!(engines, (
            id=string(get(engine_data, "id", "engine_$(engine_index)")),
            max_thrust_newton=max_thrust,
            reverse_thrust_ratio=reverse_ratio,
            position_body_m=position_body,
            direction_body=direction_body,
            spool_up_speed=spool_up,
            spool_down_speed=spool_down,
            throttle_channel=throttle_channel
        ))
    end

    if isempty(engines)
        push!(engines, (
            id="engine_1",
            max_thrust_newton=base_max_thrust,
            reverse_thrust_ratio=base_reverse_ratio,
            position_body_m=default_position,
            direction_body=default_direction,
            spool_up_speed=base_spool_up,
            spool_down_speed=base_spool_down,
            throttle_channel=1
        ))
    end

    return engines
end

function extract_inertia_tensor(raw_data::Dict{String,Any}, aero_data::AeroData)
    if haskey(raw_data, "inertia") && raw_data["inertia"] isa AbstractDict
        inertia_data = raw_data["inertia"]
        if haskey(inertia_data, "tensor_body_kg_m2") && inertia_data["tensor_body_kg_m2"] isa Vector
            rows = inertia_data["tensor_body_kg_m2"]
            if length(rows) == 3 && all(row -> row isa Vector && length(row) >= 3, rows)
                return [
                    Float64(rows[1][1]) Float64(rows[1][2]) Float64(rows[1][3]);
                    Float64(rows[2][1]) Float64(rows[2][2]) Float64(rows[2][3]);
                    Float64(rows[3][1]) Float64(rows[3][2]) Float64(rows[3][3])
                ]
            end
        end
    end

    mass = fetch_required_numeric_constant(aero_data, "aircraft_mass"; aliases=["mass_kg", "reference.mass_kg"])
    pitch_angle_deg = fetch_optional_constant(aero_data, "principal_axis_pitch_up_DEG", 0.0; aliases=["principal_axis_pitch_up_deg", "principal_axes_pitch_angle_deg", "pitch_angle_deg", "inertia.principal_axes_rotation_deg.pitch", "principal_axes_rotation_deg.pitch"])

    Ixx_p = fetch_optional_constant(aero_data, "Ixx_p", 0.0; aliases=["inertia.principal_moments_kgm2.Ixx_p", "principal_moments_kgm2.Ixx_p"])
    Iyy_p = fetch_optional_constant(aero_data, "Iyy_p", 0.0; aliases=["inertia.principal_moments_kgm2.Iyy_p", "principal_moments_kgm2.Iyy_p"])
    Izz_p = fetch_optional_constant(aero_data, "Izz_p", 0.0; aliases=["inertia.principal_moments_kgm2.Izz_p", "principal_moments_kgm2.Izz_p"])

    if Ixx_p > 0.0 && Iyy_p > 0.0 && Izz_p > 0.0
        I_body_principal = [
            Ixx_p 0.0 0.0;
            0.0 Iyy_p 0.0;
            0.0 0.0 Izz_p
        ]
        theta_rad = deg2rad(pitch_angle_deg)
        rotation_matrix = [
            cos(theta_rad) 0.0 sin(theta_rad);
            0.0 1.0 0.0;
            -sin(theta_rad) 0.0 cos(theta_rad)
        ]
        return rotation_matrix * I_body_principal * transpose(rotation_matrix)
    end

    return compute_inertial_tensor_body_frame(
        mass,
        fetch_optional_constant(aero_data, "radius_of_giration_pitch", 1.0; aliases=["radius_of_gyration_pitch_m", "inertia.radius_of_gyration_pitch_m", "inertia.radius_of_gyration_m.pitch"]),
        fetch_optional_constant(aero_data, "radius_of_giration_roll", 1.0; aliases=["radius_of_gyration_roll_m", "inertia.radius_of_gyration_roll_m", "inertia.radius_of_gyration_m.roll"]),
        fetch_optional_constant(aero_data, "radius_of_giration_yaw", 1.0; aliases=["radius_of_gyration_yaw_m", "inertia.radius_of_gyration_yaw_m", "inertia.radius_of_gyration_m.yaw"]),
        pitch_angle_deg
    )
end

function _vector_mean(values::Vector{Float64}, default_value::Float64)
    return isempty(values) ? default_value : sum(values) / length(values)
end

function _extract_max_deflection_deg(raw_data::Dict{String,Any}, surface::String, default_deg::Float64)
    if haskey(raw_data, "actuators") && raw_data["actuators"] isa AbstractDict
        actuators = raw_data["actuators"]
        if haskey(actuators, "position_limit_deg") && actuators["position_limit_deg"] isa AbstractDict
            limits = actuators["position_limit_deg"]
            if haskey(limits, surface) && limits[surface] isa Vector && length(limits[surface]) >= 2
                return max(abs(Float64(limits[surface][1])), abs(Float64(limits[surface][2])))
            end
            surface_lc = lowercase(surface)
            best_match = nothing
            for (key, value) in pairs(limits)
                !(value isa Vector) && continue
                length(value) < 2 && continue
                key_lc = lowercase(string(key))
                if key_lc == surface_lc || occursin(surface_lc, key_lc)
                    candidate = max(abs(Float64(value[1])), abs(Float64(value[2])))
                    best_match = isnothing(best_match) ? candidate : max(best_match, candidate)
                end
            end
            if !isnothing(best_match)
                return best_match
            end
        end
    end
    return default_deg
end

default_aircraft_configuration = extract_default_configuration(normalized_aircraft_yaml)
available_aircraft_configurations = extract_available_configurations(normalized_aircraft_yaml, default_aircraft_configuration)
engine_models = extract_engine_models(normalized_aircraft_yaml, aircraft_aero_and_propulsive_database)
engine_spool_up_speeds = [engine.spool_up_speed for engine in engine_models]
engine_spool_down_speeds = [engine.spool_down_speed for engine in engine_models]
engine_reverse_thrust_ratios = [engine.reverse_thrust_ratio for engine in engine_models]
maximum_total_thrust = sum(engine.max_thrust_newton for engine in engine_models)
aircraft_inertia_tensor_body = Base.invokelatest(
    extract_inertia_tensor,
    normalized_aircraft_yaml,
    aircraft_aero_and_propulsive_database,
)
tail_surface_geometry = extract_tail_surface_geometry(normalized_aircraft_yaml)
horizontal_tail_ac_xyz_m = tail_surface_ac_xyz(
    tail_surface_geometry,
    "horizontal",
    [
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_horizontal_tail_aerodynamic_center", 0.0),
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_horizontal_tail_aerodynamic_center", 0.0),
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_horizontal_tail_aerodynamic_center", 0.0),
    ],
)
vertical_tail_ac_xyz_m = tail_surface_ac_xyz(
    tail_surface_geometry,
    "vertical",
    [
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_vertical_tail_aerodynamic_center", 0.0),
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_vertical_tail_aerodynamic_center", 0.0),
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_vertical_tail_aerodynamic_center", 0.0),
    ],
)

# ---- Extract visual_geometry from YAML if present (generated by AeroModel) ----
_visual_geometry_result = _visual_geometry_from_selected_or_companion(
    normalized_aircraft_yaml,
    aircraft_dir,
    aircraft_files,
    aircraft_files[yaml_idx],
    aircraft_folder_name,
)
global aircraft_visual_geometry = _visual_geometry_result[1]
global aircraft_visual_geometry_source = _visual_geometry_result[2]
if aircraft_visual_geometry !== nothing
    println("INFO: Visual geometry data found in $(aircraft_visual_geometry_source) - will be sent to OpenFlight frontend")
else
    println("INFO: No visual_geometry section in YAML - frontend will use default aircraft model")
end

aircraft_flight_physics_and_propulsive_data = (
    default_configuration=default_aircraft_configuration,
    available_configurations=available_aircraft_configurations,
    engines=engine_models,
    engine_count=length(engine_models),
    engine_spool_up_speeds=engine_spool_up_speeds,
    engine_spool_down_speeds=engine_spool_down_speeds,
    engine_reverse_thrust_ratios=engine_reverse_thrust_ratios,
    aircraft_mass=fetch_required_numeric_constant(aircraft_aero_and_propulsive_database, "aircraft_mass"; aliases=["mass_kg"]),
    x_CoG=fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_CoG", 0.0; aliases=["x_cog_m", "x_cg_m", "cg_ref_m.x"]),
    y_CoG=fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_CoG", 0.0; aliases=["y_cog_m", "y_cg_m", "cg_ref_m.y"]),
    z_CoG=fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_CoG", 0.0; aliases=["z_cog_m", "z_cg_m", "cg_ref_m.z"]),
    x_wing_aerodynamic_center=fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_wing_aerodynamic_center", 0.0; aliases=["x_wing_aerodynamic_center_m", "wing_fuselage_aero_center_x", "wing_aerodynamic_center.x"]),
    wing_lift_lever_arm_wrt_CoG_over_MAC=-1.0 * (
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_wing_aerodynamic_center", 0.0; aliases=["x_wing_aerodynamic_center_m"]) -
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_CoG", 0.0; aliases=["x_cog_m", "x_cg_m", "cg_ref_m.x"])
    ) / fetch_optional_constant(aircraft_aero_and_propulsive_database, "wing_mean_aerodynamic_chord", 1.0; aliases=["mean_aerodynamic_chord_m", "mac_m", "c_ref_m", "geometry.c_ref_m"]),
    reference_area=fetch_required_numeric_constant(aircraft_aero_and_propulsive_database, "reference_area"; aliases=["reference_area_m2", "s_ref_m2", "geometry.S_ref_m2"]),
    reference_span=fetch_required_numeric_constant(aircraft_aero_and_propulsive_database, "reference_span"; aliases=["reference_span_m", "b_ref_m", "geometry.b_ref_m"]),
    AR=fetch_optional_constant(aircraft_aero_and_propulsive_database, "AR",
        (fetch_optional_constant(aircraft_aero_and_propulsive_database, "reference_span", 1.0; aliases=["b_ref_m", "geometry.b_ref_m"])^2) / fetch_optional_constant(aircraft_aero_and_propulsive_database, "reference_area", 1.0; aliases=["s_ref_m2", "geometry.S_ref_m2"]);
        aliases=["aspect_ratio"]),
    Oswald_factor=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Oswald_factor", 0.8; aliases=["oswald", "oswald_factor", "oswald_efficiency_factor"]),
    wing_mean_aerodynamic_chord=fetch_required_numeric_constant(aircraft_aero_and_propulsive_database, "wing_mean_aerodynamic_chord"; aliases=["mean_aerodynamic_chord_m", "mac_m", "c_ref_m", "geometry.c_ref_m"]),
    wing_fuselage_reference_area=fetch_optional_constant(aircraft_aero_and_propulsive_database, "reference_area", 1.0; aliases=["reference_area_m2", "s_ref_m2", "geometry.S_ref_m2"]),
    wing_fuselage_aero_center_x=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "x_wing_fuselage_aerodynamic_center",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_wing_body_neutral_point", 0.0);
        aliases=["wing_aerodynamic_center.x"]
    ),
    wing_fuselage_aero_center_y=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "y_wing_fuselage_aerodynamic_center",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_wing_body_neutral_point", 0.0);
        aliases=["wing_aerodynamic_center.y"]
    ),
    wing_fuselage_aero_center_z=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "z_wing_fuselage_aerodynamic_center",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_wing_body_neutral_point", 0.0);
        aliases=["wing_aerodynamic_center.z"]
    ),
    x_wing_body_neutral_point=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "x_wing_body_neutral_point",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_wing_fuselage_aerodynamic_center", 0.0)
    ),
    y_wing_body_neutral_point=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "y_wing_body_neutral_point",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_wing_fuselage_aerodynamic_center", 0.0)
    ),
    z_wing_body_neutral_point=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "z_wing_body_neutral_point",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_wing_fuselage_aerodynamic_center", 0.0)
    ),
    x_aero_reference_CoG=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "x_aero_reference_CoG",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_CoG", 0.0; aliases=["x_cog_m", "x_cg_m", "cg_ref_m.x"])
    ),
    y_aero_reference_CoG=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "y_aero_reference_CoG",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_CoG", 0.0; aliases=["y_cog_m", "y_cg_m", "cg_ref_m.y"])
    ),
    z_aero_reference_CoG=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "z_aero_reference_CoG",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_CoG", 0.0; aliases=["z_cog_m", "z_cg_m", "cg_ref_m.z"])
    ),
    tail_reference_area=fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_reference_area", 0.0),
    horizontal_tail_reference_area=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "horizontal_tail_reference_area",
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_reference_area", 0.0)
    ),
    vertical_tail_reference_area=fetch_optional_constant(aircraft_aero_and_propulsive_database, "vertical_tail_reference_area", 0.0),
    tail_aero_center_x=fetch_optional_constant(aircraft_aero_and_propulsive_database, "x_tail_aerodynamic_center", 0.0),
    tail_aero_center_y=fetch_optional_constant(aircraft_aero_and_propulsive_database, "y_tail_aerodynamic_center", 0.0),
    tail_aero_center_z=fetch_optional_constant(aircraft_aero_and_propulsive_database, "z_tail_aerodynamic_center", 0.0),
    x_horizontal_tail_aerodynamic_center=horizontal_tail_ac_xyz_m[1],
    y_horizontal_tail_aerodynamic_center=horizontal_tail_ac_xyz_m[2],
    z_horizontal_tail_aerodynamic_center=horizontal_tail_ac_xyz_m[3],
    x_vertical_tail_aerodynamic_center=vertical_tail_ac_xyz_m[1],
    y_vertical_tail_aerodynamic_center=vertical_tail_ac_xyz_m[2],
    z_vertical_tail_aerodynamic_center=vertical_tail_ac_xyz_m[3],
    tail_CL_q=fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_CL_q", 3.0),
    tail_CS_r=fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_CS_r", 0.5),
    tail_CD0=fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_CD0", 0.015),
    tail_k_induced=fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_k_induced", 0.20),
    tail_k_side=fetch_optional_constant(aircraft_aero_and_propulsive_database, "tail_k_side", 0.10),
    horizontal_tail_downwash_slope=fetch_optional_constant(aircraft_aero_and_propulsive_database, "horizontal_tail_downwash_slope", 0.35),
    horizontal_tail_downwash_max_abs_deg=fetch_optional_constant(aircraft_aero_and_propulsive_database, "horizontal_tail_downwash_max_abs_deg", 12.0),
    vertical_tail_sidewash_slope=fetch_optional_constant(aircraft_aero_and_propulsive_database, "vertical_tail_sidewash_slope", 0.20),
    vertical_tail_sidewash_max_abs_deg=fetch_optional_constant(aircraft_aero_and_propulsive_database, "vertical_tail_sidewash_max_abs_deg", 10.0),
    scale_tail_forces=fetch_optional_constant(aircraft_aero_and_propulsive_database, "scale_tail_forces", 1.0),
    max_aileron_deflection_deg=_extract_max_deflection_deg(normalized_aircraft_yaml, "aileron", 25.0),
    max_elevator_deflection_deg=_extract_max_deflection_deg(normalized_aircraft_yaml, "elevator", 25.0),
    max_rudder_deflection_deg=_extract_max_deflection_deg(normalized_aircraft_yaml, "rudder", 30.0), Cl_da=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cl_da", 0.0),
    Cm_de=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cm_de", 0.0),
    Cn_dr=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cn_dr", 0.0),
    Cn_da=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cn_da", 0.0),
    Cm0=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cm0", 0.0),
    Cm_trim=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cm_trim", 0.0),
    Cn_beta=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cn_beta", 0.0),
    Cl_beta=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cl_beta", 0.0),
    Cm_alpha=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cm_alpha", 0.0),
    Cl_p=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cl_p", 0.0; aliases=["Cl_p_hat", "cl_p_hat"]),
    Cm_q=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cm_q", 0.0; aliases=["Cm_q_hat", "cm_q_hat"]),
    Cn_r=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cn_r", 0.0; aliases=["Cn_r_hat", "cn_r_hat"]),
    Cn_p=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cn_p", 0.0; aliases=["Cn_p_hat", "cn_p_hat"]),
    Cl_r=fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cl_r", 0.0; aliases=["Cl_r_hat", "cl_r_hat"]), maximum_thrust_at_sea_level=maximum_total_thrust,
    thrust_installation_angle_DEG=fetch_optional_constant(aircraft_aero_and_propulsive_database, "thrust_installation_angle_DEG", 0.0; aliases=["thrust_installation_angle_deg"]),
    # Priority: mission YAML override → aero YAML value → 4.0 /s default.
    # Exposing this in the mission lets a user tune control feel per
    # session without editing the aircraft database.
    control_actuator_speed=Float64(get(
        MISSION_DATA,
        "control_actuator_speed",
        fetch_optional_constant(aircraft_aero_and_propulsive_database,
            "control_actuator_speed", 4.0; aliases=["actuator_speed_per_s"])
    )),
    engine_spool_up_speed=_vector_mean(
        engine_spool_up_speeds,
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "engine_spool_up_speed", 1.0; aliases=["engine_spool_up_per_s"])
    ),
    engine_spool_down_speed=_vector_mean(
        engine_spool_down_speeds,
        fetch_optional_constant(aircraft_aero_and_propulsive_database, "engine_spool_down_speed", 1.0; aliases=["engine_spool_down_per_s"])
    ), alpha_stall_positive=fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_positive", 15.0),
    alpha_stall_negative=fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_negative", -15.0),
    CL_max=fetch_optional_constant(aircraft_aero_and_propulsive_database, "CL_max", 1.2),
    stall_speed_sea_level_m_s=fetch_optional_constant(aircraft_aero_and_propulsive_database, "stall_speed_sea_level_m_s", 0.0),
    stall_speed_analysis_altitude_m_s=fetch_optional_constant(aircraft_aero_and_propulsive_database, "stall_speed_analysis_altitude_m_s", 0.0),
    recommended_initial_velocity_m_s=fetch_optional_constant(aircraft_aero_and_propulsive_database, "recommended_initial_velocity_m_s", 0.0),
    CD0=fetch_optional_constant(aircraft_aero_and_propulsive_database, "CD0", 0.013),
    dynamic_stall_alpha_on_deg=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "dynamic_stall_alpha_on_deg",
        max(
            abs(fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_positive", 15.0)),
            abs(fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_negative", -15.0))
        )
    ),
    dynamic_stall_alpha_off_deg=fetch_optional_constant(
        aircraft_aero_and_propulsive_database,
        "dynamic_stall_alpha_off_deg",
        max(
            max(
                abs(fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_positive", 15.0)),
                abs(fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_negative", -15.0))
            ) - 4.0,
            0.0
        )
    ),
    dynamic_stall_tau_alpha_s=fetch_optional_constant(aircraft_aero_and_propulsive_database, "dynamic_stall_tau_alpha_s", 0.08),
    dynamic_stall_tau_sigma_rise_s=fetch_optional_constant(aircraft_aero_and_propulsive_database, "dynamic_stall_tau_sigma_rise_s", 0.12),
    dynamic_stall_tau_sigma_fall_s=fetch_optional_constant(aircraft_aero_and_propulsive_database, "dynamic_stall_tau_sigma_fall_s", 0.35),
    dynamic_stall_qhat_to_alpha_deg=fetch_optional_constant(aircraft_aero_and_propulsive_database, "dynamic_stall_qhat_to_alpha_deg", 2.0),
    poststall_cl_scale=fetch_optional_constant(aircraft_aero_and_propulsive_database, "poststall_cl_scale", 1.1),
    poststall_cd90=fetch_optional_constant(aircraft_aero_and_propulsive_database, "poststall_cd90", 1.6),
    poststall_cd_min=fetch_optional_constant(aircraft_aero_and_propulsive_database, "poststall_cd_min", 0.08),
    poststall_sideforce_scale=fetch_optional_constant(aircraft_aero_and_propulsive_database, "poststall_sideforce_scale", 0.70),
    # Linear aerodynamic coefficients (optional; used only when the simulator
    # is running in linear-aero mode, controlled by the mission yaml key
    # `aerodynamic_model_mode`: "linear" | "table").  When absent the linear
    # model falls back to conservative defaults defined in
    # 0.3_🧮_linear_aerodynamic_model.jl.
    # Control-surface derivatives:  the new key names are `*_delta_*`, but
    # legacy aircraft YAML files use the short form `C?_d?` (e.g. Cm_de,
    # Cl_da, Cn_dr, Cn_da).  All magnitudes are treated as /rad.  Aliases
    # keep backwards compatibility so legacy SU57-style YAMLs drive the
    # linear model without having to be rewritten.
    CL_0       = fetch_optional_constant(aircraft_aero_and_propulsive_database, "CL_0",       0.35; aliases=["cl_0"]),
    CL_alpha   = fetch_optional_constant(aircraft_aero_and_propulsive_database, "CL_alpha",   5.50; aliases=["cl_alpha"]),
    CL_q_hat   = fetch_optional_constant(aircraft_aero_and_propulsive_database, "CL_q_hat",   4.00; aliases=["cl_q_hat","cl_q"]),
    CL_delta_e = fetch_optional_constant(aircraft_aero_and_propulsive_database, "CL_delta_e", 0.40; aliases=["cl_delta_e","cl_de"]),
    CY_beta    = fetch_optional_constant(aircraft_aero_and_propulsive_database, "CY_beta",   -0.50; aliases=["cy_beta","cs_beta"]),
    CY_delta_r = fetch_optional_constant(aircraft_aero_and_propulsive_database, "CY_delta_r", 0.15; aliases=["cy_delta_r","cs_delta_r"]),
    Cl_delta_a = fetch_optional_constant_with_per_degree_alias(
        aircraft_aero_and_propulsive_database,
        "Cl_delta_a",
        0.20;
        aliases=["cl_delta_a_linear","Cl_da","cl_da"],
        per_degree_aliases=["Cl_da_per_deg","cl_da_per_deg"]
    ),
    Cl_delta_r = fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cl_delta_r", 0.0; aliases=["Cl_dr","cl_dr"]),
    Cm_delta_e = fetch_optional_constant_with_per_degree_alias(
        aircraft_aero_and_propulsive_database,
        "Cm_delta_e",
        -1.50;
        aliases=["cm_delta_e_linear","Cm_de","cm_de"],
        per_degree_aliases=["Cm_de_per_deg","cm_de_per_deg"]
    ),
    # Extra pitching-moment stiffness (per rad).  Added on top of the Cm
    # coefficient table in "table" mode — useful when the underlying
    # VortexLattice/JDATCOM export has produced a weaker-than-physical
    # Cm_alpha and we need to restore a realistic short-period response.
    Cm_alpha_extra = fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cm_alpha_extra", 0.0),
    # Sideslip stall limit (degrees).  Sets the soft-saturation envelope
    # for β in the linear aerodynamic model.  Beyond ±beta_stall, CY, Cl_β
    # and Cn_β contributions stop growing linearly and smoothly cap out.
    beta_stall = fetch_optional_constant(aircraft_aero_and_propulsive_database, "beta_stall", 20.0; aliases=["beta_stall_deg"]),
    # Soft-saturation knee widths (degrees).  The smooth transition from
    # "fully linear" to "fully saturated" takes place over this angular
    # range above the stall threshold.
    alpha_stall_knee_deg = fetch_optional_constant(aircraft_aero_and_propulsive_database, "alpha_stall_knee_deg", 3.0),
    beta_stall_knee_deg  = fetch_optional_constant(aircraft_aero_and_propulsive_database, "beta_stall_knee_deg",  5.0),
    Cn_delta_a = fetch_optional_constant(aircraft_aero_and_propulsive_database, "Cn_delta_a", 0.0; aliases=["Cn_da","cn_da"]),
    # Cn_delta_r default is POSITIVE: right rudder (positive δr in the sim
    # convention, i.e. right pedal → nose right) produces a positive
    # yawing moment. Verified empirically by probing r_yaw_rate dynamics.
    Cn_delta_r = fetch_optional_constant_with_per_degree_alias(
        aircraft_aero_and_propulsive_database,
        "Cn_delta_r",
        0.10;
        aliases=["Cn_dr","cn_dr"],
        per_degree_aliases=["Cn_dr_per_deg","cn_dr_per_deg"]
    ),
    # Aerodynamic model mode: "linear" uses the scalar-derivative path in
    # 0.3, "table" uses the full coefficient tables.  Falls back to "table".
    aerodynamic_model_mode = lowercase(string(get(MISSION_DATA, "aerodynamic_model_mode", "table"))),
    I_body=aircraft_inertia_tensor_body,
    # Schema v3.0 — per-tail-surface geometry (name, arm_m, ac_xyz_m). Used by
    # the assembler in 0.2.5 to perform r×F moment transfer from tail AC → CoG.
    tail_surfaces = tail_surface_geometry,
    # True when the v3 `wb_*` tables are present in the database.
    use_component_assembly = has_v3_split_tables(aircraft_aero_and_propulsive_database),
)
