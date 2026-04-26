/********************************************
 * vlm-mesh-view.js — Render VLM panel mesh
 * as wireframe overlay in the BabylonJS 3D view.
 *
 * v3 — 2026-03-08 — Fully self-contained geometry
 * (no dependency on computeSurfacePlanform or any
 * external function). Uses IDENTICAL formulas to
 * addLiftingSurfaceToScene in component-creation.js.
 * All coordinates are GLOBAL (root_LE offset baked in).
 ********************************************/
console.log("[VLM Mesh] vlm-mesh-view.js v3 loaded");

// Container for all VLM mesh line meshes
window.vlmMeshRoot = null;
window.vlmMeshVisible = false;

// Role -> wireframe color
var VLM_MESH_COLORS = {
  wing:                   new BABYLON.Color3(0.2, 0.8, 1.0),   // cyan
  horizontal_stabilizer:  new BABYLON.Color3(1.0, 0.6, 0.1),   // orange
  vertical_stabilizer:    new BABYLON.Color3(0.6, 1.0, 0.2),   // lime
  canard:                 new BABYLON.Color3(1.0, 0.2, 0.8),   // magenta
  fuselage:               new BABYLON.Color3(0.7, 0.7, 0.7),   // grey
  other:                  new BABYLON.Color3(0.9, 0.9, 0.4)    // yellow
};

function deg2rad_vlm(deg) { return deg * Math.PI / 180; }

/**
 * renderVLMMesh(vlmMeshData)
 *
 * Draws wireframe panels in the 3D scene.
 * vlmMeshData: Array of { name, role, nc, ns, points }
 *   points[ic][is] = [x, y, z] in GLOBAL aero coords
 */
function renderVLMMesh(vlmMeshData) {
  disposeVLMMesh();
  if (!vlmMeshData || !vlmMeshData.length) return;

  window.vlmMeshRoot = new BABYLON.TransformNode("vlmMeshRoot", window.scene);
  if (window.aircraftRoot) {
    window.vlmMeshRoot.parent = window.aircraftRoot;
  }

  for (var si = 0; si < vlmMeshData.length; si++) {
    var surf = vlmMeshData[si];
    var pts = surf.points;
    var nc = surf.nc;
    var ns = surf.ns;
    var role = surf.role || "other";
    var color = VLM_MESH_COLORS[role] || VLM_MESH_COLORS.other;

    if (!pts || pts.length < 2) continue;

    var lines = [];

    // Chordwise lines (constant spanwise index)
    for (var is = 0; is <= ns; is++) {
      var line = [];
      for (var ic = 0; ic <= nc; ic++) {
        var p = pts[ic][is];
        line.push(new BABYLON.Vector3(p[0], p[1], p[2]));
      }
      lines.push(line);
    }

    // Spanwise lines (constant chordwise index)
    for (var ic = 0; ic <= nc; ic++) {
      var line = [];
      for (var is = 0; is <= ns; is++) {
        var p = pts[ic][is];
        line.push(new BABYLON.Vector3(p[0], p[1], p[2]));
      }
      lines.push(line);
    }

    var meshName = "vlm_" + (surf.name || "surf" + si);
    var lineSystem = BABYLON.MeshBuilder.CreateLineSystem(meshName, {
      lines: lines,
      updatable: false
    }, window.scene);

    lineSystem.color = color;
    lineSystem.parent = window.vlmMeshRoot;
    lineSystem.isPickable = false;

    // Quarter-chord lines
    if (role !== "fuselage" && nc >= 1 && ns >= 1) {
      var qcLines = [];
      for (var ic2 = 0; ic2 < nc; ic2++) {
        var qcLine = [];
        for (var is2 = 0; is2 <= ns; is2++) {
          var pLE = pts[ic2][is2];
          var pTE = pts[ic2 + 1][is2];
          qcLine.push(new BABYLON.Vector3(
            pLE[0] + 0.25 * (pTE[0] - pLE[0]),
            pLE[1] + 0.25 * (pTE[1] - pLE[1]),
            pLE[2] + 0.25 * (pTE[2] - pLE[2])
          ));
        }
        qcLines.push(qcLine);
      }
      if (qcLines.length > 0) {
        var qcMesh = BABYLON.MeshBuilder.CreateLineSystem(meshName + "_qc", {
          lines: qcLines, updatable: false
        }, window.scene);
        qcMesh.color = new BABYLON.Color3(
          Math.min(color.r + 0.3, 1),
          Math.min(color.g + 0.3, 1),
          Math.min(color.b + 0.3, 1)
        );
        qcMesh.parent = window.vlmMeshRoot;
        qcMesh.isPickable = false;
      }
    }
  }

  window.vlmMeshVisible = true;
  updateVLMMeshButton();
}

