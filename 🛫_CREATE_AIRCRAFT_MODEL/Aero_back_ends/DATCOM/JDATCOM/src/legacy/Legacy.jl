module Legacy

using ..IO: parse_file

const _FLOAT_TOKEN_RE = r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[EeDd][+-]?\d+)?$"

normalize_case_id(s::AbstractString) = replace(strip(uppercase(String(s))), r"\s+" => " ")

function _normalize_space(s::AbstractString)
    return replace(strip(String(s)), r"\s+" => " ")
end

function _parse_float_or_nan(token::AbstractString)
    t = strip(String(token))
    isempty(t) && return NaN
    u = uppercase(t)
    if u == "NDM" || occursin("*", u)
        return NaN
    end
    t = replace(replace(t, 'D' => 'E'), 'd' => 'e')
    try
        return parse(Float64, t)
    catch
        return NaN
    end
end

function _clean_number(v)
    return (v isa Number && isfinite(v)) ? float(v) : nothing
end

function _is_numeric_token(token::AbstractString)
    t = strip(String(token))
    isempty(t) && return false
    return occursin(_FLOAT_TOKEN_RE, replace(replace(t, 'D' => 'E'), 'd' => 'e'))
end

function _regime_from_mach(mach::Real)
    if mach < 0.9
        return "subsonic"
    elseif mach < 1.2
        return "transonic"
    elseif mach < 5.0
        return "supersonic"
    end
    return "hypersonic"
end

function _find_previous(lines::AbstractVector{<:AbstractString}, start_idx::Int, predicate::Function)
    for k in start_idx:-1:1
        if predicate(lines[k])
            return k
        end
    end
    return nothing
end

function _find_case_title(lines::AbstractVector{<:AbstractString}, from_idx::Int, to_idx::Int)
    if from_idx > to_idx
        return ""
    end
    for k in from_idx:to_idx
        s = _normalize_space(lines[k])
        isempty(s) && continue
        u = uppercase(s)
        if startswith(u, "0 ") || startswith(u, "1 ")
            continue
        elseif occursin("AUTOMATED STABILITY", u) || occursin("CHARACTERISTICS AT ANGLE", u)
            continue
        elseif occursin("FLIGHT CONDITIONS", u) || occursin("REFERENCE DIMENSIONS", u)
            continue
        elseif occursin("CONFIGURATION AUXILIARY", u)
            continue
        elseif startswith(u, "RETURN TO MAIN PROGRAM")
            continue
        end
        return s
    end
    return ""
end

function _parse_flight_condition_line(line::AbstractString)
    toks = split(strip(String(line)))
    mach = NaN
    altitude = NaN
    reynolds = NaN

    if length(toks) >= 2
        mach = _parse_float_or_nan(toks[2])
    end
    if length(toks) >= 3
        alt_candidate = _parse_float_or_nan(toks[3])
        if isfinite(alt_candidate) && abs(alt_candidate) <= 2.0e5
            altitude = alt_candidate
        end
    end

    vals = Float64[]
    for tok in toks[3:end]
        v = _parse_float_or_nan(tok)
        if isfinite(v)
            push!(vals, v)
        end
    end
    if !isempty(vals)
        # Reynolds is typically the largest positive quantity in this row.
        reynolds = maximum(vals)
        if reynolds < 1.0e4
            reynolds = NaN
        end
    end

    return _clean_number(mach), _clean_number(altitude), _clean_number(reynolds)
end

function _slice_field(line::AbstractString, start_col::Int, end_col::Int)
    s = String(line)
    n = lastindex(s)
    if start_col > n || end_col < start_col
        return ""
    end
    a = max(start_col, 1)
    b = min(end_col, n)
    return strip(s[a:b])
end

function _parse_primary_coeff_row(line::AbstractString)
    # DATCOM "0 ALPHA CD CL CM ..." table uses fixed-width columns for the
    # leading aerodynamic coefficients. Parsing by whitespace can misalign
    # CM when the CM field is blank (CN shifts left).
    alpha = _parse_float_or_nan(_slice_field(line, 2, 10))
    cd = _parse_float_or_nan(_slice_field(line, 11, 19))
    cl = _parse_float_or_nan(_slice_field(line, 20, 28))
    cm = _parse_float_or_nan(_slice_field(line, 29, 37))
    return alpha, _clean_number(cd), _clean_number(cl), _clean_number(cm)
