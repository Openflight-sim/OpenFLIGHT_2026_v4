let lineDebugMaterialRed = null;
let lineDebugMaterialBlue = null;

let wingLiftArrow = null;
let htailLiftArrow = null;
let vtailLiftArrow = null;
let weightArrow = null;
let freestreamLine = null;
let freestreamLineMaterial = null;
let tailLocalVelocityLineMaterial = null;
let htailLocalVelocityLine = null;
let vtailLocalVelocityLine = null;
let legacyForceLinesDisposed = false;
let forceMeshesReset = false;

function getLineDebugMaterial(color, scene) {
    if (!scene) return null;
    if (color === "red" && !lineDebugMaterialRed) {
        lineDebugMaterialRed = new BABYLON.StandardMaterial("lineDebugMatRed", scene);
        lineDebugMaterialRed.emissiveColor = BABYLON.Color3.Red();
        lineDebugMaterialRed.disableLighting = true;
    } else if (color === "blue" && !lineDebugMaterialBlue) {
        lineDebugMaterialBlue = new BABYLON.StandardMaterial("lineDebugMatBlue", scene);
        lineDebugMaterialBlue.emissiveColor = BABYLON.Color3.Blue();
        lineDebugMaterialBlue.disableLighting = true;
    }
    return color === "red" ? lineDebugMaterialRed : lineDebugMaterialBlue;
}

function createVelocityLine(scene) {
    if (!scene) return null;
    if (scene.getMeshByName("velocityLine")) {
        velocityLine = scene.getMeshByName("velocityLine");
        if (!velocityLine.material) velocityLine.material = getLineDebugMaterial("red", scene);
        return velocityLine;
    }
    velocityLine = BABYLON.MeshBuilder.CreateLines(
        "velocityLine",
        { points: [BABYLON.Vector3.Zero(), new BABYLON.Vector3(1, 0, 0)], updatable: true },
        scene
    );
    velocityLine.material = getLineDebugMaterial("red", scene);
    velocityLine.renderingGroupId = 2;
    velocityLine.isPickable = false;
    velocityLine.alwaysSelectAsActiveMesh = true;
    return velocityLine;
}

function createVectorArrow(name, color3, scene) {
    const shaft = BABYLON.MeshBuilder.CreateCylinder(`${name}_shaft`, {
        height: 1.0,
        diameter: 0.12,
        tessellation: 18
    }, scene);
    const shaftMat = new BABYLON.StandardMaterial(`${name}_shaft_mat`, scene);
    shaftMat.diffuseColor = color3;
    shaftMat.specularColor = new BABYLON.Color3(0.2, 0.2, 0.2);
    shaft.material = shaftMat;
    shaft.renderingGroupId = 2;
    shaft.isPickable = false;
    shaft.alwaysSelectAsActiveMesh = true;

    const head = BABYLON.MeshBuilder.CreateCylinder(`${name}_head`, {
        height: 0.7,
        diameterTop: 0.0,
        diameterBottom: 0.30,
        tessellation: 18
    }, scene);
    const mat = new BABYLON.StandardMaterial(`${name}_mat`, scene);
    mat.diffuseColor = color3;
    mat.specularColor = new BABYLON.Color3(0.2, 0.2, 0.2);
    head.material = mat;
    head.renderingGroupId = 2;
    head.isPickable = false;
    head.alwaysSelectAsActiveMesh = true;

    // Babylon setDirection aligns local +Z to the direction vector.
    // Cylinders are created along local +Y, so rotate geometry to +Z once.
    const alignToZ = BABYLON.Matrix.RotationX(Math.PI / 2);
    shaft.bakeTransformIntoVertices(alignToZ);
    head.bakeTransformIntoVertices(alignToZ);

    return { shaft, head };
}

