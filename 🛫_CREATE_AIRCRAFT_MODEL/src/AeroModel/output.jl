"""
    output.jl — Custom YAML / JSON output writer for schema v2.1

Produces clean, ordered YAML matching the target aerodynamic model format:
- Deterministic key ordering per section
- Flow arrays `[v1, v2, v3]` for leaf numeric vectors
- Block sequences for nested lookup tables
- Inline dicts `{x: 1.0, y: 2.0}` for small position-like objects
- Mach-index comments inside lookup table values
"""

# ─── Top-level ordered key list ───────────────────────────────────

const MODEL_KEY_ORDER = [
    "schema_version", "model_name", "meta", "conventions",
    "reference", "limits", "configurations", "aerodynamics",
    "per_surface_data", "runtime_model",
    "visual_geometry",
    "propulsion", "actuators", "failures", "quality", "vlm_mesh"
]

const AERO_KEY_ORDER = [
    "interpolation",
    "coefficient_tuning",
    "static_coefficients",          # legacy whole-aircraft overlay (kept for plotting diffs)
    "wing_body",                    # schema v3.0: wing + fuselage contribution
    "tail",                         # schema v3.0: per-tail-surface in local angles @ AC
    "interference",                 # schema v3.0: downwash, sidewash, η_h, η_v
    "dynamic_derivatives",
    "control_effectiveness", "control_drag_increments",
    "local_flow", "poststall"
]

const PROPULSION_KEY_ORDER = [
    "engine_count", "throttle_input_mode", "engines",
    "thrust_map_shared", "aero_propulsion_coupling"
]

# ─── Public API ───────────────────────────────────────────────────

"""
    write_yaml(model::Dict, filepath::String)

Write the aerodynamic model to a clean YAML file with ordered keys.
"""
function write_yaml(model::Dict, filepath::String)
    open(filepath, "w") do io
        write_yaml_model(io, model)
    end
end

"""
    write_json(model::Dict, filepath::String)

Write the aerodynamic model to a JSON file.
"""
function write_json(model::Dict, filepath::String)
    open(filepath, "w") do io
        JSON.print(io, model, 2)
    end
end

"""
    model_to_json_string(model::Dict) -> String

Serialize the model to a JSON string.
"""
function model_to_json_string(model::Dict)
    return JSON.json(model)
end

"""
    model_to_yaml_string(model::Dict) -> String

Serialize the model to a YAML string with clean formatting.
"""
function model_to_yaml_string(model::Dict)
    io = IOBuffer()
    write_yaml_model(io, model)
    return String(take!(io))
end

# ─── Top-level writer ─────────────────────────────────────────────

function write_yaml_model(io::IO, model::Dict)
    for key in MODEL_KEY_ORDER
        haskey(model, key) || continue
        val = model[key]

        if key == "schema_version"
            println(io, "schema_version: ", format_scalar(val))
        elseif key == "model_name"
            println(io, "model_name: ", yaml_quote(val))
        elseif key == "aerodynamics"
            println(io)
            println(io, "aerodynamics:")
            write_aero_section(io, val, 2)
        elseif key == "propulsion"
            println(io)
            println(io, "propulsion:")
            write_propulsion_section(io, val, 2)
        else
            println(io)
            println(io, key, ":")
            write_yaml_value(io, val, 2)
        end
    end
end

# ─── Aerodynamics section (custom key order) ──────────────────────

function write_aero_section(io::IO, aero::Dict, indent::Int)
    pfx = " "^indent
    for key in AERO_KEY_ORDER
        haskey(aero, key) || continue
        val = aero[key]
        println(io, pfx, key, ":")
        if key in ("static_coefficients", "dynamic_derivatives",
            "control_effectiveness", "control_drag_increments",
            "wing_body")
            write_lookup_section(io, val, indent + 2, key)
        elseif key == "tail"
            write_tail_section(io, val, indent + 2)
        elseif key == "interference"
            write_interference_section(io, val, indent + 2)
        else
            write_yaml_value(io, val, indent + 2)
        end
    end
