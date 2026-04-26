
// ========================================================
// Aircraft Creation Function
// ========================================================
// Track which visual_geometry payload has been applied. This lets live
// aircraft reloads rebuild the parametric model when the YAML geometry changes.
let visualGeometryApplied = false;
let visualGeometryAppliedSignature = null;

/**
 * Create — or recreate — the ribbon-blade propeller at a specific
 * physical tip-to-tip diameter, in meters.  The blade mesh vertices are
 * placed directly at the requested dimensions; the propeller pivot's
 * own scaling stays at identity (1,1,1), so there is NO scale factor
 * sitting anywhere in the transform chain that could combine with GLB
 * scale, per-aircraft overrides, or anything else to produce a wildly-
 * out-of-scale prop.
 *
 * Call signature lets `applyRenderSettingsToAircraft` in 4.3 re-run
 * this whenever the user edits `diameter_m` in render_settings.yaml
 * and presses respawn — we dispose the old blades and create new ones
 * at the new size.  Shadow-caster registration is idempotent (Babylon
 * deduplicates internally), so it's safe to re-register on every rebuild.
 *
 * @param {BABYLON.Scene} scene
 * @param {BABYLON.TransformNode} propellerPivot - parent pivot; kept at
 *   scale 1, rotation animated by createAircraft's onBeforeRender hook.
 * @param {number} diameterM - physical tip-to-tip diameter in METERS.
 * @param {BABYLON.ShadowGenerator} [shadowGenerator]
 */
function rebuildPropellerBlades(scene, propellerPivot, diameterM, shadowGenerator) {
    if (!scene || !propellerPivot) return;
    if (!(typeof diameterM === 'number' && isFinite(diameterM) && diameterM > 0)) return;

    // Dispose existing blades via the pivot's own child list.
    //
    // DO NOT use `scene.getMeshByName("blade1")` here: the wind turbines
    // in 4.3.7_💨_create_wind_turbines.js also create meshes named
    // blade1/blade2/blade3, and `getMeshByName` returns the first match
    // in scene.meshes (typically creation order). On a scenery level that
    // spawns turbines before the aircraft, a name-based lookup happily
    // disposes a windmill's blade1 and blade2 every time the aircraft
    // propeller is rebuilt — leaving windmills with only their blade3
    // visible. Iterating the aircraft's own pivot children is namespace-
    // safe: it can never touch anything that isn't already a child of
    // the aircraft's propellerPivot.
    propellerPivot.getChildMeshes().slice().forEach(mesh => mesh.dispose());

    // Each blade extends from the pivot (y=0) to the tip (y = diameterM/2).
    // Two blades 180° apart give the full tip-to-tip span equal to diameterM.
    // The blade's root chord (0.1 m) and tip chord (0.05 m) are fixed —
    // realistic prop chord-to-diameter is ≈ 0.05–0.08, which matches these
    // numbers reasonably for any plausible diameterM.
    const halfSpan = diameterM / 2;
    const rootChordM = 0.10;
    const tipChordM  = 0.05;

    const bottomEdge = [
        new BABYLON.Vector3(-rootChordM / 2, 0, 0),
        new BABYLON.Vector3( rootChordM / 2, 0, 0),
    ];
    const topEdge = [
        new BABYLON.Vector3(-tipChordM / 2, halfSpan, 0),
        new BABYLON.Vector3( tipChordM / 2, halfSpan, 0),
    ];

    const blade1 = BABYLON.MeshBuilder.CreateRibbon("blade1", {
        pathArray: [bottomEdge, topEdge],
        sideOrientation: BABYLON.Mesh.DOUBLESIDE,
    }, scene);
    blade1.rotation.y = BABYLON.Tools.ToRadians(90);
    blade1.parent = propellerPivot;

    const blade2 = blade1.clone("blade2");
    blade2.rotation.x += Math.PI;

    const propellerMaterial = new BABYLON.PBRMetallicRoughnessMaterial("propellerMetal", scene);
    propellerMaterial.metallic = 1.0;
    propellerMaterial.roughness = 0.2;
    propellerMaterial.baseColor = new BABYLON.Color3(0.8, 0.8, 0.8);
    // Translucent blades — easier for the pilot to see through the
    // propeller disc when the prop is spinning in front of the camera.
    // MATERIAL_ALPHABLEND is required for PBR materials to actually
    // honor the alpha value instead of falling back to opaque.
    propellerMaterial.alpha = 0.2;
    propellerMaterial.transparencyMode = BABYLON.Material.MATERIAL_ALPHABLEND;
    blade1.material = propellerMaterial;
    blade2.material = propellerMaterial;

    if (shadowGenerator) {
        shadowGenerator.addShadowCaster(blade1);
        shadowGenerator.addShadowCaster(blade2);
    }

    console.log(
        `Propeller blades built: diameter_m = ${diameterM.toFixed(3)} m ` +
        `(pivot scale kept at 1.0 — size baked into mesh vertices)`
    );
}

// Expose globally so 4.3_🔼_import_parameters_for_glb_aircraft.js can
// call it from applyRenderSettingsToAircraft when the yaml changes.
if (typeof window !== 'undefined') {
    window.rebuildPropellerBlades = rebuildPropellerBlades;
}

/**
 * Converts body-axis position {x, y, z} (x-fwd, y-right, z-down by default)
 * to Babylon.js scene coordinates (x-fwd, y-up, z-right).
 * Accepts either an object {x,y,z} or falls back to defaults.
 */
function bodyToScene(pos, defaultX, defaultY, defaultZ, verticalSign = -1) {
    if (pos && typeof pos.x === "number") {
        return new BABYLON.Vector3(pos.x, verticalSign * pos.z, pos.y);
    }
    return new BABYLON.Vector3(
        defaultX !== undefined ? defaultX : 0,
        defaultY !== undefined ? defaultY : 0,
        defaultZ !== undefined ? defaultZ : 0
    );
}

