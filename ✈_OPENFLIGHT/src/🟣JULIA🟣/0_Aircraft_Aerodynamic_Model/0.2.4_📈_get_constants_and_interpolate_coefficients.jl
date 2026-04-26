struct ParameterBounds
    min_val::Float64
    max_val::Float64
end

struct SortedParameterData
    values::Vector{Float64}
    source_indices::Dict{Float64,Int}
end

struct FastLookupState
    alpha_deg::Float64
    beta_deg::Float64
    mach::Float64
    config_id::Int
end

struct FastTensorMetadata
    axis_count::Int
    kind_codes::NTuple{4,UInt8}
    sorted_values::NTuple{4,Vector{Float64}}
    sorted_source_indices::NTuple{4,Vector{Int}}
    bound_mins::NTuple{4,Float64}
    bound_maxs::NTuple{4,Float64}
    alpha_axis_slot::Int
    beta_axis_slot::Int
    mach_axis_slot::Int
    config_axis_slot::Int
    config_local_from_global::Vector{Int}
end

struct CoefficientMetadata
    parameters::Vector{String}
    canonical_parameters::Vector{String}
    parameter_lookup::Dict{String,String}
    parameter_kinds::Dict{String,Symbol}
    bounds::Dict{String,ParameterBounds}
    sorted_data::Dict{String,SortedParameterData}
    categorical_values::Dict{String,Vector{String}}
    categorical_indices::Dict{String,Dict{String,Int}}
    data_format::Symbol
end

struct AeroData
    constants::Dict{String,Any}
    coefficients::Dict{String,Any}
    metadata::Dict{String,CoefficientMetadata}
    constant_aliases::Dict{String,String}
    coefficient_aliases::Dict{String,String}
    tuning::Dict{String,Any}
    configuration_names::Vector{String}
    configuration_aliases::Dict{String,Int}
    fast_tensor_metadata::Dict{String,FastTensorMetadata}
end

const _PARAMETER_ALIASES = Dict{String,String}(
    "mach_number" => "mach",
    "mach" => "mach",
    "alpha" => "alpha",
    "alpha_deg" => "alpha",
    "alpha_degrees" => "alpha",
    "beta" => "beta",
    "beta_deg" => "beta",
    "beta_degrees" => "beta",
    "altitude" => "altitude_m",
    "altitude_m" => "altitude_m",
    "height_m" => "altitude_m",
    "h_m" => "altitude_m",
    "throttle" => "throttle",
    "throttle_setting" => "throttle",
    "thrust" => "throttle",
    "tau" => "throttle",
    "config" => "config",
    "configuration" => "config",
    "configuration_id" => "config",
    "engine" => "engine",
    "engine_index" => "engine",
    "p" => "p",
    "q" => "q",
    "r" => "r",
    "p_hat" => "p_hat",
    "q_hat" => "q_hat",
    "r_hat" => "r_hat",
    "elevator_deg" => "elevator_deg",
    "elevator" => "elevator_deg",
    "delta_e" => "elevator_deg",
    "delta_e_deg" => "elevator_deg",
    "rudder_deg" => "rudder_deg",
    "rudder" => "rudder_deg",
    "delta_r" => "rudder_deg",
    "delta_r_deg" => "rudder_deg",
)

const _CONSTANT_ALIAS_CANDIDATES = Dict{String,Vector{String}}(
    "aircraft_mass" => ["mass_kg", "reference.mass_kg", "mass_properties.mass_kg"],
    "radius_of_giration_pitch" => ["radius_of_gyration_pitch_m", "inertia.radius_of_gyration_pitch_m", "inertia.radius_of_gyration_m.pitch"],
    "radius_of_giration_roll" => ["radius_of_gyration_roll_m", "inertia.radius_of_gyration_roll_m", "inertia.radius_of_gyration_m.roll"],
    "radius_of_giration_yaw" => ["radius_of_gyration_yaw_m", "inertia.radius_of_gyration_yaw_m", "inertia.radius_of_gyration_m.yaw"],
    "principal_axis_pitch_up_DEG" => ["principal_axis_pitch_up_deg", "inertia.principal_axis_pitch_up_deg", "inertia.principal_axes_pitch_angle_deg", "inertia.pitch_angle_deg"],
    "x_CoG" => ["x_cog_m", "x_cg_m", "reference.x_cog_m", "reference.x_cg_m", "reference.cg.x_m", "reference.cg_ref_m.x"],
    "y_CoG" => ["y_cog_m", "y_cg_m", "reference.y_cog_m", "reference.y_cg_m", "reference.cg.y_m", "reference.cg_ref_m.y"],
    "z_CoG" => ["z_cog_m", "z_cg_m", "reference.z_cog_m", "reference.z_cg_m", "reference.cg.z_m", "reference.cg_ref_m.z"],
    "x_wing_aerodynamic_center" => ["x_wing_aerodynamic_center_m", "reference.x_wing_aerodynamic_center_m", "reference.wing_aerodynamic_center_m.x"],
    "y_wing_aerodynamic_center" => ["y_wing_aerodynamic_center_m", "reference.y_wing_aerodynamic_center_m", "reference.wing_aerodynamic_center_m.y"],
    "z_wing_aerodynamic_center" => ["z_wing_aerodynamic_center_m", "reference.z_wing_aerodynamic_center_m", "reference.wing_aerodynamic_center_m.z"],
    "reference_area" => ["reference_area_m2", "s_ref_m2", "wing_area_m2", "reference.reference_area_m2", "reference.s_ref_m2", "reference.geometry.S_ref_m2"],
    "reference_span" => ["reference_span_m", "b_ref_m", "span_m", "reference.reference_span_m", "reference.b_ref_m", "reference.geometry.b_ref_m"],
    "wing_mean_aerodynamic_chord" => ["mean_aerodynamic_chord_m", "mac_m", "reference.mean_aerodynamic_chord_m", "reference.mac_m", "reference.geometry.c_ref_m"],
    "AR" => ["aspect_ratio", "reference.aspect_ratio"],
    "Oswald_factor" => ["oswald", "oswald_factor", "oswald_efficiency_factor", "reference.oswald_factor"],
    "maximum_thrust_at_sea_level" => ["maximum_thrust_n", "max_thrust_n", "propulsion.maximum_thrust_n", "propulsion.total_max_thrust_n"],
    "thrust_installation_angle_DEG" => ["thrust_installation_angle_deg", "propulsion.thrust_installation_angle_deg"],
    "control_actuator_speed" => ["actuator_speed_per_s", "controls.actuator_speed_per_s", "flight_controls.actuator_speed_per_s"],
    "engine_spool_up_speed" => ["engine_spool_up_per_s", "propulsion.engine_spool_up_per_s"],
    "engine_spool_down_speed" => ["engine_spool_down_per_s", "propulsion.engine_spool_down_per_s"],
)

function _normalize_token(value)::String
    token = lowercase(strip(string(value)))
    token = replace(token, "-" => "_", " " => "_")
    return replace(token, r"[^a-z0-9_]" => "")
end

function _canonicalize_parameter_name(value)::String
    normalized = _normalize_token(value)
    return get(_PARAMETER_ALIASES, normalized, normalized)
end

function _deep_stringify_keys(data)
    if data isa AbstractDict
        output = Dict{String,Any}()
        for (k, v) in data
            output[string(k)] = _deep_stringify_keys(v)
        end
        return output
    elseif data isa Vector
        return [_deep_stringify_keys(v) for v in data]
    end
    return data
end

function _flatten_scalar_constants!(target::Dict{String,Any}, source; prefix::String="", skip_keys::Set{String}=Set{String}())
    if source isa AbstractDict
        for (raw_key, value) in source
            key = string(raw_key)
            if key in skip_keys
                continue
            end
            path = isempty(prefix) ? key : string(prefix, ".", key)
            _flatten_scalar_constants!(target, value; prefix=path)
        end
        return
    end

    if source isa Vector
        if all(v -> v isa Number, source)
            target[prefix] = [Float64(v) for v in source]
        end
        return
    end

    target[prefix] = source
    leaf = split(prefix, ".")[end]
    if !haskey(target, leaf)
        target[leaf] = source
    end
end

