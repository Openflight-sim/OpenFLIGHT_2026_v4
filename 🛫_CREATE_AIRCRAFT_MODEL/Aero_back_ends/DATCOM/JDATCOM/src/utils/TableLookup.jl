module TableLookup

function _interp1(x::Real, xp::AbstractVector, fp::AbstractVector)
    n = min(length(xp), length(fp))
    n == 0 && return 0.0
    n == 1 && return fp[1]
    if x <= xp[1]
        return fp[1]
    elseif x >= xp[n]
        return fp[n]
    end
    i = clamp(searchsortedlast(xp, x), 1, n - 1)
    x1 = xp[i]
    x2 = xp[i + 1]
    y1 = fp[i]
    y2 = fp[i + 1]
    x2 == x1 && return y1
    t = (x - x1) / (x2 - x1)
    return y1 + t * (y2 - y1)
end

function fig26(reynolds::Real, mach::Real)
    a_coef = [
        4.12963e-6, 3.92725e-6, 4.55853e-6, 4.49735e-6, 4.11442e-6,
        4.51587e-6, 4.61971e-6, 4.53836e-6, 3.86772e-6,
    ]
    b_coef = [
        -1.36204e-4, -1.3037e-4, -1.48715e-4, -1.47407e-4, -1.36505e-4,
        -1.47222e-4, -1.48773e-4, -1.44676e-4, -1.23287e-4,
    ]
    c_coef = [
        1.7162e-3, 1.65388e-3, 1.85005e-3, 1.83955e-3, 1.72383e-3,
        1.8252e-3, 1.81973e-3, 1.74944e-3, 1.49335e-3,
    ]
    d_coef = [
        -9.88935e-3, -9.59519e-3, -1.0503e-2, -1.04587e-2, -9.91294e-3,
        -1.02911e-2, -1.01084e-2, -9.59421e-3, -8.22227e-3,
    ]
    e_coef = [
        2.23641e-2, 2.18366e-2, 2.33437e-2, 2.32398e-2, 2.22626e-2,
        2.2622e-2, 2.18584e-2, 2.04571e-2, 1.76472e-2,
    ]
    mach_points = [0.0, 0.3, 0.7, 0.9, 1.0, 1.5, 2.0, 2.5, 3.0]

    x = log10(max(reynolds, 1.0))
    eval_poly(idx) = x * (
        e_coef[idx] + x * (d_coef[idx] + x * (c_coef[idx] + x * (b_coef[idx] + x * a_coef[idx])))
    )

    m_idx = 8
    for m in 1:8
        if mach >= mach_points[m] && mach < mach_points[m + 1]
            m_idx = m
            break
        end
    end

    if m_idx < 8 && abs(mach - mach_points[m_idx]) > 0.02
        cf_m = eval_poly(m_idx)
        cf_n = eval_poly(m_idx + 1)
        frac = (mach - mach_points[m_idx]) / (mach_points[m_idx + 1] - mach_points[m_idx])
        return cf_m + frac * (cf_n - cf_m)
    end
    return eval_poly(m_idx)
end

function fig53a(rv::Real, z::Real)
    a_coef = [8.98425e-3, 4.50351e-3, 6.0128e-3, 1.07637e-2, 8.48758e-3]
    b_coef = [-0.138262, -0.064239, -0.08858, -0.167056, -0.130342]
    c_coef = [0.718213, 0.263365, 0.410583, 0.893775, 0.67405]
    d_coef = [-1.49813, -0.478074, -0.771195, -1.79298, -1.35093]
    e_coef = [1.00929, 0.162566, 0.423931, 1.27184, 0.96068]
    z_points = [0.0, 0.25, 0.50, 0.75, 1.0]

    x = log10(max(rv, 1.0))
    eval_poly(idx) = x * (
        e_coef[idx] + x * (d_coef[idx] + x * (c_coef[idx] + x * (b_coef[idx] + x * a_coef[idx])))
    )

    z_idx = 5
    for i in 1:4
        if z >= z_points[i] && z < z_points[i + 1]
            z_idx = i
            break
        end
    end

    if z_idx < 5
        r1 = eval_poly(z_idx)
        r2 = eval_poly(z_idx + 1)
        frac = (z - z_points[z_idx]) / (z_points[z_idx + 1] - z_points[z_idx])
        return r1 + frac * (r2 - r1)
    end
    return eval_poly(z_idx)
end

function fig60b(beta::Real)
    beta_data = [
        0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0,
        2.2, 2.4, 2.6, 2.8, 3.0, 3.2, 3.4, 3.6, 3.8, 4.0,
    ]
    btana_data = [
        0.0, 0.0, 0.0, 0.011, 0.045, 0.095, 0.16, 0.229, 0.30, 0.369, 0.435,
        0.494, 0.548, 0.596, 0.640, 0.679, 0.715, 0.748, 0.778, 0.806, 0.832,
    ]
    cnaa_data = [
        6.28, 6.28, 6.29, 6.29, 6.30, 6.31, 6.32, 6.33, 6.34, 6.35, 6.36,
        6.37, 6.38, 6.39, 6.40, 6.40, 6.41, 6.42, 6.42, 6.43, 6.43,
    ]
    btana = _interp1(beta, beta_data, btana_data)
    cnaa = _interp1(beta, beta_data, cnaa_data)
    return btana, cnaa
end

function fig68(mach::Real, delta::Real)
    if mach <= 1.0
        return 0.0, 1
    end
    theta = rad2deg(asin(1.0 / mach)) + delta
    max_deflection = rad2deg(asin(1.0 / mach)) * 2.0
    if delta > max_deflection
        return 0.0, 1
    end
    return theta, 0
end

mutable struct DatcomTableManager
    cache::Dict{String, Any}
end

DatcomTableManager() = DatcomTableManager(Dict{String, Any}())

function load_table!(mgr::DatcomTableManager, table_name::String)
    if haskey(mgr.cache, table_name)
        return mgr.cache[table_name]
    end
    mgr.cache[table_name] = Dict{String, Any}()
    return mgr.cache[table_name]
end

function lookup(mgr::DatcomTableManager, table_name::String, args...)
    if table_name == "FIG26" && length(args) == 2
        return fig26(args[1], args[2])
    elseif table_name == "FIG53A" && length(args) == 2
        return fig53a(args[1], args[2])
    elseif table_name == "FIG60B" && length(args) == 1
        btana, _ = fig60b(args[1])
        return btana
    elseif table_name == "FIG68" && length(args) == 2
        theta, _ = fig68(args[1], args[2])
        return theta
    end
    return 0.0
end

const _table_manager = DatcomTableManager()

get_table_manager() = _table_manager

export fig26
export fig53a
export fig60b
export fig68
export DatcomTableManager
export load_table!
export lookup
export get_table_manager

end
