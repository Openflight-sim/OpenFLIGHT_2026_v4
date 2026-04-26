/********************************************
 * FILE: ui-logic.js
 ********************************************/

var liftingSurfaceColors = [
  new BABYLON.Color3(0.8, 1.0, 0.8),
  new BABYLON.Color3(0.9, 0.8, 1.0),
  new BABYLON.Color3(0.7, 0.9, 0.7),
  new BABYLON.Color3(0.8, 0.7, 0.9)
];

// Role-based colors for surface visualization
var roleColors = {
  wing: new BABYLON.Color3(0.204, 0.596, 0.859),               // #3498db blue
  horizontal_stabilizer: new BABYLON.Color3(0.180, 0.800, 0.443), // #2ecc71 green
  vertical_stabilizer: new BABYLON.Color3(0.902, 0.494, 0.133),   // #e67e22 orange
  canard: new BABYLON.Color3(0.608, 0.349, 0.714),                // #9b59b6 purple
  other: new BABYLON.Color3(0.584, 0.647, 0.651)                  // #95a5a6 gray
};

function autoDetectRole(name) {
  if (!name) return "wing";
  var n = name.toLowerCase();
  if (/^(h?tail|horizontal|h_?stab|elevator)/.test(n)) return "horizontal_stabilizer";
  if (/^(v?tail|vertical|v_?stab|fin|rudder)/.test(n)) return "vertical_stabilizer";
  if (/^canard/.test(n)) return "canard";
  if (/^(wing|main)/.test(n)) return "wing";
  return "other";
}

// Main JSON data structure
window.aircraftData = {
  general: {
    aircraft_reference_area_m2: 10.0,
    aircraft_reference_mean_aerodynamic_chord_m: 3.0,
    aircraft_CoG_coords_xyz_m: [2, 1, 0]
  },
  lifting_surfaces: [],
  fuselages: [],
  engines: []
};

window.editingType = "";
window.editingObject = null;
window.selectedComponent = null;
window.currentGLBModel = null; // will store the root mesh of any imported GLB

// Track the last loaded GLB filename
window.lastLoadedGLBName = "";

/**
 * Setup GLB controls
 */
(function setupGLBControls() {
  // 1) Rotation input fields
  const rotXInput = document.getElementById("glbRotateXInput");
  const rotYInput = document.getElementById("glbRotateYInput");
  const rotZInput = document.getElementById("glbRotateZInput");

  // "Apply Rotation" button
  const applyRotationBtn = document.getElementById("applyGlbRotationBtn");
  if (applyRotationBtn) {
    applyRotationBtn.addEventListener("click", function() {
      if (!window.glbRoot) return;

      // Read the angles (degrees)
      const xDeg = parseFloat(rotXInput.value) || 0;
      const yDeg = parseFloat(rotYInput.value) || 0;
      const zDeg = parseFloat(rotZInput.value) || 0;

      // Convert to radians and set the rotation
      window.glbRoot.rotation.x = BABYLON.Tools.ToRadians(xDeg);
      window.glbRoot.rotation.y = BABYLON.Tools.ToRadians(yDeg);
      window.glbRoot.rotation.z = BABYLON.Tools.ToRadians(zDeg);

      // Update snippet if needed
      if (typeof updateGLBTransformSnippet === 'function') {
        updateGLBTransformSnippet();
        document.getElementById("glbTransformSnippet").style.display = "block";
      }
    });
  }

  // 2) Scale input/button
  const scaleInput = document.getElementById("glbScaleInput");
  const applyScaleBtn = document.getElementById("applyGlbScaleBtn");
  if (applyScaleBtn) {
    applyScaleBtn.addEventListener("click", function() {
      if (!window.glbRoot) return;
      const sVal = parseFloat(scaleInput.value);
      if (!isNaN(sVal)) {
        window.glbRoot.scaling = new BABYLON.Vector3(sVal, sVal, sVal);
        if (typeof updateGLBTransformSnippet === 'function') {
          updateGLBTransformSnippet();
          document.getElementById("glbTransformSnippet").style.display = "block";
        }
      }
    });
  }

  // 3) Toggle translucency (ON by default for better marker visibility)
  window.isTranslucent = true;
  const translucencyBtn = document.getElementById("toggleTranslucencyBtn");
  if (translucencyBtn) {
    translucencyBtn.addEventListener("click", function() {
      window.isTranslucent = !window.isTranslucent;
      setTranslucencyMode(window.isTranslucent);
    });
  }

  // 3b) GLB translucency toggle
  const glbTransBtn = document.getElementById("toggleGlbTranslucencyBtn");
  if (glbTransBtn) {
    glbTransBtn.addEventListener("click", function() {
      if (typeof setGlbTranslucency === 'function') {
        window.isGlbTranslucent = !window.isGlbTranslucent;
        setGlbTranslucency(window.isGlbTranslucent);
      }
    });
  }

  // 4) Reset view button
  const resetViewBtn = document.getElementById("resetViewBtn");
  if (resetViewBtn) {
    resetViewBtn.addEventListener("click", function() {
      if (camera) {
        camera.setTarget(new BABYLON.Vector3(7, 0, 0));
        camera.radius = 40;
        camera.alpha = -2.0;
        camera.beta = 1.2;
      }
    });
  }
})();