function _build_constants_dictionary(data::Dict{String,Any})
    constants = Dict{String,Any}()

    if haskey(data, "constants") && data["constants"] isa AbstractDict
        _flatten_scalar_constants!(constants, data["constants"])
    end

    if haskey(data, "runtime_model") && data["runtime_model"] isa AbstractDict
        if haskey(data["runtime_model"], "constants") && data["runtime_model"]["constants"] isa AbstractDict
            _flatten_scalar_constants!(constants, data["runtime_model"]["constants"])
        end
        # Extract LINEAR-MODEL scalar stability derivatives from
        # runtime_model. These are the slopes at α≈0 / β≈0 extracted
        # from the full-envelope tables by the model creator's
        # extract_scalar_derivatives(). Only names that the LINEAR model
        # reads via `fetch_optional_constant` are imported — dynamic
        # derivatives (_hat suffixed) and control effectiveness (_per_deg)
        # are excluded to prevent the alias system from short-circuiting
        # the table lookup engine in TABLE mode.
        _linear_scalar_names = Set([
            "CL_0", "CL_alpha", "CL_q_hat", "CL_delta_e", "CD0", "Cm0", "Cm_alpha", "Cm_q_hat", "Cm_de_per_deg", "Cm_alpha_extra",
            "CY_beta", "CY_delta_r", "Cl_beta", "Cl_p_hat", "Cl_r", "Cl_da_per_deg", "Cl_delta_r",
            "Cn_beta", "Cn_p", "Cn_r_hat", "Cn_delta_a", "Cn_dr_per_deg",
            "alpha_stall_positive", "alpha_stall_negative", "CL_max",
            "stall_speed_sea_level_m_s", "stall_speed_analysis_altitude_m_s", "recommended_initial_velocity_m_s",
            "dynamic_stall_alpha_on_deg", "dynamic_stall_alpha_off_deg", "dynamic_stall_tau_alpha_s",
            "dynamic_stall_tau_sigma_rise_s", "dynamic_stall_tau_sigma_fall_s", "dynamic_stall_qhat_to_alpha_deg",
            "poststall_cl_scale", "poststall_cd90", "poststall_cd_min", "poststall_sideforce_scale",
            "tail_CD0", "tail_CL_q", "tail_CS_r", "tail_k_induced", "tail_k_side",
        ])
        runtime_section = data["runtime_model"]
        for k in _linear_scalar_names
            if haskey(runtime_section, k) && runtime_section[k] isa Number
                constants[k] = Float64(runtime_section[k])
            end
        end
    end

    section_specs = [
        ("reference", Set(["coefficients", "tables", "surfaces"])),
        ("mass_properties", Set{String}()),
        ("inertia", Set{String}()),
        ("flight_dynamics", Set{String}()),
        ("controls", Set{String}()),
        ("flight_controls", Set{String}()),
        ("propulsion", Set(["engines", "engine_models"])),
    ]

    for (section_name, skip_keys) in section_specs
        if haskey(data, section_name) && data[section_name] isa AbstractDict
            _flatten_scalar_constants!(constants, data[section_name]; prefix=section_name, skip_keys=skip_keys)
        end
    end

    if haskey(data, "aerodynamics") && data["aerodynamics"] isa AbstractDict
        aero_skip_keys = Set([
            "coefficients",
            "tables",
            "surfaces",
            "coefficient_tuning",
            "wing_body",
            "tail",
            "interference",
            "static_coefficients",
            "dynamic_derivatives",
            "control_effectiveness",
            "control_drag_increments",
            "body_forces",
            "local_flow",
        ])
        _flatten_scalar_constants!(
            constants,
            data["aerodynamics"];
            prefix="aerodynamics",
            skip_keys=aero_skip_keys
        )
    end

    for (key, value) in data
        if value isa AbstractDict || value isa Vector
            continue
        end
        if !haskey(constants, key)
            constants[key] = value
        end
    end

    for (canonical_key, candidates) in _CONSTANT_ALIAS_CANDIDATES
        if haskey(constants, canonical_key)
            continue
        end
        for candidate in candidates
            if haskey(constants, candidate)
                constants[canonical_key] = constants[candidate]
                break
            end
        end
    end

    return constants
end

function _build_coefficient_tuning(data::Dict{String,Any})
    if haskey(data, "aerodynamics") && data["aerodynamics"] isa AbstractDict
        aero = data["aerodynamics"]
        if haskey(aero, "coefficient_tuning") && aero["coefficient_tuning"] isa AbstractDict
            raw_tuning = _deep_stringify_keys(aero["coefficient_tuning"])
            return Dict{String,Any}(string(k) => v for (k, v) in raw_tuning)
        end
    end
    return Dict{String,Any}()
end

function _build_alias_index(keys_iterable)
    alias_map = Dict{String,String}()
    for key in keys_iterable
        normalized = _normalize_token(key)
        alias_map[normalized] = key

        # Add automatic mapping for _hat and _per_deg variables
        if endswith(normalized, "_hat")
            alias_map[normalized[1:end-4]] = key
        elseif endswith(normalized, "_per_deg")
            alias_map[normalized[1:end-8]] = key
        end
    end
    return alias_map
end

function _is_tensor_coefficient_definition(coeff_data::Dict{String,Any})
    return haskey(coeff_data, "axis_order") && haskey(coeff_data, "axes") && haskey(coeff_data, "values")
end

function _looks_like_coefficient_payload(value)
    return value isa AbstractDict && haskey(value, "values")
end

function _is_numeric_axis(values::Vector)
    return !isempty(values) && all(v -> v isa Number, values)
end

function _find_parameter_values_in_legacy_tree(data::Vector, param::String)
    values = Any[]
    for entry in data
        if !(entry isa AbstractDict)
            continue
        end
        if haskey(entry, param)
            push!(values, entry[param])
        end
        if haskey(entry, "data") && entry["data"] isa Vector
            append!(values, _find_parameter_values_in_legacy_tree(entry["data"], param))
        end
    end
    return unique(values)
end

function _compute_parameter_bounds(values::Vector{Float64})
    return ParameterBounds(minimum(values), maximum(values))
end

function _create_sorted_parameter_data(values::Vector{Float64})
    sorted_values = sort(unique(values))
    source_indices = Dict(value => i for (i, value) in enumerate(values))
    return SortedParameterData(sorted_values, source_indices)
end

function _compute_legacy_coefficient_metadata(coeff_data::Dict{String,Any})
    if !(haskey(coeff_data, "parameters") && haskey(coeff_data, "data"))
        throw(ArgumentError("Legacy coefficient must contain 'parameters' and 'data' keys"))
    end

    parameters = [string(param) for param in coeff_data["parameters"]]
    canonical_parameters = [_canonicalize_parameter_name(param) for param in parameters]
    parameter_lookup = Dict(canonical => param for (canonical, param) in zip(canonical_parameters, parameters))
    parameter_kinds = Dict{String,Symbol}()
    bounds = Dict{String,ParameterBounds}()
    sorted_data = Dict{String,SortedParameterData}()
    categorical_values = Dict{String,Vector{String}}()
    categorical_indices = Dict{String,Dict{String,Int}}()

    for param in parameters
        values = _find_parameter_values_in_legacy_tree(coeff_data["data"], param)
        if isempty(values)
            throw(ArgumentError("No values found for parameter '$param' in legacy aerodynamic table"))
        end

        if _is_numeric_axis(values)
            numeric_values = [Float64(v) for v in values]
            parameter_kinds[param] = :numeric
            bounds[param] = _compute_parameter_bounds(numeric_values)
            sorted_data[param] = _create_sorted_parameter_data(numeric_values)
        else
            categories = [string(v) for v in values]
            parameter_kinds[param] = :categorical
            categorical_values[param] = categories
            categorical_indices[param] = Dict(category => i for (i, category) in enumerate(categories))
        end
    end

    return CoefficientMetadata(
        parameters,
        canonical_parameters,
        parameter_lookup,
        parameter_kinds,
        bounds,
        sorted_data,
        categorical_values,
        categorical_indices,
        :legacy
    )
end

function _compute_tensor_coefficient_metadata(coeff_data::Dict{String,Any})
    axis_order = [string(param) for param in coeff_data["axis_order"]]
    axes = Dict{String,Any}(string(k) => v for (k, v) in coeff_data["axes"])

    canonical_parameters = [_canonicalize_parameter_name(param) for param in axis_order]
    parameter_lookup = Dict(canonical => param for (canonical, param) in zip(canonical_parameters, axis_order))
    parameter_kinds = Dict{String,Symbol}()
    bounds = Dict{String,ParameterBounds}()
    sorted_data = Dict{String,SortedParameterData}()
    categorical_values = Dict{String,Vector{String}}()
    categorical_indices = Dict{String,Dict{String,Int}}()

    for param in axis_order
        if !haskey(axes, param)
            throw(ArgumentError("Tensor coefficient missing axis values for '$param'"))
        end

        axis_values = axes[param]
        if !(axis_values isa Vector)
            throw(ArgumentError("Tensor axis '$param' must be a vector"))
        end
        if isempty(axis_values)
            throw(ArgumentError("Tensor axis '$param' cannot be empty"))
        end

        if _is_numeric_axis(axis_values)
            numeric_values = [Float64(v) for v in axis_values]
            parameter_kinds[param] = :numeric
            bounds[param] = _compute_parameter_bounds(numeric_values)
            sorted_pairs = sort(collect(enumerate(numeric_values)); by=x -> x[2])
            sorted_values = [pair[2] for pair in sorted_pairs]
            source_indices = Dict(value => index for (index, value) in enumerate(numeric_values))
            sorted_data[param] = SortedParameterData(sorted_values, source_indices)
        else
            categories = [string(v) for v in axis_values]
            parameter_kinds[param] = :categorical
            categorical_values[param] = categories
            categorical_indices[param] = Dict(category => i for (i, category) in enumerate(categories))
        end
    end

    return CoefficientMetadata(
        axis_order,
        canonical_parameters,
        parameter_lookup,
        parameter_kinds,
        bounds,
        sorted_data,
        categorical_values,
        categorical_indices,
        :tensor
    )