end

# ─── Tail section writer (schema v3.0) ─────────────────────────────
function write_tail_section(io::IO, tail::Dict, indent::Int)
    pfx = " "^indent
    if haskey(tail, "axis_order_per_surface")
        println(io, pfx, "axis_order_per_surface: ", format_flow_array(tail["axis_order_per_surface"]))
    end
    if haskey(tail, "axes")
        println(io, pfx, "axes:")
        ax = tail["axes"]
        for akey in ("config", "mach", "alpha_h_deg", "beta_v_deg")
            haskey(ax, akey) || continue
            println(io, pfx, "  ", akey, ": ", format_flow_array(ax[akey]))
        end
    end

    surfaces = get(tail, "surfaces", [])
    println(io, pfx, "surfaces:")
    pfx2 = " "^(indent + 2)

    machs  = haskey(tail, "axes") ? get(tail["axes"], "mach", Float64[]) : Float64[]
    alphas = haskey(tail, "axes") ? get(tail["axes"], "alpha_h_deg", Float64[]) : Float64[]
    betas  = haskey(tail, "axes") ? get(tail["axes"], "beta_v_deg",  Float64[]) : Float64[]
    col_comment = isempty(betas) ? "" : ", beta_v_deg: $(format_flow_array(betas))"

    for surf in surfaces
        println(io, pfx2, "- name: ", yaml_quote(get(surf, "name", "tail")))
        println(io, pfx2, "  role: ", yaml_quote(get(surf, "role", "")))
        println(io, pfx2, "  component: ", yaml_quote(get(surf, "component", "")))
        if haskey(surf, "arm_m")
            println(io, pfx2, "  arm_m: ", format_flow_array(surf["arm_m"]))
        end
        if haskey(surf, "ac_xyz_m")
            println(io, pfx2, "  ac_xyz_m: ", format_flow_array(surf["ac_xyz_m"]))
        end
        for cname in ("CL", "CD", "CY", "Cl_at_AC", "Cm_at_AC", "Cn_at_AC")
            haskey(surf, cname) || continue
            println(io, pfx2, "  ", cname, ":")
            cval = surf[cname]
            if cval isa Dict && haskey(cval, "values")
                println(io, pfx2, "    values:")
                write_lookup_values(io, cval["values"], indent + 6, machs, alphas, col_comment)
            else
                write_yaml_value(io, cval, indent + 4)
            end
        end
    end
end

# ─── Interference section writer (schema v3.0) ─────────────────────
function write_interference_section(io::IO, ifb::Dict, indent::Int)
    pfx = " "^indent

    if haskey(ifb, "source")
        println(io, pfx, "source: ", yaml_quote(ifb["source"]))
    end
    for key in ("axis_order_alpha", "axis_order_beta")
        haskey(ifb, key) || continue
        println(io, pfx, key, ": ", format_flow_array(ifb[key]))
    end
    if haskey(ifb, "axes")
        println(io, pfx, "axes:")
        ax = ifb["axes"]
        for akey in ("config", "mach", "alpha_deg", "beta_deg")
            haskey(ax, akey) || continue
            println(io, pfx, "  ", akey, ": ", format_flow_array(ax[akey]))
        end
    end
    println(io)

    machs  = haskey(ifb, "axes") ? get(ifb["axes"], "mach",       Float64[]) : Float64[]
    alphas = haskey(ifb, "axes") ? get(ifb["axes"], "alpha_deg",  Float64[]) : Float64[]
    betas  = haskey(ifb, "axes") ? get(ifb["axes"], "beta_deg",   Float64[]) : Float64[]

    # α-indexed: downwash_deg, eta_h
    for key in ("downwash_deg", "eta_h")
        haskey(ifb, key) || continue
        println(io, pfx, key, ":")
        dval = ifb[key]
        if dval isa Dict && haskey(dval, "values")
            println(io, pfx, "  values:")
            write_lookup_values(io, dval["values"], indent + 4, machs, alphas, "")
        end
    end

    # β-indexed: sidewash_deg, eta_v — reuse write_lookup_values with β as row axis
    for key in ("sidewash_deg", "eta_v")
        haskey(ifb, key) || continue
        println(io, pfx, key, ":")
        dval = ifb[key]
        if dval isa Dict && haskey(dval, "values")
            println(io, pfx, "  values:")
            write_lookup_values(io, dval["values"], indent + 4, machs, betas, "")
        end
    end
