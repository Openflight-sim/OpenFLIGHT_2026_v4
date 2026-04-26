/**
 * Sets up and configures all cameras for the scene.
 *
 * @param {BABYLON.Scene} scene - The Babylon.js scene.
 * @param {HTMLCanvasElement} canvas - The canvas element for camera controls.
 * @param {BABYLON.ShadowGenerator} shadowGenerator - (Optional) Shadow generator for the scene.
 * @returns {Object} An object containing all camera instances.
 */
function setupCameras(scene, canvas, shadowGenerator) {
  // Create and configure the main orbital (arc rotate) camera.
  const arcRotateCamera = new BABYLON.ArcRotateCamera(
    "ArcRotateCamera",
    -1.2, // Alpha rotation.
    1.6,  // Beta rotation.
    100,  // Radius (distance from target).
    new BABYLON.Vector3(170, 110, -70), // Target position.
    scene
  );
  arcRotateCamera.minZ = 10;
  arcRotateCamera.maxZ = 50000;
  arcRotateCamera.fovMode = BABYLON.Camera.FOVMODE_VERTICAL_FIXED;
  arcRotateCamera.fov = 0.8; // Standard FOV (~45 degrees)
  arcRotateCamera.attachControl(canvas, true);
  arcRotateCamera.upperBetaLimit = Math.PI;
  arcRotateCamera.lowerBetaLimit = 0;
  arcRotateCamera.inertia = 0.9;
  arcRotateCamera.lowerRadiusLimit = 10;
  arcRotateCamera.upperRadiusLimit = 1650;
  arcRotateCamera.wheelPrecision = 8;

  if (arcRotateCamera.inputs.attached.pointers) {
    arcRotateCamera.inputs.attached.pointers.panningSensibility = 10;
  }

  // Create the chase camera. Its pose is updated explicitly after the aircraft
  // visual pose is smoothed, avoiding Babylon FollowCamera's separate lag loop.
  const followCamera = new BABYLON.UniversalCamera(
    "FollowCamera",
    new BABYLON.Vector3(-10, 5, 0),
    scene
  );
  followCamera.rotationQuaternion = BABYLON.Quaternion.Identity();
  followCamera.minZ = 10;
  followCamera.maxZ = 50000;
  followCamera.fovMode = BABYLON.Camera.FOVMODE_VERTICAL_FIXED;
  followCamera.fov = 0.8; // Match arc rotate camera
  followCamera.upVector = new BABYLON.Vector3(0, 1, 0);

  // Create the cockpit camera (first-person view).
  const cockpitCamera = new BABYLON.UniversalCamera(
    "CockpitCamera",
    new BABYLON.Vector3(0, 0, 0),
    scene
  );
  cockpitCamera.rotationQuaternion = BABYLON.Quaternion.Identity();
  cockpitCamera.fovMode = BABYLON.Camera.FOVMODE_VERTICAL_FIXED;
  cockpitCamera.fov = 0.87; // Slightly wider for cockpit immersion
  cockpitCamera.minZ = 0.1; // Closer near plane for cockpit details
  cockpitCamera.maxZ = 50000;

  // Create the wing camera (external view).
  const wingCamera = new BABYLON.UniversalCamera(
    "WingCamera",
    new BABYLON.Vector3(0, 0, 0),
    scene
  );
  wingCamera.rotationQuaternion = BABYLON.Quaternion.Identity();
  wingCamera.minZ = 0.1;
  wingCamera.maxZ = 50000;
  wingCamera.fovMode = BABYLON.Camera.FOVMODE_VERTICAL_FIXED;
  wingCamera.fov = 1.2; // Wider for dramatic wing view (reduced from 1.9)

  // Store direct references to each camera in the canonical index order
  // used by the input handlers in 3.1_🕹_joystick_gamepad.js:
  //   0 = orbital, 1 = cockpit, 2 = chase, 3 = wing
  // setActiveCamera() below looks up the target camera in this map so the
  // actual order of scene.cameras (which depends on Babylon's auto-add
  // behaviour) never matters.
  scene._canonicalCameras = [
    arcRotateCamera,  // 0 — orbital
    cockpitCamera,    // 1 — cockpit (first-person)
    followCamera,     // 2 — chase   (follow)
    wingCamera,       // 3 — wing    (external wing)
  ];

  // Guarantee that every camera is registered in scene.cameras even if
  // Babylon's constructor auto-add ever changes or is skipped. Duplicates
  // are harmless because the input handlers go through the direct-ref map
  // above — they never index scene.cameras.
  for (const cam of scene._canonicalCameras) {
    if (!scene.cameras.includes(cam)) {
      scene.cameras.push(cam);
    }
  }

  /**
   * Defaults for the cockpit and wing cameras — the fallback used
   * whenever the current aircraft's `render_settings.yaml` doesn't
   * specify a `camera_positions` block (or that file doesn't exist).
   * Euler angles are in degrees; internally we convert to radians and
   * hand them to BABYLON.Quaternion.FromEulerAngles, which applies
   * rotations in (X, Y, Z) order. With the camera parented to the
   * aircraft body (x-forward, y-up, z-right), yaw = rotation around
   * Y-axis and aligns the camera's default +Z look direction with
   * aircraft +X when yaw_deg = 90.
   *
   * `render_aircraft` / `render_propeller` default per camera:
   *   - cockpit: hide aircraft body (first-person view), show propeller
   *              in front of the pilot.
   *   - wing / orbital / chase: show both.
   * Any of these can be overridden per aircraft in render_settings.yaml:
   *
   *     camera_positions:
   *       cockpit: { ..., render_aircraft: false, render_propeller: true }
   *       wing:    { ..., render_aircraft: true,  render_propeller: true }
   */
  const DEFAULT_COCKPIT_CAMERA = {
    x: 0.5, y: 1.0, z: 0.0,
    yaw_deg: 90, pitch_deg: 0, roll_deg: 0,
    render_aircraft: false,
    render_propeller: true,
  };
  const DEFAULT_WING_CAMERA = {
    x: -1.5, y: 0.5, z: -3.2,
    yaw_deg: -5.7, pitch_deg: 0, roll_deg: 0,
    render_aircraft: true,
    render_propeller: true,
  };
  const DEFAULT_ORBITAL_CAMERA = { render_aircraft: true, render_propeller: true };
  const DEFAULT_CHASE_CAMERA = {
    frame: "trajectory",
    distance_m: 18.0,
    height_m: 5.0,
    lateral_m: 0.0,
    target_distance_m: 3.0,
    target_height_m: 0.9,
    target_lateral_m: 0.0,
    x: -18.0, y: 5.0, z: 0.0,
    target_x: 3.0, target_y: 0.9, target_z: 0.0,
    lag_time_s: 0.65,
    target_lag_time_s: 0.22,
    frame_lag_time_s: 0.55,
    yaw_deg: 90, pitch_deg: 0, roll_deg: 0,
    render_aircraft: true,
    render_propeller: true,
  };

  // Canonical name for each slot in scene._canonicalCameras. Used to
  // look up the matching `camera_positions.<key>` block in the yaml.
  const CANONICAL_CAMERA_KEYS = ['orbital', 'cockpit', 'chase', 'wing'];

  function _cameraConfig(key, fallback) {
    const rs = (typeof window !== 'undefined' && window.aircraftRenderSettings) || null;
    const override = rs && rs.camera_positions && rs.camera_positions[key];
    if (!override || typeof override !== 'object') return fallback;
    const pickNumber = (k) => (typeof override[k] === 'number') ? override[k] : fallback[k];
    const pickBool   = (k) => (typeof override[k] === 'boolean') ? override[k] : fallback[k];
    return {
      x: pickNumber('x'),
      y: pickNumber('y'),
      z: pickNumber('z'),
      yaw_deg:         pickNumber('yaw_deg'),
      pitch_deg:       pickNumber('pitch_deg'),
      roll_deg:        pickNumber('roll_deg'),
      render_aircraft:  pickBool('render_aircraft'),
      render_propeller: pickBool('render_propeller'),
    };
  }

  function _chaseCameraConfig() {
    const rs = (typeof window !== 'undefined' && window.aircraftRenderSettings) || null;
    const override = rs && rs.camera_positions && rs.camera_positions.chase;
    if (!override || typeof override !== 'object') return DEFAULT_CHASE_CAMERA;
    const pickNumber = (k) => (typeof override[k] === 'number') ? override[k] : DEFAULT_CHASE_CAMERA[k];
    const pickBool = (k) => (typeof override[k] === 'boolean') ? override[k] : DEFAULT_CHASE_CAMERA[k];
    const pickString = (k) => (typeof override[k] === 'string') ? override[k] : DEFAULT_CHASE_CAMERA[k];
    const hasNumber = (k) => (typeof override[k] === 'number');
    const distance = pickNumber('distance_m');
    const height = pickNumber('height_m');
    const lateral = pickNumber('lateral_m');
    const targetDistance = pickNumber('target_distance_m');
    const targetHeight = pickNumber('target_height_m');
    const targetLateral = pickNumber('target_lateral_m');
    return {
      frame: pickString('frame'),
      distance_m: distance,
      height_m: height,
      lateral_m: lateral,
      target_distance_m: targetDistance,
      target_height_m: targetHeight,
      target_lateral_m: targetLateral,
      x: hasNumber('x') ? override.x : -Math.abs(distance),
      y: hasNumber('y') ? override.y : height,
      z: hasNumber('z') ? override.z : lateral,
      target_x: hasNumber('target_x') ? override.target_x : targetDistance,
      target_y: hasNumber('target_y') ? override.target_y : targetHeight,
      target_z: hasNumber('target_z') ? override.target_z : targetLateral,
      lag_time_s: pickNumber('lag_time_s'),
      target_lag_time_s: pickNumber('target_lag_time_s'),
      frame_lag_time_s: pickNumber('frame_lag_time_s'),
      yaw_deg: pickNumber('yaw_deg'),
      pitch_deg: pickNumber('pitch_deg'),
      roll_deg: pickNumber('roll_deg'),
      render_aircraft: pickBool('render_aircraft'),
      render_propeller: pickBool('render_propeller'),
    };
  }

  function _applyCameraConfig(camera, cfg) {
    camera.position.set(cfg.x, cfg.y, cfg.z);
    camera.rotationQuaternion = BABYLON.Quaternion.FromEulerAngles(
      cfg.pitch_deg * Math.PI / 180,
      cfg.yaw_deg   * Math.PI / 180,
      cfg.roll_deg  * Math.PI / 180
    );
  }

  /**
   * Resolve the canonical key ('orbital' | 'cockpit' | 'chase' | 'wing')
   * of whichever camera is currently active in the scene. Used by the
   * per-camera visibility logic to pick which yaml block drives the
   * `render_aircraft` / `render_propeller` decision on this frame.
   */
  function _getActiveCameraKey() {
    if (!scene || !scene._canonicalCameras) return null;
    const idx = scene._canonicalCameras.indexOf(scene.activeCamera);
    if (idx < 0) return null;
    return CANONICAL_CAMERA_KEYS[idx] || null;
  }

  /**
   * Apply the `render_aircraft` / `render_propeller` flags for the
   * currently-active camera. Called on every camera switch AND when
   * render_settings arrive on the WebSocket, so any yaml edit picks up
   * on the next restart without having to re-cycle cameras.
   *
   * - `render_aircraft` controls the aircraft body mesh (the GLB if one
   *   is loaded, or the parametric planeNode otherwise).
   * - `render_propeller` controls the propellerPivot. The yaml's
   *   propeller section (or its absence) still decides whether a
   *   propeller EXISTS at all — this camera flag can only hide it.
   */
  function _applyVisibilityForActiveCamera() {
    const key = _getActiveCameraKey();
    if (!key) return;
    const fallback =
      key === 'cockpit' ? DEFAULT_COCKPIT_CAMERA :
      key === 'wing'    ? DEFAULT_WING_CAMERA    :
      key === 'orbital' ? DEFAULT_ORBITAL_CAMERA :
      key === 'chase'   ? DEFAULT_CHASE_CAMERA   : null;
    if (!fallback) return;
    const cfg = _cameraConfig(key, fallback);

    // --- Aircraft body ---
    const hasGLB = (typeof glbNode !== 'undefined' && !!glbNode);
    if (hasGLB) {
      glbNode.setEnabled(!!cfg.render_aircraft);
    }
    if (typeof planeNode !== 'undefined' && planeNode) {
      // When a GLB is loaded, planeNode is the parametric fallback and
      // stays disabled regardless. Without a GLB, planeNode is the
      // aircraft body so camera visibility applies to it.
      planeNode.setEnabled(hasGLB ? false : !!cfg.render_aircraft);
    }

    // --- Propeller ---
    // Combine the camera's render_propeller flag with whether the yaml
    // actually has a `propeller:` section. No yaml section ⇒ nothing to
    // render (the helper in 4.3 already disabled the pivot), so the
    // camera flag can't force-enable it.
    const yamlHasProp = !!(typeof window !== 'undefined' && window.aircraftHasPropellerInYaml);
    const propellerPivot = scene.getTransformNodeByName("propellerPivot");
    if (propellerPivot) {
      propellerPivot.setEnabled(yamlHasProp && !!cfg.render_propeller);
    }
  }

  /**
   * Updates camera positions and targets based on the aircraft's position.
   * Idempotent — safe to call again when render_settings arrive on the
   * WebSocket after the cameras were first placed against defaults.
   */
  function updateCamerasForAircraft(aircraft) {
    if (!aircraft) return;

    arcRotateCamera.lockedTarget = aircraft;
    followCamera.parent = null;

    // Cockpit (first-person)
    cockpitCamera.parent = aircraft;
    _applyCameraConfig(cockpitCamera, _cameraConfig('cockpit', DEFAULT_COCKPIT_CAMERA));

    // Wing (chase-from-the-wing)
    wingCamera.parent = aircraft;
    _applyCameraConfig(wingCamera, _cameraConfig('wing', DEFAULT_WING_CAMERA));

    // Re-apply the aircraft/propeller visibility flags against the new
    // yaml values (may have just arrived over the WebSocket).
    _applyVisibilityForActiveCamera();
  }

  const _chaseLocalPosition = new BABYLON.Vector3();
  const _chaseLocalTarget = new BABYLON.Vector3();
  const _chaseWorldPosition = new BABYLON.Vector3();
  const _chaseWorldTarget = new BABYLON.Vector3();
  const _chaseSmoothedPosition = new BABYLON.Vector3();
  const _chaseSmoothedTarget = new BABYLON.Vector3();
  const _chaseWorldUp = new BABYLON.Vector3(0, 1, 0);
  const _chaseForwardLocal = new BABYLON.Vector3(1, 0, 0);
  const _chaseRightLocal = new BABYLON.Vector3(0, 0, 1);
  const _chaseFrameForward = new BABYLON.Vector3(1, 0, 0);
  const _chaseFrameRight = new BABYLON.Vector3(0, 0, 1);
  const _chaseCandidateForward = new BABYLON.Vector3(1, 0, 0);
  const _chaseTmp = new BABYLON.Vector3();
  const _chaseForwardRay = new BABYLON.Ray(BABYLON.Vector3.Zero(), new BABYLON.Vector3(0, 0, 1));
  let _chaseCameraInitialized = false;
  let _chaseFrameInitialized = false;

  function _chaseLagAlpha(dtMs, timeConstantS) {
    if (!Number.isFinite(timeConstantS) || timeConstantS <= 0.0001) return 1.0;
    const boundedDtS = Math.min(Math.max((dtMs || 16.667) / 1000.0, 0.0), 0.25);
    return 1.0 - Math.exp(-boundedDtS / timeConstantS);
  }

  function _crossToRef(a, b, out) {
    const x = a.y * b.z - a.z * b.y;
    const y = a.z * b.x - a.x * b.z;
    const z = a.x * b.y - a.y * b.x;
    out.set(x, y, z);
  }

  function _normalizeOrFallbackToRef(v, fallback, out) {
    const len = Math.hypot(v.x, v.y, v.z);
    if (!Number.isFinite(len) || len < 1e-6) {
      out.copyFrom(fallback);
      return false;
    }
    out.set(v.x / len, v.y / len, v.z / len);
    return true;
  }

  function _aircraftBodyForwardToRef(aircraftWorld, out) {
    BABYLON.Vector3.TransformNormalToRef(_chaseForwardLocal, aircraftWorld, out);
    _normalizeOrFallbackToRef(out, _chaseFrameForward, out);
  }

  function _aircraftBodyRightToRef(aircraftWorld, out) {
    BABYLON.Vector3.TransformNormalToRef(_chaseRightLocal, aircraftWorld, out);
    _normalizeOrFallbackToRef(out, _chaseFrameRight, out);
  }

  function _trajectoryForwardToRef(aircraftWorld, out) {
    if (typeof velocity !== 'undefined' && velocity) {
      const vx = Number(velocity.x);
      const vy = Number(velocity.y);
      const vz = Number(velocity.z);
      const speed = Math.hypot(vx, vy, vz);
      if (Number.isFinite(speed) && speed > 0.5) {
        out.set(vx / speed, vy / speed, vz / speed);
        return;
      }
    }
    _aircraftBodyForwardToRef(aircraftWorld, out);
  }

  function _placeFromChaseFrame(origin, x, y, z, out) {
    out.copyFrom(origin);
    _chaseFrameForward.scaleToRef(x, _chaseTmp);
    out.addInPlace(_chaseTmp);
    _chaseWorldUp.scaleToRef(y, _chaseTmp);
    out.addInPlace(_chaseTmp);
    _chaseFrameRight.scaleToRef(z, _chaseTmp);
    out.addInPlace(_chaseTmp);
  }

  function _updateTrajectoryChaseFrame(aircraftWorld, cfg, dtMs) {
    _trajectoryForwardToRef(aircraftWorld, _chaseCandidateForward);

    if (!_chaseFrameInitialized) {
      _chaseFrameForward.copyFrom(_chaseCandidateForward);
      _chaseFrameInitialized = true;
    } else {
      const frameAlpha = _chaseLagAlpha(dtMs, cfg.frame_lag_time_s);
      BABYLON.Vector3.LerpToRef(
        _chaseFrameForward,
        _chaseCandidateForward,
        frameAlpha,
        _chaseFrameForward
      );
      _normalizeOrFallbackToRef(_chaseFrameForward, _chaseCandidateForward, _chaseFrameForward);
    }

    _crossToRef(_chaseFrameForward, _chaseWorldUp, _chaseFrameRight);
    if (!_normalizeOrFallbackToRef(_chaseFrameRight, _chaseRightLocal, _chaseFrameRight)) {
      _aircraftBodyRightToRef(aircraftWorld, _chaseFrameRight);
    }
  }

  function updateFollowCameraForAircraft(dtMs) {
    if (!aircraft || !aircraft.getWorldMatrix) return;
    const cfg = _chaseCameraConfig();
    _chaseLocalPosition.set(cfg.x, cfg.y, cfg.z);
    _chaseLocalTarget.set(cfg.target_x, cfg.target_y, cfg.target_z);

    aircraft.computeWorldMatrix(true);
    const aircraftWorld = aircraft.getWorldMatrix();
    if (String(cfg.frame || "").toLowerCase() === "body") {
      BABYLON.Vector3.TransformCoordinatesToRef(_chaseLocalPosition, aircraftWorld, _chaseWorldPosition);
      BABYLON.Vector3.TransformCoordinatesToRef(_chaseLocalTarget, aircraftWorld, _chaseWorldTarget);
    } else {
      _updateTrajectoryChaseFrame(aircraftWorld, cfg, dtMs);
      _placeFromChaseFrame(aircraft.position, cfg.x, cfg.y, cfg.z, _chaseWorldPosition);
      _placeFromChaseFrame(aircraft.position, cfg.target_x, cfg.target_y, cfg.target_z, _chaseWorldTarget);
    }

    if (!_chaseCameraInitialized) {
      followCamera.computeWorldMatrix(true);
      _chaseSmoothedPosition.copyFrom(followCamera.globalPosition || followCamera.position);
      const ray = followCamera.getForwardRay ? followCamera.getForwardRay(100.0) : null;
      if (ray && ray.direction) {
        _chaseForwardRay.origin.copyFrom(_chaseSmoothedPosition);
        _chaseForwardRay.direction.copyFrom(ray.direction);
        _chaseForwardRay.direction.normalize();
        _chaseSmoothedTarget.copyFrom(_chaseSmoothedPosition);
        _chaseForwardRay.direction.scaleToRef(100.0, _chaseTmp);
        _chaseSmoothedTarget.addInPlace(_chaseTmp);
      } else {
        _chaseSmoothedTarget.copyFrom(_chaseWorldTarget);
      }
      _chaseCameraInitialized = true;
    }

    const posAlpha = _chaseLagAlpha(dtMs, cfg.lag_time_s);
    const targetAlpha = _chaseLagAlpha(dtMs, cfg.target_lag_time_s);
    BABYLON.Vector3.LerpToRef(_chaseSmoothedPosition, _chaseWorldPosition, posAlpha, _chaseSmoothedPosition);
    BABYLON.Vector3.LerpToRef(_chaseSmoothedTarget, _chaseWorldTarget, targetAlpha, _chaseSmoothedTarget);

    followCamera.position.copyFrom(_chaseSmoothedPosition);
    followCamera.setTarget(_chaseSmoothedTarget);
  }

  // Expose the visibility helper so 4.3_🔼... can call it after applying
  // render_settings — that way editing render_aircraft / render_propeller
  // in the yaml and pressing respawn takes effect immediately without
  // requiring the user to cycle cameras.
  scene.applyPerCameraAircraftVisibility = _applyVisibilityForActiveCamera;

  if (typeof aircraft !== "undefined" && aircraft) {
    updateCamerasForAircraft(aircraft);
  }

  // **CRITICAL FIX**: Remove the onBeforeRenderObservable that was forcing upVector every frame
  // This was causing the aspect ratio distortion during rolls
  // The upVector should only be set once during initialization

  scene.updateCamerasForAircraft = updateCamerasForAircraft;
  scene.updateFollowCameraForAircraft = updateFollowCameraForAircraft;

  return {
    arcRotateCamera,
    followCamera,
    cockpitCamera,
    wingCamera
  };
}