end

function _compute_coefficient_metadata(coeff_data::Dict{String,Any})
    if _is_tensor_coefficient_definition(coeff_data)
        return _compute_tensor_coefficient_metadata(coeff_data)
    end
    return _compute_legacy_coefficient_metadata(coeff_data)
end

function _build_configuration_registry(metadata::Dict{String,CoefficientMetadata})
    names = String[]
    aliases = Dict{String,Int}()

    for meta in values(metadata)
        haskey(meta.parameter_lookup, "config") || continue
        param_name = meta.parameter_lookup["config"]
        categories = get(meta.categorical_values, param_name, String[])
        for category in categories
            normalized = _normalize_token(category)
            haskey(aliases, normalized) && continue
            push!(names, category)
            aliases[normalized] = length(names)
        end
    end

    if isempty(names)
        push!(names, "clean")
        aliases["clean"] = 1
    end

    return names, aliases
end

function _build_fast_tensor_metadata(
    metadata::CoefficientMetadata,
    configuration_aliases::Dict{String,Int},
)
    metadata.data_format == :tensor || return nothing
    axis_count = length(metadata.parameters)
    axis_count <= 4 || return nothing

    kind_codes = fill(UInt8(0), 4)
    sorted_values = [Float64[] for _ in 1:4]
    sorted_source_indices = [Int[] for _ in 1:4]
    bound_mins = fill(0.0, 4)
    bound_maxs = fill(0.0, 4)

    alpha_axis_slot = 0
    beta_axis_slot = 0
    mach_axis_slot = 0
    config_axis_slot = 0

    for slot in 1:axis_count
        param_name = metadata.parameters[slot]
        canonical_name = metadata.canonical_parameters[slot]

        if canonical_name == "config"
            kind_codes[slot] = 0x02
            config_axis_slot = slot
            continue
        elseif canonical_name == "alpha"
            alpha_axis_slot = slot
        elseif canonical_name == "beta"
            beta_axis_slot = slot
        elseif canonical_name == "mach"
            mach_axis_slot = slot
        else
            return nothing
        end

        if get(metadata.parameter_kinds, param_name, :categorical) != :numeric
            return nothing
        end

        kind_codes[slot] = 0x01
        haskey(metadata.sorted_data, param_name) || return nothing
        haskey(metadata.bounds, param_name) || return nothing

        sd = metadata.sorted_data[param_name]
        sorted_values[slot] = sd.values
        sorted_source_indices[slot] = [sd.source_indices[value] for value in sd.values]
        bound_mins[slot] = metadata.bounds[param_name].min_val
        bound_maxs[slot] = metadata.bounds[param_name].max_val
    end

    config_local_from_global = Int[]
    if config_axis_slot != 0
        param_name = metadata.parameters[config_axis_slot]
        categories = get(metadata.categorical_values, param_name, String[])
        isempty(categories) && return nothing

        category_to_local = Dict{String,Int}()
        for (local_index, category) in enumerate(categories)
            category_to_local[_normalize_token(category)] = local_index
        end

        config_local_from_global = fill(1, length(configuration_aliases))
        for (normalized_name, global_index) in configuration_aliases
            config_local_from_global[global_index] = get(category_to_local, normalized_name, 1)
        end
    end

    return FastTensorMetadata(
        axis_count,
        (kind_codes[1], kind_codes[2], kind_codes[3], kind_codes[4]),
        (sorted_values[1], sorted_values[2], sorted_values[3], sorted_values[4]),
        (sorted_source_indices[1], sorted_source_indices[2], sorted_source_indices[3], sorted_source_indices[4]),
        (bound_mins[1], bound_mins[2], bound_mins[3], bound_mins[4]),
        (bound_maxs[1], bound_maxs[2], bound_maxs[3], bound_maxs[4]),
        alpha_axis_slot,
        beta_axis_slot,
        mach_axis_slot,
        config_axis_slot,
        config_local_from_global,
    )
end

function _reorder_dict_values_to_vector(values, axis_order::Vector, axes::AbstractDict)
    # When the YAML grouped format nests values under category keys (e.g. "clean", "landing"),
    # the parsed result is a Dict instead of a Vector. The tensor interpolation expects a
    # nested Vector indexed by integers. This function converts Dict-keyed levels to Vectors
    # ordered according to the category order defined in axes.
    if !(values isa AbstractDict)
        return values
    end

    # Find which axis this Dict level corresponds to by checking if its keys match
    # any categorical axis in the axis_order.
    matched_axis = nothing
    for axis_name in axis_order
        if !haskey(axes, string(axis_name))
            continue
        end
        axis_categories = [string(c) for c in axes[string(axis_name)]]
        dict_keys = Set(string(k) for k in keys(values))
        if !isempty(intersect(dict_keys, Set(axis_categories)))
            matched_axis = axis_name
            break
        end
    end

    if matched_axis === nothing
        return values
    end

    # Build remaining axis_order for recursive processing of nested levels
    remaining_axes = filter(a -> a != matched_axis, axis_order)
    axis_categories = [string(c) for c in axes[string(matched_axis)]]

    ordered_values = Any[]
    for category in axis_categories
        category_key = string(category)
        if haskey(values, category_key)
            nested = values[category_key]
            # Recursively convert any deeper Dict levels
            push!(ordered_values, _reorder_dict_values_to_vector(nested, remaining_axes, axes))
        end
    end

    return ordered_values
end

