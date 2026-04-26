/***************************************************************
 * 6.1_♻_MAIN_render_loop.js
 *
 * Keeps a single global `engine` and `scene` so helper scripts
 * ("draw_forces_and_velocities.js" etc.) see the same object,
 * updates the debug visualizations each frame, and sends pilot
 * inputs to the Julia physics server.
 *
 * IMPORTANT:
 * The browser never feeds its visual aircraft transform back into the
 * solver. Julia remains the single source of truth for the physics
 * state; browser-side prediction below is visual-only and exists only
 * to draw continuous motion between authoritative server samples.
 ***************************************************************/

// Wait for the DOM content to be fully loaded before initializing Babylon
window.addEventListener("DOMContentLoaded", () => {
    /*------------------------------------------------------------
     * ENGINE + SCENE (use the globals declared in initialisations)
     *-----------------------------------------------------------*/
    const canvas = document.getElementById("renderCanvas");

    // Ensure canvas exists
    if (!canvas) {
        console.error("renderCanvas not found in the DOM!");
        return;
    }

    // Initialize the Babylon engine (assigns to global 'engine')
    engine = new BABYLON.Engine(canvas, true, {
        preserveDrawingBuffer: false,
        stencil: true,
        limitDeviceRatio: 1.0 // Optional: Limit device pixel ratio for performance
    });
    window.engine = engine; // Expose engine globally if needed elsewhere

    // Create the Babylon scene (assigns to global 'scene' via createScene function)
    // createScene itself should assign to window.scene
    scene = createScene(engine, canvas);

    // Verify scene creation
    if (!scene) {
        console.error("Scene creation failed!");
        return;
    }
    // Ensure window.scene is set if createScene doesn't do it reliably
    if (!window.scene) {
        window.scene = scene;
    }

    /*------------------------------------------------------------
     * POSE SMOOTHING
     *
     * The Julia physics server replies at a variable rate dictated by
     * WebSocket round-trip time + RK4 compute time (~30-50 Hz), while
     * the browser renders at vSync (60-120 Hz). If we wrote server-
     * reported x/y/z/qxyzw straight into aircraft.position and
     * aircraft.rotationQuaternion, the mesh would teleport on reply
     * frames and freeze on all frames in between — perceived as
     * jerky motion even when the physics itself is perfectly smooth.
     *
     * Instead, 1.1_..._exchange_aircraft_state_with_server.js stores
     * the latest authoritative pose in window.authoritativePosition and
     * also appends received poses to window.authoritativePoseBuffer.
     * Each render frame samples that buffer at a small fixed delay. The
     * authoritative values are what gets echoed back to the server —
     * the smoothing affects ONLY the visual transform.
     *
     * The current implementation below uses buffered interpolation first.
     * The fallback exponential half-life is only used before that buffer is
     * populated or if an old client does not provide it.
     *-----------------------------------------------------------*/
    // Current visual smoothing uses buffered interpolation/extrapolation first;
    // the fallback half-life is only used for startup or missing buffers.
    const VISUAL_POSE_DEFAULT_BUFFER_DELAY_MS = 50;
    const VISUAL_POSE_CHASE_BUFFER_DELAY_MS = 120;
    const VISUAL_POSE_MAX_EXTRAPOLATION_MS = 180;
    const VISUAL_POSE_CHASE_CORRECTION_HALFLIFE_MS = 260;
    const VISUAL_POSE_CHASE_MAX_RENDER_DT_MS = 100;
    const VISUAL_POSE_CHASE_RESET_DISTANCE_M = 120;
    const VISUAL_POSE_RENDER_HALFLIFE_MS = 28;
    const POSE_SMOOTH_HALFLIFE_MS = 70;
    const _smoothingTargetPosition = new BABYLON.Vector3(0, 0, 0);
    const _smoothingTargetQuaternion = new BABYLON.Quaternion(0, 0, 0, 1);
    const _poseBufferQuatA = new BABYLON.Quaternion(0, 0, 0, 1);
    const _poseBufferQuatB = new BABYLON.Quaternion(0, 0, 0, 1);
    const _chaseVisualPosition = new BABYLON.Vector3(0, 0, 0);
    let _smoothingTargetStalenessMs = 0;
    let _chaseVisualPositionInitialized = false;
    let _chaseVisualPoseResetTokenSeen = null;

    function _finiteVelocityVectorOrNull() {
        const candidate = window.authoritativeVelocity ||
            ((typeof velocity !== 'undefined') ? velocity : null);
        if (!candidate ||
            !Number.isFinite(candidate.x) ||
            !Number.isFinite(candidate.y) ||
            !Number.isFinite(candidate.z)) {
            return null;
        }
        return candidate;
    }

    function _slerpVisualAircraftAttitude(alpha) {
        if (aircraft.rotationQuaternion && typeof orientation !== 'undefined') {
            BABYLON.Quaternion.SlerpToRef(
                aircraft.rotationQuaternion,
                _smoothingTargetQuaternion,
                alpha,
                aircraft.rotationQuaternion
            );
            aircraft.rotationQuaternion.normalize();
        }
    }

    function _advanceChaseVisualPosition(dtMs) {
        const resetToken = window.authoritativePoseResetToken || 0;
        if (!_chaseVisualPositionInitialized ||
            _chaseVisualPoseResetTokenSeen !== resetToken) {
            _chaseVisualPosition.copyFrom(aircraft.position);
            _chaseVisualPositionInitialized = true;
            _chaseVisualPoseResetTokenSeen = resetToken;
        }

        const dx = _smoothingTargetPosition.x - _chaseVisualPosition.x;
        const dy = _smoothingTargetPosition.y - _chaseVisualPosition.y;
        const dz = _smoothingTargetPosition.z - _chaseVisualPosition.z;
        const targetIsStale =
            _smoothingTargetStalenessMs > VISUAL_POSE_MAX_EXTRAPOLATION_MS;
        const resetDistanceSq =
            VISUAL_POSE_CHASE_RESET_DISTANCE_M * VISUAL_POSE_CHASE_RESET_DISTANCE_M;
        if (!targetIsStale && dx * dx + dy * dy + dz * dz > resetDistanceSq) {
            _chaseVisualPosition.copyFrom(_smoothingTargetPosition);
            aircraft.position.copyFrom(_chaseVisualPosition);
            return;
        }

        const boundedDtMs = Math.min(
            Math.max(Number.isFinite(dtMs) ? dtMs : 0, 0),
            VISUAL_POSE_CHASE_MAX_RENDER_DT_MS
        );
        const dtS = boundedDtMs * 0.001;
        const velocityVector = _finiteVelocityVectorOrNull();
        if (velocityVector && dtS > 0) {
            _chaseVisualPosition.x += velocityVector.x * dtS;
            _chaseVisualPosition.y += velocityVector.y * dtS;
            _chaseVisualPosition.z += velocityVector.z * dtS;
        }

        if (!targetIsStale) {
            const correctionAlpha = 1.0 - Math.pow(
                0.5,
                boundedDtMs / VISUAL_POSE_CHASE_CORRECTION_HALFLIFE_MS
            );
            _chaseVisualPosition.x += (_smoothingTargetPosition.x - _chaseVisualPosition.x) * correctionAlpha;
            _chaseVisualPosition.y += (_smoothingTargetPosition.y - _chaseVisualPosition.y) * correctionAlpha;
            _chaseVisualPosition.z += (_smoothingTargetPosition.z - _chaseVisualPosition.z) * correctionAlpha;
        }
        aircraft.position.copyFrom(_chaseVisualPosition);
    }

    function _sampleBufferedAuthoritativePose(nowMs, bufferDelayMs) {
        const buffer = window.authoritativePoseBuffer;
        if (!Array.isArray(buffer) || buffer.length === 0) {
            return false;
        }

        if (typeof isPaused !== 'undefined' && isPaused) {
            const latest = buffer[buffer.length - 1];
            if (buffer.length > 1) {
                window.authoritativePoseBuffer = [latest];
            }
            _smoothingTargetStalenessMs = 0;
            _smoothingTargetPosition.set(latest.x, latest.y, latest.z);
            _smoothingTargetQuaternion.set(latest.qx, latest.qy, latest.qz, latest.qw);
            return true;
        }

        const renderTimeMs = nowMs - bufferDelayMs;
        while (buffer.length > 2 && buffer[1].clientTimeMs <= renderTimeMs) {
            buffer.shift();
        }

        const a = buffer[0];
        const b = buffer.length > 1 ? buffer[1] : null;
        if (!b || b.clientTimeMs <= a.clientTimeMs) {
            _smoothingTargetStalenessMs = Math.max(renderTimeMs - a.clientTimeMs, 0.0);
            _smoothingTargetPosition.set(a.x, a.y, a.z);
            _smoothingTargetQuaternion.set(a.qx, a.qy, a.qz, a.qw);
            return true;
        }

        const spanMs = b.clientTimeMs - a.clientTimeMs;
        const rawT = (renderTimeMs - a.clientTimeMs) / spanMs;
        const hasVelocitySample = Number.isFinite(b.vx) && Number.isFinite(b.vy) && Number.isFinite(b.vz);
        if (rawT > 1.0 && hasVelocitySample) {
            _smoothingTargetStalenessMs = Math.max(renderTimeMs - b.clientTimeMs, 0.0);
            const extrapolationS = Math.min(
                _smoothingTargetStalenessMs,
                VISUAL_POSE_MAX_EXTRAPOLATION_MS
            ) * 0.001;
            _smoothingTargetPosition.set(
                b.x + b.vx * extrapolationS,
                b.y + b.vy * extrapolationS,
                b.z + b.vz * extrapolationS
            );
        } else {
            _smoothingTargetStalenessMs = rawT > 1.0
                ? Math.max(renderTimeMs - b.clientTimeMs, 0.0)
                : 0;
            const maxPositionT = 1.0 + VISUAL_POSE_MAX_EXTRAPOLATION_MS / spanMs;
            const positionT = Math.min(Math.max(rawT, 0.0), maxPositionT);
            _smoothingTargetPosition.set(
                a.x + (b.x - a.x) * positionT,
                a.y + (b.y - a.y) * positionT,
                a.z + (b.z - a.z) * positionT
            );
        }
        const attitudeT = Math.min(Math.max(rawT, 0.0), 1.0);
        _poseBufferQuatA.set(a.qx, a.qy, a.qz, a.qw);
        _poseBufferQuatB.set(b.qx, b.qy, b.qz, b.qw);
        BABYLON.Quaternion.SlerpToRef(
            _poseBufferQuatA,
            _poseBufferQuatB,
            attitudeT,
            _smoothingTargetQuaternion
        );
        return true;
    }

    function _smoothAircraftPoseTowardAuthoritative(dtMs) {
        if (!aircraft || !window.authoritativePosition || !window.initialDataReceived) {
            return;
        }

        const activeCameraName = scene && scene.activeCamera ? scene.activeCamera.name : "";
        const bufferDelayMs = activeCameraName === "FollowCamera"
            ? VISUAL_POSE_CHASE_BUFFER_DELAY_MS
            : VISUAL_POSE_DEFAULT_BUFFER_DELAY_MS;
        const hasBufferedPose = _sampleBufferedAuthoritativePose(performance.now(), bufferDelayMs);
        if (!hasBufferedPose) {
            _smoothingTargetPosition.set(
                window.authoritativePosition.x,
                window.authoritativePosition.y,
                window.authoritativePosition.z
            );
            _smoothingTargetQuaternion.set(
                orientation.x,
                orientation.y,
                orientation.z,
                orientation.w
            );
        }

        if (activeCameraName === "FollowCamera" && hasBufferedPose &&
            !(typeof isPaused !== 'undefined' && isPaused)) {
            _advanceChaseVisualPosition(dtMs);
            const attitudeAlpha = 1.0 - Math.pow(
                0.5,
                dtMs / VISUAL_POSE_RENDER_HALFLIFE_MS
            );
            _slerpVisualAircraftAttitude(attitudeAlpha);
            return;
        }

        if (activeCameraName !== "FollowCamera" ||
            (typeof isPaused !== 'undefined' && isPaused)) {
            _chaseVisualPositionInitialized = false;
        }

        const alpha = 1.0 - Math.pow(
            0.5,
            dtMs / (hasBufferedPose ? VISUAL_POSE_RENDER_HALFLIFE_MS : POSE_SMOOTH_HALFLIFE_MS)
        );
        aircraft.position.x += (_smoothingTargetPosition.x - aircraft.position.x) * alpha;
        aircraft.position.y += (_smoothingTargetPosition.y - aircraft.position.y) * alpha;
        aircraft.position.z += (_smoothingTargetPosition.z - aircraft.position.z) * alpha;
        _slerpVisualAircraftAttitude(alpha);
    }

    /*------------------------------------------------------------
     * STARTUP / PAUSE OVERLAY STATE MACHINE
     *
     * The #glbLoadingOverlay div is baked into the HTML body so the
     * user sees "Loading…" the instant the page parses — before Babylon,
     * the scene, or the WebSocket handshake have a chance to run.
     *
     * Four visible states, driven by this function once per frame:
     *   1. LOADING — !window.initialDataReceived OR window.isGlbLoading
     *        Text is whatever the GLB loader / initial HTML set it to
     *        ("Loading…" or "Loading aircraft model (…)"). We don't
     *        touch it here so the more specific GLB progress label wins.
     *   2. READY TO START — loaded AND paused AND never run yet
     *        Text becomes "Simulation ready, press space to start".
     *        window.simReadyToPlay latches true so the keyboard/gamepad
     *        handlers in 3.1_... are allowed to un-pause.
     *   3. PAUSED AFTER STARTED — loaded AND paused AND has run before
     *        Text becomes "Paused, press space to continue".
     *        Re-appears every time the pilot pauses mid-flight; vanishes
     *        again on un-pause. This is why the "startup" latch that
     *        used to hide the overlay for good was removed — the pause
     *        prompt needs to re-show on every pause.
     *   4. HIDDEN — sim is running (!isPaused)
     *        display:none; pilot is flying.
     *-----------------------------------------------------------*/
    window.simReadyToPlay = false;

    function _updatePauseOrLoadingOverlay() {
        const overlay = document.getElementById('glbLoadingOverlay');
        if (!overlay) return;

        const loaded = window.initialDataReceived && !window.isGlbLoading;
        if (!loaded) {
            // Still loading — restore the opaque background and the
            // column layout in case we previously transitioned to the
            // transparent paused state. Do NOT wipe innerHTML: the
            // bootstrap script in front_end_and_client.html populated
            // a title element + a mission-info <pre> that we want to
            // keep visible while the aircraft and aero database stream
            // in. The title's text is updated by the GLB loader
            // (4.3_…) via its #glbLoadingTitle selector.
            if (overlay.dataset.mode !== 'loading') {
                overlay.dataset.mode = 'loading';
                overlay.style.background = 'rgba(0,0,0,0.78)';
                overlay.style.alignItems = 'center';
                overlay.style.justifyContent = 'center';
                overlay.style.flexDirection = 'column';
                const infoEl = overlay.querySelector('#glbLoadingMissionInfo');
                if (infoEl) infoEl.style.display = '';
            }
            if (overlay.style.display === 'none') overlay.style.display = 'flex';
            return;
        }

        // Once we reach "loaded", latch simReadyToPlay so un-pause is
        // allowed. We never clear this — subsequent pauses don't block
        // un-pause again, they just change the overlay text.
        if (!window.simReadyToPlay) {
            window.simReadyToPlay = true;
            console.log("Simulator ready — press space to begin.");
        }

        const paused = (typeof isPaused !== 'undefined') ? !!isPaused : true;
        if (!paused) {
            // Flying — hide the overlay. Cheap to set display repeatedly.
            if (overlay.style.display !== 'none') overlay.style.display = 'none';
            return;
        }

        // Paused while loaded. The pilot needs to keep seeing the world,
        // so we drop the opaque gray and show the prompt as a compact
        // pill at the top of the screen instead of greying everything out.
        const hasStarted = (typeof hasStartedOnce !== 'undefined') ? !!hasStartedOnce : false;
        const message = hasStarted
            ? 'Paused, press space to continue'
            : 'Simulation ready, press space to start';

        if (overlay.dataset.mode !== 'paused') {
            overlay.dataset.mode = 'paused';
            overlay.style.background = 'transparent';
            overlay.style.alignItems = 'flex-start';
            overlay.style.justifyContent = 'flex-start';
            // Hide the loading-time title and mission-info pre — they
            // are no longer relevant once the sim is loaded — and inject
            // (or reuse) a single compact "paused" pill so the world
            // remains fully visible behind it.
            const titleEl = overlay.querySelector('#glbLoadingTitle');
            if (titleEl) titleEl.style.display = 'none';
            const infoEl = overlay.querySelector('#glbLoadingMissionInfo');
            if (infoEl) infoEl.style.display = 'none';
            if (!overlay.querySelector('#pausedPrompt')) {
                const pillDiv = document.createElement('div');
                pillDiv.id = 'pausedPrompt';
                pillDiv.style.cssText = 'margin-top:24px;background:rgba(0,0,0,0.55);'
                    + 'padding:8px 20px;border-radius:8px;font-weight:bold;'
                    + 'letter-spacing:0.5px;align-self:center;';
                overlay.appendChild(pillDiv);
            }
        }
        const pill = overlay.querySelector('#pausedPrompt');
        if (pill && pill.textContent !== message) pill.textContent = message;
        if (overlay.style.display === 'none') overlay.style.display = 'flex';
    }
    // Backwards-compat alias — an earlier name for this function; kept
    // in case anything else ever called it by the old name.
    const _maybeHideStartupLoadingOverlay = _updatePauseOrLoadingOverlay;

    /*------------------------------------------------------------
     * MAIN RENDER LOOP
     *-----------------------------------------------------------*/
    engine.runRenderLoop(() => {
        const dtMs = engine.getDeltaTime();
        // Hide the page-level "Loading…" overlay as soon as the sim is
        // ready to be unpaused. Cheap check; safe to run every frame.
        _maybeHideStartupLoadingOverlay();

        // Smooth the visual aircraft pose toward the authoritative server
        // pose BEFORE anything else in this frame reads `aircraft.position`
        // or `aircraft.rotationQuaternion`.
        //
        // Order matters: updateVelocityLine / updateForceLine / updateTrajectory
        // all read the aircraft transform (directly or via localPointToWorld
        // which calls aircraft.getWorldMatrix()). If pose smoothing ran AFTER
        // them, the attached visuals would be computed against last frame's
        // pose while scene.render() drew the aircraft at this frame's pose —
        // a one-frame mismatch that shows up as all force arrows trembling
        // at render rate as the aircraft rotates.
        _smoothAircraftPoseTowardAuthoritative(dtMs);
        if (scene &&
            scene.activeCamera &&
            scene.activeCamera.name === "FollowCamera" &&
            typeof scene.updateFollowCameraForAircraft === 'function') {
            scene.updateFollowCameraForAircraft(dtMs);
        }

        // Handle gamepad pause/resume controls first
        // Assumes handleGamepadPauseControls uses global 'isPaused'
        if (typeof handleGamepadPauseControls === 'function') {
            handleGamepadPauseControls();
        }

        // --- Simulation Logic (only when not paused) ---
        if (!isPaused && !simulationEnded) {
            // Get pilot inputs (keyboard/gamepad)
            // Pass scene if the function requires it (check its definition)
            if (typeof updateForcesFromJoystickOrKeyboard === 'function') {
                updateForcesFromJoystickOrKeyboard(scene);
            }

            // Send the last server-authoritative state back to the server
            // together with the latest pilot inputs. Do not integrate a
            // browser-side predicted pose here.
            // Checks WebSocket connection internally
            if (typeof sendStateToServer === 'function') {
                sendStateToServer();
            }

            // Update trajectory visualization based on server time.
            // Reads aircraft.position to drop each new sphere at the
            // smoothed visual position so the trail matches the visible
            // aircraft, not the authoritative-lagged one.
            const serverTime = window.serverElapsedTime || 0;
            if (typeof updateTrajectory === 'function') {
                updateTrajectory(serverTime);
            }
        }

        // --- Visualization Updates (run even when paused, but depend on data) ---

        // Update vectors continuously; each updater validates data internally.
        const velocityVectorsEnabled = (show_velocity_vectors === "true" || show_velocity_vectors === true);
        const forceVectorsEnabled = (show_force_vectors === "true" || show_force_vectors === true);

        if (typeof updateVelocityLine === 'function') {
            updateVelocityLine(scene); // Pass scene
        }
        if (typeof updateForceLine === 'function') {
            updateForceLine(scene); // Pass scene
        }

        // Update GUI display text if aircraft exists
        // Assumes updateInfo uses global variables like 'aircraft', 'velocity', etc.
        if (aircraft && typeof updateInfo === 'function') {
            updateInfo();
        }

        // Render the scene
        if (scene && scene.isReady()) { // Check if scene is ready
            scene.render();
        }
    });

    /*------------------------------------------------------------
     * WINDOW / GAMEPAD EVENTS
     *-----------------------------------------------------------*/
    // Handle window resize
    window.addEventListener("resize", () => {
        if (engine) {
            engine.resize();
        }
    });

    // Handle gamepad connection/disconnection
    window.addEventListener("gamepadconnected", (e) => {
        // Ensure gamepad property exists
        if (e.gamepad) {
            gamepadIndex = e.gamepad.index;
            console.log(`Gamepad connected (index ${gamepadIndex}, ID: ${e.gamepad.id})`);
        } else {
            console.warn("Gamepad connected event fired without gamepad data.");
        }
    });

    window.addEventListener("gamepaddisconnected", (e) => {
        // Ensure gamepad property exists
        if (e.gamepad) {
            console.log(`Gamepad disconnected (index ${e.gamepad.index}, ID: ${e.gamepad.id})`);
            // Only reset index if the disconnected gamepad is the one we were tracking
            if (gamepadIndex === e.gamepad.index) {
                gamepadIndex = null;
            }
        } else {
            console.warn("Gamepad disconnected event fired without gamepad data.");
        }
    });
});
