/********************************************
 * inertia-ellipsoid.js — Inertia ellipsoid overlay
 *
 * Draws a semi-transparent ellipsoid in the 3D view
 * centered at the aircraft CoG, with semi-axes equal
 * to the radius of gyration in each principal axis:
 *   k_i = sqrt(I_i / m)
 *
 * The ellipsoid is rotated by the principal axes
 * rotation angles (roll, pitch, yaw) from the data file.
 *
 * Also draws:
 *   - Principal axes lines through CoG (red=X, green=Y, blue=Z)
 *   - Aerodynamic neutral point marker (when wing data available)
 ********************************************/

window.inertiaEllipsoidMesh = null;
window.inertiaEllipsoidVisible = false;

/**
 * Build or rebuild the inertia ellipsoid from current aircraftData.
 */
function buildInertiaEllipsoid() {
  disposeInertiaEllipsoid();

  var ad = window.aircraftData;
  if (!ad || !ad.general) {
    console.warn("[Inertia Ellipsoid] No aircraft data loaded.");
    return;
  }

  var gen = ad.general;
  var mass = gen.mass_kg || 1;
  if (mass <= 0) mass = 1;

  // Get principal moments of inertia
  var inertia = gen.inertia || {};
  var pm = inertia.principal_moments_kgm2 || {};
  var Ixx = pm.Ixx_p || 1000;
  var Iyy = pm.Iyy_p || 3000;
  var Izz = pm.Izz_p || 3500;

  // Radius of gyration: k = sqrt(I / m)
  var kx = Math.sqrt(Math.abs(Ixx) / mass);
  var ky = Math.sqrt(Math.abs(Iyy) / mass);
  var kz = Math.sqrt(Math.abs(Izz) / mass);

  // Get principal axes rotation angles
  var pa = inertia.principal_axes_rotation_deg || {};
  var rollDeg  = pa.roll  || 0;
  var pitchDeg = pa.pitch || 0;
  var yawDeg   = pa.yaw   || 0;

  // CoG position (aero frame)
  var cog = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];

  // Create a parent node to group everything
  var root = new BABYLON.TransformNode("inertiaEllipsoidRoot", window.scene);
  if (window.aircraftRoot) {
    root.parent = window.aircraftRoot;
  }

  // Principal axes rotation quaternion
  var quat = BABYLON.Quaternion.FromEulerAngles(
    deg2rad(rollDeg),
    deg2rad(yawDeg),
    deg2rad(pitchDeg)
  );

  // --- Ellipsoid (solid + wireframe) ---
  var ellipsoid = BABYLON.MeshBuilder.CreateSphere("inertiaEllipsoid", {
    diameterX: 2, diameterY: 2, diameterZ: 2, segments: 24
  }, window.scene);
  ellipsoid.scaling = new BABYLON.Vector3(kx, ky, kz);
  ellipsoid.position = new BABYLON.Vector3(cog[0], cog[1], cog[2]);
  ellipsoid.rotationQuaternion = quat.clone();
  ellipsoid.parent = root;
  ellipsoid.isPickable = false;

  var mat = new BABYLON.StandardMaterial("inertiaEllipsoidMat", window.scene);
  mat.diffuseColor  = new BABYLON.Color3(0.3, 0.7, 1.0);
  mat.emissiveColor = new BABYLON.Color3(0.05, 0.15, 0.3);
  mat.alpha = 0.25;
  mat.backFaceCulling = false;
  ellipsoid.material = mat;

  var wireframe = BABYLON.MeshBuilder.CreateSphere("inertiaEllipsoidWire", {
    diameterX: 2, diameterY: 2, diameterZ: 2, segments: 16
  }, window.scene);
  wireframe.scaling = ellipsoid.scaling.clone();
  wireframe.position = ellipsoid.position.clone();
  wireframe.rotationQuaternion = quat.clone();
  wireframe.parent = root;
  wireframe.isPickable = false;

  var wireMat = new BABYLON.StandardMaterial("inertiaEllipsoidWireMat", window.scene);
  wireMat.diffuseColor  = new BABYLON.Color3(0.2, 0.6, 1.0);
  wireMat.emissiveColor = new BABYLON.Color3(0.1, 0.3, 0.6);
  wireMat.alpha = 0.6;
  wireMat.wireframe = true;
  wireMat.backFaceCulling = false;
  wireframe.material = wireMat;

  // --- Principal axes lines through CoG ---
  // Each axis extends ±(radius of gyration * 1.3) for visibility beyond ellipsoid
  var axisScale = 1.3;
  var axisData = [
    { name: "X_p", dir: [1, 0, 0], len: kx * axisScale, color: new BABYLON.Color3(1.0, 0.2, 0.2) },
    { name: "Y_p", dir: [0, 1, 0], len: ky * axisScale, color: new BABYLON.Color3(0.2, 1.0, 0.2) },
    { name: "Z_p", dir: [0, 0, 1], len: kz * axisScale, color: new BABYLON.Color3(0.3, 0.5, 1.0) }
  ];

  // Build a rotation matrix from the quaternion to rotate axis directions
  var rotMatrix = new BABYLON.Matrix();
  BABYLON.Matrix.FromQuaternionToRef(quat, rotMatrix);

  for (var i = 0; i < axisData.length; i++) {
    var ax = axisData[i];
    var dir = BABYLON.Vector3.TransformNormal(
      new BABYLON.Vector3(ax.dir[0], ax.dir[1], ax.dir[2]),
      rotMatrix
    );
    var p1 = new BABYLON.Vector3(
      cog[0] - dir.x * ax.len,
      cog[1] - dir.y * ax.len,
      cog[2] - dir.z * ax.len
    );
    var p2 = new BABYLON.Vector3(
      cog[0] + dir.x * ax.len,
      cog[1] + dir.y * ax.len,
      cog[2] + dir.z * ax.len
    );

    var axisLine = BABYLON.MeshBuilder.CreateLines("inertiaAxis_" + ax.name, {
      points: [p1, p2],
      updatable: false
    }, window.scene);
    axisLine.color = ax.color;
    axisLine.parent = root;
    axisLine.isPickable = false;

    // Arrow tip at positive end (small cone)
    var tipLen = ax.len * 0.15;
    var tipRadius = ax.len * 0.05;
    var cone = BABYLON.MeshBuilder.CreateCylinder("inertiaTip_" + ax.name, {
      diameterTop: 0, diameterBottom: tipRadius * 2,
      height: tipLen, tessellation: 8
    }, window.scene);
    // Position the cone at the positive axis tip
    cone.position = p2.clone();
    // Orient the cone along the axis direction
    var up = new BABYLON.Vector3(0, 1, 0);
    var angle = Math.acos(Math.min(1, Math.max(-1, BABYLON.Vector3.Dot(up, dir.normalize()))));
    var cross = BABYLON.Vector3.Cross(up, dir.normalize());
    if (cross.length() > 0.0001) {
      cone.rotationQuaternion = BABYLON.Quaternion.RotationAxis(cross.normalize(), angle);
    } else if (angle > Math.PI / 2) {
      cone.rotationQuaternion = BABYLON.Quaternion.RotationAxis(new BABYLON.Vector3(1, 0, 0), Math.PI);
    }
    var coneMat = new BABYLON.StandardMaterial("inertiaTipMat_" + ax.name, window.scene);
    coneMat.diffuseColor = ax.color;
    coneMat.emissiveColor = ax.color.scale(0.4);
    cone.material = coneMat;
    cone.parent = root;
    cone.isPickable = false;
  }

  // --- Aerodynamic neutral point marker ---
  buildNeutralPointMarker(ad, root);

  window.inertiaEllipsoidMesh = root;
  window.inertiaEllipsoidVisible = true;
  updateInertiaEllipsoidButton();

  console.log("[Inertia Ellipsoid] Built: kx=" + kx.toFixed(2) +
              " ky=" + ky.toFixed(2) + " kz=" + kz.toFixed(2) +
              " at CoG=[" + cog.join(",") + "]" +
              " PA rot=[" + rollDeg + "," + pitchDeg + "," + yawDeg + "]°");
}