function finiteNumberOrNull(value) {
    return (typeof value === "number" && Number.isFinite(value)) ? value : null;
}

function averageNumbers(values) {
    const nums = values.filter((value) => typeof value === "number" && Number.isFinite(value));
    if (!nums.length) return null;
    return nums.reduce((sum, value) => sum + value, 0) / nums.length;
}

function inferLongitudinalAxisSign(vg) {
    const coordinateSystem = typeof vg?.coordinate_system === "string"
        ? vg.coordinate_system.toLowerCase()
        : "";

    if (coordinateSystem.includes("x_aft") || coordinateSystem.includes("x_forward_to_aft")) {
        return -1;
    }

    const liftingSurfaces = Array.isArray(vg?.lifting_surfaces) ? vg.lifting_surfaces : [];
    const fuselageNoseX = finiteNumberOrNull(vg?.fuselages?.[0]?.nose_position_m?.x);
    const surfaceXs = liftingSurfaces
        .map((surf) => finiteNumberOrNull(surf?.root_LE_m?.x))
        .filter((value) => value !== null);

    if (fuselageNoseX !== null) {
        const meanSurfaceX = averageNumbers(surfaceXs);
        if (meanSurfaceX !== null) {
            if (meanSurfaceX > fuselageNoseX + 0.25) return -1;
            if (meanSurfaceX < fuselageNoseX - 0.25) return 1;
        }
    }

    const wingX = averageNumbers(liftingSurfaces
        .filter((surf) => (surf?.role || "").toLowerCase() === "wing")
        .map((surf) => finiteNumberOrNull(surf?.root_LE_m?.x)));
    const tailX = averageNumbers(liftingSurfaces
        .filter((surf) => {
            const role = (surf?.role || "").toLowerCase();
            return role === "horizontal_stabilizer" || role === "vertical_stabilizer";
        })
        .map((surf) => finiteNumberOrNull(surf?.root_LE_m?.x)));

    if (wingX !== null && tailX !== null) {
        if (tailX > wingX + 0.25) return -1;
        if (tailX < wingX - 0.25) return 1;
    }

    const propellerX = finiteNumberOrNull(vg?.propeller?.position_m?.x);
    const tailLightX = finiteNumberOrNull(vg?.lights?.tailcone_position_m?.x) ??
        finiteNumberOrNull(vg?.lights?.strobe_position_m?.x);

    if (propellerX !== null && tailLightX !== null) {
        if (tailLightX > propellerX + 0.25) return -1;
        if (tailLightX < propellerX - 0.25) return 1;
    }

    return 1;
}

function inferVerticalAxisSignFromGeometry(vg) {
    const liftingSurfaces = Array.isArray(vg?.lifting_surfaces) ? vg.lifting_surfaces : [];
    let votes = 0;

    for (const surf of liftingSurfaces) {
        if (!surf || surf.vertical) continue;

        const rootLE = surf.root_LE_m;
        const tipLE = surf.tip_LE_m;
        if (!rootLE || !tipLE) continue;

        const dihedralDeg = finiteNumberOrNull(surf.dihedral_deg);
        if (dihedralDeg === null || Math.abs(dihedralDeg) < 0.1) continue;

        const rawDeltaZ = finiteNumberOrNull(tipLE.z) !== null && finiteNumberOrNull(rootLE.z) !== null
            ? tipLE.z - rootLE.z
            : null;
        if (rawDeltaZ === null || Math.abs(rawDeltaZ) < 1e-4) continue;

        const expectedUpSign = Math.sign(dihedralDeg);
        const rawSign = Math.sign(rawDeltaZ);
        if (rawSign === expectedUpSign) votes += 1;
        if (rawSign === -expectedUpSign) votes -= 1;
    }

    if (votes > 0) return 1;
    if (votes < 0) return -1;
    return null;
}

function inferVerticalAxisSign(vg) {
    const coordinateSystem = typeof vg?.coordinate_system === "string"
        ? vg.coordinate_system.toLowerCase()
        : "";
    const geometrySign = inferVerticalAxisSignFromGeometry(vg);

    if (coordinateSystem.includes("z_up")) {
        return 1;
    }
    if (coordinateSystem.includes("z_down")) {
        // Early Model Creator exports mislabeled z-up visual geometry as
        // z-down. If the wing dihedral/tip data clearly says otherwise,
        // prefer the geometry so existing hangar YAMLs render upright.
        if (geometrySign === 1) return 1;
        return -1;
    }

    // Model Creator exports z-up visual geometry. Older hand-authored
    // OpenFLIGHT models without a coordinate tag are still close enough to
    // the defaults that this is the safer assumption for new files.
    return geometrySign || 1;
}

function longitudinalToSceneX(rawX, cgX, longitudinalSign) {
    const x = finiteNumberOrNull(rawX) ?? 0;
    const cg = finiteNumberOrNull(cgX) ?? 0;
    return longitudinalSign * (x - cg);
}

function visualPointToScene(pos, cg, longitudinalSign, verticalSign, defaultX, defaultY, defaultZ) {
    if (pos && typeof pos.x === "number") {
        return new BABYLON.Vector3(
            longitudinalToSceneX(pos.x, cg?.x, longitudinalSign),
            verticalSign * ((pos.z || 0) - (cg?.z || 0)),
            (pos.y || 0) - (cg?.y || 0)
        );
    }
    return new BABYLON.Vector3(
        defaultX !== undefined ? defaultX : 0,
        defaultY !== undefined ? defaultY : 0,
        defaultZ !== undefined ? defaultZ : 0
    );
}

