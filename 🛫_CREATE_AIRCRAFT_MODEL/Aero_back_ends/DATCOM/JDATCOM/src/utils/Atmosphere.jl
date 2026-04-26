module Atmosphere

struct AtmosphereModel end

const G0 = 32.1740484
const WM0 = 28.9644
const R0 = 20890855.0
const GMRS = 0.018743418

const HG = [-16404.0, 0.0, 36089.0, 65617.0, 104987.0, 154199.0, 170604.0, 200131.0, 250186.0, 291160.0]
const ZM = [
    295276.0, 328084.0, 360892.0, 393701.0, 492126.0, 524934.0, 557743.0,
    623360.0, 754593.0, 984252.0, 1312336.0, 1640420.0, 1968504.0, 2296588.0,
]
const WM = [28.9644, 28.88, 28.56, 28.07, 26.92, 26.66, 26.4, 25.85, 24.7, 22.66, 19.94, 17.94, 16.84, 16.17]
const TM = [
    577.17, 518.67, 389.97, 389.97, 411.57, 487.17, 487.17, 454.77, 325.17, 325.17, 379.17,
    469.17, 649.17, 1729.17, 1999.17, 2179.17, 2431.17, 2791.17, 3295.17, 3889.17, 4357.17,
    4663.17, 4861.17,
]
const PM = [
    3711.0839, 2116.2165, 472.67563, 114.34314, 18.128355, 2.3162178, 1.2321972, 0.38030279,
    0.021671352, 0.0034313478, 0.00062773411, 0.00015349091, 5.2624212e-5, 1.0561806e-5,
    7.7083076e-6, 5.8267151e-6, 3.5159854e-6, 1.4520255e-6, 3.9290563e-7, 8.4030242e-8,
    2.2835256e-8, 7.1875452e-9,
]

function calculate(altitude::Real)
    z = float(altitude)
    g = G0 * (R0 / (R0 + z))^2

    tms = 0.0
    elz = 0.0
    dmdz = 0.0
    em = WM0
    pressure = PM[1]

    if z <= 295276.0
        h = R0 * z / (R0 + z)
        j = 1
        for i in 2:length(HG)
            if HG[i] >= h
                j = i - 1
                break
            end
        end

        if j < length(HG)
            elh = (TM[j + 1] - TM[j]) / (HG[j + 1] - HG[j])
        else
            elh = 0.0
        end

        tms = TM[j] + elh * (h - HG[j])
        elz = elh * g / G0
        dmdz = 0.0
        em = WM0

        if elh != 0.0
            pressure = PM[j] * (TM[j] / tms)^(GMRS / elh)
        else
            pressure = PM[j] * exp(GMRS * (HG[j] - h) / tms)
        end
    else
        j = 9
        k = 1
        for i in 2:length(ZM)
            if ZM[i] >= z
                j = i + 8
                k = i - 1
                break
            end
        end

        if k < length(ZM)
            elz = (TM[j + 1] - TM[j]) / (ZM[k + 1] - ZM[k])
        else
            elz = 0.0
        end

        tms = TM[j] + elz * (z - ZM[k])

        if k < length(WM)
            dmdz = (WM[k + 1] - WM[k]) / (ZM[k + 1] - ZM[k])
        else
            dmdz = 0.0
        end

        em = WM[k] + dmdz * (z - ZM[k])
        zlz = elz != 0.0 ? z - tms / elz : z

        if elz != 0.0
            exp_term = GMRS / elz * (R0 / (R0 + zlz))^2 * (
                (z - ZM[k]) * (R0 + zlz) / (R0 + z) / (R0 + ZM[k]) -
                log(tms * (R0 + ZM[k]) / TM[j] / (R0 + z))
            )
            pressure = PM[j] * exp(exp_term)
        else
            pressure = PM[j]
        end
    end

    cs = 49.022164 * sqrt(tms)
    dcs_dz = 0.5 * elz / tms

    density = GMRS * pressure / G0 / tms
    drho_dz = -(density * g / pressure + elz / tms)
    dp_dz = -density * g

    temperature = em * tms / WM0
    dt_dz = (em * elz + tms * dmdz) / WM0

    return Dict{String, Float64}(
        "cs" => cs,
        "dcs_dz" => dcs_dz,
        "altitude" => z,
        "pressure" => pressure,
        "dp_dz" => dp_dz,
        "density" => density,
        "drho_dz" => drho_dz,
        "temperature" => temperature,
        "dt_dz" => dt_dz,
    )
end

function get_properties(altitude::Real)
    atm = calculate(altitude)
    return atm["temperature"], atm["pressure"], atm["density"]
end

export AtmosphereModel
export calculate
export get_properties

end
