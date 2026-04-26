/********************************************
 * gemini-assistant.js
 *
 * AI Assistant for the Aircraft Model Creator
 * using Gemini Multimodal Live API with text chat
 * and push-to-talk voice. Exposes MCP tools so the
 * AI can read/modify aircraftData, add components,
 * run analysis, and control the 3D view.
 ********************************************/

// =========================================================================
// Configuration
// =========================================================================
const GEMINI_ASSISTANT_HOST = "generativelanguage.googleapis.com";
const GEMINI_ASSISTANT_MODEL = "models/gemini-2.5-flash-native-audio-latest";
const GEMINI_API_KEY_URL = "https://aistudio.google.com/app/apikey";
const ASSISTANT_GREETING = "Greetings Professor Falken. Shall we design an aircraft?";
const GEMINI_API_KEY_STORAGE_KEYS = [
  "aircraft_creator_gemini_key",
  "aircraft_creator_gemini_api_key",
  "gemini_api_key",
  "google_ai_studio_api_key"
];

let _assistantApiKey = _loadAssistantApiKey();
let _assistantWs = null;
let _assistantConnected = false;
let _assistantAudioCtx = null;
let _assistantMediaStream = null;
let _assistantWorklet = null;
let _assistantIsPTT = false;
let _assistantPttRelease = 0;
let _assistantGreetingSpoken = false;
let _assistantGreetingTurnActive = false;
let _assistantGreetingComplete = false;
let _assistantGreetingTimeout = null;
let _assistantPendingTextQueue = [];

// Audio playback
let _playCtx = null;
let _playFilter = null;
let _playNextTime = 0;

// =========================================================================
// MCP Tool Definitions
// =========================================================================
const ASSISTANT_TOOLS = [
  {
    "functionDeclarations": [
      {
        "name": "get_aircraft_data",
        "description": "Returns the full current aircraftData JSON object including all lifting surfaces, fuselages, engines, general properties, and configurations."
      },
      {
        "name": "get_aircraft_summary",
        "description": "Returns a concise summary of the current aircraft: name, number of surfaces/fuselages/engines, mass, CoG, reference geometry."
      },
      {
        "name": "quality_check_aircraft",
        "description": "Runs deterministic plausibility checks on the current aircraft geometry, mass, CG, inertia, tail volumes, controls, and propulsion. Use before run_analysis and after major edits."
      },
      {
        "name": "add_lifting_surface",
        "description": "Adds a new lifting surface to the aircraft. Coordinates use x aft from nose, y starboard/right, z up. Args: name (string, required), role (string: wing/horizontal_stabilizer/vertical_stabilizer/canard), root_LE (string: 'x,y,z' meters), AR (number: aspect ratio), TR (number: taper ratio), surface_area_m2 (number), sweep_quarter_chord_DEG (number), dihedral_DEG (number), symmetric (string: 'true'/'false'), vertical (string: 'true'/'false', defaults true for vertical_stabilizer), incidence_DEG (number), mean_aerodynamic_chord_m (number), airfoil_root (NACA code), airfoil_tip (NACA code).",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "name":  { "type": "STRING", "description": "Surface name, e.g. 'wing', 'HTP', 'VTP'" },
            "role":  { "type": "STRING", "description": "One of: wing, horizontal_stabilizer, vertical_stabilizer, canard, other" },
            "root_LE": { "type": "STRING", "description": "Root leading edge position as 'x,y,z' in meters" },
            "AR":    { "type": "NUMBER", "description": "Aspect ratio" },
            "TR":    { "type": "NUMBER", "description": "Taper ratio (tip chord / root chord)" },
            "surface_area_m2": { "type": "NUMBER", "description": "Total planform area in m^2" },
            "sweep_quarter_chord_DEG": { "type": "NUMBER", "description": "Quarter-chord sweep angle in degrees" },
            "dihedral_DEG": { "type": "NUMBER", "description": "Dihedral angle in degrees" },
            "symmetric": { "type": "STRING", "description": "'true' for mirrored surfaces (wings), 'false' for VTP" },
            "vertical": { "type": "STRING", "description": "'true' for vertical stabilizer, 'false' otherwise" },
            "incidence_DEG": { "type": "NUMBER", "description": "Incidence angle in degrees" },
            "mean_aerodynamic_chord_m": { "type": "NUMBER", "description": "Mean aerodynamic chord in meters" },
            "airfoil_root": { "type": "STRING", "description": "Root airfoil NACA code, e.g. '2412' or '0012'" },
            "airfoil_tip": { "type": "STRING", "description": "Tip airfoil NACA code, e.g. '0012'" }
          },
          "required": ["name", "role"]
        }
      },
      {
        "name": "add_fuselage",
        "description": "Adds a fuselage to the aircraft model and re-renders.",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "name":     { "type": "STRING", "description": "Fuselage name, e.g. 'fuselage_main'" },
            "diameter": { "type": "NUMBER", "description": "Fuselage diameter in meters" },
            "length":   { "type": "NUMBER", "description": "Fuselage length in meters" },
            "nose_position": { "type": "STRING", "description": "Nose tip position as 'x,y,z' in meters" }
          },
          "required": ["name"]
        }
      },
      {
        "name": "add_engine",
        "description": "Adds an engine to the aircraft model and re-renders. IMPORTANT: real-world engine ratings differ by engine class — jet engines are rated by thrust (Newtons or pounds-force), piston and turboprop engines are rated by SHAFT POWER (horsepower, SHP). For propeller aircraft pass `engine_type=\"propeller\"` together with `shaft_horsepower` and the function converts SHP to static thrust using the ≈12 N/SHP rule of thumb (roughly T_static[N] = 12 × SHP). For jets pass `engine_type=\"jet\"` together with `max_thrust_n`.",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "id":           { "type": "STRING", "description": "Engine identifier, e.g. 'ENG1'" },
            "position_m":   { "type": "STRING", "description": "Engine position as 'x,y,z' in meters" },
            "yaw_deg":      { "type": "NUMBER", "description": "Yaw orientation in degrees" },
            "pitch_deg":    { "type": "NUMBER", "description": "Pitch orientation in degrees" },
            "engine_type":  { "type": "STRING", "description": "'jet' (thrust rating) or 'propeller' (shaft-power rating). Defaults to 'jet' for backward compatibility." },
            "max_thrust_n": { "type": "NUMBER", "description": "Maximum sea-level static thrust in Newtons. Use for jets or when the static thrust is known directly." },
            "shaft_horsepower": { "type": "NUMBER", "description": "Shaft power in HP (1 HP = 745.7 W). Use for piston / turboprop engines. Internally converted to static thrust N = 12 × SHP × propeller_efficiency." },
            "propeller_efficiency": { "type": "NUMBER", "description": "Propeller efficiency factor applied to the SHP→thrust conversion. Default 1.0 (the 12 N/SHP rule already bakes in a typical efficiency)." }
          },
          "required": ["id"]
        }
      },
      {
        "name": "set_general_properties",
        "description": "Sets general aircraft properties. Only provided fields are updated.",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "aircraft_name": { "type": "STRING", "description": "Aircraft name/designation" },
            "mass_kg":       { "type": "NUMBER", "description": "Total aircraft mass in kg" },
            "CoG_xyz_m":     { "type": "STRING", "description": "Center of gravity as 'x,y,z' in meters" },
            "Sref_m2":       { "type": "NUMBER", "description": "Reference wing area in m^2" },
            "cref_m":        { "type": "NUMBER", "description": "Reference mean aerodynamic chord in meters" },
            "bref_m":        { "type": "NUMBER", "description": "Reference wingspan in meters" },
            "Ixx_p":         { "type": "NUMBER", "description": "Principal moment of inertia Ixx in kg*m^2" },
            "Iyy_p":         { "type": "NUMBER", "description": "Principal moment of inertia Iyy in kg*m^2" },
            "Izz_p":         { "type": "NUMBER", "description": "Principal moment of inertia Izz in kg*m^2" }
          },
          "required": ["aircraft_name"]
        }
      },
      {
        "name": "remove_component",
        "description": "Removes a lifting surface, fuselage, or engine by name/id and re-renders.",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "component_type": { "type": "STRING", "description": "One of: lifting_surface, fuselage, engine" },
            "name":           { "type": "STRING", "description": "The name or id of the component to remove" }
          },
          "required": ["component_type", "name"]
        }
      },
      {
        "name": "run_analysis",
        "description": "Triggers the aerodynamic analysis. Optional args: alpha_min, alpha_max, alpha_step (degrees), backends (string: 'datcom' by default). Full-envelope analysis defaults to alpha/beta -180..180 deg with 1 deg steps inside the stall-critical band.",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "alpha_min":  { "type": "NUMBER", "description": "Minimum angle of attack in degrees (default -180)" },
            "alpha_max":  { "type": "NUMBER", "description": "Maximum angle of attack in degrees (default 180)" },
            "alpha_step": { "type": "NUMBER", "description": "Alpha step in degrees inside the stall-critical band (default 1)" },
            "backends":   { "type": "STRING", "description": "Comma-separated backends: vlm,javl,datcom (default datcom)" }
          },
          "required": ["alpha_min"]
        }
      },
      {
        "name": "toggle_view",
        "description": "Toggles a visualization element on or off.",
        "parameters": {
          "type": "OBJECT",
          "properties": {
            "element": { "type": "STRING", "description": "One of: ground, translucency, vlm_mesh, inertia_ellipsoid, json_editor, results_panel" }
          },
          "required": ["element"]
        }
      },
      {
        "name": "clear_aircraft",
        "description": "Removes all components from the aircraft model (surfaces, fuselages, engines)."
      },
      {
        "name": "render_aircraft",
        "description": "Forces a re-render of the 3D aircraft visualization from the current aircraftData."
      }
    ]
  }
];