function updateVectorArrow(arrow, origin, vector, scaleFactor) {
    if (!arrow || !origin || !vector) return;
    let scaled = vector.scale(scaleFactor);
    let len = scaled.length();
    if (!isFinite(len) || len <= 0.0) {
        arrow.shaft.setEnabled(false);
        arrow.head.setEnabled(false);
        return;
    }

    const dir = scaled.normalize();
    const coneLen = len * 0.25;
    const shaftLen = len - coneLen;

    arrow.shaft.setEnabled(true);
    arrow.head.setEnabled(true);
    arrow.shaft.scaling.x = 1.0;
    arrow.shaft.scaling.y = 1.0;
    arrow.shaft.scaling.z = shaftLen;
    arrow.shaft.position = origin.add(dir.scale(shaftLen * 0.5));
    arrow.shaft.setDirection(dir);

    arrow.head.scaling.x = 1.0;
    arrow.head.scaling.y = 1.0;
    arrow.head.scaling.z = coneLen / 0.7;
    // Standard arrow: cone base is at shaft tip.
    arrow.head.position = origin.add(dir.scale(shaftLen + coneLen * 0.5));
    arrow.head.setDirection(dir);
}

function localPointToWorld(localPoint) {
    if (!aircraft || !localPoint) return null;
    aircraft.computeWorldMatrix(true);
    return BABYLON.Vector3.TransformCoordinates(localPoint, aircraft.getWorldMatrix());
}

function isFiniteVector3(v) {
    return !!v && Number.isFinite(v.x) && Number.isFinite(v.y) && Number.isFinite(v.z);
}

function resolveForceOrigin(localOffset, rawOrigin, fallbackLocalOffset) {
    if (isFiniteVector3(localOffset)) {
        return localPointToWorld(localOffset);
    }
    if (isFiniteVector3(rawOrigin)) {
        return rawOrigin.clone();
    }
    return localPointToWorld(fallbackLocalOffset);
}

// Per-frame exponential smoothing of the world-frame force / velocity
// vectors the server ships at ~30 Hz.  Without smoothing, arrow lengths
// step discretely at the network rate while the aircraft visual moves
// continuously (via the 40 ms-half-life pose smoothing in 6.1_...),
// producing a visible "dance".  Smoothing the raw world-frame values
// with the SAME 40 ms half-life as the pose keeps arrow and aircraft in
// lock step.
//
// The previous attempt rotated each vector by qSmooth·qAuth⁻¹ to sync
// body-attached forces with the visible attitude, but this wrongly
// rotated the weight vector (which is world-attached / always points
// down) along with the rolling aircraft, making it wobble.  Straight
// exponential smoothing handles both world-attached and body-attached
// forces correctly: the smoothed weight vector stays pointing down (the
// authoritative value it relaxes toward is constant), and body-attached
// forces like lift smoothly rotate with the server-updated direction.
const FORCE_ARROW_SMOOTH_HALFLIFE_MS = 40;
const _wingForceSmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _htailForceSmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _vtailForceSmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _weightForceSmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _velocityLineSmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _freestreamSmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _htailLocalVelocitySmoothedVec = new BABYLON.Vector3(0, 0, 0);
const _vtailLocalVelocitySmoothedVec = new BABYLON.Vector3(0, 0, 0);
let _forceArrowSmoothingInitialized = false;
let _velocityLineSmoothingInitialized = false;
let _freestreamSmoothingInitialized = false;
let _tailLocalVelocitySmoothingInitialized = false;

function _exponentialSmoothVector3InPlace(smoothed, target, alpha) {
    smoothed.x += (target.x - smoothed.x) * alpha;
    smoothed.y += (target.y - smoothed.y) * alpha;
    smoothed.z += (target.z - smoothed.z) * alpha;
}

function _forceArrowSmoothingAlpha() {
    const dtMs = (typeof engine !== 'undefined' && engine && typeof engine.getDeltaTime === 'function')
        ? engine.getDeltaTime()
        : 16.6;
    // Clamp so an occasional long frame (tab backgrounded, GC) doesn't
    // produce an alpha > 1 that would overshoot the target.
    const clampedDtMs = Math.min(Math.max(dtMs, 0.0), 250.0);
    return 1.0 - Math.pow(0.5, clampedDtMs / FORCE_ARROW_SMOOTH_HALFLIFE_MS);
}

