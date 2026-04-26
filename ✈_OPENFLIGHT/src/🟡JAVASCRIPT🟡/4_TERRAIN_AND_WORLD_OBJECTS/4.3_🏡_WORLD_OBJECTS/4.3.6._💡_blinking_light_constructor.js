// Shared glow helpers. Babylon's GlowLayer is a post-process, so an
// emissive marker can bloom through nearer geometry unless we remove it
// from the layer when it is not visible from the active camera.
(function () {
    if (typeof window === "undefined" || window.getOpenFlightSharedGlowLayer) {
        return;
    }

    const DEFAULT_OCCLUSION_CLEARANCE_M = 0.08;

    function ensureGlowKeepaliveMesh(scene, glowLayer) {
        if (!scene || !glowLayer || glowLayer._openFlightKeepaliveMesh) return;

        const keepalive = BABYLON.MeshBuilder.CreateSphere(
            "openflightGlowKeepalive",
            { diameter: 0.01, segments: 4 },
            scene
        );
        keepalive.isVisible = false;
        keepalive.isPickable = false;
        keepalive._openFlightGlowLightMarker = true;

        const mat = new BABYLON.StandardMaterial("openflightGlowKeepaliveMaterial", scene);
        mat.emissiveColor = BABYLON.Color3.Black();
        mat.diffuseColor = BABYLON.Color3.Black();
        mat.specularColor = BABYLON.Color3.Black();
        keepalive.material = mat;

        glowLayer.addIncludedOnlyMesh(keepalive);
        glowLayer._openFlightKeepaliveMesh = keepalive;
    }

    window.getOpenFlightSharedGlowLayer = function (scene, intensity = 1.0) {
        if (!scene) return null;
        let glowLayer = scene.getGlowLayerByName("sharedGlowLayer");
        if (!glowLayer) {
            glowLayer = new BABYLON.GlowLayer("sharedGlowLayer", scene, {
                mainTextureRatio: 0.5
            });
            glowLayer.intensity = intensity;
            console.log("Created shared GlowLayer with intensity:", glowLayer.intensity);
        } else if (Number.isFinite(intensity)) {
            glowLayer.intensity = Math.max(glowLayer.intensity || 0, intensity);
        }
        ensureGlowKeepaliveMesh(scene, glowLayer);
        return glowLayer;
    };

    function meshOrAncestorIsGlowMarker(mesh) {
        let node = mesh;
        while (node) {
            if (node._openFlightGlowLightMarker) return true;
            node = node.parent;
        }
        return false;
    }

    function isCandidateOccluder(mesh) {
        if (!mesh || meshOrAncestorIsGlowMarker(mesh)) return false;
        if (typeof mesh.isEnabled === "function" && !mesh.isEnabled(true)) return false;
        if (mesh.isVisible === false) return false;
        if (typeof mesh.visibility === "number" && mesh.visibility <= 0.01) return false;
        if (mesh.material && typeof mesh.material.alpha === "number" && mesh.material.alpha <= 0.05) return false;
        return true;
    }

    window.isOpenFlightGlowMeshVisibleFromCamera = function (
        scene,
        mesh,
        clearanceM = DEFAULT_OCCLUSION_CLEARANCE_M
    ) {
        if (!scene || !mesh || !scene.activeCamera || typeof BABYLON === "undefined") return true;
        if (typeof mesh.isEnabled === "function" && !mesh.isEnabled(true)) return false;
        if (mesh.isVisible === false) return false;

        const camera = scene.activeCamera;
        if (typeof camera.computeWorldMatrix === "function") {
            camera.computeWorldMatrix(true);
        }
        const cameraPosition = camera.globalPosition || camera.position;
        const meshPosition = mesh.getAbsolutePosition ? mesh.getAbsolutePosition() : mesh.position;
        if (!cameraPosition || !meshPosition) return true;

        const direction = meshPosition.subtract(cameraPosition);
        const distance = direction.length();
        const rayLength = distance - Math.max(0, clearanceM);
        if (!Number.isFinite(distance) || rayLength <= 0.02) return true;

        direction.normalize();
        const ray = new BABYLON.Ray(cameraPosition, direction, rayLength);
        const pick = scene.pickWithRay(ray, isCandidateOccluder, true);
        return !(pick && pick.hit);
    };

    window.updateOpenFlightGlowMesh = function (scene, glowLayer, mesh, shouldGlow, state, clearanceM) {
        if (!glowLayer || !mesh || !state) return;
        const visible = shouldGlow &&
            window.isOpenFlightGlowMeshVisibleFromCamera(scene, mesh, clearanceM);
        if (visible && !state.inGlowLayer) {
            glowLayer.addIncludedOnlyMesh(mesh);
            state.inGlowLayer = true;
        } else if (!visible && state.inGlowLayer) {
            glowLayer.removeIncludedOnlyMesh(mesh);
            state.inGlowLayer = false;
        }
    };
})();