end

function write_propulsion_section(io::IO, prop::Dict, indent::Int)
    pfx = " "^indent
    for key in PROPULSION_KEY_ORDER
        haskey(prop, key) || continue
        val = prop[key]
        if is_scalar(val)
            println(io, pfx, key, ": ", format_scalar(val))
        elseif key == "engines"
            println(io, pfx, "engines:")
            write_engine_list(io, val, indent + 2)
        elseif key == "thrust_map_shared"
            println(io, pfx, "thrust_map_shared:")
            write_thrust_map(io, val, indent + 2)
        elseif key == "aero_propulsion_coupling"
            println(io, pfx, "aero_propulsion_coupling:")
            write_yaml_value(io, val, indent + 2)
        else
            println(io, pfx, key, ":")
            write_yaml_value(io, val, indent + 2)
        end
    end
end

# ─── Lookup table section writer (static_coefficients etc.) ───────

function write_lookup_section(io::IO, section::Dict, indent::Int, ::String)
    pfx = " "^indent

    # axis_order first, then axes, then data keys
    if haskey(section, "axis_order")
        println(io, pfx, "axis_order: ", format_flow_array(section["axis_order"]))
    end
    if haskey(section, "axes")
        println(io, pfx, "axes:")
        axes = section["axes"]
        for akey in ["config", "mach", "alpha_deg", "beta_deg", "abs_deflection_deg", "ct_total"]
            haskey(axes, akey) || continue
            println(io, pfx, "  ", akey, ": ", format_flow_array(axes[akey]))
        end
    end
    println(io)

    # Get axis values for comments
    machs = haskey(section, "axes") ? get(section["axes"], "mach", Float64[]) : Float64[]
    alphas = haskey(section, "axes") ? get(section["axes"], "alpha_deg", Float64[]) : Float64[]

    # Build column-axis comment suffix (e.g. ", beta_deg: [-15, -10, ...]")
    col_comment = ""
    if haskey(section, "axis_order")
        ao = section["axis_order"]
        if length(ao) >= 4
            col_name = ao[4]
            if haskey(section, "axes") && haskey(section["axes"], col_name)
                col_comment = ", $(col_name): $(format_flow_array(section["axes"][col_name]))"
            end
        end
    end

    # Write coefficient/derivative data keys (sorted)
    meta_keys = Set(["axis_order", "axes"])
    data_keys = sort(collect(filter(k -> !(k in meta_keys), keys(section))))
    for dkey in data_keys
        dval = section[dkey]
        println(io, pfx, dkey, ":")
        if dval isa Dict && haskey(dval, "values")
            println(io, pfx, "  values:")
            write_lookup_values(io, dval["values"], indent + 4, machs, alphas, col_comment)
        elseif dval isa Dict
            write_yaml_value(io, dval, indent + 2)
        else
            write_yaml_value(io, dval, indent + 2)
        end
    end
end

"""
Write the `values:` block of a lookup table.
Structure: values[config_name][mach_idx][alpha_idx][beta_idx_or_scalar]
"""
function write_lookup_values(io::IO, values, indent::Int, machs::Vector, alphas::Vector=Float64[], col_comment::String="")
    pfx = " "^indent

    if values isa Dict
        for cfg in sort(collect(keys(values)))
            cfg_data = values[cfg]
            println(io, pfx, cfg, ":")
            if cfg_data isa Vector
                write_mach_indexed_array(io, cfg_data, indent + 2, machs, alphas, col_comment)
            else
                # Scalar per config (e.g., poststall)
                println(io, pfx, "  ", format_scalar(cfg_data))
            end
        end
    elseif values isa Vector
        write_mach_indexed_array(io, values, indent, machs, alphas, col_comment)
    end
