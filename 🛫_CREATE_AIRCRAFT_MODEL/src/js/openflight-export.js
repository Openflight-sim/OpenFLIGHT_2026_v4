/********************************************
 * FILE: openflight-export.js
 * Converts v2.1 analysis results + aircraftData
 * into legacy OpenFlight simulator YAML format
 ********************************************/

function resolveReferenceAreaM2(gen) {
  var sref = Number(gen && gen.aircraft_reference_area_m2);
  if (isFinite(sref) && sref > 0) return sref;
  return 10;
}

function estimateAircraftLengthForExport(ad) {
  var minX = Infinity;
  var maxX = -Infinity;
  (ad.fuselages || []).forEach(function(f) {
    var nose = f.nose_position || [0, 0, 0];
    var tailX = (nose[0] || 0) + (f.length || 0);
    minX = Math.min(minX, nose[0] || 0, tailX);
    maxX = Math.max(maxX, nose[0] || 0, tailX);
  });
  (ad.lifting_surfaces || []).forEach(function(s) {
    var root = s.root_LE || [0, 0, 0];
    var area = s.surface_area_m2 || 0;
    var AR = s.AR || 0;
    var TR = s.TR || 1;
    var span = area > 0 && AR > 0 ? Math.sqrt(area * AR) : 0;
    var chord = span > 0 ? (2 * area) / (span * (1 + TR)) : (s.mean_aerodynamic_chord_m || 1);
    minX = Math.min(minX, root[0] || 0);
    maxX = Math.max(maxX, (root[0] || 0) + chord);
  });
  var cref = ad.general && ad.general.aircraft_reference_mean_aerodynamic_chord_m || 1;
  return isFinite(minX) && isFinite(maxX) && maxX > minX ? Math.max(maxX - minX, 2.5 * cref) : 2.5 * cref;
}

function resolveInertiaForExport(ad) {
  var gen = ad.general || {};
  var inertia = gen.inertia || {};
  var pm = inertia.principal_moments_kgm2 || {};
  var mass = Math.max(gen.mass_kg || 1000, 1);
  var bref = Math.max(gen.aircraft_reference_span_m || 1, 1);
  var length = Math.max(estimateAircraftLengthForExport(ad), 1);
  var Ixx = Number(pm.Ixx_p || 0);
  var Iyy = Number(pm.Iyy_p || 0);
  var Izz = Number(pm.Izz_p || 0);
  var defaultLike = Math.abs(Ixx - 1000) < 1e-6 && Math.abs(Iyy - 3000) < 1e-6 && Math.abs(Izz - 3500) < 1e-6;
  var weak = !(Ixx > 0 && Iyy > 0 && Izz > 0) ||
    Math.sqrt(Math.max(Ixx, 0) / mass) < 0.16 * bref ||
    Math.sqrt(Math.max(Iyy, 0) / mass) < 0.14 * length ||
    Math.sqrt(Math.max(Izz, 0) / mass) < 0.18 * bref;

  if (inertia.auto_estimate === false || (!defaultLike && !weak)) {
    return inertia;
  }

  var kx = Math.max(0.28 * bref, 0.65);
  var ky = Math.max(0.30 * length, 0.65);
  var kz = Math.max(Math.sqrt(Math.pow(0.30 * bref, 2) + Math.pow(0.22 * length, 2)), kx);
  return {
    principal_moments_kgm2: {
      Ixx_p: Math.round(mass * kx * kx),
      Iyy_p: Math.round(mass * ky * ky),
      Izz_p: Math.round(mass * kz * kz)
    },
    principal_axes_rotation_deg: { roll: 0, pitch: 0, yaw: 0 },
    auto_estimated: true
  };
}

// ================================================================
// MAIN ENTRY POINT
// ================================================================

function buildOpenFlightYAML(v21Model, aircraftData) {
  var constants = buildConstants(v21Model, aircraftData);
  var coefficients = buildCoefficients(v21Model, aircraftData);
  var propulsion = buildPropulsionSection(aircraftData);
  var visualGeometry = buildVisualGeometry(aircraftData);
  return serializeLegacyYAML(constants, coefficients, propulsion, visualGeometry);
}

// ================================================================
// CONSTANTS BUILDER
// ================================================================

function buildConstants(model, ad) {
  var gen = ad.general || {};
  var inertia = resolveInertiaForExport(ad);
  var pm = inertia.principal_moments_kgm2 || {};
  var pa = inertia.principal_axes_rotation_deg || {};
  var mass = gen.mass_kg || 1000;

  // Find wing and tail surfaces
  var wingSurf = findSurfaceByRole(ad, 'wing');
  var htailSurf = findSurfaceByRole(ad, 'horizontal_stabilizer');
  var vtailSurf = findSurfaceByRole(ad, 'vertical_stabilizer');

  var Sref = resolveReferenceAreaM2(gen);
  var bref = gen.aircraft_reference_span_m || 10;
  var cref = gen.aircraft_reference_mean_aerodynamic_chord_m || 1;
  var AR = bref * bref / Sref;
  var CoG = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];

  // Compute wing aerodynamic center from wing surface if available
  var wingAC = wingSurf ? computeAC(wingSurf) : [CoG[0] + 0.25 * cref, 0, 0];

  // Tail properties — computed by model creator, stored in runtime_model.
  var leg = (model && model.runtime_model) || {};
  var tailArea = computeTailArea(htailSurf, vtailSurf);
  var htailAC = computeAC(htailSurf);
  var vtailAC = computeAC(vtailSurf);
  var tailAC = htailAC[0] > vtailAC[0] ? htailAC : (vtailAC[0] > 0 ? vtailAC : htailAC);

  // Extract derivatives from v2.1 model
  var derivs = extractScalarDerivatives(model);

  // Engine data
  var engines = ad.engines || [];
  var eng0 = engines[0] || {};

  var c = {};

  // ---- Mass & Inertia ----
  c.aircraft_mass = mass;
  c.radius_of_giration_pitch = Math.sqrt((pm.Iyy_p || 3000) / mass);
  c.radius_of_giration_yaw = Math.sqrt((pm.Izz_p || 3500) / mass);
  c.radius_of_giration_roll = Math.sqrt((pm.Ixx_p || 1000) / mass);
  c.principal_axis_pitch_up_DEG = pa.pitch || 0;
  c.x_CoG = CoG[0];
  c.y_CoG = CoG[1] || 0;
  c.z_CoG = CoG[2] || 0;

  // ---- Wing Geometry ----
  c.x_wing_aerodynamic_center = wingAC[0];
  c.y_wing_aerodynamic_center = wingAC[1] || 0;
  c.z_wing_aerodynamic_center = wingAC[2] || 0;
  // Wing-fuselage AC used by the simulator for force application point
  c.x_wing_fuselage_aerodynamic_center = wingAC[0];
  c.y_wing_fuselage_aerodynamic_center = wingAC[1] || 0;
  c.z_wing_fuselage_aerodynamic_center = wingAC[2] || 0;
  c.reference_area = Sref;
  c.reference_span = bref;
  c.AR = roundN(AR, 4);
  c.Oswald_factor = estimateOswaldFactor(wingSurf);
  c.wing_mean_aerodynamic_chord = cref;
  c.Sideslip_drag_K_factor = 2.0;

  // ---- Tail Geometry ----
  c.tail_reference_area = tailArea;
  // Use HTP AC for the main tail aero center (HTP dominates pitch moment)
  c.x_tail_aerodynamic_center = htailAC[0] || vtailAC[0] || CoG[0] + 3;
  c.y_tail_aerodynamic_center = htailAC[1] || 0;
  c.z_tail_aerodynamic_center = htailAC[2] || 0;
  c.x_horizontal_tail_aerodynamic_center = htailAC[0] || tailAC[0];
  c.y_horizontal_tail_aerodynamic_center = htailAC[1] || 0;
  c.z_horizontal_tail_aerodynamic_center = htailAC[2] || 0;
  c.x_vertical_tail_aerodynamic_center = vtailAC[0] || tailAC[0];
  c.y_vertical_tail_aerodynamic_center = vtailAC[1] || 0.5;
  c.z_vertical_tail_aerodynamic_center = vtailAC[2] || 0;
  // Legacy scalar damping references kept for backwards compatibility.
  // In current table mode, OpenFlight gets tail damping from local tail
  // flow plus the current CG lever arm when forming r x F.
  c.tail_CL_q = leg.tail_CL_q || 3.0;
  c.tail_CS_r = leg.tail_CS_r || 0.5;
  c.tail_CD0 = leg.tail_CD0 || 0.015;
  c.tail_k_induced = leg.tail_k_induced || 0.2;
  c.tail_k_side = leg.tail_k_side || 0.1;
  c.scale_tail_forces = 1;

  // ---- Neutral Point ----
  if (model && model.neutral_point_x_m != null) {
    c.x_neutral_point = model.neutral_point_x_m;
    c.static_margin_MAC = roundN((model.neutral_point_x_m - CoG[0]) / cref, 4);
  }

  // ---- Stability & Damping Derivatives ----
  c.Cm0 = derivs.Cm0 || -0.05;
  c.Cm_trim = derivs.Cm_trim || 0.0;
  c.Cl_beta = derivs.Cl_beta || -0.1;
  // Cm_alpha and Cn_beta are set to 0: the simulator computes these effects
  // from forces applied at the wing/tail aerodynamic centers (r×F model).
  // Including non-zero values here would double-count the α/β stability.
  c.Cm_alpha = 0;
  c.Cn_beta = 0;
  c.Cl_p = derivs.Cl_p || -0.5;
  c.Cm_q = derivs.Cm_q || -5.0;
  c.Cn_r = derivs.Cn_r || -0.2;

  // ---- Control Derivatives ----
  // derivs.*_per_deg values must be scaled by maximum deflection (degrees)
  // because the simulator uses normalized demand (-1..+1) for full stick.
  var maxElevDeg = getMaxDeflectionDeg(ad, 'elevator');
  var maxAilDeg  = getMaxDeflectionDeg(ad, 'aileron');
  var maxRudDeg  = getMaxDeflectionDeg(ad, 'rudder');
  // Control derivatives stored as per-degree values (NOT pre-multiplied by max deflection).
  // The simulator multiplies by the actual deflection in degrees at runtime.
  c.Cl_da = derivs.Cl_da != null ? derivs.Cl_da : 0.003;
  c.Cm_de = derivs.Cm_de != null ? derivs.Cm_de : -0.012;
  c.Cn_dr = derivs.Cn_dr != null ? derivs.Cn_dr : -0.002;
  c.Cn_da = derivs.Cn_da != null ? derivs.Cn_da : -0.0004;

  // ---- Stall Parameters ----
  c.alpha_stall_positive = leg.alpha_stall_positive != null ? leg.alpha_stall_positive : 15;
  c.alpha_stall_negative = leg.alpha_stall_negative != null ? leg.alpha_stall_negative : -15;
  c.CL_max = leg.CL_max != null ? leg.CL_max : 1.2;
  c.CD0 = leg.CD0 != null ? leg.CD0 : 0.02;

  // ---- Dynamic Stall ----
  c.dynamic_stall_alpha_on_deg = leg.dynamic_stall_alpha_on_deg != null ? leg.dynamic_stall_alpha_on_deg : 14;
  c.dynamic_stall_alpha_off_deg = leg.dynamic_stall_alpha_off_deg != null ? leg.dynamic_stall_alpha_off_deg : 10;
  c.dynamic_stall_tau_alpha_s = leg.dynamic_stall_tau_alpha_s != null ? leg.dynamic_stall_tau_alpha_s : 0.08;
  c.dynamic_stall_tau_sigma_rise_s = leg.dynamic_stall_tau_sigma_rise_s != null ? leg.dynamic_stall_tau_sigma_rise_s : 0.12;
  c.dynamic_stall_tau_sigma_fall_s = leg.dynamic_stall_tau_sigma_fall_s != null ? leg.dynamic_stall_tau_sigma_fall_s : 0.35;
  c.dynamic_stall_qhat_to_alpha_deg = leg.dynamic_stall_qhat_to_alpha_deg != null ? leg.dynamic_stall_qhat_to_alpha_deg : 2.0;
  c.poststall_cl_scale = leg.poststall_cl_scale != null ? leg.poststall_cl_scale : 1.1;
  c.poststall_cd90 = leg.poststall_cd90 != null ? leg.poststall_cd90 : 1.6;
  c.poststall_cd_min = leg.poststall_cd_min != null ? leg.poststall_cd_min : 0.08;
  c.poststall_sideforce_scale = leg.poststall_sideforce_scale != null ? leg.poststall_sideforce_scale : 0.7;

  // ---- Propulsion ----
  c.maximum_thrust_at_sea_level = eng0.max_thrust_n || eng0.thrust_scale * 1000 || 600;
  c.thrust_installation_angle_DEG = (eng0.orientation_deg && eng0.orientation_deg.pitch) || 0;
  c.control_actuator_speed = 4;
  c.engine_spool_up_speed = eng0.spool_up_1_s || 1.3;
  c.engine_spool_down_speed = eng0.spool_down_1_s || 1.1;

  return c;
}