/**
 * Fill the Lifting Surface modal
 */
function fillLiftingSurfaceModal(data) {
  document.getElementById("ls_name").value = data.name || "";
  // Auto-detect role from name if not set
  var role = data.role || autoDetectRole(data.name || "");
  document.getElementById("ls_role").value = role;
  document.getElementById("ls_mass_kg").value = data.mass_kg ?? 600;
  document.getElementById("ls_root_LE").value = (data.root_LE || [0,0,0]).join(",");
  document.getElementById("ls_AR").value = data.AR ?? 8.33;
  document.getElementById("ls_TR").value = data.TR ?? 0.6;
  document.getElementById("ls_mirror").checked = !!data.mirror;
  document.getElementById("ls_symmetric").checked = !!data.symmetric;
  document.getElementById("ls_dihedral_DEG").value = data.dihedral_DEG ?? 3;
  document.getElementById("ls_vertical").checked = !!data.vertical;
  document.getElementById("ls_sweep_quarter_chord_DEG").value = data.sweep_quarter_chord_DEG ?? 15;
  document.getElementById("ls_surface_area_m2").value = data.surface_area_m2 ?? 48;
  document.getElementById("ls_mean_aerodynamic_chord_m").value = data.mean_aerodynamic_chord_m ?? 1.35;
  document.getElementById("ls_stations_eta").value = (data.stations_eta || [0,0.5,1]).join(",");
  document.getElementById("ls_radius_of_giration_pitch_m").value = data.radius_of_giration_pitch_m ?? 3.5;
  document.getElementById("ls_radius_of_giration_yaw_m").value = data.radius_of_giration_yaw_m ?? 4.0;
  document.getElementById("ls_radius_of_giration_roll_m").value = data.radius_of_giration_roll_m ?? 4.0;
  document.getElementById("ls_principal_axis_pitch_up_DEG").value = data.principal_axis_pitch_up_DEG ?? -2;
  document.getElementById("ls_CoG_pos_xyz_m").value = (data.CoG_pos_xyz_m || [0,0,0]).join(",");

  // Extended fields
  document.getElementById("ls_incidence_DEG").value = data.incidence_DEG ?? 0;
  document.getElementById("ls_twist_tip_DEG").value = data.twist_tip_DEG ?? 0;
  document.getElementById("ls_airfoil_root").value = (data.airfoil && data.airfoil.root) ? data.airfoil.root : "2412";
  document.getElementById("ls_airfoil_tip").value = (data.airfoil && data.airfoil.tip) ? data.airfoil.tip : "0012";
  if (typeof populateControlSurfaces === 'function') {
    populateControlSurfaces(data.control_surfaces || []);
  }

  document.getElementById("liftingSurfaceModal").style.display = "block";
}

/**
 * Fill the Fuselage modal
 */