end

"""
Write an array where the first dimension is indexed by Mach number.
"""
function write_mach_indexed_array(io::IO, arr::Vector, indent::Int, machs::Vector, alphas::Vector=Float64[], col_comment::String="")
    pfx = " "^indent

    for (mi, mach_data) in enumerate(arr)
        # Add Mach comment (with optional column-axis suffix)
        if !isempty(machs) && mi <= length(machs)
            println(io, pfx, "- # Mach ", format_num(machs[mi]), col_comment)
        else
            print(io, pfx, "- ")
        end

        if mach_data isa Vector && !isempty(mach_data) && first(mach_data) isa Vector
            # Array of arrays: alpha rows containing beta/deflection columns
            for (ai, alpha_row) in enumerate(mach_data)
                comment = !isempty(alphas) && ai <= length(alphas) ? "  # alpha = $(format_num(alphas[ai]))" : ""
                println(io, pfx, "  - ", format_flow_array(alpha_row), comment)
            end
        elseif mach_data isa Vector
            # 1D array: alpha values only (dynamic_derivatives, control_effectiveness)
            if !isempty(machs) && mi <= length(machs)
                # Already on "- # Mach" line, print the array as flow
                # But the comment took the line, so print indented
                println(io, pfx, "  ", format_flow_array(mach_data))
            else
                println(format_flow_array(mach_data))
            end
        else
            println(io, pfx, "  ", format_scalar(mach_data))
        end
    end
end

# ─── Engine list writer ───────────────────────────────────────────

function write_engine_list(io::IO, engines::Vector, indent::Int)
    pfx = " "^indent
    for eng in engines
        println(io, pfx, "- id: ", yaml_quote(get(eng, "id", "ENG")))
        if haskey(eng, "position_m")
            println(io, pfx, "  position_m: ", format_inline_dict(eng["position_m"]))
        end
        if haskey(eng, "orientation_deg")
            println(io, pfx, "  orientation_deg: ", format_inline_dict(eng["orientation_deg"]))
        end
        for k in ["thrust_scale", "spool_up_1_s", "spool_down_1_s"]
            haskey(eng, k) || continue
            println(io, pfx, "  ", k, ": ", format_num(eng[k]))
        end
    end
end

# ─── Thrust map writer ────────────────────────────────────────────

function write_thrust_map(io::IO, tmap::Dict, indent::Int)
    pfx = " "^indent

    if haskey(tmap, "axis_order")
        println(io, pfx, "axis_order: ", format_flow_array(tmap["axis_order"]))
    end
    if haskey(tmap, "axes")
        println(io, pfx, "axes:")
        axes = tmap["axes"]
        for akey in ["mach", "altitude_m", "throttle"]
            haskey(axes, akey) || continue
            println(io, pfx, "  ", akey, ": ", format_flow_array(axes[akey]))
        end
    end
    println(io)

    machs = haskey(tmap, "axes") ? get(tmap["axes"], "mach", Float64[]) : Float64[]

    if haskey(tmap, "values")
        println(io, pfx, "# values[mach_index][altitude_index][throttle_index]")
        println(io, pfx, "values:")
        write_mach_indexed_array(io, tmap["values"], indent + 2, machs)
    end
end

# ─── Generic YAML value writer ────────────────────────────────────

function write_yaml_value(io::IO, value, indent::Int)
    pfx = " "^indent

    if value isa Dict
        ordered_keys = sort_dict_keys(value)
        for k in ordered_keys
            v = value[k]
            if is_scalar(v)
                println(io, pfx, k, ": ", format_scalar(v))
            elseif v isa Vector && is_leaf_array(v)
                println(io, pfx, k, ": ", format_flow_array(v))
            elseif v isa Dict && is_inline_dict(v)
                println(io, pfx, k, ": ", format_inline_dict(v))
            elseif v isa Vector && all(x -> x isa Dict, v)
                println(io, pfx, k, ":")
                write_dict_array(io, v, indent + 2)
            elseif v isa Vector
                println(io, pfx, k, ":")
                write_block_array(io, v, indent + 2)
            else
                println(io, pfx, k, ":")
                write_yaml_value(io, v, indent + 2)
            end
        end
    elseif value isa Vector
        write_block_array(io, value, indent)
    else
        println(io, pfx, format_scalar(value))
    end
