

/***************************************************************
 * Creates a large sky sphere with a vertical gradient texture.
 * Automatically positions it based on the active camera.
 **************************************************************/
const DEFAULT_SKY_SPHERE_DIAMETER = 12000;
const LOW_DETAIL_SKY_DIAMETER_MARGIN = 2000;
const FALLBACK_LOW_DETAIL_GROUND_BOARD_SIZE = 15000;
const NIGHT_SKY_CLEAR_COLOR = new BABYLON.Color4(0.008, 0.011, 0.020, 1.0);
const DUSK_SKY_CLEAR_COLOR = new BABYLON.Color4(0.010, 0.012, 0.020, 1.0);
const DAY_SKY_CLEAR_COLOR = new BABYLON.Color4(180 / 255, 206 / 255, 255 / 255, 1.0);
const NIGHT_FOG_COLOR = new BABYLON.Color3(0.014, 0.018, 0.030);
const DUSK_FOG_COLOR = new BABYLON.Color3(0.105, 0.112, 0.135);

function _getLowDetailGroundBoardSize() {
    if (
        typeof window !== "undefined" &&
        Number.isFinite(window.lowDetailGroundBoardSize) &&
        window.lowDetailGroundBoardSize > 0
    ) {
        return window.lowDetailGroundBoardSize;
    }

    const groundRoot = (typeof window !== "undefined") ? window.ground : null;
    if (
        groundRoot &&
        groundRoot.metadata &&
        Number.isFinite(groundRoot.metadata.boardSize) &&
        groundRoot.metadata.boardSize > 0
    ) {
        return groundRoot.metadata.boardSize;
    }

    return FALLBACK_LOW_DETAIL_GROUND_BOARD_SIZE;
}

function _getCameraWorldPosition(camera) {
    if (
        camera &&
        camera.globalPosition &&
        Number.isFinite(camera.globalPosition.x) &&
        Number.isFinite(camera.globalPosition.y) &&
        Number.isFinite(camera.globalPosition.z)
    ) {
        return camera.globalPosition;
    }

    if (
        camera &&
        camera.position &&
        Number.isFinite(camera.position.x) &&
        Number.isFinite(camera.position.y) &&
        Number.isFinite(camera.position.z)
    ) {
        return camera.position;
    }

    return null;
}

function _normalizedEnvironment() {
    return (typeof game_environment !== "undefined" && game_environment)
        ? String(game_environment).trim().toLowerCase()
        : "day";
}

function _isNightSkyEnvironment() {
    const environment = _normalizedEnvironment();
    return environment === "night" || environment === "dusk";
}

function getEnvironmentClearColor() {
    const environment = _normalizedEnvironment();
    if (environment === "night") return NIGHT_SKY_CLEAR_COLOR.clone();
    if (environment === "dusk") return DUSK_SKY_CLEAR_COLOR.clone();
    return DAY_SKY_CLEAR_COLOR.clone();
}

function _createSolidSkyMaterial(scene, materialName, color) {
    const material = new BABYLON.StandardMaterial(materialName, scene);
    material.backFaceCulling = false;
    material.diffuseColor = BABYLON.Color3.Black();
    material.emissiveColor = color.clone ? color.clone() : color;
    material.disableLighting = true;
    material.disableDepthWrite = true;
    material.fogEnabled = _normalizedEnvironment() === "dusk";
    material.specularColor = BABYLON.Color3.Black();
    return material;
}

function _setMaterialFogEnabled(material, enabled) {
    if (!material || typeof material.fogEnabled === "undefined") {
        return;
    }
    material.fogEnabled = enabled;
}

function _enforceDuskFogOnSceneMaterials(scene) {
    if (!scene || _normalizedEnvironment() !== "dusk") {
        return;
    }

    scene.materials.forEach((material) => {
        _setMaterialFogEnabled(material, true);
    });
}