function fillFuselageModal(data) {
  document.getElementById("fus_name").value = data.name || "fus1";
  document.getElementById("fus_diameter").value = data.diameter ?? 2.5;
  document.getElementById("fus_length").value = data.length ?? 15.0;
  document.getElementById("fus_nose_position").value = (data.nose_position || [0,0,0]).join(",");
  document.getElementById("fuselageModal").style.display = "block";
}

/**
 * Remove derived or legacy aerodynamic inputs from the editable aircraft
 * definition so ac_data files remain geometry/mass/propulsion-focused.
 */
function stripDerivedAerodynamicInputs(data) {
  if (!data || typeof data !== "object") return data;

  delete data.stall_parameters;
  delete data.dynamic_stall;
  delete data.tail_properties;

  var gen = data.general;
  if (gen && typeof gen === "object") {
    delete gen.Oswald_factor;
    delete gen.sideslip_drag_K;
    delete gen.scale_tail_forces;
  }

  var surfaces = data.lifting_surfaces;
  if (Array.isArray(surfaces)) {
    surfaces.forEach(function(surface) {
      if (!surface || typeof surface !== "object") return;
      delete surface.Oswald_factor;
      delete surface.aerodynamic_center_pos_xyz_m;
    });
  }

  return data;
}

function buildAcDataYaml(data) {
  var exportData = data && typeof data === "object"
    ? JSON.parse(JSON.stringify(data))
    : {};

  stripDerivedAerodynamicInputs(exportData);

  if (typeof jsyaml !== 'undefined') {
    return jsyaml.dump(exportData, { lineWidth: 120, noRefs: true, sortKeys: false });
  }

  return JSON.stringify(exportData, null, 2);
}

window.buildAcDataYaml = buildAcDataYaml;

/**
 * Parse aircraft data from JSON or YAML text
 */
function parseAircraft(text, filename) {
  var lowerName = (filename || '').toLowerCase();
  if (lowerName.endsWith('.yaml') || lowerName.endsWith('.yml')) {
    if (typeof jsyaml === 'undefined') {
      throw new Error('js-yaml library not available for parsing YAML files.');
    }
    aircraftData = jsyaml.load(text);
  } else {
    aircraftData = JSON.parse(text);
  }
  stripDerivedAerodynamicInputs(aircraftData);
  // Re-apply defaults for any missing extended fields (analysis, engines, etc.)
  if (typeof ensureExtendedData === 'function') ensureExtendedData();
  renderAircraft();
}

/**
 * Event Listener Setup
 */