function _extract_coefficients_dictionary(data::Dict{String,Any})
    extracted = Dict{String,Any}()

    if haskey(data, "coefficients") && data["coefficients"] isa AbstractDict
        for (k, v) in data["coefficients"]
            extracted[string(k)] = v
        end
    end

    if haskey(data, "aerodynamics") && data["aerodynamics"] isa AbstractDict
        aero_section = data["aerodynamics"]

        # Parse legacy formats
        for key in ("coefficients", "tables", "surfaces")
            if haskey(aero_section, key) && aero_section[key] isa AbstractDict
                for (k, v) in aero_section[key]
                    extracted[string(k)] = v
                end
            end
        end

        # Parse new grouped unified formats
        for subgroup in ("static_coefficients", "dynamic_derivatives", "control_effectiveness", "control_drag_increments", "body_forces", "local_flow")
            if haskey(aero_section, subgroup) && aero_section[subgroup] isa AbstractDict
                group_data = aero_section[subgroup]
                if haskey(group_data, "axis_order") && haskey(group_data, "axes")
                    # Shared axis_order/axes at the group level (static_coefficients, etc.)
                    axis_order = group_data["axis_order"]
                    axes = group_data["axes"]
                    for (k, v) in group_data
                        if k != "axis_order" && k != "axes" && _looks_like_coefficient_payload(v)
                            coeff_dict = Dict{String,Any}(string(sub_k) => sub_v for (sub_k, sub_v) in v)
                            coeff_dict["axis_order"] = axis_order
                            coeff_dict["axes"] = axes
                            # Convert Dict-keyed values to ordered Vectors so the tensor
                            # interpolation can index them by integer position.
                            if haskey(coeff_dict, "values") && coeff_dict["values"] isa AbstractDict
                                coeff_dict["values"] = _reorder_dict_values_to_vector(
                                    coeff_dict["values"], [string(a) for a in axis_order], axes
                                )
                            end
                            extracted[string(k)] = coeff_dict
                        end
                    end
                else
                    # Per-coefficient axis_order/axes (local_flow, etc.)
                    for (k, v) in group_data
                        if _looks_like_coefficient_payload(v) && haskey(v, "axis_order") && haskey(v, "axes")
                            coeff_dict = Dict{String,Any}(string(sub_k) => sub_v for (sub_k, sub_v) in v)
                            local_axis_order = coeff_dict["axis_order"]
                            local_axes = coeff_dict["axes"]
                            if coeff_dict["values"] isa AbstractDict
                                coeff_dict["values"] = _reorder_dict_values_to_vector(
                                    coeff_dict["values"], [string(a) for a in local_axis_order], local_axes
                                )
                            end
                            extracted[string(k)] = coeff_dict
                        end
                    end
                end
            end
        end
    end

    # Extract coefficient tables from runtime_model.
    # These may use a simple 1D format (alphas_deg + values or betas_deg + values)
    # or 2D (alphas_deg + betas_deg + values).  Convert to tensor format so the
    # existing interpolation engine can handle them.
    if haskey(data, "runtime_model") && data["runtime_model"] isa AbstractDict
        for (k, v) in data["runtime_model"]
            key = string(k)
            if key == "constants" || haskey(extracted, key)
                continue
            end
            if !(v isa AbstractDict) || !haskey(v, "values")
                continue
            end
            coeff_dict = Dict{String,Any}(string(sk) => sv for (sk, sv) in v)
            if haskey(coeff_dict, "axis_order") && haskey(coeff_dict, "axes")
                extracted[key] = coeff_dict
                continue
            end
            has_alpha = haskey(v, "alphas_deg")
            has_beta  = haskey(v, "betas_deg")
            has_elevator = haskey(v, "delta_e_deg")
            has_rudder   = haskey(v, "delta_r_deg")
            if has_alpha && has_elevator
                coeff_dict["axis_order"] = ["alpha_deg", "elevator_deg"]
                coeff_dict["axes"] = Dict{String,Any}(
                    "alpha_deg" => v["alphas_deg"],
                    "elevator_deg" => v["delta_e_deg"],
                )
            elseif has_beta && has_rudder
                coeff_dict["axis_order"] = ["beta_deg", "rudder_deg"]
                coeff_dict["axes"] = Dict{String,Any}(
                    "beta_deg" => v["betas_deg"],
                    "rudder_deg" => v["delta_r_deg"],
                )
            elseif has_alpha && has_beta
                coeff_dict["axis_order"] = ["alpha_deg", "beta_deg"]
                coeff_dict["axes"] = Dict{String,Any}("alpha_deg" => v["alphas_deg"],
                                                       "beta_deg"  => v["betas_deg"])
            elseif has_alpha
                coeff_dict["axis_order"] = ["alpha_deg"]
                coeff_dict["axes"] = Dict{String,Any}("alpha_deg" => v["alphas_deg"])
            elseif has_beta
                coeff_dict["axis_order"] = ["beta_deg"]
                coeff_dict["axes"] = Dict{String,Any}("beta_deg" => v["betas_deg"])
            else
                continue
            end
            extracted[key] = coeff_dict
        end
    end

    # ════════════════════════════════════════════════════════════════
    # Schema v3.0 — wing_body / tail / interference blocks
    # ════════════════════════════════════════════════════════════════
    if haskey(data, "aerodynamics") && data["aerodynamics"] isa AbstractDict
        aero_section = data["aerodynamics"]

        # ── wing_body (same shape as static_coefficients) ──
        if haskey(aero_section, "wing_body") && aero_section["wing_body"] isa AbstractDict
            wb = aero_section["wing_body"]
            if haskey(wb, "axis_order") && haskey(wb, "axes")
                axis_order = wb["axis_order"]
                axes = wb["axes"]
                for (k, v) in wb
                    (k == "axis_order" || k == "axes") && continue
                    _looks_like_coefficient_payload(v) || continue
                    coeff_dict = Dict{String,Any}(string(sk) => sv for (sk, sv) in v)
                    coeff_dict["axis_order"] = axis_order
                    coeff_dict["axes"] = axes
                    if haskey(coeff_dict, "values") && coeff_dict["values"] isa AbstractDict
                        coeff_dict["values"] = _reorder_dict_values_to_vector(
                            coeff_dict["values"], [string(a) for a in axis_order], axes
                        )
                    end
                    extracted["wb_" * string(k)] = coeff_dict
                end
            end
        end

        # ── tail block: list of per-surface coefficient tables in local angles ──
        if haskey(aero_section, "tail") && aero_section["tail"] isa AbstractDict
            tail = aero_section["tail"]
            raw_axes = get(tail, "axes", Dict{String,Any}())
            # The tail axes use local tail angles. Canonicalise to alpha_deg/beta_deg
            # so the existing interpolation engine can resolve them with the same
            # lookup keys the assembler passes (alpha_h, beta_v, mapped to alpha/beta).
            raw_axis_order = get(tail, "axis_order_per_surface", ["config", "mach", "alpha_h_deg", "beta_v_deg"])
            canon_axis_order = [a == "alpha_h_deg" ? "alpha_deg" :
                                (a == "beta_v_deg" ? "beta_deg" : a) for a in raw_axis_order]
            canon_axes = Dict{String,Any}(
                "config" => get(raw_axes, "config", ["clean"]),
                "mach"   => get(raw_axes, "mach", [0.2]),
                "alpha_deg" => get(raw_axes, "alpha_h_deg", Float64[]),
                "beta_deg"  => get(raw_axes, "beta_v_deg",  Float64[]),
            )
            for surf in get(tail, "surfaces", Any[])
                surf isa AbstractDict || continue
                name = string(get(surf, "name", "tail"))
                for cn in ("CL", "CD", "CY", "Cl_at_AC", "Cm_at_AC", "Cn_at_AC")
                    haskey(surf, cn) || continue
                    cv = surf[cn]
                    cv isa AbstractDict || continue
                    coeff_dict = Dict{String,Any}(string(sk) => sv for (sk, sv) in cv)
                    coeff_dict["axis_order"] = canon_axis_order
                    coeff_dict["axes"] = canon_axes
                    if haskey(coeff_dict, "values") && coeff_dict["values"] isa AbstractDict
                        coeff_dict["values"] = _reorder_dict_values_to_vector(
                            coeff_dict["values"], [string(a) for a in canon_axis_order], canon_axes
                        )
                    end
                    extracted["tail_" * name * "_" * cn] = coeff_dict
                end
            end
        end

        # ── interference block (α-indexed + β-indexed 1-D tables) ──
        if haskey(aero_section, "interference") && aero_section["interference"] isa AbstractDict
            ifd = aero_section["interference"]
            raw_axes = get(ifd, "axes", Dict{String,Any}())
            α_axis_order = ["config", "mach", "alpha_deg"]
            β_axis_order = ["config", "mach", "beta_deg"]
            α_axes = Dict{String,Any}(
                "config" => get(raw_axes, "config", ["clean"]),
                "mach"   => get(raw_axes, "mach", [0.2]),
                "alpha_deg" => get(raw_axes, "alpha_deg", Float64[])
            )
            β_axes = Dict{String,Any}(
                "config" => get(raw_axes, "config", ["clean"]),
                "mach"   => get(raw_axes, "mach", [0.2]),
                "beta_deg" => get(raw_axes, "beta_deg", Float64[])
            )
            for (k, axis_order, axes) in (
                ("downwash_deg", α_axis_order, α_axes),
                ("eta_h",        α_axis_order, α_axes),
                ("sidewash_deg", β_axis_order, β_axes),
                ("eta_v",        β_axis_order, β_axes),
            )
                haskey(ifd, k) || continue
                cv = ifd[k]
                cv isa AbstractDict || continue
                coeff_dict = Dict{String,Any}(string(sk) => sv for (sk, sv) in cv)
                coeff_dict["axis_order"] = axis_order
                coeff_dict["axes"] = axes
                if haskey(coeff_dict, "values") && coeff_dict["values"] isa AbstractDict
                    coeff_dict["values"] = _reorder_dict_values_to_vector(
                        coeff_dict["values"], [string(a) for a in axis_order], axes
                    )
                end
                extracted["interference_" * k] = coeff_dict
            end
        end
    end

    # Common name aliases: sideforce is called CY in some models and CS in others.
    if haskey(extracted, "CY") && !haskey(extracted, "CS")
        extracted["CS"] = extracted["CY"]
    end
    if haskey(extracted, "CS") && !haskey(extracted, "CY")
        extracted["CY"] = extracted["CS"]
    end

    return extracted
end

"""
    _as_float_xyz(value, fallback)

Convert a vector or `{x,y,z}` mapping into a Float64 xyz vector.
YAML so the assembler has the r vector for the r×F transfer. Returns an empty
"""
function _as_float_xyz(value, fallback::AbstractVector{<:Real})
    if value isa AbstractVector && length(value) >= 3
        return [Float64(value[1]), Float64(value[2]), Float64(value[3])]
    end
    if value isa AbstractDict
        has_xyz = all(k -> haskey(value, k), ("x", "y", "z"))
        if has_xyz
            return [Float64(value["x"]), Float64(value["y"]), Float64(value["z"])]
        end
    end
    return [Float64(fallback[1]), Float64(fallback[2]), Float64(fallback[3])]
end

function _tail_component_from_role(component_raw::AbstractString, role_raw::AbstractString)
    role = lowercase(role_raw)
    if occursin("vertical", role) || occursin("rudder", role)
        return "tail_v"
    elseif occursin("horizontal", role) || occursin("elevator", role)
        return "tail_h"
    end

    component = lowercase(component_raw)
    if component in ("tail_h", "tail_v")
        return component
    end
    return "tail_h"
end

function _tail_lifting_surface_ac_index(data::AbstractDict)
    by_name = Dict{String,Vector{Float64}}()
    by_role = Dict{String,Vector{Float64}}()
    surface_blocks = Any[get(data, "lifting_surfaces", Any[])]
    visual_geometry = get(data, "visual_geometry", nothing)
    if visual_geometry isa AbstractDict
        push!(surface_blocks, get(visual_geometry, "lifting_surfaces", Any[]))
    end
    geometry = get(data, "geometry", nothing)
    if geometry isa AbstractDict
        push!(surface_blocks, get(geometry, "lifting_surfaces", Any[]))
    end
    for surfaces in surface_blocks
        surfaces isa AbstractVector || continue
        for surf in surfaces
        surf isa AbstractDict || continue
        role = lowercase(string(get(surf, "role", "")))
        is_tail = occursin("stabilizer", role) || occursin("tail", role)
        is_tail || continue

        ac_xyz = _as_float_xyz(get(surf, "aerodynamic_center_m", nothing), [NaN, NaN, NaN])
        all(isfinite, ac_xyz) || continue

        name_key = lowercase(string(get(surf, "name", "")))
        if !isempty(name_key)
            by_name[name_key] = ac_xyz
        end
        if !isempty(role)
            by_role[role] = ac_xyz
        end
    end
    end
    return by_name, by_role
