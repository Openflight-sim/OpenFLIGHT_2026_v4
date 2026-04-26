module NamelistParserModule

using Logging

mutable struct NamelistParser
    cases::Vector{Dict{String, Any}}
    current_case::Dict{String, Any}
end

function NamelistParser()
    return NamelistParser(
        Dict{String, Any}[],
        Dict{String, Any}(
            "namelists" => Dict{String, Any}(),
            "commands" => String[],
            "caseid" => "",
        ),
    )
end

const KNOWN_NAMELISTS = Set([
    "FLTCON", "OPTINS", "SYNTHS", "BODY", "WGPLNF", "WGSCHR",
    "HTPLNF", "HTSCHR", "VTPLNF", "VTSCHR", "VFPLNF", "VFSCHR",
    "SYMFLP", "ASYFLP", "DEFLCT", "GROUND", "TRIM", "DAMP",
    "PART", "DERIV", "DUMP", "BUILD", "PWRINP", "JET",
    "HYPER", "PROPWR", "JETPWR", "NACON", "CONTAB", "EXPDATA",
    "EXPR01", "EXPR02", "TVTPAN",
])

const PREFIX_MAP = Dict(
    "FLTCON" => "flight",
    "OPTINS" => "options",
    "SYNTHS" => "synths",
    "BODY" => "body",
    "WGPLNF" => "wing",
    "WGSCHR" => "wing",
    "HTPLNF" => "htail",
    "HTSCHR" => "htail",
    "VTPLNF" => "vtail",
    "VTSCHR" => "vtail",
    "VFPLNF" => "vfin",
    "VFSCHR" => "vfin",
)

function parse_file(parser::NamelistParser, filepath::AbstractString)
    content = read(filepath, String)
    return parse(parser, content)
end

function parse(parser::NamelistParser, content::String)
    parser.cases = Dict{String, Any}[]
    saved_namelists = Dict{String, Any}()
    parser.current_case = Dict{String, Any}(
        "namelists" => deepcopy(saved_namelists),
        "commands" => String[],
        "caseid" => "",
    )

    lines = split(content, '\n')
    i = 1
    while i <= length(lines)
        line = strip(lines[i])
        upper_line = uppercase(line)

        if isempty(line) || startswith(line, "!")
            i += 1
            continue
        end

        if startswith(upper_line, "CASEID")
            parser.current_case["caseid"] = strip(line[7:end])
            i += 1
            continue
        end

        if upper_line == "SAVE"
            push!(parser.current_case["commands"], "SAVE")
            i += 1
            continue
        end

        if startswith(upper_line, "NEXT")
            if !_case_empty(parser.current_case)
                push!(parser.cases, parser.current_case)
            end
            if "SAVE" in parser.current_case["commands"]
                saved_namelists = deepcopy(parser.current_case["namelists"])
            end
            parser.current_case = Dict{String, Any}(
                "namelists" => deepcopy(saved_namelists),
                "commands" => String[],
                "caseid" => "",
            )
            i += 1
            continue
        end

        if startswith(upper_line, "DUMP")
            dump_what = strip(length(line) > 4 ? line[5:end] : "")
            cmd = isempty(dump_what) ? "DUMP" : "DUMP $dump_what"
            push!(parser.current_case["commands"], cmd)
            i += 1
            continue
        end

        if upper_line == "BUILD"
            push!(parser.current_case["commands"], "BUILD")
            i += 1
            continue
        end

        if startswith(upper_line, "DIM")
            push!(parser.current_case["commands"], upper_line)
            i += 1
            continue
        end

        if startswith(line, "C") && !startswith(upper_line, "CASEID")
            i += 1
            continue
        end

        if startswith(line, '$')
            namelist_content, next_idx = _extract_namelist(lines, i)
            if !isempty(namelist_content)
                name, params = _parse_namelist(namelist_content)
                if !isnothing(name)
                    _merge_namelist!(parser.current_case["namelists"], name, params)
                end
            end
            i = next_idx
            continue
        end

        i += 1
    end

    if !_case_empty(parser.current_case)
        push!(parser.cases, parser.current_case)
    end

    return parser.cases