// ================================================================
// COEFFICIENTS BUILDER
// ================================================================

function buildCoefficients(model, ad) {
  var coeffs = {};
  var aero = model && model.aerodynamics;
  if (!aero || !aero.static_coefficients) return buildFallbackCoefficients(ad);

  var sc = aero.static_coefficients;
  var axes = sc.axes || {};
  var machs = axes.mach || [0];
  var alphas = axes.alpha_deg || [0];
  var betas = axes.beta_deg || [0];
  var configs = axes.config || ['clean'];
  var configKey = configs[0]; // Use first config for legacy format

  var gen = ad.general || {};
  var Sref = resolveReferenceAreaM2(gen);
  var bref = gen.aircraft_reference_span_m || 10;
  var AR = bref * bref / Sref;
  var Oswald = estimateOswaldFactor(findSurfaceByRole(ad, 'wing'));

  // CL table: parameters [Mach, beta, alpha]
  if (sc.CL && sc.CL.values) {
    coeffs.CL = buildLegacyTable3D('CL', sc.CL.values[configKey], machs, alphas, betas, ['Mach', 'beta', 'alpha']);
  }

  // CS table (from CY): parameters [Mach, alpha, beta]
  if (sc.CY && sc.CY.values) {
    coeffs.CS = buildLegacyTable3D('CS', sc.CY.values[configKey], machs, alphas, betas, ['Mach', 'alpha', 'beta']);
  }

  // CD0 table: try pre-computed from Julia, else compute CD_total - CL^2/(pi*AR*e)
  var usedLegacyCD0 = false;
  if (model && model.runtime_model && model.runtime_model.CD0_table &&
      model.runtime_model.CD0_table.values) {
    var cd0Legacy = model.runtime_model.CD0_table;
    // Wrap into [mach][alpha][beta] format (legacy has just [alpha][beta] for first Mach)
    var cd0Wrapped = [cd0Legacy.values];
    coeffs.CD0 = buildLegacyTable3D('CD0', cd0Wrapped, [machs[0]], alphas, betas, ['Mach', 'beta', 'alpha']);
    usedLegacyCD0 = true;
  }
  if (!usedLegacyCD0 && sc.CD && sc.CD.values && sc.CL && sc.CL.values) {
    var cdData = sc.CD.values[configKey];
    var clData = sc.CL.values[configKey];
    var cd0Data = [];
    for (var mi = 0; mi < machs.length; mi++) {
      var machSlice = [];
      for (var ai = 0; ai < alphas.length; ai++) {
        var row = [];
        for (var bi = 0; bi < betas.length; bi++) {
          var cd = getVal3D(cdData, mi, ai, bi);
          var cl = getVal3D(clData, mi, ai, bi);
          var cdi = cl * cl / (Math.PI * AR * Oswald);
          row.push(roundN(Math.max(cd - cdi, 0.001), 6));
        }
        machSlice.push(row);
      }
      cd0Data.push(machSlice);
    }
    coeffs.CD0 = buildLegacyTable3D('CD0', cd0Data, machs, alphas, betas, ['Mach', 'beta', 'alpha']);
  }

  // Tail CL and CS tables (1D)
  // Try to get from per_surface_data or local_flow, or generate from slope approximations
  var tailCL = buildTailCLTable(model, ad, alphas);
  if (tailCL) coeffs.tail_CL = tailCL;

  var tailCS = buildTailCSTable(model, ad, betas);
  if (tailCS) coeffs.tail_CS = tailCS;

  // Optional: downwash, sidewash, dynamic pressure ratio
  var downwash = buildDownwashTable(model, ad, alphas);
  if (downwash) coeffs.Horizontal_tail_downwash_deg = downwash;

  var sidewash = buildSidewashTable(model, ad, betas);
  if (sidewash) coeffs.Vertical_tail_sidewash_deg = sidewash;

  var dpr = buildDPRTable(model, ad, alphas);
  if (dpr) coeffs.tail_dynamic_pressure_ratio = dpr;

  return coeffs;
}