end

function _tail_surface_ac_from_geometry(
    data::AbstractDict,
    name::AbstractString,
    role::AbstractString,
    fallback::AbstractVector{<:Real},
)
    by_name, by_role = _tail_lifting_surface_ac_index(data)
    name_key = lowercase(name)
    if haskey(by_name, name_key)
        return by_name[name_key]
    end

    role_key = lowercase(role)
    if haskey(by_role, role_key)
        return by_role[role_key]
    end

    role_hint = occursin("vertical", role_key) ? "vertical" :
                occursin("horizontal", role_key) ? "horizontal" : ""
    if !isempty(role_hint)
        for (candidate_role, ac_xyz) in by_role
            if occursin(role_hint, candidate_role)
                return ac_xyz
            end
        end
    end

    return [Float64(fallback[1]), Float64(fallback[2]), Float64(fallback[3])]
end

function tail_surface_ac_xyz(
    tail_surfaces::AbstractVector,
    role_hint::AbstractString,
    fallback::AbstractVector{<:Real},
)
    hint = lowercase(role_hint)
    for ts in tail_surfaces
        if hasproperty(ts, :role) && occursin(hint, lowercase(string(ts.role))) &&
           hasproperty(ts, :ac_xyz_m) && length(ts.ac_xyz_m) >= 3
            return [Float64(ts.ac_xyz_m[1]), Float64(ts.ac_xyz_m[2]), Float64(ts.ac_xyz_m[3])]
        end
    end
    return [Float64(fallback[1]), Float64(fallback[2]), Float64(fallback[3])]
end

function _tail_surfaces_from_lifting_surfaces(data::AbstractDict)
    out = NamedTuple[]
    surface_blocks = Any[get(data, "lifting_surfaces", Any[])]
    visual_geometry = get(data, "visual_geometry", nothing)
    if visual_geometry isa AbstractDict
        push!(surface_blocks, get(visual_geometry, "lifting_surfaces", Any[]))
    end
    geometry = get(data, "geometry", nothing)
    if geometry isa AbstractDict
        push!(surface_blocks, get(geometry, "lifting_surfaces", Any[]))
    end
    for surfaces in surface_blocks
        surfaces isa AbstractVector || continue
        for surf in surfaces
        surf isa AbstractDict || continue
        role = string(get(surf, "role", "tail"))
        role_lc = lowercase(role)
        is_tail = occursin("stabilizer", role_lc) || occursin("tail", role_lc)
        is_tail || continue

        ac_xyz = _as_float_xyz(get(surf, "aerodynamic_center_m", nothing), [0.0, 0.0, 0.0])
        push!(out, (
            name = string(get(surf, "name", "tail")),
            role = role,
            component = _tail_component_from_role("", role),
            arm_m = [0.0, 0.0, 0.0],
            ac_xyz_m = ac_xyz,
        ))
    end
    end
    return out
end

"""
    extract_tail_surface_geometry(data::AbstractDict) -> Vector{NamedTuple}

Pull per-tail-surface metadata from the v3 YAML. The role and geometric
lifting-surface aerodynamic center are authoritative when present, so HTP and
VTP origins, local velocities, and r x F moment arms use their own centers.
"""
function extract_tail_surface_geometry(data::AbstractDict)
    out = NamedTuple[]
    if !(haskey(data, "aerodynamics") && data["aerodynamics"] isa AbstractDict)
        return _tail_surfaces_from_lifting_surfaces(data)
    end
    aero = data["aerodynamics"]
    if !(haskey(aero, "tail") && aero["tail"] isa AbstractDict)
        return _tail_surfaces_from_lifting_surfaces(data)
    end
    for surf in get(aero["tail"], "surfaces", Any[])
        surf isa AbstractDict || continue
        name = string(get(surf, "name", "tail"))
        role = string(get(surf, "role", "tail"))
        raw_component = string(get(surf, "component", ""))
        fallback_ac = _as_float_xyz(get(surf, "ac_xyz_m", nothing), [0.0, 0.0, 0.0])
        push!(out, (
            name = name,
            role = role,
            component = _tail_component_from_role(raw_component, role),
            arm_m = _as_float_xyz(get(surf, "arm_m", nothing), [0.0, 0.0, 0.0]),
            ac_xyz_m = _tail_surface_ac_from_geometry(data, name, role, fallback_ac)
        ))
    end
    return isempty(out) ? _tail_surfaces_from_lifting_surfaces(data) : out
end

function parse_aero_data(data::Dict)
    normalized_data = _deep_stringify_keys(data)
    constants = _build_constants_dictionary(normalized_data)
    coefficients = _extract_coefficients_dictionary(normalized_data)
    metadata = Dict{String,CoefficientMetadata}()
    tuning = _build_coefficient_tuning(normalized_data)

    for (coeff_name, coeff_data_raw) in coefficients
        coeff_data = _deep_stringify_keys(coeff_data_raw)
        coefficients[coeff_name] = coeff_data
        metadata[coeff_name] = _compute_coefficient_metadata(coeff_data)
    end

    configuration_names, configuration_aliases = _build_configuration_registry(metadata)
    fast_tensor_metadata = Dict{String,FastTensorMetadata}()
    for (coeff_name, coeff_metadata) in metadata
        fast_meta = _build_fast_tensor_metadata(coeff_metadata, configuration_aliases)
        fast_meta === nothing && continue
        fast_tensor_metadata[coeff_name] = fast_meta
    end

    return AeroData(
        constants,
        coefficients,
        metadata,
        _build_alias_index(keys(constants)),
        _build_alias_index(keys(coefficients)),
        tuning,
        configuration_names,
        configuration_aliases,
        fast_tensor_metadata,
    )
end

function _try_get_constant(aero_data::AeroData, constant_name::String)
    if haskey(aero_data.constants, constant_name)
        return true, aero_data.constants[constant_name]
    end

    normalized = _normalize_token(constant_name)
    if haskey(aero_data.constant_aliases, normalized)
        actual_name = aero_data.constant_aliases[normalized]
        return true, aero_data.constants[actual_name]
    end

    return false, nothing
end

function _resolve_constant_name(aero_data::AeroData, constant_name::String)
    if haskey(aero_data.constants, constant_name)
        return constant_name
    end

    normalized = _normalize_token(constant_name)
    if haskey(aero_data.constant_aliases, normalized)
        return aero_data.constant_aliases[normalized]
    end

    throw(KeyError(constant_name))
end

function _resolve_coefficient_name(aero_data::AeroData, coeff_name::String)
    resolved = _resolve_coefficient_name_or_nothing(aero_data, coeff_name)
    resolved === nothing && throw(KeyError(coeff_name))
    return resolved
end

function _resolve_coefficient_name_or_nothing(aero_data::AeroData, coeff_name::String)
    if haskey(aero_data.coefficients, coeff_name)
        return coeff_name
    end

    normalized = _normalize_token(coeff_name)
    if haskey(aero_data.coefficient_aliases, normalized)
        return aero_data.coefficient_aliases[normalized]
    end

    return nothing
end

function lookup_configuration_id(aero_data::AeroData, configuration_name)::Int
    normalized = _normalize_token(configuration_name)
    return get(aero_data.configuration_aliases, normalized, 1)
end

function configuration_name_from_id(aero_data::AeroData, configuration_id::Int)::String
    if 1 <= configuration_id <= length(aero_data.configuration_names)
        return aero_data.configuration_names[configuration_id]
    end
    return aero_data.configuration_names[1]
end

function make_fast_lookup_state(
    aero_data::AeroData,
    alpha_deg::Float64,
    beta_deg::Float64,
    mach::Float64,
    configuration_name,
)
    return FastLookupState(
        alpha_deg,
        beta_deg,
        mach,
        lookup_configuration_id(aero_data, configuration_name),
    )
end

function _tuning_scalar(source, key::String, default_value::Float64=1.0)
    source isa AbstractDict || return default_value
    if haskey(source, key)
        value = source[key]
        if value isa Number && isfinite(Float64(value))
            return Float64(value)
        end
    end
    return default_value
end

function _lookup_tuning_value(section, key::String, default_value::Float64)
    section isa AbstractDict || return default_value

    if haskey(section, key)
        value = section[key]
        if value isa Number && isfinite(Float64(value))
            return Float64(value)
        end
    end

    leaf = split(key, ".")[end]
    if haskey(section, leaf)
        value = section[leaf]
        if value isa Number && isfinite(Float64(value))
            return Float64(value)
        end
    end

    normalized_key = _normalize_token(key)
    normalized_leaf = _normalize_token(leaf)
    for (raw_key, raw_value) in section
        raw_value isa Number || continue
        normalized_raw_key = _normalize_token(string(raw_key))
        if normalized_raw_key == normalized_key || normalized_raw_key == normalized_leaf
            return Float64(raw_value)
        end
    end

    return default_value
