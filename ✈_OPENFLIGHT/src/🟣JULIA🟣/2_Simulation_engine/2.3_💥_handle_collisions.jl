

function  handle_collisions(new_position_y, new_velocity_y )   # Handle ground collision

    # Simple ground contact model: below 14 m the vertical velocity is frozen
    # to zero so the aircraft sits on the runway surface.  (Horizontal
    # components are damped by update_aircraft_state's ground-friction path.)
    if !isfinite(new_position_y) || new_position_y <= 14.0
        new_velocity_y = 0.0
    end

    return new_velocity_y
end