(function setupUI() {
  // Lifting Surface Modal
  const lsModal = document.getElementById("liftingSurfaceModal");
  document.getElementById("ls_submit").addEventListener("click", function() {
    window.userNavigating = false;
    
    const newData = {
      name: document.getElementById("ls_name").value,
      role: document.getElementById("ls_role").value,
      mass_kg: parseFloat(document.getElementById("ls_mass_kg").value),
      root_LE: document.getElementById("ls_root_LE").value.split(",").map(Number),
      AR: parseFloat(document.getElementById("ls_AR").value),
      TR: parseFloat(document.getElementById("ls_TR").value),
      mirror: document.getElementById("ls_mirror").checked,
      symmetric: document.getElementById("ls_symmetric").checked,
      dihedral_DEG: parseFloat(document.getElementById("ls_dihedral_DEG").value),
      vertical: document.getElementById("ls_vertical").checked,
      sweep_quarter_chord_DEG: parseFloat(document.getElementById("ls_sweep_quarter_chord_DEG").value),
      surface_area_m2: parseFloat(document.getElementById("ls_surface_area_m2").value),
      mean_aerodynamic_chord_m: parseFloat(document.getElementById("ls_mean_aerodynamic_chord_m").value),
      stations_eta: document.getElementById("ls_stations_eta").value.split(",").map(Number),
      radius_of_giration_pitch_m: parseFloat(document.getElementById("ls_radius_of_giration_pitch_m").value),
      radius_of_giration_yaw_m: parseFloat(document.getElementById("ls_radius_of_giration_yaw_m").value),
      radius_of_giration_roll_m: parseFloat(document.getElementById("ls_radius_of_giration_roll_m").value),
      principal_axis_pitch_up_DEG: parseFloat(document.getElementById("ls_principal_axis_pitch_up_DEG").value),
      CoG_pos_xyz_m: document.getElementById("ls_CoG_pos_xyz_m").value.split(",").map(Number),
      incidence_DEG: parseFloat(document.getElementById("ls_incidence_DEG").value) || 0,
      twist_tip_DEG: parseFloat(document.getElementById("ls_twist_tip_DEG").value) || 0,
      airfoil: {
        type: "NACA",
        root: document.getElementById("ls_airfoil_root").value || "2412",
        tip: document.getElementById("ls_airfoil_tip").value || "0012"
      },
      control_surfaces: (typeof collectControlSurfaces === 'function') ? collectControlSurfaces() : []
    };

    if (window.editingType === "lifting_surface" && window.editingObject) {
      Object.assign(window.editingObject, newData);
      window.editingObject = null;
      window.editingType = "";
    } else {
      aircraftData.lifting_surfaces.push(newData);
    }

    lsModal.style.display = "none";
    renderAircraft();
    if (window.selectedComponent) {
      clearHighlight(window.selectedComponent);
      gizmoManager.attachToMesh(null);
      window.selectedComponent = null;
    }
    clearSelectedNameDisplay();
    if (typeof triggerAutoReanalysis === 'function') triggerAutoReanalysis();
  });
  document.getElementById("ls_cancel").addEventListener("click", function() {
    window.userNavigating = false;
    
    lsModal.style.display = "none";
    window.editingType = "";
    window.editingObject = null;
  });

  // Fuselage Modal
  const fusModal = document.getElementById("fuselageModal");
  document.getElementById("fus_submit").addEventListener("click", function() {
    window.userNavigating = false;
    
    const newData = {
      name: document.getElementById("fus_name").value,
      diameter: parseFloat(document.getElementById("fus_diameter").value),
      length: parseFloat(document.getElementById("fus_length").value),
      nose_position: document.getElementById("fus_nose_position").value.split(",").map(Number)
    };

    if (window.editingType === "fuselage" && window.editingObject) {
      Object.assign(window.editingObject, newData);
      window.editingObject = null;
      window.editingType = "";
    } else {
      if (!aircraftData.fuselages) {
        aircraftData.fuselages = [];
      }
      aircraftData.fuselages.push(newData);
    }

    fusModal.style.display = "none";
    renderAircraft();
    if (window.selectedComponent) {
      clearHighlight(window.selectedComponent);
      gizmoManager.attachToMesh(null);
      window.selectedComponent = null;
    }
    clearSelectedNameDisplay();
    if (typeof triggerAutoReanalysis === 'function') triggerAutoReanalysis();
  });
  document.getElementById("fus_cancel").addEventListener("click", function() {
    window.userNavigating = false;
    
    fusModal.style.display = "none";
    window.editingType = "";
    window.editingObject = null;
  });

  // "Add" buttons
  document.getElementById("addLiftingSurfaceBtn").addEventListener("click", function() {
    window.userNavigating = false;
    window.editingType = "";
    window.editingObject = null;
    fillLiftingSurfaceModal({});
  });
  document.getElementById("addFuselageBtn").addEventListener("click", function() {
    window.userNavigating = false;
    window.editingType = "";
    window.editingObject = null;
    fillFuselageModal({});
  });

  // Edit Selected
  document.getElementById("editComponentBtn").addEventListener("click", function() {
    window.userNavigating = false;
    
    if (!window.selectedComponent) return;
    const info = getMetadata(window.selectedComponent);
    if (info && info.metadata) {
      if (info.metadata.type === "lifting_surface") {
        window.editingType = "lifting_surface";
        window.editingObject = info.metadata.data;
        fillLiftingSurfaceModal(window.editingObject);
      } else if (info.metadata.type === "fuselage") {
        window.editingType = "fuselage";
        window.editingObject = info.metadata.data;
        fillFuselageModal(window.editingObject);
      } else if (info.metadata.type === "glb") {
        window.editingType = "glb";
        window.editingObject = info.metadata.data;
        fillGLBModal();
        document.getElementById("glbTransformSnippet").style.display = "block";
      }
    }
  });

  // Delete Selected
  document.getElementById("deleteComponentBtn").addEventListener("click", function() {
    window.userNavigating = false;
    
    if (!window.selectedComponent) return;
    const info = getMetadata(window.selectedComponent);
    if (!info || !info.metadata) return;

    const type = info.metadata.type;
    const dataRef = info.metadata.data;

    // Remove from JSON & Scene
    if (type === "lifting_surface") {
      const idx = aircraftData.lifting_surfaces.indexOf(dataRef);
      if (idx >= 0) {
        aircraftData.lifting_surfaces.splice(idx, 1);
      }
      renderAircraft();
    }
    else if (type === "fuselage") {
      const idx = aircraftData.fuselages.indexOf(dataRef);
      if (idx >= 0) {
        aircraftData.fuselages.splice(idx, 1);
      }
      renderAircraft();
    }
    else if (type === "glb") {
      // Dispose the GLB mesh and root
      if (window.currentGLBModel) {
        window.currentGLBModel.dispose();
        window.currentGLBModel = null;
      }
      if (window.glbRoot) {
        window.glbRoot.dispose();
        window.glbRoot = null;
      }
      document.getElementById("glbTransformSnippet").style.display = "none";
    }
    
    // Clear selection
    if (window.selectedComponent) {
      if (window.hl) {
        clearHighlight(window.selectedComponent);
      }
      gizmoManager.attachToMesh(null);
      window.selectedComponent = null;
    }
    clearSelectedNameDisplay();
    if (typeof triggerAutoReanalysis === 'function') triggerAutoReanalysis();
  });

  // JSON file input (hidden)
  const jsonFileInput = document.getElementById("jsonFileInput");
  document.getElementById("selectJsonBtn").addEventListener("click", function(event) {
    window.userNavigating = false;
    event.preventDefault();
    event.stopPropagation();
    jsonFileInput.click();
    return false;
  });
  
  jsonFileInput.addEventListener("change", function(event) {
    window.userNavigating = false;
    event.stopPropagation();

    const file = event.target.files[0];
    if (!file) return;
    const lname = file.name.toLowerCase();
    if (!lname.endsWith(".yaml") && !lname.endsWith(".yml") && !lname.endsWith(".json")) {
      alert("Please select a valid '.ac_data.yaml' or '.json' file.");
      return;
    }

    const reader = new FileReader();
    reader.onload = function(e) {
      try {
        parseAircraft(e.target.result, file.name);

        // Clear any selected component
        if (window.selectedComponent) {
          if (window.hl) {
            clearHighlight(window.selectedComponent);
          }
          window.selectedComponent = null;
        }
        clearSelectedNameDisplay();

        // Hide GLB transform snippet
        document.getElementById("glbTransformSnippet").style.display = "none";

        if (typeof recreateAxisProjectionsIfNeeded === 'function') {
          recreateAxisProjectionsIfNeeded();
        }

        jsonFileInput.value = '';
      } catch (error) {
        console.error("Error parsing aircraft data:", error);
        alert("Error loading aircraft data file: " + error.message);
      }
    };

    reader.onerror = function() {
      alert("Error reading the file. Please try again.");
    };

    reader.readAsText(file);
  });

  // Save aircraft data as YAML (via server folder picker, with browser-download fallback)
  document.getElementById("downloadJsonBtn").addEventListener("click", function(event) {
    window.userNavigating = false;
    event.preventDefault();
    event.stopPropagation();

    var yamlString = buildAcDataYaml(aircraftData);
    const name = (aircraftData.general && aircraftData.general.aircraft_name
                   ? aircraftData.general.aircraft_name.replace(/\s+/g, '_')
                   : 'aircraft');
    saveViaServer(yamlString, name + '.ac_data.yaml');
    return false;
  });

  // Clear Aircraft
  document.getElementById("clearAircraft").addEventListener("click", function() {
    window.userNavigating = false;
    
    aircraftData.lifting_surfaces = [];
    aircraftData.fuselages = [];
    renderAircraft();
    if (window.selectedComponent) {
      clearHighlight(window.selectedComponent);
      gizmoManager.attachToMesh(null);
      window.selectedComponent = null;
    }
    clearSelectedNameDisplay();
    
    if (typeof recreateAxisProjectionsIfNeeded === 'function') {
      recreateAxisProjectionsIfNeeded();
    }
  });

  // Toggle Ground
  document.getElementById("toggleGround").addEventListener("click", function() {
    window.userNavigating = false;
    
    if (window.ground) {
      ground.isVisible = !ground.isVisible;
      if (window.groundProjections) {
        window.groundProjections.setEnabled(true);
      }
      if (typeof recreateAxisProjectionsIfNeeded === 'function') {
        recreateAxisProjectionsIfNeeded();
      }
    }
  });

  // GLB file input (hidden)
  const glbRealInput = document.getElementById("glbFileInput");
  document.getElementById("selectGlbBtn").addEventListener("click", function(event) {
    window.userNavigating = false;
    event.preventDefault();
    event.stopPropagation();
    glbRealInput.click();
    return false;
  });
  
  glbRealInput.addEventListener("change", function(event) {
    window.userNavigating = false;
    event.stopPropagation();
    
    const file = event.target.files[0];
    if (!file) return;
    if (!file.name.toLowerCase().endsWith(".glb")) {
      alert("Please select a valid '.glb' file.");
      return;
    }
    
    window.lastLoadedGLBName = file.name;
    loadGLBFile(file);
    
    if (typeof recreateAxisProjectionsIfNeeded === 'function') {
      recreateAxisProjectionsIfNeeded();
    }
    glbRealInput.value = '';
  });
  
  // GLB Modal event handlers are registered in glb-editing.js — no duplication needed

  // Graphics settings modal is now handled in analysis-setup.js
})();