end

function _lookup_tuning_scale(section, key::String)
    return _lookup_tuning_value(section, key, 1.0)
end

function _lookup_tuning_offset(section, key::String)
    return _lookup_tuning_value(section, key, 0.0)
end

function _coefficient_tuning_family(coeff_name::AbstractString)
    leaf = split(coeff_name, ".")[end]
    for family in ("CL", "CD", "CY", "CS", "Cl", "Cm", "Cn")
        if occursin(family, leaf)
            return family
        end
    end
    return nothing
end

function _coefficient_tuning_groups(coeff_name::String)
    leaf = split(coeff_name, ".")[end]
    groups = String[]

    if startswith(leaf, "wb_")
        push!(groups, "wing_body")
    elseif startswith(leaf, "tail_")
        push!(groups, "tail")
    elseif startswith(leaf, "interference_") || leaf in ("downwash_deg", "sidewash_deg", "eta_h", "eta_v")
        push!(groups, "interference")
    elseif _coefficient_tuning_family(leaf) !== nothing
        push!(groups, "whole_aircraft")
    end

    if occursin("_hat", leaf) || leaf in ("Cl_p", "Cm_q", "Cn_r", "Cn_p", "Cl_r", "tail_CL_q", "tail_CS_r")
        push!(groups, "dynamic")
    end

    if occursin("_per_deg", leaf) || occursin("_delta_", leaf) || leaf in ("Cl_da", "Cm_de", "Cn_dr", "Cn_da")
        push!(groups, "control")
    end

    # Propulsion group — matches the scalar thrust / throttle-dynamics
    # constants that the runtime propulsion model consumes. The model
    # creator exposes a `coefficient_tuning.groups.propulsion` slot so
    # one slider can re-scale all of these at once (see merge.jl's
    # build_coefficient_tuning_block for the matching output key).
    if leaf in ("maximum_thrust_at_sea_level", "thrust_installation_angle_DEG",
                "thrust_installation_angle_deg",
                "engine_spool_up_speed", "engine_spool_down_speed",
                "engine_spool_up_per_s", "engine_spool_down_per_s")
        push!(groups, "propulsion")
    end

    return unique(groups)
end

function _coefficient_tuning_scale(aero_data::AeroData, coeff_name::String)
    isempty(aero_data.tuning) && return 1.0

    scale = _tuning_scalar(aero_data.tuning, "global", 1.0)

    groups_section = get(aero_data.tuning, "groups", Dict{String,Any}())
    for group_name in _coefficient_tuning_groups(coeff_name)
        scale *= _lookup_tuning_scale(groups_section, group_name)
    end

    family_name = _coefficient_tuning_family(coeff_name)
    if family_name !== nothing
        families_section = get(aero_data.tuning, "families", Dict{String,Any}())
        scale *= _lookup_tuning_scale(families_section, family_name)
    end

    coefficients_section = get(aero_data.tuning, "coefficients", Dict{String,Any}())
    scale *= _lookup_tuning_scale(coefficients_section, coeff_name)

    return scale
end

function _is_scaled_constant_name(constant_name::String)
    leaf = split(constant_name, ".")[end]

    return leaf in (
        "CL_alpha", "CL_q_hat", "CL_delta_e",
        "CY_beta", "CY_delta_r",
        "Cl_beta", "Cl_p", "Cl_r", "Cl_delta_a", "Cl_delta_r",
        "Cm_alpha", "Cm_q", "Cm_delta_e", "Cm_alpha_extra",
        "Cn_beta", "Cn_p", "Cn_r", "Cn_delta_a", "Cn_delta_r",
        "Cl_p_hat", "Cm_q_hat", "Cn_r_hat",
        "Cl_da_per_deg", "Cm_de_per_deg", "Cn_dr_per_deg",
        "tail_CL", "tail_CS", "tail_CL_q", "tail_CS_r",
        "scale_tail_forces",
        # Propulsion scalars — enables yaml-driven rescaling of the
        # rule-of-thumb HP→N conversion the model creator produces for
        # propeller aircraft, plus fine-tuning of installation angle
        # and throttle-lag bandwidth.
        "maximum_thrust_at_sea_level", "thrust_installation_angle_DEG",
        "thrust_installation_angle_deg",
        "engine_spool_up_speed", "engine_spool_down_speed",
        "engine_spool_up_per_s", "engine_spool_down_per_s",
    )
end

function _apply_tuned_lookup_value(aero_data::AeroData, coeff_name::String, value)
    value isa Number || return value
    return Float64(value) * _coefficient_tuning_scale(aero_data, coeff_name)
end

function _apply_tuned_constant_value(aero_data::AeroData, constant_name::String, value)
    value isa Number || return value

    scaled_value = Float64(value)
    if _is_scaled_constant_name(constant_name)
        scaled_value *= _coefficient_tuning_scale(aero_data, constant_name)
    end

    offsets_section = get(aero_data.tuning, "constant_offsets", Dict{String,Any}())
    return scaled_value + _lookup_tuning_offset(offsets_section, constant_name)
end

function _clip_value(value::Float64, bounds::ParameterBounds)
    if value < bounds.min_val
        return bounds.min_val
    elseif value > bounds.max_val
        return bounds.max_val
    end
    return value
end

function _find_nearest_values(sorted_values::Vector{Float64}, target::Float64)
    idx = searchsortedfirst(sorted_values, target)

    if idx > length(sorted_values)
        return sorted_values[end], sorted_values[end]
    elseif idx == 1
        return sorted_values[1], sorted_values[1]
    elseif isapprox(sorted_values[idx], target; atol=1e-10)
        return sorted_values[idx], sorted_values[idx]
    else
        return sorted_values[idx-1], sorted_values[idx]
    end
end

function _normalize_parameter_value(kind::Symbol, value, bounds::Union{ParameterBounds,Nothing}=nothing)
    if kind == :numeric
        if !(value isa Number)
            throw(ArgumentError("Expected numeric value for aerodynamic parameter, got '$value'"))
        end
        numeric_value = Float64(value)
        return bounds === nothing ? numeric_value : _clip_value(numeric_value, bounds)
    end
    return string(value)
end

function _resolve_parameter_inputs(metadata::CoefficientMetadata, kwargs...)
    incoming = Dict{String,Any}()
    for (key, value) in kwargs
        canonical_key = _canonicalize_parameter_name(string(key))
        incoming[canonical_key] = value
    end

    resolved = Dict{String,Any}()
    missing = String[]

    for (canonical_key, param_name) in metadata.parameter_lookup
        if !haskey(incoming, canonical_key)
            push!(missing, param_name)
            continue
        end

        kind = metadata.parameter_kinds[param_name]
        bounds = haskey(metadata.bounds, param_name) ? metadata.bounds[param_name] : nothing
        resolved[param_name] = _normalize_parameter_value(kind, incoming[canonical_key], bounds)
    end

    if !isempty(missing)
        throw(ArgumentError("Missing aerodynamic parameters: $(join(missing, ", "))"))
    end

    return resolved
end

function _values_match(kind::Symbol, entry_value, target_value)
    if kind == :numeric
        return entry_value isa Number && isapprox(Float64(entry_value), Float64(target_value); atol=1e-8)
    end
    return _normalize_token(entry_value) == _normalize_token(target_value)
end

function _get_value_at_params_legacy(
    data::Vector,
    params::Vector{String},
    values::Vector,
    coeff_name::String,
    metadata::CoefficientMetadata
)
    current_data = data

    for (param, value) in zip(params, values)
        found = false
        kind = metadata.parameter_kinds[param]
        for entry in current_data
            if !(entry isa AbstractDict)
                continue
            end
            if haskey(entry, param) && _values_match(kind, entry[param], value)
                if haskey(entry, "data")
                    current_data = entry["data"]
                else
                    if haskey(entry, coeff_name)
                        return Float64(entry[coeff_name])
                    end
                end
                found = true
                break
            end
        end
        if !found
            throw(ErrorException("Value not found for parameter $param = $value"))
        end
    end

    if !isempty(current_data) && current_data[1] isa AbstractDict && haskey(current_data[1], coeff_name)
        return Float64(current_data[1][coeff_name])
    end

    throw(ErrorException("Coefficient $coeff_name not found at specified legacy interpolation point"))
end

function _prepare_axis_info_legacy(metadata::CoefficientMetadata, params::Dict{String,Any})
    axis_info = Dict{String,Any}()
    for param in metadata.parameters
        kind = metadata.parameter_kinds[param]
        if kind == :numeric
            target_value = Float64(params[param])
            lower_value, upper_value = _find_nearest_values(metadata.sorted_data[param].values, target_value)
            axis_info[param] = (
                kind=:numeric,
                target=target_value,
                low_value=lower_value,
                high_value=upper_value
            )
        else
            categories = metadata.categorical_values[param]
            target_category = string(params[param])
            matched_category = target_category
            if !any(category -> _normalize_token(category) == _normalize_token(target_category), categories)
                matched_category = categories[1]
            end
            axis_info[param] = (
                kind=:categorical,
                target=matched_category,
                low_value=matched_category,
                high_value=matched_category
            )
        end
    end
    return axis_info
