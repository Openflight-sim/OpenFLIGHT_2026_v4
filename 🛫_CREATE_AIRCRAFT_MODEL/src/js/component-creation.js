// js/component-creation.js

// Add deg2rad helper function at the very top so it is available everywhere.
function deg2rad(deg) {
  return (deg * Math.PI) / 180;
}

/**
 * Compute surface planform geometry from parameters.
 * Returns corner points in LOCAL coordinates (relative to root_LE origin).
 * Used by both solid geometry rendering and VLM mesh generation
 * to guarantee they always produce identical geometry.
 */
function computeSurfacePlanform(surface) {
  var area = surface.surface_area_m2 || 10;
  var AR = surface.AR || 8;
  var TR = surface.TR || 0.6;
  var sweep_deg = surface.sweep_quarter_chord_DEG || 0;
  var dihedral_deg = surface.dihedral_DEG || 0;
  var isVertical = surface.vertical || false;

  var span = Math.sqrt(area * AR);
  var panel_span = isVertical ? span : span / 2;
  var root_chord = (2 * area) / (span * (1 + TR));
  var tip_chord = root_chord * TR;

  var sweep = deg2rad(sweep_deg);
  var dihedral = deg2rad(dihedral_deg);

  var root_LE = [0, 0, 0];
  var tip_le, root_te, tip_te;

  if (isVertical) {
    tip_le = [panel_span * Math.tan(sweep), 0, panel_span];
    root_te = [root_chord, 0, 0];
    tip_te = [tip_le[0] + tip_chord, 0, tip_le[2]];
  } else {
    tip_le = [
      panel_span * Math.tan(sweep),
      panel_span * Math.cos(dihedral),
      panel_span * Math.sin(dihedral)
    ];
    root_te = [root_chord, 0, 0];
    tip_te = [tip_le[0] + tip_chord, tip_le[1], tip_le[2]];
  }

  return {
    span: span,
    panel_span: panel_span,
    root_chord: root_chord,
    tip_chord: tip_chord,
    sweep: sweep,
    dihedral: dihedral,
    root_LE: root_LE,
    root_te: root_te,
    tip_le: tip_le,
    tip_te: tip_te
  };
}
window.computeSurfacePlanform = computeSurfacePlanform;

function createQuadMesh(name, pts, color) {
  const customMesh = new BABYLON.Mesh(name, scene);
  const positions = pts.flatMap(p => [p[0], p[1], p[2]]);
  const pivot = BABYLON.Vector3.FromArray(pts[0]);
  // Adjust positions relative to pivot
  for (let i = 0; i < positions.length; i += 3) {
    positions[i]   -= pivot.x;
    positions[i+1] -= pivot.y;
    positions[i+2] -= pivot.z;
  }
  const indices = [0, 1, 2, 0, 2, 3];
  const normals = [];
  BABYLON.VertexData.ComputeNormals(positions, indices, normals);
  const vertexData = new BABYLON.VertexData();
  vertexData.positions = positions;
  vertexData.indices = indices;
  vertexData.normals = normals;
  vertexData.applyToMesh(customMesh);
  const mat = new BABYLON.StandardMaterial(name + "Mat", scene);
  mat.diffuseColor = color;
  mat.backFaceCulling = false;
  // If you want them translucent by default, uncomment:
  // mat.alpha = 0.8;
  // mat.transparencyMode = BABYLON.Material.MATERIAL_ALPHABLEND;
  // mat.needDepthPrePass = true;
  
  customMesh.material = mat;
  customMesh.position = pivot;
  customMesh.isPickable = true;
  return customMesh;
}