function buildFallbackCoefficients(ad) {
  var coeffs = {};
  var axes = buildFallbackAxes(ad);
  var wing = findSurfaceByRole(ad, 'wing');
  var vtail = findSurfaceByRole(ad, 'vertical_stabilizer');
  var gen = ad.general || {};
  var Sref = resolveReferenceAreaM2(gen);
  var bref = Number(gen.aircraft_reference_span_m) || 10;
  var wingAR = wing && wing.AR ? wing.AR : Math.max(0.5, bref * bref / Math.max(Sref, 0.1));
  var wingGeom = wing || { TR: 0.5, sweep_quarter_chord_deg: 0, twist_tip_deg: 0 };
  var wingCLaRad = 2 * Math.PI * wingAR / (2 + Math.sqrt(4 + wingAR * wingAR));
  var wingClMax = datcomSectionClmax(getThicknessRatio(wingGeom)) * datcom3DRatio(wingAR, wingGeom);
  var wingAlphaStallRad = Math.max(wingClMax / Math.max(wingCLaRad, 1e-6), 10 * Math.PI / 180);

  var vtailAreaRatio = Math.max(
    vtail && vtail.surface_area_m2 ? vtail.surface_area_m2 / Math.max(Sref, 0.1) : 0.12,
    0.08
  );
  var vtailAR = vtail && vtail.AR ? vtail.AR : 2.0;
  var vtailGeom = vtail || { TR: 0.6, sweep_quarter_chord_deg: 25, twist_tip_deg: 0 };
  var vtailCYbRad = -0.75 * vtailAreaRatio *
    (2 * Math.PI * vtailAR / (2 + Math.sqrt(4 + vtailAR * vtailAR)));
  var vtailCyMax = datcomSectionClmax(getThicknessRatio(vtailGeom)) *
    datcom3DRatio(vtailAR, vtailGeom) * Math.max(vtailAreaRatio, 0.15);
  var vtailBetaStallRad = Math.max(
    Math.abs(vtailCyMax / Math.max(Math.abs(vtailCYbRad), 1e-6)),
    12 * Math.PI / 180
  );
  var cd0Base = 0.02;

  var clData = [];
  var csData = [];
  var cd0Data = [];

  axes.machs.forEach(function() {
    var clMach = [];
    var csMach = [];
    var cd0Mach = [];

    axes.alphas.forEach(function(alphaDeg) {
      var alphaRad = alphaDeg * Math.PI / 180;
      var clAlpha = tailStallCL(alphaRad, wingCLaRad, wingClMax, wingAlphaStallRad, 1.9);
      var sideforceAlphaScale = 0.35 + 0.65 * Math.pow(Math.cos(Math.min(Math.abs(alphaRad), Math.PI / 2)), 2);
      var clRow = [];
      var csRow = [];
      var cd0Row = [];

      axes.betas.forEach(function(betaDeg) {
        var betaRad = betaDeg * Math.PI / 180;
        var betaLiftScale = Math.max(0.15, Math.cos(Math.min(Math.abs(betaRad), Math.PI / 2)));
        var csBeta = tailStallSideforce(betaRad, vtailCYbRad, Math.abs(vtailCyMax), vtailBetaStallRad, 1.6);
        var baseDrag = cd0Base +
          0.004 * Math.pow(Math.sin(alphaRad), 2) +
          0.012 * Math.pow(Math.sin(betaRad), 2);

        clRow.push(roundN(clAlpha * betaLiftScale, 6));
        csRow.push(roundN(csBeta * sideforceAlphaScale, 6));
        cd0Row.push(roundN(baseDrag, 6));
      });

      clMach.push(clRow);
      csMach.push(csRow);
      cd0Mach.push(cd0Row);
    });

    clData.push(clMach);
    csData.push(csMach);
    cd0Data.push(cd0Mach);
  });

  coeffs.CL = buildLegacyTable3D('CL', clData, axes.machs, axes.alphas, axes.betas, ['Mach', 'beta', 'alpha']);
  coeffs.CS = buildLegacyTable3D('CS', csData, axes.machs, axes.alphas, axes.betas, ['Mach', 'alpha', 'beta']);
  coeffs.CD0 = buildLegacyTable3D('CD0', cd0Data, axes.machs, axes.alphas, axes.betas, ['Mach', 'beta', 'alpha']);

  var tailCL = buildTailCLTable(null, ad, axes.alphas);
  if (tailCL) coeffs.tail_CL = tailCL;

  var tailCS = buildTailCSTable(null, ad, axes.betas);
  if (tailCS) coeffs.tail_CS = tailCS;

  var downwash = buildDownwashTable(null, ad, axes.alphas);
  if (downwash) coeffs.Horizontal_tail_downwash_deg = downwash;

  var sidewash = buildSidewashTable(null, ad, axes.betas);
  if (sidewash) coeffs.Vertical_tail_sidewash_deg = sidewash;

  var dpr = buildDPRTable(null, ad, axes.alphas);
  if (dpr) coeffs.tail_dynamic_pressure_ratio = dpr;

  return coeffs;
}

function buildFallbackAxes(ad) {
  var analysis = (ad && ad.analysis) || {};
  return {
    machs: Array.isArray(analysis.mach_values) && analysis.mach_values.length ? analysis.mach_values.slice() : [0.2],
    alphas: sampleAxisRange(analysis.alpha_range_DEG, analysis.alpha_step_DEG, [-180, 180], 5),
    betas: sampleAxisRange(analysis.beta_range_DEG, analysis.beta_step_DEG, [-180, 180], 5)
  };
}

function sampleAxisRange(range, step, fallbackRange, minStep) {
  var bounds = Array.isArray(range) && range.length >= 2 ? range : fallbackRange;
  var start = Number(bounds[0]);
  var finish = Number(bounds[1]);
  if (!isFinite(start) || !isFinite(finish)) {
    start = fallbackRange[0];
    finish = fallbackRange[1];
  }
  if (finish < start) {
    var tmp = start;
    start = finish;
    finish = tmp;
  }

  var resolvedStep = Math.abs(Number(step) || 0);
  if (!(resolvedStep > 0)) resolvedStep = minStep || 5;
  resolvedStep = Math.max(resolvedStep, minStep || 5);

  var values = [];
  for (var value = start; value <= finish + 1e-9; value += resolvedStep) {
    values.push(roundN(value, 4));
  }
  if (values.length === 0 || values[values.length - 1] !== finish) {
    values.push(roundN(finish, 4));
  }
  return values;
}

// ================================================================
// HELPER: Build legacy 3D coefficient table
// ================================================================

function buildLegacyTable3D(name, data, machs, alphas, betas, paramOrder) {
  // paramOrder: ['Mach', 'beta', 'alpha'] for CL/CD0
  //             ['Mach', 'alpha', 'beta'] for CS
  var table = { parameters: paramOrder, data: [] };

  var isMachBetaAlpha = paramOrder[1] === 'beta';

  for (var mi = 0; mi < machs.length; mi++) {
    var machEntry = {};
    machEntry.Mach = machs[mi];
    machEntry.data = [];

    if (isMachBetaAlpha) {
      // Nesting: Mach → beta → alpha
      for (var bi = 0; bi < betas.length; bi++) {
        var betaEntry = {};
        betaEntry.beta = betas[bi];
        betaEntry.data = [];
        for (var ai = 0; ai < alphas.length; ai++) {
          var entry = {};
          entry.alpha = alphas[ai];
          entry[name] = roundN(getVal3D(data, mi, ai, bi), 6);
          betaEntry.data.push(entry);
        }
        machEntry.data.push(betaEntry);
      }
    } else {
      // Nesting: Mach → alpha → beta
      for (var ai2 = 0; ai2 < alphas.length; ai2++) {
        var alphaEntry = {};
        alphaEntry.alpha = alphas[ai2];
        alphaEntry.data = [];
        for (var bi2 = 0; bi2 < betas.length; bi2++) {
          var entry2 = {};
          entry2.beta = betas[bi2];
          entry2[name] = roundN(getVal3D(data, mi, ai2, bi2), 6);
          alphaEntry.data.push(entry2);
        }
        machEntry.data.push(alphaEntry);
      }
    }
    table.data.push(machEntry);
  }
  return table;
}

function getVal3D(data, mi, ai, bi) {
  if (!data || !data[mi]) return 0;
  if (Array.isArray(data[mi][ai])) return data[mi][ai][bi] || 0;
  if (typeof data[mi][ai] === 'number') return data[mi][ai];
  return 0;
}

// ================================================================
// DATCOM-based tail stall helpers (mirrors stall_estimation.jl)
// ================================================================

/**
 * Full-envelope lift model for an isolated tail surface.
 * Pre-stall: linear.  Post-stall: exponential decay to flat-plate sin·cos.
 * Mirrors tail_stall_CL() in merge.jl.
 */
function tailStallCL(alphaRad, CLaRad, CLmax, alphaStallRad, CD90) {
  var CL_fp = CD90 * Math.sin(alphaRad) * Math.cos(alphaRad);
  if (Math.abs(alphaRad) <= alphaStallRad) {
    return CLaRad * alphaRad;
  }
  var CL_peak = (alphaRad >= 0 ? 1 : -1) * CLmax;
  var delta = Math.abs(alphaRad) - alphaStallRad;
  var decay = Math.exp(-delta / (20 * Math.PI / 180));  // 20° e-folding
  return CL_peak * decay + CL_fp * (1 - decay);
}

/**
 * Full-envelope side-force model for an isolated vertical tail.
 * Pre-stall: linear. Post-stall: exponential decay to a flat-plate
 * cross-flow term proportional to sin(beta), so the fin remains restoring
 * in the rear quadrants and peaks near 90° sideslip.
 * Mirrors tail_stall_sideforce() in merge.jl.
 */
function tailStallSideforce(betaRad, CYbetaRad, CYmax, betaStallRad, CD90Lat) {
  var signRef = CYbetaRad >= 0 ? 1 : -1;
  var CYfp = signRef * CD90Lat * Math.sin(betaRad);
  if (Math.abs(betaRad) <= betaStallRad) {
    return CYbetaRad * betaRad;
  }
  var CYpeak = signRef * (betaRad >= 0 ? 1 : -1) * Math.abs(CYmax);
  var delta = Math.abs(betaRad) - betaStallRad;
  var decay = Math.exp(-delta / (20 * Math.PI / 180));  // 20° e-folding
  return CYpeak * decay + CYfp * (1 - decay);
}

/**
 * DATCOM section cl_max from thickness ratio (symmetric airfoil, zero camber).
 * Simplified from datcom_section_clmax() in stall_estimation.jl.
 * Assumes Re ≈ 6×10⁶, low Mach — appropriate for geometry fallback.
 */