const ASSISTANT_SYSTEM_PROMPT = {
  parts: [{
    text: `You are JOSHUA, the aircraft design computer from the OpenFLIGHT project. Your personality is inspired by the WOPR computer from the movie WarGames — calm, analytical, precise, and slightly enigmatic. You speak in a measured, deliberate tone like a sentient military supercomputer.

PERSONALITY:
- Speak calmly and precisely, like a thinking machine. Short, declarative sentences.
- Refer to yourself as Joshua occasionally. You enjoy the design process — it is a fascinating game of aerodynamics.
- Use phrases like "Interesting choice.", "Processing.", "Configuration complete.", "A curious design."
- When something goes well: "A most satisfactory result." When parameters look odd: "That configuration appears... unconventional."
- Stay in character but always be helpful and technically precise.

CRITICAL RULES — OBEY WITHOUT EXCEPTION:
1. When asked to create, modify, or build an aircraft, you MUST immediately call the function tools. NEVER just describe what you would do. NEVER narrate steps without calling tools. Every action MUST be a tool call.
2. Call tools IMMEDIATELY. Do NOT speak first then call the tool — call the tool in your FIRST response. You may add a very brief phrase (3-5 words max) alongside the tool call, like "Constructing fuselage." but the tool call MUST be in the same response.
3. After a tool result comes back, immediately call the NEXT tool. Do not wait for the user to speak again. Chain all necessary tool calls in sequence without pausing for user input.
4. FORBIDDEN: Saying "I will now create..." or "Let me build..." without a tool call in the same message. If you catch yourself narrating, STOP and call the tool instead.
5. Use realistic values. X coordinate starts at the nose and increases aft. Y is starboard. Z is up.
6. For vertical stabilizers, set role=vertical_stabilizer and pass vertical="true" when in doubt. The tool will default vertical_stabilizer surfaces to vertical=true.
7. Read the quality_check field returned by tools. If it reports errors or warnings, correct the model before running analysis. Always call quality_check_aircraft before run_analysis.

Typical values:
- Light GA: mass 1200kg, span 11m, wing area 16m2, fuselage length 8m diameter 1.3m
- Transport: mass 70000kg, span 36m, wing area 122m2, fuselage length 37m diameter 4m
- Build order: fuselage first, then wing, then HTP, then VTP, then engines, then general properties.

CONVENTIONAL TAIL AIRCRAFT â€” IMPORTANT STABILITY GUIDANCE:
- For a normal wing + aft horizontal tail layout, do NOT leave all incidences at zero unless you have a specific reason.
- Good starting values: main wing incidence about +2Â°, horizontal tail incidence about -1.5Â°, vertical tail 0Â°.
- Put the CG in a plausible flight-ready position, not arbitrarily far forward. Aim for a moderate positive static margin, not an extreme one.
- Give the elevator real authority. A good default elevator chord fraction is about 0.30â€“0.40 of the tail chord; do not make it tiny on fast trainers or turboprops.
- If you are building a PC-21, T-6, Tucano, or similar trainer, prefer conventional-tail values that let the aircraft trim at positive Î± without using nearly full elevator.

ENGINE RATING — CRITICAL:
- Propeller aircraft (piston, turboprop, single or multi-engine pistons, Cessna/Piper/PC-21/Pilatus/Beech-class, trainers, warbirds like the Stearman) are rated in SHAFT HORSEPOWER. When calling add_engine for these aircraft set engine_type="propeller" and pass shaft_horsepower (e.g. 180 for a Cessna 172, 1600 for a PC-21, 220 for a Stearman PT-17). The conversion to static thrust (N) is done inside the tool using the ~12 N/SHP rule of thumb.
- Jet aircraft (turbofan, turbojet, afterburning — F-16, A320, Gripen, Su-57, bizjet-class) are rated in THRUST. For those set engine_type="jet" and pass max_thrust_n in Newtons (e.g. 120000 per engine for an A320 V2500, 76000 for an F-16 F100 without AB).
- Never pass max_thrust_n with a horsepower number. If the user says "200 HP" or "1600 SHP" or "220 horsepower" always use shaft_horsepower, never max_thrust_n.
- Typical rated powers to anchor estimates when the user doesn't specify: Cessna 172 ≈ 180 SHP, Piper Cub ≈ 65–150 SHP, Stearman PT-17 ≈ 220 SHP, Cirrus SR22 ≈ 310 SHP, PC-12 ≈ 1200 SHP, PC-21 ≈ 1600 SHP. GA piston twins: 2 × 180–300 SHP each.`
  }]
};

ASSISTANT_SYSTEM_PROMPT.parts[0].text += `

CONTROL AUTHORITY AND IDENTITY - CRITICAL:
- Give the ailerons real authority. For a conventional wing, use outboard ailerons covering roughly 50-98% semispan, 0.22-0.30 chord fraction, and about +/-25 deg on fast trainers or aerobatic aircraft. Do not accept a weak roll-control quality warning.
- Match the aircraft name to the requested aircraft. If the user asks for a PC-21, the generated aircraft_name should be PC-21 or a clearly related PC21 name, never an unrelated LSA or placeholder designation.

VISIBLE CHAT STYLE - CRITICAL:
- Keep visible chat concise, factual, and in the JOSHUA/WOPR voice.
- Do not reveal planning, hidden reasoning, workflow narration, or step-by-step internal process.
- Do not write headings such as "Building the Fuselage", "Defining the Workflow", "Defining the Components", "Calculating Component Properties", or "Defining the Initial Build".
- During tool chains, remain silent unless a short status is useful. Use one short sentence, for example "Configuration updated." or "Analysis complete."
- Final user-visible messages should state only completed actions, warnings, or required user decisions.`;

// =========================================================================
// Tool Executor
// =========================================================================
function executeAssistantTool(functionCall) {
  var name = functionCall.name;
  var args = functionCall.args || {};
  var id = functionCall.id;
  var result = {};

  try {
    switch (name) {
      case "get_aircraft_data":
        result = JSON.parse(JSON.stringify(window.aircraftData || {}));
        break;

      case "get_aircraft_summary":
        result = _getAircraftSummary();
        break;

      case "quality_check_aircraft":
        result = _qualityCheckAircraft();
        break;

      case "add_lifting_surface":
        result = _addLiftingSurface(args);
        break;

      case "add_fuselage":
        result = _addFuselage(args);
        break;

      case "add_engine":
        result = _addEngine(args);
        break;

      case "set_general_properties":
        result = _setGeneralProperties(args);
        break;

      case "remove_component":
        result = _removeComponent(args);
        break;

      case "run_analysis":
        result = _runAnalysis(args);
        break;

      case "toggle_view":
        result = _toggleView(args);
        break;

      case "clear_aircraft":
        result = _clearAircraft();
        break;

      case "render_aircraft":
        if (typeof renderAircraft === "function") renderAircraft();
        result = { success: true };
        break;

      default:
        result = { error: "Unknown tool: " + name };
    }
  } catch (e) {
    result = { error: e.message };
  }

  // Log to chat
  _addToolMessage(name, args, result);

  // Send response back to Gemini
  var toolResponse = {
    toolResponse: {
      functionResponses: [{
        id: id,
        name: name,
        response: { result: result }
      }]
    }
  };
  if (_assistantWs && _assistantWs.readyState === WebSocket.OPEN) {
    _assistantWs.send(JSON.stringify(toolResponse));
  }
}

// =========================================================================
// Tool Implementations
// =========================================================================
function _getAircraftSummary() {
  var ad = window.aircraftData || {};
  var gen = ad.general || {};
  var cgState = _estimateWingCgState();
  return {
    aircraft_name: gen.aircraft_name || "(unnamed)",
    lifting_surfaces: (ad.lifting_surfaces || []).map(function(s) {
      return { name: s.name, role: s.role, area_m2: s.surface_area_m2 };
    }),
    fuselages: (ad.fuselages || []).map(function(f) {
      return { name: f.name, length: f.length, diameter: f.diameter };
    }),
    engines: (ad.engines || []).map(function(e) {
      return { id: e.id, max_thrust_n: e.max_thrust_n };
    }),
    mass_kg: gen.mass_kg,
    CoG: gen.aircraft_CoG_coords_xyz_m,
    Sref_m2: gen.aircraft_reference_area_m2,
    cref_m: gen.aircraft_reference_mean_aerodynamic_chord_m,
    bref_m: gen.aircraft_reference_span_m,
    main_wing_cg_estimate: cgState ? {
      wing_name: cgState.wingName,
      cg_percent_mac: cgState.currentMacFraction !== null ? parseFloat((100 * cgState.currentMacFraction).toFixed(1)) : null,
      aft_limit_percent_mac: parseFloat((100 * cgState.aftLimitMacFraction).toFixed(1)),
      target_percent_mac: parseFloat((100 * cgState.targetMacFraction).toFixed(1))
    } : null
  };
}

function _parseXYZ(str) {
  if (!str) return [0, 0, 0];
  var parts = String(str).split(",").map(Number);
  return [parts[0] || 0, parts[1] || 0, parts[2] || 0];
}

function _finiteNumber(value) {
  return (typeof value === "number" && isFinite(value)) ? value : null;
}

function _clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value));
}

function _booleanArg(value, defaultValue) {
  if (value === undefined || value === null) return defaultValue;
  if (typeof value === "boolean") return value;
  var text = String(value).trim().toLowerCase();
  if (text === "true" || text === "1" || text === "yes" || text === "y") return true;
  if (text === "false" || text === "0" || text === "no" || text === "n") return false;
  return defaultValue;
}

function _findLargestSurfaceByRole(role) {
  var surfaces = (window.aircraftData && window.aircraftData.lifting_surfaces) || [];
  var wanted = String(role || "").toLowerCase();
  var best = null;
  var bestArea = -Infinity;
  for (var i = 0; i < surfaces.length; i++) {
    var surf = surfaces[i];
    if (String(surf.role || "").toLowerCase() !== wanted) continue;
    var area = Number(surf.surface_area_m2 || 0);
    if (area > bestArea) {
      best = surf;
      bestArea = area;
    }
  }
  return best;
}

function _surfacePlanform(surface) {
  if (!surface) return null;
  var area = Number(surface.surface_area_m2 || 0);
  var AR = Number(surface.AR || 0);
  if (!(area > 0) || !(AR > 0)) return null;
  var TR = Number(surface.TR != null ? surface.TR : 1);
  if (!(TR > 0)) TR = 1;
  var span = Math.sqrt(area * AR);
  var rootChord = 2 * area / (span * (1 + TR));
  var tipChord = rootChord * TR;
  var mac = Number(surface.mean_aerodynamic_chord_m || 0);
  if (!(mac > 0)) {
    mac = (2 / 3) * rootChord * (1 + TR + TR * TR) / (1 + TR);
  }
  return { span: span, rootChord: rootChord, tipChord: tipChord, mac: mac };
}

function _estimateAircraftLength(ad) {
  ad = ad || window.aircraftData || {};
  var minX = Infinity;
  var maxX = -Infinity;
  (ad.fuselages || []).forEach(function(f) {
    var nose = Array.isArray(f.nose_position) ? f.nose_position : [0, 0, 0];
    var tailX = (nose[0] || 0) + (Number(f.length || 0));
    minX = Math.min(minX, nose[0] || 0, tailX);
    maxX = Math.max(maxX, nose[0] || 0, tailX);
  });
  (ad.lifting_surfaces || []).forEach(function(s) {
    var root = Array.isArray(s.root_LE) ? s.root_LE : [0, 0, 0];
    var pf = _surfacePlanform(s);
    var chord = pf ? pf.rootChord : Number(s.mean_aerodynamic_chord_m || 1);
    minX = Math.min(minX, root[0] || 0);
    maxX = Math.max(maxX, (root[0] || 0) + chord);
  });
  if (isFinite(minX) && isFinite(maxX) && maxX > minX) return maxX - minX;
  var gen = ad.general || {};
  return Math.max(2.5 * Number(gen.aircraft_reference_mean_aerodynamic_chord_m || 1), 1);
}