function inferSurfaceSymmetry(surf) {
    if (typeof surf.symmetric === "boolean") {
        return surf.symmetric;
    }
    if (surf.vertical) {
        return false;
    }
    if (typeof surf.mirror === "boolean" && surf.mirror) {
        return true;
    }

    const area = finiteNumberOrNull(surf.surface_area_m2);
    const semiSpan = finiteNumberOrNull(surf.semi_span_m);
    const rootChord = finiteNumberOrNull(surf.root_chord_m);
    const tipChordRaw = finiteNumberOrNull(surf.tip_chord_m);
    const tipChord = tipChordRaw !== null ? tipChordRaw : rootChord;
    if (area && semiSpan && rootChord && tipChord) {
        const oneSideArea = 0.5 * (rootChord + tipChord) * semiSpan;
        if (oneSideArea > 1e-6) {
            const ratio = area / oneSideArea;
            if (Math.abs(ratio - 2) < 0.2) return true;
            if (Math.abs(ratio - 1) < 0.2) return false;
        }
    }

    const role = typeof surf.role === "string" ? surf.role.toLowerCase() : "";
    if (role === "wing" || role === "horizontal_stabilizer" || role === "canard") {
        return true;
    }
    if (role === "vertical_stabilizer") {
        return false;
    }

    if (typeof surf.mirror === "boolean") {
        return surf.mirror;
    }
    return !surf.vertical;
}

function inferFullSurfaceSpan(surf, symmetric) {
    const explicitSpan = finiteNumberOrNull(surf.span_m);
    if (explicitSpan && explicitSpan > 0) {
        return explicitSpan;
    }

    const semiSpan = finiteNumberOrNull(surf.semi_span_m);
    if (semiSpan && semiSpan > 0) {
        if (surf.vertical) {
            return semiSpan;
        }
        return symmetric ? semiSpan * 2 : semiSpan;
    }

    const area = finiteNumberOrNull(surf.surface_area_m2);
    const aspectRatio = finiteNumberOrNull(surf.AR);
    if (area && area > 0 && aspectRatio && aspectRatio > 0) {
        return Math.sqrt(area * aspectRatio);
    }

    return 1.0;
}

function inferPanelSpan(surf, symmetric) {
    if (surf.vertical) {
        const explicitSpan = finiteNumberOrNull(surf.span_m);
        if (explicitSpan && explicitSpan > 0) {
            return explicitSpan;
        }

        const semiSpan = finiteNumberOrNull(surf.semi_span_m);
        if (semiSpan && semiSpan > 0) {
            return semiSpan;
        }
    }

    const semiSpan = finiteNumberOrNull(surf.semi_span_m);
    if (semiSpan && semiSpan > 0) {
        return semiSpan;
    }

    const rootLE = surf.root_LE_m;
    const tipLE = surf.tip_LE_m;
    if (rootLE && tipLE) {
        const panelExtent = surf.vertical
            ? Math.abs((tipLE.z || 0) - (rootLE.z || 0))
            : Math.abs((tipLE.y || 0) - (rootLE.y || 0));
        if (panelExtent > 1e-6) {
            return panelExtent;
        }
    }

    const fullSpan = inferFullSurfaceSpan(surf, symmetric);
    if (surf.vertical) {
        return fullSpan > 0 ? fullSpan : 1.0;
    }
    return symmetric ? fullSpan / 2 : fullSpan;
}

function inferDihedralRad(surf, verticalSign = 1) {
    const explicitDihedralDeg = finiteNumberOrNull(surf.dihedral_deg);
    if (explicitDihedralDeg !== null) {
        return explicitDihedralDeg * Math.PI / 180;
    }

    const rootLE = surf.root_LE_m;
    const tipLE = surf.tip_LE_m;
    if (rootLE && tipLE && !surf.vertical) {
        const deltaY = (tipLE.y || 0) - (rootLE.y || 0);
        const deltaZ = verticalSign * ((tipLE.z || 0) - (rootLE.z || 0));
        if (Math.abs(deltaY) > 1e-6) {
            return Math.atan2(deltaZ, Math.abs(deltaY));
        }
    }

    return 0;
}

function inferSweepRad(surf) {
    const explicitSweep = finiteNumberOrNull(surf.sweep_LE_rad);
    if (explicitSweep !== null) {
        return explicitSweep;
    }

    const rootLE = surf.root_LE_m;
    const tipLE = surf.tip_LE_m;
    if (rootLE && tipLE) {
        const deltaX = (tipLE.x || 0) - (rootLE.x || 0);
        const spanComponent = surf.vertical
            ? Math.abs((tipLE.z || 0) - (rootLE.z || 0))
            : Math.abs((tipLE.y || 0) - (rootLE.y || 0));
        if (spanComponent > 1e-6) {
            return Math.atan2(deltaX, spanComponent);
        }
    }

    const qcSweepDeg = finiteNumberOrNull(surf.sweep_quarter_chord_deg);
    return qcSweepDeg !== null ? qcSweepDeg * Math.PI / 180 : 0;
}

/**
 * Creates a simple parametric aircraft model.
 * If visualGeometry data is provided (from the YAML model), dimensions
 * are derived from the actual aircraft definition. Otherwise, hardcoded
 * defaults are used as a fallback.
 *
 * @param {BABYLON.ShadowGenerator} shadowGenerator - The shadow generator.
 * @param {BABYLON.Scene} scene - The Babylon.js scene.
 * @param {number} [propeller_diameter] - Optional propeller tip-to-tip diameter (meters).
 * @param {Object} [visualGeometry] - Optional visual_geometry from YAML model.
 */
