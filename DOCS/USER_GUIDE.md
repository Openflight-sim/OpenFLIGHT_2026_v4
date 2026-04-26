# OpenFLIGHT User Guide — Running the Simulator (2026 baseline)

This guide explains how to configure and fly the OpenFLIGHT flight simulator in its current layout.

## 1. Prerequisites

- **Julia**: A working Julia install (download from julialang.org). On the very first run, the backend will check for the required packages (HTTP, WebSockets, YAML, JSON, etc.) and install them automatically if missing. Subsequent runs are gated by a SHA stamp of `Project.toml` + `Manifest.toml`, so the package check is skipped unless you change the environment.
- **Web browser**: A modern browser (Edge, Chrome or Firefox). Babylon.js renders the 3D scene; the WebSocket client connects to the Julia backend.
- **Project files**: The complete OpenFLIGHT folder structure as shipped, including [🏭_HANGAR/](../🏭_HANGAR/) and [✈_OPENFLIGHT/](../✈_OPENFLIGHT/).

## 2. Configuration — `default_mission.yaml`

Before launching you can customize the flight by editing [default_mission.yaml](../default_mission.yaml) at the project root. The most useful keys:

- **`aircraft_name`** — name of the aircraft *folder* under [🏭_HANGAR/](../🏭_HANGAR/). Each folder contains the aero/propulsive data and (optionally) a `.glb` 3D model and a `render_settings.yaml`. Examples: `PC21`, `SF25B`, `F104`, `SU57`, `airliner`, `katana`, `stearman`.
- **`aerodynamic_model_mode`**: `"linear"` or `"table"`.
  - `"linear"` — scalar stability & control derivatives (simple, robust fallback).
  - `"table"` — full aerodynamic look-up tables loaded from the `.tabular.aero_prop.yaml` file. Preferred when the aircraft ships a validated tabular dataset.
- **`initial_velocity`** — starting airspeed in m/s.
- **`initial_altitude`** — starting altitude in m.
- **`control_actuator_speed`** *(optional)* — server-side actuator slew rate for aileron/elevator/rudder, in normalized units per second (`4.0` ≈ 250 ms to full deflection). If absent, the aircraft YAML's value is used (fallback `4.0`).
- **`auto_pitch_trim_mode`**: `"off"` / `"initial"` / `"continuous"`.
  - `off` — pilot flies raw; any pitching-moment bias shows up as held stick pressure.
  - `initial` — bias computed once at the IC and held forever (good for quick start).
  - `continuous` — initial trim plus a slow integrator that absorbs sustained pilot stick pressure into the trim bias (electric-trim follow-up). Tuned by `auto_pitch_trim_rate` (1/s) and `auto_pitch_trim_max_bias`.
- **`start_flight_data_recording_at` / `finish_flight_data_recording_at`** — telemetry record window in simulation seconds.
- **`scenery_complexity`**: `0` four checkered quadrants, `1` low, `2` medium, `3` high detail, `4` ultra (shadows/glow).
- **`game_environment`**: `"fog"`, `"dusk"`, or `"night"`.
- **`telemetry_screen`**: `true` renders a live telemetry overlay in the cockpit view.

## 3. Running the Julia backend

1. Open a Julia REPL and `cd` into the project root (the folder that contains [OpenFLIGHT.jl](../OpenFLIGHT.jl)).
2. Run:
   ```julia
   include("OpenFLIGHT.jl")
   ```

What to expect:

- Package bootstrap (cached on subsequent runs).
- The mission file is parsed and key parameters are synced to the JavaScript frontend.
- The backend finds a free port (search starts at 8000) and starts an HTTP + WebSocket server on it.
- It tries to launch your default browser; if that fails it tries Edge → Chrome → Firefox in turn.
- You'll see messages like `Starting WebSocket server on port 8000…` followed by `Server running. Press Ctrl+C to stop.`

If the browser doesn't open automatically, point it manually at the URL printed in the console (it serves [✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/✅_front_end_and_client.html](../✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/✅_front_end_and_client.html) over HTTP).

## 4. Using the simulator frontend