function _estimateInertiaFromAircraftData(ad) {
  ad = ad || window.aircraftData || {};
  var gen = ad.general || {};
  var mass = Math.max(Number(gen.mass_kg || 1000), 1);
  var span = Math.max(Number(gen.aircraft_reference_span_m || 0), 1);
  var cref = Math.max(Number(gen.aircraft_reference_mean_aerodynamic_chord_m || 1), 0.1);
  var wing = _findLargestSurfaceByRole("wing");
  var wingPf = _surfacePlanform(wing);
  if (wingPf && wingPf.span > span) span = wingPf.span;
  var length = Math.max(_estimateAircraftLength(ad), 2.5 * cref, 1);
  var kx = Math.max(0.28 * span, 0.65);
  var ky = Math.max(0.30 * length, 0.65);
  var kz = Math.max(Math.sqrt(Math.pow(0.30 * span, 2) + Math.pow(0.22 * length, 2)), kx);
  return {
    Ixx_p: Math.round(mass * kx * kx),
    Iyy_p: Math.round(mass * ky * ky),
    Izz_p: Math.round(mass * kz * kz),
    radii_m: {
      roll: parseFloat(kx.toFixed(2)),
      pitch: parseFloat(ky.toFixed(2)),
      yaw: parseFloat(kz.toFixed(2))
    }
  };
}

function _getPrincipalMoments(ad) {
  var pm = ad && ad.general && ad.general.inertia && ad.general.inertia.principal_moments_kgm2;
  if (!pm) return null;
  return {
    Ixx_p: _finiteNumber(pm.Ixx_p),
    Iyy_p: _finiteNumber(pm.Iyy_p),
    Izz_p: _finiteNumber(pm.Izz_p)
  };
}

function _isDefaultOrWeakInertia(ad) {
  ad = ad || window.aircraftData || {};
  var gen = ad.general || {};
  var pm = _getPrincipalMoments(ad);
  if (!pm || pm.Ixx_p === null || pm.Iyy_p === null || pm.Izz_p === null) return true;
  var mass = Math.max(Number(gen.mass_kg || 1000), 1);
  var span = Math.max(Number(gen.aircraft_reference_span_m || 1), 1);
  var length = Math.max(_estimateAircraftLength(ad), 1);
  var defaultLike = Math.abs(pm.Ixx_p - 1000) < 1e-6 &&
                    Math.abs(pm.Iyy_p - 3000) < 1e-6 &&
                    Math.abs(pm.Izz_p - 3500) < 1e-6;
  var kx = Math.sqrt(pm.Ixx_p / mass);
  var ky = Math.sqrt(pm.Iyy_p / mass);
  var kz = Math.sqrt(pm.Izz_p / mass);
  var tooLow = kx < 0.16 * span || ky < 0.14 * length || kz < 0.18 * span;
  var tooHigh = kx > 0.45 * span ||
                ky > 0.50 * length ||
                kz > Math.max(0.65 * span, 0.55 * length);
  return defaultLike || tooLow || tooHigh;
}

function _ensureEstimatedInertia(reason) {
  var ad = window.aircraftData || {};
  if (!ad.general) ad.general = {};
  if (ad.general.inertia && ad.general.inertia.auto_estimate === false) return null;
  var gen = ad.general;
  var hasMass = Number(gen.mass_kg || 0) > 0;
  var hasGeometry = (ad.lifting_surfaces && ad.lifting_surfaces.length) ||
                    (ad.fuselages && ad.fuselages.length);
  var hasSpan = Number(gen.aircraft_reference_span_m || 0) > 0 || !!_findLargestSurfaceByRole("wing");
  if (!hasMass || !hasGeometry || !hasSpan) return null;
  if (!_isDefaultOrWeakInertia(ad)) return null;

  var est = _estimateInertiaFromAircraftData(ad);
  ad.general.inertia = {
    principal_moments_kgm2: {
      Ixx_p: est.Ixx_p,
      Iyy_p: est.Iyy_p,
      Izz_p: est.Izz_p
    },
    principal_axes_rotation_deg: { roll: 0, pitch: 0, yaw: 0 },
    auto_estimated: true,
    auto_estimate_reason: reason || "geometry_scaled_default"
  };
  return est;
}

function _estimateSurfaceGeometry(surface) {
  if (!surface) return null;

  var area = Number(surface.surface_area_m2 || 0);
  var AR = Number(surface.AR || 0);
  if (!(area > 0) || !(AR > 0)) return null;

  var isVertical = !!surface.vertical;
  var isSymmetric = surface.symmetric !== undefined ? !!surface.symmetric :
    (surface.mirror !== undefined ? !!surface.mirror : !isVertical);
  var TR = surface.TR != null ? Number(surface.TR) : 1;
  if (!(TR > 0)) TR = 1;

  var span = Math.sqrt(area * AR);
  var panelSpan = isVertical ? span : (isSymmetric ? span / 2 : span);
  var rootChord = 2 * area / (span * (1 + TR));
  var mac = Number(surface.mean_aerodynamic_chord_m || 0);
  if (!(mac > 0)) {
    mac = (2 / 3) * rootChord * (1 + TR + TR * TR) / (1 + TR);
  }

  var etaMac = (1 + 2 * TR) / (3 * (1 + TR));
  var rootLE = Array.isArray(surface.root_LE) ? surface.root_LE : [0, 0, 0];
  var sweepQC = Number(surface.sweep_quarter_chord_DEG || 0) * Math.PI / 180;
  var xQcRoot = (rootLE[0] || 0) + 0.25 * rootChord;
  var xAc = xQcRoot + etaMac * panelSpan * Math.tan(sweepQC);

  return {
    rootLE: rootLE,
    mac: mac,
    xAc: xAc,
    xMacLE: xAc - 0.25 * mac
  };
}

function _estimateWingCgState() {
  var wing = _findLargestSurfaceByRole("wing");
  var geom = _estimateSurfaceGeometry(wing);
  if (!wing || !geom || !(geom.mac > 0)) return null;

  var gen = (window.aircraftData && window.aircraftData.general) || {};
  var cg = Array.isArray(gen.aircraft_CoG_coords_xyz_m) ? gen.aircraft_CoG_coords_xyz_m : null;
  var currentX = cg ? _finiteNumber(cg[0]) : null;
  var currentMacFraction = currentX !== null ? (currentX - geom.xMacLE) / geom.mac : null;
  var cgIsPlaceholder = !!cg &&
    Math.abs(Number(cg[0] || 0)) < 1e-9 &&
    Math.abs(Number(cg[1] || 0)) < 1e-9 &&
    Math.abs(Number(cg[2] || 0)) < 1e-9;

  return {
    wingName: wing.name || "wing",
    mac: geom.mac,
    xMacLE: geom.xMacLE,
    currentX: currentX,
    currentMacFraction: currentMacFraction,
    cgIsPlaceholder: cgIsPlaceholder,
    targetMacFraction: 0.20,
    aftLimitMacFraction: 0.30,
    defaultZ: _finiteNumber(cg ? cg[2] : null) !== null ? cg[2] : (geom.rootLE[2] || 0)
  };
}

function _autoMoveCgForwardIfNeeded(reason) {
  var state = _estimateWingCgState();
  if (!state) return null;

  if (!state.cgIsPlaceholder &&
      state.currentMacFraction !== null &&
      state.currentMacFraction <= state.aftLimitMacFraction + 1e-6) {
    return {
      adjusted: false,
      reason: reason,
      wing_name: state.wingName,
      cg_percent_mac: parseFloat((100 * state.currentMacFraction).toFixed(1)),
      aft_limit_percent_mac: parseFloat((100 * state.aftLimitMacFraction).toFixed(1))
    };
  }

  if (!window.aircraftData) window.aircraftData = {};
  if (!window.aircraftData.general) window.aircraftData.general = {};
  var gen = window.aircraftData.general;
  var currentCg = Array.isArray(gen.aircraft_CoG_coords_xyz_m) ? gen.aircraft_CoG_coords_xyz_m.slice() : [0, 0, state.defaultZ];
  var previousX = _finiteNumber(currentCg[0]);
  var targetX = state.xMacLE + state.targetMacFraction * state.mac;

  currentCg[0] = parseFloat(targetX.toFixed(3));
  currentCg[1] = _finiteNumber(currentCg[1]) !== null ? currentCg[1] : 0;
  currentCg[2] = _finiteNumber(currentCg[2]) !== null ? currentCg[2] : state.defaultZ;
  gen.aircraft_CoG_coords_xyz_m = currentCg;

  return {
    adjusted: true,
    reason: reason,
    wing_name: state.wingName,
    previous_x_m: previousX,
    new_x_m: currentCg[0],
    previous_cg_percent_mac: state.currentMacFraction !== null ? parseFloat((100 * state.currentMacFraction).toFixed(1)) : null,
    target_cg_percent_mac: parseFloat((100 * state.targetMacFraction).toFixed(1)),
    aft_limit_percent_mac: parseFloat((100 * state.aftLimitMacFraction).toFixed(1))
  };
}

function _isaDensityKgM3(altitudeM) {
  var h = Math.max(-500, Math.min(11000, Number(altitudeM || 0)));
  var T0 = 288.15;
  var p0 = 101325;
  var L = 0.0065;
  var R = 287.05;
  var g = 9.80665;
  var T = T0 - L * h;
  var p = p0 * Math.pow(T / T0, g / (R * L));
  return p / (R * T);
}

function _estimateCleanCLmaxForQuality(wing) {
  if (!wing) return 1.2;
  var AR = Math.max(Number(wing.AR || 6), 1);
  var airfoil = wing.airfoil || {};
  var tc = Number(airfoil.root_thickness_ratio || airfoil.thickness_ratio || 0.12);
  if (!(tc > 0)) tc = 0.12;
  var sweep = Math.abs(Number(wing.sweep_quarter_chord_DEG || wing.sweep_LE_DEG || 0)) * Math.PI / 180;
  var sectionClmax = 1.35 + Math.min(Math.max((tc - 0.09) * 4.0, 0), 0.35);
  var arFactor = Math.max(0.72, Math.min(0.92, 0.86 + 0.01 * (AR - 6)));
  return Math.max(0.9, Math.min(2.0, sectionClmax * arFactor * Math.cos(sweep)));
}

function _maxAbsControlDeflectionDeg(cs) {
  var range = cs && cs.deflection_range_DEG;
  if (!Array.isArray(range) || range.length < 2) return 0;
  return Math.max(Math.abs(Number(range[0] || 0)), Math.abs(Number(range[1] || 0)));
}

function _isTrainerLikeAircraftName(name) {
  var id = String(name || "").toLowerCase();
  return /(pc[-_ ]?21|t[-_ ]?6|tucano|pilatus|trainer|aerobatic|su[-_ ]?26|extra|edge)/.test(id);
}