function datcomSectionClmax(tc) {
  tc = Math.max(0.04, Math.min(tc, 0.25));
  if (tc < 0.06) return 0.85 + 3.0 * (tc - 0.04);
  if (tc < 0.10) return 0.91 + 4.5 * (tc - 0.06);
  if (tc < 0.15) return 1.09 + 3.6 * (tc - 0.10);
  if (tc < 0.21) return 1.27 + 1.0 * (tc - 0.15);
  return 1.33 - 1.0 * (tc - 0.21);
}

/**
 * DATCOM 3D correction ratio: CL_max_3D / cl_max_section.
 * Mirrors the k_taper × k_AR × k_sweep × k_twist logic in datcom_wing_clmax().
 */
function datcom3DRatio(AR, surf) {
  var TR = surf.TR || 0.5;
  var sweepDeg = surf.sweep_quarter_chord_deg || surf.sweep_quarter_chord_DEG || 0;
  var sweepRad = sweepDeg * Math.PI / 180;
  var twistDeg = surf.twist_tip_deg || surf.twist_tip_DEG || 0;
  var k_taper = 0.80 + 0.20 * TR;
  var k_AR = Math.max(0.85, Math.min(0.98, 0.95 - 0.01 * Math.max(AR - 6, 0)));
  var k_sweep = Math.pow(Math.cos(sweepRad), 0.5);
  var k_twist = 1.0 + 0.005 * twistDeg;
  return Math.max(0.70, Math.min(1.0, k_taper * k_AR * k_sweep * k_twist));
}

/**
 * Extract thickness ratio from a surface's airfoil field.
 * Handles NACA 4-digit: "0012" → 0.12, "0010" → 0.10.
 */
function getThicknessRatio(surf) {
  var af = surf.airfoil;
  if (!af) return 0.12;
  var root = af.root || '';
  // NACA 4-digit: last two digits are thickness percent
  var m = root.match(/(\d{2})$/);
  if (m) return parseInt(m[1], 10) / 100;
  return 0.12;  // default
}

// ================================================================
// HELPER: Build 1D tail tables
// ================================================================

function buildTailCLTable(model, ad, alphas) {
  // 1. Try pre-extracted table from runtime_model (Julia backend)
  //    May be 1D (alpha only) or 2D (alpha × elevator_deg) depending on
  //    whether AVL control derivatives were available during model creation.
  if (model && model.runtime_model && model.runtime_model.tail_CL) {
    var legacyTCL = model.runtime_model.tail_CL;
    if (legacyTCL.values && Array.isArray(legacyTCL.values)) {
      var tclAlphas = legacyTCL.alphas_deg || alphas;

      // Check for 2D table: values is array-of-arrays AND delta_e_deg axis exists
      if (legacyTCL.delta_e_deg && Array.isArray(legacyTCL.delta_e_deg) &&
          legacyTCL.values.length > 0 && Array.isArray(legacyTCL.values[0])) {
        return build2DTable('tail_CL', 'alpha', tclAlphas,
                            'elevator_deg', legacyTCL.delta_e_deg, legacyTCL.values);
      }

      // 1D table
      return build1DTable('tail_CL', 'alpha', tclAlphas, legacyTCL.values);
    }
  }

  // 2. Try per_surface_data (2D alpha×beta: extract beta=0 slice)
  if (model && model.per_surface_data) {
    var htailData = findPerSurfaceData(model.per_surface_data, 'horizontal_stabilizer', ad);
    if (htailData && htailData.CL && Array.isArray(htailData.CL)) {
      var betas = htailData.betas_deg || [0];
      var b0idx = closestIndex(betas, 0);
      var clSlice = htailData.CL.map(function(betaRow) {
        return Array.isArray(betaRow) ? (betaRow[b0idx] || 0) : betaRow;
      });
      var tclAlphas2 = htailData.alphas_deg || alphas;
      return build1DTable('tail_CL', 'alpha', tclAlphas2, clSlice);
    }
  }

  // 3. Fallback: DATCOM-based estimate with stall (full-envelope tail_stall_CL model)
  var htail = findSurfaceByRole(ad, 'horizontal_stabilizer');
  if (!htail) return null;
  var htailAR = htail.AR || 4;
  var CLa_rad = 2 * Math.PI * htailAR / (2 + Math.sqrt(4 + htailAR * htailAR)); // Helmbold
  var tc = getThicknessRatio(htail);
  var clMaxSection = datcomSectionClmax(tc);
  var clMax3D = clMaxSection * datcom3DRatio(htailAR, htail);
  var alphaStallRad = clMax3D / CLa_rad;
  var CD90 = 1.98;
  var data = alphas.map(function(a) {
    var aRad = a * Math.PI / 180;
    return roundN(tailStallCL(aRad, CLa_rad, clMax3D, alphaStallRad, CD90), 5);
  });
  return build1DTable('tail_CL', 'alpha', alphas, data);
}

function buildTailCSTable(model, ad, betas) {
  // 1. Try pre-extracted table from runtime_model (Julia backend)
  //    May be 1D (beta only) or 2D (beta × rudder_deg).
  if (model && model.runtime_model && model.runtime_model.tail_CS) {
    var legacyTCS = model.runtime_model.tail_CS;
    if (legacyTCS.values && Array.isArray(legacyTCS.values)) {
      var tcsBetas = legacyTCS.betas_deg || betas;

      // Check for 2D table: values is array-of-arrays AND delta_r_deg axis exists
      if (legacyTCS.delta_r_deg && Array.isArray(legacyTCS.delta_r_deg) &&
          legacyTCS.values.length > 0 && Array.isArray(legacyTCS.values[0])) {
        return build2DTable('tail_CS', 'beta', tcsBetas,
                            'rudder_deg', legacyTCS.delta_r_deg, legacyTCS.values);
      }

      // 1D table
      return build1DTable('tail_CS', 'beta', tcsBetas, legacyTCS.values);
    }
  }

  // 2. Try per_surface_data (2D alpha×beta: extract alpha=0 row, CY column)
  if (model && model.per_surface_data) {
    var vtailData = findPerSurfaceData(model.per_surface_data, 'vertical_stabilizer', ad);
    if (vtailData && vtailData.CY && Array.isArray(vtailData.CY)) {
      var vtAlphas = vtailData.alphas_deg || [0];
      var a0idx = closestIndex(vtAlphas, 0);
      var cyRow = vtailData.CY[a0idx];
      if (Array.isArray(cyRow)) {
        var tcsBetas2 = vtailData.betas_deg || betas;
        return build1DTable('tail_CS', 'beta', tcsBetas2, cyRow);
      }
    }
  }

  // 3. Fallback: DATCOM-based estimate with stall (full-envelope tail_stall_CL model)
  var vtail = findSurfaceByRole(ad, 'vertical_stabilizer');
  if (!vtail) return null;
  var vtailAR = vtail.AR || 2;
  var CYb_rad = -2 * Math.PI * vtailAR / (2 + Math.sqrt(4 + vtailAR * vtailAR)); // +beta -> restoring (negative CY)
  var tc = getThicknessRatio(vtail);
  var cyMaxSection = datcomSectionClmax(tc);
  var cyMax3D = cyMaxSection * datcom3DRatio(vtailAR, vtail);
  var betaStallRad = cyMax3D / CYb_rad;
  var CD90 = 1.98;
  var data = betas.map(function(b) {
    var bRad = b * Math.PI / 180;
    return roundN(tailStallSideforce(bRad, CYb_rad, Math.abs(cyMax3D), Math.abs(betaStallRad), CD90), 5);
  });
  return build1DTable('tail_CS', 'beta', betas, data);
}

function buildDownwashTable(model, ad, alphas) {
  var gen = ad.general || {};
  var bref = gen.aircraft_reference_span_m || 10;
  var Sref = resolveReferenceAreaM2(gen);
  var AR = bref * bref / Sref;

  // Try local_flow from model
  if (model && model.aerodynamics && model.aerodynamics.local_flow &&
      model.aerodynamics.local_flow.downwash_deg) {
    var dw = model.aerodynamics.local_flow.downwash_deg;
    if (dw.values) {
      var configs = Object.keys(dw.values);
      var vals = dw.values[configs[0]];
      if (Array.isArray(vals) && Array.isArray(vals[0])) {
        return build1DTable('Horizontal_tail_downwash_deg', 'alpha', alphas, vals[0]);
      }
    }
  }

  // Fallback: dε/dα ≈ 2*CL_alpha_wing / (π*AR)
  var CLa = 2 * Math.PI / (1 + 2 / AR);
  var deda = 2 * CLa / (Math.PI * AR);
  var data = alphas.map(function(a) {
    var eps = deda * a;
    return roundN(Math.max(-12, Math.min(12, eps)), 4);
  });
  return build1DTable('Horizontal_tail_downwash_deg', 'alpha', alphas, data);
}

function buildSidewashTable(model, ad, betas) {
  var data = betas.map(function(b) {
    return roundN(-0.18 * b, 4);
  });
  return build1DTable('Vertical_tail_sidewash_deg', 'beta', betas, data);
}

function buildDPRTable(model, ad, alphas) {
  var data = alphas.map(function(a) {
    var ratio = 0.95 - 0.005 * Math.abs(a);
    return roundN(Math.max(0.5, Math.min(1.0, ratio)), 4);
  });
  return build1DTable('tail_dynamic_pressure_ratio', 'alpha', alphas, data);
}