end

function _parse_derivative_cols(line::AbstractString)
    # In the standard DATCOM "CHARACTERISTICS AT ANGLE OF ATTACK" table,
    # CLA and CMA are the 8th and 9th numeric tokens in a fully populated row.
    toks = split(strip(String(line)))
    length(toks) < 9 && return nothing, nothing
    cla = _parse_float_or_nan(toks[8])
    cma = _parse_float_or_nan(toks[9])
    return _clean_number(cla), _clean_number(cma)
end

function _default_datcom_exe()
    env_exe = get(ENV, "JDATCOM_DATCOM_EXE", "")
    candidates = [
        env_exe,
        abspath(joinpath(@__DIR__, "..", "..", "..", "datcom-legacy", "datcom.exe")),
        abspath(joinpath(@__DIR__, "..", "..", "..", "datcom-legacy", "datcom")),
        abspath(joinpath(pwd(), "datcom-legacy", "datcom.exe")),
        abspath(joinpath(pwd(), "datcom-legacy", "datcom")),
    ]
    for c in candidates
        if !isempty(c) && isfile(c)
            return c
        end
    end
    throw(ArgumentError("Could not locate DATCOM executable. Set JDATCOM_DATCOM_EXE or place it at datcom-legacy/datcom.exe"))
end

function run_legacy_datcom(input_path::AbstractString; datcom_exe = nothing, workdir = nothing)
    input_file = abspath(String(input_path))
    isfile(input_file) || throw(ArgumentError("Input file not found: $input_file"))

    exe = isnothing(datcom_exe) ? _default_datcom_exe() : abspath(String(datcom_exe))
    isfile(exe) || throw(ArgumentError("DATCOM executable not found: $exe"))

    if workdir === nothing
        return mktempdir() do dir
            for005 = joinpath(dir, "for005.dat")
            cp(input_file, for005; force = true)
            cmd = Cmd(`$exe`; dir = dir)
            open(cmd, "w") do io
                write(io, "for005.dat\n")
            end
            out_path = joinpath(dir, "datcom.out")
            isfile(out_path) || throw(ErrorException("DATCOM did not generate datcom.out in $dir"))
            return read(out_path, String)
        end
    else
        dir = abspath(String(workdir))
        mkpath(dir)
        for005 = joinpath(dir, "for005.dat")
        cp(input_file, for005; force = true)
        cmd = Cmd(`$exe`; dir = dir)
        open(cmd, "w") do io
            write(io, "for005.dat\n")
        end
        out_path = joinpath(dir, "datcom.out")
        isfile(out_path) || throw(ErrorException("DATCOM did not generate datcom.out in $dir"))
        return read(out_path, String)
    end
end

