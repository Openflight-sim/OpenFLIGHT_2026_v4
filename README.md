# OpenFLIGHT

An open, hackable flight simulator with a **Julia** physics core and a **Babylon.js** browser frontend, connected over WebSockets. Drop a YAML aircraft definition into `🏭_HANGAR/`, set `aircraft_name` in the mission file, and fly.

> Project page: <https://sites.google.com/view/openflight/base>

---

## Highlights

- **6-DOF flight dynamics** integrated with RK4 in Julia.
- **Two aero modelling modes** per aircraft:
  - `linear` — scalar stability & control derivatives.
  - `table` — full look-up tables (`α`, `β`, `Mach`, control deflections).
- **2+ aircraft** included out of the box — PC-21, SF-28 and P28 
- **Auto pitch trim**: `off` / `initial` / `continuous` (electric-trim follow-up).
- **Hot reload** of mission and aircraft YAMLs from the in-sim pause menu — no restart needed when iterating on aero data.
- **Slew-rate-limited keyboard inputs** for spring-stick feel; auto-detected gamepad / joystick mapping (Xbox, PlayStation, generic flight sticks).
- **Scenery levels 0–4**, day / dusk / night / fog environments, force / velocity / trajectory overlays, optional in-cockpit telemetry overlay.
- **Live ATC** via Google Gemini (push-to-talk).
- **Companion apps**: Aircraft Model Creator (VLM-backed YAML builder), aero model viewer, telemetry dashboard.
- **CSV flight-test recording** with configurable start/stop times.

---

## Quick start

```julia
# from the project root, in a Julia REPL:
include("OpenFLIGHT.jl")
```

The first run installs the required Julia packages automatically; subsequent runs skip the check via a SHA stamp of `Project.toml` + `Manifest.toml`. The backend opens an HTTP + WebSocket server (port search starts at `8000`) and launches your default browser. If the browser doesn't open, paste the URL printed in the console.

For everything else — controls, configuration, output files — see the **[user guide](DOCS/USER_GUIDE.md)**.

### Requirements

- [Julia](https://julialang.org) (recent stable).
- A modern browser (Edge, Chrome, Firefox).
- Optional: a gamepad or USB flight stick.

Julia dependencies (auto-installed): `HTTP`, `WebSockets`, `YAML`, `JSON`, `MsgPack`, `CSV`, `DataFrames`, `StaticArrays`, `VortexLattice`.

---

## Configuring a mission

Edit [`default_mission.yaml`](default_mission.yaml):

```yaml
aircraft_name: "SF25B"             # folder under 🏭_HANGAR/
aerodynamic_model_mode: "linear"   # or "table"

initial_velocity: 60               # m/s
initial_altitude: 2000             # m

auto_pitch_trim_mode: "initial"    # off | initial | continuous
auto_pitch_trim_rate: 0.1
auto_pitch_trim_max_bias: 0.25

start_flight_data_recording_at:  3
finish_flight_data_recording_at: 145

scenery_complexity: 0              # 0..4
game_environment:   "fog"          # fog | dusk | night
telemetry_screen:   false
```

---

## Adding an aircraft

Create a folder `🏭_HANGAR/<NAME>/` containing:

| File                          | Purpose                                              |
|-------------------------------|------------------------------------------------------|
| `*.ac_data.yaml`              | mass, inertia, geometry, propulsion                  |
| `*.linearized.aero_prop.yaml` | derivatives — used by `linear` mode                  |
| `*.tabular.aero_prop.yaml`    | look-up tables — used by `table` mode                |
| `*.glb` *(optional)*          | 3D visual model                                      |
| `render_settings.yaml` *(optional)* | per-aircraft GLB transform, lights, propeller |

The bundled [Aircraft Model Creator](RunModelCreator.jl) generates these YAMLs from a parametric description (uses `VortexLattice.jl` for the aero side).

---

## Controls (default)

### Keyboard
| Action                   | Keys                                |
|--------------------------|-------------------------------------|
| Pitch up / down          | `A` / `Q`                           |
| Roll left / right        | `O` / `P`                           |
| Yaw left / right         | `K` / `L`                           |
| Camera select            | `I` / `U` / `Y` / `T`               |
| Thrust 0…100 %           | `0`…`9`                             |
| Toggle HUD               | `H`                                 |
| Forces / Velocity / Trajectory | `F` / `V` / `S`               |
| Reset / Respawn          | `R` (Shift+`R` = page reload)       |
| Pause / Resume           | `Space`                             |
| Connect ATC              | `C` — push-to-talk: hold `Enter`    |

### Gamepad / joystick (auto-detected)
- Right stick — **pitch / roll**
- Left stick / twist — **yaw / throttle**
- Start / Options — **pause**
- Face buttons — **camera**
- Select / Back — **respawn**

---

## Project layout

```
.
├── OpenFLIGHT.jl                # main entry point (the simulator)
├── RunModelCreator.jl           # aircraft model creator entry point
├── default_mission.yaml         # mission configuration
├── ✈_OPENFLIGHT/                # simulator source
│   ├── src/🟣JULIA🟣/            # backend: aero model, EOM, RK4, websockets, atmos…
│   ├── src/🟡JAVASCRIPT🟡/       # frontend: scene, HUD, inceptors, ATC, render loop
│   └── 📊_Flight_Test_Data/     # CSV flight-test output
├── 🏭_HANGAR/                   # aircraft library (one folder per aircraft)
├── 🛫_CREATE_AIRCRAFT_MODEL/    # companion app: VLM-based aircraft YAML generator
└── DOCS/                       # technical manual + user guide
```

---

## Output

When telemetry recording is active, OpenFLIGHT writes a CSV to
`✈_OPENFLIGHT/📊_Flight_Test_Data/simulation_data_<YYYY-MM-DD>_@_<HHh-MM-SS>.csv`
containing the full aircraft state and inceptor demands at each integration step.

---

## Documentation

- [User guide](DOCS/USER_GUIDE.md) — install, configure, fly.
- [Technical manual (PDF)](DOCS/OpenFLIGHT_Technical_Manual.pdf) — physics, code architecture, reference.
- Aero model viewer: `✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/aero_model_viewer.html`.
- Telemetry dashboard: `✈_OPENFLIGHT/src/🟡JAVASCRIPT🟡/telemetry_dashboard.html`.

---

## Stopping the simulator

In the Julia REPL where you ran `OpenFLIGHT.jl`, press **Ctrl + C**. The HTTP and WebSocket servers shut down cleanly; you can then close the browser tab.

---

## Contributing

Pull requests welcome — particularly for:

- New aircraft (drop a folder into `🏭_HANGAR/`).
- Tabular aero datasets validated against flight-test data.
- Scenery, models, and visual effects.
- Improvements to the Aircraft Model Creator pipeline.

Please keep new aero data in YAML and follow the schema used by existing aircraft (see e.g. `🏭_HANGAR/PC21/`).

---

## License

See `LICENSE` if present, or contact the maintainers.