end

function _case_empty(case::Dict{String, Any})
    return isempty(case["namelists"]) && isempty(case["commands"]) && isempty(strip(case["caseid"]))
end

function _extract_namelist(lines::Vector{SubString{String}}, start_idx::Int)
    namelist_lines = String[]
    i = start_idx
    line = strip(lines[i])
    push!(namelist_lines, line)

    if count(==('$'), line) >= 2
        return join(namelist_lines, " "), i + 1
    end

    i += 1
    while i <= length(lines)
        line = strip(lines[i])
        if isempty(line) || startswith(line, "!")
            i += 1
            continue
        end
        push!(namelist_lines, line)
        if occursin('$', line)
            return join(namelist_lines, " "), i + 1
        end
        i += 1
    end
    return join(namelist_lines, " "), i
end

function _parse_namelist(content::String)
    m = match(r"^\$(\w+)\s+(.*?)\$"s, content)
    if m === nothing
        @warn "Could not parse namelist: $(first(content, min(80, lastindex(content))))"
        return nothing, Dict{String, Any}()
    end

    name = uppercase(String(m.captures[1]))
    params = _parse_parameters(String(m.captures[2]))
    return name, params
end

function _parse_parameters(param_str::AbstractString)
    params = Dict{String, Any}()
    compact = strip(replace(param_str, r"\s+" => " "))
    assignments = _split_assignments(compact)

    last_array_name = nothing
    last_array_idx = nothing
    last_scalar_name = nothing

    for assignment in assignments
        assignment = strip(assignment)
        isempty(assignment) && continue

        if occursin('=', assignment)
            parts = split(assignment, '=', limit = 2)
            param_name = uppercase(strip(parts[1]))
            value_str = strip(parts[2])
            value = _parse_value(param_name, value_str)

            if occursin('(', param_name)
                pparts = split(param_name, '(', limit = 2)
                array_name = strip(pparts[1])
                index_str = replace(strip(pparts[2]), ")" => "")
                start_idx = try
                    Int(Base.parse(Float64, index_str))
                catch
                    1
                end
                start_idx = max(start_idx, 1)

                if !haskey(params, array_name) || !(params[array_name] isa Vector)
                    params[array_name] = Any[]
                end
                arr = params[array_name]

                if value isa Vector
                    for (j, v) in enumerate(value)
                        idx = start_idx + j - 1
                        while length(arr) < idx
                            push!(arr, nothing)
                        end
                        arr[idx] = v
                    end
                    last_array_idx = start_idx + length(value)
                else
                    idx = start_idx
                    while length(arr) < idx
                        push!(arr, nothing)
                    end
                    arr[idx] = value
                    last_array_idx = idx + 1
                end
                params[array_name] = arr
                last_array_name = array_name
                last_scalar_name = nothing
            else
                params[param_name] = value
                last_array_name = nothing
                last_array_idx = nothing
                last_scalar_name = param_name
            end
        else
            if !isnothing(last_array_name) && !isnothing(last_array_idx)
                cont_values = _parse_value("", assignment)
                arr = params[last_array_name]

                if cont_values isa Vector
                    for v in cont_values
                        idx = last_array_idx
                        while length(arr) < idx
                            push!(arr, nothing)
                        end
                        arr[idx] = v
                        last_array_idx = idx + 1
                    end
                else
                    idx = last_array_idx
                    while length(arr) < idx
                        push!(arr, nothing)
                    end
                    arr[idx] = cont_values
                    last_array_idx = idx + 1
                end
                params[last_array_name] = arr
            elseif !isnothing(last_scalar_name)
                cont_values = _parse_value("", assignment)
                existing = get(params, last_scalar_name, nothing)
                vals = existing isa Vector ? Any[existing...] : Any[existing]

                if cont_values isa Vector
                    append!(vals, cont_values)
                else
                    push!(vals, cont_values)
                end

                params[last_scalar_name] = vals
            end
        end
    end

    return params