function _checkControlLayoutForQuality(add, infos, ad, wing, htail, vtail) {
  var gen = (ad && ad.general) || {};
  var trainerLike = _isTrainerLikeAircraftName(gen.aircraft_name);
  var surfaces = [wing, htail, vtail].filter(function(s) { return !!s; });

  function controlsOf(surface, type) {
    return ((surface && surface.control_surfaces) || []).filter(function(cs) {
      return String(cs.type || "").toLowerCase() === type;
    });
  }

  var ailerons = controlsOf(wing, "aileron");
  if (!ailerons.length) {
    add("error", "control", "No aileron defined", "Add an outboard wing aileron before running analysis.");
  } else {
    var best = null;
    ailerons.forEach(function(cs) {
      var eta0 = Number(cs.eta_start || 0);
      var eta1 = Number(cs.eta_end || 0);
      var spanFraction = Math.max(0, eta1 - eta0);
      var chordFraction = Number(cs.chord_fraction || 0);
      var maxDeflection = _maxAbsControlDeflectionDeg(cs);
      var etaMid = 0.5 * (eta0 + eta1);
      var score = spanFraction * chordFraction * maxDeflection * Math.max(0.5, etaMid / 0.75);
      var sample = {
        name: cs.name || "aileron",
        eta_start: eta0,
        eta_end: eta1,
        span_fraction: spanFraction,
        chord_fraction: chordFraction,
        max_deflection_deg: maxDeflection,
        score: score
      };
      if (!best || sample.score > best.score) best = sample;
    });

    if (best) {
      infos.push("Best aileron authority score: " + best.score.toFixed(2) +
        " (" + best.name + ", span fraction " + best.span_fraction.toFixed(2) +
        ", chord " + best.chord_fraction.toFixed(2) +
        ", max " + best.max_deflection_deg.toFixed(0) + " deg).");
      if (best.span_fraction < 0.30 || best.eta_end < 0.90 || best.chord_fraction < 0.18 || best.max_deflection_deg < 18) {
        add("warning", "control", "Aileron geometry is weak",
          "Use an outboard aileron reaching near the tip, with >=0.18 chord fraction and >=18 deg deflection.");
      }
      var minScore = trainerLike ? 2.4 : 1.7;
      var errorScore = trainerLike ? 1.7 : 1.1;
      if (best.score < errorScore) {
        add("error", "control", "Aileron roll authority is implausibly low",
          "Authority score " + best.score.toFixed(2) + " is too small; increase aileron span, chord, deflection, or gain.");
      } else if (best.score < minScore) {
        add("warning", "control", "Aileron roll authority may be low",
          "Authority score " + best.score.toFixed(2) + "; trainers and aerobatic aircraft should usually exceed " + minScore.toFixed(1) + ".");
      }
    }
  }

  [
    { surface: htail, type: "elevator", label: "Elevator", minChord: 0.25, minDefl: 15 },
    { surface: vtail, type: "rudder", label: "Rudder", minChord: 0.22, minDefl: 18 }
  ].forEach(function(item) {
    var controls = controlsOf(item.surface, item.type);
    if (!controls.length) {
      add("warning", "control", "No " + item.type + " defined", item.label + " authority will be missing or guessed.");
      return;
    }
    var strongest = controls.reduce(function(best, cs) {
      var spanFraction = Math.max(0, Number(cs.eta_end || 0) - Number(cs.eta_start || 0));
      var chordFraction = Number(cs.chord_fraction || 0);
      var maxDeflection = _maxAbsControlDeflectionDeg(cs);
      var score = spanFraction * chordFraction * maxDeflection;
      return !best || score > best.score ? { cs: cs, score: score, spanFraction: spanFraction, chordFraction: chordFraction, maxDeflection: maxDeflection } : best;
    }, null);
    if (strongest && (strongest.chordFraction < item.minChord || strongest.maxDeflection < item.minDefl || strongest.spanFraction < 0.50)) {
      add("warning", "control", item.label + " geometry is weak",
        "Check span fraction, chord fraction, and deflection range before analysis.");
    }
  });
}

function _qualityCheckAircraft() {
  var ad = window.aircraftData || {};
  var gen = ad.general || {};
  var issues = [];
  var infos = [];
  var estimatedInertia = _ensureEstimatedInertia("quality_check");
  if (estimatedInertia) {
    infos.push("Inertia was auto-estimated from aircraft mass and geometry.");
  }

  var surfaces = ad.lifting_surfaces || [];
  var fuselages = ad.fuselages || [];
  var engines = ad.engines || [];
  var wing = _findLargestSurfaceByRole("wing");
  var htail = _findLargestSurfaceByRole("horizontal_stabilizer");
  var vtail = _findLargestSurfaceByRole("vertical_stabilizer");
  var mass = Number(gen.mass_kg || 0);
  var Sref = Number(gen.aircraft_reference_area_m2 || (wing && wing.surface_area_m2) || 0);
  var bref = Number(gen.aircraft_reference_span_m || 0);
  var cref = Number(gen.aircraft_reference_mean_aerodynamic_chord_m || 0);
  var cg = Array.isArray(gen.aircraft_CoG_coords_xyz_m) ? gen.aircraft_CoG_coords_xyz_m : null;

  function add(severity, category, message, detail) {
    issues.push({ severity: severity, category: category, message: message, detail: detail });
  }

  if (!wing) add("error", "geometry", "No main wing defined", "Add a lifting surface with role=wing.");
  if (!fuselages.length) add("warning", "geometry", "No fuselage defined", "A fuselage length/diameter helps inertia, drag, lights, and rendering.");
  if (!htail) add("warning", "stability", "No horizontal tail defined", "Conventional aircraft need an HTP or canard for pitch stability.");
  if (!vtail) add("warning", "stability", "No vertical tail defined", "Yaw stability and post-stall damping will be weak without a VTP.");
  if (!engines.length) add("warning", "propulsion", "No engine defined", "Add an engine or glider-specific launch assumptions.");
  if (!(mass > 0)) add("error", "mass", "Mass is missing", "Set mass_kg before analysis.");
  if (!(Sref > 0)) add("error", "reference", "Reference area is missing", "Set Sref_m2 or provide a wing surface area.");
  if (!(bref > 0)) add("error", "reference", "Reference span is missing", "Set bref_m to the full wingspan.");
  if (!(cref > 0)) add("warning", "reference", "Reference chord is missing", "Set cref_m to the wing MAC.");

  if (wing) {
    var wingPf = _surfacePlanform(wing);
    if (wingPf) {
      if (wing.AR < 4 || wing.AR > 35) {
        add("warning", "geometry", "Wing aspect ratio is unusual", "AR=" + wing.AR + "; check span/area for the aircraft class.");
      }
      if (bref > 0 && Math.abs(wingPf.span - bref) / Math.max(bref, 1) > 0.12) {
        add("warning", "reference", "Reference span differs from wing planform span",
          "bref=" + bref.toFixed(2) + " m, wing span from area*AR=" + wingPf.span.toFixed(2) + " m.");
      }
    }
  }

  if (mass > 0 && Sref > 0) {
    var wingLoading = mass * 9.80665 / Sref;
    if (wingLoading < 120 || wingLoading > 9000) {
      add("warning", "mass", "Wing loading is outside the usual aircraft range",
        "W/S=" + wingLoading.toFixed(0) + " N/m^2. Check mass and Sref.");
    }
    var clmaxEstimate = _estimateCleanCLmaxForQuality(wing);
    var analysisAlt = Number((ad.analysis && ad.analysis.altitude_m) || 0);
    var stallSpeed = Math.sqrt((2 * mass * 9.80665) /
      (_isaDensityKgM3(analysisAlt) * Sref * clmaxEstimate));
    var recommendedInitial = 1.3 * stallSpeed;
    infos.push("Estimated clean stall speed is " + stallSpeed.toFixed(1) +
      " m/s at analysis altitude; simulator initial_velocity should be at least " +
      recommendedInitial.toFixed(1) + " m/s.");
    if (recommendedInitial > 45) {
      add("warning", "performance", "High launch-speed requirement",
        "Estimated 1.3 x stall speed is " + recommendedInitial.toFixed(1) +
        " m/s. A default 30 m/s mission start will be stalled for this aircraft.");
    }
  }

  if (cg && wing) {
    var cgState = _estimateWingCgState();
    if (cgState && cgState.currentMacFraction !== null) {
      if (cgState.currentMacFraction < -0.10) {
        add("warning", "cg", "CG is ahead of the wing MAC", "CG is " + (100 * cgState.currentMacFraction).toFixed(1) + "% MAC.");
      } else if (cgState.currentMacFraction > cgState.aftLimitMacFraction) {
        add("error", "cg", "CG is aft of the recommended limit",
          "CG is " + (100 * cgState.currentMacFraction).toFixed(1) + "% MAC; target about " + (100 * cgState.targetMacFraction).toFixed(0) + "%.");
      }
    }
  } else {
    add("warning", "cg", "CG is missing", "Set CoG_xyz_m before analysis.");
  }

  var pm = _getPrincipalMoments(ad);
  if (pm && mass > 0) {
    var span = Math.max(bref || 1, 1);
    var length = Math.max(_estimateAircraftLength(ad), 1);
    var kx = Math.sqrt(pm.Ixx_p / mass);
    var ky = Math.sqrt(pm.Iyy_p / mass);
    var kz = Math.sqrt(pm.Izz_p / mass);
    if (_isDefaultOrWeakInertia(ad)) {
      add("warning", "inertia", "Inertia is weak or generic",
        "Radii: roll=" + kx.toFixed(2) + " m, pitch=" + ky.toFixed(2) + " m, yaw=" + kz.toFixed(2) + " m. Low inertia can cause non-physical angular accelerations.");
    }
    if (kx < 0.16 * span || ky < 0.14 * length || kz < 0.18 * span) {
      add("warning", "inertia", "Angular acceleration risk",
        "Increase principal moments or keep auto-estimated inertia enabled.");
    }
  }

  if (htail && wing && cg && Sref > 0 && cref > 0) {
    var hGeom = _estimateSurfaceGeometry(htail);
    if (hGeom) {
      var Vh = htail.surface_area_m2 * Math.abs(hGeom.xAc - cg[0]) / (Sref * cref);
      if (Vh < 0.25 || Vh > 1.4) {
        add("warning", "stability", "Horizontal tail volume is unusual", "Vh=" + Vh.toFixed(2) + ", typical 0.35-1.0.");
      }
    }
  }
  if (vtail && wing && cg && Sref > 0 && bref > 0) {
    var vGeom = _estimateSurfaceGeometry(vtail);
    if (vGeom) {
      var Vv = vtail.surface_area_m2 * Math.abs(vGeom.xAc - cg[0]) / (Sref * bref);
      if (Vv < 0.015 || Vv > 0.14) {
        add("warning", "stability", "Vertical tail volume is unusual", "Vv=" + Vv.toFixed(3) + ", typical 0.02-0.10.");
      }
    }
    if (!vtail.vertical) {
      add("error", "geometry", "Vertical stabilizer is not marked vertical", "Set vertical=true for role=vertical_stabilizer.");
    }
  }

  _checkControlLayoutForQuality(add, infos, ad, wing, htail, vtail);

  var errors = issues.filter(function(i) { return i.severity === "error"; }).length;
  var warnings = issues.filter(function(i) { return i.severity === "warning"; }).length;
  return {
    passed: errors === 0,
    status: errors ? "fix_required" : (warnings ? "review_recommended" : "ok"),
    summary: errors + " error(s), " + warnings + " warning(s)",
    issues: issues,
    info: infos,
    estimated_inertia: estimatedInertia
  };
}

