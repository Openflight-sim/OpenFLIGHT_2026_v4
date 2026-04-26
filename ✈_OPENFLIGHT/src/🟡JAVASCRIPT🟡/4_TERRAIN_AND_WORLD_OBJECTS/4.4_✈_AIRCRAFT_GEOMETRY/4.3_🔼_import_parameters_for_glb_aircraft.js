
// ========================================================
// GLB Transformation Lookup
// ========================================================
/**
 * Returns transformation and positioning parameters for the current
 * aircraft's GLB model.
 *
 * The per-aircraft values USED to live as a giant `switch (fileName)`
 * block here.  That coupled the simulator code to every aircraft the
 * project ever shipped, and required a JS edit every time somebody added
 * a new model.  Values now live in an optional `render_settings.yaml`
 * that sits next to the `.glb` inside each aircraft folder — the
 * Julia-side loader parses it and ships the dict over the WebSocket as
 * `render_settings`; 1.1_... stows it on `window.aircraftRenderSettings`
 * before this function is called.
 *
 * Contract:
 *   - If `window.aircraftRenderSettings` has a `glb_transform`, `lights`,
 *     or `propeller` section, those fields override the defaults below.
 *   - Any missing section or key falls back to the default, so the file
 *     can be as minimal as you like (e.g. only the GLB rotation).
 *   - If `render_settings.yaml` is absent entirely, every aircraft runs
 *     on the exact defaults established here — which match the PC21
 *     baseline look.
 *
 * Convention for body-frame offsets: x toward the tail from CoG,
 *   y upwards from CoG, z toward the right wing from CoG.
 *
 * @param {string} fileName - The GLB filename (e.g. "PC9.glb").
 *                            Kept in the signature only for legacy call
 *                            sites; the settings now come from server state.
 * @returns {Object} params with scaleFactor, rotation*, translation*,
 *                   light positions, propeller info.
 */
function getGLBTransformations(fileName) {
    const params = {
        scaleFactor: 1,
        rotationX: 0, rotationY: 0, rotationZ: 0,
        translationX: 0, translationY: 0, translationZ: 0,
        wing_lights_pos: null,
        tailcone_light_pos: null,
        strobe_light_pos: null,
        propeller_pos: null,
        propeller_diameter: null
    };

    const rs = (typeof window !== 'undefined' && window.aircraftRenderSettings) || null;
    if (!rs) {
        return params;
    }

    // ── GLB transform: rotation (degrees), translation (meters), scale ──
    if (rs.glb_transform && typeof rs.glb_transform === 'object') {
        const gt = rs.glb_transform;
        if (typeof gt.scale === 'number') params.scaleFactor = gt.scale;
        if (gt.rotation_deg && typeof gt.rotation_deg === 'object') {
            if (typeof gt.rotation_deg.x === 'number') params.rotationX = gt.rotation_deg.x;
            if (typeof gt.rotation_deg.y === 'number') params.rotationY = gt.rotation_deg.y;
            if (typeof gt.rotation_deg.z === 'number') params.rotationZ = gt.rotation_deg.z;
        }
        if (gt.translation_m && typeof gt.translation_m === 'object') {
            if (typeof gt.translation_m.x === 'number') params.translationX = gt.translation_m.x;
            if (typeof gt.translation_m.y === 'number') params.translationY = gt.translation_m.y;
            if (typeof gt.translation_m.z === 'number') params.translationZ = gt.translation_m.z;
        }
    }

    // ── Position lights (`null` means "disabled") ──
    // Accepts either a 3-element array [x, y, z] or an object {x, y, z}.
    const _coerceXYZArray = (value) => {
        if (Array.isArray(value) && value.length >= 3) {
            const [x, y, z] = value;
            if ([x, y, z].every((v) => typeof v === 'number')) return [x, y, z];
        }
        if (value && typeof value === 'object' &&
            typeof value.x === 'number' && typeof value.y === 'number' && typeof value.z === 'number') {
            return [value.x, value.y, value.z];
        }
        return null;
    };
    if (rs.lights && typeof rs.lights === 'object') {
        const l = rs.lights;
        params.wing_lights_pos    = _coerceXYZArray(l.wing_tip_position)   || params.wing_lights_pos;
        params.tailcone_light_pos = _coerceXYZArray(l.tailcone_position)   || params.tailcone_light_pos;
        params.strobe_light_pos   = _coerceXYZArray(l.strobe_position)     || params.strobe_light_pos;
    }

    // ── Propeller pivot ──
    // The yaml spec is strict: position is a body-frame offset in meters
    // and `diameter_m` is the physical tip-to-tip diameter in meters.
    // This value is authoritative — if the GLB ships a propeller mesh
    // the parametric propeller is drawn on top at whatever size the yaml
    // dictates, giving the user full override control.
    if (rs.propeller && typeof rs.propeller === 'object') {
        const p = rs.propeller;
        const pos = _coerceXYZArray(p.position);
        if (pos) params.propeller_pos = pos;
        if (typeof p.diameter_m === 'number') params.propeller_diameter = p.diameter_m;
    }

    return params;
}