/**
 * Clear selected name display
 */
function clearSelectedNameDisplay() {
  const span = document.getElementById("selectedComponentName");
  span.innerText = "Selected: None";
  document.getElementById("editComponentBtn").disabled = true;
  document.getElementById("deleteComponentBtn").disabled = true;
}

/**
 * Update selected name display
 */
function updateSelectedNameDisplay(name) {
  const span = document.getElementById("selectedComponentName");
  span.innerText = "Selected: " + name;
  const isNoneOrGround = (name === "None" || name === "Ground");
  document.getElementById("editComponentBtn").disabled = isNoneOrGround;
  document.getElementById("deleteComponentBtn").disabled = isNoneOrGround;
}

/**
 * Open edit modal for selected
 */
function openEditModalForSelected() {
  if (!window.selectedComponent) return;
  const info = getMetadata(window.selectedComponent);
  if (info && info.metadata && info.metadata.data) {
    if (info.metadata.type === "lifting_surface") {
      window.editingType = "lifting_surface";
      window.editingObject = info.metadata.data;
      fillLiftingSurfaceModal(window.editingObject);
    } else if (info.metadata.type === "fuselage") {
      window.editingType = "fuselage";
      window.editingObject = info.metadata.data;
      fillFuselageModal(window.editingObject);
    } else if (info.metadata.type === "glb") {
      window.editingType = "glb";
      window.editingObject = info.metadata.data;
      fillGLBModal();
      document.getElementById("glbTransformSnippet").style.display = "block";
    }
  }
}

// Handle focus/blur events
window.addEventListener('blur', function() {
  window.userNavigating = false;
});
window.addEventListener('focus', function() {
  window.userNavigating = false;
});

// Also apply to all buttons
document.addEventListener('DOMContentLoaded', function() {
  const buttons = document.querySelectorAll('button');
  buttons.forEach(button => {
    button.addEventListener('click', function(e) {
      window.userNavigating = false;
    });
  });
});

// Prevent Alt+Left from navigating
window.addEventListener('keydown', function(e) {
  if (e.altKey && e.key === 'ArrowLeft') {
    e.preventDefault();
  }
});

// For clicks on the canvas
window.canvas.addEventListener('click', function() {
  window.userNavigating = false;
});

// For any clicks on document
document.addEventListener('click', function() {
  window.userNavigating = false;
});
