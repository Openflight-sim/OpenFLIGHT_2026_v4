# ──────────────────────────────────────────────────────────────
# input.jl — AVL configuration file parser (matching ainput.f)
# ──────────────────────────────────────────────────────────────

"""Tolerant integer parse: accepts \"1.0\" as 1."""
parse_int_tolerant(s::AbstractString) = floor(Int, parse(Float64, s))

"""
    read_avl(filename) → AVLConfig

Parse an AVL geometry input file (.avl).
"""
function read_avl(filename::AbstractString)
    config = AVLConfig()
    config.basedir = dirname(abspath(filename))

    lines = readlines(filename)
    idx = 1
    nlines = length(lines)

    # skip comment/blank lines helper
    function nextdata()
        while idx <= nlines
            line = lines[idx]
            # strip inline comments (! or # anywhere in line)
            for ch in ('!', '#')
                pos = findfirst(ch, line)
                if pos !== nothing
                    line = line[1:prevind(line, pos)]
                end
            end
            line = strip(line)
            if isempty(line)
                idx += 1
                continue
            end
            return line
        end
        return nothing
    end

    # 1. Title
    line = nextdata()
    line === nothing && error("Unexpected end of file reading title")
    config.title = line
    idx += 1

    # 2. Mach
    line = nextdata()
    line === nothing && error("Unexpected end of file reading Mach")
    config.mach = parse(Float64, split(line)[1])
    idx += 1

    # 3. Symmetry: iYsym iZsym Zsym
    line = nextdata()
    line === nothing && error("Unexpected end of file reading symmetry")
    tokens = split(line)
    config.iysym = parse_int_tolerant(tokens[1])
    config.izsym = length(tokens) >= 2 ? parse_int_tolerant(tokens[2]) : 0
    config.zsym  = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 0.0
    idx += 1

    # 4. Reference: Sref Cref Bref
    line = nextdata()
    line === nothing && error("Unexpected end of file reading reference")
    tokens = split(line)
    config.sref = parse(Float64, tokens[1])
    config.cref = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 1.0
    config.bref = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 1.0
    idx += 1

    # 5. Moment reference: Xref Yref Zref
    line = nextdata()
    line === nothing && error("Unexpected end of file reading reference point")
    tokens = split(line)
    xr = parse(Float64, tokens[1])
    yr = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 0.0
    zr = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 0.0
    config.xyzref = (xr, yr, zr)
    idx += 1

    # 6. Optional CDp
    line = nextdata()
    if line !== nothing
        key4 = uppercase(line[1:min(4,length(line))])
        if !startswith(key4, "SURF") && !startswith(key4, "BODY")
            # could be CDp
            tokens = split(line)
            val = tryparse(Float64, tokens[1])
            if val !== nothing
                config.cdref = val
                idx += 1
            end
        end
    end

    # ── Keyword loop ────────────────────────────────────────
    current_surf = nothing
    current_body = nothing
    current_sect = nothing

    while idx <= nlines
        line = nextdata()
        line === nothing && break

        key4 = uppercase(strip(line))[1:min(4, length(strip(line)))]

        if startswith(key4, "SURF")
            # finalize previous surface
            if current_sect !== nothing && current_surf !== nothing
                push!(current_surf.sections, current_sect)
                current_sect = nothing
            end
            if current_surf !== nothing
                push!(config.surfaces, current_surf)
            end
            if current_body !== nothing
                push!(config.bodies, current_body)
                current_body = nothing
            end

            idx += 1
            # surface name
            line = nextdata()
            line === nothing && break
            sname = strip(line)
            idx += 1

            current_surf = SurfaceDef(sname)
            current_sect = nothing

            # paneling line: Nchord Cspace [Nspan Sspace]
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            current_surf.nchord = parse_int_tolerant(tokens[1])
            current_surf.cspace = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 1.0
            current_surf.nspan = length(tokens) >= 3 ? parse_int_tolerant(tokens[3]) : 0
            current_surf.sspace = length(tokens) >= 4 ? parse(Float64, tokens[4]) : 1.0
            idx += 1

        elseif startswith(key4, "BODY")
            if current_sect !== nothing && current_surf !== nothing
                push!(current_surf.sections, current_sect)
                current_sect = nothing
            end
            if current_surf !== nothing
                push!(config.surfaces, current_surf)
                current_surf = nothing
            end
            if current_body !== nothing
                push!(config.bodies, current_body)
            end

            idx += 1
            line = nextdata()
            line === nothing && break
            bname = strip(line)
            idx += 1

            current_body = BodyDef(bname)

            line = nextdata()
            line === nothing && break
            tokens = split(line)
            current_body.nbody = parse_int_tolerant(tokens[1])
            current_body.bspace = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 1.0
            idx += 1

        elseif startswith(key4, "SECT")
            if current_sect !== nothing && current_surf !== nothing
                push!(current_surf.sections, current_sect)
            end
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)

            sect = SectionDef()
            sect.xle = parse(Float64, tokens[1])
            sect.yle = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 0.0
            sect.zle = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 0.0
            sect.chord = length(tokens) >= 4 ? parse(Float64, tokens[4]) : 1.0
            sect.ainc = length(tokens) >= 5 ? parse(Float64, tokens[5]) : 0.0
            sect.nspan = length(tokens) >= 6 ? parse_int_tolerant(tokens[6]) : 0
            sect.sspace = length(tokens) >= 7 ? parse(Float64, tokens[7]) : 0.0
            idx += 1
            current_sect = sect

        elseif startswith(key4, "NACA")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            naca_num = parse_int_tolerant(tokens[1])
            x1 = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 0.0
            x2 = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 1.0
            idx += 1

            if current_sect !== nothing
                if naca_num < 10000
                    xc, camber, thick = naca4_camber(naca_num)
                else
                    xc, camber, thick = naca5_camber(naca_num)
                end
                # store pre-computed slopes at uniform points (matching Fortran ainput.f)
                xf, slopes = camber_to_slopes(xc, camber; npts=length(xc))
                current_sect.xaf = xf
                current_sect.yaf = slopes
                current_sect.taf = thick
                current_sect.naf = length(xc)
            end

        elseif startswith(key4, "AIRF") || startswith(key4, "AFIL")
            is_file = startswith(key4, "AFIL")
            idx += 1
            line = nextdata()
            line === nothing && break

            if is_file
                # read airfoil from file — handle quoted names and optional x-range
                parts = split(line)
                afname = strip(parts[1], ['"', '\''])
                # resolve relative path
                if !isabspath(afname)
                    afname = joinpath(config.basedir, afname)
                end
                idx += 1
                if isfile(afname)
                    xb, yb = read_airfoil(afname)
                    if length(xb) >= 3 && current_sect !== nothing
                        xc, yc, tc, nc = getcam(xb, yb)
                        # store pre-computed slopes at uniform points (matching Fortran ainput.f)
                        xf, slopes = camber_to_slopes(xc, yc; npts=nc)
                        current_sect.xaf = xf
                        current_sect.yaf = slopes
                        current_sect.taf = tc
                        current_sect.naf = nc
                    end
                else
                    @warn "Airfoil file not found: $afname"
                end
            else
                # inline airfoil coordinates
                xb = Float64[]
                yb = Float64[]
                while idx <= nlines
                    line = nextdata()
                    line === nothing && break
                    tokens = split(line)
                    if length(tokens) >= 2
                        xval = tryparse(Float64, tokens[1])
                        yval = tryparse(Float64, tokens[2])
                        if xval !== nothing && yval !== nothing
                            push!(xb, xval)
                            push!(yb, yval)
                            idx += 1
                        else
                            break
                        end
                    else
                        break
                    end
                end
                if length(xb) >= 3 && current_sect !== nothing
                    xc, yc, tc, nc = getcam(xb, yb)
                    # store pre-computed slopes at uniform points (matching Fortran ainput.f)
                    xf, slopes = camber_to_slopes(xc, yc; npts=nc)
                    current_sect.xaf = xf
                    current_sect.yaf = slopes
                    current_sect.taf = tc
                    current_sect.naf = nc
                end
            end

        elseif startswith(key4, "CONT")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            cname = tokens[1]
            gain = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 1.0
            xhinge = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 0.75
            hx = length(tokens) >= 4 ? parse(Float64, tokens[4]) : 0.0
            hy = length(tokens) >= 5 ? parse(Float64, tokens[5]) : 0.0
            hz = length(tokens) >= 6 ? parse(Float64, tokens[6]) : 0.0
            sgndup = length(tokens) >= 7 ? parse(Float64, tokens[7]) : 1.0
            idx += 1

            if current_sect !== nothing
                push!(current_sect.controls,
                      ControlDef(cname, gain, xhinge, (hx, hy, hz), sgndup))
            end

        elseif startswith(key4, "DESI")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            dname = tokens[1]
            dgain = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 1.0
            idx += 1

            if current_sect !== nothing
                push!(current_sect.design_names, dname)
                push!(current_sect.design_gains, dgain)
            end

        elseif startswith(key4, "CLAF")
            idx += 1
            line = nextdata()
            line === nothing && break
            val = parse(Float64, split(line)[1])
            idx += 1
            if current_sect !== nothing
                current_sect.claf = val
            end

        elseif startswith(key4, "CDCL")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            cdcl_data = [parse(Float64, t) for t in tokens[1:min(6, length(tokens))]]
            while length(cdcl_data) < 6
                push!(cdcl_data, 0.0)
            end
            idx += 1

            if current_sect !== nothing
                current_sect.cdcl = cdcl_data
                current_sect.has_cdcl = true
            elseif current_surf !== nothing
                current_surf.cdcl = cdcl_data
                current_surf.has_cdcl = true
            end

        elseif startswith(key4, "YDUP")
            idx += 1
            line = nextdata()
            line === nothing && break
            ydup = parse(Float64, split(line)[1])
            idx += 1

            if current_surf !== nothing
                current_surf.yduplicate = ydup
                current_surf.has_ydup = true
            elseif current_body !== nothing
                current_body.yduplicate = ydup
                current_body.has_ydup = true
            end

        elseif startswith(key4, "SCAL")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            sx = parse(Float64, tokens[1])
            sy = length(tokens) >= 2 ? parse(Float64, tokens[2]) : sx
            sz = length(tokens) >= 3 ? parse(Float64, tokens[3]) : sx
            idx += 1

            if current_surf !== nothing
                current_surf.scale = (sx, sy, sz)
            elseif current_body !== nothing
                current_body.scale = (sx, sy, sz)
            end

        elseif startswith(key4, "TRAN")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            dx = parse(Float64, tokens[1])
            dy = length(tokens) >= 2 ? parse(Float64, tokens[2]) : 0.0
            dz = length(tokens) >= 3 ? parse(Float64, tokens[3]) : 0.0
            idx += 1

            if current_surf !== nothing
                current_surf.translate = (dx, dy, dz)
            elseif current_body !== nothing
                current_body.translate = (dx, dy, dz)
            end

        elseif startswith(key4, "ANGL") || startswith(key4, "AINC")
            idx += 1
            line = nextdata()
            line === nothing && break
            val = parse(Float64, split(line)[1])
            idx += 1
            if current_surf !== nothing
                current_surf.angle_offset = val
            end

        elseif startswith(key4, "NOWA")
            idx += 1
            if current_surf !== nothing
                current_surf.nowake = true
            end

        elseif startswith(key4, "NOAL")
            idx += 1
            if current_surf !== nothing
                current_surf.noalbe = true
            end

        elseif startswith(key4, "NOLO")
            idx += 1
            if current_surf !== nothing
                current_surf.noload = true
            end

        elseif startswith(key4, "COMP") || startswith(key4, "INDE")
            idx += 1
            line = nextdata()
            line === nothing && break
            val = parse_int_tolerant(split(line)[1])
            idx += 1
            if current_surf !== nothing
                current_surf.component = val
            end

        elseif startswith(key4, "CORE")
            idx += 1
            line = nextdata()
            line === nothing && break
            tokens = split(line)
            if current_surf !== nothing
                current_surf.vrcorec = parse(Float64, tokens[1])
                current_surf.vrcorew = length(tokens) >= 2 ? parse(Float64, tokens[2]) : current_surf.vrcorew
            end
            idx += 1

        elseif startswith(key4, "BFIL") || startswith(key4, "BSEC")
            is_file = startswith(key4, "BFIL")
            idx += 1
            if is_file && current_body !== nothing
                line = nextdata()
                line === nothing && break
                bfparts = split(line)
                bfname = strip(bfparts[1], ['"', '\''])
                if !isabspath(bfname)
                    bfname = joinpath(config.basedir, bfname)
                end
                idx += 1
                if isfile(bfname)
                    xb, yb = read_airfoil(bfname)
                    if length(xb) >= 3
                        # Use body-specific getcam (LNORM=.FALSE., no rotation)
                        # Returns absolute x-positions, raw centerline y, full thickness
                        xc, yc, tc, nc = getcam_body(xb, yb)
                        current_body.xb = xc                  # absolute x-positions
                        current_body.yb = yc                  # centerline y offsets
                        current_body.rb = tc ./ 2.0           # radius = half-thickness
                        current_body.zb = zeros(nc)
                    end
                end
            else
                idx += 1
            end

        else
            idx += 1
        end
    end

    # finalize last surface/body
    if current_sect !== nothing && current_surf !== nothing
        push!(current_surf.sections, current_sect)
    end
    if current_surf !== nothing
        push!(config.surfaces, current_surf)
    end
    if current_body !== nothing
        push!(config.bodies, current_body)
    end

    # assign default component indices
    comp_idx = 0
    for surf in config.surfaces
        if surf.component == 0
            comp_idx += 1
            surf.component = comp_idx
        end
    end

    return config