// Remembers the diameter_m the blades were last BUILT at. When the yaml
// value changes (user edits render_settings.yaml and restarts), we
// rebuild the ribbon mesh at the new size via rebuildPropellerBlades in
// 4.1_✈_default_aircraft_model.js.  When the value is unchanged we
// leave the existing mesh alone — no per-frame work, no accumulation.
let _lastAppliedPropellerDiameterM = null;

// Flag to prevent auto-loading GLB more than once
let glbAutoLoaded = false;
// Filename of the GLB we auto-loaded, used for logging when render_settings
// are re-applied on respawn.
let glbAutoLoadedFilename = null;

/**
 * Re-applies the current window.aircraftRenderSettings to the already-loaded
 * GLB aircraft: glbNode transform (scale / rotation / translation), position
 * lights, and propeller pivot. Safe to call when the GLB has not been loaded
 * yet (no-op), and safe to call repeatedly (idempotent).
 *
 * This exists so the user can edit `render_settings.yaml` inside the
 * aircraft folder, press the respawn/restart button, and see the edits
 * applied without restarting Julia — the server re-reads the file on
 * every reload_data message and re-ships the dict, and we use that to
 * refresh the live scene here.
 *
 * @param {BABYLON.Scene} scene - The Babylon scene, used to look up
 *   named light / propeller nodes.
 * @param {BABYLON.ShadowGenerator} [shadowGenerator] - Optional; only
 *   needed on the first apply call so the newly-parented meshes register
 *   as shadow casters.  On subsequent calls the shadow binding is
 *   already in place.
 */
