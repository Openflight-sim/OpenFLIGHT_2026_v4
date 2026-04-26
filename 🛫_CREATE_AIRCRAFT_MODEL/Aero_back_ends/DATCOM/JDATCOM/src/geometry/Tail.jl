module Tail

using ..Wing

const TailGeometry = Wing.TailGeometry
const calculate_tail_geometry = Wing.calculate_tail_geometry

function calculate_horizontal_tail(state::Dict{String, Any})
    return calculate_tail_geometry(state; tail_type = "htail")
end

function calculate_vertical_tail(state::Dict{String, Any})
    return calculate_tail_geometry(state; tail_type = "vtail")
end

export TailGeometry
export calculate_tail_geometry
export calculate_horizontal_tail
export calculate_vertical_tail

end
