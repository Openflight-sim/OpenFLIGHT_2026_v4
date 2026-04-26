// js/scene-utils.js

function getMetadata(mesh) {
  let current = mesh;
  while (current) {
    if (current.metadata && current.metadata.data) {
      return { mesh: current, metadata: current.metadata };
    }
    current = current.parent;
  }
  // If none found, check if mesh is descendant of glbRoot
  if (window.glbRoot && isDescendantOf(mesh, window.glbRoot)) {
    return { mesh: window.glbRoot, metadata: window.glbRoot.metadata };
  }
  return null;
}

function isDescendantOf(child, parent) {
  let curr = child.parent;
  while (curr) {
    if (curr === parent) return true;
    curr = curr.parent;
  }
  return false;
}

// Add highlight using highlight layer with contour-only glow
function setColorLightPink(componentNode) {
  // Ensure the highlight layer exists
  if (!window.hl) {
    window.hl = new BABYLON.HighlightLayer("hl1", window.scene);
    window.hl.innerGlow = false;  // Disable inner glow for a more discrete highlight
    window.hl.outerGlow = true;   // Keep only outer glow (contour)
    
    // Adjust glow intensity and blur radius for a more subtle effect
    window.hl.blurHorizontalSize = 0.5;
    window.hl.blurVerticalSize = 0.5;
  }
  
  // Add all meshes to the highlight layer
  componentNode.getChildMeshes().forEach(mesh => {
    if (mesh.name !== "ground" && 
        mesh.name !== CAMERA_SPHERE_NAME && 
        !mesh.name.startsWith("axis") &&
        !mesh.name.startsWith("axisProj") &&
        !mesh.name.startsWith("label_")) {
      window.hl.addMesh(mesh, new BABYLON.Color3(1.0, 0.4, 0.7));
    }
  });
}

// Remove highlight
function clearHighlight(componentNode) {
  if (!window.hl) return;
  
  componentNode.getChildMeshes().forEach(mesh => {
    window.hl.removeMesh(mesh);
  });
}

function setTranslucencyMode(enabled) {
  const alphaValue = enabled ? 0.65 : 1.0;

  function updateMeshTransparency(mesh) {
    // Skip labels, markers (CoG, NP, AC), and crosshair lines — they must stay fully visible
    if (mesh.name.startsWith("label_")) return;
    if (mesh.renderingGroupId === 1) return; // markers are in rendering group 1

    if (mesh.material) {
      mesh.material.alpha = alphaValue;
      if (enabled) {
        mesh.material.transparencyMode = BABYLON.Material.MATERIAL_ALPHABLEND;
        mesh.material.needDepthPrePass = true;
      } else {
        mesh.material.transparencyMode = BABYLON.Material.MATERIAL_OPAQUE;
        mesh.material.needDepthPrePass = false;
      }
    }
  }

  // Update everything under aircraftRoot
  if (window.aircraftRoot) {
    window.aircraftRoot.getChildMeshes().forEach(updateMeshTransparency);
  }
  // GLB translucency is controlled separately — only apply aircraft translucency
  // to glbRoot if glb-specific translucency is not active
  if (window.glbRoot && !window.isGlbTranslucent) {
    window.glbRoot.getChildMeshes().forEach(updateMeshTransparency);
  }
}

/**
 * Toggle GLB model translucency independently.
 */
window.isGlbTranslucent = false;

function setGlbTranslucency(enabled) {
  window.isGlbTranslucent = enabled;
  if (!window.glbRoot) return;

  var alpha = enabled ? 0.35 : 1.0;
  window.glbRoot.getChildMeshes().forEach(function(mesh) {
    if (!mesh.material) return;
    mesh.material.alpha = alpha;
    if (enabled) {
      mesh.material.transparencyMode = BABYLON.Material.MATERIAL_ALPHABLEND;
      mesh.material.needDepthPrePass = true;
    } else {
      // Respect the aircraft-level translucency if active
      if (window.isTranslucent) {
        mesh.material.alpha = 0.65;
        mesh.material.transparencyMode = BABYLON.Material.MATERIAL_ALPHABLEND;
        mesh.material.needDepthPrePass = true;
      } else {
        mesh.material.transparencyMode = BABYLON.Material.MATERIAL_OPAQUE;
        mesh.material.needDepthPrePass = false;
      }
    }
  });
}

/**
 * Smoothly transition camera.target to newTarget over 'durationInSeconds'.
 */
function smoothTransitionToTarget(newTarget, camera, scene, durationInSeconds) {
  const frameRate = 60;
  const totalFrames = durationInSeconds * frameRate;

  const animCamTarget = new BABYLON.Animation(
    "animCam",
    "target",
    frameRate,
    BABYLON.Animation.ANIMATIONTYPE_VECTOR3,
    BABYLON.Animation.ANIMATIONLOOPMODE_CONSTANT
  );

  const keys = [];
  keys.push({ frame: 0, value: camera.target });
  keys.push({ frame: totalFrames, value: newTarget });
  animCamTarget.setKeys(keys);

  scene.beginDirectAnimation(camera, [animCamTarget], 0, totalFrames, false);
}