async function createAircraft(shadowGenerator, scene, propeller_diameter, visualGeometry) {
    // Dispose of an existing aircraft if it exists.
    if (aircraft) {
        aircraft.dispose();
    }
    // Dispose of existing GLB model if it exists
    if (glbNode) {
        glbNode.dispose(false, true); // Dispose hierarchy and materials
        glbNode = null;
    }

    // Create the main aircraft sphere (invisible physics body).
    aircraft = BABYLON.MeshBuilder.CreateSphere("aircraft", { diameter: 0.1 }, scene);
    aircraft.position.y = initial_altitude || 100;
    aircraft.position.x = -250;

    aircraft.rotationQuaternion = new BABYLON.Quaternion(0, 0, 0, 1);
    aircraft.isVisible = false;

    // Create a transform node to hold the simple aircraft geometry.
    planeNode = new BABYLON.TransformNode("simpleAircraft", scene);
    planeNode.parent = aircraft;

    // ---- Extract geometry parameters ----
    const geom = extractGeometryParams(visualGeometry);

    // --- Create Aircraft Components ---
    // Fuselage
    const fuselage = BABYLON.MeshBuilder.CreateCylinder("fuselage", {
        diameter: geom.fuselage.diameter,
        height: geom.fuselage.length,
        tessellation: 16
    }, scene);
    fuselage.rotation = new BABYLON.Vector3(0, 0, -Math.PI / 2);
    fuselage.position = geom.fuselage.position;
    fuselage.parent = planeNode;

    // Create lifting surfaces from geometry
    const surfaceMeshes = [];
    for (const surf of geom.liftingSurfaces) {
        const mesh = createLiftingSurfaceMesh(surf, scene);
        mesh.parent = planeNode;
        surfaceMeshes.push(mesh);
    }

    // --- Material Assignment ---
    const aircraftMaterial = new BABYLON.StandardMaterial("aircraftMaterial", scene);
    aircraftMaterial.diffuseColor = new BABYLON.Color3(0.9, 0.9, 0.2);
    fuselage.material = aircraftMaterial;
    for (const mesh of surfaceMeshes) {
        mesh.material = aircraftMaterial;
    }

    // --- Propeller ---
    // Blade mesh is built at the PHYSICAL tip-to-tip diameter (meters)
    // directly — no pivot scaling. `rebuildPropellerBlades` is also
    // called from applyRenderSettingsToAircraft in 4.3 whenever the
    // render_settings.yaml `diameter_m` changes, so the prop can be
    // re-sized live on restart without ever compounding scales.
    const propellerPivot = new BABYLON.TransformNode("propellerPivot", scene);
    propellerPivot.parent = planeNode;
    propellerPivot.position = geom.propeller.position;
    propellerPivot.scaling = new BABYLON.Vector3(1, 1, 1);

    const initialDiameterM =
        (typeof propeller_diameter === 'number' && propeller_diameter > 0) ? propeller_diameter :
        (geom.propeller.diameter > 0 ? geom.propeller.diameter : 1.5);
    rebuildPropellerBlades(scene, propellerPivot, initialDiameterM, shadowGenerator);

    // Animate propeller
    const rpm = 310;
    const rps = rpm / 60;
    const angularSpeed = rps * 2 * Math.PI;
    scene.onBeforeRenderObservable.add(() => {
        if (propellerPivot && propellerPivot.isEnabled()) {
            const deltaTimeInSeconds = scene.getEngine().getDeltaTime() / 1000;
            propellerPivot.rotation.x += angularSpeed * deltaTimeInSeconds;
        }
    });

    // --- Add non-propeller planeNode children to the shadow generator ---
    // (The prop blades were registered inside rebuildPropellerBlades.)
    planeNode.getChildMeshes().forEach(mesh => {
        if (mesh.name === "blade1" || mesh.name === "blade2") return;
        shadowGenerator.addShadowCaster(mesh);
    });

    // --- Lights ---
    const rightWingLightSphere = createBlinkingSphere(scene, 0, 0, 0, {
        sphereColor: new BABYLON.Color3(0, 1, 0),
        diameter: 0.05, lightRange: 2, blinkInterval: -1000,
        lightIntensity: 3, glowIntensity: 2, name: "starboard_light",
        createPointLight: false
    });
    rightWingLightSphere.sphere.parent = planeNode;
    rightWingLightSphere.sphere.position = geom.lights.starboard;

    const leftWingLightSphere = createBlinkingSphere(scene, 0, 0, 0, {
        sphereColor: new BABYLON.Color3(1, 0, 0),
        diameter: 0.05, lightRange: 2, blinkInterval: -1000,
        lightIntensity: 3, glowIntensity: 2, name: "port_light",
        createPointLight: false
    });
    leftWingLightSphere.sphere.parent = planeNode;
    leftWingLightSphere.sphere.position = geom.lights.port;

    const tailconeLightSphere = createBlinkingSphere(scene, 0, 0, 0, {
        sphereColor: new BABYLON.Color3(1, 1, 1),
        diameter: 0.05, lightRange: 2, blinkInterval: -1000,
        lightIntensity: 1, glowIntensity: 1, name: "tailcone_light",
        createPointLight: false
    });
    tailconeLightSphere.sphere.parent = planeNode;
    tailconeLightSphere.sphere.position = geom.lights.tailcone;

    const strobeLightSphere = createBlinkingSphere(scene, 0, 0, 0, {
        sphereColor: new BABYLON.Color3(1, 1, 1),
        diameter: 0.05, lightRange: 2, blinkInterval: 40,
        lightIntensity: 5, glowIntensity: 2, waitingInterval: 800,
        number_of_blinks: 3, name: "strobe_light",
        createPointLight: false
    });
    strobeLightSphere.sphere.parent = planeNode;
    strobeLightSphere.sphere.position = geom.lights.strobe;

    // Initial update for cameras to target the new aircraft physics body
    if (scene.updateCamerasForAircraft) {
        scene.updateCamerasForAircraft(aircraft);
    }

    planeNode.setEnabled(true);

    if (visualGeometry) {
        console.log("Aircraft model built from YAML visual_geometry data");
    }
}

// ========================================================
// Geometry Parameter Extraction
// ========================================================
/**
 * Extracts rendering parameters from visual_geometry YAML data.
 * Falls back to hardcoded defaults when no data is available.
 *
 * visual_geometry may use x-forward or x-aft, and z-up or z-down.
 * Babylon scene: x-forward, y-up, z-right.
 * The coordinate_system tag controls the conversion before mesh creation.
 */