function _installDuskFogMaterialObserver(scene) {
    if (
        !scene ||
        scene._duskFogMaterialObserverInstalled ||
        !scene.onNewMaterialAddedObservable ||
        typeof scene.onNewMaterialAddedObservable.add !== "function"
    ) {
        return;
    }

    scene._duskFogMaterialObserverInstalled = true;
    scene.onNewMaterialAddedObservable.add((material) => {
        if (_normalizedEnvironment() === "dusk") {
            _setMaterialFogEnabled(material, true);
        }
    });
}

function _getSkyTextureSource() {
    const environment = _normalizedEnvironment();

    if (environment === "dusk") {
        return null;
    }

    if (environment === "night") {
        if (typeof NIGHT_SKY_DOME_B64 !== "undefined" && NIGHT_SKY_DOME_B64) {
            return NIGHT_SKY_DOME_B64;
        }
        return "./assets/night_sky.jpg";
    }

    if (environment === "sunny") {
        if (typeof DAY_SKY_B64 !== "undefined" && DAY_SKY_B64) {
            return DAY_SKY_B64;
        }
        return "./assets/day_sky.jpg";
    }

    return null;
}

function _createDuskSkyTexture(scene) {
    const width = 1024;
    const height = 512;
    const texture = new BABYLON.DynamicTexture("duskSkyTexture", { width, height }, scene, false);
    const context = texture.getContext();

    const skyGradient = context.createLinearGradient(0, 0, 0, height);
    skyGradient.addColorStop(0.00, "#050711");
    skyGradient.addColorStop(0.52, "#0a0d18");
    skyGradient.addColorStop(0.78, "#111520");
    skyGradient.addColorStop(1.00, "#171a22");
    context.fillStyle = skyGradient;
    context.fillRect(0, 0, width, height);

    const lowCloudGradient = context.createLinearGradient(0, Math.round(height * 0.56), 0, height);
    lowCloudGradient.addColorStop(0.00, "rgba(18, 20, 30, 0)");
    lowCloudGradient.addColorStop(0.55, "rgba(42, 40, 42, 0.18)");
    lowCloudGradient.addColorStop(1.00, "rgba(13, 16, 25, 0.35)");
    context.fillStyle = lowCloudGradient;
    context.fillRect(0, Math.round(height * 0.52), width, Math.round(height * 0.48));

    texture.update(false);
    texture.hasAlpha = false;
    return texture;
}

function getSkySphereDiameter(camera, sceneryComplexity) {
    if (!(typeof sceneryComplexity !== "undefined" && sceneryComplexity <= 0)) {
        return DEFAULT_SKY_SPHERE_DIAMETER;
    }

    const boardSize = _getLowDetailGroundBoardSize();
    const halfBoard = boardSize / 2;
    const minDiameter = Math.ceil(boardSize * Math.SQRT2 + LOW_DETAIL_SKY_DIAMETER_MARGIN);
    const cameraPos = _getCameraWorldPosition(camera);

    if (!cameraPos) {
        return Math.max(DEFAULT_SKY_SPHERE_DIAMETER, minDiameter);
    }

    const boardCorners = [
        [-halfBoard, -halfBoard],
        [-halfBoard, halfBoard],
        [halfBoard, -halfBoard],
        [halfBoard, halfBoard],
    ];

    let maxCornerDistance = 0;
    for (const [cornerX, cornerZ] of boardCorners) {
        const dx = cornerX - cameraPos.x;
        const dy = -cameraPos.y;
        const dz = cornerZ - cameraPos.z;
        const cornerDistance = Math.sqrt(dx * dx + dy * dy + dz * dz);
        maxCornerDistance = Math.max(maxCornerDistance, cornerDistance);
    }

    return Math.max(
        DEFAULT_SKY_SPHERE_DIAMETER,
        minDiameter,
        Math.ceil(2 * maxCornerDistance + LOW_DETAIL_SKY_DIAMETER_MARGIN)
    );
}