function createBlinkingSphere(scene, x, y, z, options = {}) {
    const defaults = {
        sphereColor: new BABYLON.Color3(1, 0, 0),
        diameter: 4,
        lightRange: 10,
        blinkInterval: 1000, // Time for ON phase or total cycle if waitingInterval is null
        lightIntensity: 1,
        glowIntensity: 1, // Target global intensity for the layer (used if layer is created AND enabled)
        waitingInterval: null, // Time for OFF phase (if specified)
        number_of_blinks: null, // Number of blinks before waiting
        name: "blinkingSphere",
        createPointLight: true, // Option to skip PointLight creation
        glowOcclusionClearance: 0.08
    };

    const settings = { ...defaults, ...options };

    // --- Sphere Mesh and Material ---
    const sphere = BABYLON.MeshBuilder.CreateSphere(settings.name, {
        diameter: settings.diameter,
        segments: 8 // Reduced segments for performance if many spheres
    }, scene);

    sphere.position = new BABYLON.Vector3(x, y, z);
    sphere.isPickable = false; // Usually not needed for lights
    sphere._openFlightGlowLightMarker = true;

    const sphereMaterial = new BABYLON.StandardMaterial(settings.name + "Material", scene);
    sphereMaterial.emissiveColor = new BABYLON.Color3(0, 0, 0); // Start off
    sphereMaterial.diffuseColor = new BABYLON.Color3(0, 0, 0);
    sphereMaterial.specularColor = new BABYLON.Color3(0, 0, 0);
    sphereMaterial.fogEnabled = true;
    sphere.material = sphereMaterial;

    // --- Optional Point Light ---
    let light = null;
    if (settings.createPointLight) {
        light = new BABYLON.PointLight(settings.name + "Light", sphere.position, scene);
        light.intensity = 0; // Start off
        light.diffuse = settings.sphereColor;
        light.range = settings.lightRange;
    }

    // --- Optional Shared Glow Layer ---
    let glowLayer = null; // Initialize glowLayer as null

    // Check the global setting BEFORE attempting to use the glow layer
    // (Assuming 'enable_glow_effect' is a global variable set in initializations.js)
    if (typeof enable_glow_effect !== 'undefined' && enable_glow_effect === true && typeof scenery_complexity !== 'undefined' && scenery_complexity === 4) {
        glowLayer = typeof window.getOpenFlightSharedGlowLayer === 'function'
            ? window.getOpenFlightSharedGlowLayer(scene, settings.glowIntensity)
            : null;
    } else {
        // console.log("Glow effect is disabled globally."); // Optional log
    }
    // END Optional Shared Glow Layer

    // --- Animation Logic ---
    let isOn = false;
    const glowState = { inGlowLayer: false };
    let startTime = Date.now();
    let observer = null;

    function updateGlowVisibility() {
        if (glowLayer && typeof window.updateOpenFlightGlowMesh === 'function') {
            window.updateOpenFlightGlowMesh(
                scene,
                glowLayer,
                sphere,
                isOn,
                glowState,
                settings.glowOcclusionClearance
            );
        }
    }

    function setLightState(shouldBeOn) {
        if (isOn === shouldBeOn) {
            updateGlowVisibility();
            return;
        }

        const targetEmissive = shouldBeOn ? settings.sphereColor : BABYLON.Color3.Black();
        const targetLightIntensity = shouldBeOn ? settings.lightIntensity : 0;

        sphereMaterial.emissiveColor = targetEmissive;

        if (light) {
            light.intensity = targetLightIntensity;
        }

        isOn = shouldBeOn;
        updateGlowVisibility();
    }

    // --- Blinking Timer Logic (unchanged) ---
    if (settings.blinkInterval >= 0) {
        observer = scene.onBeforeRenderObservable.add(() => {
            const currentTime = Date.now();
            const elapsedTime = currentTime - startTime;

            if (settings.number_of_blinks !== null && settings.waitingInterval !== null) {
                const blinkCycleTime = settings.blinkInterval * 2;
                const totalBlinkTime = blinkCycleTime * settings.number_of_blinks;
                const totalCycleTime = totalBlinkTime + settings.waitingInterval;
                const timeInMainCycle = elapsedTime % totalCycleTime;

                if (timeInMainCycle < totalBlinkTime) {
                    const timeInBlinkSubCycle = timeInMainCycle % blinkCycleTime;
                    const shouldBeOn = timeInBlinkSubCycle < settings.blinkInterval;
                    setLightState(shouldBeOn);
                } else {
                    setLightState(false);
                }
            } else if (settings.waitingInterval !== null) {
                const totalCycleTime = settings.waitingInterval + settings.blinkInterval;
                const timeInCycle = elapsedTime % totalCycleTime;
                const shouldBeOn = timeInCycle >= settings.waitingInterval;
                setLightState(shouldBeOn);
            } else {
                const shouldBeOn = (currentTime % (settings.blinkInterval * 2)) < settings.blinkInterval;
                setLightState(shouldBeOn);
            }
            updateGlowVisibility();
        });
    } else {
        setLightState(true); // Always on if blinkInterval is negative
        if (glowLayer) {
            observer = scene.onBeforeRenderObservable.add(updateGlowVisibility);
        }
    }

    // Return object with a dispose function
    return {
        sphere,
        light, // Might be null
        // glowLayer, // No need to return the shared layer reference here
        dispose: () => {
            if (observer) {
                scene.onBeforeRenderObservable.remove(observer);
            }
            // ** Dispose Logic - Only interact if glowLayer exists **
            if (glowLayer) {
                glowLayer.removeIncludedOnlyMesh(sphere);
                glowState.inGlowLayer = false;
            }
            // ** END Dispose Logic **
            if (light) {
                light.dispose();
            }
            sphere.material.dispose();
            sphere.dispose();
        }
    };
}
