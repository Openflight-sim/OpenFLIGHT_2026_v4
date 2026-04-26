# ──────────────────────────────────────────────────────────────
# mass.jl — Mass distribution file reader (matching amass.f)
# ──────────────────────────────────────────────────────────────

"""
Mass properties loaded from a .mass file.
"""
struct MassProperties
    mass::Float64
    xcg::Float64; ycg::Float64; zcg::Float64
    ixx::Float64; iyy::Float64; izz::Float64
    ixy::Float64; ixz::Float64; iyz::Float64
    gravity::Float64
    density::Float64
    unitl::Float64; unitm::Float64; unitt::Float64
end

"""
    read_mass(filename) → MassProperties

Parse an AVL mass distribution file (.mass).
"""
function read_mass(filename::AbstractString)
    lines = readlines(filename)

    unitl = 1.0; unitm = 1.0; unitt = 1.0
    gee = 9.81; rho = 1.225

    # scale/offset factors (up to 10 columns)
    fac = ones(10)
    add = zeros(10)

    # accumulators
    sum_m = 0.0
    sum_mx = 0.0; sum_my = 0.0; sum_mz = 0.0
    sum_ixx = 0.0; sum_iyy = 0.0; sum_izz = 0.0
    sum_ixy = 0.0; sum_ixz = 0.0; sum_iyz = 0.0
    sum_mxx = 0.0; sum_myy = 0.0; sum_mzz = 0.0
    sum_mxy = 0.0; sum_mxz = 0.0; sum_myz = 0.0

    for raw_line in lines
        line = strip(raw_line)
        isempty(line) && continue
        startswith(line, '#') && continue
        startswith(line, '!') && continue

        # check for header parameters
        llow = lowercase(line)
        if occursin("lunit", llow)
            m = match(r"lunit\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", llow)
            m !== nothing && (unitl = parse(Float64, m.captures[1]))
            continue
        elseif occursin("munit", llow)
            m = match(r"munit\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", llow)
            m !== nothing && (unitm = parse(Float64, m.captures[1]))
            continue
        elseif occursin("tunit", llow)
            m = match(r"tunit\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", llow)
            m !== nothing && (unitt = parse(Float64, m.captures[1]))
            continue
        elseif startswith(llow, "g") && occursin("=", llow)
            m = match(r"g\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", llow)
            m !== nothing && (gee = parse(Float64, m.captures[1]))
            continue
        elseif startswith(llow, "rho") && occursin("=", llow)
            m = match(r"rho\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", llow)
            m !== nothing && (rho = parse(Float64, m.captures[1]))
            continue
        end

        # check for multiplier/adder lines
        if startswith(line, '*')
            tokens = split(line[2:end])
            for (k, tok) in enumerate(tokens)
                k > 10 && break
                val = tryparse(Float64, tok)
                val !== nothing && (fac[k] = val)
            end
            continue
        elseif startswith(line, '+')
            tokens = split(line[2:end])
            for (k, tok) in enumerate(tokens)
                k > 10 && break
                val = tryparse(Float64, tok)
                val !== nothing && (add[k] = val)
            end
            continue
        end

        # data line: mass, x, y, z, Ixx, Iyy, Izz, [Ixy, Ixz, Iyz]
        tokens = split(line)
        vals = Float64[]
        for tok in tokens
            v = tryparse(Float64, tok)
            v === nothing && break
            push!(vals, v)
        end
        length(vals) < 4 && continue

        while length(vals) < 10
            push!(vals, 0.0)
        end

        # apply fac and add
        for k in 1:10
            vals[k] = fac[k]*vals[k] + add[k]
        end

        mi  = vals[1]
        xi  = vals[2]; yi = vals[3]; zi = vals[4]
        ixxi = vals[5]; iyyi = vals[6]; izzi = vals[7]
        ixyi = vals[8]; ixzi = vals[9]; iyzi = vals[10]

        sum_m   += mi
        sum_mx  += mi*xi;  sum_my += mi*yi;  sum_mz += mi*zi
        sum_mxx += mi*xi^2; sum_myy += mi*yi^2; sum_mzz += mi*zi^2
        sum_mxy += mi*xi*yi; sum_mxz += mi*xi*zi; sum_myz += mi*yi*zi
        sum_ixx += ixxi; sum_iyy += iyyi; sum_izz += izzi
        sum_ixy += ixyi; sum_ixz += ixzi; sum_iyz += iyzi
    end

    # CG
    xcg = sum_m > 0 ? sum_mx/sum_m : 0.0
    ycg = sum_m > 0 ? sum_my/sum_m : 0.0
    zcg = sum_m > 0 ? sum_mz/sum_m : 0.0

    # inertia about CG via parallel axis theorem
    ixx = sum_ixx + (sum_myy + sum_mzz) - sum_m*(ycg^2 + zcg^2)
    iyy = sum_iyy + (sum_mxx + sum_mzz) - sum_m*(xcg^2 + zcg^2)
    izz = sum_izz + (sum_mxx + sum_myy) - sum_m*(xcg^2 + ycg^2)
    ixy = sum_ixy + sum_mxy - sum_m*xcg*ycg
    ixz = sum_ixz + sum_mxz - sum_m*xcg*zcg
    iyz = sum_iyz + sum_myz - sum_m*ycg*zcg

    # apply unit conversions
    mass_si = sum_m * unitm
    xcg_l = xcg * unitl; ycg_l = ycg * unitl; zcg_l = zcg * unitl
    ul2 = unitm * unitl^2
    ixx *= ul2; iyy *= ul2; izz *= ul2
    ixy *= ul2; ixz *= ul2; iyz *= ul2

    return MassProperties(mass_si, xcg, ycg, zcg,
                          ixx, iyy, izz, ixy, ixz, iyz,
                          gee, rho, unitl, unitm, unitt)
end