function createSkySphere(scene, camera, sceneryComplexity) {
    const skyDiameter = getSkySphereDiameter(camera, sceneryComplexity);
    scene.clearColor = getEnvironmentClearColor();

    // Create a sphere (with inverted normals) to serve as the sky dome.
    const skySphere = BABYLON.MeshBuilder.CreateSphere(
        "skySphere",
        {
            diameter: skyDiameter,
            segments: 16, // <--- Added this line. Lower value = fewer triangles.
            sideOrientation: BABYLON.Mesh.BACKSIDE
        },
        scene
    );
    skySphere.metadata = {
        initialDiameter: skyDiameter,
        followsCamera: true
    };
    skySphere.isPickable = false;
    skySphere.checkCollisions = false;
    skySphere.receiveShadows = false;
    skySphere.alwaysSelectAsActiveMesh = true;
    skySphere.renderingGroupId = 0;
    skySphere.position.copyFrom(_getCameraWorldPosition(camera) || BABYLON.Vector3.Zero());
    scene._skySphere = skySphere;

    const environment = _normalizedEnvironment();
    const useDuskProceduralSky = environment === "dusk";
    const skyTextureSource = _getSkyTextureSource();
    if (!skyTextureSource && !useDuskProceduralSky) {
        // Fog/Day mode (or fallback): Skip texture loading for performance
        // Return early with a very basic solid color material
        const fogMaterial = _createSolidSkyMaterial(
            scene,
            "fogSkyMaterial",
            new BABYLON.Color3(180 / 255, 206 / 255, 255 / 255)
        );

        skySphere.material = fogMaterial;
        return skySphere;
    }

    const fallbackSkyColor = environment === "night"
        ? new BABYLON.Color3(0.010, 0.012, 0.022)
        : environment === "dusk"
            ? new BABYLON.Color3(0.010, 0.012, 0.020)
            : new BABYLON.Color3(180 / 255, 206 / 255, 255 / 255);

    skySphere.material = _createSolidSkyMaterial(scene, "skyFallbackMaterial", fallbackSkyColor);

    const skyTexture = useDuskProceduralSky
        ? _createDuskSkyTexture(scene)
        : new BABYLON.Texture(skyTextureSource, scene);

    // MeshBuilder.CreateSphere already supplies equirectangular UVs. Using
    // spherical reflection coordinates can smear the bright moon across the
    // dome and wash the sky toward white.
    if (typeof BABYLON.Texture.EXPLICIT_MODE !== "undefined") {
        skyTexture.coordinatesMode = BABYLON.Texture.EXPLICIT_MODE;
    }
    skyTexture.hasAlpha = false;
    skyTexture.wrapU = BABYLON.Texture.CLAMP_ADDRESSMODE;
    skyTexture.wrapV = BABYLON.Texture.CLAMP_ADDRESSMODE;
    skyTexture.level = environment === "night" ? 0.20 : environment === "dusk" ? 0.90 : 1.0;

    // Create a material that uses the gradient texture.
    const skyMaterial = new BABYLON.StandardMaterial("skyMaterial", scene);
    skyMaterial.backFaceCulling = false;  // Render the inside of the sphere.
    skyMaterial.diffuseColor = BABYLON.Color3.Black();
    skyMaterial.emissiveTexture = skyTexture;
    skyMaterial.disableLighting = true;
    skyMaterial.disableDepthWrite = true;
    skyMaterial.fogEnabled = environment === "dusk";
    skyMaterial.specularColor = BABYLON.Color3.Black();
    if (skyTexture.onErrorObservable && typeof skyTexture.onErrorObservable.addOnce === "function") {
        skyTexture.onErrorObservable.addOnce(() => {
            skySphere.material = _createSolidSkyMaterial(scene, "skyTextureErrorMaterial", fallbackSkyColor);
            console.warn("Sky texture failed to load; using dark fallback sky.", skyTextureSource);
        });
    }
    skyTexture.onError = () => {
        skySphere.material = _createSolidSkyMaterial(scene, "skyTextureErrorMaterial", fallbackSkyColor);
        console.warn("Sky texture failed to load; using dark fallback sky.", skyTextureSource);
    };

    // Apply the material to the sky sphere.
    skySphere.material = skyMaterial;

    // Adjust brightness based on the environment
    if (environment === "night") {
        skyMaterial.emissiveColor = new BABYLON.Color3(0.16, 0.18, 0.24);
    } else if (environment === "dusk") {
        skyMaterial.emissiveColor = new BABYLON.Color3(0.70, 0.72, 0.82);
    } else {
        skyMaterial.emissiveColor = new BABYLON.Color3(1, 1, 1); // Full brightness for daytime
    }
    skySphere.position.copyFrom(_getCameraWorldPosition(camera) || BABYLON.Vector3.Zero());

    // Optionally rotate the sky sphere to align the sun position or horizon.
    skySphere.rotation.x = 0; // Fixed from Math.PI/2 which was turning the horizon 90 degrees
    skySphere.rotation.y = 0;
    skySphere.rotation.z = Math.PI; // Flip upright if the texture is inverted

    return skySphere;
}


