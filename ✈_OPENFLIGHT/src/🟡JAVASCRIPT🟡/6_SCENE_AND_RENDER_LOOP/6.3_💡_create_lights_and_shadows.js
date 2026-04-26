/**
 * Sets up all lighting components including hemispheric lights, directional light,
 * and shadow generation for a Babylon.js scene.
 * @param {BABYLON.Scene} scene - The Babylon.js scene to add lighting to
 * @returns {{lights: {mainHemisphericLight: BABYLON.HemisphericLight, ambientHemisphericLight: BABYLON.HemisphericLight, sunDirectionalLight: BABYLON.DirectionalLight}, shadowGenerator: BABYLON.CascadedShadowGenerator}}
 */
function setupLights_and_shadows(scene) {
    // Hemispheric Lighting Setup
    const mainHemisphericLight = new BABYLON.HemisphericLight(
        "mainHemisphericLight",
        new BABYLON.Vector3(0, 1, 0), // Direction vector (positive Y-axis)
        scene
    );

    // Secondary ambient light for fill-in illumination from below
    const ambientHemisphericLight = new BABYLON.HemisphericLight(
        "ambientHemisphericLight",
        new BABYLON.Vector3(0, -1, 0), // Direction vector (negative Y-axis)
        scene
    );

    // Directional Light (Sun/Moon) Setup
    const sunDirectionalLight = new BABYLON.DirectionalLight(
        "sunDirectionalLight",
        new BABYLON.Vector3(-1, -2, -1), // Light direction vector (-X, -Y, -Z)
        scene
    );
    sunDirectionalLight.position = new BABYLON.Vector3(5, 10, 5); // Position relative to scene origin

    if (typeof game_environment !== 'undefined' && (game_environment === "night" || game_environment === "dusk")) {
        mainHemisphericLight.intensity = 0.05;
        mainHemisphericLight.diffuse = new BABYLON.Color3(0.4, 0.45, 0.6);

        ambientHemisphericLight.intensity = 0.05;
        ambientHemisphericLight.diffuse = new BABYLON.Color3(0.2, 0.25, 0.4);

        sunDirectionalLight.intensity = 0.2;
        sunDirectionalLight.diffuse = new BABYLON.Color3(0.8, 0.85, 1.0); // Soft moon/dusk light
    } else {
        mainHemisphericLight.intensity = 0.3;
        mainHemisphericLight.diffuse = new BABYLON.Color3(1, 0.98, 0.8); // Warm white light

        ambientHemisphericLight.intensity = 0.4;
        ambientHemisphericLight.diffuse = new BABYLON.Color3(1, 0.98, 0.8);

        sunDirectionalLight.intensity = 0.9;
    }

    // Shadow Generation Setup
    //
    // Shadows are the single most expensive per-frame rendering cost (cascaded
    // shadow map passes + per-caster depth draws). Keep them for an explicit
    // ultra setting only; scenery_complexity=3 should remain flyable on normal
    // hardware. The rest of the scene code calls addShadowCaster(mesh) on many
    // meshes, so return a silent no-op stub instead of null.
    let shadowGenerator;
    if (typeof scenery_complexity !== 'undefined' && scenery_complexity < 4) {
        shadowGenerator = {
            addShadowCaster: function () {},
            removeShadowCaster: function () {}
        };
    } else {
        shadowGenerator = new BABYLON.CascadedShadowGenerator(2048, sunDirectionalLight);

        // Configure shadow cascades (adjust for optimal performance/balance)
        shadowGenerator.numCascades = 4; // Number of shadow cascade levels

        // Configure shadow properties
        shadowGenerator.lambda = 0.5; // Balance between linear and logarithmic distribution
        shadowGenerator.shadowMaxZ = 1000; // Maximum distance for shadows (increase if needed)
        shadowGenerator.stabilizeCascades = true; // Prevent shadow "shimmering" artifacts

        shadowGenerator.bias = 0.001; // adjust this value as needed

        // Configure directional light's shadow settings (only meaningful when
        // a real shadow generator is attached to the sun light).
        sunDirectionalLight.shadowMinZ = 1; // Minimum distance for shadows
        sunDirectionalLight.shadowMaxZ = 100; // Maximum shadow casting range
        sunDirectionalLight.autoCalcShadowZBounds = true; // Enable automatic shadow bounds calculation
    }

    return {
        lights: { mainHemisphericLight, ambientHemisphericLight, sunDirectionalLight },
        shadowGenerator
    };
}