function applyRenderSettingsToAircraft(scene, shadowGenerator) {
    if (!scene) return;
    if (!glbNode) {
        // No GLB in the scene yet (either still loading, or disabled by
        // scenery_complexity === 0).  Nothing to re-apply — when/if a GLB
        // does load, `loadGLBFromURL` will call this function itself.
        return;
    }

    const params = getGLBTransformations(glbAutoLoadedFilename || "");

    // --- GLB transform ---
    glbNode.scaling = new BABYLON.Vector3(params.scaleFactor, params.scaleFactor, params.scaleFactor);
    glbNode.rotationQuaternion = null;
    glbNode.rotation = new BABYLON.Vector3(
        BABYLON.Tools.ToRadians(params.rotationX),
        BABYLON.Tools.ToRadians(params.rotationY),
        BABYLON.Tools.ToRadians(params.rotationZ)
    );
    glbNode.position = new BABYLON.Vector3(params.translationX, params.translationY, params.translationZ);
    // Mirror Z so the GLB's right-wing convention matches the sim's
    // z-toward-right-wing body frame. Done after scaling so it survives
    // re-applies without double-flipping (we always reset scaling above).
    glbNode.scaling.z *= -1;

    if (typeof aircraft !== 'undefined' && aircraft) {
        glbNode.parent = aircraft;
    }

    // Shadow binding is a one-time thing — register the new child meshes
    // only when a shadowGenerator is handed to us (first-load case).
    if (shadowGenerator) {
        glbNode.getChildMeshes(true).forEach((mesh) => {
            shadowGenerator.addShadowCaster(mesh);
            mesh.receiveShadows = false;
        });
        if (glbNode instanceof BABYLON.AbstractMesh) {
            shadowGenerator.addShadowCaster(glbNode);
            glbNode.receiveShadows = false;
        }
    }

    // --- Lights + propeller: always re-apply so yaml edits pick up ---
    // The parametric default aircraft (planeNode) owns the light meshes;
    // they stay disabled once we've loaded a GLB.
    if (typeof planeNode !== 'undefined' && planeNode) {
        planeNode.setEnabled(false);
    }

    const rightWingLight = scene.getMeshByName("starboard_light");
    const leftWingLight = scene.getMeshByName("port_light");
    if (rightWingLight && leftWingLight) {
        if (params.wing_lights_pos) {
            rightWingLight.position = new BABYLON.Vector3(
                params.wing_lights_pos[0], params.wing_lights_pos[1], -params.wing_lights_pos[2]
            );
            leftWingLight.position = new BABYLON.Vector3(
                params.wing_lights_pos[0], params.wing_lights_pos[1], params.wing_lights_pos[2]
            );
            if (typeof aircraft !== 'undefined' && aircraft) {
                rightWingLight.parent = aircraft;
                leftWingLight.parent = aircraft;
            }
            rightWingLight.setEnabled(true);
            leftWingLight.setEnabled(true);
        } else {
            rightWingLight.setEnabled(false);
            leftWingLight.setEnabled(false);
        }
    }

    const tailconeLight = scene.getMeshByName("tailcone_light");
    if (tailconeLight) {
        if (params.tailcone_light_pos) {
            tailconeLight.position = new BABYLON.Vector3(
                params.tailcone_light_pos[0], params.tailcone_light_pos[1], params.tailcone_light_pos[2]
            );
            if (typeof aircraft !== 'undefined' && aircraft) {
                tailconeLight.parent = aircraft;
            }
            tailconeLight.setEnabled(true);
        } else {
            tailconeLight.setEnabled(false);
        }
    }

    const strobeLight = scene.getMeshByName("strobe_light");
    if (strobeLight) {
        if (params.strobe_light_pos) {
            strobeLight.position = new BABYLON.Vector3(
                params.strobe_light_pos[0], params.strobe_light_pos[1], params.strobe_light_pos[2]
            );
            if (typeof aircraft !== 'undefined' && aircraft) {
                strobeLight.parent = aircraft;
            }
            strobeLight.setEnabled(true);
        } else {
            strobeLight.setEnabled(false);
        }
    }

    const propellerPivot = scene.getTransformNodeByName("propellerPivot");
    const yamlHasPropellerSection = !!(params.propeller_pos && params.propeller_diameter);
    // Track whether the yaml has a propeller block so the per-camera
    // visibility logic in 6.4 can combine it with the camera's
    // render_propeller flag.
    window.aircraftHasPropellerInYaml = yamlHasPropellerSection;
    if (propellerPivot) {
        if (yamlHasPropellerSection) {
            propellerPivot.position = new BABYLON.Vector3(
                params.propeller_pos[0], params.propeller_pos[1], params.propeller_pos[2]
            );
            // IMPORTANT: no pivot scaling. The blade mesh is rebuilt
            // directly at the requested tip-to-tip diameter by the
            // helper in 4.1_✈_default_aircraft_model.js so the transform
            // chain stays at scale 1 end-to-end.  This eliminates any
            // possibility of a hidden scale factor combining with GLB
            // scale / parent scale / animation and producing the wildly-
            // out-of-scale propeller we observed previously.
            propellerPivot.scaling = new BABYLON.Vector3(1, 1, 1);

            const requestedDiameterM = params.propeller_diameter;
            if (_lastAppliedPropellerDiameterM !== requestedDiameterM) {
                if (typeof window.rebuildPropellerBlades === 'function') {
                    window.rebuildPropellerBlades(
                        scene,
                        propellerPivot,
                        requestedDiameterM,
                        shadowGenerator  // only non-null on first GLB apply; idempotent otherwise
                    );
                }
                _lastAppliedPropellerDiameterM = requestedDiameterM;
            }

            if (typeof aircraft !== 'undefined' && aircraft) {
                propellerPivot.parent = aircraft;
            }
            // Provisional enable; the per-camera visibility pass below
            // will refine this based on the active camera's
            // render_propeller flag.
            propellerPivot.setEnabled(true);
        } else {
            propellerPivot.setEnabled(false);
            _lastAppliedPropellerDiameterM = null;
        }
    }

    // Re-apply the per-camera render_aircraft / render_propeller flags
    // now that the yaml's propeller section state is known. Cheap no-op
    // if setupCameras hasn't registered the helper yet.
    if (scene && typeof scene.applyPerCameraAircraftVisibility === 'function') {
        scene.applyPerCameraAircraftVisibility();
    }
}