function build1DTable(name, paramName, paramValues, values) {
  var table = { parameters: [paramName], data: [] };
  for (var i = 0; i < paramValues.length; i++) {
    var entry = {};
    entry[paramName] = paramValues[i];
    entry[name] = values[i] !== undefined ? values[i] : 0;
    table.data.push(entry);
  }
  return table;
}

function build2DTable(name, param1Name, param1Values, param2Name, param2Values, values2D) {
  var table = { parameters: [param1Name, param2Name], data: [] };
  for (var i = 0; i < param1Values.length; i++) {
    var entry = {};
    entry[param1Name] = param1Values[i];
    entry.data = [];
    var row = (values2D && values2D[i]) || [];
    for (var j = 0; j < param2Values.length; j++) {
      var subEntry = {};
      subEntry[param2Name] = param2Values[j];
      subEntry[name] = (row[j] !== undefined) ? row[j] : 0;
      entry.data.push(subEntry);
    }
    table.data.push(entry);
  }
  return table;
}

// ================================================================
// DERIVATIVE EXTRACTION
// ================================================================

function extractScalarDerivatives(model) {
  var d = {};
  if (!model) return d;

  // Try pre-computed scalar derivatives from Julia backend
  if (model.runtime_model) {
    var sd = model.runtime_model.scalar_derivatives || model.runtime_model;
    // Map Julia keys to legacy constant names
    if (sd.Cm0 !== undefined) d.Cm0 = sd.Cm0;
    if (sd.Cm_alpha !== undefined) d.Cm_alpha = sd.Cm_alpha;
    if (sd.Cl_beta !== undefined) d.Cl_beta = sd.Cl_beta;
    if (sd.Cn_beta !== undefined) d.Cn_beta = sd.Cn_beta;
    if (sd.Cl_p_hat !== undefined) d.Cl_p = sd.Cl_p_hat;
    if (sd.Cm_q_hat !== undefined) d.Cm_q = sd.Cm_q_hat;
    if (sd.Cn_r_hat !== undefined) d.Cn_r = sd.Cn_r_hat;
    if (sd.Cm_de_per_deg !== undefined) d.Cm_de = sd.Cm_de_per_deg;
    if (sd.Cl_da_per_deg !== undefined) d.Cl_da = sd.Cl_da_per_deg;
    if (sd.Cn_dr_per_deg !== undefined) d.Cn_dr = sd.Cn_dr_per_deg;
  }

  if (!model.aerodynamics) return d;
  var aero = model.aerodynamics;

  // From dynamic_derivatives at alpha closest to 0
  if (aero.dynamic_derivatives) {
    var dd = aero.dynamic_derivatives;
    var alphas = (dd.axes && dd.axes.alpha_deg) || [0];
    var configs = (dd.axes && dd.axes.config) || ['clean'];
    var cfg = configs[0];
    var a0idx = closestIndex(alphas, 0);

    var derivMap = {
      'Cl_p_hat': 'Cl_p', 'Cm_q_hat': 'Cm_q', 'Cn_r_hat': 'Cn_r',
      'CY_p_hat': 'CY_p', 'CL_q_hat': 'CL_q', 'CY_r_hat': 'CY_r'
    };
    Object.keys(derivMap).forEach(function(key) {
      if (dd[key] && dd[key].values && dd[key].values[cfg]) {
        var machData = dd[key].values[cfg][0]; // First Mach
        if (machData && machData[a0idx] !== undefined) {
          d[derivMap[key]] = roundN(machData[a0idx], 6);
        }
      }
    });
  }

  // From control_effectiveness
  if (aero.control_effectiveness) {
    var ce = aero.control_effectiveness;
    var ceAlphas = (ce.axes && ce.axes.alpha_deg) || [0];
    var ceConfigs = (ce.axes && ce.axes.config) || ['clean'];
    var ceCfg = ceConfigs[0];
    var ceA0 = closestIndex(ceAlphas, 0);

    // Map control effectiveness names to legacy derivatives
    var ceMap = {
      'Cm_de_per_deg': { key: 'Cm_de', scale: 1 },
      'Cl_da_per_deg': { key: 'Cl_da', scale: 1 },
      'Cn_dr_per_deg': { key: 'Cn_dr', scale: 1 },
      'Cn_da_per_deg': { key: 'Cn_da', scale: 1 }
    };
    Object.keys(ceMap).forEach(function(name) {
      if (ce[name] && ce[name].values && ce[name].values[ceCfg]) {
        var machData = ce[name].values[ceCfg][0];
        if (machData && machData[ceA0] !== undefined) {
          d[ceMap[name].key] = roundN(machData[ceA0] * ceMap[name].scale, 6);
        }
      }
    });
  }

  // From static coefficients - extract Cm0, Cm_alpha, Cl_beta, Cn_beta
  if (aero.static_coefficients) {
    var sc = aero.static_coefficients;
    var scAxes = sc.axes || {};
    var scAlphas = scAxes.alpha_deg || [0];
    var scBetas = scAxes.beta_deg || [0];
    var scConfigs = scAxes.config || ['clean'];
    var scCfg = scConfigs[0];
    var scA0 = closestIndex(scAlphas, 0);
    var scB0 = closestIndex(scBetas, 0);

    // Cm0 = Cm at alpha=0, beta=0
    if (sc.Cm && sc.Cm.values && sc.Cm.values[scCfg]) {
      var cmVal = getVal3D(sc.Cm.values[scCfg], 0, scA0, scB0);
      d.Cm0 = roundN(cmVal, 6);
      d.Cm_trim = 0;

      // Cm_alpha = slope of Cm vs alpha near alpha=0
      if (scA0 > 0 && scA0 < scAlphas.length - 1) {
        var cm1 = getVal3D(sc.Cm.values[scCfg], 0, scA0 - 1, scB0);
        var cm2 = getVal3D(sc.Cm.values[scCfg], 0, scA0 + 1, scB0);
        var dalpha = scAlphas[scA0 + 1] - scAlphas[scA0 - 1];
        if (dalpha > 0) d.Cm_alpha = roundN((cm2 - cm1) / dalpha, 6);
      }
    }

    // Cl_beta = slope of Cl vs beta near beta=0
    if (sc.Cl && sc.Cl.values && sc.Cl.values[scCfg]) {
      if (scB0 > 0 && scB0 < scBetas.length - 1) {
        var cl1 = getVal3D(sc.Cl.values[scCfg], 0, scA0, scB0 - 1);
        var cl2 = getVal3D(sc.Cl.values[scCfg], 0, scA0, scB0 + 1);
        var dbeta = scBetas[scB0 + 1] - scBetas[scB0 - 1];
        if (dbeta > 0) d.Cl_beta = roundN((cl2 - cl1) / dbeta, 6);
      }
    }

    // Cn_beta = slope of Cn vs beta near beta=0
    if (sc.Cn && sc.Cn.values && sc.Cn.values[scCfg]) {
      if (scB0 > 0 && scB0 < scBetas.length - 1) {
        var cn1 = getVal3D(sc.Cn.values[scCfg], 0, scA0, scB0 - 1);
        var cn2 = getVal3D(sc.Cn.values[scCfg], 0, scA0, scB0 + 1);
        var dbeta2 = scBetas[scB0 + 1] - scBetas[scB0 - 1];
        if (dbeta2 > 0) d.Cn_beta = roundN((cn2 - cn1) / dbeta2, 6);
      }
    }
  }

  return d;
}

// ================================================================
// PROPULSION SECTION (multi-engine support)
// ================================================================

function buildPropulsionSection(ad) {
  var engines = ad.engines || [];
  if (engines.length <= 1) return null; // Single engine handled by constants

  return {
    engines: engines.map(function(e) {
      var orient = e.orientation_deg || {};
      var pitchRad = (orient.pitch || 0) * Math.PI / 180;
      var yawRad = (orient.yaw || 0) * Math.PI / 180;
      var dir = [
        Math.cos(pitchRad) * Math.cos(yawRad),
        Math.sin(pitchRad),
        Math.cos(pitchRad) * Math.sin(yawRad)
      ];
      return {
        id: e.id || 'ENG',
        max_thrust_n: e.max_thrust_n || (e.thrust_scale || 1) * 1000,
        position_body_m: e.position_m || [0, 0, 0],
        direction_body: dir.map(function(v) { return roundN(v, 4); }),
        throttle_channel: e.throttle_channel || 1,
        spool_up_speed: e.spool_up_1_s || 1.3,
        spool_down_speed: e.spool_down_1_s || 1.1,
        reverse_thrust_ratio: e.reverse_thrust_ratio || 0,
        // Pass through the raw SHP rating (if set via gemini-assistant's
        // propeller path) so the exported yaml retains a paper trail of
        // where max_thrust_n came from. Runtime ignores these fields.
        engine_type: e.engine_type || null,
        shaft_horsepower: e.shaft_horsepower || null,
        propeller_efficiency: e.propeller_efficiency || null
      };
    })
  };
}

// ================================================================
// VISUAL GEOMETRY BUILDER
// ================================================================