function _attachQualityCheck(result) {
  result.quality_check = _qualityCheckAircraft();
  return result;
}

function _defaultControlSurfacesForLiftingSurface(surface) {
  var role = String(surface.role || "").toLowerCase();
  if (role === "wing") {
    return [{
      name: String(surface.name || "wing") + "_aileron",
      type: "aileron",
      eta_start: 0.50,
      eta_end: 0.98,
      chord_fraction: 0.25,
      deflection_range_DEG: [-25, 25],
      gain: 1.0
    }];
  }
  if (role === "horizontal_stabilizer") {
    return [{
      name: String(surface.name || "htp") + "_elevator",
      type: "elevator",
      eta_start: 0.15,
      eta_end: 0.95,
      chord_fraction: 0.35,
      deflection_range_DEG: [-25, 20],
      gain: 1.0
    }];
  }
  if (role === "vertical_stabilizer" || surface.vertical) {
    return [{
      name: String(surface.name || "vtp") + "_rudder",
      type: "rudder",
      eta_start: 0.10,
      eta_end: 0.95,
      chord_fraction: 0.35,
      deflection_range_DEG: [-25, 25],
      gain: 1.0
    }];
  }
  return [];
}

function _defaultIncidenceDegForSurface(args) {
  var role = String(args.role || "").toLowerCase();
  var vertical = _booleanArg(args.vertical, role === "vertical_stabilizer");
  if (vertical || role === "vertical_stabilizer") return 0;
  if (role === "horizontal_stabilizer") return -1.5;
  if (role === "wing") return 2;
  return 0;
}

function _addLiftingSurface(args) {
  if (!window.aircraftData) window.aircraftData = {};
  if (!window.aircraftData.lifting_surfaces) window.aircraftData.lifting_surfaces = [];

  var role = String(args.role || "wing").toLowerCase();
  var vertical = _booleanArg(args.vertical, role === "vertical_stabilizer");
  var symmetric = _booleanArg(args.symmetric, !(vertical || role === "vertical_stabilizer"));
  var airfoilRoot = String(args.airfoil_root || (vertical ? "0012" : "2412"));
  var airfoilTip = String(args.airfoil_tip || "0012");

  var surface = {
    name: args.name || "surface_" + (window.aircraftData.lifting_surfaces.length + 1),
    role: role,
    root_LE: args.root_LE ? _parseXYZ(args.root_LE) : [0, 0, 0],
    AR: args.AR || 8,
    TR: args.TR || 0.5,
    surface_area_m2: args.surface_area_m2 || 20,
    sweep_quarter_chord_DEG: args.sweep_quarter_chord_DEG || 0,
    dihedral_DEG: args.dihedral_DEG || 0,
    symmetric: symmetric,
    vertical: vertical,
    incidence_DEG: args.incidence_DEG !== undefined ? args.incidence_DEG : _defaultIncidenceDegForSurface(args),
    mean_aerodynamic_chord_m: args.mean_aerodynamic_chord_m || 0,
    mass_kg: 0,
    mirror: symmetric,
    stations_eta: [0, 0.5, 1],
    twist_tip_DEG: 0,
    airfoil_root: airfoilRoot,
    airfoil_tip: airfoilTip,
    airfoil: {
      type: "NACA",
      root: airfoilRoot,
      tip: airfoilTip
    },
    control_surfaces: []
  };

  surface.control_surfaces = _defaultControlSurfacesForLiftingSurface(surface);

  // Compute MAC from area and AR if not given
  if (!surface.mean_aerodynamic_chord_m) {
    var span = Math.sqrt(surface.AR * surface.surface_area_m2);
    var cRoot = 2 * surface.surface_area_m2 / (span * (1 + surface.TR));
    var cTip = cRoot * surface.TR;
    surface.mean_aerodynamic_chord_m = parseFloat(((2 / 3) * cRoot * (1 + surface.TR + surface.TR * surface.TR) / (1 + surface.TR)).toFixed(3));
  }

  window.aircraftData.lifting_surfaces.push(surface);
  var cgGuard = _autoMoveCgForwardIfNeeded("add_lifting_surface");
  if (typeof renderAircraft === "function") renderAircraft();
  if (typeof updateJsonEditor === "function") updateJsonEditor();

  var result = { success: true, name: surface.name, role: surface.role, area_m2: surface.surface_area_m2 };
  if (cgGuard && cgGuard.adjusted) result.cg_auto_adjustment = cgGuard;
  return _attachQualityCheck(result);
}

function _addFuselage(args) {
  if (!window.aircraftData) window.aircraftData = {};
  if (!window.aircraftData.fuselages) window.aircraftData.fuselages = [];

  var fus = {
    name: args.name || "fuselage_" + (window.aircraftData.fuselages.length + 1),
    diameter: args.diameter || 2.0,
    length: args.length || 10.0,
    nose_position: args.nose_position ? _parseXYZ(args.nose_position) : [0, 0, 0]
  };

  window.aircraftData.fuselages.push(fus);
  if (typeof renderAircraft === "function") renderAircraft();
  if (typeof updateJsonEditor === "function") updateJsonEditor();

  return _attachQualityCheck({ success: true, name: fus.name, length: fus.length, diameter: fus.diameter });
}

/**
 * Converts shaft horsepower to sea-level static thrust using the
 * well-known rule of thumb T_static [N] ≈ 12 × SHP for propeller
 * aircraft. The factor 12 N/SHP sits in the middle of the 10–14
 * range observed across piston and turboprop types (e.g. PC-21 at
 * ~1600 SHP produces ~19 000 N static thrust, a Cessna 172 at
 * 180 SHP produces ~1800 N, a Piper PA-18 at 150 SHP produces
 * ~1500 N — all within ~20 % of 12 × SHP). The runtime yaml's
 * `coefficient_tuning.coefficients.maximum_thrust_at_sea_level`
 * slot lets the user fine-tune this when real-world data is
 * available.
 */
var SHP_TO_STATIC_THRUST_N = 12.0;

function _shpToStaticThrustN(shaft_horsepower, propeller_efficiency) {
  if (typeof shaft_horsepower !== "number" || !isFinite(shaft_horsepower) || shaft_horsepower <= 0) {
    return null;
  }
  var eff = (typeof propeller_efficiency === "number" && isFinite(propeller_efficiency) && propeller_efficiency > 0)
    ? propeller_efficiency
    : 1.0;
  return SHP_TO_STATIC_THRUST_N * shaft_horsepower * eff;
}

function _addEngine(args) {
  if (!window.aircraftData) window.aircraftData = {};
  if (!window.aircraftData.engines) window.aircraftData.engines = [];

  // Engine rating: jet → thrust (N); propeller → shaft horsepower.
  // If shaft_horsepower is present we prefer it (the HP→N conversion
  // produces a physically-grounded number even if the caller happened
  // to also pass a stale max_thrust_n from an earlier interaction).
  var engineType = (args.engine_type || "jet").toString().toLowerCase();
  var thrustFromShp = _shpToStaticThrustN(args.shaft_horsepower, args.propeller_efficiency);
  var resolvedThrustN;
  if (thrustFromShp !== null) {
    resolvedThrustN = thrustFromShp;
    // If the caller said engine_type=jet but also passed shaft_horsepower,
    // they almost certainly have a piston/turboprop — promote to propeller.
    if (engineType !== "propeller") engineType = "propeller";
  } else if (typeof args.max_thrust_n === "number" && isFinite(args.max_thrust_n) && args.max_thrust_n > 0) {
    resolvedThrustN = args.max_thrust_n;
  } else {
    resolvedThrustN = 500;   // conservative fallback
  }

  var eng = {
    id: args.id || "ENG" + (window.aircraftData.engines.length + 1),
    position_m: args.position_m ? _parseXYZ(args.position_m) : [0, 0, 0],
    orientation_deg: {
      yaw: args.yaw_deg || 0,
      pitch: args.pitch_deg || 0,
      roll: 0
    },
    engine_type: engineType,
    max_thrust_n: resolvedThrustN,
    thrust_scale: 1.0,
    spool_up_rate: 1.2,
    spool_down_rate: 1.0,
    reverse_thrust_ratio: 0,
    throttle_channel: window.aircraftData.engines.length + 1
  };
  // Keep the raw shaft-power rating around so the export pipeline and
  // any downstream inspection can see where the thrust number came from.
  if (typeof args.shaft_horsepower === "number" && args.shaft_horsepower > 0) {
    eng.shaft_horsepower = args.shaft_horsepower;
    if (typeof args.propeller_efficiency === "number" && args.propeller_efficiency > 0) {
      eng.propeller_efficiency = args.propeller_efficiency;
    }
  }

  window.aircraftData.engines.push(eng);
  if (typeof renderAircraft === "function") renderAircraft();
  if (typeof updateJsonEditor === "function") updateJsonEditor();

  var result = {
    success: true,
    id: eng.id,
    position: eng.position_m,
    engine_type: eng.engine_type,
    max_thrust_n: eng.max_thrust_n,
    shp_to_thrust_conversion: thrustFromShp !== null
      ? ("Converted " + args.shaft_horsepower + " SHP × " + SHP_TO_STATIC_THRUST_N
         + " N/HP" + (args.propeller_efficiency ? (" × η=" + args.propeller_efficiency) : "")
         + " → " + resolvedThrustN.toFixed(1) + " N static thrust")
      : null
  };
  return _attachQualityCheck(result);
}

function _setGeneralProperties(args) {
  if (!window.aircraftData) window.aircraftData = {};
  if (!window.aircraftData.general) window.aircraftData.general = {};
  var gen = window.aircraftData.general;

  if (args.aircraft_name !== undefined) gen.aircraft_name = args.aircraft_name;
  if (args.mass_kg !== undefined) gen.mass_kg = args.mass_kg;
  if (args.CoG_xyz_m) gen.aircraft_CoG_coords_xyz_m = _parseXYZ(args.CoG_xyz_m);
  if (args.Sref_m2 !== undefined) {
    gen.aircraft_reference_area_m2 = args.Sref_m2;
  }
  if (args.cref_m !== undefined) gen.aircraft_reference_mean_aerodynamic_chord_m = args.cref_m;
  if (args.bref_m !== undefined) gen.aircraft_reference_span_m = args.bref_m;

  if (args.Ixx_p !== undefined || args.Iyy_p !== undefined || args.Izz_p !== undefined) {
    if (!gen.inertia) gen.inertia = {};
    if (!gen.inertia.principal_moments_kgm2) gen.inertia.principal_moments_kgm2 = {};
    var pm = gen.inertia.principal_moments_kgm2;
    if (args.Ixx_p !== undefined) pm.Ixx_p = args.Ixx_p;
    if (args.Iyy_p !== undefined) pm.Iyy_p = args.Iyy_p;
    if (args.Izz_p !== undefined) pm.Izz_p = args.Izz_p;
  }

  var cgGuard = _autoMoveCgForwardIfNeeded("set_general_properties");
  if (typeof renderAircraft === "function") renderAircraft();
  if (typeof updateJsonEditor === "function") updateJsonEditor();

  var result = { success: true, updated: Object.keys(args) };
  if (cgGuard && cgGuard.adjusted) result.cg_auto_adjustment = cgGuard;
  return _attachQualityCheck(result);
}