function extractGeometryParams(vg) {
    const params = {
        fuselage: { diameter: 0.5, length: 5, position: new BABYLON.Vector3(0, 0, 0) },
        liftingSurfaces: [],
        propeller: { position: new BABYLON.Vector3(2.5, 0, 0), diameter: 1.5 },
        lights: {
            starboard: new BABYLON.Vector3(0, 0, -4),  // right wing (negative Z in scene = starboard)
            port: new BABYLON.Vector3(0, 0, 4),          // left wing
            tailcone: new BABYLON.Vector3(-2.9, 0, 0),
            strobe: new BABYLON.Vector3(-2.5, 1.25, 0)
        }
    };

    if (!vg) {
        // No visual_geometry: use original hardcoded defaults
        params.liftingSurfaces = [
            { name: "wing", role: "wing", chord: 1.2, span: 8, position: new BABYLON.Vector3(0, 0, 0), vertical: false, sweepRad: 0, dihedralRad: 0 },
            { name: "hstab", role: "horizontal_stabilizer", chord: 0.75, span: 3, position: new BABYLON.Vector3(-2.5, 0, 0), vertical: false, sweepRad: 0, dihedralRad: 0 },
            { name: "vstab", role: "vertical_stabilizer", chord: 1.2, span: 0.7, position: new BABYLON.Vector3(-2.5, 0.65, 0), vertical: true, sweepRad: 0, dihedralRad: 0 }
        ];
        return params;
    }

    // ---- CG offset: positions in YAML are relative to aircraft origin;
    // we position geometry relative to CG for correct force visualization ----
    const cg = vg.cg_position_m || { x: 0, y: 0, z: 0 };
    const longitudinalSign = inferLongitudinalAxisSign(vg);
    const verticalSign = inferVerticalAxisSign(vg);

    // ---- Fuselages ----
    if (vg.fuselages && vg.fuselages.length > 0) {
        const fus = vg.fuselages[0];
        params.fuselage.diameter = fus.diameter_m || 0.5;
        params.fuselage.length = fus.length_m || 5;

        // The creator stores x increasing from nose toward tail, while the
        // sim's simple mesh uses +x as forward. Convert the nose position to
        // scene coordinates first, then place the cylinder midpoint half a
        // fuselage length aft of that nose point.
        const nosePos = fus.nose_position_m || { x: 0, y: 0, z: 0 };
        const noseScene = visualPointToScene(nosePos, cg, longitudinalSign, verticalSign, 0, 0, 0);
        params.fuselage.position = new BABYLON.Vector3(
            noseScene.x - params.fuselage.length / 2,
            noseScene.y,
            noseScene.z
        );
    }

    // ---- Lifting surfaces ----
    if (vg.lifting_surfaces && vg.lifting_surfaces.length > 0) {
        for (const surf of vg.lifting_surfaces) {
            const role = typeof surf.role === "string" ? surf.role.toLowerCase() : "";
            const vertical = !!surf.vertical || role === "vertical_stabilizer";
            const surfForInference = Object.assign({}, surf, { vertical });
            const rootLE = surfForInference.root_LE_m || { x: 0, y: 0, z: 0 };
            const position = visualPointToScene(rootLE, cg, longitudinalSign, verticalSign, 0, 0, 0);

            const symmetric = inferSurfaceSymmetry(surfForInference);
            const fullSpan = inferFullSurfaceSpan(surfForInference, symmetric);
            const panelSpan = inferPanelSpan(surfForInference, symmetric);

            const rootChord = surfForInference.root_chord_m || 1.0;
            const tipChord = surfForInference.tip_chord_m || rootChord;
            const avgChord = (rootChord + tipChord) / 2;

            params.liftingSurfaces.push({
                name: surfForInference.name,
                role: surfForInference.role,
                chord: avgChord,
                rootChord: rootChord,
                tipChord: tipChord,
                span: vertical ? panelSpan : (symmetric ? fullSpan : panelSpan),
                position: position,
                vertical: vertical,
                sweepRad: inferSweepRad(surfForInference),
                dihedralRad: inferDihedralRad(surfForInference, verticalSign),
                mirror: symmetric,
                TR: surfForInference.TR || 1.0
            });
        }
    }

    // ---- Propeller ----
    if (vg.propeller && vg.propeller.position_m) {
        params.propeller.position = visualPointToScene(vg.propeller.position_m, cg, longitudinalSign, verticalSign, 2.5, 0, 0);
        params.propeller.diameter = vg.propeller.diameter_m || 1.5;
    }

    // ---- Lights ----
    if (vg.lights) {
        const lights = vg.lights;
        if (lights.wing_tip_position_m) {
            const wingTip = visualPointToScene(lights.wing_tip_position_m, cg, longitudinalSign, verticalSign, 0, 0, 0);
            // Default simple aircraft convention: starboard is negative scene z.
            params.lights.starboard = new BABYLON.Vector3(wingTip.x, wingTip.y, -Math.abs(wingTip.z));
            params.lights.port = new BABYLON.Vector3(wingTip.x, wingTip.y, Math.abs(wingTip.z));
        }
        if (lights.tailcone_position_m) {
            params.lights.tailcone = visualPointToScene(lights.tailcone_position_m, cg, longitudinalSign, verticalSign, -2.9, 0, 0);
        }
        if (lights.strobe_position_m) {
            params.lights.strobe = visualPointToScene(lights.strobe_position_m, cg, longitudinalSign, verticalSign, -2.5, 1.25, 0);
        }
    }

    return params;
}

// ========================================================
// Lifting Surface Mesh Builder
// ========================================================
/**
 * Creates a flat trapezoidal mesh for a lifting surface (wing, tail, etc).
 * For mirrored surfaces, creates both left and right halves.
 * For vertical surfaces, orients the span axis vertically.
 */