function disposeVLMMesh() {
  if (window.vlmMeshRoot) {
    window.vlmMeshRoot.getChildMeshes().forEach(function(m) { m.dispose(); });
    window.vlmMeshRoot.dispose();
    window.vlmMeshRoot = null;
  }
  window.vlmMeshVisible = false;
  updateVLMMeshButton();
}

function toggleVLMMesh() {
  if (window.vlmMeshRoot) {
    window.vlmMeshVisible = !window.vlmMeshVisible;
    window.vlmMeshRoot.setEnabled(window.vlmMeshVisible);
    updateVLMMeshButton();
    return;
  }

  // Always use client-side geometry — guaranteed to match solid model
  var geomMesh = buildVLMMeshFromGeometry();
  if (geomMesh && geomMesh.length > 0) {
    renderVLMMesh(geomMesh);
    console.log("[VLM Mesh] Generated from geometry: " + geomMesh.length + " grids");
    return;
  }

  console.warn("[VLM Mesh] No aircraft data loaded.");
}

function updateVLMMeshButton() {
  var btn = document.getElementById("toggleVLMMeshBtn");
  if (!btn) return;
  btn.style.backgroundColor = window.vlmMeshVisible ? "#2980b9" : "";
  btn.title = window.vlmMeshVisible ? "Hide VLM Panel Mesh" : "Show VLM Panel Mesh";
}

/**
 * buildVLMMeshFromGeometry()
 *
 * Client-side VLM grid generation from window.aircraftData.
 * Uses EXACTLY THE SAME formulas as addLiftingSurfaceToScene()
 * in component-creation.js. All coords are GLOBAL (root_LE baked in).
 * No dependency on any external function.
 */