function createFuselageNode(name, diameter, length, nosePosition) {
  const parent = new BABYLON.TransformNode(name + "_parent", scene);
  parent.name = name + "_transform";
  parent.position = new BABYLON.Vector3(...nosePosition);
  const color = new BABYLON.Color3(1.0, 0.7, 0.3);
  const radius = diameter / 2;

  // Nose truncated cone (10% of length, tapers from 20% diameter at tip to full diameter)
  var noseLen = Math.min(length * 0.10, diameter * 1.0);
  // Tail truncated cone (25% of length, tapers from full diameter to 20% diameter)
  var tailLen = Math.min(length * 0.25, diameter * 2.5);
  // Main body is what remains
  var bodyLen = length - noseLen - tailLen;

  var noseCone = BABYLON.MeshBuilder.CreateCylinder(name + "_nose", {
    height: noseLen,
    diameterTop: diameter * 0.2,
    diameterBottom: diameter,
    tessellation: 32
  }, scene);
  noseCone.rotation.z = Math.PI / 2;
  noseCone.position = new BABYLON.Vector3(noseLen / 2, 0, 0);
  noseCone.parent = parent;
  noseCone.isPickable = true;

  // Main body cylinder
  const cylinder = BABYLON.MeshBuilder.CreateCylinder(name, {
    height: bodyLen,
    diameter: diameter,
    tessellation: 32
  }, scene);
  cylinder.rotation.z = Math.PI / 2;
  cylinder.position = new BABYLON.Vector3(noseLen + bodyLen / 2, 0, 0);
  cylinder.isPickable = true;
  cylinder.parent = parent;

  // Tail truncated cone (longer, tapers to 20% of fuselage diameter)
  var tailCone = BABYLON.MeshBuilder.CreateCylinder(name + "_tail", {
    height: tailLen,
    diameterTop: diameter,
    diameterBottom: diameter * 0.2,
    tessellation: 32
  }, scene);
  tailCone.rotation.z = Math.PI / 2;
  tailCone.position = new BABYLON.Vector3(noseLen + bodyLen + tailLen / 2, 0, 0);
  tailCone.parent = parent;
  tailCone.isPickable = true;

  // Shared material
  const mat = new BABYLON.StandardMaterial(name + "Mat", scene);
  mat.diffuseColor = color;
  mat.backFaceCulling = false;

  noseCone.material = mat;
  cylinder.material = mat;
  tailCone.material = mat;

  window.shadowGenerator.addShadowCaster(noseCone, true);
  window.shadowGenerator.addShadowCaster(cylinder, true);
  window.shadowGenerator.addShadowCaster(tailCone, true);

  parent.metadata = {
    type: "fuselage",
    data: null,
    originalColor: color
  };
  parent.isPickable = false;

  return parent;
}