end

@inline function _smoothstep_weight(fraction::Float64)
    # Hermite smoothstep s(t) = 3t² − 2t³, applied to the per-axis fraction
    # inside the multilinear table-lookup weights so the interpolated
    # coefficient is C¹-continuous at every knot.  The α/β grids were thinned
    # to ~10° steps (was ~2°), so plain linear interpolation produces visible
    # slope jumps each time the aircraft state crosses a knot — felt by the
    # pilot as jerky pitch/roll/yaw response.  s(0)=0 and s(1)=1, so the
    # tabulated values at the knots are preserved exactly.
    if fraction <= 0.0
        return 0.0
    elseif fraction >= 1.0
        return 1.0
    end
    return fraction * fraction * (3.0 - 2.0 * fraction)
end

function _interpolate_legacy_coefficient(
    coeff_data::Dict{String,Any},
    metadata::CoefficientMetadata,
    coeff_name::String,
    params::Dict{String,Any},
)
    axis_info = _prepare_axis_info_legacy(metadata, params)
    numeric_params = [param for param in metadata.parameters if metadata.parameter_kinds[param] == :numeric]
    numeric_axis_count = length(numeric_params)

    if numeric_axis_count == 0
        target_values = [axis_info[param].target for param in metadata.parameters]
        return _get_value_at_params_legacy(coeff_data["data"], metadata.parameters, target_values, coeff_name, metadata)
    end

    interpolated_value = 0.0
    total_weight = 0.0
    max_combination = 2^numeric_axis_count - 1

    for combination_bits in 0:max_combination
        current_values = Any[]
        weight = 1.0
        numeric_axis_index = 1
        for param in metadata.parameters
            info = axis_info[param]
            if info.kind == :numeric
                low_value = info.low_value
                high_value = info.high_value
                target_value = info.target
                bit_selected = (combination_bits >> (numeric_axis_index - 1)) & 0x1
                choose_high = bit_selected == 1

                if high_value == low_value
                    push!(current_values, low_value)
                else
                    interpolation_fraction = _smoothstep_weight(
                        (target_value - low_value) / (high_value - low_value)
                    )
                    if choose_high
                        push!(current_values, high_value)
                        weight *= interpolation_fraction
                    else
                        push!(current_values, low_value)
                        weight *= (1.0 - interpolation_fraction)
                    end
                end
                numeric_axis_index += 1
            else
                push!(current_values, info.target)
            end
        end

        if weight <= 0.0
            continue
        end

        try
            local_value = _get_value_at_params_legacy(
                coeff_data["data"],
                metadata.parameters,
                current_values,
                coeff_name,
                metadata
            )
            interpolated_value += weight * local_value
            total_weight += weight
        catch e
            if !(e isa ErrorException)
                rethrow(e)
            end
        end
    end

    if total_weight <= 0.0
        throw(ErrorException("No valid legacy interpolation points found for coefficient '$coeff_name'"))
    end

    return interpolated_value / total_weight
end

function _get_tensor_value(raw_values, indices::Vector{Int}, coeff_name::String)
    current = raw_values
    for index in indices
        if !(current isa Vector)
            throw(ErrorException("Tensor value path is not indexable while reading '$coeff_name'"))
        end
        if index < 1 || index > length(current)
            throw(BoundsError(current, index))
        end
        current = current[index]
    end

    if current isa Number
        return Float64(current)
    elseif current isa AbstractDict
        if haskey(current, coeff_name) && current[coeff_name] isa Number
            return Float64(current[coeff_name])
        end
        throw(ErrorException("Tensor terminal dict does not contain numeric '$coeff_name' value"))
    end

    throw(ErrorException("Tensor terminal value is not numeric for '$coeff_name'"))
end

@inline function _fast_lookup_numeric_target(
    metadata::FastTensorMetadata,
    slot::Int,
    lookup_state::FastLookupState,
)
    if slot == metadata.alpha_axis_slot
        return lookup_state.alpha_deg
    elseif slot == metadata.beta_axis_slot
        return lookup_state.beta_deg
    elseif slot == metadata.mach_axis_slot
        return lookup_state.mach
    end

    throw(ArgumentError("Fast tensor slot $slot does not map to a supported numeric axis"))
end

@inline function _fast_bracket_axis(
    sorted_values::Vector{Float64},
    sorted_source_indices::Vector{Int},
    target::Float64,
)
    idx = searchsortedfirst(sorted_values, target)

    if idx > length(sorted_values)
        source_index = sorted_source_indices[end]
        return source_index, source_index, 0.0
    elseif idx == 1
        source_index = sorted_source_indices[1]
        return source_index, source_index, 0.0
    end

    high_value = sorted_values[idx]
    if abs(high_value - target) <= 1e-10
        source_index = sorted_source_indices[idx]
        return source_index, source_index, 0.0
    end

    low_value = sorted_values[idx - 1]
    fraction = (target - low_value) / (high_value - low_value)
    return sorted_source_indices[idx - 1], sorted_source_indices[idx], fraction
end

@inline function _fast_tensor_terminal_value(current, coeff_name::String)
    if current isa Number
        return Float64(current)
    elseif current isa AbstractDict
        if haskey(current, coeff_name) && current[coeff_name] isa Number
            return Float64(current[coeff_name])
        end
        throw(ErrorException("Tensor terminal dict does not contain numeric '$coeff_name' value"))
    end

    throw(ErrorException("Tensor terminal value is not numeric for '$coeff_name'"))
end

@inline function _fast_tensor_index(current, index::Int, coeff_name::String)
    if !(current isa AbstractVector)
        throw(ErrorException("Tensor value path is not indexable while reading '$coeff_name'"))
    end
    if index < 1 || index > length(current)
        throw(BoundsError(current, index))
    end
    return current[index]
end

function _get_tensor_value_fast(
    raw_values,
    axis_count::Int,
    indices::NTuple{4,Int},
    coeff_name::String,
)
    current = raw_values

    if axis_count >= 1
        current = _fast_tensor_index(current, indices[1], coeff_name)
    end
    if axis_count >= 2
        current = _fast_tensor_index(current, indices[2], coeff_name)
    end
    if axis_count >= 3
        current = _fast_tensor_index(current, indices[3], coeff_name)
    end
    if axis_count >= 4
        current = _fast_tensor_index(current, indices[4], coeff_name)
    end

    return _fast_tensor_terminal_value(current, coeff_name)
end

function _interpolate_tensor_coefficient_fast(
    coeff_data::Dict{String,Any},
    metadata::FastTensorMetadata,
    coeff_name::String,
    lookup_state::FastLookupState,
)
    raw_values = coeff_data["values"]
    axis_count = metadata.axis_count

    low_indices = (1, 1, 1, 1)
    high_indices = (1, 1, 1, 1)
    fractions = (0.0, 0.0, 0.0, 0.0)
    categorical_indices = (1, 1, 1, 1)
    numeric_axis_count = 0

    for slot in 1:axis_count
        kind_code = metadata.kind_codes[slot]
        if kind_code == 0x01
            numeric_axis_count += 1
            target = _fast_lookup_numeric_target(metadata, slot, lookup_state)
            clipped_target = clamp(target, metadata.bound_mins[slot], metadata.bound_maxs[slot])
            low_index, high_index, fraction = _fast_bracket_axis(
                metadata.sorted_values[slot],
                metadata.sorted_source_indices[slot],
                clipped_target,
            )
            low_indices = Base.setindex(low_indices, low_index, slot)
            high_indices = Base.setindex(high_indices, high_index, slot)
            # Store the smoothed weight, not the raw linear fraction, so the
            # downstream corner-weight product is C¹ across knots (see
            # `_smoothstep_weight`).
            fractions = Base.setindex(fractions, _smoothstep_weight(fraction), slot)
        elseif kind_code == 0x02
            selected_index = metadata.config_local_from_global[lookup_state.config_id]
            categorical_indices = Base.setindex(categorical_indices, selected_index, slot)
        end
    end

    interpolated_value = 0.0
    total_weight = 0.0
    max_combination = (1 << numeric_axis_count) - 1

    for combination_bits in 0:max_combination
        indices = (1, 1, 1, 1)
        weight = 1.0
        numeric_axis_index = 0

        for slot in 1:axis_count
            kind_code = metadata.kind_codes[slot]
            if kind_code == 0x01
                numeric_axis_index += 1
                low_index = low_indices[slot]
                high_index = high_indices[slot]
                fraction = fractions[slot]

                if high_index == low_index
                    indices = Base.setindex(indices, low_index, slot)
                else
                    choose_high = ((combination_bits >> (numeric_axis_index - 1)) & 0x1) == 1
                    if choose_high
                        indices = Base.setindex(indices, high_index, slot)
                        weight *= fraction
                    else
                        indices = Base.setindex(indices, low_index, slot)
                        weight *= (1.0 - fraction)
                    end
                end
            else
                indices = Base.setindex(indices, categorical_indices[slot], slot)
            end
        end

        if weight <= 0.0
            continue
        end

        local_value = _get_tensor_value_fast(raw_values, axis_count, indices, coeff_name)
        interpolated_value += weight * local_value
        total_weight += weight
    end

    if total_weight <= 0.0
        throw(ErrorException("No valid tensor interpolation points found for coefficient '$coeff_name'"))
    end

    return interpolated_value / total_weight