// `resolveArrowOrigin` was removed to prevent 10Hz telemetry jitter versus 60Hz smoothly interpolated aircraft.

function disposeLegacyForceLines(scene) {
    if (!scene || legacyForceLinesDisposed) return;
    const legacyNames = [
        "forceLine",
        "wingForceLine",
        "tailForceLine",
        "tailLiftLine",
        "wingLiftLine",
        "htailLiftLine",
        "vtailLiftLine",
        "weightLine"
    ];
    for (const name of legacyNames) {
        const m = scene.getMeshByName(name);
        if (m) m.dispose();
    }
    legacyForceLinesDisposed = true;
}

function createForceLine(scene) {
    if (!scene) return null;
    disposeLegacyForceLines(scene);
    if (!forceMeshesReset) {
        const stale = scene.meshes.filter(m => m && m.name && m.name.startsWith("force_"));
        for (const m of stale) m.dispose();
        forceMeshesReset = true;
    }
    if (!wingLiftArrow) wingLiftArrow = createVectorArrow("force_wing_lift", BABYLON.Color3.Blue(), scene);
    if (!htailLiftArrow) htailLiftArrow = createVectorArrow("force_htail_lift", BABYLON.Color3.FromHexString("#ff00ff"), scene);
    if (!vtailLiftArrow) vtailLiftArrow = createVectorArrow("force_vtail_lift", BABYLON.Color3.FromHexString("#ff9f1a"), scene);
    if (!weightArrow) weightArrow = createVectorArrow("force_weight", BABYLON.Color3.FromHexString("#9cff57"), scene);
    if (!freestreamLine) {
        freestreamLine = BABYLON.MeshBuilder.CreateLines("force_freestream_line",
            { points: [BABYLON.Vector3.Zero(), new BABYLON.Vector3(1, 0, 0)], updatable: true }, scene);
        freestreamLineMaterial = new BABYLON.StandardMaterial("force_freestream_mat", scene);
        freestreamLineMaterial.emissiveColor = BABYLON.Color3.Yellow();
        freestreamLineMaterial.disableLighting = true;
        freestreamLine.color = BABYLON.Color3.Yellow();
        freestreamLine.renderingGroupId = 2;
        freestreamLine.isPickable = false;
        freestreamLine.alwaysSelectAsActiveMesh = true;
    }
    if (!tailLocalVelocityLineMaterial) {
        tailLocalVelocityLineMaterial = new BABYLON.StandardMaterial("force_tail_local_velocity_mat", scene);
        tailLocalVelocityLineMaterial.emissiveColor = BABYLON.Color3.Yellow();
        tailLocalVelocityLineMaterial.disableLighting = true;
    }
    if (!htailLocalVelocityLine) {
        htailLocalVelocityLine = BABYLON.MeshBuilder.CreateLines("force_htail_local_velocity_line",
            { points: [BABYLON.Vector3.Zero(), new BABYLON.Vector3(1, 0, 0)], updatable: true }, scene);
        htailLocalVelocityLine.material = tailLocalVelocityLineMaterial;
        htailLocalVelocityLine.color = BABYLON.Color3.Yellow();
        htailLocalVelocityLine.renderingGroupId = 2;
        htailLocalVelocityLine.isPickable = false;
        htailLocalVelocityLine.alwaysSelectAsActiveMesh = true;
    }
    if (!vtailLocalVelocityLine) {
        vtailLocalVelocityLine = BABYLON.MeshBuilder.CreateLines("force_vtail_local_velocity_line",
            { points: [BABYLON.Vector3.Zero(), new BABYLON.Vector3(1, 0, 0)], updatable: true }, scene);
        vtailLocalVelocityLine.material = tailLocalVelocityLineMaterial;
        vtailLocalVelocityLine.color = BABYLON.Color3.Yellow();
        vtailLocalVelocityLine.renderingGroupId = 2;
        vtailLocalVelocityLine.isPickable = false;
        vtailLocalVelocityLine.alwaysSelectAsActiveMesh = true;
    }
    return wingLiftArrow?.shaft || null;
}