function addLiftingSurfaceToScene(surface, aircraftData, aircraftRoot, liftingSurfaceColors) {
  // Create a parent transform node for the lifting surface.
  const parent = new BABYLON.TransformNode(surface.name + "_parent", scene);
  parent.position = new BABYLON.Vector3(...surface.root_LE);
  // Use role-based color if available, otherwise fall back to index-based
  const role = surface.role || autoDetectRole(surface.name || "");
  const baseColor = (window.roleColors && window.roleColors[role])
    ? window.roleColors[role]
    : liftingSurfaceColors[(aircraftData.lifting_surfaces.indexOf(surface)) % liftingSurfaceColors.length];
  parent.metadata = {
    type: "lifting_surface",
    data: surface,
    originalColor: baseColor
  };
  parent.parent = aircraftRoot;
  parent.isPickable = false;

  // Compute geometry parameters (inline — no external function dependency).
  const area = surface.surface_area_m2;
  const AR = surface.AR;
  const TR = surface.TR;
  const sweep = deg2rad(surface.sweep_quarter_chord_DEG);
  const dihedral = deg2rad(surface.dihedral_DEG);
  const span = Math.sqrt(area * AR);
  const semi_span = span / 2;
  // Vertical surfaces are single-sided: use full span. Others use half-span.
  const panel_span = surface.vertical ? span : semi_span;
  const root_chord = (2 * area) / (span * (1 + TR));
  const tip_chord = root_chord * TR;
  const root_LE = [0, 0, 0];
  let tip_le, root_te, tip_te;

  if (surface.vertical) {
    tip_le = [
      root_LE[0] + panel_span * Math.tan(sweep),
      root_LE[1],
      root_LE[2] + panel_span
    ];
    root_te = [root_LE[0] + root_chord, root_LE[1], root_LE[2]];
    tip_te = [tip_le[0] + tip_chord, tip_le[1], tip_le[2]];
  } else {
    tip_le = [
      root_LE[0] + panel_span * Math.tan(sweep),
      root_LE[1] + panel_span * Math.cos(dihedral),
      root_LE[2] + panel_span * Math.sin(dihedral)
    ];
    root_te = [root_LE[0] + root_chord, root_LE[1], root_LE[2]];
    tip_te = [tip_le[0] + tip_chord, tip_le[1], tip_le[2]];
  }

  const points = [root_LE, root_te, tip_te, tip_le];

  // Create the quad mesh for the lifting surface.
  const mesh = createQuadMesh(surface.name, points, baseColor);
  mesh.parent = parent;

  // Create a label showing name and role
  var roleLabel = role && role !== 'other' ? ' [' + role.replace(/_/g, ' ') + ']' : '';
  var label = createLabel(surface.name + roleLabel, 3, 0.5);
  label.parent = parent;
  label.position = new BABYLON.Vector3(0, 0, 0);

  // If the lifting surface is symmetric (and not vertical), create the mirror.
  if (surface.symmetric && !surface.vertical) {
    const mirrorMesh = mesh.clone(surface.name + "_mirror");
    mirrorMesh.scaling.y *= -1;
    mirrorMesh.parent = parent;
    mirrorMesh.material = mesh.material.clone(surface.name + "_mirrorMat");
    mirrorMesh.material.diffuseColor = baseColor;
    mirrorMesh.material.backFaceCulling = false;
    mirrorMesh.isPickable = false;
  }

  // Render control surfaces if defined
  if (surface.control_surfaces && Array.isArray(surface.control_surfaces)) {
    var csColors = {
      aileron:  new BABYLON.Color3(1.0, 0.6, 0.2),  // orange
      elevator: new BABYLON.Color3(0.3, 0.5, 1.0),  // blue
      rudder:   new BABYLON.Color3(1.0, 0.3, 0.3),  // red
      flap:     new BABYLON.Color3(0.9, 0.9, 0.3),  // yellow
      spoiler:  new BABYLON.Color3(0.6, 0.3, 0.6)   // purple
    };

    surface.control_surfaces.forEach(function(cs) {
      var csColor = csColors[cs.type] || new BABYLON.Color3(1.0, 0.5, 0.0);
      var eta1 = cs.eta_start || 0;
      var eta2 = cs.eta_end || 1;
      var chordFrac = cs.chord_fraction || 0.25;

      // Interpolate leading edge and chord at eta1 and eta2
      var root_LE_local = [0, 0, 0];
      var rootChord = root_chord;
      var tipChord = tip_chord;

      // LE and TE at eta1
      var le1 = [
        root_LE_local[0] + eta1 * (tip_le[0] - root_LE_local[0]),
        root_LE_local[1] + eta1 * (tip_le[1] - root_LE_local[1]),
        root_LE_local[2] + eta1 * (tip_le[2] - root_LE_local[2])
      ];
      var chord1 = rootChord + eta1 * (tipChord - rootChord);
      var te1 = [le1[0] + chord1, le1[1], le1[2]];

      // LE and TE at eta2
      var le2 = [
        root_LE_local[0] + eta2 * (tip_le[0] - root_LE_local[0]),
        root_LE_local[1] + eta2 * (tip_le[1] - root_LE_local[1]),
        root_LE_local[2] + eta2 * (tip_le[2] - root_LE_local[2])
      ];
      var chord2 = rootChord + eta2 * (tipChord - rootChord);
      var te2 = [le2[0] + chord2, le2[1], le2[2]];

      // Control surface quad: from (1-chordFrac)*chord to trailing edge
      var csLE1 = [le1[0] + chord1 * (1 - chordFrac), le1[1], le1[2]];
      var csLE2 = [le2[0] + chord2 * (1 - chordFrac), le2[1], le2[2]];
      var csPoints = [csLE1, te1, te2, csLE2];

      var csMesh = createQuadMesh(surface.name + "_cs_" + cs.name, csPoints, csColor);
      csMesh.parent = parent;
      csMesh.isPickable = false;
      // Slight offset to avoid z-fighting
      csMesh.position.z += 0.01;

      // Mirror the control surface if symmetric
      if (surface.symmetric && !surface.vertical) {
        var csMirror = csMesh.clone(surface.name + "_cs_" + cs.name + "_mirror");
        csMirror.scaling.y *= -1;
        // Negate Y position so the mirror appears on the opposite side.
        csMirror.position.y = -csMesh.position.y;
        csMirror.parent = parent;
        csMirror.material = csMesh.material.clone(cs.name + "_mirrorMat");
        csMirror.material.diffuseColor = csColor;
        csMirror.material.backFaceCulling = false;
        csMirror.isPickable = false;
      }
    });
  }
}

