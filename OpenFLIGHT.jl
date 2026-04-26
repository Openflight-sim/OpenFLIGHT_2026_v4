###########################################
# OpenFLIGHT — Flight Simulator Entry Point
###########################################

# project_dir points to the ✈_OPENFLIGHT subfolder (where src/, mission config, etc. live)
project_dir = joinpath(dirname(@__FILE__), "✈_OPENFLIGHT")

# Add required Julia packages in the first execution and ignore afterwards.
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/1.0_📚_Check_packages_and_websockets_port/🎁_load_required_packages.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/1.0_📚_Check_packages_and_websockets_port/🔌_Find_free_port.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/1.0_📚_Check_packages_and_websockets_port/✨_sync_mission_data_to_javascript.jl")

# 2) Load aerodynamic and flight-model code:
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.2.4_📈_get_constants_and_interpolate_coefficients.jl")
# 0.2.5 must load BEFORE 0.1 because 0.1 calls has_v3_split_tables() when
# assembling aircraft_flight_physics_and_propulsive_data.
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.2.5_🧩_assemble_from_components.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.1_📊_aircraft_aerodynamic_and_propulsive_data.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.2.1_▶_compute_aerodynamic_force_coeffs.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.2.2_⏩_compute_aerodynamic_moment_coeffs.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.2.3_🚀_compute_propulsive_forces.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.3_🧮_linear_aerodynamic_model.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.4_📊_aero_model_inspector.jl")

# 3) Load math & auxiliary functions:
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/1.1_🔮_quaternions_and_transformations.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/1.2_🛠_auxiliary_functions.jl")

# 4) Load the simulation engine:
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/2_Simulation_engine/2.1_⭐_Runge_Kutta_4_integrator.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/2_Simulation_engine/2.2_🤸‍♀️_compute_6DOF_equations_of_motion.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/2_Simulation_engine/2.3_💥_handle_collisions.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/2_Simulation_engine/2.4_📶_compute_instantaneous_flight_conditions.jl")

# 5) Load websockets + flight-data code:
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/3_Websockets_and_flight_data/3.0_🌐_launch_web_browser.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/3_Websockets_and_flight_data/3.1_🤝_Establish_WebSockets_connection.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/3_Websockets_and_flight_data/3.2_🔁_Update_and_transfer_aircraft_state.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/3_Websockets_and_flight_data/3.3_📈_record_and_save_flight_data.jl")

# 6) Load atmosphere, anemometry, and constants:
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/4_Atmosphere_anemometry_and_constants/4.1_🎯_physical_constants.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/4_Atmosphere_anemometry_and_constants/4.2_🌍_ISA76.jl")
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/4_Atmosphere_anemometry_and_constants/4.3_🕑_anemometry.jl")

# 7) Load control/actuator dynamics:
include(raw"./✈_OPENFLIGHT/src/🟣JULIA🟣/5_Control_Laws_and_Systems_Dynamics/5.1_➰_Actuator_and_Engine_Dynamics.jl")

# Start the HTTP + WebSocket server first (non-blocking)
start_server()

# Then launch the browser — the server is already listening
launch_client(project_dir)

# Block the main thread to keep the server alive
wait_for_server()
