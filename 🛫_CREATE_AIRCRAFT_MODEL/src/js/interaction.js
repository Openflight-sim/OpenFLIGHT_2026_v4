/********************************************
 * FILE: interaction.js
 ********************************************/

/**
 * We disable gizmos by default, so the translation arrows never
 * appear when simply selecting an object.
 */
gizmoManager.positionGizmoEnabled = false;   // was `true`
gizmoManager.rotationGizmoEnabled = false;
gizmoManager.scaleGizmoEnabled    = false;

var pointerDownPos = null;
window.ctrlIsPressed = false;
window.isDraggingGizmo = false;

// GLB gizmo mode: "position" | "rotation" | "scale" | "off"
window.glbGizmoMode = "position";

// Track whether we've registered the position gizmo observables
var _posGizmoObserversRegistered = false;

/**
 * Sync all scene node positions back to aircraftData.
 * Must be called before any operation that reads aircraftData (analysis, export, etc.)
 */
function syncScenePositionsToData() {
  if (!window.aircraftRoot) return;
  window.aircraftRoot.getChildren().forEach(function(node) {
    if (!node.metadata || !node.metadata.data) return;
    if (node.metadata.type === "lifting_surface") {
      node.metadata.data.root_LE = [node.position.x, node.position.y, node.position.z];
    } else if (node.metadata.type === "fuselage") {
      node.metadata.data.nose_position = [node.position.x, node.position.y, node.position.z];
    }
  });
}
window.syncScenePositionsToData = syncScenePositionsToData;

/**
 * Rebuild VLM mesh from current aircraftData geometry.
 */
function rebuildVLMMesh() {
  if (typeof disposeVLMMesh === 'function') disposeVLMMesh();
  if (typeof buildVLMMeshFromGeometry === 'function' && typeof renderVLMMesh === 'function') {
    var geomMesh = buildVLMMeshFromGeometry();
    if (geomMesh && geomMesh.length > 0) renderVLMMesh(geomMesh);
  }
}

/**
 * Register drag start/end observables on the current position gizmo.
 * Called lazily the first time the gizmo is actually enabled.
 */
function ensurePositionGizmoObservers() {
  if (_posGizmoObserversRegistered) return;
  var pg = gizmoManager.gizmos.positionGizmo;
  if (!pg) return;

  _posGizmoObserversRegistered = true;

  pg.onDragStartObservable.add(function() {
    window.isDraggingGizmo = true;
  });

  pg.onDragEndObservable.add(function() {
    window.isDraggingGizmo = false;

    if (window.selectedComponent && window.selectedComponent.metadata) {
      var md = window.selectedComponent.metadata;
      if (md.type === "glb") {
        updateGLBMetadataFromTransform();
        if (typeof updateGLBTransformSnippet === 'function') {
          updateGLBTransformSnippet();
          document.getElementById("glbTransformSnippet").style.display = "block";
        }
      } else if (md.type === "lifting_surface" && md.data) {
        md.data.root_LE = [
          window.selectedComponent.position.x,
          window.selectedComponent.position.y,
          window.selectedComponent.position.z
        ];
        rebuildVLMMesh();
      } else if (md.type === "fuselage" && md.data) {
        md.data.nose_position = [
          window.selectedComponent.position.x,
          window.selectedComponent.position.y,
          window.selectedComponent.position.z
        ];
        rebuildVLMMesh();
      }
    }

    // Enforce ground-only vertical movement
    if (window.selectedComponent && window.selectedComponent.name === "ground") {
      const groundPos = window.selectedComponent.position;
      window.selectedComponent.position = new BABYLON.Vector3(0, groundPos.y, 0);
    }

    // Update JSON Editor if visible
    if (window.appState?.jsonEditorVisible && window.jsonEditor) {
      updateJsonEditor();
    }
  });
}

/**
 * Track Ctrl key down => enable the gizmo and attach to mesh
 */
window.addEventListener("keydown", function (evt) {
  if (evt.key === "Control") {
    window.ctrlIsPressed = true;

    // Enable & attach the position gizmo ONLY if something is selected
    gizmoManager.positionGizmoEnabled = true;

    // Register observers now that the gizmo actually exists
    ensurePositionGizmoObservers();

    if (window.selectedComponent) {
      gizmoManager.attachToMesh(window.selectedComponent);

      // Special case: restrict movement axes if ground is selected
      if (window.selectedComponent.name === "ground") {
        const groundGizmo = gizmoManager.gizmos.positionGizmo;
        groundGizmo.xGizmo.isEnabled = false;
        groundGizmo.zGizmo.isEnabled = false;
        groundGizmo.yGizmo.isEnabled = true;
      } else {
        // For non-ground objects, allow all axes
        const pg = gizmoManager.gizmos.positionGizmo;
        pg.xGizmo.isEnabled = true;
        pg.yGizmo.isEnabled = true;
        pg.zGizmo.isEnabled = true;
      }
    }
  }
});