/**
 * Compute and draw the aerodynamic neutral point (NP) as a diamond marker.
 * NP = wing aerodynamic center (25% MAC from root LE), approximated from geometry.
 * Also draws for each surface: its own AC at 25% MAC.
 */
function buildNeutralPointMarker(ad, parent) {
  if (!ad.lifting_surfaces) return;

  var gen = ad.general;
  var cog = gen.aircraft_CoG_coords_xyz_m || [0, 0, 0];
  var cref = gen.aircraft_reference_mean_aerodynamic_chord_m || 2.0;

  // Find wing and compute its aerodynamic center (25% MAC)
  var wingSurf = null;
  for (var i = 0; i < ad.lifting_surfaces.length; i++) {
    var s = ad.lifting_surfaces[i];
    if ((s.role || "").toLowerCase() === "wing" || (s.name || "").toLowerCase().indexOf("wing") >= 0) {
      wingSurf = s;
      break;
    }
  }

  if (!wingSurf) return;

  // Wing AC = root LE x + 25% of MAC
  var mac = wingSurf.mean_aerodynamic_chord_m || cref;
  var rootLE = wingSurf.root_LE || [0, 0, 0];
  var x_ac = rootLE[0] + 0.25 * mac;
  var y_ac = 0;   // on symmetry plane
  var z_ac = rootLE[2] || 0;

  // Static margin
  var staticMargin = (x_ac - cog[0]) / cref;

  // Draw neutral point as an octahedron (diamond shape)
  var npSize = cref * 0.08;
  var npMesh = BABYLON.MeshBuilder.CreatePolyhedron("neutralPoint", {
    type: 1,  // octahedron
    size: npSize
  }, window.scene);
  npMesh.position = new BABYLON.Vector3(x_ac, y_ac, z_ac);
  npMesh.parent = parent;
  npMesh.isPickable = false;

  var npMat = new BABYLON.StandardMaterial("neutralPointMat", window.scene);
  npMat.diffuseColor  = new BABYLON.Color3(1.0, 0.85, 0.0);   // gold
  npMat.emissiveColor = new BABYLON.Color3(0.5, 0.4, 0.0);
  npMat.alpha = 0.9;
  npMesh.material = npMat;

  // Draw a line from CoG to NP to visualize static margin
  var marginLine = BABYLON.MeshBuilder.CreateLines("staticMarginLine", {
    points: [
      new BABYLON.Vector3(cog[0], 0, z_ac),
      new BABYLON.Vector3(x_ac, 0, z_ac)
    ],
    updatable: false
  }, window.scene);
  marginLine.color = new BABYLON.Color3(1.0, 0.85, 0.0);
  marginLine.parent = parent;
  marginLine.isPickable = false;

  console.log("[Neutral Point] x_ac=" + x_ac.toFixed(3) + "m, " +
              "static margin=" + (staticMargin * 100).toFixed(1) + "% MAC");
}