function addFuselageToScene(fusData, aircraftRoot) {
  // Create the fuselage node using the existing helper function.
  const fusNode = createFuselageNode(fusData.name, fusData.diameter, fusData.length, fusData.nose_position);
  fusNode.metadata.data = fusData;
  fusNode.parent = aircraftRoot;
  
  // Create a label for the fuselage using the helper function.
  var label = createLabel(fusData.name, 2, 0.5);
  label.parent = fusNode;
  label.position = new BABYLON.Vector3(0, 0, 0);
}

// Helper function to create a billboard-style label with the given text.
// Renders with a semi-transparent dark background pill for readability.
var _labelCounter = 0;
function createLabel(text, width, height) {
  _labelCounter++;
  var uniqueName = "label_" + text + "_" + _labelCounter;
  var plane = BABYLON.MeshBuilder.CreatePlane(uniqueName, { width: width, height: height * 1.2 }, scene);
  plane.billboardMode = BABYLON.Mesh.BILLBOARDMODE_ALL;
  plane.renderingGroupId = 1; // render on top of aircraft geometry

  var texW = 512;
  var texH = 96;
  var dt = new BABYLON.DynamicTexture("dt_" + uniqueName, { width: texW, height: texH }, scene, false);
  dt.hasAlpha = true;

  var ctx = dt.getContext();
  ctx.clearRect(0, 0, texW, texH);

  // Dark background pill
  var fontSize = 30;
  var font = "bold " + fontSize + "px 'Segoe UI', Arial, sans-serif";
  ctx.font = font;
  var textWidth = ctx.measureText(text).width;
  var pillW = Math.min(textWidth + 24, texW - 4);
  var pillH = fontSize + 14;
  var pillX = (texW - pillW) / 2;
  var pillY = (texH - pillH) / 2;

  ctx.fillStyle = "rgba(15, 17, 23, 0.75)";
  ctx.beginPath();
  var r = 8;
  ctx.moveTo(pillX + r, pillY);
  ctx.lineTo(pillX + pillW - r, pillY);
  ctx.quadraticCurveTo(pillX + pillW, pillY, pillX + pillW, pillY + r);
  ctx.lineTo(pillX + pillW, pillY + pillH - r);
  ctx.quadraticCurveTo(pillX + pillW, pillY + pillH, pillX + pillW - r, pillY + pillH);
  ctx.lineTo(pillX + r, pillY + pillH);
  ctx.quadraticCurveTo(pillX, pillY + pillH, pillX, pillY + pillH - r);
  ctx.lineTo(pillX, pillY + r);
  ctx.quadraticCurveTo(pillX, pillY, pillX + r, pillY);
  ctx.closePath();
  ctx.fill();

  // White text
  ctx.fillStyle = "#f0f0f0";
  ctx.font = font;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, texW / 2, texH / 2 + 1);
  dt.update();

  var mat = new BABYLON.StandardMaterial("labelMat_" + uniqueName, scene);
  mat.diffuseTexture = dt;
  mat.useAlphaFromDiffuseTexture = true;
  mat.transparencyMode = BABYLON.Material.MATERIAL_ALPHABLEND;
  mat.emissiveColor = new BABYLON.Color3(1, 1, 1);
  mat.backFaceCulling = false;
  mat.disableLighting = true;
  plane.material = mat;

  return plane;
}

