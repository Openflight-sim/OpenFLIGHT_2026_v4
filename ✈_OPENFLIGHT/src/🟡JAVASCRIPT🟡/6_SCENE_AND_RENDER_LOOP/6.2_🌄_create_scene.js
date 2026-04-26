

/***************************************************************
 * 6.2_🌄_create_scene.js  — COMPLETE, FIXED
 *
 * • Publishes the freshly‑created Babylon `scene` to
 * `window.scene` as soon as it exists so helper modules
 * loaded during construction can reference it.
 * • Otherwise identical to your original, so nothing goes
 * missing.
 * • *** ADDED: Explicit creation of velocity/force lines during setup. ***
 ***************************************************************/

/**
 * Creates and initializes a complete 3D scene.
 * @param {BABYLON.Engine} engine - Babylon engine.
 * @param {HTMLCanvasElement} canvas - The render canvas.
 * @returns {BABYLON.Scene} The initialized scene.
 */
function createScene(engine, canvas) {
    /*--------------------------------------------------------*/
    const scene = initializeBaseScene(engine);
    window.scene = scene;               // <-- publish early
    /*--------------------------------------------------------*/

    /* Physics first */
    scene.enablePhysics(
        new BABYLON.Vector3(0, -9.81, 0),
        new BABYLON.CannonJSPlugin()
    );

    /* Lights, cameras, world, aircraft, GUI… */
    const sceneElements = setupSceneElements(scene, canvas);

    /* GLB loader & picking helpers */
    setupInteractions(scene, sceneElements.shadowGenerator);

    /* Per‑frame callbacks (sky‑sphere etc.) */
    setupRenderLoop(scene);

    return scene;
}

/*================================================================
 * BELOW THIS LINE: original helper functions (unchanged except
 * for any comments).  Keep them all so nothing goes undefined.
 *================================================================*/

/*--------------------------------------------------------------*/
function initializeBaseScene(engine) {
    const scene = new BABYLON.Scene(engine);
    if (typeof getEnvironmentClearColor === "function") {
        scene.clearColor = getEnvironmentClearColor();
    } else if (typeof game_environment !== 'undefined' && (game_environment === "night" || game_environment === "dusk")) {
        scene.clearColor = new BABYLON.Color4(0.018, 0.022, 0.040, 1.0);
    } else {
        scene.clearColor = new BABYLON.Color4(180 / 255, 206 / 255, 255 / 255, 1.0);
    }
    return scene;
}

/*--------------------------------------------------------------*/
function setupSceneElements(scene, canvas) {
    const { lights, shadowGenerator } = setupLights_and_shadows(scene);
    const cameras = setupCameras(scene, canvas);
    createAircraft(shadowGenerator, scene);
    createWorldScenery(scene, shadowGenerator, cameras.arcRotateCamera);
    setupVisualizationElements(scene); // <= This function is modified below
    window.shadowGenerator = shadowGenerator;  // expose for visual_geometry handler
    return { lights, shadowGenerator, cameras };
}

function setupVisualizationElements(scene) { // scene is already a parameter here
    initializeTrajectorySystem(scene);
    createGUI(scene); // Assuming createGUI might also need scene

    // === MODIFIED CALLS ===
    // Pass the 'scene' object explicitly
    if (typeof createVelocityLine === 'function') {
        createVelocityLine(scene); // Pass scene
    } else {
        console.error("createVelocityLine function is not defined!");
    }
    if (typeof createForceLine === 'function') {
        createForceLine(scene); // Always create force arrows; visibility is data-driven.
    } else {
        console.error("createForceLine function is not defined!");
    }
    // === END MODIFIED CALLS ===
}

/*--------------------------------------------------------------*/
function setupInteractions(scene, shadowGenerator) {
    setup_GLB_model_transformations(scene, shadowGenerator);
    setupPickingCoordinates(scene);
}

/*--------------------------------------------------------------*/
function setupPickingCoordinates(scene) {
    scene.onPointerObservable.add((pointerInfo) => {
        handlePickingEvent(scene, pointerInfo);
    });
}

/*--------------------------------------------------------------*/
function handlePickingEvent(scene, pointerInfo) {
    if (pointerInfo.type !== BABYLON.PointerEventTypes.POINTERDOWN) return;

    const pick = scene.pick(pointerInfo.event.clientX, pointerInfo.event.clientY);
    if (pick.hit && pick.pickedPoint) {
        logPickedCoordinates(pick.pickedPoint);
    }
}

/*--------------------------------------------------------------*/
function logPickedCoordinates(p) {
    console.log(`Picked  x:${p.x.toFixed(3)}  y:${p.y.toFixed(3)}  z:${p.z.toFixed(3)}`);
}

/*--------------------------------------------------------------*/
function setupRenderLoop(scene) {
    scene.onBeforeRenderObservable.add(() => {
        updateSkySphereDiameter(scene, scene.activeCamera);
    });
}