function buildVLMMeshFromGeometry() {
  var ad = window.aircraftData;
  if (!ad || !ad.lifting_surfaces) return null;

  var meshData = [];

  for (var si = 0; si < ad.lifting_surfaces.length; si++) {
    var surf = ad.lifting_surfaces[si];

    // ---- SAME formulas as addLiftingSurfaceToScene ----
    var area = surf.surface_area_m2 || 10;
    var AR   = surf.AR || 8;
    var TR   = surf.TR || 0.6;
    var sweep     = deg2rad_vlm(surf.sweep_quarter_chord_DEG || 0);
    var dihedral_r = deg2rad_vlm(surf.dihedral_DEG || 0);
    var isVertical = surf.vertical || false;
    var isSymmetric = (surf.symmetric !== undefined) ? surf.symmetric : true;
    var doMirror = isSymmetric && !isVertical;

    var offset = surf.root_LE || [0, 0, 0];
    var role   = surf.role || "wing";
    var name   = surf.name || ("Surface_" + si);

    var span = Math.sqrt(area * AR);
    var semi_span = span / 2;
    // Vertical surfaces are single-sided: use full span. Others use half-span.
    var panel_span = isVertical ? span : semi_span;
    var root_chord = (2 * area) / (span * (1 + TR));
    var tip_chord  = root_chord * TR;

    // Tip LE in LOCAL coords — IDENTICAL to component-creation.js
    var tip_le_x, tip_le_y, tip_le_z;
    if (isVertical) {
      tip_le_x = panel_span * Math.tan(sweep);
      tip_le_y = 0;
      tip_le_z = panel_span;
    } else {
      tip_le_x = panel_span * Math.tan(sweep);
      tip_le_y = panel_span * Math.cos(dihedral_r);
      tip_le_z = panel_span * Math.sin(dihedral_r);
    }

    // Convert to GLOBAL coords
    var xle_root = offset[0];
    var yle_root = offset[1];
    var zle_root = offset[2];
    var xle_tip  = offset[0] + tip_le_x;
    var yle_tip  = offset[1] + tip_le_y;
    var zle_tip  = offset[2] + tip_le_z;

    console.log("[VLM Mesh] " + name + " root=[" +
      xle_root.toFixed(3) + "," + yle_root.toFixed(3) + "," + zle_root.toFixed(3) +
      "] tip=[" + xle_tip.toFixed(3) + "," + yle_tip.toFixed(3) + "," + zle_tip.toFixed(3) +
      "] rc=" + root_chord.toFixed(3) + " tc=" + tip_chord.toFixed(3));

    // Panel counts based on aspect ratio
    var L_span = Math.sqrt(
      (xle_tip - xle_root) * (xle_tip - xle_root) +
      (yle_tip - yle_root) * (yle_tip - yle_root) +
      (zle_tip - zle_root) * (zle_tip - zle_root)
    );
    var avg_chord = (root_chord + tip_chord) / 2;
    var ratio = L_span / Math.max(avg_chord, 0.01);

    var min_span = 7, min_chord = 5;
    var nc, ns;
    if (ratio >= 1) {
      nc = min_chord;
      ns = Math.max(min_span, Math.round(ratio * nc));
    } else {
      ns = min_span;
      nc = Math.max(min_chord, Math.round(ns / Math.max(ratio, 0.01)));
    }

    // Build right-half grid in GLOBAL coords
    var half = buildHalfGrid_v3(
      xle_root, yle_root, zle_root,
      xle_tip, yle_tip, zle_tip,
      root_chord, tip_chord, nc, ns
    );

    if (doMirror) {
      // Mirror: negate tip Y relative to root
      var yle_tip_m = offset[1] - tip_le_y;

      var mirrorHalf = buildHalfGrid_v3(
        xle_root, yle_root, zle_root,
        xle_tip, yle_tip_m, zle_tip,
        root_chord, tip_chord, nc, ns
      );

      // Merge: mirror reversed + right half
      var merged = [];
      for (var ic = 0; ic <= nc; ic++) {
        var row = [];
        for (var js = ns; js >= 1; js--) { row.push(mirrorHalf[ic][js]); }
        for (var js = 0; js <= ns; js++) { row.push(half[ic][js]); }
        merged.push(row);
      }

      meshData.push({ name: name, role: role, nc: nc, ns: 2 * ns, points: merged });
    } else {
      meshData.push({ name: name, role: role, nc: nc, ns: ns, points: half });
    }
  }

  // ---- Fuselages (octagonal cross-section) ----
  if (ad.fuselages) {
    for (var fi = 0; fi < ad.fuselages.length; fi++) {
      var fus = ad.fuselages[fi];
      var R = (fus.diameter || 2.0) / 2;
      var flen = fus.length || 10.0;
      var nosePos = fus.nose_position || [0, 0, 0];

      var s_oct = R * Math.sin(Math.PI / 8);
      var nChord = Math.max(2, Math.round(flen / Math.max(s_oct, 0.01)));
      var nSpan = 1;

      for (var iSide = 0; iSide < 8; iSide++) {
        var a1 = (Math.PI / 4) * iSide;
        var a2 = (Math.PI / 4) * (iSide + 1);
        var yc1 = nosePos[1] + R * Math.cos(a1);
        var zc1 = nosePos[2] + R * Math.sin(a1);
        var yc2 = nosePos[1] + R * Math.cos(a2);
        var zc2 = nosePos[2] + R * Math.sin(a2);

        var points = [];
        for (var ic = 0; ic <= nChord; ic++) {
          var row = [];
          for (var js = 0; js <= nSpan; js++) {
            var chordFrac = ic / nChord;
            var lerpFrac  = js / nSpan;
            row.push([
              nosePos[0] + chordFrac * flen,
              (1 - lerpFrac) * yc1 + lerpFrac * yc2,
              (1 - lerpFrac) * zc1 + lerpFrac * zc2
            ]);
          }
          points.push(row);
        }

        meshData.push({
          name: (fus.name || "Fuselage") + "_panel_" + iSide,
          role: "fuselage",
          nc: nChord,
          ns: nSpan,
          points: points
        });
      }
    }
  }

  return meshData.length > 0 ? meshData : null;
}

/**
 * Build one half of a wing grid (root to tip) in GLOBAL coords.
 * Simple linear interpolation of LE + chord offset along X.
 * Returns points[ic][is] = [x, y, z]
 */
function buildHalfGrid_v3(xle0, yle0, zle0, xle1, yle1, zle1,
                          cRoot, cTip, nc, ns) {
  var points = [];
  for (var ic = 0; ic <= nc; ic++) {
    var xi = ic / nc;  // chordwise: 0=LE, 1=TE
    var row = [];
    for (var js = 0; js <= ns; js++) {
      var eta = js / ns;  // spanwise: 0=root, 1=tip

      var xle = xle0 + eta * (xle1 - xle0);
      var yle = yle0 + eta * (yle1 - yle0);
      var zle = zle0 + eta * (zle1 - zle0);
      var c = cRoot + eta * (cTip - cRoot);

      row.push([
        Math.round((xle + xi * c) * 1e4) / 1e4,
        Math.round(yle * 1e4) / 1e4,
        Math.round(zle * 1e4) / 1e4
      ]);
    }
    points.push(row);
  }
  return points;
}

// Export
window.renderVLMMesh = renderVLMMesh;
window.disposeVLMMesh = disposeVLMMesh;
window.toggleVLMMesh = toggleVLMMesh;
window.buildVLMMeshFromGeometry = buildVLMMeshFromGeometry;