/**
 * Add an engine to the 3D scene as a cone with a thrust direction arrow.
 */
function addEngineToScene(engData, aircraftRoot) {
  var pos = engData.position_m || [0, 0, 0];
  var orient = engData.orientation_deg || {};
  var yawDeg = orient.yaw || 0;
  var pitchDeg = orient.pitch || 0;
  var rollDeg = orient.roll || 0;

  var parent = new BABYLON.TransformNode(engData.id + "_parent", scene);
  parent.position = new BABYLON.Vector3(pos[0], pos[1], pos[2]);
  parent.parent = aircraftRoot;
  parent.isPickable = false;
  parent.metadata = {
    type: "engine",
    data: engData,
    originalColor: new BABYLON.Color3(0.85, 0.2, 0.2)
  };

  // Engine nacelle — wide end forward (intake/prop disc), narrow aft (exhaust)
  var coneLen = 0.8;
  var coneRadius = 0.3;
  var cone = BABYLON.MeshBuilder.CreateCylinder(engData.id + "_nacelle", {
    height: coneLen,
    diameterTop: coneRadius * 2,       // wide end → maps to +X (forward)
    diameterBottom: coneRadius * 0.4,   // narrow end → maps to -X (aft/exhaust)
    tessellation: 16
  }, scene);
  // Rotate default Y-axis cylinder to lie along X-axis: +Y → +X
  cone.rotation.z = -Math.PI / 2;
  cone.position = new BABYLON.Vector3(-coneLen / 2, 0, 0);
  cone.parent = parent;
  cone.isPickable = true;

  var coneMat = new BABYLON.StandardMaterial(engData.id + "_coneMat", scene);
  coneMat.diffuseColor = new BABYLON.Color3(0.85, 0.2, 0.2);
  coneMat.emissiveColor = new BABYLON.Color3(0.2, 0.05, 0.05);
  coneMat.backFaceCulling = false;
  cone.material = coneMat;
  window.shadowGenerator.addShadowCaster(cone, true);

  // Thrust arrow — points FORWARD (+X) to indicate force direction
  var thrustLen = 1.5;
  var thrustLine = BABYLON.MeshBuilder.CreateLines(engData.id + "_thrust", {
    points: [
      new BABYLON.Vector3(0.1, 0, 0),
      new BABYLON.Vector3(thrustLen, 0, 0)
    ]
  }, scene);
  thrustLine.color = new BABYLON.Color3(1.0, 0.5, 0.0);
  thrustLine.parent = parent;
  thrustLine.isPickable = false;

  // Apply orientation (yaw, pitch, roll) to the parent node
  parent.rotation = new BABYLON.Vector3(
    deg2rad(pitchDeg),
    deg2rad(yawDeg),
    deg2rad(rollDeg)
  );

  // Label
  var label = createLabel(engData.id, 1.5, 0.4);
  label.parent = parent;
  label.position = new BABYLON.Vector3(0, 0.5, 0);
}

/**
 * Draw a CoG (center of gravity) marker as a small sphere with crosshair lines.
 */