end

function _try_make_fast_lookup_state(
    aero_data::AeroData,
    metadata::FastTensorMetadata,
    kwargs,
)
    alpha_deg = 0.0
    beta_deg = 0.0
    mach = 0.0
    config_id = 1

    has_alpha = false
    has_beta = false
    has_mach = false
    has_config = false

    for (key, value) in kwargs
        canonical_key = _canonicalize_parameter_name(string(key))
        if canonical_key == "alpha"
            value isa Number || return nothing
            alpha_deg = Float64(value)
            has_alpha = true
        elseif canonical_key == "beta"
            value isa Number || return nothing
            beta_deg = Float64(value)
            has_beta = true
        elseif canonical_key == "mach"
            value isa Number || return nothing
            mach = Float64(value)
            has_mach = true
        elseif canonical_key == "config"
            config_id = lookup_configuration_id(aero_data, string(value))
            has_config = true
        end
    end

    metadata.alpha_axis_slot == 0 || has_alpha || return nothing
    metadata.beta_axis_slot == 0 || has_beta || return nothing
    metadata.mach_axis_slot == 0 || has_mach || return nothing
    metadata.config_axis_slot == 0 || has_config || return nothing

    return FastLookupState(alpha_deg, beta_deg, mach, config_id)
end

function _fetch_value_from_aero_database_generic(aero_data::AeroData, requested_name::String; kwargs...)
    has_constant, constant_value = _try_get_constant(aero_data, requested_name)
    if has_constant && isempty(kwargs)
        actual_constant_name = _resolve_constant_name(aero_data, requested_name)
        return _apply_tuned_constant_value(aero_data, actual_constant_name, constant_value)
    elseif has_constant && !(constant_value isa Number)
        return constant_value
    elseif has_constant && !has_aero_coefficient(aero_data, requested_name)
        actual_constant_name = _resolve_constant_name(aero_data, requested_name)
        return _apply_tuned_constant_value(aero_data, actual_constant_name, constant_value)
    end

    coeff_name = _resolve_coefficient_name(aero_data, requested_name)
    coeff_data = aero_data.coefficients[coeff_name]
    metadata = aero_data.metadata[coeff_name]

    if isempty(kwargs)
        throw(ArgumentError("No parameters provided for non-constant coefficient '$requested_name'"))
    end

    resolved_params = _resolve_parameter_inputs(metadata, kwargs...)

    if metadata.data_format == :tensor
        value = _interpolate_tensor_coefficient(coeff_data, metadata, coeff_name, resolved_params)
        return _apply_tuned_lookup_value(aero_data, coeff_name, value)
    end
    value = _interpolate_legacy_coefficient(coeff_data, metadata, coeff_name, resolved_params)
    return _apply_tuned_lookup_value(aero_data, coeff_name, value)
end

function _prepare_axis_info_tensor(coeff_data::Dict{String,Any}, metadata::CoefficientMetadata, params::Dict{String,Any})
    axes = Dict{String,Any}(string(k) => v for (k, v) in coeff_data["axes"])
    axis_info = Dict{String,Any}()

    for param in metadata.parameters
        kind = metadata.parameter_kinds[param]
        if kind == :numeric
            target_value = Float64(params[param])
            bounds = metadata.bounds[param]
            clipped_target = _clip_value(target_value, bounds)
            sorted_data = metadata.sorted_data[param]
            lower_value, upper_value = _find_nearest_values(sorted_data.values, clipped_target)
            lower_index = sorted_data.source_indices[lower_value]
            upper_index = sorted_data.source_indices[upper_value]
            axis_info[param] = (
                kind=:numeric,
                target=clipped_target,
                low_value=lower_value,
                high_value=upper_value,
                low_index=lower_index,
                high_index=upper_index
            )
        else
            category_axis = [string(v) for v in axes[param]]
            category_map = Dict(_normalize_token(category) => i for (i, category) in enumerate(category_axis))
            target_category = string(params[param])
            normalized_target = _normalize_token(target_category)
            selected_index = get(category_map, normalized_target, 1)
            axis_info[param] = (
                kind=:categorical,
                target=category_axis[selected_index],
                selected_index=selected_index
            )
        end
    end

    return axis_info
end

function _interpolate_tensor_coefficient(
    coeff_data::Dict{String,Any},
    metadata::CoefficientMetadata,
    coeff_name::String,
    params::Dict{String,Any},
)
    axis_info = _prepare_axis_info_tensor(coeff_data, metadata, params)
    numeric_params = [param for param in metadata.parameters if metadata.parameter_kinds[param] == :numeric]
    numeric_axis_count = length(numeric_params)
    raw_values = coeff_data["values"]

    if numeric_axis_count == 0
        indices = Int[]
        for param in metadata.parameters
            info = axis_info[param]
            if info.kind == :categorical
                push!(indices, info.selected_index)
            else
                push!(indices, info.low_index)
            end
        end
        return _get_tensor_value(raw_values, indices, coeff_name)
    end

    interpolated_value = 0.0
    total_weight = 0.0
    max_combination = 2^numeric_axis_count - 1

    for combination_bits in 0:max_combination
        indices = Int[]
        weight = 1.0
        numeric_axis_index = 1
        for param in metadata.parameters
            info = axis_info[param]
            if info.kind == :numeric
                low_value = info.low_value
                high_value = info.high_value
                target_value = info.target
                bit_selected = (combination_bits >> (numeric_axis_index - 1)) & 0x1
                choose_high = bit_selected == 1
                if high_value == low_value
                    push!(indices, info.low_index)
                else
                    interpolation_fraction = _smoothstep_weight(
                        (target_value - low_value) / (high_value - low_value)
                    )
                    if choose_high
                        push!(indices, info.high_index)
                        weight *= interpolation_fraction
                    else
                        push!(indices, info.low_index)
                        weight *= (1.0 - interpolation_fraction)
                    end
                end
                numeric_axis_index += 1
            else
                push!(indices, info.selected_index)
            end
        end

        if weight <= 0.0
            continue
        end

        local_value = _get_tensor_value(raw_values, indices, coeff_name)
        interpolated_value += weight * local_value
        total_weight += weight
    end

    if total_weight <= 0.0
        throw(ErrorException("No valid tensor interpolation points found for coefficient '$coeff_name'"))
    end

    return interpolated_value / total_weight
end

function fetch_value_from_aero_database(aero_data::AeroData, requested_name::String; kwargs...)
    coeff_name = _resolve_coefficient_name_or_nothing(aero_data, requested_name)
    if coeff_name !== nothing
        fast_metadata = get(aero_data.fast_tensor_metadata, coeff_name, nothing)
        if fast_metadata !== nothing
            lookup_state = _try_make_fast_lookup_state(aero_data, fast_metadata, kwargs)
            if lookup_state !== nothing
                value = _interpolate_tensor_coefficient_fast(
                    aero_data.coefficients[coeff_name],
                    fast_metadata,
                    coeff_name,
                    lookup_state,
                )
                return _apply_tuned_lookup_value(aero_data, coeff_name, value)
            end
        end
    end

    return _fetch_value_from_aero_database_generic(aero_data, requested_name; kwargs...)
end

function fetch_value_from_aero_database(
    aero_data::AeroData,
    requested_name::String,
    lookup_state::FastLookupState,
)
    coeff_name = _resolve_coefficient_name_or_nothing(aero_data, requested_name)
    if coeff_name !== nothing
        fast_metadata = get(aero_data.fast_tensor_metadata, coeff_name, nothing)
        if fast_metadata !== nothing
            value = _interpolate_tensor_coefficient_fast(
                aero_data.coefficients[coeff_name],
                fast_metadata,
                coeff_name,
                lookup_state,
            )
            return _apply_tuned_lookup_value(aero_data, coeff_name, value)
        end
    end

    return _fetch_value_from_aero_database_generic(
        aero_data,
        requested_name;
        alpha_deg=lookup_state.alpha_deg,
        beta_deg=lookup_state.beta_deg,
        mach=lookup_state.mach,
        config=configuration_name_from_id(aero_data, lookup_state.config_id),
    )
end

function has_aero_coefficient(aero_data::AeroData, coeff_name::String)
    return _resolve_coefficient_name_or_nothing(aero_data, coeff_name) !== nothing
end

function fetch_constant_from_aero_database(aero_data::AeroData, constant_name::String, default_value=nothing)
    has_constant, constant_value = _try_get_constant(aero_data, constant_name)
    if has_constant
        actual_constant_name = _resolve_constant_name(aero_data, constant_name)
        return _apply_tuned_constant_value(aero_data, actual_constant_name, constant_value)
    end
    if default_value === nothing
        throw(KeyError(constant_name))
    end
    return _apply_tuned_constant_value(aero_data, constant_name, default_value)
end
