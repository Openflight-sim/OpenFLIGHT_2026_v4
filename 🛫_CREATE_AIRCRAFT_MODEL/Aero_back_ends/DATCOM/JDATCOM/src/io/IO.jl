module IO

include("NamelistParser.jl")
include("StateManager.jl")

using .NamelistParserModule
using .StateManagerModule

export NamelistParser
export parse_file
export parse
export to_state_dict
export KNOWN_NAMELISTS

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

const NamelistParser = NamelistParserModule.NamelistParser
const parse_file = NamelistParserModule.parse_file
const parse = NamelistParserModule.parse
const to_state_dict = NamelistParserModule.to_state_dict
const KNOWN_NAMELISTS = NamelistParserModule.KNOWN_NAMELISTS

const StateManager = StateManagerModule.StateManager
const get_state = StateManagerModule.get_state
const set_state! = StateManagerModule.set_state!
const update_state! = StateManagerModule.update_state!
const reset! = StateManagerModule.reset!
const export_to_yaml = StateManagerModule.export_to_yaml
const export_to_json = StateManagerModule.export_to_json
const import_from_yaml! = StateManagerModule.import_from_yaml!
const get_all = StateManagerModule.get_all
const get_component = StateManagerModule.get_component

end