function addCoGMarker(aircraftRoot) {
  var gen = window.aircraftData.general;
  if (!gen) return;
  var cog = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];

  // Sphere at CoG — rendering group 1 so it's always visible on top
  var cogSphere = BABYLON.MeshBuilder.CreateSphere("cogMarker", {
    diameter: 0.4, segments: 12
  }, scene);
  cogSphere.position = new BABYLON.Vector3(cog[0], cog[1], cog[2]);
  cogSphere.parent = aircraftRoot;
  cogSphere.isPickable = false;
  cogSphere.renderingGroupId = 1;

  var cogMat = new BABYLON.StandardMaterial("cogMarkerMat", scene);
  cogMat.diffuseColor = new BABYLON.Color3(1.0, 0.2, 0.2);
  cogMat.emissiveColor = new BABYLON.Color3(0.8, 0.15, 0.15);
  cogMat.backFaceCulling = false;
  cogSphere.material = cogMat;

  // Small crosshair lines at CoG
  var armLen = 0.6;
  var crossLines = BABYLON.MeshBuilder.CreateLineSystem("cogCross", {
    lines: [
      [new BABYLON.Vector3(-armLen, 0, 0), new BABYLON.Vector3(armLen, 0, 0)],
      [new BABYLON.Vector3(0, -armLen, 0), new BABYLON.Vector3(0, armLen, 0)],
      [new BABYLON.Vector3(0, 0, -armLen), new BABYLON.Vector3(0, 0, armLen)]
    ]
  }, scene);
  crossLines.color = new BABYLON.Color3(1.0, 0.2, 0.2);
  crossLines.position = new BABYLON.Vector3(cog[0], cog[1], cog[2]);
  crossLines.parent = aircraftRoot;
  crossLines.isPickable = false;
  crossLines.renderingGroupId = 1;

  // Label
  var label = createLabel("CoG", 1.2, 0.35);
  label.parent = aircraftRoot;
  label.position = new BABYLON.Vector3(cog[0], cog[1] + 0.5, cog[2]);
}

/**
 * Draw a Neutral Point (NP) marker — a green diamond with crosshair lines.
 * Only shown when real aerodynamic analysis results are available (window.aeroModel).
 * The NP is computed from the analysis as the point where dCM/dCL = 0.
 */
function addNeutralPointMarker(aircraftRoot) {
  // Only show NP when we have actual analysis results — do not estimate
  if (!window.aeroModel || window.aeroModel.neutral_point_x_m == null) return;
  var npX = window.aeroModel.neutral_point_x_m;

  var gen = window.aircraftData.general || {};
  var cog = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];
  var npPos = [npX, cog[1], cog[2]]; // same Y/Z as CoG for visual alignment

  // Diamond shape (rotated sphere) — rendering group 1 for always-on-top
  var npSphere = BABYLON.MeshBuilder.CreateSphere("npMarker", {
    diameter: 0.35, segments: 8
  }, scene);
  npSphere.position = new BABYLON.Vector3(npPos[0], npPos[1], npPos[2]);
  npSphere.rotation.z = Math.PI / 4;
  npSphere.parent = aircraftRoot;
  npSphere.isPickable = false;
  npSphere.renderingGroupId = 1;

  var npMat = new BABYLON.StandardMaterial("npMarkerMat", scene);
  npMat.diffuseColor = new BABYLON.Color3(0.2, 0.8, 0.3);
  npMat.emissiveColor = new BABYLON.Color3(0.15, 0.65, 0.25);
  npMat.backFaceCulling = false;
  npSphere.material = npMat;

  // Crosshair
  var armLen = 0.5;
  var npCross = BABYLON.MeshBuilder.CreateLineSystem("npCross", {
    lines: [
      [new BABYLON.Vector3(-armLen, 0, 0), new BABYLON.Vector3(armLen, 0, 0)],
      [new BABYLON.Vector3(0, -armLen, 0), new BABYLON.Vector3(0, armLen, 0)],
      [new BABYLON.Vector3(0, 0, -armLen), new BABYLON.Vector3(0, 0, armLen)]
    ]
  }, scene);
  npCross.color = new BABYLON.Color3(0.2, 0.8, 0.3);
  npCross.position = new BABYLON.Vector3(npPos[0], npPos[1], npPos[2]);
  npCross.parent = aircraftRoot;
  npCross.isPickable = false;
  npCross.renderingGroupId = 1;

  // Label
  var label = createLabel("NP", 1.0, 0.35);
  label.parent = aircraftRoot;
  label.position = new BABYLON.Vector3(npPos[0], npPos[1] - 0.5, npPos[2]);

  // Static margin line between CoG and NP
  if (Math.abs(npPos[0] - cog[0]) > 0.01) {
    var smLine = BABYLON.MeshBuilder.CreateLines("staticMarginLine", {
      points: [
        new BABYLON.Vector3(cog[0], cog[1] - 0.3, cog[2]),
        new BABYLON.Vector3(npPos[0], npPos[1] - 0.3, npPos[2])
      ]
    }, scene);
    smLine.color = new BABYLON.Color3(0.9, 0.6, 0.1);
    smLine.parent = aircraftRoot;
    smLine.isPickable = false;
    smLine.renderingGroupId = 1;

    // Label showing static margin
    var mac = gen.aircraft_reference_mean_aerodynamic_chord_m || 1;
    var sm = ((npPos[0] - cog[0]) / mac * 100).toFixed(1);
    var smLabel = createLabel("SM: " + sm + "% MAC", 3, 0.35);
    smLabel.parent = aircraftRoot;
    smLabel.position = new BABYLON.Vector3(
      (cog[0] + npPos[0]) / 2,
      cog[1] - 0.8,
      cog[2]
    );
  }
}