function createLiftingSurfaceMesh(surf, scene) {
    const rootChord = Math.max(surf.rootChord || surf.chord || 1.0, 0.01);
    const tipChord = Math.max(surf.tipChord || rootChord, 0.01);
    const sweepTan = Math.tan(surf.sweepRad || 0);

    if (surf.vertical) {
        const span = Math.max(surf.span || 1.0, 0.01);
        const numSpanStations = 5;
        const paths = [];

        for (let i = 0; i <= numSpanStations; i++) {
            const eta = i / numSpanStations;
            const spanPos = eta * span;
            const localChord = rootChord + (tipChord - rootChord) * eta;
            const sweepOffset = spanPos * sweepTan;

            paths.push([
                new BABYLON.Vector3(-sweepOffset, spanPos, 0),
                new BABYLON.Vector3(-sweepOffset - localChord, spanPos, 0)
            ]);
        }

        const ribbon = BABYLON.MeshBuilder.CreateRibbon(surf.name, {
            pathArray: paths,
            sideOrientation: BABYLON.Mesh.DOUBLESIDE,
            closePath: false,
            closeArray: false
        }, scene);

        ribbon.position = surf.position.clone();
        return ribbon;
    }

    // Horizontal surface: use a ribbon for trapezoidal planform with sweep
    const panelSpan = Math.max((surf.mirror ? surf.span / 2 : surf.span) || 1.0, 0.01);
    const dihedralSin = Math.sin(surf.dihedralRad || 0);

    // Build ribbon paths: left tip -> root -> right tip
    // Each path is a chordwise line (front to back) at a given spanwise station
    const numSpanStations = 5;  // Enough for smooth sweep/taper
    const paths = [];

    const mirror = surf.mirror !== undefined ? surf.mirror : true;
    const startSpan = mirror ? -panelSpan : 0;
    const endSpan = panelSpan;

    for (let i = 0; i <= numSpanStations; i++) {
        const eta = i / numSpanStations;
        const spanPos = startSpan + eta * (endSpan - startSpan);
        const spanMagnitude = mirror ? Math.abs(spanPos) : spanPos;
        const spanFraction = panelSpan > 1e-6 ? (spanMagnitude / panelSpan) : 0;

        // Taper ratio interpolation
        const localChord = rootChord + (tipChord - rootChord) * spanFraction;
        // Sweep offset (LE moves back with span)
        const sweepOffset = spanMagnitude * sweepTan;
        // Dihedral (vertical offset)
        const dihedralOffset = spanMagnitude * dihedralSin;

        const path = [
            new BABYLON.Vector3(
                -sweepOffset,                        // LE x-offset from sweep
                dihedralOffset,                       // dihedral vertical offset
                spanPos                               // spanwise position
            ),
            new BABYLON.Vector3(
                -sweepOffset - localChord,            // TE
                dihedralOffset,
                spanPos
            )
        ];
        paths.push(path);
    }

    const ribbon = BABYLON.MeshBuilder.CreateRibbon(surf.name, {
        pathArray: paths,
        sideOrientation: BABYLON.Mesh.DOUBLESIDE,
        closePath: false,
        closeArray: false
    }, scene);

    ribbon.position = surf.position.clone();
    return ribbon;
}


// ========================================================
// Apply Visual Geometry from Server
// ========================================================
/**
 * Called when visual_geometry data is received from the server.
 * Rebuilds the default aircraft model to match the YAML geometry.
 * Re-runs only when the geometry signature changes.
 */
function visualGeometryRenderSignature(vg) {
    if (!vg) return "";
    const fuselage = Array.isArray(vg.fuselages) && vg.fuselages.length ? vg.fuselages[0] : null;
    const surfaces = Array.isArray(vg.lifting_surfaces) ? vg.lifting_surfaces : [];
    const engines = Array.isArray(vg.engines) ? vg.engines : [];
    return JSON.stringify({
        coordinate_system: vg.coordinate_system || "",
        cg_position_m: vg.cg_position_m || null,
        fuselage: fuselage ? {
            diameter_m: fuselage.diameter_m,
            length_m: fuselage.length_m,
            nose_position_m: fuselage.nose_position_m || null
        } : null,
        lifting_surfaces: surfaces.map((surf) => ({
            name: surf?.name || "",
            role: surf?.role || "",
            root_LE_m: surf?.root_LE_m || null,
            root_chord_m: surf?.root_chord_m,
            tip_chord_m: surf?.tip_chord_m,
            semi_span_m: surf?.semi_span_m,
            span_m: surf?.span_m,
            sweep_LE_rad: surf?.sweep_LE_rad,
            dihedral_deg: surf?.dihedral_deg,
            vertical: !!surf?.vertical,
            mirror: surf?.mirror
        })),
        propeller: vg.propeller || null,
        engines: engines.map((engine) => ({
            id: engine?.id || "",
            position_m: engine?.position_m || null,
            orientation_deg: engine?.orientation_deg || null
        }))
    });
}

function applyVisualGeometry(vg, scene, shadowGenerator) {
    if (!vg || !scene) return;

    const signature = visualGeometryRenderSignature(vg);
    if (visualGeometryAppliedSignature === signature) return;

    console.log("Applying visual_geometry from YAML model...");

    // If a GLB model is loaded, don't override it
    if (glbNode && glbNode.isEnabled()) {
        if (visualGeometryAppliedSignature !== signature) {
            console.log("GLB model is active, skipping visual_geometry application.");
        }
        visualGeometryApplied = false;
        visualGeometryAppliedSignature = signature;
        return;
    }

    // Rebuild the default aircraft with the YAML geometry
    // We need the shadowGenerator from the scene setup
    if (!shadowGenerator) {
        // Try to find it from the scene's lights
        const shadowLight = scene.lights.find(l => l.getShadowGenerator && l.getShadowGenerator());
        shadowGenerator = shadowLight ? shadowLight.getShadowGenerator() : null;
    }

    if (shadowGenerator) {
        createAircraft(shadowGenerator, scene, null, vg);
        visualGeometryApplied = true;
        visualGeometryAppliedSignature = signature;
    } else {
        console.warn("No shadow generator found, cannot rebuild aircraft with visual_geometry");
    }
}