/**
 * Keeps the sky dome centered on the active camera. This avoids clipping and
 * horizon shimmer without resizing the sphere every frame.
 * @param {BABYLON.Scene} scene - The Babylon scene.
 * @param {BABYLON.Camera} camera - The currently active camera.
 */
function updateSkySphereDiameter(scene, camera) {
    const skySphere = scene._skySphere || scene.getMeshByName("skySphere");
    if (
        !skySphere ||
        !skySphere.metadata ||
        !Number.isFinite(skySphere.metadata.initialDiameter) ||
        skySphere.metadata.initialDiameter <= 0
    ) {
        return;
    }

    const cameraPos = _getCameraWorldPosition(camera);
    if (!cameraPos) {
        return;
    }

    skySphere.position.copyFrom(cameraPos);
}


function create_fog(scene) {
    // Fog is a "looks like a sim" extra, not a low-spec feature. Turn it
    // on at scenery_complexity >= 2 (same threshold that unlocks buildings
    // and the animated water surface in 4.1_🌍_create_world_scenery.js).
    // The previous guard was `< 4`, which was always true for the
    // documented 0-3 range and silently disabled fog everywhere.
    const environment = _normalizedEnvironment();
    if (environment !== "dusk" && typeof scenery_complexity !== 'undefined' && scenery_complexity < 2) {
        scene.fogMode = BABYLON.Scene.FOGMODE_NONE;
        return;
    }

    if (environment === "night") {
        scene.fogMode = BABYLON.Scene.FOGMODE_NONE; // Disable fog by default in strict night mode
    } else if (environment === "dusk") {
        scene.fogMode = BABYLON.Scene.FOGMODE_LINEAR;
        scene.fogStart = 60.0;
        scene.fogEnd = 1850.0;
        scene.fogColor = DUSK_FOG_COLOR.clone();
        _enforceDuskFogOnSceneMaterials(scene);
        _installDuskFogMaterialObserver(scene);
    } else if (environment === "sunny") {
        // Enable a very thin fog for the sunny mode.
        // The massive distance between 1000 and 100,000 means objects at 3,000 units
        // barely have 1% of fog applied to them, making it look incredibly thin.
        scene.fogMode = BABYLON.Scene.FOGMODE_LINEAR;
        scene.fogStart = 400.0;
        scene.fogEnd = 5000.0; // Pushed VERY far back to make the fog incredibly thin over distance
        scene.fogColor = new BABYLON.Color3(160 / 255, 170 / 255, 200 / 255); // Color matching the sky dome
    } else {
        // Enable linear fog for day/fog environments.
        scene.fogMode = BABYLON.Scene.FOGMODE_LINEAR;
        scene.fogStart = 300.0; // Start distance of fog effect
        scene.fogEnd = 2800.0; // Full fog effect distance
        scene.fogColor = new BABYLON.Color3(180 / 255, 206 / 255, 255 / 255); // Light blueish fog blending with the sky horizon
    }
}