window.addEventListener("keyup", function (evt) {
  if (evt.key === "Control") {
    window.ctrlIsPressed = false;

    // Sync positions to data before detaching gizmo (catches any drag that ended)
    syncScenePositionsToData();
    rebuildVLMMesh();

    // Detach gizmo (so it disappears)
    gizmoManager.attachToMesh(null);

    // Also disable the position gizmo so it won't show automatically
    gizmoManager.positionGizmoEnabled = false;

    // Final updates if selected is GLB or ground
    if (window.selectedComponent && window.selectedComponent.metadata?.type === "glb") {
      updateGLBMetadataFromTransform();
      if (typeof updateGLBTransformSnippet === 'function') {
        updateGLBTransformSnippet();
        document.getElementById("glbTransformSnippet").style.display = "block";
      }
    }
    if (window.selectedComponent?.name === "ground") {
      const groundPos = window.selectedComponent.position;
      window.selectedComponent.position = new BABYLON.Vector3(0, groundPos.y, 0);
    }

    // Update JSON Editor if visible
    if (window.appState?.jsonEditorVisible && window.jsonEditor) {
      updateJsonEditor();
    }
  }
});

/**
 * When we click (pointer down/up), figure out which object we picked.
 * If we pick "ground" or pick nothing, we clear selection. Otherwise,
 * we highlight the chosen component but do NOT attach the gizmo yet.
 */
scene.onPointerObservable.add(function (pointerInfo) {
  switch (pointerInfo.type) {
    case BABYLON.PointerEventTypes.POINTERDOWN:
      if (pointerInfo.event.button === 0) {
        pointerDownPos = {
          x: pointerInfo.event.clientX,
          y: pointerInfo.event.clientY
        };
      }
      break;

    case BABYLON.PointerEventTypes.POINTERUP:
      if (pointerInfo.event.button !== 0) return; // only left-click
      if (!pointerDownPos) return;

      const dx = pointerInfo.event.clientX - pointerDownPos.x;
      const dy = pointerInfo.event.clientY - pointerDownPos.y;
      const dist = Math.sqrt(dx*dx + dy*dy);
      const isClick = dist < 5;
      pointerDownPos = null;
      if (!isClick) return;

      const pickInfo = pointerInfo.pickInfo;
      if (!pickInfo.hit || pickInfo.pickedMesh.name === "ground") {
        // Unselect any current component
        if (window.selectedComponent) {
          clearHighlight(window.selectedComponent);
          detachGLBGizmo();
          window.selectedComponent = null;
        }
        clearSelectedNameDisplay();

        // If we actually clicked ground, treat "Ground" as selected
        if (pickInfo.hit && pickInfo.pickedMesh.name === "ground") {
          updateSelectedNameDisplay("Ground");
          window.selectedComponent = pickInfo.pickedMesh;
          // (But do NOT attach gizmo unless user holds Ctrl => done above)
        }

        // Hide GLB snippet if we are not on a GLB
        if (document.getElementById("glbTransformSnippet")) {
          document.getElementById("glbTransformSnippet").style.display = "none";
        }

        // Update JSON editor selection
        if (window.appState?.jsonEditorVisible && window.jsonEditor) {
          updateJsonEditorSelection(null);
        }
        return;
      }

      // We clicked a valid mesh with metadata
      const info = getMetadata(pickInfo.pickedMesh);
      if (info) {
        // Unhighlight old selection
        if (window.selectedComponent && window.selectedComponent !== info.mesh) {
          clearHighlight(window.selectedComponent);
        }
        // Select the new component (highlight only)
        window.selectedComponent = info.mesh;
        setColorLightPink(window.selectedComponent);

        // If not ground, re-enable all axes if/when Ctrl is pressed
        if (window.selectedComponent.name !== "ground" && gizmoManager.gizmos.positionGizmo) {
          gizmoManager.gizmos.positionGizmo.xGizmo.isEnabled = true;
          gizmoManager.gizmos.positionGizmo.yGizmo.isEnabled = true;
          gizmoManager.gizmos.positionGizmo.zGizmo.isEnabled = true;
        }

        const compName = info.metadata?.data?.name
          || (info.metadata?.type === "glb"
              ? "GLB: " + window.lastLoadedGLBName
              : "Unnamed");
        updateSelectedNameDisplay(compName);

        // If it's GLB, auto-attach gizmo and show the snippet
        if (info.metadata?.type === "glb") {
          attachGLBGizmo(window.selectedComponent);
          if (typeof updateGLBTransformSnippet === 'function') {
            updateGLBTransformSnippet();
            document.getElementById("glbTransformSnippet").style.display = "block";
          }
        } else {
          // Not a GLB — detach gizmo and hide snippet
          detachGLBGizmo();
          if (document.getElementById("glbTransformSnippet")) {
            document.getElementById("glbTransformSnippet").style.display = "none";
          }
        }

        // Update JSON editor selection:
        if (window.appState?.jsonEditorVisible && window.jsonEditor) {
          updateJsonEditorSelection(info);
        }
      }
      break;
  }
});