end

"""
    read_runfile(filename, ncontrol) → Vector{RunCase}

Parse an AVL run case file (.run).
"""
function read_runfile(filename::AbstractString, ncontrol::Int=0)
    cases = RunCase[]
    isfile(filename) || return cases

    lines = readlines(filename)
    idx = 1
    nlines = length(lines)

    # variable name lookup
    var_names = Dict(
        "alpha" => IVALFA, "beta" => IVBETA,
        "pb/2v" => IVROTX, "qc/2v" => IVROTY, "rb/2v" => IVROTZ
    )
    con_names = Dict(
        "alpha" => ICALFA, "beta" => ICBETA,
        "pb/2v" => ICROTX, "qc/2v" => ICROTY, "rb/2v" => ICROTZ,
        "cl" => ICCL, "cy" => ICCY,
        "cl roll" => ICMOMX, "cm pitch" => ICMOMY, "cn yaw" => ICMOMZ
    )

    while idx <= nlines
        line = strip(lines[idx])
        # look for "Run case" header
        if occursin(r"[Rr]un\s+[Cc]ase"i, line)
            rc = RunCase(ncontrol)

            # parse run case number and name
            m = match(r"(\d+)\s*:\s*(.*)", line)
            if m !== nothing
                rc.number = parse(Int, m.captures[1])
                rc.name = strip(m.captures[2])
            end
            idx += 1

            # read constraint block until blank line or parameter block
            while idx <= nlines
                line = strip(lines[idx])
                if isempty(line)
                    idx += 1
                    continue
                end
                # check for parameter block marker
                if occursin("->", line)
                    # parse: variable -> constraint = value
                    parts = split(line, "->")
                    if length(parts) == 2
                        varpart = strip(lowercase(parts[1]))
                        conpart = strip(parts[2])
                        # extract constraint name and value
                        m2 = match(r"(.+?)\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", conpart)
                        if m2 !== nothing
                            conname = strip(lowercase(m2.captures[1]))
                            conval = parse(Float64, m2.captures[2])
                            # map to indices
                            # (simplified; will match common patterns)
                        end
                    end
                    idx += 1
                elseif occursin("=", line) && !occursin("->", line)
                    # parameter line: name = value
                    m3 = match(r"(\w[\w/\s]*?)\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)", line)
                    if m3 !== nothing
                        pname = strip(lowercase(m3.captures[1]))
                        pval = parse(Float64, m3.captures[2])
                        # map parameter name to index
                        if startswith(pname, "alpha")
                            rc.parval[IPALFA] = pval * π/180
                        elseif startswith(pname, "beta")
                            rc.parval[IPBETA] = pval * π/180
                        elseif pname == "pb/2v"
                            rc.parval[IPROTX] = pval
                        elseif pname == "qc/2v"
                            rc.parval[IPROTY] = pval
                        elseif pname == "rb/2v"
                            rc.parval[IPROTZ] = pval
                        elseif startswith(pname, "cl")
                            rc.parval[IPCL] = pval
                        elseif startswith(pname, "cd")
                            rc.parval[IPCD0] = pval
                        elseif startswith(pname, "bank")
                            rc.parval[IPPHI] = pval * π/180
                        elseif startswith(pname, "mach")
                            rc.parval[IPMACH] = pval
                        elseif startswith(pname, "veloc")
                            rc.parval[IPVEL] = pval
                        elseif startswith(pname, "dens")
                            rc.parval[IPRHO] = pval
                        elseif startswith(pname, "grav")
                            rc.parval[IPGEE] = pval
                        elseif startswith(pname, "x_cg")
                            rc.parval[IPXCG] = pval
                        elseif startswith(pname, "y_cg")
                            rc.parval[IPYCG] = pval
                        elseif startswith(pname, "z_cg")
                            rc.parval[IPZCG] = pval
                        elseif startswith(pname, "mass")
                            rc.parval[IPMASS] = pval
                        elseif startswith(pname, "ixx")
                            rc.parval[IPIXX] = pval
                        elseif startswith(pname, "iyy")
                            rc.parval[IPIYY] = pval
                        elseif startswith(pname, "izz")
                            rc.parval[IPIZZ] = pval
                        end
                    end
                    idx += 1
                elseif occursin(r"[Rr]un\s+[Cc]ase"i, line)
                    break  # next run case
                else
                    idx += 1
                end
            end

            push!(cases, rc)
        else
            idx += 1
        end
    end

    return cases
end
