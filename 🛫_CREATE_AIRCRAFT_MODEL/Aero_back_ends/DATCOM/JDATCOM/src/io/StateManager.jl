module StateManagerModule

using JSON3
using YAML
using ...Utils: get_constants_dict

mutable struct StateManager
    state::Dict{String, Any}
end

function _initialize_defaults!()
    s = Dict{String, Any}()
    merge!(s, get_constants_dict())

    s["flight_nmach"] = 1
    s["flight_mach"] = Any[]
    s["flight_nalpha"] = 0
    s["flight_alpha"] = Any[]
    s["flight_rnnub"] = Any[]
    s["flight_alt"] = Any[]
    s["flight_vinf"] = Any[]
    s["flight_pinf"] = Any[]
    s["flight_tinf"] = Any[]

    s["options_sref"] = nothing
    s["options_cbarr"] = nothing
    s["options_rougfc"] = 1.6e-4
    s["options_blref"] = nothing
    s["options_irun"] = 0

    s["synths_xcg"] = nothing
    s["synths_xw"] = nothing
    s["synths_zw"] = nothing
    s["synths_aliw"] = nothing
    s["synths_zcg"] = nothing
    s["synths_xh"] = nothing
    s["synths_zh"] = nothing
    s["synths_alih"] = nothing
    s["synths_xv"] = nothing
    s["synths_zv"] = nothing
    s["synths_xvf"] = nothing
    s["synths_zvf"] = nothing
    s["synths_yv"] = nothing
    s["synths_yf"] = nothing
    s["synths_phiv"] = nothing
    s["synths_phif"] = nothing
    s["synths_vertup"] = false
    s["synths_hinax"] = nothing
    s["synths_scale"] = nothing

    s["body_nx"] = 0
    s["body_x"] = Any[]
    s["body_s"] = Any[]
    s["body_p"] = Any[]
    s["body_r"] = Any[]
    s["body_zu"] = Any[]
    s["body_zl"] = Any[]
    s["body_bnose"] = nothing
    s["body_btail"] = nothing
    s["body_bln"] = nothing
    s["body_bla"] = nothing
    s["body_ds"] = nothing
    s["body_itype"] = 2
    s["body_method"] = 1

    s["wing_data"] = Dict{String, Any}()
    s["wing_a"] = fill(0.0, 195)
    s["wing_b"] = fill(0.0, 49)

    s["htail_data"] = Dict{String, Any}()
    s["htail_a"] = fill(0.0, 195)
    s["htail_b"] = fill(0.0, 49)

    s["vtail_data"] = Dict{String, Any}()
    s["vtail_a"] = fill(0.0, 195)
    s["vtail_vf"] = fill(0.0, 195)

    s["aero_cl"] = nothing
    s["aero_cd"] = nothing
    s["aero_cm"] = nothing
    s["aero_cn"] = nothing
    s["aero_ca"] = nothing

    s["flags_fltc"] = false
    s["flags_opti"] = false
    s["flags_bo"] = false
    s["flags_wgpl"] = false
    s["flags_wgsc"] = false
    s["flags_synt"] = false
    s["flags_htpl"] = false
    s["flags_htsc"] = false
    s["flags_vtpl"] = false
    s["flags_vtsc"] = false
    s["flags_supers"] = false
    s["flags_subson"] = false
    s["flags_transn"] = false
    s["flags_hypers"] = false

    s["case_id"] = ""
    s["case_save"] = false
    s["case_dump"] = false

    return s
end

function StateManager()
    return StateManager(_initialize_defaults!())
end

function get_state(sm::StateManager, key::String, default = nothing)
    return get(sm.state, key, default)
end

function set_state!(sm::StateManager, key::String, value)
    sm.state[key] = value
    return nothing
end

function update_state!(sm::StateManager, data::Dict{String, Any})
    merge!(sm.state, data)
    return nothing
end

function reset!(sm::StateManager; keep_constants::Bool = true)
    if keep_constants
        constants = Dict{String, Any}()
        for (k, v) in sm.state
            if startswith(k, "constants_")
                constants[k] = v
            end
        end
        sm.state = _initialize_defaults!()
        merge!(sm.state, constants)
    else
        sm.state = _initialize_defaults!()
    end
    return nothing
end

function export_to_yaml(sm::StateManager, filepath::AbstractString)
    YAML.write_file(filepath, sm.state)
    return nothing
end

function export_to_json(sm::StateManager, filepath::AbstractString)
    open(filepath, "w") do io
        JSON3.pretty(io, sm.state)
    end
    return nothing
end

function import_from_yaml!(sm::StateManager, filepath::AbstractString)
    data = YAML.load_file(filepath)
    for (k, v) in data
        sm.state[string(k)] = v
    end
    return nothing
end

function get_all(sm::StateManager)
    return copy(sm.state)
end

function get_component(sm::StateManager, prefix::String)
    out = Dict{String, Any}()
    pk = string(prefix, "_")
    for (k, v) in sm.state
        if startswith(k, pk)
            out[replace(k, pk => "")] = v
        end
    end
    return out
end

export StateManager
export get_state
export set_state!
export update_state!
export reset!
export export_to_yaml
export export_to_json
export import_from_yaml!
export get_all
export get_component

end