When the page loads it connects to the Julia WebSocket server, builds the scene, and waits at a "Loading…" overlay until first valid server data and any GLB upload have completed. Pilot inputs are blocked until the overlay clears (so the first second of handshake doesn't feel "dead").

### Keyboard

- **Pitch up / down**: A / Q
- **Roll left / right**: O / P
- **Yaw left / right**: K / L *(L = nose right)*
- **Camera select**: I / U / Y / T
- **Thrust level**: 1…9 (10 % steps; 0 = idle)
- **Toggle HUD**: H
- **Toggle force vectors**: F
- **Toggle velocity vectors**: V
- **Toggle trajectory ribbon**: S
- **Reset / Respawn**: R *(in-place reset to initial conditions and reload data)*
- **Full page reload**: Shift + R
- **Pause / Resume**: Spacebar
- **Connect Gemini ATC**: C
- **ATC push-to-talk**: hold Enter (while flying)

Keyboard control demands are slew-rate limited client-side (≈ ±0.8 stick authority, ramp ≈ 4–8 /s) so press/release feels like a spring-loaded stick instead of a step input.

### Gamepad / joystick

Connect the controller before launching (the browser exposes it via the standard Gamepad API). Mapping is auto-detected:

- **Pitch / roll**: right stick
- **Yaw / throttle**: left stick (or twist-axis on flight sticks)
- **Pause / resume**: Start / Options button
- **Camera toggle**: face buttons (X / Y / A / B — varies)
- **Reset / Respawn**: Select / Back (varies)

The pause menu shows the live mapping for the controller it detected.

### Pause menu

Press Spacebar (or the gamepad pause button). The "FLIGHT CONTROLS" panel summarizes keyboard + gamepad mappings. It also exposes a **RELOAD AIRCRAFT & MISSION DATA** button — clicking it makes the Julia backend re-read [default_mission.yaml](../default_mission.yaml) and the aircraft folder's YAMLs *without* restarting the sim. Useful when iterating on aero data or tweaking trim.

### Aircraft 3D model

Each aircraft folder under [🏭_HANGAR/](../🏭_HANGAR/) (e.g. [🏭_HANGAR/PC21/](../🏭_HANGAR/PC21/)) may contain:

- `*.ac_data.yaml` — mass, geometry, inertia, propulsion config.
- `*.linearized.aero_prop.yaml` — derivatives for `linear` mode.
- `*.tabular.aero_prop.yaml` — full look-up tables for `table` mode.
- A `.glb` file — the 3D model.
- `render_settings.yaml` — optional per-aircraft visuals (GLB scale / rotation / translation, light positions, propeller diameter and offset).

If `render_settings.yaml` is absent, the model loads with the default transform baseline (PC-21 reference).

## 5. Stopping the simulation

- Return to the Julia REPL and press **Ctrl + C**. Confirm if prompted; the WebSocket and HTTP servers shut down cleanly.
- Close the browser tab.

## 6. Simulation output

If telemetry recording is active (window set in `default_mission.yaml`), the backend writes a CSV into [✈_OPENFLIGHT/📊_Flight_Test_Data/](../✈_OPENFLIGHT/📊_Flight_Test_Data/) with a timestamped filename, e.g. `simulation_data_2026-04-26_@_19h-46-31.csv`. Each row is a sample of the full aircraft state vector and the active inceptor demands.

## 7. Companion tools

- **Aircraft Model Creator** — separate one-click entry point [RunModelCreator.jl](../RunModelCreator.jl). Starts a parallel Julia + browser app for building / inspecting an aircraft's `.ac_data` and `.aero_prop` YAMLs (a VLM-backed pipeline lives under [🛫_CREATE_AIRCRAFT_MODEL/](../🛫_CREATE_AIRCRAFT_MODEL/)).
- **Aero model viewer** — [✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/aero_model_viewer.html](../✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/aero_model_viewer.html) for inspecting the loaded coefficients.
- **Telemetry dashboard** — [✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/telemetry_dashboard.html](../✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/telemetry_dashboard.html) for live flight data plots.
- **Technical manual** — [OpenFLIGHT_Technical_Manual.pdf](OpenFLIGHT_Technical_Manual.pdf) for the underlying physics and code architecture.

Enjoy your flight!
