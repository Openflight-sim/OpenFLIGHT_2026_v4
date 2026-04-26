/********************************************
 * FILE: load_glb_file.js
 ********************************************/

async function loadGLBFile(file) {
  // 1) Show "Loading 3D Model..." overlay
  const loadingText = document.getElementById("loadingText");
  loadingText.style.display = "block";
  loadingText.textContent = "Loading 3D Model...";

  // 2) If there's a previously loaded GLB model, dispose it first
  if (window.currentGLBModel) {
    window.currentGLBModel.dispose();
    window.currentGLBModel = null;
  }

  try {
    // 3) Import the .glb file
    const result = await BABYLON.SceneLoader.ImportMeshAsync(
      "",
      "",
      file,
      scene,
      (evt) => {
        if (evt.lengthComputable) {
          const progress = ((evt.loaded * 100) / evt.total).toFixed();
          loadingText.textContent = `Loading: ${progress}%`;
        }
      }
    );

    // 4) The result.meshes array contains all imported meshes
    const model = result.meshes[0];
    window.currentGLBModel = model;

    // 5) Create or reuse a glbRoot TransformNode to hold them
    if (!window.glbRoot) {
      window.glbRoot = new BABYLON.TransformNode("glbRoot", scene);
    }
    
    // Update metadata for editing
    window.glbRoot.metadata = { 
      type: "glb", 
      data: {
        scale: 1.0,
        rotationDeg: [0, 0, 0],
        position: [0, 0, 0]
      } 
    };
    window.glbRoot.isPickable = true;
    window.lastLoadedGLBName = file.name;

    // 6) Parent all imported meshes under glbRoot & make pickable
    result.meshes.forEach(mesh => {
      mesh.setParent(window.glbRoot);
      mesh.isPickable = true;
    });

    // 7) Auto-center & auto-scale (optional)
    const boundingBox = model.getHierarchyBoundingVectors();
    const modelSize = boundingBox.max.subtract(boundingBox.min);
    const modelCenter = boundingBox.min.add(modelSize.scale(0.5));
    const scaleFactor = 5 / Math.max(modelSize.x, modelSize.y, modelSize.z);
    model.scaling = new BABYLON.Vector3(scaleFactor, scaleFactor, scaleFactor);
    model.position = new BABYLON.Vector3(
      -modelCenter.x * scaleFactor,
      -modelCenter.y * scaleFactor,
      -modelCenter.z * scaleFactor
    );
    window.glbRoot.metadata.data.scale = scaleFactor;

    // 8) Adjust materials for imported GLB meshes only (not the whole scene)
    result.meshes.forEach(mesh => {
      if (mesh.material) {
        mesh.material.transparencyMode = BABYLON.Material.MATERIAL_OPAQUE;
        mesh.material.backFaceCulling = false;
      }
    });

    // 9) Add shadow casters for imported GLB meshes only
    result.meshes.forEach((mesh) => {
      shadowGenerator.addShadowCaster(mesh, true);
    });

  } catch (error) {
    console.error("Error loading GLB file:", error);
    alert("Error loading 3D model. Please try another file.");
  }

  // 10) Hide loading overlay
  loadingText.style.display = "none";

  // Ensure the newly loaded GLB is NOT selected
  if (window.selectedComponent) {
    clearHighlight(window.selectedComponent);
    gizmoManager.attachToMesh(null);
    window.selectedComponent = null;
  }
  clearSelectedNameDisplay();

  // Also hide the snippet, so no transform info shows
  document.getElementById("glbTransformSnippet").style.display = "none";
}