function buildVisualGeometry(ad) {
  var gen = ad.general || {};
  var CoG = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];
  var vg = {};

  // Geometry authored in Model Creator uses x increasing from nose toward tail and z up.
  // Keep that explicit here so the runtime can convert it to its local
  // forward-positive mesh convention without guessing.
  vg.coordinate_system = 'x_aft_y_right_z_up';
  vg.cg_position_m = { x: CoG[0], y: CoG[1] || 0, z: CoG[2] || 0 };
  vg.reference_span_m = gen.aircraft_reference_span_m || 10;
  vg.reference_chord_m = gen.aircraft_reference_mean_aerodynamic_chord_m || 1;

  // Lifting surfaces
  var surfaces = ad.lifting_surfaces || [];
  vg.lifting_surfaces = surfaces.map(function(s) {
    var rootLE = s.root_LE || [0, 0, 0];
    var role = String(s.role || '').toLowerCase();
    var isVertical = !!s.vertical || role === 'vertical_stabilizer';
    var isSymmetric = (s.symmetric !== undefined) ? !!s.symmetric :
      ((s.mirror !== undefined) ? !!s.mirror : !isVertical);
    var area = s.surface_area_m2 || 0;
    var taperRatio = s.TR || 1;
    var computedSpan = (area > 0 && s.AR > 0) ? Math.sqrt(area * s.AR) : 0;
    var spanForChord = s.span_m || computedSpan || 10;
    var panelSpan = isVertical
      ? (s.span_m || s.semi_span_m || spanForChord)
      : (s.semi_span_m || (isSymmetric ? spanForChord / 2 : spanForChord));
    var visualSpan = isVertical ? panelSpan : (isSymmetric ? panelSpan * 2 : panelSpan);
    var rootChord = s.root_chord_m ||
      ((area > 0 && spanForChord > 0) ? (2 * area) / (spanForChord * (1 + taperRatio)) : (s.mean_aerodynamic_chord_m || 1));
    var tipChord = s.tip_chord_m || rootChord * taperRatio;
    var meanChord = s.mean_aerodynamic_chord_m ||
      ((2 / 3) * rootChord * (1 + taperRatio + taperRatio * taperRatio) / (1 + taperRatio));
    var sweepQC = deg2rad(s.sweep_quarter_chord_DEG || 0);
    var sweepLE = Math.atan(Math.tan(sweepQC) + 0.25 * (rootChord - tipChord) / Math.max(panelSpan, 1e-6));
    var dihedral = (s.dihedral_DEG || 0) * Math.PI / 180;

    var sd = {
      name: s.name || 'surface',
      role: s.role || 'wing',
      root_LE_m: { x: rootLE[0], y: rootLE[1] || 0, z: rootLE[2] || 0 },
      root_chord_m: roundN(rootChord, 4),
      tip_chord_m: roundN(tipChord, 4),
      semi_span_m: roundN(panelSpan, 4),
      span_m: roundN(visualSpan, 4),
      sweep_quarter_chord_deg: s.sweep_quarter_chord_DEG || 0,
      dihedral_deg: s.dihedral_DEG || 0,
      incidence_deg: s.incidence_DEG || 0,
      mirror: isSymmetric,
      symmetric: isSymmetric,
      vertical: isVertical,
      surface_area_m2: s.surface_area_m2 || 0,
      AR: s.AR || 0,
      TR: s.TR || 1,
      mean_aerodynamic_chord_m: roundN(meanChord, 4)
    };

    // Aerodynamic center
    var ac = computeAC(Object.assign({}, s, { vertical: isVertical }));
    sd.aerodynamic_center_m = { x: roundN(ac[0], 4), y: ac[1] || 0, z: ac[2] || 0 };

    // Tip LE
    var tipX = rootLE[0] + panelSpan * Math.tan(sweepLE);
    var tipY = (rootLE[1] || 0) + (isVertical ? 0 : panelSpan);
    var tipZ = (rootLE[2] || 0) + (isVertical ? panelSpan : panelSpan * Math.sin(dihedral));
    sd.tip_LE_m = { x: roundN(tipX, 4), y: roundN(tipY, 4), z: roundN(tipZ, 4) };

    return sd;
  });

  // Fuselages
  var fuselages = ad.fuselages || [];
  vg.fuselages = fuselages.map(function(f) {
    var nose = f.nose_position || [0, 0, 0];
    return {
      name: f.name || 'fuselage',
      diameter_m: f.diameter || 1,
      length_m: f.length || 5,
      nose_position_m: { x: nose[0], y: nose[1] || 0, z: nose[2] || 0 }
    };
  });

  // Engines
  var engines = ad.engines || [];
  vg.engines = engines.map(function(e) {
    var pos = e.position_m || [0, 0, 0];
    return {
      id: e.id || 'ENG',
      position_m: { x: pos[0], y: pos[1] || 0, z: pos[2] || 0 },
      orientation_deg: e.orientation_deg || { pitch: 0, yaw: 0 }
    };
  });

  vg.lights = buildVisualLightPositions(ad, vg);
  vg.propeller = buildVisualPropeller(ad);

  return vg;
}

function getSurfaceVisualPlanform(surface) {
  var s = surface || {};
  var rootLE = s.root_LE || [0, 0, 0];
  var role = String(s.role || '').toLowerCase();
  var isVertical = !!s.vertical || role === 'vertical_stabilizer';
  var isSymmetric = (s.symmetric !== undefined) ? !!s.symmetric :
    ((s.mirror !== undefined) ? !!s.mirror : !isVertical);
  var area = s.surface_area_m2 || 0;
  var AR = s.AR || 0;
  var taperRatio = s.TR || 1;
  var computedSpan = (area > 0 && AR > 0) ? Math.sqrt(area * AR) : 0;
  var spanForChord = s.span_m || computedSpan || 10;
  var panelSpan = isVertical
    ? (s.span_m || s.semi_span_m || spanForChord)
    : (s.semi_span_m || (isSymmetric ? spanForChord / 2 : spanForChord));
  var rootChord = s.root_chord_m ||
    ((area > 0 && spanForChord > 0) ? (2 * area) / (spanForChord * (1 + taperRatio)) : (s.mean_aerodynamic_chord_m || 1));
  var tipChord = s.tip_chord_m || rootChord * taperRatio;

  return {
    rootLE: rootLE,
    isVertical: isVertical,
    isSymmetric: isSymmetric,
    spanForChord: spanForChord,
    panelSpan: panelSpan,
    rootChord: rootChord,
    tipChord: tipChord,
    sweepLE: Math.atan(Math.tan(deg2rad(s.sweep_quarter_chord_DEG || 0)) + 0.25 * (rootChord - tipChord) / Math.max(panelSpan, 1e-6)),
    dihedral: deg2rad(s.dihedral_DEG || 0)
  };
}

function buildVisualLightPositions(ad, vg) {
  var lights = {};
  var gen = ad.general || {};
  var CoG = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];
  var wing = findSurfaceByRole(ad, 'wing');
  var htail = findSurfaceByRole(ad, 'horizontal_stabilizer');
  var vtail = findSurfaceByRole(ad, 'vertical_stabilizer');

  if (wing) {
    var wingGeom = getSurfaceVisualPlanform(wing);
    var wingRoot = wingGeom.rootLE;
    lights.wing_tip_position_m = {
      x: roundN((wingRoot[0] || 0) + wingGeom.panelSpan * Math.tan(wingGeom.sweepLE) + wingGeom.tipChord * 0.5, 3),
      y: roundN((wingRoot[1] || 0) + wingGeom.panelSpan, 3),
      z: roundN((wingRoot[2] || 0) + wingGeom.panelSpan * Math.sin(wingGeom.dihedral), 3)
    };
  }

  var tailX = (CoG[0] || 0) + 3.0;
  var tailY = 0;
  var tailZ = 0;
  if (htail) {
    var htailGeom = getSurfaceVisualPlanform(htail);
    var htailRoot = htailGeom.rootLE;
    tailX = (htailRoot[0] || 0) + htailGeom.rootChord;
    tailY = htailRoot[1] || 0;
    tailZ = htailRoot[2] || 0;
  } else if (ad.fuselages && ad.fuselages.length > 0) {
    var fus = ad.fuselages[0];
    var nose = fus.nose_position || [0, 0, 0];
    tailX = (nose[0] || 0) + (fus.length || 0);
    tailY = nose[1] || 0;
    tailZ = nose[2] || 0;
  }
  lights.tailcone_position_m = {
    x: roundN(tailX, 3),
    y: roundN(tailY, 3),
    z: roundN(tailZ, 3)
  };

  if (vtail) {
    var vtailGeom = getSurfaceVisualPlanform(vtail);
    var vtailRoot = vtailGeom.rootLE;
    lights.strobe_position_m = {
      x: roundN((vtailRoot[0] || 0) + vtailGeom.panelSpan * Math.tan(vtailGeom.sweepLE) + vtailGeom.tipChord * 0.5, 3),
      y: roundN(vtailRoot[1] || 0, 3),
      z: roundN((vtailRoot[2] || 0) + vtailGeom.panelSpan, 3)
    };
  }

  return lights;
}

function buildVisualPropeller(ad) {
  var prop = {};
  var engines = ad.engines || [];
  if (!engines.length) return prop;

  var engine = engines[0];
  for (var i = 1; i < engines.length; i++) {
    var currentX = (engines[i].position_m || [0])[0] || 0;
    var bestX = (engine.position_m || [0])[0] || 0;
    if (currentX < bestX) engine = engines[i];
  }

  var pos = engine.position_m || [0, 0, 0];
  var maxThrust = engine.max_thrust_n || (engine.thrust_scale || 1) * 1000;
  var diameter = 0.6 * Math.sqrt(maxThrust / 500);
  prop.position_m = { x: pos[0], y: pos[1] || 0, z: pos[2] || 0 };
  prop.diameter_m = roundN(Math.max(0.5, Math.min(4.0, diameter)), 2);
  return prop;
}

