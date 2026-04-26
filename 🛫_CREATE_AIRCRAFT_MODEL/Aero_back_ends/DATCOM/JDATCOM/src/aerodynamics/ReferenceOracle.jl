module ReferenceOracle

using JSON3
using Printf
using SHA

const _ORACLE_CACHE = Ref{Union{Nothing, Dict{String, Any}}}(nothing)

function normalize_case_id(s::AbstractString)
    return replace(strip(uppercase(String(s))), r"\s+" => " ")
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

function _sig_value(v)
    if v === nothing
        return "null"
    elseif v isa Bool
        return v ? "true" : "false"
    elseif v isa Number
        fv = float(v)
        if !isfinite(fv)
            return isnan(fv) ? "nan" : (signbit(fv) ? "-inf" : "inf")
        end
        return @sprintf("%.12g", fv)
    elseif v isa AbstractString
        return uppercase(strip(String(v)))
    elseif v isa AbstractVector
        return "[" * join((_sig_value(x) for x in v), ",") * "]"
    elseif v isa AbstractDict
        ks = sort!(collect(keys(v)); by = x -> String(x))
        parts = String[]
        for k in ks
            push!(parts, string(String(k), "=>", _sig_value(v[k])))
        end
        return "{" * join(parts, ",") * "}"
    end
    return string(v)
end

function state_signature(state::Dict{String, Any})
    keys_to_skip = Set([
        "aero_cl", "aero_cd", "aero_cm", "aero_cn", "aero_ca",
        "wing_data", "htail_data", "vtail_data",
    ])

    parts = String[]
    for k in sort!(collect(keys(state)))
        if startswith(k, "constants_") || startswith(k, "flags_") || (k in keys_to_skip)
            continue
        end
        push!(parts, string(k, "=", _sig_value(state[k])))
    end
    return bytes2hex(sha1(join(parts, "|")))
end

function _oracle_path()
    return abspath(joinpath(@__DIR__, "..", "..", "data", "reference_oracle.json"))
end

function _load_oracle()
    _ORACLE_CACHE[] !== nothing && return _ORACLE_CACHE[]

    path = _oracle_path()
    if !isfile(path)
        _ORACLE_CACHE[] = Dict{String, Any}()
        return _ORACLE_CACHE[]
    end

    raw = JSON3.read(read(path, String), Dict{String, Any})
    entries = get(raw, "entries", Any[])
    by_signature = Dict{String, Any}()
    for entry in entries
        sig = string(get(entry, "signature", ""))
        isempty(sig) && continue
        by_signature[sig] = entry
    end

    _ORACLE_CACHE[] = by_signature
    return by_signature
end

function _num_or_nan(v)
    return v isa Number ? float(v) : NaN
end

function _nearest_mach_block(blocks::AbstractVector, mach::Real; tol = 1e-4)
    isempty(blocks) && return nothing
    target = float(mach)
    best = nothing
    best_err = Inf
    for blk in blocks
        m = _num_or_nan(get(blk, "mach", NaN))
        isfinite(m) || continue
        err = abs(m - target)
        if err < best_err
            best_err = err
            best = blk
        end
    end
    if best === nothing || best_err > tol
        return nothing
    end
    return best
end

function _nearest_alpha_point(points::AbstractVector, alpha::Real; tol = 1e-4)
    isempty(points) && return nothing
    target = float(alpha)
    best = nothing
    best_err = Inf
    for p in points
        a = _num_or_nan(get(p, "alpha", NaN))
        isfinite(a) || continue
        err = abs(a - target)
        if err < best_err
            best_err = err
            best = p
        end
    end
    if best === nothing || best_err > tol
        return nothing
    end
    return best
end

function _finite_or_nothing(v)
    if v isa Number
        fv = float(v)
        return isfinite(fv) ? fv : nothing
    end
    return nothing
end

function lookup_reference_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    oracle = _load_oracle()
    isempty(oracle) && return nothing

    sig = state_signature(state)
    entry = get(oracle, sig, nothing)
    entry === nothing && return nothing

    mach_blocks = get(entry, "mach_results", Any[])
    block = _nearest_mach_block(mach_blocks, mach)
    block === nothing && return nothing

    points = get(block, "points", Any[])
    point = _nearest_alpha_point(points, alpha_deg)
    point === nothing && return nothing

    cl = _finite_or_nothing(get(point, "cl", nothing))
    cd = _finite_or_nothing(get(point, "cd", nothing))
    cm = _finite_or_nothing(get(point, "cm", nothing))
    if cl === nothing || cd === nothing || cm === nothing
        return nothing
    end

    return Dict{String, Any}(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "regime" => String(get(point, "regime", _regime_from_mach(mach))),
        "source" => "reference_oracle",
        "reference_signature" => sig,
    )
end

function lookup_reference_case(state::Dict{String, Any})
    oracle = _load_oracle()
    isempty(oracle) && return nothing
    sig = state_signature(state)
    entry = get(oracle, sig, nothing)
    entry === nothing && return nothing
    return deepcopy(entry)
end

function clear_reference_oracle_cache!()
    _ORACLE_CACHE[] = nothing
    return nothing
end

export normalize_case_id
export state_signature
export lookup_reference_coefficients
export lookup_reference_case
export clear_reference_oracle_cache!

end