// Expose so 1.1_🔁_exchange_aircraft_state_with_server.js can call this
// whenever fresh render_settings arrive from the server.
if (typeof window !== 'undefined') {
    window.applyRenderSettingsToAircraft = applyRenderSettingsToAircraft;
}

// Global gate: while a GLB is being fetched, uploaded, and its materials
// are still compiling on the render thread, the simulation must not
// advance. Otherwise the first frame after the meshes become visible
// triggers a multi-hundred-ms shader-compile stall that shows up as a
// one-off jerk mid-flight. sendStateToServer() in 1.1_... reads this.
window.isGlbLoading = false;

// Pre-create a DOM overlay lazily the first time we need it.
function _showGlbLoadingOverlay(label) {
    let overlay = document.getElementById('glbLoadingOverlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'glbLoadingOverlay';
        overlay.style.cssText =
            'position:fixed;top:0;left:0;width:100%;height:100%;' +
            'background:rgba(0,0,0,0.78);color:#fff;' +
            'display:flex;align-items:center;justify-content:center;' +
            'font-family:"Segoe UI",Arial,sans-serif;font-size:22px;' +
            'letter-spacing:0.5px;z-index:99999;pointer-events:none;';
        document.body.appendChild(overlay);
    }
    // Prefer updating the title sub-element if it exists (the inline
    // bootstrap script in front_end_and_client.html creates the title +
    // mission-info pre on first load). Otherwise fall back to the legacy
    // single-line behaviour.
    const titleEl = overlay.querySelector('#glbLoadingTitle');
    if (titleEl) {
        titleEl.textContent = label || 'Loading aircraft model…';
    } else {
        overlay.textContent = label || 'Loading aircraft model…';
    }
    overlay.style.display = 'flex';
}

function _hideGlbLoadingOverlay() {
    const overlay = document.getElementById('glbLoadingOverlay');
    if (overlay) overlay.style.display = 'none';
}

function _finishGlbGate() {
    window.isGlbLoading = false;
    _hideGlbLoadingOverlay();
    // Reset client dt so the first resumed frame does not report a
    // multi-second deltaTime to the server (which would be clamped and
    // then produce a visible "jump back to reality").
    if (typeof window.resetServerDataTimer === 'function') {
        window.resetServerDataTimer();
    }
}

/**
 * Auto-loads a GLB model from a server URL (e.g. /aircraft/PC21.glb).
 * Called automatically when the server reports a .glb file in the aircraft folder.
 *
 * @param {string} url - The URL to fetch the GLB from.
 * @param {BABYLON.Scene} scene - The Babylon.js scene.
 * @param {BABYLON.ShadowGenerator} shadowGenerator - The shadow generator.
 */