function updateVelocityLine(scene) {
    if (!scene || !velocityLine || velocityLine.isDisposed()) return;

    const velocityVectorsEnabled = (typeof show_velocity_vectors !== 'undefined' && (show_velocity_vectors === "true" || show_velocity_vectors === true));
    if (!velocityVectorsEnabled) {
        velocityLine.isVisible = false;
        return;
    }
    velocityLine.isVisible = true;

    if (!aircraft || !aircraft.position || typeof velocity === "undefined") return;

    const origin = aircraft.position.clone();
    const velRaw = new BABYLON.Vector3(velocity.x, velocity.y, velocity.z);
    if (!isFinite(velRaw.x) || !isFinite(velRaw.y) || !isFinite(velRaw.z)) return;

    // Smooth the raw world-frame velocity with the same 40 ms half-life
    // the render loop uses for the aircraft pose (see 6.1_...).  This
    // removes the per-network-frame discrete steps in the velocity vector
    // so the red line neither lengthens nor swings in a visible "dance"
    // against the smoothly-moving aircraft.
    if (!_velocityLineSmoothingInitialized) {
        _velocityLineSmoothedVec.copyFrom(velRaw);
        _velocityLineSmoothingInitialized = true;
    } else {
        _exponentialSmoothVector3InPlace(_velocityLineSmoothedVec, velRaw, _forceArrowSmoothingAlpha());
    }
    const end = origin.add(_velocityLineSmoothedVec.scale(0.3));
    velocityLine.updateVerticesData(BABYLON.VertexBuffer.PositionKind, [
        origin.x, origin.y, origin.z,
        end.x, end.y, end.z
    ]);
    velocityLine.computeWorldMatrix(true);
}