function parse_legacy_datcom_output(content::AbstractString)
    text = replace(String(content), "\r\n" => "\n")
    lines = split(text, '\n')
    blocks = Dict{String, Any}[]
    n = length(lines)

    i = 1
    while i <= n
        line = lines[i]
        if occursin(r"^\s*0\s+ALPHA\b", line)
            uline = uppercase(line)
            if occursin("Q/QINF", uline) || occursin("EPSLON", uline)
                i += 1
                continue
            end
            config_idx = _find_previous(lines, i - 1, l -> begin
                u = uppercase(l)
                occursin("CONFIGURATION", u) &&
                endswith(strip(u), "CONFIGURATION") &&
                !occursin("FLIGHT CONDITIONS", u) &&
                !occursin("REFERENCE DIMENSIONS", u) &&
                !occursin("CONFIGURATION AUXILIARY", u)
            end)

            config = config_idx === nothing ? "" : _normalize_space(lines[config_idx])
            title = config_idx === nothing ? "" : _find_case_title(lines, config_idx + 1, i - 1)

            mach_idx = _find_previous(lines, i - 1, l -> begin
                s = strip(l)
                u = uppercase(s)
                startswith(s, "0 ") && !occursin("ALPHA", u) && length(split(s)) >= 2 && _is_numeric_token(split(s)[2])
            end)
            mach, altitude, reynolds = mach_idx === nothing ? (nothing, nothing, nothing) : _parse_flight_condition_line(lines[mach_idx])

            pts = Any[]
            j = i + 1
            while j <= n
                raw = lines[j]
                s = strip(raw)
                if isempty(s)
                    if !isempty(pts)
                        break
                    end
                    j += 1
                    continue
                end

                u = uppercase(s)
                if startswith(u, "0***") || startswith(u, "CASEID") || startswith(u, "RETURN TO MAIN PROGRAM")
                    break
                elseif occursin("AUTOMATED STABILITY", u) || occursin("FLIGHT CONDITIONS", u)
                    break
                elseif occursin("CONFIGURATION AUXILIARY", u) || occursin("INPUT DIMENSIONS", u)
                    break
                elseif occursin("Q/QINF", u) || occursin("EPSLON", u) || occursin("D(EPSLON", u)
                    # Secondary downwash/epsilon tables follow the CL/CD/CM block
                    # and must not be parsed as aerodynamic coefficients.
                    break
                end

                alpha, cd, cl, cm = _parse_primary_coeff_row(raw)
                cla_deg, cma_deg = _parse_derivative_cols(raw)
                if !isfinite(alpha)
                    toks = split(s)
                    if isempty(toks) || !_is_numeric_token(toks[1])
                        if !isempty(pts)
                            break
                        end
                        j += 1
                        continue
                    end
                    alpha = _parse_float_or_nan(toks[1])
                end
                if !isfinite(alpha)
                    if !isempty(pts)
                        break
                    end
                    j += 1
                    continue
                end

                push!(pts, Dict(
                    "alpha" => alpha,
                    "cl" => cl,
                    "cd" => cd,
                    "cm" => cm,
                    "cla_per_deg" => cla_deg,
                    "cma_per_deg" => cma_deg,
                    "regime" => _regime_from_mach(mach isa Number ? mach : 0.0),
                ))
                j += 1
            end

            if !isempty(pts)
                sort!(pts, by = p -> p["alpha"])
                push!(blocks, Dict(
                    "case_id" => title,
                    "case_id_norm" => normalize_case_id(title),
                    "configuration" => config,
                    "mach" => mach,
                    "altitude" => altitude,
                    "reynolds" => reynolds,
                    "points" => pts,
                ))
            end
            i = j
            continue
        end
        i += 1
    end

    return blocks
end

function run_fixture_legacy(input_path::AbstractString; datcom_exe = nothing, workdir = nothing)
    input_file = String(input_path)
    parsed_cases = parse_file(input_file)
    case_ids = [String(get(c, "caseid", "")) for c in parsed_cases]
    norm_ids = normalize_case_id.(case_ids)

    output_text = run_legacy_datcom(input_file; datcom_exe = datcom_exe, workdir = workdir)
    blocks = parse_legacy_datcom_output(output_text)

    out_cases = Any[
        Dict(
            "case_index" => i,
            "case_id" => case_ids[i],
            "has_surfaces" => false,
            "mach_results" => Any[],
        ) for i in 1:length(case_ids)
    ]

    fallback_idx = 1
    for blk in blocks
        blk_id = blk["case_id_norm"]
        ci = findfirst(==(blk_id), norm_ids)
        if ci === nothing
            ci = clamp(fallback_idx, 1, length(out_cases))
            fallback_idx += 1
        end

        config_upper = uppercase(String(get(blk, "configuration", "")))
        has_surfaces = !(occursin("BODY ALONE", config_upper))
        out_cases[ci]["has_surfaces"] = out_cases[ci]["has_surfaces"] || has_surfaces

        push!(out_cases[ci]["mach_results"], Dict(
            "mach" => blk["mach"],
            "altitude" => blk["altitude"],
            "reynolds" => blk["reynolds"],
            "points" => blk["points"],
            "configuration" => blk["configuration"],
            "source" => "legacy_datcom",
        ))
    end

    return Dict(
        "input" => input_file,
        "backend" => "legacy_datcom",
        "num_cases" => length(out_cases),
        "cases" => out_cases,
    )
end

export normalize_case_id
export run_legacy_datcom
export parse_legacy_datcom_output
export run_fixture_legacy

end