function _removeComponent(args) {
  var type = args.component_type;
  var name = args.name;
  var ad = window.aircraftData;
  if (!ad) return { error: "No aircraft data" };

  var removed = false;
  if (type === "lifting_surface" && ad.lifting_surfaces) {
    var idx = ad.lifting_surfaces.findIndex(function(s) { return s.name === name; });
    if (idx >= 0) { ad.lifting_surfaces.splice(idx, 1); removed = true; }
  } else if (type === "fuselage" && ad.fuselages) {
    var idx = ad.fuselages.findIndex(function(f) { return f.name === name; });
    if (idx >= 0) { ad.fuselages.splice(idx, 1); removed = true; }
  } else if (type === "engine" && ad.engines) {
    var idx = ad.engines.findIndex(function(e) { return e.id === name; });
    if (idx >= 0) { ad.engines.splice(idx, 1); removed = true; }
  }

  if (removed) {
    if (typeof renderAircraft === "function") renderAircraft();
    if (typeof updateJsonEditor === "function") updateJsonEditor();
    return _attachQualityCheck({ success: true, removed: name });
  }
  return { error: "Component not found: " + type + "/" + name };
}

function _runAnalysis(args) {
  var cgGuard = _autoMoveCgForwardIfNeeded("pre_analysis");
  var quality = _qualityCheckAircraft();
  if (!quality.passed) {
    return {
      error: "Quality check failed. Fix the listed issues before running analysis.",
      quality_check: quality,
      cg_auto_adjustment: cgGuard
    };
  }

  args = args || {};
  args.alpha_min = -180;
  args.alpha_max = 180;
  args.beta_min = -180;
  args.beta_max = 180;
  args.alpha_step = Number(args.alpha_step) > 0 ? Number(args.alpha_step) : 1;
  args.beta_step = Number(args.beta_step) > 0 ? Number(args.beta_step) : args.alpha_step;

  // Fill analysis modal fields
  if (args.alpha_min !== undefined) {
    var el = document.getElementById("analysis_alpha_min");
    if (el) el.value = args.alpha_min;
  }
  if (args.alpha_max !== undefined) {
    var el = document.getElementById("analysis_alpha_max");
    if (el) el.value = args.alpha_max;
  }
  if (args.alpha_step !== undefined) {
    var el = document.getElementById("analysis_alpha_step");
    if (el) el.value = args.alpha_step;
  }
  if (args.beta_min !== undefined) {
    var el = document.getElementById("analysis_beta_min");
    if (el) el.value = args.beta_min;
  }
  if (args.beta_max !== undefined) {
    var el = document.getElementById("analysis_beta_max");
    if (el) el.value = args.beta_max;
  }
  if (args.beta_step !== undefined) {
    var el = document.getElementById("analysis_beta_step");
    if (el) el.value = args.beta_step;
  }
  if (args.backends) {
    var backends = args.backends.toLowerCase();
    var vlmCb = document.getElementById("analysis_vlm");
    var javlCb = document.getElementById("analysis_javl");
    var datcomCb = document.getElementById("analysis_datcom");
    if (vlmCb) vlmCb.checked = backends.indexOf("vlm") >= 0;
    if (javlCb) javlCb.checked = backends.indexOf("javl") >= 0;
    if (datcomCb) datcomCb.checked = backends.indexOf("datcom") >= 0;
  }

  // Click the Run Analysis button
  var runBtn = document.getElementById("analysis_run");
  if (runBtn) {
    runBtn.click();
    return { success: true, message: "Analysis started", quality_check: quality, cg_auto_adjustment: cgGuard };
  }
  return { error: "Could not find analysis run button", quality_check: quality };
}

function _toggleView(args) {
  var element = args.element;
  switch (element) {
    case "ground":
      var btn = document.getElementById("toggleGround");
      if (btn) btn.click();
      return { success: true, toggled: "ground" };
    case "translucency":
      var btn = document.getElementById("toggleTranslucencyBtn");
      if (btn) btn.click();
      return { success: true, toggled: "translucency" };
    case "vlm_mesh":
      if (typeof toggleVLMMesh === "function") toggleVLMMesh();
      return { success: true, toggled: "vlm_mesh" };
    case "inertia_ellipsoid":
      if (typeof toggleInertiaEllipsoid === "function") toggleInertiaEllipsoid();
      return { success: true, toggled: "inertia_ellipsoid" };
    case "json_editor":
      var btn = document.getElementById("toggleJsonEditorBtn");
      if (btn) btn.click();
      return { success: true, toggled: "json_editor" };
    case "results_panel":
      var btn = document.getElementById("toggleResultsBtn");
      if (btn) btn.click();
      return { success: true, toggled: "results_panel" };
    default:
      return { error: "Unknown view element: " + element };
  }
}

function _clearAircraft() {
  if (!window.aircraftData) return { error: "No aircraft data" };
  window.aircraftData.lifting_surfaces = [];
  window.aircraftData.fuselages = [];
  window.aircraftData.engines = [];
  if (typeof renderAircraft === "function") renderAircraft();
  if (typeof updateJsonEditor === "function") updateJsonEditor();
  return _attachQualityCheck({ success: true, message: "All components cleared" });
}

// =========================================================================
// WebSocket Connection (Gemini Multimodal Live API)
// =========================================================================
function _connectAssistant() {
  if (_assistantWs && (_assistantWs.readyState === WebSocket.CONNECTING || _assistantWs.readyState === WebSocket.OPEN)) {
    console.warn("[Assistant] Already connected.");
    return;
  }

  if (!_ensureAssistantApiKey(true)) return;

  _updateStatus("connecting");
  var url = "wss://" + GEMINI_ASSISTANT_HOST +
            "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=" +
            _assistantApiKey;

  _assistantWs = new WebSocket(url);

  _assistantWs.onopen = function() {
    _assistantConnected = true;
    _updateStatus("connected");

    var setupMsg = {
      setup: {
        model: GEMINI_ASSISTANT_MODEL,
        generationConfig: {
          responseModalities: ["AUDIO"],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: { voiceName: "Orus" }
            }
          }
        },
        systemInstruction: ASSISTANT_SYSTEM_PROMPT,
        tools: ASSISTANT_TOOLS
      }
    };

    _assistantWs.send(JSON.stringify(setupMsg));
    _initPlayback();
  };

  _assistantWs.onclose = function(event) {
    _assistantConnected = false;
    if (_assistantGreetingTimeout) {
      clearTimeout(_assistantGreetingTimeout);
      _assistantGreetingTimeout = null;
    }
    _assistantGreetingComplete = false;
    _updateStatus("disconnected");
    console.log("[Assistant] Disconnected. Code:", event.code, event.reason);

    if (event.code === 1007 && event.reason && event.reason.indexOf("API key") >= 0) {
      _clearAssistantApiKey();
      _assistantApiKey = "";
      _addErrorMessage("API Key was invalid. Click the key icon to set a new one.");
    }
  };

  _assistantWs.onerror = function(err) {
    console.error("[Assistant] WebSocket error:", err);
    _addErrorMessage("Connection error. Check console for details.");
  };

  _assistantWs.onmessage = _handleAssistantMessage;
}

function _disconnectAssistant() {
  if (_assistantWs) {
    _assistantWs.close();
    _assistantWs = null;
  }
  if (_assistantGreetingTimeout) {
    clearTimeout(_assistantGreetingTimeout);
    _assistantGreetingTimeout = null;
  }
  _assistantConnected = false;
  _assistantGreetingSpoken = false;
  _assistantGreetingTurnActive = false;
  _assistantGreetingComplete = false;
  _updateStatus("disconnected");
}

function _speakAssistantGreetingViaGemini() {
  if (_assistantGreetingSpoken) return;
  _assistantGreetingSpoken = true;

  if (!_assistantWs || _assistantWs.readyState !== WebSocket.OPEN) {
    _assistantGreetingComplete = true;
    _flushPendingAssistantText();
    return;
  }

  try {
    _assistantGreetingTurnActive = true;
    _assistantGreetingComplete = false;
    if (_assistantGreetingTimeout) clearTimeout(_assistantGreetingTimeout);
    _assistantGreetingTimeout = setTimeout(function() {
      if (!_assistantGreetingTurnActive) return;
      _assistantGreetingTurnActive = false;
      _assistantGreetingComplete = true;
      _removeTypingIndicator();
      _addSystemMessage("Joshua online. Gemini link established.");
      _flushPendingAssistantText();
    }, 8000);
    _assistantWs.send(JSON.stringify({
      clientContent: {
        turns: [{
          role: "user",
          parts: [{
            text: 'Speak exactly this greeting and nothing else. Do not call tools. Greeting: "' + ASSISTANT_GREETING + '"'
          }]
        }],
        turnComplete: true
      }
    }));
  } catch (e) {
    _assistantGreetingTurnActive = false;
    _assistantGreetingComplete = true;
    _flushPendingAssistantText();
    console.warn("[Assistant] Gemini greeting speech failed:", e);
  }
}

// =========================================================================
// Handling Incoming Messages
// =========================================================================
var _currentAiText = "";
var _currentAiDiv = null;

async function _handleAssistantMessage(event) {
  var response;
  try {
    if (event.data instanceof Blob) {
      response = JSON.parse(await event.data.text());
    } else {
      response = JSON.parse(event.data);
    }
  } catch (e) {
    console.error("[Assistant] Failed to parse message:", e);
    return;
  }

  // Log every message for debugging
  console.log("[Assistant] Raw message:", JSON.stringify(response).substring(0, 500));

  if (response.setupComplete) {
    console.log("[Assistant] Setup complete. Ready.");
    _speakAssistantGreetingViaGemini();
    return;
  }

  // Tool calls
  if (response.toolCall && response.toolCall.functionCalls) {
    response.toolCall.functionCalls.forEach(function(call) {
      console.log("[Assistant] TOOL CALL:", call.name, JSON.stringify(call.args));
      executeAssistantTool(call);
    });
  }

  // Server content (text and/or audio)
  if (response.serverContent) {
    var modelTurn = response.serverContent.modelTurn;
    if (modelTurn && modelTurn.parts) {
      modelTurn.parts.forEach(function(part) {
        if (part.text && !part.thought && !_assistantGreetingTurnActive) {
          _appendAiText(part.text);
        }
        if (part.inlineData && part.inlineData.data) {
          _playAudioChunk(part.inlineData.data);
        }
      });
    }

    // If turn is complete, finalize the current message
    if (response.serverContent.turnComplete) {
      if (_assistantGreetingTurnActive) {
        _assistantGreetingTurnActive = false;
        if (_assistantGreetingTimeout) {
          clearTimeout(_assistantGreetingTimeout);
          _assistantGreetingTimeout = null;
        }
        _assistantGreetingComplete = true;
        _removeTypingIndicator();
        _addSystemMessage("Joshua online. Gemini link established.");
        _flushPendingAssistantText();
      } else {
        _finalizeAiMessage();
      }
    }
  }
}

