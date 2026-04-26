// Default value for the server port, it will be updated by the server
let freeport = 8000  // Default aircraft configuration file name
let aircraft_name = "PC21"

// Initial flight conditions
let initial_velocity = 60
let initial_altitude = 2000

// Time interval (in server time seconds) for flight data recording visualization (pink trajectory)
let start_flight_data_recording_at = 3
let finish_flight_data_recording_at = 45

// Flags to control 3D visualization elements
let show_force_vectors = "false"
let show_velocity_vectors = "false"
let show_trajectory = "false"
let frames_per_trajectory_marker = 2; // Add a trajectory dot every N frames

// Scenery complexity level: 0 = checkered ground only, 1 = low, 2 = medium, 3 = high
let scenery_complexity = 0

// Flag to enable/disable the glow effect layer. Keep it off below ultra scenery
// because GlowLayer is expensive and can shimmer against night/dusk skies.
let game_environment = "fog"
let telemetry_screen = false
let enable_glow_effect = (game_environment === "night" || game_environment === "dusk") && scenery_complexity >= 4 ? true : false;
let aircraft = null;
// TransformNode holding the simple default aircraft visual geometry
let planeNode = null;
// TransformNode holding the loaded GLB aircraft visual geometry
let glbNode = null;

// Babylon.js engine and scene instances (will be assigned in 6.1_...)
let engine, scene;

// Aircraft velocity vector components (m/s)
let velocity = { x: initial_velocity, y: 0, z: 0 };
// Aircraft angular velocity vector components (rad/s)
let angularVelocity = { x: 0, y: 0, z: 0 };
// Aircraft orientation represented as a quaternion
let orientation = { x: 0, y: 0, z: 0, w: 1 };

// Simulation control flags
let isPaused = true; // Is the simulation currently paused?
let hasStartedOnce = false; // Tracks if it started from initial pause
let simulationEnded = false; // Has the simulation ended (e.g., crash)?

// Visualization line meshes (will be assigned in 5.1_...)
let velocityLine;
let forceLine;

// Timing variables
let simulationStartTime = Date.now(); // Timestamp when the simulation started
let lastFrameTime = Date.now(); // Timestamp of the last rendered frame
let elapsedTime = 0; // Total elapsed simulation time (client-side, may differ from server)
let timeSinceLastUpdate = 0; // Accumulated time since last physics update (client-side)
let fps_demanded = 60; // Target frames per second for the simulation
let global_time_step = 1.0 / fps_demanded; // Ideal time step per frame (seconds)
let distanceFromCenter = 0; // Aircraft distance from world origin (0,0,0)

// Material reference (can be used for shared materials if needed)
let material;

// === Pilot Control Inputs ===

// Raw force inputs (potentially unused if using control surface demands)
let forceX = 0.0;
let forceY = 0.0;
// Thrust demand (0.0 to 1.0) set by pilot input
let thrust_setting_demand = 0.0;
// Actual thrust attained (feedback from server simulation)
let thrust_attained = 0.0;
// Multi-engine throttle vectors (normalized per engine, -1.0 to 1.0)
let throttle_demand_vector = [0.0];
let throttle_attained_vector = [0.0];
let engine_count = 1;

// Aerodynamic configuration identifier (e.g. "clean", "takeoff", "landing")
let configuration = "clean";
let available_configurations = ["clean"];

// Control surface demands (normalized, e.g., -1.0 to 1.0 or 0.0 to 1.0) set by pilot input
let roll_demand = 0.0;
let pitch_demand = 0.0;
let yaw_demand = 0.0;

// Actual control surface positions/effects attained (feedback from server simulation)
let roll_demand_attained = 0.0;
let pitch_demand_attained = 0.0;
let yaw_demand_attained = 0.0;

// === Server Feedback Variables ===

// Global forces acting on the aircraft (feedback from server simulation)
let forceGlobalX = 0.0;
let forceGlobalY = 0.0;
let forceGlobalZ = 0.0;

// Aerodynamic component forces (global frame) and application points
let wingForceGlobalX = 0.0;
let wingForceGlobalY = 0.0;
let wingForceGlobalZ = 0.0;
let tailForceGlobalX = 0.0;
let tailForceGlobalY = 0.0;
let tailForceGlobalZ = 0.0;
let tailLiftGlobalX = 0.0;
let tailLiftGlobalY = 0.0;
let tailLiftGlobalZ = 0.0;

