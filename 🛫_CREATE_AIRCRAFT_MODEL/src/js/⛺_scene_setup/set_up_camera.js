/********************************************
 * FILE: set_up_camera.js
 ********************************************/

function setupCamera() {
    // Create ArcRotateCamera
    window.camera = new BABYLON.ArcRotateCamera(
      "Camera",
      -2.0,  // alpha
      1.2,   // beta
      40,    // radius
      new BABYLON.Vector3(7, 0, 0), // target
      window.scene
    );
  
    camera.fov = 0.647;
    camera.rotation.z = Math.PI / 2;
    camera.attachControl(window.canvas, true);
    camera.upperBetaLimit = Math.PI;
    camera.lowerBetaLimit = 0;
    camera.inertia = 0.9;
    camera.lowerRadiusLimit = 0.2;
    camera.upperRadiusLimit = 1500;
  
    // Dynamically adjust wheel & panning with distance
    camera.onViewMatrixChangedObservable.add(() => {
      const distance = BABYLON.Vector3.Distance(camera.position, camera.target);
      camera.wheelPrecision = 200 / distance;
      camera.panningSensibility = 5000 / distance;
    });
  
    // Middle-click => pivot camera to clicked point
    let originalTarget = camera.target.clone();
    let lastTarget = camera.target.clone();
  
    window.canvas.addEventListener("pointerdown", function (evt) {
      if (evt.button === 1) {
        evt.preventDefault();
        const pickResult = window.scene.pick(window.scene.pointerX, window.scene.pointerY);
        if (pickResult.hit) {
          lastTarget = camera.target.clone();
          smoothTransitionToTarget(pickResult.pickedPoint, camera, window.scene, 0.3);
        }
      }
    });
  
    // Double-click => open edit or revert
    window.canvas.addEventListener("dblclick", function () {
      const pickResult = window.scene.pick(window.scene.pointerX, window.scene.pointerY);
      if (pickResult.hit) {
        const info = getMetadata(pickResult.pickedMesh);
        if (info && window.selectedComponent === info.mesh) {
          openEditModalForSelected();
          return;
        }
      }
      if (!pickResult.hit) {
        smoothTransitionToTarget(lastTarget, camera, window.scene, 0.3);
      }
    });
  
    // Keyboard shortcuts
    window.addEventListener("keydown", function (evt) {
      if (evt.key === "h" || evt.key === "H") {
        smoothTransitionToTarget(lastTarget, camera, window.scene, 0.3);
      } else if (evt.key === "o" || evt.key === "O") {
        smoothTransitionToTarget(originalTarget, camera, window.scene, 0.3);
      }
    });
  }

  /**
   * Set camera to a preset view (top, bottom, front, side).
   * Uses smooth animation to transition.
   */
  function setCameraPreset(preset) {
    var cam = window.camera;
    if (!cam) return;

    var duration = 0.4;
    var frameRate = 60;
    var totalFrames = duration * frameRate;

    var targetAlpha, targetBeta;
    var radius = cam.radius;

    switch (preset) {
      case 'top':
        targetAlpha = -Math.PI / 2;
        targetBeta = 0.01;
        break;
      case 'bottom':
        targetAlpha = -Math.PI / 2;
        targetBeta = Math.PI - 0.01;
        break;
      case 'front':
        targetAlpha = -Math.PI / 2;
        targetBeta = Math.PI / 2;
        break;
      case 'side':
        targetAlpha = Math.PI;
        targetBeta = Math.PI / 2;
        break;
      default:
        return;
    }

    // Animate alpha
    var animAlpha = new BABYLON.Animation("presetAlpha", "alpha", frameRate,
      BABYLON.Animation.ANIMATIONTYPE_FLOAT, BABYLON.Animation.ANIMATIONLOOPMODE_CONSTANT);
    animAlpha.setKeys([
      { frame: 0, value: cam.alpha },
      { frame: totalFrames, value: targetAlpha }
    ]);

    // Animate beta
    var animBeta = new BABYLON.Animation("presetBeta", "beta", frameRate,
      BABYLON.Animation.ANIMATIONTYPE_FLOAT, BABYLON.Animation.ANIMATIONLOOPMODE_CONSTANT);
    animBeta.setKeys([
      { frame: 0, value: cam.beta },
      { frame: totalFrames, value: targetBeta }
    ]);

    window.scene.beginDirectAnimation(cam, [animAlpha, animBeta], 0, totalFrames, false);
  }
  window.setCameraPreset = setCameraPreset;

  /**
   * Toggle between perspective and orthographic (parallel) camera mode.
   */
  function toggleParallelView(enabled) {
    var cam = window.camera;
    if (!cam) return;

    if (enabled) {
      // Switch to orthographic
      var distance = BABYLON.Vector3.Distance(cam.position, cam.target);
      var aspect = window.engine.getAspectRatio(cam);
      var halfHeight = distance * Math.tan(cam.fov / 2);
      var halfWidth = halfHeight * aspect;

      cam.mode = BABYLON.Camera.ORTHOGRAPHIC_CAMERA;
      cam.orthoLeft = -halfWidth;
      cam.orthoRight = halfWidth;
      cam.orthoTop = halfHeight;
      cam.orthoBottom = -halfHeight;

      // Update ortho bounds when zooming (radius changes)
      if (!cam._orthoObserver) {
        cam._orthoObserver = cam.onViewMatrixChangedObservable.add(function() {
          if (cam.mode !== BABYLON.Camera.ORTHOGRAPHIC_CAMERA) return;
          var dist = BABYLON.Vector3.Distance(cam.position, cam.target);
          var asp = window.engine.getAspectRatio(cam);
          var hh = dist * Math.tan(cam.fov / 2);
          var hw = hh * asp;
          cam.orthoLeft = -hw;
          cam.orthoRight = hw;
          cam.orthoTop = hh;
          cam.orthoBottom = -hh;
        });
      }
    } else {
      cam.mode = BABYLON.Camera.PERSPECTIVE_CAMERA;
      if (cam._orthoObserver) {
        cam.onViewMatrixChangedObservable.remove(cam._orthoObserver);
        cam._orthoObserver = null;
      }
    }
  }
  window.toggleParallelView = toggleParallelView;
  