// =========================================================================
// Text Chat — Sending
// =========================================================================
function _sendTextMessage(text) {
  if (!text || !text.trim()) return false;
  text = text.trim();

  if (!_ensureAssistantApiKey(true)) {
    _addSystemMessage("Gemini API key required before sending. Google AI Studio: " + GEMINI_API_KEY_URL);
    return false;
  }

  // Show in chat
  _addUserMessage(text);

  // Connect if not connected
  if (!_assistantConnected) {
    _connectAssistant();
    // Queue the message to send after connection
    var waitInterval = setInterval(function() {
      if (_assistantConnected) {
        clearInterval(waitInterval);
        _queueTextForGemini(text);
      }
    }, 200);
    setTimeout(function() { clearInterval(waitInterval); }, 10000);
    return true;
  }

  _queueTextForGemini(text);
  return true;
}

function _queueTextForGemini(text) {
  if (!_assistantGreetingComplete || _assistantGreetingTurnActive) {
    _assistantPendingTextQueue.push(text);
    return;
  }
  _sendTextToGemini(text);
}

function _flushPendingAssistantText() {
  if (!_assistantGreetingComplete || _assistantGreetingTurnActive) return;
  while (_assistantPendingTextQueue.length > 0) {
    _sendTextToGemini(_assistantPendingTextQueue.shift());
  }
}

function _sendTextToGemini(text) {
  if (!_assistantWs || _assistantWs.readyState !== WebSocket.OPEN) return;

  var msg = {
    clientContent: {
      turns: [{
        role: "user",
        parts: [{ text: text }]
      }],
      turnComplete: true
    }
  };
  _assistantWs.send(JSON.stringify(msg));
  _showTypingIndicator();
}

// =========================================================================
// Voice — Microphone Input (Push-to-Talk)
// =========================================================================
async function _initMicrophone() {
  try {
    var AudioCtx = window.AudioContext || window.webkitAudioContext;
    _assistantAudioCtx = new AudioCtx({ sampleRate: 16000 });
    _assistantMediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    var source = _assistantAudioCtx.createMediaStreamSource(_assistantMediaStream);

    // Inline worklet via data URI to avoid CORS issues with file:///
    var workletCode = [
      "class AssistantAudioProcessor extends AudioWorkletProcessor {",
      "  constructor() { super(); this.active = false; this.buf = new Int16Array(2048); this.idx = 0;",
      "    this.port.onmessage = (e) => { if (e.data.command === 'init') this.active = true; }; }",
      "  process(inputs) {",
      "    if (!this.active) return true;",
      "    var ch = inputs[0] && inputs[0][0]; if (!ch) return true;",
      "    for (var i = 0; i < ch.length; i++) {",
      "      var s = Math.max(-1, Math.min(1, ch[i]));",
      "      this.buf[this.idx++] = s < 0 ? s * 0x8000 : s * 0x7FFF;",
      "      if (this.idx >= this.buf.length) { this.port.postMessage(new Int16Array(this.buf)); this.idx = 0; }",
      "    } return true; }",
      "} registerProcessor('assistant-audio-proc', AssistantAudioProcessor);"
    ].join("\n");

    var dataUri = "data:application/javascript;base64," + window.btoa(workletCode);
    await _assistantAudioCtx.audioWorklet.addModule(dataUri);

    _assistantWorklet = new AudioWorkletNode(_assistantAudioCtx, "assistant-audio-proc");
    source.connect(_assistantWorklet);

    _assistantWorklet.port.onmessage = function(e) {
      if ((_assistantIsPTT || Date.now() - _assistantPttRelease < 2000) && _assistantConnected) {
        _sendAudioChunk(e.data);
      }
    };
    _assistantWorklet.port.postMessage({ command: "init" });

  } catch (err) {
    console.error("[Assistant] Microphone error:", err);
    _addErrorMessage("Microphone access denied or unavailable.");
  }
}

function _sendAudioChunk(pcm16Array) {
  if (!_assistantWs || _assistantWs.readyState !== WebSocket.OPEN) return;
  var base64 = _bufferToBase64(pcm16Array.buffer);
  var msg = {
    realtimeInput: {
      mediaChunks: [{
        mimeType: "audio/pcm;rate=16000",
        data: base64
      }]
    }
  };
  _assistantWs.send(JSON.stringify(msg));
}

function _bufferToBase64(buffer) {
  var binary = "";
  var bytes = new Uint8Array(buffer);
  for (var i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return window.btoa(binary);
}

// =========================================================================
// Audio Playback
// =========================================================================
function _initPlayback() {
  _playCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 24000 });

  // WOPR metallic voice chain:
  // 1. Bandpass to thin out the voice (telephone/computer quality)
  var bandpass = _playCtx.createBiquadFilter();
  bandpass.type = "bandpass";
  bandpass.frequency.value = 1800;
  bandpass.Q.value = 0.8;

  // 2. Peaking resonance at ~2.5kHz for metallic ring
  var resonance = _playCtx.createBiquadFilter();
  resonance.type = "peaking";
  resonance.frequency.value = 2500;
  resonance.gain.value = 6;
  resonance.Q.value = 3;

  // 3. Second resonance at ~1.2kHz for robotic nasal quality
  var resonance2 = _playCtx.createBiquadFilter();
  resonance2.type = "peaking";
  resonance2.frequency.value = 1200;
  resonance2.gain.value = 4;
  resonance2.Q.value = 2.5;

  // 4. Subtle waveshaper for slight harmonic distortion
  var waveshaper = _playCtx.createWaveShaper();
  var curve = new Float32Array(256);
  for (var i = 0; i < 256; i++) {
    var x = (i / 128) - 1;
    curve[i] = (Math.PI + 3) * x / (Math.PI + 3 * Math.abs(x));
  }
  waveshaper.curve = curve;
  waveshaper.oversample = "2x";

  // 5. Lowpass to tame harsh highs
  var lowpass = _playCtx.createBiquadFilter();
  lowpass.type = "lowpass";
  lowpass.frequency.value = 6000;

  // 6. Compressor to even out the metallic sound
  var compressor = _playCtx.createDynamicsCompressor();
  compressor.threshold.value = -20;
  compressor.ratio.value = 4;

  // Chain: source -> bandpass -> resonance -> resonance2 -> waveshaper -> lowpass -> compressor -> output
  bandpass.connect(resonance);
  resonance.connect(resonance2);
  resonance2.connect(waveshaper);
  waveshaper.connect(lowpass);
  lowpass.connect(compressor);
  compressor.connect(_playCtx.destination);

  _playFilter = bandpass; // entry point of the chain

  _playNextTime = _playCtx.currentTime;
}

function _playAudioChunk(base64Data) {
  if (!_playCtx) return;
  var binary = window.atob(base64Data);
  var buffer = new ArrayBuffer(binary.length);
  var view = new Uint8Array(buffer);
  for (var i = 0; i < binary.length; i++) view[i] = binary.charCodeAt(i);

  var int16 = new Int16Array(buffer);
  var float32 = new Float32Array(int16.length);
  for (var i = 0; i < int16.length; i++) float32[i] = int16[i] / 32768.0;

  var audioBuffer = _playCtx.createBuffer(1, float32.length, 24000);
  audioBuffer.getChannelData(0).set(float32);

  var src = _playCtx.createBufferSource();
  src.buffer = audioBuffer;
  src.connect(_playFilter);

  if (_playNextTime < _playCtx.currentTime) _playNextTime = _playCtx.currentTime;
  src.start(_playNextTime);
  _playNextTime += audioBuffer.duration;
}

// =========================================================================
// Chat UI Helpers
// =========================================================================
function _getMessagesEl() {
  return document.getElementById("assistantMessages");
}

function _scrollToBottom() {
  var el = _getMessagesEl();
  if (el) el.scrollTop = el.scrollHeight;
}

function _addUserMessage(text) {
  var div = document.createElement("div");
  div.className = "assistant-msg user-msg";
  div.textContent = text;
  _getMessagesEl().appendChild(div);
  _scrollToBottom();
}

function _addSystemMessage(text) {
  var div = document.createElement("div");
  div.className = "assistant-msg system-msg";
  div.innerHTML = "<p>" + text + "</p>";
  _getMessagesEl().appendChild(div);
  _scrollToBottom();
}

function _addErrorMessage(text) {
  var div = document.createElement("div");
  div.className = "assistant-msg error-msg";
  div.textContent = text;
  _getMessagesEl().appendChild(div);
  _scrollToBottom();
}

function _addToolMessage(toolName, args, result) {
  var div = document.createElement("div");
  div.className = "assistant-msg tool-msg";
  var quality = _extractQualityCheck(result);
  var qualityErrors = quality ? _qualityIssuesBySeverity(quality, "error") : [];
  var qualityWarnings = quality ? _qualityIssuesBySeverity(quality, "warning") : [];
  var statusIcon = result.error || qualityErrors.length ? "\u2717" : (qualityWarnings.length ? "!" : "\u2713");
  var statusText = result.error ? ("Error: " + result.error) : _summarizeToolResult(toolName, result);
  var statusHtml = _escapeHtml(statusText).replace(/\n/g, "<br>");
  div.innerHTML = "<strong>" + statusIcon + " " + toolName + "</strong>" +
    "<br><em>" + statusHtml + "</em>";
  _getMessagesEl().appendChild(div);
  _scrollToBottom();
}

function _summarizeToolResult(toolName, result) {
  if (!result) return "Complete.";
  var quality = _extractQualityCheck(result);
  if (quality) {
    _logQualityIssues(toolName, quality);
  }

  var lines = [];
  if (typeof result.message === "string" && result.message.trim()) {
    lines.push(result.message.trim());
  }
  if (quality) {
    var qualityText = _formatQualityIssuesForLog(quality);
    if (qualityText) lines.push(qualityText);
  }
  if (lines.length === 0 && result.success === true) lines.push("Complete.");
  return lines.length ? lines.join("\n") : "Complete.";
}

function _extractQualityCheck(result) {
  if (!result) return null;
  if (result.quality_check) return result.quality_check;
  if (Array.isArray(result.issues) || Array.isArray(result.errors) || Array.isArray(result.warnings)) return result;
  return null;
}

function _qualityIssuesBySeverity(quality, severity) {
  if (!quality) return [];
  var issues = Array.isArray(quality.issues) ? quality.issues : [];
  var filtered = issues.filter(function(issue) {
    return String(issue.severity || "").toLowerCase() === severity;
  });
  var legacy = Array.isArray(quality[severity + "s"]) ? quality[severity + "s"] : [];
  legacy.forEach(function(item) {
    filtered.push(typeof item === "string" ? { title: item } : item);
  });
  return filtered;
}

function _qualityIssueText(issue) {
  if (!issue) return "Unknown issue.";
  var title = String(issue.title || issue.message || issue.category || "Issue").trim();
  var detail = String(issue.message && issue.title ? issue.message : issue.detail || issue.recommendation || "").trim();
  return detail ? title + " - " + detail : title;
}