let wingForceOriginGlobalX = 0.0;
let wingForceOriginGlobalY = 0.0;
let wingForceOriginGlobalZ = 0.0;
let tailForceOriginGlobalX = 0.0;
let tailForceOriginGlobalY = 0.0;
let tailForceOriginGlobalZ = 0.0;

// Requested force visualization vectors (global frame)
let wingLiftGlobalX = 0.0;
let wingLiftGlobalY = 0.0;
let wingLiftGlobalZ = 0.0;
let htailLiftGlobalX = 0.0;
let htailLiftGlobalY = 0.0;
let htailLiftGlobalZ = 0.0;
let vtailLiftGlobalX = 0.0;
let vtailLiftGlobalY = 0.0;
let vtailLiftGlobalZ = 0.0;
let htailForceGlobalX = 0.0;
let htailForceGlobalY = 0.0;
let htailForceGlobalZ = 0.0;
let vtailForceGlobalX = 0.0;
let vtailForceGlobalY = 0.0;
let vtailForceGlobalZ = 0.0;
let htailLocalVelocityGlobalX = 0.0;
let htailLocalVelocityGlobalY = 0.0;
let htailLocalVelocityGlobalZ = 0.0;
let vtailLocalVelocityGlobalX = 0.0;
let vtailLocalVelocityGlobalY = 0.0;
let vtailLocalVelocityGlobalZ = 0.0;
let weightForceGlobalX = 0.0;
let weightForceGlobalY = 0.0;
let weightForceGlobalZ = 0.0;

let wingLiftOriginGlobalX = 0.0;
let wingLiftOriginGlobalY = 0.0;
let wingLiftOriginGlobalZ = 0.0;
let htailLiftOriginGlobalX = 0.0;
let htailLiftOriginGlobalY = 0.0;
let htailLiftOriginGlobalZ = 0.0;
let vtailLiftOriginGlobalX = 0.0;
let vtailLiftOriginGlobalY = 0.0;
let vtailLiftOriginGlobalZ = 0.0;
let weightOriginGlobalX = 0.0;
let weightOriginGlobalY = 0.0;
let weightOriginGlobalZ = 0.0;
let scale_tail_forces = 5.0; // Visualization multiplier for tail force vectors

// Aerodynamic angles (feedback from server simulation)
let alpha_RAD = 0.0; // Angle of attack in radians
let beta_RAD = 0.0; // Sideslip angle in radians

// === Load Factor Variables (using nz from body axis) ===
let nz = 1.0; // Load factor in body Z-axis (normal to aircraft, received from server)
let currentCL = 0.0;
let currentCD = 0.0;
let currentLD = 0.0;

// === Gamepad/Input Variables ===

// Index of the currently connected gamepad
let gamepadIndex = null;
// Array holding the current state of gamepad axes
let joystickAxes = [0, 0, 0, 0]; // Initialize with default values
// Array holding the current state of gamepad buttons (can be populated if needed)
let joystickButtons = [];

// === GUI Variables ===

// Babylon.GUI AdvancedDynamicTexture instance
let advancedTexture;
// Babylon.GUI TextBlock elements for displaying data (will be assigned in 2.1_...)
let positionText, velocityText, timeText, alpha_beta_Text, joystickText, fpsText;
let loadFactorText;
let cockpitHudContainer, cockpitHudPrimaryText, cockpitHudSecondaryText;
let cockpitHudReticleH, cockpitHudReticleV;
let cockpitHudHorizonRoot, cockpitHudHorizonMovingGroup;
let cockpitHudState = null;
// Babylon.GUI Button element for pausing/resuming (will be assigned in 2.1_...)
let pauseButton;
let gForceOverlay; // Fullscreen overlay for G-force effects

// === Global State Flags ===

// Server time received from the WebSocket connection (updated in 1.1_...)
window.serverElapsedTime = 0;

// *** MODIFIED: Define initialDataReceived on the window object ***
// Flag to indicate if the first valid data packet has been received from the server
window.initialDataReceived = false;
