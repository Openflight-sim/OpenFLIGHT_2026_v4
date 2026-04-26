###########################################
# FILE: 3.3_📈_record_and_save_flight_data.jl
# MODIFIED TO INCLUDE ADDITIONAL TELEMETRY DATA
###########################################

using DataFrames
using CSV
using Dates

const DECIMAL_PLACES = 3
const CSV_WRITE_CHUNK_ROWS = 250
global csv_write_in_progress = false
global csv_write_task = nothing
# Assume TIMESTAMP, csv_file, start_recording_sec, finish_recording_sec,
# and the initial df DataFrame definition (with ALL required columns)
# are handled elsewhere (e.g., in reset_flight_data_recording).
# Assume has_written_to_csv is also managed elsewhere.

# NOTE: The DataFrame 'df' passed to this function MUST be initialized
#       with columns corresponding to ALL the fields being pushed below,
#       including the newly added ones (CL, CD, ..., r_yaw_rate).

function write_flight_data_csv_async(csv_path::AbstractString, df_snapshot::DataFrame)
    global csv_write_in_progress
    global csv_write_task

    if csv_write_in_progress
        return
    end

    csv_write_in_progress = true
    csv_write_task = Threads.@spawn begin
        try
            row_count = nrow(df_snapshot)
            if row_count == 0
                CSV.write(csv_path, df_snapshot)
            else
                isfile(csv_path) && rm(csv_path; force=true)
                first_row = 1
                wrote_header = false
                while first_row <= row_count
                    last_row = min(first_row + CSV_WRITE_CHUNK_ROWS - 1, row_count)
                    CSV.write(
                        csv_path,
                        @view(df_snapshot[first_row:last_row, :]);
                        append = wrote_header,
                        writeheader = !wrote_header,
                    )
                    wrote_header = true
                    first_row = last_row + 1
                    yield()
                end
            end
            @info "Flight data saved to CSV file: $csv_path"
            return true
        catch e
            @error "Failed to write CSV file $csv_path" exception=(e, catch_backtrace())
            return false
        finally
            global csv_write_in_progress
            csv_write_in_progress = false
        end
    end
end