end

function write_block_array(io::IO, arr::Vector, indent::Int)
    pfx = " "^indent
    for item in arr
        if is_scalar(item)
            println(io, pfx, "- ", format_scalar(item))
        elseif item isa Vector && is_leaf_array(item)
            println(io, pfx, "- ", format_flow_array(item))
        elseif item isa Vector
            println(io, pfx, "-")
            write_block_array(io, item, indent + 2)
        elseif item isa Dict
            write_dict_array_item(io, item, indent)
        end
    end
end

function write_dict_array_item(io::IO, item::Dict, indent::Int)
    pfx = " "^indent
    ordered_keys = sort_dict_keys(item)
    isempty(ordered_keys) && return

    first_key = ordered_keys[1]
    first_val = item[first_key]
    if is_scalar(first_val)
        println(io, pfx, "- ", first_key, ": ", format_scalar(first_val))
    elseif first_val isa Dict && is_inline_dict(first_val)
        println(io, pfx, "- ", first_key, ": ", format_inline_dict(first_val))
    elseif first_val isa Vector && is_leaf_array(first_val)
        println(io, pfx, "- ", first_key, ": ", format_flow_array(first_val))
    else
        println(io, pfx, "- ", first_key, ":")
        write_yaml_value(io, first_val, indent + 4)
    end

    for k in ordered_keys[2:end]
        v = item[k]
        if is_scalar(v)
            println(io, pfx, "  ", k, ": ", format_scalar(v))
        elseif v isa Vector && is_leaf_array(v)
            println(io, pfx, "  ", k, ": ", format_flow_array(v))
        elseif v isa Dict && is_inline_dict(v)
            println(io, pfx, "  ", k, ": ", format_inline_dict(v))
        else
            println(io, pfx, "  ", k, ":")
            write_yaml_value(io, v, indent + 4)
        end
    end
end

function write_dict_array(io::IO, arr::Vector, indent::Int)
    for item in arr
        item isa Dict || continue
        write_dict_array_item(io, item, indent)
    end
end

# ─── Formatting helpers ───────────────────────────────────────────

function is_scalar(v)
    return v isa Number || v isa AbstractString || v isa Bool || isnothing(v)
end

function is_leaf_array(arr::Vector)
    return all(x -> is_scalar(x), arr)
end

function is_inline_dict(d::Dict)
    return length(d) <= 4 && all(v -> is_scalar(v), values(d))
end

function format_scalar(v)
    if v isa Bool
        return v ? "true" : "false"
    elseif v isa AbstractString
        return needs_quoting(v) ? yaml_quote(v) : v
    elseif v isa AbstractFloat
        return format_num(v)
    elseif v isa Integer
        return string(v)
    elseif isnothing(v)
        return "null"
    end
    return string(v)
end

function format_num(v::Number)
    if v isa Integer
        return string(v)
    end
    if v == 0.0
        return "0.0"
    end
    # Use fixed-point for "nice" numbers
    if v == round(v) && abs(v) < 1e8
        return @sprintf("%.1f", v)
    end
    # Format with appropriate precision, trim trailing zeros
    if abs(v) >= 0.0001
        s = @sprintf("%.6f", v)
        # Trim trailing zeros but keep at least one decimal
        s = replace(s, r"0+$" => "")
        s = replace(s, r"\.$" => ".0")
        return s
    else
        return @sprintf("%.6e", v)
    end
end

function yaml_quote(s::AbstractString)
    return "\"" * replace(s, "\"" => "\\\"") * "\""
end