function loadGLBFromURL(url, scene, shadowGenerator) {
    if (glbAutoLoaded || !scene) return;
    // Skip GLB entirely at scenery_complexity 0 (low-spec / debug path).
    // Mesh upload + shader compile on first render of a freshly-loaded
    // GLB is a well-known mid-flight stall source.
    if (typeof scenery_complexity !== 'undefined' && scenery_complexity <= 0) {
        console.log("Skipping GLB auto-load (scenery_complexity=0):", url);
        return;
    }
    glbAutoLoaded = true;

    // Extract the filename from the URL for transformation lookup
    const fileName = url.split('/').pop();
    glbAutoLoadedFilename = fileName;
    console.log(`Auto-loading GLB model: ${fileName} from ${url}`);

    // Raise the global gate BEFORE the async fetch begins so the next
    // render-loop tick already sees it and stops advancing physics.
    window.isGlbLoading = true;
    _showGlbLoadingOverlay(`Loading aircraft model (${fileName})…`);

    // Clear previous GLB model
    if (glbNode) {
        glbNode.dispose(false, true);
        glbNode = null;
    }

    if (!BABYLON.SceneLoader) {
        console.error("SceneLoader not available.");
        glbAutoLoaded = false;
        return;
    }

    // Split URL into rootUrl and filename for ImportMeshAsync
    const lastSlash = url.lastIndexOf('/');
    const rootUrl = url.substring(0, lastSlash + 1);
    const sceneFile = url.substring(lastSlash + 1);

    BABYLON.SceneLoader.ImportMeshAsync("", rootUrl, sceneFile, scene, null, ".glb")
        .then((result) => {
            if (!result.meshes || result.meshes.length === 0) {
                console.warn("GLB loaded but no meshes found.");
                return;
            }

            let rootNode = result.meshes.find(m => m.name === "__root__");
            if (!rootNode) {
                rootNode = new BABYLON.TransformNode("glbRoot_" + fileName, scene);
                result.meshes.forEach(mesh => {
                    if (!mesh.parent) mesh.parent = rootNode;
                });
            }
            glbNode = rootNode;
            console.log("GLB auto-loaded successfully:", glbNode.name);

            // Delegate transform / lights / propeller placement to the
            // shared helper. Pass shadowGenerator on first-load only so it
            // registers the new meshes as shadow casters.
            applyRenderSettingsToAircraft(scene, shadowGenerator);

            if (result.animationGroups && result.animationGroups.length > 0) {
                result.animationGroups.forEach(ag => ag.play(true));
            }

            // Wait until Babylon reports the scene is ready to render, which
            // in practice means every material/texture/mesh has finished
            // uploading and compiling. Only THEN do we drop the gate; the
            // first un-gated render frame is guaranteed stall-free.
            const readyPromise = (scene && typeof scene.whenReadyAsync === 'function')
                ? scene.whenReadyAsync()
                : new Promise((resolve) => {
                    // Fallback for older Babylon: spin 3 frames so mesh
                    // upload + first-use shader compile has a chance to run.
                    let framesLeft = 3;
                    const tick = () => {
                        framesLeft -= 1;
                        if (framesLeft <= 0) resolve();
                        else requestAnimationFrame(tick);
                    };
                    requestAnimationFrame(tick);
                });
            return readyPromise;
        })
        .then(() => {
            console.log("GLB ready; releasing simulation gate.");
            _finishGlbGate();
        })
        .catch((error) => {
            console.error("Error auto-loading GLB:", error);
            glbAutoLoaded = false;
            if (planeNode) planeNode.setEnabled(true);
            // Release the gate on failure so the sim doesn't freeze forever.
            _finishGlbGate();
        });
}

function setup_GLB_model_transformations(scene, shadowGenerator) {
    const fileInput = document.getElementById("fileInput");

    if (!fileInput) {
        console.error("fileInput element not found. Cannot set up GLB loading.");
        return;
    }

    fileInput.addEventListener("change", (event) => {
      const file = event.target.files ? event.target.files[0] : null;
      if (!file) {
          console.log("No file selected.");
          event.target.value = null;
          return;
      }

      const fileName = file.name;
      console.log("File selected:", fileName);

      if (fileName.toLowerCase().endsWith(".glb")) {
        const params = getGLBTransformations(fileName);

        loadGLB(
          file,
          params.scaleFactor,
          params.rotationX,
          params.rotationY,
          params.rotationZ,
          params.translationX,
          params.translationY,
          params.translationZ,
          scene,
          shadowGenerator,
          params.wing_lights_pos,
          params.tailcone_light_pos,
          params.strobe_light_pos,
          params.propeller_pos,
          params.propeller_diameter
        );
      } else {
        alert("Please select a valid .glb file");
      }
      event.target.value = null;
    });
}