function gather_flight_data(
    # Rename input dict for clarity - it contains the *updated* state from the integrator
    updated_aircraft_state_dict::AbstractDict{String,Any},
    current_sim_time::Float64,
    df::DataFrame # Pass the DataFrame explicitly
)
    global has_written_to_csv # Flag from external scope
    global csv_file           # File path from external scope
    global start_recording_sec # Start time from external scope
    global finish_recording_sec # End time from external scope
    global csv_write_in_progress # Async write flag
    global csv_write_task        # Async write task handle


    function read_numeric(key::String, default_value::Float64=0.0)
        if !haskey(updated_aircraft_state_dict, key)
            return default_value
        end
        value = updated_aircraft_state_dict[key]
        if value isa Number
            return Float64(value)
        elseif value isa AbstractString
            try
                return parse(Float64, strip(value))
            catch
                return default_value
            end
        end
        return default_value
    end

    # 1) Append data while within [start_recording_sec .. finish_recording_sec]
    if current_sim_time >= start_recording_sec &&
       current_sim_time <= finish_recording_sec

        # Push data using a standard named tuple with keys matching DataFrame columns
        push!(df, (
            time = round(current_sim_time, digits=DECIMAL_PLACES),

            # --- Original Position/Velocity/Orientation/Forces ---
            LATITUDE_m  = round(read_numeric("x"),  digits=DECIMAL_PLACES), # x -> LATITUDE_m
            ALTITUDE_m  = round(read_numeric("y"),  digits=DECIMAL_PLACES), # y -> ALTITUDE_m
            LONGITUDE_m = round(read_numeric("z"),  digits=DECIMAL_PLACES), # z -> LONGITUDE_m

            vx = round(read_numeric("vx"), digits=DECIMAL_PLACES),
            VSI_ms = round(read_numeric("vy"), digits=DECIMAL_PLACES), # vy -> VSI_ms
            vz = round(read_numeric("vz"), digits=DECIMAL_PLACES),

            qx = round(read_numeric("qx"), digits=DECIMAL_PLACES),
            qy = round(read_numeric("qy"), digits=DECIMAL_PLACES),
            qz = round(read_numeric("qz"), digits=DECIMAL_PLACES),
            qw = round(read_numeric("qw", 1.0), digits=DECIMAL_PLACES),

            wx = round(read_numeric("wx"), digits=DECIMAL_PLACES), # Angular velocities
            wy = round(read_numeric("wy"), digits=DECIMAL_PLACES),
            wz = round(read_numeric("wz"), digits=DECIMAL_PLACES),

            fx_global = round(read_numeric("fx_global"), digits=DECIMAL_PLACES),
            fy_global = round(read_numeric("fy_global"), digits=DECIMAL_PLACES),
            fz_global = round(read_numeric("fz_global"), digits=DECIMAL_PLACES),

            # --- Original Angles/Demands ---
            alpha_DEG = round(rad2deg(read_numeric("alpha_RAD")), digits=DECIMAL_PLACES),
            beta_DEG  = round(rad2deg(read_numeric("beta_RAD")),  digits=DECIMAL_PLACES),

            pitch_demand          = round(read_numeric("pitch_demand"),          digits=DECIMAL_PLACES),
            roll_demand           = round(read_numeric("roll_demand"),           digits=DECIMAL_PLACES),
            yaw_demand            = round(read_numeric("yaw_demand"),            digits=DECIMAL_PLACES),
            pitch_demand_attained = round(read_numeric("pitch_demand_attained"), digits=DECIMAL_PLACES),
            roll_demand_attained  = round(read_numeric("roll_demand_attained"),  digits=DECIMAL_PLACES),
            yaw_demand_attained   = round(read_numeric("yaw_demand_attained"),   digits=DECIMAL_PLACES),
            thrust_setting_demand = round(read_numeric("thrust_setting_demand"), digits=DECIMAL_PLACES),
            thrust_attained       = round(read_numeric("thrust_attained"),       digits=DECIMAL_PLACES),

            # --- NEW: Additional Flight Data for Telemetry ---
            CL = round(read_numeric("CL"), digits=DECIMAL_PLACES),
            CD = round(read_numeric("CD"), digits=DECIMAL_PLACES),
            CL_CD_ratio = round(read_numeric("CL/CD"), digits=DECIMAL_PLACES), # Renamed key
            CS = round(read_numeric("CS"), digits=DECIMAL_PLACES),

            nx = round(read_numeric("nx"), digits=DECIMAL_PLACES),
            nz = round(read_numeric("nz"), digits=DECIMAL_PLACES),
            ny = round(read_numeric("ny"), digits=DECIMAL_PLACES),

            CM_roll_from_aero_forces   = round(read_numeric("CM_roll_from_aero_forces"),   digits=DECIMAL_PLACES),
            CM_yaw_from_aero_forces    = round(read_numeric("CM_yaw_from_aero_forces"),    digits=DECIMAL_PLACES),
            CM_pitch_from_aero_forces  = round(read_numeric("CM_pitch_from_aero_forces"),  digits=DECIMAL_PLACES),

            CM_roll_from_control       = round(read_numeric("CM_roll_from_control"),       digits=DECIMAL_PLACES),
            CM_yaw_from_control        = round(read_numeric("CM_yaw_from_control"),        digits=DECIMAL_PLACES),
            CM_pitch_from_control      = round(read_numeric("CM_pitch_from_control"),      digits=DECIMAL_PLACES),

            CM_roll_from_aero_stiffness  = round(read_numeric("CM_roll_from_aero_stiffness"),  digits=DECIMAL_PLACES),
            CM_yaw_from_aero_stiffness   = round(read_numeric("CM_yaw_from_aero_stiffness"),   digits=DECIMAL_PLACES),
            CM_pitch_from_aero_stiffness = round(read_numeric("CM_pitch_from_aero_stiffness"), digits=DECIMAL_PLACES),

            CM_roll_from_aero_damping    = round(read_numeric("CM_roll_from_aero_damping"),    digits=DECIMAL_PLACES),
            CM_yaw_from_aero_damping     = round(read_numeric("CM_yaw_from_aero_damping"),     digits=DECIMAL_PLACES),
            CM_pitch_from_aero_damping   = round(read_numeric("CM_pitch_from_aero_damping"),   digits=DECIMAL_PLACES),

            # --- NEW: Body frame rotation rates (assuming source is average_flight_data_for_telemetry as per dict) ---
            # Note: These might be redundant if wx, wy, wz are sufficient, but included as per the dictionary structure.
            q_pitch_rate = round(read_numeric("q_pitch_rate"), digits=DECIMAL_PLACES),
            p_roll_rate  = round(read_numeric("p_roll_rate"),  digits=DECIMAL_PLACES),
            r_yaw_rate   = round(read_numeric("r_yaw_rate"),   digits=DECIMAL_PLACES), 

            TAS = round(read_numeric("TAS"), digits=DECIMAL_PLACES),
            EAS = round(read_numeric("EAS"), digits=DECIMAL_PLACES),
            Mach= round(read_numeric("Mach"), digits=DECIMAL_PLACES),
            dynamic_pressure = round(read_numeric("dynamic_pressure"), digits=DECIMAL_PLACES)


        ), promote=true) # Use promote=true just in case types are inferred narrowly initially
    end

    # 2) If we're *past* the interval and haven't written CSV yet, do it now
    if current_sim_time > finish_recording_sec && !has_written_to_csv && !csv_write_in_progress
        # Make sure the directory exists before writing
        data_dir = dirname(csv_file)
        if !isdir(data_dir)
            try
                mkpath(data_dir)
                println("Created directory: $data_dir")
            catch e
                 @error "Failed to create directory $data_dir" exception=e
                 return # Exit if directory creation fails
            end
        end

        csv_snapshot = copy(df)
        csv_path = String(csv_file)
        write_flight_data_csv_async(csv_path, csv_snapshot)
        has_written_to_csv = true
        println("Flight data CSV write started in background: $(csv_file)")
    end
end