/**
 * Switches the active camera in the scene using the canonical index:
 *   0 → orbital (arcRotate)
 *   1 → cockpit (first-person)
 *   2 → chase   (follow)
 *   3 → wing    (external wing view)
 * The resolution is done via scene._canonicalCameras, which is populated
 * by setupCameras() with direct references — no name lookup, no
 * scene.cameras indexing, so the ordering of scene.cameras is irrelevant.
 */
function setActiveCamera(index, scene) {
  const cameras = scene && scene._canonicalCameras;
  if (!cameras) {
    console.warn("setActiveCamera: scene._canonicalCameras missing — did setupCameras() run?");
    return;
  }
  if (index < 0 || index >= cameras.length) {
    console.warn("Invalid camera index:", index);
    return;
  }
  const camera = cameras[index];
  if (!camera) {
    console.warn("No camera registered at canonical index", index);
    return;
  }
  console.log("[setActiveCamera] idx=", index, "name=", camera.name, "parent=", camera.parent && camera.parent.name, "pos=", camera.position && camera.position.asArray());
  scene.activeCamera = camera;

  // Visibility of the aircraft body and the propeller from this camera
  // comes from the yaml's `camera_positions.<name>.render_aircraft` /
  // `render_propeller` flags (see 6.4 DEFAULT_*_CAMERA tables for the
  // fallback per camera — notably cockpit defaults to
  // render_aircraft=false so the pilot sees out of the cockpit instead
  // of through the fuselage).
  if (typeof scene.applyPerCameraAircraftVisibility === 'function') {
    scene.applyPerCameraAircraftVisibility();
  }
}