function needs_quoting(s::AbstractString)
    isempty(s) && return true
    s in ("true", "false", "null", "yes", "no", "on", "off") && return true
    occursin(r"[:\{\}\[\],&\*\?\|>'\"%@`#]", s) && return true
    (startswith(s, " ") || endswith(s, " ")) && return true
    tryparse(Float64, s) !== nothing && return true
    return false
end

function format_flow_array(arr::Vector)
    parts = String[]
    for v in arr
        if v isa AbstractString
            push!(parts, needs_quoting(v) ? yaml_quote(v) : v)
        elseif v isa AbstractFloat
            push!(parts, format_num(v))
        elseif v isa Integer
            push!(parts, string(v))
        elseif v isa Bool
            push!(parts, v ? "true" : "false")
        else
            push!(parts, string(v))
        end
    end
    return "[" * join(parts, ", ") * "]"
end

function format_inline_dict(d::Dict)
    parts = String[]
    for k in sort(collect(keys(d)))
        v = d[k]
        push!(parts, string(k, ": ", format_scalar(v)))
    end
    return "{" * join(parts, ", ") * "}"
end

# ─── Key ordering ─────────────────────────────────────────────────

function sort_dict_keys(d::Dict)
    ks = collect(keys(d))

    # Known patterns — check for characteristic keys
    if any(k -> k == "aircraft_id", ks)
        return sort_by_order(ks, ["aircraft_id", "created_utc", "author", "notes"])
    elseif any(k -> k == "angles", ks)
        return sort_by_order(ks, ["angles", "rates", "forces", "moments", "coeff_axes",
            "body_axes", "coefficient_order", "nondim_rates"])
    elseif any(k -> k == "mass_kg", ks) && any(k -> k == "geometry", ks)
        return sort_by_order(ks, ["mass_kg", "geometry", "cg_ref_m", "inertia"])
    elseif any(k -> k == "S_ref_m2", ks)
        return sort_by_order(ks, ["S_ref_m2", "b_ref_m", "c_ref_m"])
    elseif any(k -> k == "principal_moments_kgm2", ks)
        return sort_by_order(ks, ["principal_moments_kgm2", "principal_axes_rotation_deg"])
    elseif any(k -> k == "Ixx_p", ks)
        return sort_by_order(ks, ["Ixx_p", "Iyy_p", "Izz_p"])
    elseif any(k -> k == "p_hat", ks)
        return sort_by_order(ks, ["p_hat", "q_hat", "r_hat"])
    elseif any(k -> k == "controls_deg", ks)
        return sort_by_order(ks, ["mach", "alpha_deg", "beta_deg", "controls_deg"])
    elseif any(k -> k == "id", ks) && any(k -> k == "flap_deg", ks)
        return sort_by_order(ks, ["id", "flap_deg", "gear"])
    elseif any(k -> k == "method", ks)
        return sort_by_order(ks, ["method", "out_of_range"])
    elseif any(k -> k == "alpha_on_deg", ks)
        return sort_by_order(ks, ["alpha_on_deg", "alpha_off_deg", "model",
            "sideforce_scale", "drag_floor", "drag_90deg"])
    elseif any(k -> k == "surface_rate_limit_deg_s", ks)
        return sort_by_order(ks, ["surface_rate_limit_deg_s", "position_limit_deg"])
    elseif any(k -> k == "allow_engine_out", ks)
        return sort_by_order(ks, ["allow_engine_out", "default_failed_engines", "failure_ramp_time_s"])
    elseif any(k -> k == "missing_term_policy", ks)
        return sort_by_order(ks, ["missing_term_policy", "provenance", "confidence"])
    elseif any(k -> k == "linear_core", ks)
        return sort_by_order(ks, ["linear_core", "nonlinear_surfaces", "nonlinear",
            "propulsion", "poststall"])
    end
    return sort(ks)
end

function sort_by_order(keys_list, order)
    ordered = String[]
    for k in order
        if string(k) in [string(x) for x in keys_list]
            push!(ordered, string(k))
        end
    end
    for k in sort([string(x) for x in keys_list])
        if !(k in ordered)
            push!(ordered, k)
        end
    end
    return ordered
end