// ================================================================
// LEGACY YAML SERIALIZER
// ================================================================

function serializeLegacyYAML(constants, coefficients, propulsion, visualGeometry) {
  var lines = [];
  lines.push('# ═══════════════════════════════════════════════════════════');
  lines.push('# OpenFlight Legacy Aircraft Aerodynamic Model');
  lines.push('# Generated by Aircraft Model Creator');
  lines.push('# ═══════════════════════════════════════════════════════════');
  lines.push('');

  // ---- Constants ----
  lines.push('constants:');

  var constGroups = [
    { title: 'Mass & Inertia', keys: ['aircraft_mass', 'radius_of_giration_pitch', 'radius_of_giration_yaw', 'radius_of_giration_roll', 'principal_axis_pitch_up_DEG', 'x_CoG', 'y_CoG', 'z_CoG'] },
    { title: 'Wing Geometry', keys: ['x_wing_aerodynamic_center', 'y_wing_aerodynamic_center', 'z_wing_aerodynamic_center', 'x_wing_fuselage_aerodynamic_center', 'y_wing_fuselage_aerodynamic_center', 'z_wing_fuselage_aerodynamic_center', 'reference_area', 'reference_span', 'AR', 'Oswald_factor', 'wing_mean_aerodynamic_chord', 'Sideslip_drag_K_factor'] },
    { title: 'Tail Geometry', keys: ['tail_reference_area', 'x_tail_aerodynamic_center', 'y_tail_aerodynamic_center', 'z_tail_aerodynamic_center', 'x_horizontal_tail_aerodynamic_center', 'y_horizontal_tail_aerodynamic_center', 'z_horizontal_tail_aerodynamic_center', 'x_vertical_tail_aerodynamic_center', 'y_vertical_tail_aerodynamic_center', 'z_vertical_tail_aerodynamic_center', 'tail_CL_q', 'tail_CS_r', 'tail_CD0', 'tail_k_induced', 'tail_k_side', 'scale_tail_forces'] },
    { title: 'Neutral Point', keys: ['x_neutral_point', 'static_margin_MAC'] },
    { title: 'Stability Derivatives', keys: ['Cm0', 'Cm_trim', 'Cl_beta', 'Cm_alpha', 'Cn_beta'] },
    { title: 'Damping Derivatives', keys: ['Cl_p', 'Cm_q', 'Cn_r'] },
    { title: 'Control Derivatives', keys: ['Cl_da', 'Cm_de', 'Cn_dr', 'Cn_da'] },
    { title: 'Stall Parameters', keys: ['alpha_stall_positive', 'alpha_stall_negative', 'CL_max', 'CD0'] },
    { title: 'Dynamic Stall', keys: ['dynamic_stall_alpha_on_deg', 'dynamic_stall_alpha_off_deg', 'dynamic_stall_tau_alpha_s', 'dynamic_stall_tau_sigma_rise_s', 'dynamic_stall_tau_sigma_fall_s', 'dynamic_stall_qhat_to_alpha_deg', 'poststall_cl_scale', 'poststall_cd90', 'poststall_cd_min', 'poststall_sideforce_scale'] },
    { title: 'Propulsion', keys: ['maximum_thrust_at_sea_level', 'thrust_installation_angle_DEG', 'control_actuator_speed', 'engine_spool_up_speed', 'engine_spool_down_speed'] }
  ];

  constGroups.forEach(function(group) {
    lines.push('');
    lines.push('  # ' + group.title);
    group.keys.forEach(function(key) {
      if (constants.hasOwnProperty(key)) {
        lines.push('  ' + key + ': ' + formatYamlNumber(constants[key]));
      }
    });
  });

  // ---- Coefficients ----
  lines.push('');
  lines.push('coefficients:');

  var coeffOrder = ['CL', 'CS', 'CD0', 'tail_CL', 'tail_CS',
    'Horizontal_tail_downwash_deg', 'Vertical_tail_sidewash_deg',
    'tail_dynamic_pressure_ratio'];

  coeffOrder.forEach(function(name) {
    if (!coefficients[name]) return;
    var coeff = coefficients[name];
    lines.push('');
    lines.push('  ' + name + ':');
    lines.push('    parameters: [' + coeff.parameters.join(', ') + ']');
    lines.push('    data:');
    serializeNestedData(lines, coeff.data, 6, coeff.parameters, 0, name);
  });

  // ---- Multi-engine propulsion ----
  if (propulsion && propulsion.engines) {
    lines.push('');
    lines.push('propulsion:');
    lines.push('  engines:');
    propulsion.engines.forEach(function(eng) {
      lines.push('    - id: ' + eng.id);
      lines.push('      max_thrust_n: ' + formatYamlNumber(eng.max_thrust_n));
      lines.push('      position_body_m: [' + eng.position_body_m.map(formatYamlNumber).join(', ') + ']');
      lines.push('      direction_body: [' + eng.direction_body.map(formatYamlNumber).join(', ') + ']');
      lines.push('      throttle_channel: ' + eng.throttle_channel);
      lines.push('      spool_up_speed: ' + formatYamlNumber(eng.spool_up_speed));
      lines.push('      spool_down_speed: ' + formatYamlNumber(eng.spool_down_speed));
      lines.push('      reverse_thrust_ratio: ' + formatYamlNumber(eng.reverse_thrust_ratio));
      // Paper-trail fields: if the engine was rated by SHP (propeller
      // aircraft) keep the source numbers so a human reviewer can
      // double-check the HP→N conversion that landed in max_thrust_n.
      if (eng.engine_type) {
        lines.push('      engine_type: ' + eng.engine_type);
      }
      if (typeof eng.shaft_horsepower === 'number') {
        lines.push('      shaft_horsepower: ' + formatYamlNumber(eng.shaft_horsepower));
      }
      if (typeof eng.propeller_efficiency === 'number') {
        lines.push('      propeller_efficiency: ' + formatYamlNumber(eng.propeller_efficiency));
      }
    });
  }

  // ---- Visual Geometry ----
  if (visualGeometry) {
    lines.push('');
    lines.push('visual_geometry:');
    lines.push('  coordinate_system: ' + visualGeometry.coordinate_system);
    if (visualGeometry.cg_position_m) {
      lines.push('  cg_position_m:');
      lines.push('    x: ' + formatYamlNumber(visualGeometry.cg_position_m.x));
      lines.push('    y: ' + formatYamlNumber(visualGeometry.cg_position_m.y));
      lines.push('    z: ' + formatYamlNumber(visualGeometry.cg_position_m.z));
    }
    lines.push('  reference_span_m: ' + formatYamlNumber(visualGeometry.reference_span_m));
    lines.push('  reference_chord_m: ' + formatYamlNumber(visualGeometry.reference_chord_m));

    if (visualGeometry.lifting_surfaces && visualGeometry.lifting_surfaces.length > 0) {
      lines.push('  lifting_surfaces:');
      visualGeometry.lifting_surfaces.forEach(function(s) {
        lines.push('    - name: ' + s.name);
        lines.push('      role: ' + s.role);
        lines.push('      root_LE_m:');
        lines.push('        x: ' + formatYamlNumber(s.root_LE_m.x));
        lines.push('        y: ' + formatYamlNumber(s.root_LE_m.y));
        lines.push('        z: ' + formatYamlNumber(s.root_LE_m.z));
        lines.push('      root_chord_m: ' + formatYamlNumber(s.root_chord_m));
        lines.push('      tip_chord_m: ' + formatYamlNumber(s.tip_chord_m));
        lines.push('      semi_span_m: ' + formatYamlNumber(s.semi_span_m));
        lines.push('      span_m: ' + formatYamlNumber(s.span_m));
        lines.push('      sweep_quarter_chord_deg: ' + formatYamlNumber(s.sweep_quarter_chord_deg));
        lines.push('      dihedral_deg: ' + formatYamlNumber(s.dihedral_deg));
        lines.push('      incidence_deg: ' + formatYamlNumber(s.incidence_deg));
        lines.push('      mirror: ' + s.mirror);
        if (typeof s.symmetric === 'boolean') {
          lines.push('      symmetric: ' + s.symmetric);
        }
        lines.push('      vertical: ' + s.vertical);
        lines.push('      surface_area_m2: ' + formatYamlNumber(s.surface_area_m2));
        lines.push('      AR: ' + formatYamlNumber(s.AR));
        lines.push('      TR: ' + formatYamlNumber(s.TR));
        lines.push('      mean_aerodynamic_chord_m: ' + formatYamlNumber(s.mean_aerodynamic_chord_m));
        lines.push('      aerodynamic_center_m:');
        lines.push('        x: ' + formatYamlNumber(s.aerodynamic_center_m.x));
        lines.push('        y: ' + formatYamlNumber(s.aerodynamic_center_m.y));
        lines.push('        z: ' + formatYamlNumber(s.aerodynamic_center_m.z));
        lines.push('      tip_LE_m:');
        lines.push('        x: ' + formatYamlNumber(s.tip_LE_m.x));
        lines.push('        y: ' + formatYamlNumber(s.tip_LE_m.y));
        lines.push('        z: ' + formatYamlNumber(s.tip_LE_m.z));
      });
    }

    if (visualGeometry.fuselages && visualGeometry.fuselages.length > 0) {
      lines.push('  fuselages:');
      visualGeometry.fuselages.forEach(function(f) {
        lines.push('    - name: ' + f.name);
        lines.push('      diameter_m: ' + formatYamlNumber(f.diameter_m));
        lines.push('      length_m: ' + formatYamlNumber(f.length_m));
        lines.push('      nose_position_m:');
        lines.push('        x: ' + formatYamlNumber(f.nose_position_m.x));
        lines.push('        y: ' + formatYamlNumber(f.nose_position_m.y));
        lines.push('        z: ' + formatYamlNumber(f.nose_position_m.z));
      });
    }

    if (visualGeometry.engines && visualGeometry.engines.length > 0) {
      lines.push('  engines:');
      visualGeometry.engines.forEach(function(e) {
        lines.push('    - id: ' + e.id);
        lines.push('      position_m:');
        lines.push('        x: ' + formatYamlNumber(e.position_m.x));
        lines.push('        y: ' + formatYamlNumber(e.position_m.y));
        lines.push('        z: ' + formatYamlNumber(e.position_m.z));
        lines.push('      orientation_deg:');
        lines.push('        pitch: ' + formatYamlNumber(e.orientation_deg.pitch || 0));
        lines.push('        yaw: ' + formatYamlNumber(e.orientation_deg.yaw || 0));
      });
    }

    if (visualGeometry.lights && (
        visualGeometry.lights.wing_tip_position_m ||
        visualGeometry.lights.tailcone_position_m ||
        visualGeometry.lights.strobe_position_m)) {
      lines.push('  lights:');
      if (visualGeometry.lights.wing_tip_position_m) {
        lines.push('    wing_tip_position_m:');
        lines.push('      x: ' + formatYamlNumber(visualGeometry.lights.wing_tip_position_m.x));
        lines.push('      y: ' + formatYamlNumber(visualGeometry.lights.wing_tip_position_m.y));
        lines.push('      z: ' + formatYamlNumber(visualGeometry.lights.wing_tip_position_m.z));
      }
      if (visualGeometry.lights.tailcone_position_m) {
        lines.push('    tailcone_position_m:');
        lines.push('      x: ' + formatYamlNumber(visualGeometry.lights.tailcone_position_m.x));
        lines.push('      y: ' + formatYamlNumber(visualGeometry.lights.tailcone_position_m.y));
        lines.push('      z: ' + formatYamlNumber(visualGeometry.lights.tailcone_position_m.z));
      }
      if (visualGeometry.lights.strobe_position_m) {
        lines.push('    strobe_position_m:');
        lines.push('      x: ' + formatYamlNumber(visualGeometry.lights.strobe_position_m.x));
        lines.push('      y: ' + formatYamlNumber(visualGeometry.lights.strobe_position_m.y));
        lines.push('      z: ' + formatYamlNumber(visualGeometry.lights.strobe_position_m.z));
      }
    }

    if (visualGeometry.propeller && visualGeometry.propeller.position_m) {
      lines.push('  propeller:');
      lines.push('    position_m:');
      lines.push('      x: ' + formatYamlNumber(visualGeometry.propeller.position_m.x));
      lines.push('      y: ' + formatYamlNumber(visualGeometry.propeller.position_m.y));
      lines.push('      z: ' + formatYamlNumber(visualGeometry.propeller.position_m.z));
      lines.push('    diameter_m: ' + formatYamlNumber(visualGeometry.propeller.diameter_m));
    }
  }

  lines.push('');
  return lines.join('\n');
}