/**
 * Compute the aerodynamic center position for a lifting surface from geometry.
 * Returns [x, y, z] in aero coordinates.
 * AC is at 25% of MAC, at the MAC spanwise station.
 */
function computeACFromGeometry(surf) {
  var area = surf.surface_area_m2 || 10;
  var AR = surf.AR || 8;
  var TR = surf.TR || 0.6;
  var sweep_qc_deg = surf.sweep_quarter_chord_DEG || 0;
  var root_LE = surf.root_LE || [0, 0, 0];
  var isVertical = surf.vertical || false;

  var span = Math.sqrt(area * AR);
  var panel_span = isVertical ? span : span / 2;
  var root_chord = 2 * area / (span * (1 + TR));

  // MAC spanwise station: eta_mac = (1/3)*(1+2*TR)/(1+TR)
  var eta_mac = (1 + 2 * TR) / (3 * (1 + TR));

  // Chord at eta_mac
  var c_mac = root_chord * (1 - eta_mac * (1 - TR));

  // Quarter-chord x position at eta_mac
  var sweep_qc = deg2rad(sweep_qc_deg);
  var x_qc_root = root_LE[0] + 0.25 * root_chord;
  var x_ac = x_qc_root + eta_mac * panel_span * Math.tan(sweep_qc);

  if (isVertical) {
    var z_ac = root_LE[2] + eta_mac * panel_span;
    return [x_ac, root_LE[1], z_ac];
  } else {
    return [x_ac, root_LE[1], root_LE[2]];
  }
}

/**
 * Draw Aerodynamic Center (AC) markers for each lifting surface.
 * If aerodynamic_center_pos_xyz_m is defined, uses that;
 * otherwise computes AC from geometry (25% MAC at MAC spanwise station).
 */