function updateForceLine(scene) {
    if (!scene || !aircraft || !aircraft.position) return;
    if (!wingLiftArrow || !htailLiftArrow || !vtailLiftArrow || !weightArrow ||
        !htailLocalVelocityLine || !vtailLocalVelocityLine) {
        createForceLine(scene);
    }
    if (!wingLiftArrow || !htailLiftArrow || !vtailLiftArrow || !weightArrow) return;

    const forceVectorsEnabled = (typeof show_force_vectors !== 'undefined' && (show_force_vectors === "true" || show_force_vectors === true));
    if (!forceVectorsEnabled) {
        wingLiftArrow.shaft.setEnabled(false);
        wingLiftArrow.head.setEnabled(false);
        htailLiftArrow.shaft.setEnabled(false);
        htailLiftArrow.head.setEnabled(false);
        vtailLiftArrow.shaft.setEnabled(false);
        vtailLiftArrow.head.setEnabled(false);
        weightArrow.shaft.setEnabled(false);
        weightArrow.head.setEnabled(false);
        if (freestreamLine) freestreamLine.setEnabled(false);
        if (htailLocalVelocityLine) htailLocalVelocityLine.setEnabled(false);
        if (vtailLocalVelocityLine) vtailLocalVelocityLine.setEnabled(false);
        return;
    }

    const wingOriginRaw = new BABYLON.Vector3(
        wingLiftOriginGlobalX,
        wingLiftOriginGlobalY,
        wingLiftOriginGlobalZ
    );
    const wingVecRaw = new BABYLON.Vector3(wingLiftGlobalX, wingLiftGlobalY, wingLiftGlobalZ);
    const htailOriginRaw = new BABYLON.Vector3(
        htailLiftOriginGlobalX,
        htailLiftOriginGlobalY,
        htailLiftOriginGlobalZ
    );
    const htailVecRaw = new BABYLON.Vector3(
        htailForceGlobalX,
        htailForceGlobalY,
        htailForceGlobalZ
    );
    const vtailOriginRaw = new BABYLON.Vector3(
        vtailLiftOriginGlobalX,
        vtailLiftOriginGlobalY,
        vtailLiftOriginGlobalZ
    );
    const vtailVecRaw = new BABYLON.Vector3(
        vtailForceGlobalX,
        vtailForceGlobalY,
        vtailForceGlobalZ
    );
    const htailLocalVelocityRaw = new BABYLON.Vector3(
        htailLocalVelocityGlobalX,
        htailLocalVelocityGlobalY,
        htailLocalVelocityGlobalZ
    );
    const vtailLocalVelocityRaw = new BABYLON.Vector3(
        vtailLocalVelocityGlobalX,
        vtailLocalVelocityGlobalY,
        vtailLocalVelocityGlobalZ
    );
    const weightOriginRaw = new BABYLON.Vector3(
        weightOriginGlobalX,
        weightOriginGlobalY,
        weightOriginGlobalZ
    );
    const weightVecRaw = new BABYLON.Vector3(weightForceGlobalX, weightForceGlobalY, weightForceGlobalZ);

    if (
        ![wingVecRaw, htailVecRaw, vtailVecRaw, weightVecRaw,
          htailLocalVelocityRaw, vtailLocalVelocityRaw].every(
            v => isFiniteVector3(v)
        )
    ) {
        return;
    }

    // Per-frame exponential smoothing of the server-sent world-frame
    // vectors.  The server ships these at ~30 Hz, so without smoothing
    // the arrows step discretely while the aircraft pose interpolates
    // continuously — visible as a "dance" at network rate.  Smoothing
    // with the same 40 ms half-life as the pose keeps both in sync, so
    // the arrows stay attached to the visible aircraft cleanly.
    //
    // Weight is world-attached (always (0, -mg, 0)); its smoothed value
    // converges to that constant and doesn't wobble.  Lift and tail
    // forces are effectively body-attached: their world-frame direction
    // tracks qAuth, and the smoothing lag matches the qSmooth lag, so
    // arrow and aircraft stay aligned during rolls.
    const _alpha = _forceArrowSmoothingAlpha();
    if (!_forceArrowSmoothingInitialized) {
        _wingForceSmoothedVec.copyFrom(wingVecRaw);
        _htailForceSmoothedVec.copyFrom(htailVecRaw);
        _vtailForceSmoothedVec.copyFrom(vtailVecRaw);
        _weightForceSmoothedVec.copyFrom(weightVecRaw);
        _forceArrowSmoothingInitialized = true;
    } else {
        _exponentialSmoothVector3InPlace(_wingForceSmoothedVec, wingVecRaw, _alpha);
        _exponentialSmoothVector3InPlace(_htailForceSmoothedVec, htailVecRaw, _alpha);
        _exponentialSmoothVector3InPlace(_vtailForceSmoothedVec, vtailVecRaw, _alpha);
        _exponentialSmoothVector3InPlace(_weightForceSmoothedVec, weightVecRaw, _alpha);
    }
    if (!_tailLocalVelocitySmoothingInitialized) {
        _htailLocalVelocitySmoothedVec.copyFrom(htailLocalVelocityRaw);
        _vtailLocalVelocitySmoothedVec.copyFrom(vtailLocalVelocityRaw);
        _tailLocalVelocitySmoothingInitialized = true;
    } else {
        _exponentialSmoothVector3InPlace(_htailLocalVelocitySmoothedVec, htailLocalVelocityRaw, _alpha);
        _exponentialSmoothVector3InPlace(_vtailLocalVelocitySmoothedVec, vtailLocalVelocityRaw, _alpha);
    }
    const wingVec = _wingForceSmoothedVec;
    const htailVec = _htailForceSmoothedVec;
    const vtailVec = _vtailForceSmoothedVec;
    const weightVec = _weightForceSmoothedVec;
    const htailLocalVelocityVec = _htailLocalVelocitySmoothedVec;
    const vtailLocalVelocityVec = _vtailLocalVelocitySmoothedVec;

    // Prefer body-local AC offsets so the origins ride on the smoothed visual aircraft.
    // Raw world origins remain only as a compatibility fallback for older servers.
    const wingOrigin = resolveForceOrigin(window.wingLiftLocalOffset, wingOriginRaw, new BABYLON.Vector3(0.25, 0.0, 0.0));
    const htailOrigin = resolveForceOrigin(window.htailLiftLocalOffset, htailOriginRaw, new BABYLON.Vector3(-2.5, 0.0, 0.0));
    const vtailOrigin = resolveForceOrigin(window.vtailLiftLocalOffset, vtailOriginRaw, new BABYLON.Vector3(-2.5, 0.65, 0.0));
    const weightOrigin = resolveForceOrigin(window.weightLocalOffset, weightOriginRaw, new BABYLON.Vector3(0.0, 0.0, 0.0));

    // Fallback if localPointToWorld returns null before aircraft is ready
    if (!wingOrigin || !htailOrigin || !vtailOrigin || !weightOrigin) return;

    const forceScale = 0.0006; // +50% versus previous global scale
    const tailForceScale = forceScale * (isFinite(scale_tail_forces) && scale_tail_forces > 0 ? scale_tail_forces : 5.0);
    updateVectorArrow(wingLiftArrow, wingOrigin, wingVec, forceScale);
    updateVectorArrow(htailLiftArrow, htailOrigin, htailVec, tailForceScale);
    updateVectorArrow(vtailLiftArrow, vtailOrigin, vtailVec, tailForceScale);
    updateVectorArrow(weightArrow, weightOrigin, weightVec, forceScale);

    const tailLocalVelocityScale = 0.06;
    const updateTailVelocityLine = (line, origin, vector) => {
        if (!line || !origin || !vector) return;
        const speed = vector.length();
        if (!isFinite(speed) || speed <= 0.05) {
            line.setEnabled(false);
            return;
        }
        const visualLength = Math.max(0.35, Math.min(7.0, speed * tailLocalVelocityScale));
        const tip = origin.add(vector.scale(visualLength / speed));
        line.setEnabled(true);
        BABYLON.MeshBuilder.CreateLines(line.name, { points: [origin, tip], instance: line });
    };
    updateTailVelocityLine(htailLocalVelocityLine, htailOrigin, htailLocalVelocityVec);
    updateTailVelocityLine(vtailLocalVelocityLine, vtailOrigin, vtailLocalVelocityVec);

    // Flight velocity line: yellow line from CG in the direction of flight.
    // Base at CG, extends forward along the velocity vector.
    if (freestreamLine && typeof velocity !== 'undefined') {
        const cgWorld = localPointToWorld(new BABYLON.Vector3(0.0, 0.0, 0.0));
        if (cgWorld) {
            const velRaw = new BABYLON.Vector3(velocity.x, velocity.y, velocity.z);
            // Same exponential smoothing as the force arrows — the CG
            // anchor comes from the smoothed aircraft matrix, so the
            // freestream vector must also be smoothed at the same rate
            // to avoid a step change every network frame.
            let vel;
            if (isFinite(velRaw.x) && isFinite(velRaw.y) && isFinite(velRaw.z)) {
                if (!_freestreamSmoothingInitialized) {
                    _freestreamSmoothedVec.copyFrom(velRaw);
                    _freestreamSmoothingInitialized = true;
                } else {
                    _exponentialSmoothVector3InPlace(_freestreamSmoothedVec, velRaw, _forceArrowSmoothingAlpha());
                }
                vel = _freestreamSmoothedVec;
            } else {
                vel = velRaw;
            }
            if (isFinite(vel.x) && isFinite(vel.y) && isFinite(vel.z) && vel.length() > 0.1) {
                const lineLength = 0.15;
                const tip = cgWorld.add(vel.scale(lineLength));
                freestreamLine.setEnabled(true);
                freestreamLine = BABYLON.MeshBuilder.CreateLines("force_freestream_line",
                    { points: [cgWorld, tip], instance: freestreamLine });
            } else {
                freestreamLine.setEnabled(false);
            }
        }
    }
}