// REMOVED/COMMENTED OUT: Original loadGlbFile function. It's replaced by the new loadGLB below.
/*
function loadGlbFile(
    file,
    scaleFactor,
    rotationX,
    rotationY,
    rotationZ,
    translationX,
    translationY,
    translationZ,
    scene,
    shadowGenerator,
    wing_lights_pos,
    tailcone_light_pos,
    strobe_light_pos,
    propeller_pos,
    propeller_diameter
) {
    // ... original implementation ...
}
*/


// ========================================================
// NEW GLB Loading Function (adapted from the example)
// ========================================================
/**
 * Loads a GLB file asynchronously, applies transformations, handles lights/propeller,
 * and replaces the default aircraft model.
 *
 * @param {File} file - The GLB file object from the input element.
 * @param {number} scaleFactor - Uniform scaling factor.
 * @param {number} rotationX - Rotation around X axis (degrees).
 * @param {number} rotationY - Rotation around Y axis (degrees).
 * @param {number} rotationZ - Rotation around Z axis (degrees).
 * @param {number} translationX - Translation along X axis.
 * @param {number} translationY - Translation along Y axis.
 * @param {number} translationZ - Translation along Z axis.
 * @param {BABYLON.Scene} scene - The Babylon.js scene.
 * @param {BABYLON.ShadowGenerator} shadowGenerator - The shadow generator.
 * @param {Array<number>|null} wing_lights_pos - [x, y, z] position for wing lights, or null.
 * @param {Array<number>|null} tailcone_light_pos - [x, y, z] position for tail light, or null.
 * @param {Array<number>|null} strobe_light_pos - [x, y, z] position for strobe light, or null.
 * @param {Array<number>|null} propeller_pos - [x, y, z] position for propeller pivot, or null.
 * @param {number|null} propeller_diameter - Diameter of the propeller, or null.
 */