function addAerodynamicCenterMarkers(aircraftRoot) {
  var ad = window.aircraftData;
  if (!ad || !ad.lifting_surfaces) return;

  // Color map by role
  var acColors = {
    wing:                   new BABYLON.Color3(0.2, 0.6, 1.0),   // blue
    horizontal_stabilizer:  new BABYLON.Color3(1.0, 0.5, 0.1),   // orange
    vertical_stabilizer:    new BABYLON.Color3(0.4, 0.9, 0.3),   // green
    canard:                 new BABYLON.Color3(0.9, 0.2, 0.7),   // magenta
    other:                  new BABYLON.Color3(0.7, 0.7, 0.3)    // olive
  };

  for (var i = 0; i < ad.lifting_surfaces.length; i++) {
    var surf = ad.lifting_surfaces[i];
    var acPos = surf.aerodynamic_center_pos_xyz_m;
    if (!acPos) {
      acPos = computeACFromGeometry(surf);
    }
    if (!acPos) continue;

    var role = surf.role || "other";
    var color = acColors[role] || acColors.other;
    var name = surf.name || ("Surface_" + i);
    var tag = "ac_" + name;

    // Diamond marker — rendering group 1 for always-on-top
    var acMarker = BABYLON.MeshBuilder.CreateSphere(tag + "_marker", {
      diameter: 0.25, segments: 4
    }, scene);
    acMarker.position = new BABYLON.Vector3(acPos[0], acPos[1], acPos[2]);
    acMarker.rotation.z = Math.PI / 4;
    acMarker.parent = aircraftRoot;
    acMarker.isPickable = false;
    acMarker.renderingGroupId = 1;

    var acMat = new BABYLON.StandardMaterial(tag + "_mat", scene);
    acMat.diffuseColor = color;
    acMat.emissiveColor = new BABYLON.Color3(color.r * 0.6, color.g * 0.6, color.b * 0.6);
    acMat.backFaceCulling = false;
    acMarker.material = acMat;

    // Crosshair
    var arm = 0.35;
    var acCross = BABYLON.MeshBuilder.CreateLineSystem(tag + "_cross", {
      lines: [
        [new BABYLON.Vector3(-arm, 0, 0), new BABYLON.Vector3(arm, 0, 0)],
        [new BABYLON.Vector3(0, -arm, 0), new BABYLON.Vector3(0, arm, 0)],
        [new BABYLON.Vector3(0, 0, -arm), new BABYLON.Vector3(0, 0, arm)]
      ]
    }, scene);
    acCross.color = color;
    acCross.position = new BABYLON.Vector3(acPos[0], acPos[1], acPos[2]);
    acCross.parent = aircraftRoot;
    acCross.isPickable = false;
    acCross.renderingGroupId = 1;

    // Label
    var acLabel = createLabel("AC " + name, 2.0, 0.3);
    acLabel.parent = aircraftRoot;
    acLabel.position = new BABYLON.Vector3(acPos[0], acPos[1] + 0.4, acPos[2]);
  }
}

/**
 * Update the static margin legend overlay.
 * Shows CoG x, NP x, and Static Margin % MAC when a valid NP has been computed.
 */
function updateStaticMarginLegend() {
  var legend = document.getElementById('staticMarginLegend');
  if (!legend) return;

  var model = window.aeroModel;
  var ad = window.aircraftData;
  if (!model || model.neutral_point_x_m == null || !ad || !ad.general) {
    legend.style.display = 'none';
    return;
  }

  var gen = ad.general;
  var cog = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];
  var cref = gen.aircraft_reference_mean_aerodynamic_chord_m || 1;
  var npX = model.neutral_point_x_m;
  var sm = ((npX - cog[0]) / cref) * 100;

  document.getElementById('smCogX').textContent = cog[0].toFixed(3) + ' m';
  document.getElementById('smNpX').textContent = npX.toFixed(3) + ' m';

  var smEl = document.getElementById('smValue');
  smEl.textContent = 'SM = ' + sm.toFixed(1) + '% MAC';

  // Color-code by stability level
  smEl.className = 'sm-val-main';
  if (sm > 5) {
    smEl.classList.add('sm-stable');
  } else if (sm > 0) {
    smEl.classList.add('sm-marginal');
  } else {
    smEl.classList.add('sm-unstable');
  }

  legend.style.display = '';
}

/**
 * Trigger auto-reanalysis if the aero server is connected.
 * Called after any geometric, mass, or propulsive parameter change.
 */
function triggerAutoReanalysis() {
  if (!window.aeroClient || !window.aeroClient.isConnected()) return;
  var wsUrl = 'ws://localhost:' + (window.aeromodel_port || 8765);
  if (typeof startAnalysis === 'function') {
    startAnalysis(wsUrl, window.aircraftData);
  }
}