end

function _split_assignments(param_str::AbstractString)
    assignments = String[]
    current = IOBuffer()
    depth = 0
    for c in param_str
        if c == '('
            depth += 1
            print(current, c)
        elseif c == ')'
            depth -= 1
            print(current, c)
        elseif c == ',' && depth == 0
            token = strip(String(take!(current)))
            !isempty(token) && push!(assignments, token)
        else
            print(current, c)
        end
    end
    tail = strip(String(take!(current)))
    !isempty(tail) && push!(assignments, tail)
    return assignments
end

function _parse_value(param_name::AbstractString, value_str::AbstractString)
    v = strip(value_str)
    if occursin(',', v)
        vals = Any[]
        for part in split(v, ',')
            token = strip(part)
            isempty(token) && continue
            push!(vals, _parse_single_value(token))
        end
        return vals
    end
    return _parse_single_value(v)
end

function _parse_single_value(value_str::AbstractString)
    v = strip(value_str)
    upper = uppercase(v)

    if upper == ".TRUE." || upper == "TRUE"
        return true
    elseif upper == ".FALSE." || upper == "FALSE"
        return false
    end

    try
        return Base.parse(Int, v)
    catch
    end

    normalized = replace(replace(v, 'D' => 'E'), 'd' => 'e')
    try
        return Base.parse(Float64, normalized)
    catch
    end

    if (startswith(v, "'") && endswith(v, "'")) || (startswith(v, "\"") && endswith(v, "\""))
        return v[2:(end - 1)]
    end

    return v
end

function _merge_namelist!(all_namelists::Dict{String, Any}, name::String, params::Dict{String, Any})
    if !haskey(all_namelists, name)
        all_namelists[name] = params
        return
    end

    existing = all_namelists[name]
    for (k, v) in params
        if haskey(existing, k) && (existing[k] isa Vector) && (v isa Vector)
            old = existing[k]
            max_len = max(length(old), length(v))
            while length(old) < max_len
                push!(old, nothing)
            end
            for (idx, vv) in enumerate(v)
                if vv !== nothing
                    old[idx] = vv
                end
            end
            existing[k] = old
        else
            existing[k] = v
        end
    end
    all_namelists[name] = existing
end

function to_state_dict(parser::NamelistParser, case::Dict{String, Any})
    state = Dict{String, Any}()
    namelists = case["namelists"]
    for (namelist_name, params) in namelists
        prefix = get(PREFIX_MAP, namelist_name, lowercase(namelist_name))
        for (param_name, value) in params
            key = string(prefix, "_", lowercase(param_name))
            state[key] = _coerce_value(value)
        end
    end

    state["case_id"] = get(case, "caseid", "")
    state["case_save"] = "SAVE" in get(case, "commands", String[])
    return state
end

function parse_file(filepath::AbstractString)
    parser = NamelistParser()
    return parse_file(parser, filepath)
end

function parse(content::String)
    parser = NamelistParser()
    return parse(parser, content)
end

function to_state_dict(case::Dict{String, Any})
    parser = NamelistParser()
    return to_state_dict(parser, case)
end

function _coerce_value(value)
    if value isa AbstractVector
        out = Any[]
        for v in value
            push!(out, _coerce_value(v))
        end
        return out
    elseif value isa AbstractString
        v = strip(value)
        upper = uppercase(v)
        if upper == ".TRUE." || upper == "TRUE"
            return true
        elseif upper == ".FALSE." || upper == "FALSE"
            return false
        end
        try
            return Base.parse(Int, v)
        catch
        end
        normalized = replace(replace(v, 'D' => 'E'), 'd' => 'e')
        try
            return Base.parse(Float64, normalized)
        catch
            return value
        end
    else
        return value
    end
end

export NamelistParser
export KNOWN_NAMELISTS
export parse_file
export parse
export to_state_dict

end