function loadGLB(
    file,
    scaleFactor,
    rotationX,
    rotationY,
    rotationZ,
    translationX,
    translationY,
    translationZ,
    scene,
    shadowGenerator,
    wing_lights_pos,
    tailcone_light_pos,
    strobe_light_pos,
    propeller_pos,
    propeller_diameter
) {
    if (!file || !scene) {
        console.error("File or scene not provided to loadGLB");
        return;
    }

    const reader = new FileReader();

    reader.onload = (event) => {
        try {
            const arrayBuffer = event.target.result;
            if (!arrayBuffer) {
                throw new Error("FileReader did not return an ArrayBuffer.");
            }

            const blob = new Blob([arrayBuffer], { type: "application/octet-stream" });
            const url = URL.createObjectURL(blob);

            console.log("Attempting to load GLB from URL:", url);

            // --- Clear previous model ---
            if (glbNode) {
                console.log("Disposing previous GLB model:", glbNode.name);
                glbNode.dispose(false, true); // Dispose hierarchy and materials
                glbNode = null;
            }

            // --- Ensure loaders are ready ---
            if (!BABYLON.SceneLoader) {
                console.error("SceneLoader not available. Make sure loaders library is included.");
                alert("Error: Babylon.js loaders are missing.");
                URL.revokeObjectURL(url);
                return;
            }

            // --- Load the GLB file using ImportMeshAsync ---
            BABYLON.SceneLoader.ImportMeshAsync("", url, "", scene, null, ".glb")
                .then((result) => {
                    if (result.meshes && result.meshes.length > 0) {
                        // --- Find Root Node ---
                        // Prefer __root__, otherwise create a new TransformNode to group meshes.
                        let rootNode = result.meshes.find(m => m.name === "__root__");
                        if (!rootNode) {
                            console.warn("GLB has no __root__ node. Creating a parent TransformNode.");
                            rootNode = new BABYLON.TransformNode("glbRoot_" + file.name, scene);
                            result.meshes.forEach(mesh => {
                                // Only parent top-level meshes to avoid double parenting
                                if (!mesh.parent) {
                                    mesh.parent = rootNode;
                                }
                            });
                        }
                        glbNode = rootNode; // Store reference to the new root
                        console.log("GLB loaded successfully. Root node:", glbNode.name);

                        // --- Apply Transformations to the Root Node ---
                        // Apply scaling first
                        glbNode.scaling = new BABYLON.Vector3(scaleFactor, scaleFactor, scaleFactor);
                        // Apply rotation (convert degrees to radians)
                        glbNode.rotationQuaternion = null; // Ensure we use Euler angles
                        glbNode.rotation = new BABYLON.Vector3(
                            BABYLON.Tools.ToRadians(rotationX),
                            BABYLON.Tools.ToRadians(rotationY),
                            BABYLON.Tools.ToRadians(rotationZ)
                        );
                        // Apply translation
                        glbNode.position = new BABYLON.Vector3(translationX, translationY, translationZ);

                        // <<< --- FIX: Apply corrective scaling for Z-axis flip --- >>>
                        glbNode.scaling.z *= -1;
                        // <<< --- END FIX --- >>>

                        // Parent the loaded GLB node to the main aircraft physics sphere
                        if (aircraft) {
                            glbNode.parent = aircraft;
                        } else {
                            console.warn("Aircraft physics body not found, GLB model might not move correctly.");
                        }

                        // Add all meshes in the hierarchy to the shadow generator
                        glbNode.getChildMeshes(true).forEach(mesh => { // true = include children of children
                            if (shadowGenerator) {
                                shadowGenerator.addShadowCaster(mesh);
                            }
                            mesh.receiveShadows = false; // Models usually don't receive shadows on themselves
                        });
                        // Check if rootNode itself is a mesh and add it
                        if (glbNode instanceof BABYLON.AbstractMesh && shadowGenerator) {
                            shadowGenerator.addShadowCaster(glbNode);
                            glbNode.receiveShadows = false;
                        }


                        // --- Disable Default Model & Handle Lights/Propeller ---
                        if (planeNode) {
                            // Disable the simple default aircraft visuals
                            planeNode.setEnabled(false);

                            // Handle wing lights
                            const rightWingLight = scene.getMeshByName("starboard_light");
                            const leftWingLight = scene.getMeshByName("port_light");
                            if (rightWingLight && leftWingLight) {
                                if (wing_lights_pos) {
                                    // Position relative to the *aircraft* (parent of glbNode)
                                    rightWingLight.position = new BABYLON.Vector3(
                                        wing_lights_pos[0], wing_lights_pos[1], -wing_lights_pos[2]
                                    );
                                    leftWingLight.position = new BABYLON.Vector3(
                                        wing_lights_pos[0], wing_lights_pos[1], wing_lights_pos[2]
                                    );
                                    // Ensure lights are parented correctly to move with aircraft
                                    rightWingLight.parent = aircraft;
                                    leftWingLight.parent = aircraft;
                                    rightWingLight.setEnabled(true);
                                    leftWingLight.setEnabled(true);
                                } else {
                                    rightWingLight.setEnabled(false);
                                    leftWingLight.setEnabled(false);
                                }
                            }

                            // Handle tail light
                            const tailconeLight = scene.getMeshByName("tailcone_light");
                            if (tailconeLight) {
                                if (tailcone_light_pos) {
                                    tailconeLight.position = new BABYLON.Vector3(
                                        tailcone_light_pos[0], tailcone_light_pos[1], tailcone_light_pos[2]
                                    );
                                    tailconeLight.parent = aircraft;
                                    tailconeLight.setEnabled(true);
                                } else {
                                    tailconeLight.setEnabled(false);
                                }
                            }

                            // Handle strobe light
                            const strobeLight = scene.getMeshByName("strobe_light");
                            if (strobeLight) {
                                if (strobe_light_pos) {
                                    strobeLight.position = new BABYLON.Vector3(
                                        strobe_light_pos[0], strobe_light_pos[1], strobe_light_pos[2]
                                    );
                                    strobeLight.parent = aircraft;
                                    strobeLight.setEnabled(true);
                                } else {
                                    strobeLight.setEnabled(false);
                                }
                            }

                            // Handle propeller
                            const propellerPivot = scene.getTransformNodeByName("propellerPivot");
                            if (propellerPivot) {
                                if (propeller_pos && propeller_diameter) {
                                    propellerPivot.position = new BABYLON.Vector3(
                                        propeller_pos[0], propeller_pos[1], propeller_pos[2]
                                    );
                                    // Rebuild the blade mesh at the requested physical diameter,
                                    // keeping the pivot at scale 1. This replaces the old
                                    // "pivot.scaling = ratio" approach AND the name-based
                                    // `scene.getMeshByName("blade1")` lookup that used to
                                    // accidentally dispose windmill blades when multiple
                                    // meshes in the scene shared the "blade1" name.
                                    propellerPivot.scaling = new BABYLON.Vector3(1, 1, 1);
                                    rebuildPropellerBlades(scene, propellerPivot, propeller_diameter, shadowGenerator);
                                    propellerPivot.parent = aircraft;
                                    propellerPivot.setEnabled(true);
                                } else {
                                    propellerPivot.setEnabled(false);
                                }
                            }
                        } else {
                            console.warn("planeNode (default aircraft) not found. Cannot disable it or reposition lights/propeller.");
                        }


                        // --- Frame Camera ---
                        const camera = scene.activeCamera;
                        if (camera && camera.zoomOn && glbNode) {
                            try {
                                // Delay zoomOn slightly to ensure bounding box is calculated
                                setTimeout(() => {
                                    camera.zoomOnFactor = 1.5; // Add padding
                                    camera.zoomOn([glbNode], true);
                                    console.log("Camera framed on loaded GLB model.");
                                }, 100); // 100ms delay
                            } catch (zoomError) {
                                console.error("Error during camera.zoomOn:", zoomError);
                                // Fallback: Manually set target
                                const centerPoint = glbNode.getAbsolutePosition();
                                camera.setTarget(centerPoint);
                                camera.radius = (glbNode.getBoundingInfo()?.boundingSphere.radiusWorld * 2) || 10; // Adjust radius based on model size, added optional chaining
                                console.warn("zoomOn failed, attempting manual camera target.");
                            }
                        } else {
                            console.warn("Could not get active camera or GLB root reference to frame.");
                        }

                        if (result.animationGroups && result.animationGroups.length > 0) {
                            console.log(`Starting ${result.animationGroups.length} animation groups.`);
                            result.animationGroups.forEach(ag => ag.play(true)); // Play all animations looping
                        }

                        // --- FIX: Reset physics deltaTime counter after a freezing block of loading ---
                        if (typeof window.resetServerDataTimer === 'function') {
                            window.resetServerDataTimer();
                        }

                    } else {
                        console.warn("GLB loaded, but no meshes found in the result.");
                    }
                    URL.revokeObjectURL(url); // Clean up the object URL
                })
                .catch((error) => {
                    console.error("Error loading GLB using ImportMeshAsync:", error);
                    alert(`Error loading GLB file: ${error.message || error}`);
                    URL.revokeObjectURL(url); // Clean up URL even on error
                    // Re-enable default plane if GLB fails to load?
                    if (planeNode) planeNode.setEnabled(true);

                });

        } catch (loadError) {
            console.error("Error processing file for loading:", loadError);
            alert(`Error processing file: ${loadError.message}`);
            // Re-enable default plane if file processing fails?
            if (planeNode) planeNode.setEnabled(true);
        }
    };

    reader.onerror = (error) => {
        console.error("FileReader error:", error);
        alert("Error reading file.");
        // Re-enable default plane if file reading fails?
        if (planeNode) planeNode.setEnabled(true);
    };

    reader.readAsArrayBuffer(file); // Read the file as binary data
}