/**
 * After releasing the pointer, if we dragged something,
 * update the relevant position in JSON data and rebuild VLM mesh.
 */
scene.onPointerObservable.add(function (pointerInfo) {
  if (pointerInfo.type === BABYLON.PointerEventTypes.POINTERUP) {
    if (!window.selectedComponent) return;
    const md = window.selectedComponent.metadata;
    var geometryChanged = false;
    if (md && md.data) {
      if (md.type === "lifting_surface") {
        md.data.root_LE = [
          window.selectedComponent.position.x,
          window.selectedComponent.position.y,
          window.selectedComponent.position.z
        ];
        geometryChanged = true;
      } else if (md.type === "fuselage") {
        md.data.nose_position = [
          window.selectedComponent.position.x,
          window.selectedComponent.position.y,
          window.selectedComponent.position.z
        ];
        geometryChanged = true;
      } else if (md.type === "glb") {
        // Update GLB's stored metadata
        updateGLBMetadataFromTransform();
        if (typeof updateGLBTransformSnippet === 'function') {
          updateGLBTransformSnippet();
          document.getElementById("glbTransformSnippet").style.display = "block";
        }
      }
    }
    // If it's ground, force Y-only
    if (window.selectedComponent.name === "ground") {
      let gpos = window.selectedComponent.position;
      window.selectedComponent.position = new BABYLON.Vector3(0, gpos.y, 0);
    }
    // Rebuild VLM mesh immediately when geometry changes
    if (geometryChanged) {
      if (typeof disposeVLMMesh === 'function') disposeVLMMesh();
      if (typeof buildVLMMeshFromGeometry === 'function' && typeof renderVLMMesh === 'function') {
        var geomMesh = buildVLMMeshFromGeometry();
        if (geomMesh && geomMesh.length > 0) renderVLMMesh(geomMesh);
      }
    }
    // Update JSON Editor if visible
    if (window.appState?.jsonEditorVisible && window.jsonEditor) {
      updateJsonEditor();
    }
  }
});

/**
 * Double-click => open the edit modal for the selected object
 * (still does NOT attach the gizmo unless Ctrl is held).
 */