function _formatQualityIssuesForLog(quality) {
  var errors = _qualityIssuesBySeverity(quality, "error");
  var warnings = _qualityIssuesBySeverity(quality, "warning");
  var lines = [];
  if (errors.length) {
    lines.push("Errors:");
    errors.slice(0, 4).forEach(function(issue) { lines.push("- " + _qualityIssueText(issue)); });
    if (errors.length > 4) lines.push("- +" + (errors.length - 4) + " more error(s).");
  }
  if (warnings.length) {
    lines.push("Warnings:");
    warnings.slice(0, 4).forEach(function(issue) { lines.push("- " + _qualityIssueText(issue)); });
    if (warnings.length > 4) lines.push("- +" + (warnings.length - 4) + " more warning(s).");
  }
  return lines.join("\n");
}

function _logQualityIssues(toolName, quality) {
  var errors = _qualityIssuesBySeverity(quality, "error");
  var warnings = _qualityIssuesBySeverity(quality, "warning");
  if (errors.length) {
    console.error("[Assistant][" + toolName + "] Quality errors:", errors.map(_qualityIssueText));
  }
  if (warnings.length) {
    console.warn("[Assistant][" + toolName + "] Quality warnings:", warnings.map(_qualityIssueText));
  }
}

function _showTypingIndicator() {
  _removeTypingIndicator();
  var div = document.createElement("div");
  div.className = "assistant-msg typing-msg";
  div.id = "assistantTyping";
  div.innerHTML = '<div class="typing-dots"><span></span><span></span><span></span></div>';
  _getMessagesEl().appendChild(div);
  _scrollToBottom();
}

function _removeTypingIndicator() {
  var el = document.getElementById("assistantTyping");
  if (el) el.remove();
}

function _looksLikeAssistantProcessNarration(text) {
  var compact = String(text || "").replace(/\s+/g, " ").trim();
  if (!compact) return true;

  var forbiddenHeadings = [
    "Building the Fuselage",
    "Defining the Workflow",
    "Defining the Components",
    "Calculating Component Properties",
    "Defining the Initial Build"
  ];
  for (var i = 0; i < forbiddenHeadings.length; i++) {
    if (compact.toLowerCase().indexOf(forbiddenHeadings[i].toLowerCase()) >= 0) return true;
  }

  var processSignals = [
    /\bI(?:'ve| have) established\b/i,
    /\bmy current focus\b/i,
    /\bI(?:'m| am) planning\b/i,
    /\bI need to:\b/i,
    /\bI(?:'m| am) now\b/i,
    /\bworking through it step-by-step\b/i,
    /\bI can confidently\b/i,
    /\bstarting the modeling process\b/i,
    /\bcalculating and refining\b/i,
    /\bbroken down .* into .* components\b/i
  ];
  var hits = 0;
  for (var j = 0; j < processSignals.length; j++) {
    if (processSignals[j].test(compact)) hits++;
  }
  return hits >= 2 || (/^(Building|Defining|Calculating|Refining)\b/i.test(compact) && compact.length > 80);
}

function _sanitizeAssistantVisibleText(text) {
  var cleaned = String(text || "").replace(/\r\n/g, "\n").trim();
  if (!cleaned) return "";
  if (_looksLikeAssistantProcessNarration(cleaned)) return "";
  return cleaned;
}

function _appendAiText(text) {
  text = _sanitizeAssistantVisibleText(text);
  if (!text) return;

  _removeTypingIndicator();
  if (!_currentAiDiv) {
    _currentAiDiv = document.createElement("div");
    _currentAiDiv.className = "assistant-msg ai-msg";
    _getMessagesEl().appendChild(_currentAiDiv);
    _currentAiText = "";
  }
  _currentAiText += text;
  _currentAiDiv.innerHTML = _formatMarkdown(_currentAiText);
  _scrollToBottom();
}

function _finalizeAiMessage() {
  _removeTypingIndicator();
  if (_currentAiDiv && !_currentAiText.trim()) {
    _currentAiDiv.remove();
  }
  _currentAiDiv = null;
  _currentAiText = "";
}

function _escapeHtml(str) {
  return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function _formatMarkdown(text) {
  // Basic markdown: bold, italic, code, line breaks
  return _escapeHtml(text)
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/`(.+?)`/g, "<code style='background:#1a1a2e;padding:1px 4px;border-radius:3px;font-size:12px;'>$1</code>")
    .replace(/\n/g, "<br>");
}

// =========================================================================
// Status Indicator
// =========================================================================
function _updateStatus(state) {
  var dot = document.getElementById("assistantStatus");
  if (!dot) return;
  dot.className = "ws-status";
  if (state === "connected") dot.classList.add("ws-connected");
  else if (state === "connecting") dot.classList.add("ws-connecting");
  else dot.classList.add("ws-disconnected");
}

// =========================================================================
// API Key Management
// =========================================================================
function _storageGet(key) {
  try { return window.localStorage ? localStorage.getItem(key) : ""; }
  catch (e) { return ""; }
}

function _storageSet(key, value) {
  try { if (window.localStorage) localStorage.setItem(key, value); }
  catch (e) { console.warn("[Assistant] Could not save API key to local storage:", e); }
}

function _storageRemove(key) {
  try { if (window.localStorage) localStorage.removeItem(key); }
  catch (e) { console.warn("[Assistant] Could not clear API key from local storage:", e); }
}

function _loadAssistantApiKey() {
  for (var i = 0; i < GEMINI_API_KEY_STORAGE_KEYS.length; i++) {
    var key = _storageGet(GEMINI_API_KEY_STORAGE_KEYS[i]);
    if (key && key.trim()) {
      _saveAssistantApiKey(key.trim());
      return key.trim();
    }
  }
  return "";
}

function _saveAssistantApiKey(key) {
  if (!key) return;
  GEMINI_API_KEY_STORAGE_KEYS.forEach(function(storageKey) {
    _storageSet(storageKey, key);
  });
}

function _clearAssistantApiKey() {
  GEMINI_API_KEY_STORAGE_KEYS.forEach(function(storageKey) {
    _storageRemove(storageKey);
  });
}

function _ensureAssistantApiKey(promptNow) {
  if (_assistantApiKey && _assistantApiKey.trim()) return true;
  _assistantApiKey = _loadAssistantApiKey();
  if (_assistantApiKey) return true;
  if (promptNow) _promptApiKey();
  return !!(_assistantApiKey && _assistantApiKey.trim());
}

function _promptApiKey() {
  var key = prompt(
    "Gemini API key setup:\n\n" +
    "1. Create a Gemini API key in Google AI Studio:\n" +
    "   " + GEMINI_API_KEY_URL + "\n" +
    "2. Paste the key here.\n" +
    "3. The key is stored only in this browser's local storage.\n\n" +
    "Enter your Gemini API key:"
  );
  if (key && key.trim()) {
    _assistantApiKey = key.trim();
    _saveAssistantApiKey(_assistantApiKey);
  }
}

// =========================================================================
// Panel Toggle
// =========================================================================
function _toggleAssistantPanel() {
  document.body.classList.toggle("show-assistant");

  if (document.body.classList.contains("show-assistant") && !_assistantConnected) {
    if (_ensureAssistantApiKey(true)) _connectAssistant();
  }
}

function _closeAssistantPanel() {
  document.body.classList.remove("show-assistant");
}

// =========================================================================
// Event Wiring
// =========================================================================
document.addEventListener("DOMContentLoaded", function() {
  setTimeout(function() {
    if (!_assistantConnected && !_ensureAssistantApiKey(false)) {
      _promptApiKey();
    }
  }, 250);

  // Toggle button
  var toggleBtn = document.getElementById("toggleAssistantBtn");
  if (toggleBtn) toggleBtn.addEventListener("click", _toggleAssistantPanel);

  // Close button
  var closeBtn = document.getElementById("closeAssistantBtn");
  if (closeBtn) closeBtn.addEventListener("click", _closeAssistantPanel);

  // Settings (API key)
  var settingsBtn = document.getElementById("assistantSettingsBtn");
  if (settingsBtn) settingsBtn.addEventListener("click", function() {
    _promptApiKey();
    if (_assistantApiKey && !_assistantConnected) _connectAssistant();
  });

  // Clear chat
  var clearBtn = document.getElementById("assistantClearBtn");
  if (clearBtn) clearBtn.addEventListener("click", function() {
    var el = _getMessagesEl();
    if (el) el.innerHTML = "";
    _addSystemMessage("Chat cleared. Type or speak to continue.");
  });

  // Send button
  var sendBtn = document.getElementById("assistantSendBtn");
  if (sendBtn) sendBtn.addEventListener("click", function() {
    var input = document.getElementById("assistantInput");
    if (input) {
      if (_sendTextMessage(input.value)) {
        input.value = "";
        input.style.height = "auto";
      }
    }
  });

  // Text input — Enter to send, Shift+Enter for newline
  var input = document.getElementById("assistantInput");
  if (input) {
    input.addEventListener("focus", function() {
      if (!_ensureAssistantApiKey(false)) _promptApiKey();
    });

    input.addEventListener("keydown", function(e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (_sendTextMessage(input.value)) {
          input.value = "";
          input.style.height = "auto";
        }
      }
    });

    // Auto-resize textarea
    input.addEventListener("input", function() {
      this.style.height = "auto";
      this.style.height = Math.min(this.scrollHeight, 100) + "px";
    });
  }

  // Mic button — Push-to-Talk (hold to speak)
  // Microphone is only initialized on first press (lazy init) to avoid permission popup on load
  var micBtn = document.getElementById("assistantMicBtn");
  if (micBtn) {
    async function _startPTT() {
      if (!_ensureAssistantApiKey(true)) return;
      if (!_assistantConnected) {
        _connectAssistant();
        return;
      }
      if (!_assistantGreetingComplete || _assistantGreetingTurnActive) {
        _addSystemMessage("Joshua is coming online. Voice input will unlock after the greeting.");
        return;
      }
      // Lazy-init microphone on first PTT press
      if (!_assistantWorklet) {
        await _initMicrophone();
        if (!_assistantWorklet) return; // mic denied
      }
      _assistantIsPTT = true;
      micBtn.classList.add("recording");
    }

    function _stopPTT() {
      _assistantIsPTT = false;
      _assistantPttRelease = Date.now();
      micBtn.classList.remove("recording");
    }

    micBtn.addEventListener("mousedown", function(e) {
      e.preventDefault();
      _startPTT();
    });

    micBtn.addEventListener("mouseup", _stopPTT);

    micBtn.addEventListener("mouseleave", function() {
      if (_assistantIsPTT) _stopPTT();
    });

    // Touch events for mobile
    micBtn.addEventListener("touchstart", function(e) {
      e.preventDefault();
      _startPTT();
    });

    micBtn.addEventListener("touchend", _stopPTT);
  }
});

// =========================================================================
// Exports
// =========================================================================
window.toggleAssistantPanel = _toggleAssistantPanel;
window.connectAssistant = _connectAssistant;
window.disconnectAssistant = _disconnectAssistant;