/**
 * Dispose the inertia ellipsoid and all child visuals.
 */
function disposeInertiaEllipsoid() {
  if (window.inertiaEllipsoidMesh) {
    window.inertiaEllipsoidMesh.getChildMeshes().forEach(function(m) { m.dispose(); });
    window.inertiaEllipsoidMesh.dispose();
    window.inertiaEllipsoidMesh = null;
  }
  window.inertiaEllipsoidVisible = false;
  updateInertiaEllipsoidButton();
}

/**
 * Toggle inertia ellipsoid on/off.
 */
function toggleInertiaEllipsoid() {
  if (window.inertiaEllipsoidMesh) {
    window.inertiaEllipsoidVisible = !window.inertiaEllipsoidVisible;
    window.inertiaEllipsoidMesh.setEnabled(window.inertiaEllipsoidVisible);
    updateInertiaEllipsoidButton();
    return;
  }
  buildInertiaEllipsoid();
}

/**
 * Update the ellipsoid toggle button appearance.
 */
function updateInertiaEllipsoidButton() {
  var btn = document.getElementById("toggleInertiaEllipsoidBtn");
  if (!btn) return;
  if (window.inertiaEllipsoidVisible) {
    btn.style.backgroundColor = "#8e44ad";
    btn.title = "Hide Inertia Ellipsoid";
  } else {
    btn.style.backgroundColor = "";
    btn.title = "Show Inertia Ellipsoid";
  }
}

// Export
window.buildInertiaEllipsoid = buildInertiaEllipsoid;
window.disposeInertiaEllipsoid = disposeInertiaEllipsoid;
window.toggleInertiaEllipsoid = toggleInertiaEllipsoid;