window.canvas.addEventListener("dblclick", function (evt) {
  // Only handle left button double-click
  if (evt.button !== 0) return;
  
  const pickResult = scene.pick(scene.pointerX, scene.pointerY);
  if (pickResult.hit) {
    const info = getMetadata(pickResult.pickedMesh);
    if (info && info.metadata) {
      // If not already selected, highlight it
      if (window.selectedComponent !== info.mesh) {
        if (window.selectedComponent) {
          clearHighlight(window.selectedComponent);
        }
        window.selectedComponent = info.mesh;
        setColorLightPink(window.selectedComponent);

        if (window.selectedComponent.name !== "ground" && gizmoManager.gizmos.positionGizmo) {
          // Just enabling axes (actual gizmo attach is only if Ctrl is pressed)
          gizmoManager.gizmos.positionGizmo.xGizmo.isEnabled = true;
          gizmoManager.gizmos.positionGizmo.yGizmo.isEnabled = true;
          gizmoManager.gizmos.positionGizmo.zGizmo.isEnabled = true;
        } else if (window.selectedComponent.name === "ground") {
          enforceGroundMovementRestrictions();
        }
        const compName = info.metadata?.data?.name
          || (info.metadata?.type === "glb"
              ? "GLB: " + window.lastLoadedGLBName
              : "Unnamed");
        updateSelectedNameDisplay(compName);

        // If JSON editor is open, highlight the appropriate node
        if (window.appState?.jsonEditorVisible && window.jsonEditor) {
          updateJsonEditorSelection(info);
        }
      }

      // Show the appropriate modal
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
});

/**
 * Real-time updates while dragging the gizmo (if Ctrl is held)
 */
scene.onBeforeRenderObservable.add(() => {
  // If currently dragging a GLB, update snippet in real-time
  if (window.isDraggingGizmo && 
      window.selectedComponent?.metadata?.type === "glb") {
    if (typeof updateGLBTransformSnippet === 'function') {
      updateGLBTransformSnippet();
      document.getElementById("glbTransformSnippet").style.display = "block";
    }
  }
  // If ground is selected & being dragged, keep it Y-only
  if (window.isDraggingGizmo && window.selectedComponent?.name === "ground") {
    let groundPos = window.selectedComponent.position;
    window.selectedComponent.position = new BABYLON.Vector3(0, groundPos.y, 0);
  }
});

/**
 * Update JSON editor data from `window.aircraftData`
 */
function updateJsonEditor() {
  if (window.jsonEditor) {
    window.jsonEditor.update(window.aircraftData);
  }
}

/**
 * If a user selects something, focus that part of the JSON in the editor
 */
function updateJsonEditorSelection(info) {
  if (!window.jsonEditor) return;
  if (!info) {
    window.jsonEditor.setSelection({});
    return;
  }
  if (info.metadata.type === "lifting_surface") {
    const idx = window.aircraftData.lifting_surfaces.indexOf(info.metadata.data);
    if (idx >= 0) {
      window.jsonEditor.setSelection({ path: ["lifting_surfaces", idx] });
      window.jsonEditor.expandAll();
    }
  } else if (info.metadata.type === "fuselage") {
    const idx = window.aircraftData.fuselages.indexOf(info.metadata.data);
    if (idx >= 0) {
      window.jsonEditor.setSelection({ path: ["fuselages", idx] });
      window.jsonEditor.expandAll();
    }
  } else if (info.metadata.type === "glb") {
    // GLB has no direct JSON array in `aircraftData`
    window.jsonEditor.setSelection({});
  }
}

/**
 * Sync GLB metadata with the transform of the selected mesh
 */
function updateGLBMetadataFromTransform() {
  if (!window.selectedComponent?.metadata) return;
  const md = window.selectedComponent.metadata;
  if (md.type === "glb") {
    if (!md.data) md.data = {};
    md.data.position = [
      window.selectedComponent.position.x,
      window.selectedComponent.position.y,
      window.selectedComponent.position.z
    ];
    md.data.rotationDeg = [
      BABYLON.Tools.ToDegrees(window.selectedComponent.rotation.x),
      BABYLON.Tools.ToDegrees(window.selectedComponent.rotation.y),
      BABYLON.Tools.ToDegrees(window.selectedComponent.rotation.z)
    ];
    md.data.scale = window.selectedComponent.scaling.x;
  }
}

/**
 * Ground is restricted to Y-axis only
 */
function enforceGroundMovementRestrictions() {
  if (window.selectedComponent && window.selectedComponent.name === "ground") {
    if (gizmoManager.gizmos.positionGizmo) {
      gizmoManager.gizmos.positionGizmo.xGizmo.isEnabled = false;
      gizmoManager.gizmos.positionGizmo.zGizmo.isEnabled = false;
      gizmoManager.gizmos.positionGizmo.yGizmo.isEnabled = true;
    }
    let pos = window.selectedComponent.position;
    window.selectedComponent.position = new BABYLON.Vector3(0, pos.y, 0);
  }
}

// ================================================================
// GLB Gizmo: auto-attach and mode cycling (G/R/S keys)
// ================================================================

/**
 * Attach the appropriate gizmo to the GLB based on current mode.
 * Called when a GLB object is selected or gizmo mode changes.
 */
function attachGLBGizmo(mesh) {
  if (!mesh) { detachGLBGizmo(); return; }

  // Disable all gizmo types first
  gizmoManager.positionGizmoEnabled = false;
  gizmoManager.rotationGizmoEnabled = false;
  gizmoManager.scaleGizmoEnabled = false;

  switch (window.glbGizmoMode) {
    case "position":
      gizmoManager.positionGizmoEnabled = true;
      break;
    case "rotation":
      gizmoManager.rotationGizmoEnabled = true;
      break;
    case "scale":
      gizmoManager.scaleGizmoEnabled = true;
      break;
    case "off":
      gizmoManager.attachToMesh(null);
      updateGizmoIndicator();
      return;
  }

  gizmoManager.attachToMesh(mesh);

  // Set up drag observers for the newly enabled gizmo
  var activeGizmo = null;
  if (window.glbGizmoMode === "position" && gizmoManager.gizmos.positionGizmo)
    activeGizmo = gizmoManager.gizmos.positionGizmo;
  else if (window.glbGizmoMode === "rotation" && gizmoManager.gizmos.rotationGizmo)
    activeGizmo = gizmoManager.gizmos.rotationGizmo;
  else if (window.glbGizmoMode === "scale" && gizmoManager.gizmos.scaleGizmo)
    activeGizmo = gizmoManager.gizmos.scaleGizmo;

  if (activeGizmo) {
    activeGizmo.onDragStartObservable.add(function() { window.isDraggingGizmo = true; });
    activeGizmo.onDragEndObservable.add(function() {
      window.isDraggingGizmo = false;
      if (window.selectedComponent && window.selectedComponent.metadata &&
          window.selectedComponent.metadata.type === "glb") {
        updateGLBMetadataFromTransform();
        if (typeof updateGLBTransformSnippet === 'function') {
          updateGLBTransformSnippet();
          document.getElementById("glbTransformSnippet").style.display = "block";
        }
      }
      if (window.appState && window.appState.jsonEditorVisible && window.jsonEditor) {
        updateJsonEditor();
      }
    });
  }

  updateGizmoIndicator();
}

function detachGLBGizmo() {
  gizmoManager.positionGizmoEnabled = false;
  gizmoManager.rotationGizmoEnabled = false;
  gizmoManager.scaleGizmoEnabled = false;
  gizmoManager.attachToMesh(null);
  updateGizmoIndicator();
}

/**
 * Cycle gizmo mode: position -> rotation -> scale -> off -> position ...
 */
function cycleGLBGizmoMode() {
  var modes = ["position", "rotation", "scale", "off"];
  var idx = modes.indexOf(window.glbGizmoMode);
  window.glbGizmoMode = modes[(idx + 1) % modes.length];

  if (window.selectedComponent && window.selectedComponent.metadata &&
      window.selectedComponent.metadata.type === "glb") {
    attachGLBGizmo(window.selectedComponent);
  }
}

/**
 * Set a specific gizmo mode
 */
function setGLBGizmoMode(mode) {
  window.glbGizmoMode = mode;
  if (window.selectedComponent && window.selectedComponent.metadata &&
      window.selectedComponent.metadata.type === "glb") {
    attachGLBGizmo(window.selectedComponent);
  }
}

/**
 * Update the gizmo mode indicator in the UI
 */
function updateGizmoIndicator() {
  var el = document.getElementById("gizmoModeIndicator");
  if (!el) return;
  var labels = { position: "Move (G)", rotation: "Rotate (R)", scale: "Scale (S)", off: "Off" };
  var colors = { position: "#3498db", rotation: "#e74c3c", scale: "#f1c40f", off: "#7f8c8d" };
  el.textContent = labels[window.glbGizmoMode] || "Off";
  el.style.background = colors[window.glbGizmoMode] || "#7f8c8d";
  el.style.display = (window.selectedComponent && window.selectedComponent.metadata &&
                       window.selectedComponent.metadata.type === "glb") ? "inline-block" : "none";
}

// Keyboard shortcuts for gizmo modes (only when not typing in an input)
window.addEventListener("keydown", function(evt) {
  // Don't intercept if user is typing in an input/textarea
  var tag = document.activeElement ? document.activeElement.tagName.toLowerCase() : "";
  if (tag === "input" || tag === "textarea" || tag === "select") return;

  // Only active when GLB is selected
  if (!window.selectedComponent || !window.selectedComponent.metadata ||
      window.selectedComponent.metadata.type !== "glb") return;

  switch (evt.key.toLowerCase()) {
    case "g": setGLBGizmoMode("position"); evt.preventDefault(); break;
    case "r": setGLBGizmoMode("rotation"); evt.preventDefault(); break;
    case "s": setGLBGizmoMode("scale"); evt.preventDefault(); break;
    case "escape": setGLBGizmoMode("off"); evt.preventDefault(); break;
  }
});

// Export functions
window.attachGLBGizmo = attachGLBGizmo;
window.detachGLBGizmo = detachGLBGizmo;
window.cycleGLBGizmoMode = cycleGLBGizmoMode;
window.setGLBGizmoMode = setGLBGizmoMode;