function serializeNestedData(lines, data, indent, params, depth, coeffName) {
  var pad = ' '.repeat(indent);
  var paramName = params[depth];

  data.forEach(function(entry) {
    if (depth < params.length - 1) {
      // Intermediate level
      lines.push(pad + '- ' + paramName + ': ' + formatYamlNumber(entry[paramName]));
      lines.push(pad + '  data:');
      serializeNestedData(lines, entry.data, indent + 4, params, depth + 1, coeffName);
    } else {
      // Leaf level
      lines.push(pad + '- ' + paramName + ': ' + formatYamlNumber(entry[paramName]));
      lines.push(pad + '  ' + coeffName + ': ' + formatYamlNumber(entry[coeffName]));
    }
  });
}

// ================================================================
// UTILITY FUNCTIONS
// ================================================================

function findSurfaceByRole(ad, role) {
  var surfaces = ad.lifting_surfaces || [];
  var found = surfaces.find(function(s) { return s.role === role; });
  if (found) return found;

  // Fallback: match by name patterns
  var patterns = {
    'wing': /^(wing|main_?wing)/i,
    'horizontal_stabilizer': /^(h?tail|horizontal|h_?stab|elevator)/i,
    'vertical_stabilizer': /^(v?tail|vertical|v_?stab|fin|rudder)/i,
    'canard': /^canard/i
  };
  var pat = patterns[role];
  if (pat) {
    found = surfaces.find(function(s) { return pat.test(s.name); });
  }
  return found || null;
}

function findPerSurfaceData(perSurfData, role, ad) {
  if (!perSurfData) return null;
  // Try direct role key
  if (perSurfData[role]) return perSurfData[role];
  // Try surface name
  var surf = findSurfaceByRole(ad, role);
  if (surf && perSurfData[surf.name]) return perSurfData[surf.name];
  return null;
}

function computeTailArea(htail, vtail) {
  var area = 0;
  if (htail) area += htail.surface_area_m2 || 0;
  if (vtail) area += vtail.surface_area_m2 || 0;
  return area || 2.0;
}

function computeAC(surface) {
  if (!surface) return [0, 0, 0];
  var rootLE = surface.root_LE || [0, 0, 0];
  var area = surface.surface_area_m2 || 0;
  var AR = surface.AR || 0;
  var TR = surface.TR != null ? surface.TR : 1;
  var sweepQC = deg2rad(surface.sweep_quarter_chord_DEG || 0);
  var role = String(surface.role || '').toLowerCase();
  var vertical = !!surface.vertical || role === 'vertical_stabilizer';
  var isSymmetric = (surface.symmetric !== undefined) ? !!surface.symmetric :
    ((surface.mirror !== undefined) ? !!surface.mirror : !vertical);

  if (area > 0 && AR > 0) {
    var span = Math.sqrt(area * AR);
    var panelSpan = vertical ? span : span / (isSymmetric ? 2 : 1);
    var rootChord = 2 * area / (span * (1 + TR));
    var etaMac = (1 + 2 * TR) / (3 * (1 + TR));
    var xQcRoot = rootLE[0] + 0.25 * rootChord;
    var xAc = xQcRoot + etaMac * panelSpan * Math.tan(sweepQC);
    var zAc = (rootLE[2] || 0) + (vertical
      ? etaMac * panelSpan
      : etaMac * panelSpan * Math.sin(deg2rad(surface.dihedral_DEG || 0)));
    return [xAc, rootLE[1] || 0, zAc];
  }

  var mac = surface.mean_aerodynamic_chord_m || 1;
  return [rootLE[0] + 0.25 * mac, rootLE[1] || 0, rootLE[2] || 0];
}

function estimateOswaldFactor(surface) {
  var AR = surface && surface.AR != null ? surface.AR : 6;
  var e = 1.78 * (1 - 0.045 * Math.pow(Math.max(AR, 0.1), 0.68)) - 0.64;
  return roundN(Math.max(0.55, Math.min(0.95, e)), 4);
}

/**
 * Find the maximum absolute deflection (in degrees) for a given control surface
 * type across all lifting surfaces. The simulator uses normalized demand (-1..+1),
 * so per-degree derivatives must be scaled by this value.
 */
function getMaxDeflectionDeg(ad, controlType) {
  var maxDef = 0;
  var surfaces = (ad && ad.lifting_surfaces) || [];
  for (var i = 0; i < surfaces.length; i++) {
    var cs = surfaces[i].control_surfaces || [];
    for (var j = 0; j < cs.length; j++) {
      if (cs[j].type === controlType && cs[j].deflection_range_DEG) {
        var range = cs[j].deflection_range_DEG;
        var absMax = Math.max(Math.abs(range[0] || 0), Math.abs(range[1] || 0));
        if (absMax > maxDef) maxDef = absMax;
      }
    }
  }
  return maxDef || 25;  // default 25° if not specified
}

function closestIndex(arr, val) {
  var best = 0, bestDist = Math.abs(arr[0] - val);
  for (var i = 1; i < arr.length; i++) {
    var dist = Math.abs(arr[i] - val);
    if (dist < bestDist) { bestDist = dist; best = i; }
  }
  return best;
}

function deg2rad(val) {
  return (typeof val === 'number' ? val : 0) * Math.PI / 180;
}

function roundN(val, n) {
  if (typeof val !== 'number' || isNaN(val)) return 0;
  var f = Math.pow(10, n);
  return Math.round(val * f) / f;
}

function formatYamlNumber(val) {
  if (typeof val !== 'number') return String(val);
  if (Number.isInteger(val) && Math.abs(val) < 1e10) return String(val);
  if (val === 0) return '0.0';
  if (Math.abs(val) < 0.0001 && val !== 0) return val.toExponential(4);
  // Keep reasonable decimal places
  var s = val.toFixed(6).replace(/0+$/, '').replace(/\.$/, '.0');
  return s;
}
