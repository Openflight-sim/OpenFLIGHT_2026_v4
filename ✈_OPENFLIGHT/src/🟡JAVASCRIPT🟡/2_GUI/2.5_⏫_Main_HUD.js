// ------------------------------------------------------------
// gui/mainHud.js
// Description: Creates the main "Flight Data" HUD and
//              handles its per-frame updates.
// Relies on:
// - createStyledTextBlock from gui/guiComponents.js
// - pauseSimulation from simulation/simulationManager.js
// - calculateFPS from utils/fpsCalculator.js
// - Many global variables (advancedTexture, aircraft, velocity, etc.)
// ------------------------------------------------------------

/**
 * Creates the main GUI interface.
 */
function createGUI() {
  // Create the fullscreen UI texture.
  advancedTexture = BABYLON.GUI.AdvancedDynamicTexture.CreateFullscreenUI("UI");

  // === G-Force Effect Overlay ===
  gForceOverlay = new BABYLON.GUI.Rectangle("gForceOverlay");
  gForceOverlay.width = "100%";
  gForceOverlay.height = "100%";
  gForceOverlay.thickness = 0;
  gForceOverlay.background = "black";
  gForceOverlay.alpha = 0;
  gForceOverlay.zIndex = -10;
  advancedTexture.addControl(gForceOverlay);
  // === END ===

  // Create the main container panel.
  const mainPanel = new BABYLON.GUI.StackPanel();
  mainPanel.width = "350px";
  mainPanel.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  mainPanel.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  mainPanel.padding = "20px";
  mainPanel.spacing = 8;
  mainPanel.background = "rgba(44, 62, 80, 0.8)";
  advancedTexture.addControl(mainPanel); // Add this *after* the overlay

  // Create a small toggle button to hide/show the panel.
  createPanelToggleButton(advancedTexture, mainPanel);

  // Create header text.
  const headerText = createStyledTextBlock("white");
  headerText.text = "Flight Data";
  headerText.fontSize = 24;
  headerText.fontWeight = "bold";
  headerText.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  mainPanel.addControl(headerText);

  // Create information text blocks and assign to global variables
  positionText = createStyledTextBlock();
  velocityText = createStyledTextBlock();
  timeText = createStyledTextBlock();
  alpha_beta_Text = createStyledTextBlock();
  joystickText = createStyledTextBlock();
  fpsText = createStyledTextBlock("#00ff00");
  loadFactorText = createStyledTextBlock("#FFFFFF");
  atcStatusText = createStyledTextBlock("#00ff00"); // NEW: ATC Status
  atcStatusText.fontSize = 18;
  joystickText.fontSize = 16;

  // Add all text blocks to the main panel
  [positionText, velocityText, timeText, alpha_beta_Text, loadFactorText, joystickText, fpsText, atcStatusText].forEach(text => {
    if (text) mainPanel.addControl(text);
  });

  // Create a horizontal container for the buttons.
  const buttonRow = new BABYLON.GUI.StackPanel();
  buttonRow.isVertical = false;
  buttonRow.width = "100%";
  buttonRow.height = "50px";
  buttonRow.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  buttonRow.spacing = 10;
  mainPanel.addControl(buttonRow);

  // Create the file load and pause buttons.
  const fileLoadBtn = createFileLoadButton();
  pauseButton = createPauseButton(); // Assign to global variable
  buttonRow.addControl(fileLoadBtn);
  buttonRow.addControl(pauseButton);

  // Create cockpit-only HUD overlay (appears when CockpitCamera is active).
  createCockpitHUD(advancedTexture);

  // === Recording Indicator ===
  recordingDot = new BABYLON.GUI.Ellipse("recordingDot");
  recordingDot.width = "20px";
  recordingDot.height = "20px";
  recordingDot.color = "red";
  recordingDot.background = "red";
  recordingDot.thickness = 0;
  recordingDot.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  recordingDot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  recordingDot.left = "-20px";
  recordingDot.top = "20px";
  recordingDot.isVisible = false;
  recordingDot.zIndex = 40; // Render on top of everything else
  advancedTexture.addControl(recordingDot);

  // === Show Initial Controls ===
  // === Show Initial Controls ===
  if (typeof isPaused !== 'undefined' && isPaused && typeof hasStartedOnce !== 'undefined' && !hasStartedOnce) {
    if (typeof createControlsHelpPanel === 'function') {
      createControlsHelpPanel(advancedTexture);
      if (window.controlsHelp) window.controlsHelp.isVisible = true;
    }
  }
}

/**
 * Creates a small toggle button in the top-left corner that hides/shows the main panel.
 * @param {BABYLON.GUI.AdvancedDynamicTexture} advancedTexture - The main UI texture.
 * @param {BABYLON.GUI.StackPanel} mainPanel - The main panel to toggle.
 */
function createPanelToggleButton(advancedTexture, mainPanel) {
  const toggleButton = BABYLON.GUI.Button.CreateSimpleButton("toggleButton", "");
  toggleButton.width = "20px";
  toggleButton.height = "20px";
  toggleButton.color = "white";
  toggleButton.fontSize = 14;
  toggleButton.cornerRadius = 15;
  toggleButton.background = "lightblue";
  toggleButton.thickness = 1;
  toggleButton.hoverCursor = "pointer";
  toggleButton.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  toggleButton.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  toggleButton.left = "5px";
  toggleButton.top = "5px";

  let panelVisible = true;
  toggleButton.onPointerUpObservable.add(() => {
    panelVisible = !panelVisible;
    mainPanel.isVisible = panelVisible;
  });

  advancedTexture.addControl(toggleButton);
}

/**
 * Creates and returns a button to load .glb files.
 * @returns {BABYLON.GUI.Button} The file load button.
 */
function createFileLoadButton() {
  const fileLoadButton = BABYLON.GUI.Button.CreateSimpleButton("fileLoadButton", "Load Aircraft (.glb)");
  fileLoadButton.width = "120px";
  fileLoadButton.height = "40px";
  fileLoadButton.color = "white";
  fileLoadButton.fontSize = 16;
  fileLoadButton.cornerRadius = 10;
  fileLoadButton.thickness = 2;
  fileLoadButton.background = "#6C757D";
  fileLoadButton.hoverCursor = "pointer";

  fileLoadButton.onPointerEnterObservable.add(() => {
    fileLoadButton.background = "#5a6268";
  });
  fileLoadButton.onPointerOutObservable.add(() => {
    fileLoadButton.background = "#6C757D";
  });

  fileLoadButton.onPointerUpObservable.add(() => {
    const fileInput = document.getElementById("fileInput");
    if (fileInput) {
      fileInput.click();
    } else {
      console.error("fileInput element not found in the DOM!");
    }
  });

  return fileLoadButton;
}


/**
 * Creates and returns a pause button.
 * @returns {BABYLON.GUI.Button} The pause button.
 */
function createPauseButton() {
  const pauseBtn = BABYLON.GUI.Button.CreateSimpleButton("pauseButton", "Pause Simulation");
  pauseBtn.width = "120px";
  pauseBtn.height = "40px";
  pauseBtn.color = "white";
  pauseBtn.fontSize = 16;
  pauseBtn.cornerRadius = 10;
  pauseBtn.thickness = 2;
  pauseBtn.background = "#4CAF50";
  pauseBtn.hoverCursor = "pointer";

  pauseBtn.onPointerEnterObservable.add(() => {
    if (pauseBtn.textBlock && pauseBtn.textBlock.text === "Pause Simulation") {
      pauseBtn.background = "#45a049";
    }
  });
  pauseBtn.onPointerOutObservable.add(() => {
    if (pauseBtn.textBlock && pauseBtn.textBlock.text === "Pause Simulation") {
      pauseBtn.background = "#4CAF50";
    }
  });

  // This relies on pauseSimulation being in the global scope
  if (typeof pauseSimulation === 'function') {
    pauseBtn.onPointerUpObservable.add(pauseSimulation);
  } else {
    console.error("pauseSimulation function not found for pause button.");
  }
  return pauseBtn;
}

function isCockpitCameraActive() {
  const currentScene = (typeof window !== "undefined" && window.scene) ? window.scene : null;
  return !!(currentScene && currentScene.activeCamera && currentScene.activeCamera.name === "CockpitCamera");
}

function getActiveSceneCamera() {
  const currentScene = (typeof window !== "undefined" && window.scene) ? window.scene : null;
  return currentScene && currentScene.activeCamera ? currentScene.activeCamera : null;
}

function normalizeHeadingDeg(angleDeg) {
  let normalized = angleDeg % 360;
  if (normalized < 0) normalized += 360;
  return normalized;
}

function wrapAngle180Deg(angleDeg) {
  let wrapped = (angleDeg + 180) % 360;
  if (wrapped < 0) wrapped += 360;
  return wrapped - 180;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function formatHeadingScaleLabel(headingDeg) {
  const rounded = normalizeHeadingDeg(Math.round(headingDeg));
  if (rounded === 0) return "N";
  if (rounded === 90) return "E";
  if (rounded === 180) return "S";
  if (rounded === 270) return "W";
  return `${Math.round(rounded / 10)}`;
}

function formatHudNumber(value, digits, fallback = "--") {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric.toFixed(digits) : fallback;
}

function isLiftPastStall(clValue, aoaDeg, aeroData) {
  const aero = aeroData || {};
  const positiveStall = Number(aero.alpha_stall_positive);
  const negativeStall = Number(aero.alpha_stall_negative);
  const clMax = Number(aero.CL_max);

  if (Number.isFinite(positiveStall) && aoaDeg > positiveStall) return true;
  if (Number.isFinite(negativeStall) && aoaDeg < negativeStall) return true;
  if (Number.isFinite(clMax) && clMax > 0 && Number.isFinite(clValue) && Math.abs(clValue) > clMax) return true;
  return false;
}

function getCameraAttitudeDeg(camera) {
  if (!camera) return null;

  const worldUp = new BABYLON.Vector3(0, 1, 0);
  const worldNorth = new BABYLON.Vector3(0, 0, -1);
  const worldEast = new BABYLON.Vector3(-1, 0, 0);

  const forward = camera.getForwardRay(1).direction;
  if (!forward || forward.lengthSquared() < 1e-12) return null;
  forward.normalize();

  const cameraUp = camera.getDirection(BABYLON.Axis.Y);
  if (!cameraUp || cameraUp.lengthSquared() < 1e-12) return null;
  cameraUp.normalize();

  const pitchRad = Math.asin(clamp(BABYLON.Vector3.Dot(forward, worldUp), -1, 1));

  let forwardHorizontal = forward.subtract(worldUp.scale(BABYLON.Vector3.Dot(forward, worldUp)));
  if (forwardHorizontal.lengthSquared() < 1e-12) {
    forwardHorizontal = worldNorth.clone();
  } else {
    forwardHorizontal.normalize();
  }

  const headingRad = Math.atan2(
    BABYLON.Vector3.Dot(forwardHorizontal, worldEast),
    BABYLON.Vector3.Dot(forwardHorizontal, worldNorth)
  );

  let horizonUp = worldUp.subtract(forward.scale(BABYLON.Vector3.Dot(worldUp, forward)));
  if (horizonUp.lengthSquared() < 1e-12) {
    horizonUp = cameraUp.clone();
  } else {
    horizonUp.normalize();
  }

  const sinRoll = BABYLON.Vector3.Dot(BABYLON.Vector3.Cross(horizonUp, cameraUp), forward);
  const cosRoll = clamp(BABYLON.Vector3.Dot(horizonUp, cameraUp), -1, 1);
  const rollRad = Math.atan2(sinRoll, cosRoll);

  return {
    headingDeg: normalizeHeadingDeg(headingRad * 57.295779513),
    pitchDeg: pitchRad * 57.295779513,
    rollDeg: rollRad * 57.295779513
  };
}

function getAircraftAttitudeDeg(aircraft) {
  if (!aircraft) return null;

  const worldUp = new BABYLON.Vector3(0, 1, 0);
  const worldNorth = new BABYLON.Vector3(0, 0, -1);
  const worldEast = new BABYLON.Vector3(-1, 0, 0);

  // The aircraft mesh is natively aligned with the nose along the local +X axis
  const forward = aircraft.getDirection(BABYLON.Axis.X);
  if (!forward || forward.lengthSquared() < 1e-12) return null;
  forward.normalize();

  // Y is up
  const aircraftUp = aircraft.getDirection(BABYLON.Axis.Y);
  if (!aircraftUp || aircraftUp.lengthSquared() < 1e-12) return null;
  aircraftUp.normalize();

  const pitchRad = Math.asin(clamp(BABYLON.Vector3.Dot(forward, worldUp), -1, 1));

  let forwardHorizontal = forward.subtract(worldUp.scale(BABYLON.Vector3.Dot(forward, worldUp)));
  if (forwardHorizontal.lengthSquared() < 1e-12) {
    forwardHorizontal = worldNorth.clone();
  } else {
    forwardHorizontal.normalize();
  }

  const headingRad = Math.atan2(
    BABYLON.Vector3.Dot(forwardHorizontal, worldEast),
    BABYLON.Vector3.Dot(forwardHorizontal, worldNorth)
  );

  let horizonUp = worldUp.subtract(forward.scale(BABYLON.Vector3.Dot(worldUp, forward)));
  if (horizonUp.lengthSquared() < 1e-12) {
    horizonUp = aircraftUp.clone();
  } else {
    horizonUp.normalize();
  }

  const sinRoll = BABYLON.Vector3.Dot(BABYLON.Vector3.Cross(horizonUp, aircraftUp), forward);
  const cosRoll = clamp(BABYLON.Vector3.Dot(horizonUp, aircraftUp), -1, 1);
  const rollRad = Math.atan2(sinRoll, cosRoll);

  return {
    headingDeg: normalizeHeadingDeg(headingRad * 57.295779513),
    pitchDeg: pitchRad * 57.295779513,
    rollDeg: rollRad * 57.295779513
  };
}

// Note: COCKPIT_HUD_PITCH_PIXELS_PER_DEG is deprecated. Pitch scale is now fully dynamic based on camera FOV!
const COCKPIT_HUD_PITCH_PIXELS_PER_DEG = 3.0; // Fallback
const COCKPIT_HUD_MAX_PITCH_DEG = 90.0;
const COCKPIT_HUD_SPEED_STEP_KT = 10.0;
const COCKPIT_HUD_ALTITUDE_STEP_FT = 100.0;
const COCKPIT_HUD_TAPE_PIXELS_PER_STEP = 80.0; // 50 kt range visible over ~400px tape
const COCKPIT_HUD_HEADING_PIXELS_PER_DEG = 4.0;

function createCockpitHUD(advancedTexture) {
  if (!advancedTexture) return;

  if (typeof window.hudDisplayMode === 'undefined') {
    window.hudDisplayMode = 0; // 0=Hidden, 1=Standard, 2=Bottom, 3=GreenCenter
    window.addEventListener("keydown", (e) => {
      if (e.key === 'h' || e.key === 'H') {
        window.hudDisplayMode = (window.hudDisplayMode + 1) % 4;
      }
    });
  }

  const hudColor = "#e8f1ff";
  const ladderColor = "#e8f1ff";
  const accentColor = "#ff4d4d";
  const attitudeWidthPx = 560;
  const attitudeHeightPx = 416;
  const attitudeTopPx = 36;

  cockpitHudContainer = new BABYLON.GUI.StackPanel("cockpitHudContainer");
  cockpitHudContainer.width = "980px";
  cockpitHudContainer.height = "92px";
  cockpitHudContainer.isVertical = true;
  cockpitHudContainer.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudContainer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  cockpitHudContainer.top = "12px";
  cockpitHudContainer.spacing = 2;
  cockpitHudContainer.isVisible = false;
  cockpitHudContainer.zIndex = 24;
  advancedTexture.addControl(cockpitHudContainer);

  cockpitHudPrimaryText = createStyledTextBlock(hudColor);
  cockpitHudPrimaryText.fontFamily = "Consolas";
  cockpitHudPrimaryText.fontSize = 26;
  cockpitHudPrimaryText.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudPrimaryText.text = "";
  cockpitHudContainer.addControl(cockpitHudPrimaryText);

  cockpitHudSecondaryText = createStyledTextBlock(hudColor);
  cockpitHudSecondaryText.fontFamily = "Consolas";
  cockpitHudSecondaryText.fontSize = 17;
  cockpitHudSecondaryText.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudSecondaryText.text = "";
  cockpitHudContainer.addControl(cockpitHudSecondaryText);

  cockpitHudHorizonRoot = new BABYLON.GUI.Rectangle("cockpitHudHorizonRoot");
  cockpitHudHorizonRoot.width = `${attitudeWidthPx}px`;
  cockpitHudHorizonRoot.height = `${attitudeHeightPx}px`;
  cockpitHudHorizonRoot.thickness = 0;
  cockpitHudHorizonRoot.background = "transparent";
  cockpitHudHorizonRoot.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.left = "0px";
  cockpitHudHorizonRoot.top = `${attitudeTopPx}px`;
  cockpitHudHorizonRoot.isVisible = false;
  cockpitHudHorizonRoot.zIndex = 22; // Under the window borders
  // Background for the attitude indicator should be so large edges can never be seen
  cockpitHudHorizonRoot.clipChildren = false;
  advancedTexture.addControl(cockpitHudHorizonRoot);

  const horizonMask = new BABYLON.GUI.Rectangle("cockpitHudHorizonMask");
  horizonMask.width = "4000px";
  horizonMask.height = "4000px";
  horizonMask.thickness = 0;
  horizonMask.background = "transparent"; // "There is no green HUD mode"
  horizonMask.clipChildren = true;
  horizonMask.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  horizonMask.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.addControl(horizonMask);

  const hudOverlayRoot = new BABYLON.GUI.Rectangle("hudOverlayRoot");
  hudOverlayRoot.width = `${attitudeWidthPx}px`;
  hudOverlayRoot.height = `${attitudeHeightPx}px`;
  hudOverlayRoot.thickness = 0;
  hudOverlayRoot.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  hudOverlayRoot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.addControl(hudOverlayRoot);

  // Phase 4/5/6: Alpha & Beta pointers, and AoA/AoS Texts
  const aoaTextHUD = new BABYLON.GUI.TextBlock("aoaTextHUD", "AoA -0.0");
  aoaTextHUD.color = "yellow";
  aoaTextHUD.fontFamily = "Consolas";
  aoaTextHUD.fontSize = 15;
  aoaTextHUD.width = "80px";
  aoaTextHUD.height = "20px";
  aoaTextHUD.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  aoaTextHUD.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  aoaTextHUD.left = "0px"; // Align with the line root
  aoaTextHUD.top = "30px"; // Placed right below the AoA line marker
  hudOverlayRoot.addControl(aoaTextHUD);

  const aosTextHUD = new BABYLON.GUI.TextBlock("aosTextHUD", "AoS -0.0");
  aosTextHUD.color = "yellow";
  aosTextHUD.fontFamily = "Consolas";
  aosTextHUD.fontSize = 15;
  aosTextHUD.width = "80px";
  aosTextHUD.height = "20px";
  aosTextHUD.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  aosTextHUD.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  aosTextHUD.top = "-20px";
  hudOverlayRoot.addControl(aosTextHUD);

  // Alpha Zero Reference Line (white line)
  const alphaZeroLine = new BABYLON.GUI.Rectangle("alphaZeroLine");
  alphaZeroLine.width = "64px"; // 60% longer
  alphaZeroLine.height = "2px";
  alphaZeroLine.background = "white";
  alphaZeroLine.thickness = 0;
  alphaZeroLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  alphaZeroLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  alphaZeroLine.left = "0px";
  alphaZeroLine.top = "0px";
  alphaZeroLine.transformCenterX = 0.0;
  alphaZeroLine.transformCenterY = 0.5;
  hudOverlayRoot.addControl(alphaZeroLine);

  // Alpha Pointer (magenta line rotating at origin)
  const alphaPointer = new BABYLON.GUI.Rectangle("alphaPointer");
  alphaPointer.width = "64px"; // 60% longer
  alphaPointer.height = "2px";
  alphaPointer.background = "#ff00ff";
  alphaPointer.thickness = 0;
  alphaPointer.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  alphaPointer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  alphaPointer.left = "0px";
  alphaPointer.top = "0px";
  alphaPointer.transformCenterX = 0.0;
  alphaPointer.transformCenterY = 0.5;
  hudOverlayRoot.addControl(alphaPointer);

  const alphaArrowTop = new BABYLON.GUI.Rectangle("alphaArrowTop");
  alphaArrowTop.width = "16px";
  alphaArrowTop.height = "2px";
  alphaArrowTop.background = "#ff00ff";
  alphaArrowTop.thickness = 0;
  alphaArrowTop.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  alphaArrowTop.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  alphaArrowTop.left = "2px";
  alphaArrowTop.top = "-5px";
  alphaArrowTop.rotation = -0.6; // chevron pointing left '<'
  alphaPointer.addControl(alphaArrowTop);

  const alphaArrowBot = new BABYLON.GUI.Rectangle("alphaArrowBot");
  alphaArrowBot.width = "16px";
  alphaArrowBot.height = "2px";
  alphaArrowBot.background = "#ff00ff";
  alphaArrowBot.thickness = 0;
  alphaArrowBot.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  alphaArrowBot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  alphaArrowBot.left = "2px";
  alphaArrowBot.top = "5px";
  alphaArrowBot.rotation = 0.6; // chevron pointing left '<'
  alphaPointer.addControl(alphaArrowBot);

  // Beta Pointer (magenta line moving left/right)
  const betaPointer = new BABYLON.GUI.Rectangle("betaPointer");
  betaPointer.width = "2px";
  betaPointer.height = "24px";
  betaPointer.background = "#ff00ff";
  betaPointer.thickness = 0;
  betaPointer.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaPointer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  betaPointer.top = "0px";
  hudOverlayRoot.addControl(betaPointer);

  const betaArrowLeft = new BABYLON.GUI.Rectangle("betaArrowLeft");
  betaArrowLeft.width = "2px";
  betaArrowLeft.height = "12px";
  betaArrowLeft.background = "#ff00ff";
  betaArrowLeft.thickness = 0;
  betaArrowLeft.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaArrowLeft.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
  betaArrowLeft.left = "-4px";
  betaArrowLeft.top = "2px";
  betaArrowLeft.rotation = 0.6; // chevron pointing down 'v'
  betaPointer.addControl(betaArrowLeft);

  const betaArrowRight = new BABYLON.GUI.Rectangle("betaArrowRight");
  betaArrowRight.width = "2px";
  betaArrowRight.height = "12px";
  betaArrowRight.background = "#ff00ff";
  betaArrowRight.thickness = 0;
  betaArrowRight.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaArrowRight.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
  betaArrowRight.left = "4px";
  betaArrowRight.top = "2px";
  betaArrowRight.rotation = -0.6; // chevron pointing down 'v'
  betaPointer.addControl(betaArrowRight);

  // Beta Ruler
  const betaRuler = new BABYLON.GUI.Rectangle("betaRuler");
  betaRuler.width = "200px";
  betaRuler.height = "24px";
  betaRuler.thickness = 0;
  betaRuler.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaRuler.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  betaRuler.top = "26px";
  betaRuler.zIndex = 30; // Render decisively on top of all HUD layers
  hudOverlayRoot.addControl(betaRuler);

  const betaRulerLine = new BABYLON.GUI.Rectangle("betaRulerLine");
  betaRulerLine.width = "180px";
  betaRulerLine.height = "2px";
  betaRulerLine.background = "white";
  betaRulerLine.thickness = 0;
  betaRulerLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaRulerLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  betaRuler.addControl(betaRulerLine);

  [-15, -10, -5, 0, 5, 10, 15].forEach(deg => {
    const tick = new BABYLON.GUI.Rectangle(`betaTick_${deg}`);
    tick.width = "2px";
    tick.height = deg % 10 === 0 ? "7px" : "4px"; // Shrunk ~30% from 10/6
    tick.background = "white";
    tick.thickness = 0;
    tick.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    tick.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
    tick.left = `${deg * 6.0}px`;
    betaRuler.addControl(tick);

    if (deg % 10 === 0 && deg !== 0) {
      const lbl = new BABYLON.GUI.TextBlock(`betaLbl_${deg}`, `${Math.abs(deg)}`);
      lbl.color = "white";
      lbl.fontSize = 8; // Shrunk ~30% from 11
      lbl.fontFamily = "Consolas";
      lbl.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
      lbl.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
      lbl.top = "9px"; // Moved up to match shorter ticks
      lbl.left = `${deg * 6.0}px`;
      betaRuler.addControl(lbl);
    }
  });

  // G-Force text
  const gForceTextHUD = new BABYLON.GUI.TextBlock("gForceTextHUD", "G 1.0");
  gForceTextHUD.color = "white";
  gForceTextHUD.fontFamily = "Consolas";
  gForceTextHUD.fontSize = 15;
  gForceTextHUD.width = "60px";
  gForceTextHUD.height = "20px";
  gForceTextHUD.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  gForceTextHUD.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
  gForceTextHUD.left = "0px";
  gForceTextHUD.top = "0px";
  hudOverlayRoot.addControl(gForceTextHUD);

  // Mach text
  const machTextHUD = new BABYLON.GUI.TextBlock("machTextHUD", "M 0.00");
  machTextHUD.color = "white";
  machTextHUD.fontFamily = "Consolas";
  machTextHUD.fontSize = 15;
  machTextHUD.width = "60px";
  machTextHUD.height = "20px";
  machTextHUD.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  machTextHUD.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
  machTextHUD.left = "0px";
  machTextHUD.top = "0px";
  hudOverlayRoot.addControl(machTextHUD);

  const ldTextHUD = new BABYLON.GUI.TextBlock("ldTextHUD", "L/D --");
  ldTextHUD.color = "white";
  ldTextHUD.fontFamily = "Consolas";
  ldTextHUD.fontSize = 15;
  ldTextHUD.width = "86px";
  ldTextHUD.height = "22px";
  ldTextHUD.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  ldTextHUD.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  ldTextHUD.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  ldTextHUD.left = "10px";
  ldTextHUD.top = "8px";
  hudOverlayRoot.addControl(ldTextHUD);

  const clTextHUD = new BABYLON.GUI.TextBlock("clTextHUD", "CL --");
  clTextHUD.color = "white";
  clTextHUD.fontFamily = "Consolas";
  clTextHUD.fontSize = 15;
  clTextHUD.width = "86px";
  clTextHUD.height = "22px";
  clTextHUD.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  clTextHUD.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  clTextHUD.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  clTextHUD.left = "-10px";
  clTextHUD.top = "8px";
  hudOverlayRoot.addControl(clTextHUD);

  // Phase 14-16: Aerodynamic Stall Limits
  const alphaStallLineTop = new BABYLON.GUI.Rectangle("alphaStallLineTop");
  alphaStallLineTop.width = "64px"; // 60% longer
  alphaStallLineTop.height = "2px";
  alphaStallLineTop.background = "red";
  alphaStallLineTop.thickness = 0;
  alphaStallLineTop.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  alphaStallLineTop.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  alphaStallLineTop.left = "0px";
  alphaStallLineTop.top = "0px";
  alphaStallLineTop.transformCenterX = 0.0;
  alphaStallLineTop.transformCenterY = 0.5;
  hudOverlayRoot.addControl(alphaStallLineTop);

  const alphaStallLineBottom = new BABYLON.GUI.Rectangle("alphaStallLineBottom");
  alphaStallLineBottom.width = "64px"; // 60% longer
  alphaStallLineBottom.height = "2px";
  alphaStallLineBottom.background = "red";
  alphaStallLineBottom.thickness = 0;
  alphaStallLineBottom.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  alphaStallLineBottom.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  alphaStallLineBottom.left = "0px";
  alphaStallLineBottom.top = "0px";
  alphaStallLineBottom.transformCenterX = 0.0;
  alphaStallLineBottom.transformCenterY = 0.5;
  hudOverlayRoot.addControl(alphaStallLineBottom);

  // Beta stall limits (+-9 degrees AoS)
  const betaStallLineLeft = new BABYLON.GUI.Rectangle("betaStallLineLeft");
  betaStallLineLeft.width = "2px";
  betaStallLineLeft.height = "20px";
  betaStallLineLeft.thickness = 0;
  betaStallLineLeft.background = "red";
  betaStallLineLeft.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaStallLineLeft.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  betaStallLineLeft.top = "-10px";
  hudOverlayRoot.addControl(betaStallLineLeft);

  const betaStallLineRight = new BABYLON.GUI.Rectangle("betaStallLineRight");
  betaStallLineRight.width = "2px";
  betaStallLineRight.height = "20px";
  betaStallLineRight.thickness = 0;
  betaStallLineRight.background = "red";
  betaStallLineRight.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  betaStallLineRight.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  betaStallLineRight.top = "-10px";
  hudOverlayRoot.addControl(betaStallLineRight);

  cockpitHudHorizonMovingGroup = new BABYLON.GUI.Rectangle("cockpitHudHorizonMovingGroup");
  cockpitHudHorizonMovingGroup.width = "6000px";
  cockpitHudHorizonMovingGroup.height = "6000px";
  cockpitHudHorizonMovingGroup.thickness = 0;
  cockpitHudHorizonMovingGroup.background = "transparent";
  cockpitHudHorizonMovingGroup.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudHorizonMovingGroup.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  horizonMask.addControl(cockpitHudHorizonMovingGroup);

  cockpitHudPitchGroup = new BABYLON.GUI.Rectangle("cockpitHudPitchGroup");
  cockpitHudPitchGroup.width = "6000px";
  cockpitHudPitchGroup.height = "6000px";
  cockpitHudPitchGroup.thickness = 0;
  cockpitHudPitchGroup.background = "transparent";
  cockpitHudPitchGroup.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudPitchGroup.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonMovingGroup.addControl(cockpitHudPitchGroup);

  const skyBand = new BABYLON.GUI.Rectangle("cockpitHudSkyBand");
  skyBand.width = "100%";
  skyBand.height = "50%";
  skyBand.thickness = 0;
  skyBand.background = "rgba(98, 138, 202, 0.72)";
  skyBand.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  skyBand.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_TOP;
  cockpitHudPitchGroup.addControl(skyBand);

  const groundBand = new BABYLON.GUI.Rectangle("cockpitHudGroundBand");
  groundBand.width = "100%";
  groundBand.height = "50%";
  groundBand.thickness = 0;
  groundBand.background = "rgba(84, 128, 44, 0.78)";
  groundBand.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  groundBand.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
  cockpitHudPitchGroup.addControl(groundBand);

  const horizonLine = new BABYLON.GUI.Rectangle("cockpitHudHorizonLine");
  horizonLine.width = "1400px";
  horizonLine.height = "2px";
  horizonLine.thickness = 0;
  horizonLine.background = "white"; // "make the horizon white"
  horizonLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  horizonLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudPitchGroup.addControl(horizonLine);

  const pitchTickMarks = [];

  for (let deg = -90; deg <= 90; deg += 5) {
    if (deg === 0) continue;
    const markerKey = deg < 0 ? `m${Math.abs(deg)}` : `p${deg}`;
    const isMajor = Math.abs(deg) % 10 === 0;
    const isTwenty = Math.abs(deg) % 20 === 0;
    const markerWidthPx = (isMajor ? (isTwenty ? 128 : 98) : 56) * 1.30; // Increased width 30%

    const marker = new BABYLON.GUI.Rectangle(`cockpitHudPitchMark_${markerKey}`);
    marker.width = `${markerWidthPx}px`;
    marker.height = "2px";
    marker.thickness = 0;
    marker.background = ladderColor;
    marker.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    marker.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    marker.top = `${(-deg * COCKPIT_HUD_PITCH_PIXELS_PER_DEG).toFixed(1)}px`;
    cockpitHudPitchGroup.addControl(marker);

    const labelText = `${deg}`;
    let labelLeft = new BABYLON.GUI.TextBlock(`cockpitHudPitchLabelL_${markerKey}`, labelText);
    labelLeft.color = ladderColor;
    labelLeft.fontSize = isMajor ? 15 : 12;
    labelLeft.fontFamily = "Consolas";
    labelLeft.width = "44px";
    labelLeft.height = "20px";
    labelLeft.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    labelLeft.textVerticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    labelLeft.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    labelLeft.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    labelLeft.left = `${(-markerWidthPx / 2 - 32).toFixed(1)}px`;
    labelLeft.top = `${(-deg * COCKPIT_HUD_PITCH_PIXELS_PER_DEG).toFixed(1)}px`;
    cockpitHudPitchGroup.addControl(labelLeft);

    let labelRight = new BABYLON.GUI.TextBlock(`cockpitHudPitchLabelR_${markerKey}`, labelText);
    labelRight.color = ladderColor;
    labelRight.fontSize = isMajor ? 15 : 12;
    labelRight.fontFamily = "Consolas";
    labelRight.width = "44px";
    labelRight.height = "20px";
    labelRight.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    labelRight.textVerticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    labelRight.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    labelRight.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    labelRight.left = `${(markerWidthPx / 2 + 32).toFixed(1)}px`;
    labelRight.top = `${(-deg * COCKPIT_HUD_PITCH_PIXELS_PER_DEG).toFixed(1)}px`;
    cockpitHudPitchGroup.addControl(labelRight);
    pitchTickMarks.push({ deg, marker, labelLeft, labelRight });
  }

  cockpitHudRollGroup = new BABYLON.GUI.Rectangle("cockpitHudRollGroup");
  cockpitHudRollGroup.width = "6000px";
  cockpitHudRollGroup.height = "6000px";
  cockpitHudRollGroup.thickness = 0;
  cockpitHudRollGroup.background = "transparent";
  cockpitHudRollGroup.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  cockpitHudRollGroup.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.addControl(cockpitHudRollGroup);

  const bankRadius = 98; // Reduced 30% inwards from 140 (which was 175)
  [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60].forEach((deg) => {
    const rad = deg * Math.PI / 180.0;
    const tick = new BABYLON.GUI.Rectangle(`cockpitHudBankTick_${deg}`);
    tick.width = "2px";
    tick.height = (deg === 0 || Math.abs(deg) >= 30) ? "16px" : "10px";
    tick.thickness = 0;
    tick.background = ladderColor;
    tick.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    tick.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    tick.left = `${(bankRadius * Math.sin(rad)).toFixed(1)}px`;
    tick.top = `${(-bankRadius * Math.cos(rad) - 10).toFixed(1)}px`;
    tick.rotation = rad;
    cockpitHudRollGroup.addControl(tick);

    if ([-60, -30, -10, 10, 30, 60].includes(deg)) {
      const label = new BABYLON.GUI.TextBlock(`cockpitHudBankLabel_${deg}`, `${Math.abs(deg)}`);
      label.color = ladderColor;
      label.fontFamily = "Consolas";
      label.fontSize = 14;
      label.width = "30px";
      label.height = "20px";
      label.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
      label.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
      const labelRad = bankRadius + 22; // Offset text radially outward
      label.left = `${(labelRad * Math.sin(rad)).toFixed(1)}px`;
      label.top = `${(-labelRad * Math.cos(rad) - 10).toFixed(1)}px`;
      label.rotation = 0; // Maintain numbers parallel to the artificial horizon
      cockpitHudRollGroup.addControl(label);
    }
  });

  const bankPointerL = new BABYLON.GUI.Rectangle("cockpitHudBankPointerL");
  bankPointerL.width = "14px";
  bankPointerL.height = "2px";
  bankPointerL.thickness = 0;
  bankPointerL.background = accentColor;
  bankPointerL.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  bankPointerL.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  bankPointerL.left = "-6px";
  bankPointerL.top = `${(-bankRadius - 18).toFixed(1)}px`;
  bankPointerL.rotation = 0.65;
  cockpitHudHorizonRoot.addControl(bankPointerL);

  const bankPointerR = new BABYLON.GUI.Rectangle("cockpitHudBankPointerR");
  bankPointerR.width = "14px";
  bankPointerR.height = "2px";
  bankPointerR.thickness = 0;
  bankPointerR.background = accentColor;
  bankPointerR.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  bankPointerR.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  bankPointerR.left = "6px";
  bankPointerR.top = `${(-bankRadius - 18).toFixed(1)}px`;
  bankPointerR.rotation = -0.65;
  cockpitHudHorizonRoot.addControl(bankPointerR);

  const leftWing = new BABYLON.GUI.Rectangle("cockpitHudLeftWing");
  leftWing.width = "90px";
  leftWing.height = "3px";
  leftWing.thickness = 0;
  leftWing.background = accentColor;
  leftWing.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  leftWing.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  leftWing.left = "-118px";
  cockpitHudHorizonRoot.addControl(leftWing);

  const rightWing = new BABYLON.GUI.Rectangle("cockpitHudRightWing");
  rightWing.width = "90px";
  rightWing.height = "3px";
  rightWing.thickness = 0;
  rightWing.background = accentColor;
  rightWing.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  rightWing.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  rightWing.left = "118px";
  cockpitHudHorizonRoot.addControl(rightWing);

  const centerChevronLeft = new BABYLON.GUI.Rectangle("cockpitHudCenterChevronLeft");
  centerChevronLeft.width = "30px";
  centerChevronLeft.height = "3px";
  centerChevronLeft.thickness = 0;
  centerChevronLeft.background = accentColor;
  centerChevronLeft.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  centerChevronLeft.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  centerChevronLeft.left = "-16px";
  centerChevronLeft.top = "8px";
  centerChevronLeft.rotation = -0.55;
  cockpitHudHorizonRoot.addControl(centerChevronLeft);

  const centerChevronRight = new BABYLON.GUI.Rectangle("cockpitHudCenterChevronRight");
  centerChevronRight.width = "30px";
  centerChevronRight.height = "3px";
  centerChevronRight.thickness = 0;
  centerChevronRight.background = accentColor;
  centerChevronRight.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  centerChevronRight.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  centerChevronRight.left = "16px";
  centerChevronRight.top = "8px";
  centerChevronRight.rotation = 0.55;
  cockpitHudHorizonRoot.addControl(centerChevronRight);

  // Restore the little center cross hair that anchors the aircraft origin in the UI
  const physicalNoseAnchor = new BABYLON.GUI.Rectangle("physicalNoseAnchor");
  physicalNoseAnchor.width = "2px";
  physicalNoseAnchor.height = "16px";
  physicalNoseAnchor.background = "white";
  physicalNoseAnchor.thickness = 0;
  physicalNoseAnchor.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  physicalNoseAnchor.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.addControl(physicalNoseAnchor);

  const physicalNoseAnchorH = new BABYLON.GUI.Rectangle("physicalNoseAnchorH");
  physicalNoseAnchorH.width = "16px";
  physicalNoseAnchorH.height = "2px";
  physicalNoseAnchorH.background = "white";
  physicalNoseAnchorH.thickness = 0;
  physicalNoseAnchorH.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  physicalNoseAnchorH.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  cockpitHudHorizonRoot.addControl(physicalNoseAnchorH);

  const thrustTape = new BABYLON.GUI.Rectangle("cockpitHudThrustTape");
  thrustTape.width = "12px";
  thrustTape.height = `${attitudeHeightPx}px`;
  thrustTape.thickness = 0;
  thrustTape.background = "rgba(0, 0, 0, 0.22)";
  thrustTape.clipChildren = false;
  thrustTape.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  thrustTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  thrustTape.left = "-356px";
  thrustTape.top = `${attitudeTopPx}px`;
  thrustTape.isVisible = false;
  thrustTape.zIndex = 24;
  advancedTexture.addControl(thrustTape);

  const thrustBar = new BABYLON.GUI.Rectangle("cockpitHudThrustBar");
  thrustBar.width = "10px";
  thrustBar.height = "0%";
  thrustBar.thickness = 0;
  thrustBar.background = "#00ff00";
  thrustBar.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  thrustBar.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
  thrustTape.addControl(thrustBar);

  const thrustLabelBox = new BABYLON.GUI.Rectangle("cockpitHudThrustLabelBox");
  thrustLabelBox.width = "50px";
  thrustLabelBox.height = "16px";
  thrustLabelBox.thickness = 0;
  thrustLabelBox.background = "rgba(0, 0, 0, 0.22)";
  thrustLabelBox.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  thrustLabelBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  thrustLabelBox.left = "-356px";
  thrustLabelBox.isVisible = false;
  thrustLabelBox.zIndex = 25;
  advancedTexture.addControl(thrustLabelBox);

  const thrustLabel = new BABYLON.GUI.TextBlock("cockpitHudThrustLabel", "%Thrust");
  thrustLabel.color = "white";
  thrustLabel.fontFamily = "Consolas";
  thrustLabel.fontSize = 12;
  thrustLabel.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  thrustLabel.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  thrustLabelBox.addControl(thrustLabel);

  const speedTape = new BABYLON.GUI.Rectangle("cockpitHudSpeedTape");
  speedTape.width = "60px";
  speedTape.height = `${attitudeHeightPx}px`;
  speedTape.thickness = 0;
  speedTape.color = "rgba(255, 255, 255, 0.35)";
  speedTape.background = "rgba(0, 0, 0, 0.22)";
  speedTape.clipChildren = true;
  speedTape.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  speedTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  speedTape.left = "-310px"; // Closer to artificial horizon
  speedTape.top = `${attitudeTopPx}px`;
  speedTape.isVisible = false;
  speedTape.zIndex = 24;
  advancedTexture.addControl(speedTape);

  const speedTapeOverlay = new BABYLON.GUI.Rectangle("cockpitHudSpeedTapeOverlay");
  speedTapeOverlay.width = "60px";
  speedTapeOverlay.height = `${attitudeHeightPx}px`;
  speedTapeOverlay.thickness = 0;
  speedTapeOverlay.color = "transparent";
  speedTapeOverlay.background = "transparent";
  speedTapeOverlay.clipChildren = true;
  speedTapeOverlay.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  speedTapeOverlay.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  speedTapeOverlay.left = "-310px";
  speedTapeOverlay.top = `${attitudeTopPx}px`;
  speedTapeOverlay.isVisible = false;
  speedTapeOverlay.zIndex = 30; // Float above the speed tape and value box
  advancedTexture.addControl(speedTapeOverlay);

  const greenDot = new BABYLON.GUI.Ellipse("cockpitHudGreenDot");
  greenDot.width = "14px";
  greenDot.height = "14px";
  greenDot.color = "#00ff00";
  greenDot.thickness = 2;
  greenDot.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  greenDot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  greenDot.left = "-2px";
  greenDot.zIndex = 30; // Float on top of the red tape and main speed lines
  speedTapeOverlay.addControl(greenDot);

  const redStallTape = new BABYLON.GUI.Rectangle("cockpitHudRedStallTape");
  redStallTape.width = "8px";
  redStallTape.height = "0px";
  redStallTape.thickness = 0;
  redStallTape.background = "red";
  redStallTape.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  redStallTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  speedTapeOverlay.addControl(redStallTape);

  const speedCenterLine = new BABYLON.GUI.Rectangle("cockpitHudSpeedCenterLine");
  speedCenterLine.width = "24px";
  speedCenterLine.height = "2px";
  speedCenterLine.thickness = 0;
  speedCenterLine.background = accentColor;
  speedCenterLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  speedCenterLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  speedCenterLine.left = "11px";
  speedTape.addControl(speedCenterLine);

  const speedValueBox = new BABYLON.GUI.Rectangle("cockpitHudSpeedValueBox");
  speedValueBox.width = "60px";
  speedValueBox.height = "38px";
  speedValueBox.thickness = 0;
  speedValueBox.color = hudColor;
  speedValueBox.background = "black";
  speedValueBox.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  speedValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  speedValueBox.left = "-310px"; // Align with tape
  speedValueBox.top = `${attitudeTopPx}px`;
  speedValueBox.zIndex = 25; // Render directly over the tape
  speedValueBox.isVisible = false;
  advancedTexture.addControl(speedValueBox);

  const speedValueText = new BABYLON.GUI.TextBlock("cockpitHudSpeedValueText", "");
  speedValueText.color = hudColor;
  speedValueText.fontFamily = "Consolas";
  speedValueText.fontSize = 14; // Shrunk by ~20% from 18
  speedValueBox.addControl(speedValueText);

  const speedTickMarks = [];
  for (let i = 0; i < 21; i++) {
    const line = new BABYLON.GUI.Rectangle(`cockpitHudSpeedTick_${i}`);
    line.width = "10px";
    line.height = "2px";
    line.thickness = 0;
    line.background = ladderColor;
    line.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
    line.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    line.left = "0px";
    speedTape.addControl(line);

    const label = new BABYLON.GUI.TextBlock(`cockpitHudSpeedTickLabel_${i}`, "");
    label.color = ladderColor;
    label.fontFamily = "Consolas";
    label.fontSize = 13;
    label.width = "36px";
    label.height = "18px";
    label.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    label.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    label.left = "-8px"; // Centered in the space not taken by tick
    speedTape.addControl(label);

    speedTickMarks.push({ line, label });
  }

  const altitudeTape = new BABYLON.GUI.Rectangle("cockpitHudAltitudeTape");
  altitudeTape.width = "60px";
  altitudeTape.height = `${attitudeHeightPx}px`;
  altitudeTape.thickness = 0;
  altitudeTape.color = "rgba(255, 255, 255, 0.35)";
  altitudeTape.background = "rgba(0, 0, 0, 0.22)";
  altitudeTape.clipChildren = true;
  altitudeTape.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  altitudeTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  altitudeTape.left = "330px"; // Next to vsiTape (300px edge)
  altitudeTape.top = `${attitudeTopPx}px`;
  altitudeTape.isVisible = false;
  altitudeTape.zIndex = 24;
  advancedTexture.addControl(altitudeTape);

  const altitudeCenterLine = new BABYLON.GUI.Rectangle("cockpitHudAltitudeCenterLine");
  altitudeCenterLine.width = "24px";
  altitudeCenterLine.height = "2px";
  altitudeCenterLine.thickness = 0;
  altitudeCenterLine.background = accentColor;
  altitudeCenterLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  altitudeCenterLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  altitudeCenterLine.left = "-13px";
  altitudeTape.addControl(altitudeCenterLine);

  const altitudeValueBox = new BABYLON.GUI.Rectangle("cockpitHudAltitudeValueBox");
  altitudeValueBox.width = "60px";
  altitudeValueBox.height = "38px";
  altitudeValueBox.thickness = 0;
  altitudeValueBox.color = hudColor;
  altitudeValueBox.background = "black";
  altitudeValueBox.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  altitudeValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  altitudeValueBox.left = "330px"; // Match tape shift left exactly
  altitudeValueBox.top = `${attitudeTopPx}px`;
  altitudeValueBox.zIndex = 25; // Render directly over the tape
  altitudeValueBox.isVisible = false;
  advancedTexture.addControl(altitudeValueBox);

  const altitudeValueText = new BABYLON.GUI.TextBlock("cockpitHudAltitudeValueText", "");
  altitudeValueText.color = hudColor;
  altitudeValueText.fontFamily = "Consolas";
  altitudeValueText.fontSize = 14; // Shrunk by ~20% from 18
  altitudeValueBox.addControl(altitudeValueText);

  const altitudeTickMarks = [];
  for (let i = 0; i < 21; i++) {
    const line = new BABYLON.GUI.Rectangle(`cockpitHudAltitudeTick_${i}`);
    line.width = "10px";
    line.height = "2px";
    line.thickness = 0;
    line.background = ladderColor;
    line.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
    line.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    line.left = "0px";
    altitudeTape.addControl(line);

    const label = new BABYLON.GUI.TextBlock(`cockpitHudAltitudeTickLabel_${i}`, "");
    label.color = ladderColor;
    label.fontFamily = "Consolas";
    label.fontSize = 12;
    label.width = "39px";
    label.height = "18px";
    label.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    label.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    label.left = "8px"; // Centered in the space not taken by tick
    altitudeTape.addControl(label);

    altitudeTickMarks.push({ line, label });
  }

  const slipSkidContainer = new BABYLON.GUI.Rectangle("cockpitHudSlipSkidContainer");
  slipSkidContainer.width = "100px";
  slipSkidContainer.height = "18px";
  slipSkidContainer.thickness = 2;
  slipSkidContainer.color = "white"; // the glass tube border
  slipSkidContainer.background = "transparent";
  slipSkidContainer.cornerRadius = 9; // gives it round edges like a pill/tube
  slipSkidContainer.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  slipSkidContainer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  slipSkidContainer.top = `${attitudeTopPx + attitudeHeightPx / 2 - 16}px`; // Just above heading
  slipSkidContainer.isVisible = false;
  slipSkidContainer.zIndex = 24;
  advancedTexture.addControl(slipSkidContainer);

  const slipSkidCenterLeft = new BABYLON.GUI.Rectangle("slipSkidCenterLeft");
  slipSkidCenterLeft.width = "2px";
  slipSkidCenterLeft.height = "18px";
  slipSkidCenterLeft.thickness = 0;
  slipSkidCenterLeft.background = "white";
  slipSkidCenterLeft.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  slipSkidCenterLeft.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  slipSkidCenterLeft.left = "-10px";
  slipSkidContainer.addControl(slipSkidCenterLeft);

  const slipSkidCenterRight = new BABYLON.GUI.Rectangle("slipSkidCenterRight");
  slipSkidCenterRight.width = "2px";
  slipSkidCenterRight.height = "18px";
  slipSkidCenterRight.thickness = 0;
  slipSkidCenterRight.background = "white";
  slipSkidCenterRight.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  slipSkidCenterRight.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  slipSkidCenterRight.left = "10px";
  slipSkidContainer.addControl(slipSkidCenterRight);

  const slipSkidBall = new BABYLON.GUI.Ellipse("cockpitHudSlipSkidBall");
  slipSkidBall.width = "14px";
  slipSkidBall.height = "14px";
  slipSkidBall.color = "white";
  slipSkidBall.background = "white"; // solid ball
  slipSkidBall.thickness = 0;
  slipSkidBall.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  slipSkidBall.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  slipSkidBall.left = "0px";
  slipSkidContainer.addControl(slipSkidBall);

  const headingStrip = new BABYLON.GUI.Rectangle("cockpitHudHeadingStrip");
  headingStrip.width = "320px";
  headingStrip.height = "54px"; // Reduced 40% from 90px
  headingStrip.thickness = 0;
  headingStrip.color = "rgba(255, 255, 255, 0.45)";
  headingStrip.background = "rgba(0, 0, 0, 0.30)";
  headingStrip.clipChildren = true;
  headingStrip.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  headingStrip.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  headingStrip.top = `${attitudeTopPx + attitudeHeightPx / 2 + 27}px`; // Match top flush to mask bottom (attitude center + half height + half container height)
  headingStrip.isVisible = false;
  headingStrip.zIndex = 24;
  advancedTexture.addControl(headingStrip);

  const headingValueText = new BABYLON.GUI.TextBlock("cockpitHudHeadingValueText", "");
  headingValueText.color = hudColor;
  headingValueText.fontFamily = "Consolas";
  headingValueText.fontSize = 12; // Reduced font proportionally 
  headingValueText.top = "16px"; // Shift text down
  headingStrip.addControl(headingValueText);

  const headingPointer = new BABYLON.GUI.Rectangle("cockpitHudHeadingPointer");
  headingPointer.width = "2px";
  headingPointer.height = "16px";
  headingPointer.thickness = 0;
  headingPointer.background = accentColor;
  headingPointer.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  headingPointer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  headingPointer.top = "-6px";
  headingStrip.addControl(headingPointer);

  const headingTicks = [];
  for (let i = 0; i < 37; i++) {
    const line = new BABYLON.GUI.Rectangle(`cockpitHudHeadingTick_${i}`);
    line.width = "2px";
    line.height = "6px";
    line.thickness = 0;
    line.background = ladderColor;
    line.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    line.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    line.top = "-16px"; // Shift tape lines securely away from text
    headingStrip.addControl(line);

    const label = new BABYLON.GUI.TextBlock(`cockpitHudHeadingTickLabel_${i}`, "");
    label.color = ladderColor;
    label.fontFamily = "Consolas";
    label.fontSize = 10;
    label.width = "34px";
    label.height = "18px";
    label.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
    label.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    label.top = "-2px"; // Sit label comfortably between tick line and container number string
    headingStrip.addControl(label);

    headingTicks.push({ line, label });
  }

  const vsiTape = new BABYLON.GUI.Rectangle("cockpitHudVsiTape");
  vsiTape.width = "20px";
  vsiTape.height = `${attitudeHeightPx}px`;
  vsiTape.thickness = 0; // "no border in the box for the VSI bars"
  vsiTape.color = "rgba(255, 255, 255, 0.4)";
  vsiTape.background = "transparent";
  vsiTape.clipChildren = true;
  vsiTape.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  vsiTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  vsiTape.left = "290px"; // Sandwiched accurately sitting inside of the artificial horizon and left of the right Altitude tape
  vsiTape.top = `${attitudeTopPx}px`;
  vsiTape.isVisible = false;
  vsiTape.zIndex = 26;
  advancedTexture.addControl(vsiTape);

  const vsiBar = new BABYLON.GUI.Rectangle("cockpitHudVsiBar");
  vsiBar.width = "18px";
  vsiBar.thickness = 0;
  vsiBar.background = "orange";
  vsiBar.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  vsiBar.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  vsiTape.addControl(vsiBar);

  const speedTrendLine = new BABYLON.GUI.Rectangle("cockpitHudSpeedTrendLine");
  speedTrendLine.width = "4px";
  speedTrendLine.thickness = 0;
  speedTrendLine.background = "yellow";
  speedTrendLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_RIGHT;
  speedTrendLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  speedTrendLine.left = "-2px";
  speedTape.addControl(speedTrendLine);

  const altitudeTrendLine = new BABYLON.GUI.Rectangle("cockpitHudAltitudeTrendLine");
  altitudeTrendLine.width = "4px";
  altitudeTrendLine.thickness = 0;
  altitudeTrendLine.background = "yellow";
  altitudeTrendLine.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_LEFT;
  altitudeTrendLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  altitudeTrendLine.left = "2px";
  altitudeTape.addControl(altitudeTrendLine);

  const vsiText = new BABYLON.GUI.TextBlock("cockpitHudVsiText", "");
  vsiText.color = "white";
  vsiText.fontFamily = "Consolas";
  vsiText.fontSize = 14;
  vsiText.width = "80px";
  vsiText.height = "20px";
  vsiText.horizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  vsiText.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  vsiText.textHorizontalAlignment = BABYLON.GUI.Control.HORIZONTAL_ALIGNMENT_CENTER;
  vsiText.left = "240px"; // Visibly nested distinctly inside the edge of the artificial horizon masking layer space
  vsiText.top = "18px";
  vsiText.zIndex = 26;
  vsiText.isVisible = false;
  advancedTexture.addControl(vsiText);

  cockpitHudReticleH = null;
  cockpitHudReticleV = null;

  cockpitHudState = {
    pitchTickMarks,
    speedTape,
    speedTapeOverlay,
    speedValueText,
    speedTickMarks,
    altitudeTape,
    altitudeValueText,
    altitudeTickMarks,
    headingStrip,
    headingValueText,
    headingTicks,
    greenDot,
    redStallTape,
    aoaTextHUD,
    aosTextHUD,
    alphaZeroLine,
    alphaPointer,
    betaPointer,
    alphaStallLineTop,
    alphaStallLineBottom,
    betaStallLineLeft,
    betaStallLineRight,
    speedValueBox,
    altitudeValueBox,
    gForceTextHUD,
    vsiTape,
    vsiBar,
    speedTrendLine,
    altitudeTrendLine,
    vsiText,
    machTextHUD,
    ldTextHUD,
    clTextHUD,
    thrustTape,
    thrustBar,
    thrustLabelBox,
    thrustLabel,
    slipSkidContainer,
    slipSkidBall
  };
}

function applyHUDTheme(node, isGreenMode) {
  if (!node) return;

  if (node.originalColor === undefined) node.originalColor = node.color || null;
  if (node.originalBackground === undefined) node.originalBackground = node.background || null;

  if (isGreenMode) {
    if (node.color && node.color !== "transparent" && node.color !== "black" && !node.color.startsWith("rgba(0")) {
      node.color = "#00ff00";
    }
    if (node.background && node.background !== "transparent" && node.background !== "black" && !node.background.startsWith("rgba(0")) {
      if (node.name === "cockpitHudSkyBand" || node.name === "cockpitHudGroundBand" || node.name === "cockpitHudSpeedCenterLine" || node.name === "cockpitHudAltitudeCenterLine") {
        node.isVisible = false;
      } else if (node.name === "cockpitHudHeadingStrip" || node.name === "cockpitHudSlipSkidContainer") {
        node.background = "transparent";
      } else if (node.name !== "gForceOverlay") {
        node.background = "#00ff00";
      }
    }
  } else {
    if (node.originalColor !== null) node.color = node.originalColor;
    if (node.originalBackground !== null) node.background = node.originalBackground;
    if (node.name === "cockpitHudSkyBand" || node.name === "cockpitHudGroundBand" || node.name === "cockpitHudSpeedCenterLine" || node.name === "cockpitHudAltitudeCenterLine") {
      node.isVisible = true;
    }
  }

  if (node.children && Array.isArray(node.children)) {
    node.children.forEach(child => applyHUDTheme(child, isGreenMode));
  }
}

function updateCockpitHUD(speedMs) {
  if (
    !cockpitHudContainer ||
    !cockpitHudPrimaryText ||
    !cockpitHudSecondaryText ||
    !cockpitHudHorizonRoot ||
    !cockpitHudHorizonMovingGroup ||
    !cockpitHudState
  ) {
    return;
  }

  const cockpitActive = isCockpitCameraActive();

  // Phase 17: Multi-State Cycler Logic
  const hudMode = (typeof window.hudDisplayMode !== 'undefined') ? window.hudDisplayMode : 1; // Toggles for external HUD overrides depending on visibility
  if (!window.hudDisplayMode || window.hudDisplayMode === 0) {
    cockpitHudContainer.isVisible = false;
    cockpitHudHorizonRoot.isVisible = false;
    cockpitHudState.speedTape.isVisible = false;
    cockpitHudState.speedTapeOverlay.isVisible = false;
    cockpitHudState.altitudeTape.isVisible = false;
    cockpitHudState.speedValueBox.isVisible = false;
    cockpitHudState.altitudeValueBox.isVisible = false;
    cockpitHudState.headingStrip.isVisible = false;
    cockpitHudState.vsiTape.isVisible = false;
    cockpitHudState.vsiText.isVisible = false;
    cockpitHudState.thrustTape.isVisible = false;
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.isVisible = false;
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.isVisible = false;
    return;
  }

  const isGreenMode = (window.hudDisplayMode === 3);
  if (cockpitHudState.lastGreenMode !== isGreenMode) {
    cockpitHudState.lastGreenMode = isGreenMode;
    const rootsToTheme = [
      cockpitHudHorizonRoot,
      cockpitHudState.speedTape,
      cockpitHudState.speedTapeOverlay,
      cockpitHudState.altitudeTape,
      cockpitHudState.vsiTape,
      cockpitHudState.speedValueBox,
      cockpitHudState.altitudeValueBox,
      cockpitHudState.headingStrip,
      cockpitHudState.vsiText,
      cockpitHudState.thrustTape,
      cockpitHudState.thrustLabelBox,
      cockpitHudState.slipSkidContainer,
      cockpitHudContainer
    ];
    rootsToTheme.forEach(r => applyHUDTheme(r, isGreenMode));
  }

  // Phase 17: Multi-State View layout (1=Standard, 2=Bottom, 3=Center/Green)
  cockpitHudContainer.isVisible = true;
  cockpitHudHorizonRoot.isVisible = true;
  cockpitHudState.speedTape.isVisible = true;
  cockpitHudState.speedTapeOverlay.isVisible = true;
  cockpitHudState.altitudeTape.isVisible = true;
  cockpitHudState.speedValueBox.isVisible = true;
  cockpitHudState.altitudeValueBox.isVisible = true;
  cockpitHudState.headingStrip.isVisible = true;
  cockpitHudState.vsiTape.isVisible = true;
  cockpitHudState.vsiText.isVisible = true;
  cockpitHudState.thrustTape.isVisible = true;
  if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.isVisible = true;
  if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.isVisible = true;

  if (window.hudDisplayMode === 3) {
    // Mode 3 (Center HUD, now positioned identical to standard mode)
    cockpitHudHorizonRoot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.speedTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.speedTapeOverlay.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.thrustTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.altitudeTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.vsiTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.vsiText.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.headingStrip.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.speedValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.altitudeValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;

    cockpitHudHorizonRoot.top = "36px";
    cockpitHudState.speedTape.top = "36px";
    cockpitHudState.speedTapeOverlay.top = "36px";
    cockpitHudState.thrustTape.top = "36px";
    cockpitHudState.altitudeTape.top = "36px";
    cockpitHudState.vsiTape.top = "36px";
    cockpitHudState.vsiText.top = "36px";
    // 36 + (416/2) + (54/2) = 271
    cockpitHudState.headingStrip.top = "271px";
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.top = "228px";

    cockpitHudState.speedTape.left = "-310px";
    cockpitHudState.speedTapeOverlay.left = "-310px";
    cockpitHudState.altitudeTape.left = "330px";
    cockpitHudState.speedValueBox.top = "36px";
    cockpitHudState.altitudeValueBox.top = "36px";
    cockpitHudState.speedValueBox.left = "-310px";
    cockpitHudState.altitudeValueBox.left = "330px";
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.top = `${36 + (416 / 2) + 14}px`;
    cockpitHudState.speedTape.background = "transparent";
    cockpitHudState.thrustTape.background = "transparent";
    cockpitHudState.altitudeTape.background = "transparent";
    cockpitHudState.speedValueText.parent.background = "transparent";
    cockpitHudState.altitudeValueText.parent.background = "transparent";
    cockpitHudState.headingStrip.background = "transparent";
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.background = "transparent";
    if (cockpitHudState.thrustLabel) cockpitHudState.thrustLabel.color = "#00ff00";
  } else if (window.hudDisplayMode === 2) {
    // Mode 2 (Bottom aligned HUD)
    cockpitHudHorizonRoot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.speedTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.speedTapeOverlay.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.thrustTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.altitudeTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.vsiTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.vsiText.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.headingStrip.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.speedValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    cockpitHudState.altitudeValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_BOTTOM;

    // Heading sits flush against bottom
    cockpitHudState.headingStrip.top = "0px";
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.top = "-58px";

    // The tapes and horizon are 416px tall.
    // With BOTTOM alignment, 'top' sets the distance from the screen bottom to the element's BOTTOM edge.
    // To sit exactly on top of the 54px heading strip, their bottom edges must be offset by -54px upwards.
    cockpitHudHorizonRoot.top = "-54px";
    cockpitHudState.speedTape.top = "-54px";
    cockpitHudState.speedTapeOverlay.top = "-54px";
    cockpitHudState.thrustTape.top = "-54px";
    cockpitHudState.altitudeTape.top = "-54px";
    cockpitHudState.vsiTape.top = "-54px";

    // The value boxes (38px tall) need to be centered vertically within the tapes' 416px height.
    // The tapes span from 54px to 470px vertically from the bottom (center is at 262px).
    // For a 38px box to be centered at 262px, its bottom edge must be at 262 - 19 = 243px.
    cockpitHudState.speedValueBox.top = "-243px";
    cockpitHudState.altitudeValueBox.top = "-243px";

    // The vsiText (20px tall). Centered at 262px means its bottom is at 262 - 10 = 252px.
    cockpitHudState.vsiText.top = "-252px";

    cockpitHudState.speedTape.left = "-310px";
    cockpitHudState.speedTapeOverlay.left = "-310px";
    cockpitHudState.altitudeTape.left = "330px";
    cockpitHudState.speedValueBox.left = "-310px";
    cockpitHudState.altitudeValueBox.left = "330px";
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.top = "-34px"; // Sit just below the tape at the bottom screen anchor
    cockpitHudState.speedTape.background = "rgba(0, 0, 0, 0.22)";
    cockpitHudState.thrustTape.background = "rgba(0, 0, 0, 0.22)";
    cockpitHudState.altitudeTape.background = "rgba(0, 0, 0, 0.22)";
    // Ensure value boxes have black backgrounds explicitly restored
    cockpitHudState.speedValueText.parent.background = "black";
    cockpitHudState.altitudeValueText.parent.background = "black";
    cockpitHudState.headingStrip.background = "rgba(0, 0, 0, 0.30)";
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.background = "rgba(0, 0, 0, 0.22)";
    if (cockpitHudState.thrustLabel) cockpitHudState.thrustLabel.color = "white";
  } else {
    // Mode 1 (Standard)
    cockpitHudHorizonRoot.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.speedTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.speedTapeOverlay.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.thrustTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.altitudeTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.vsiTape.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.vsiText.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.headingStrip.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.speedValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
    cockpitHudState.altitudeValueBox.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;

    cockpitHudHorizonRoot.top = "36px";
    cockpitHudState.speedTape.top = "36px";
    cockpitHudState.speedTapeOverlay.top = "36px";
    cockpitHudState.thrustTape.top = "36px";
    cockpitHudState.altitudeTape.top = "36px";
    cockpitHudState.vsiTape.top = "36px";
    cockpitHudState.vsiText.top = "36px";
    // 36 + (416/2) + (54/2) = 271
    cockpitHudState.headingStrip.top = "271px";
    if (cockpitHudState.slipSkidContainer) cockpitHudState.slipSkidContainer.top = "228px";

    cockpitHudState.speedTape.left = "-310px";
    cockpitHudState.speedTapeOverlay.left = "-310px";
    cockpitHudState.altitudeTape.left = "330px";
    cockpitHudState.speedValueBox.top = "36px";
    cockpitHudState.altitudeValueBox.top = "36px";
    cockpitHudState.speedValueBox.left = "-310px";
    cockpitHudState.altitudeValueBox.left = "330px";
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.top = `${36 + (416 / 2) + 14}px`;
    cockpitHudState.speedTape.background = "rgba(0, 0, 0, 0.22)";
    cockpitHudState.thrustTape.background = "rgba(0, 0, 0, 0.22)";
    cockpitHudState.altitudeTape.background = "rgba(0, 0, 0, 0.22)";
    cockpitHudState.speedValueText.parent.background = "black";
    cockpitHudState.altitudeValueText.parent.background = "black";
    cockpitHudState.headingStrip.background = "rgba(0, 0, 0, 0.30)";
    if (cockpitHudState.thrustLabelBox) cockpitHudState.thrustLabelBox.background = "rgba(0, 0, 0, 0.22)";
    if (cockpitHudState.thrustLabel) cockpitHudState.thrustLabel.color = "white";
  }

  const speedKt = speedMs * 1.94384449;
  const altitudeFt = aircraft.position.y * 3.2808399;
  const vsiFpm = velocity.y * 196.850394;
  const aoaDeg = alpha_RAD * 57.295779513;
  const betaDeg = beta_RAD * 57.295779513;

  let headingDeg = 0.0;
  let pitchDeg = 0.0;
  let rollDeg = 0.0;

  const aircraftAttitude = getAircraftAttitudeDeg(aircraft);
  if (aircraftAttitude) {
    headingDeg = aircraftAttitude.headingDeg;
    pitchDeg = aircraftAttitude.pitchDeg;
    rollDeg = aircraftAttitude.rollDeg;
  }

  // --- Dynamic HUD Pitch Scaling to Match Camera FOV ---
  let dynamicPixelsPerDeg = COCKPIT_HUD_PITCH_PIXELS_PER_DEG; // Fallback
  const activeCam = getActiveSceneCamera();
  const currentEngine = (typeof window !== "undefined" && window.engine) ? window.engine : null;
  if (currentEngine && activeCam && activeCam.fov) {
    const renderHeightPx = currentEngine.getRenderHeight();
    const fovDegrees = activeCam.fov * 57.295779513; // rad to deg
    dynamicPixelsPerDeg = renderHeightPx / fovDegrees; // Guaranteed 1:1 parity with the real horizon
  }

  const clampedPitchDeg = clamp(pitchDeg, -COCKPIT_HUD_MAX_PITCH_DEG, COCKPIT_HUD_MAX_PITCH_DEG);
  cockpitHudPitchGroup.top = `${(clampedPitchDeg * dynamicPixelsPerDeg).toFixed(1)}px`;
  cockpitHudHorizonMovingGroup.rotation = rollDeg * Math.PI / 180.0;
  if (typeof cockpitHudRollGroup !== 'undefined') {
    cockpitHudRollGroup.rotation = rollDeg * Math.PI / 180.0;
  }

  if (cockpitHudState.pitchTickMarks) {
    cockpitHudState.pitchTickMarks.forEach((tick) => {
      const yPx = -tick.deg * dynamicPixelsPerDeg;
      tick.marker.top = `${yPx.toFixed(1)}px`;
      if (tick.labelLeft) tick.labelLeft.top = `${yPx.toFixed(1)}px`;
      if (tick.labelRight) tick.labelRight.top = `${yPx.toFixed(1)}px`;
    });
  }

  // Phase 9.5: Update Thrust Percentage Bar
  let effectiveThrust = 0;
  if (typeof window.thrust_attained !== "undefined") {
    effectiveThrust = window.thrust_attained;
  } else if (typeof thrust_setting_demand !== "undefined") {
    effectiveThrust = thrust_setting_demand;
  }
  const thrustPercent = clamp(effectiveThrust * 100, 0, 100);
  cockpitHudState.thrustBar.height = `${thrustPercent.toFixed(1)}%`;

  // Phase 10: Blank out the legacy cockpitHudPrimaryText / cockpitHudSecondaryText strings
  cockpitHudPrimaryText.text = "";
  cockpitHudSecondaryText.text = "";

  const speedMid = Math.floor(cockpitHudState.speedTickMarks.length / 2);
  const speedRounded = Math.round(speedKt / COCKPIT_HUD_SPEED_STEP_KT) * COCKPIT_HUD_SPEED_STEP_KT;
  cockpitHudState.speedTickMarks.forEach((tick, idx) => {
    const markValue = speedRounded + (idx - speedMid) * COCKPIT_HUD_SPEED_STEP_KT;
    const yPx = -((markValue - speedKt) / COCKPIT_HUD_SPEED_STEP_KT) * COCKPIT_HUD_TAPE_PIXELS_PER_STEP;
    const visible = markValue >= 0 && Math.abs(yPx) <= 208;
    tick.line.isVisible = visible;
    tick.label.isVisible = visible;
    if (!visible) return;
    tick.line.top = `${yPx.toFixed(1)}px`;
    tick.label.top = `${yPx.toFixed(1)}px`;
    const isMajor = Math.round(markValue) % 10 === 0; // Stamp every 10 knots
    tick.line.width = isMajor ? "20px" : "10px";
    tick.label.text = isMajor ? `${Math.round(markValue)}` : "";
  });
  cockpitHudState.speedValueText.text = `${Math.max(0, speedKt).toFixed(0)}`;

  // Phase 14-16: Green Dot & Stall Tape (SF25B config)
  const fallbackAero = { aircraft_mass: 600, reference_area: 18.2, AR: 13.8, Oswald_factor: 0.8, CD0: 0.013, CL_max: 1.2, alpha_stall_positive: 15.0, alpha_stall_negative: -15.0 };
  const aero = typeof window.aeroData !== "undefined" ? window.aeroData : fallbackAero;

  // Approx standard density ratio for dynamic speeds
  const altM = Math.max(0, aircraft.position.y);
  const tempK = Math.max(288.15 - 0.0065 * altM, 200);
  const pressurePa = 101325 * Math.pow(tempK / 288.15, 5.25588);
  const rho = pressurePa / (287.05 * tempK);
  const g = 9.81;

  // Best L/D = sqrt(CD0 * pi * e * AR)
  const CL_bestLd = Math.sqrt(aero.CD0 * Math.PI * aero.Oswald_factor * aero.AR);
  const vBestLdMs = Math.sqrt((2 * aero.aircraft_mass * g) / (rho * aero.reference_area * CL_bestLd));
  const bestLdKt = vBestLdMs * 1.94384449;

  const greenDotY = -((bestLdKt - speedKt) / COCKPIT_HUD_SPEED_STEP_KT) * COCKPIT_HUD_TAPE_PIXELS_PER_STEP;
  cockpitHudState.greenDot.top = `${clamp(greenDotY, -208, 208).toFixed(1)}px`;
  cockpitHudState.greenDot.isVisible = Math.abs(greenDotY) <= 208;

  const vStallMs = Math.sqrt((2 * aero.aircraft_mass * g) / (rho * aero.reference_area * aero.CL_max));
  const vStallKt = vStallMs * 1.94384449;

  const stallTapeY = -((vStallKt - speedKt) / COCKPIT_HUD_SPEED_STEP_KT) * COCKPIT_HUD_TAPE_PIXELS_PER_STEP;

  // Phase 19: Mach Calculation
  // True Airspeed mapping from speedMs
  // speed of sound (a) = sqrt(gamma * R * T)
  const gamma = 1.4;
  const R = 287.05;
  const a = Math.sqrt(gamma * R * tempK);
  const machNumber = speedMs / a;
  cockpitHudState.machTextHUD.text = `M ${machNumber.toFixed(2)}`;

  const liveCL = (typeof currentCL !== 'undefined') ? Number(currentCL) : NaN;
  const liveLD = (typeof currentLD !== 'undefined') ? Number(currentLD) : NaN;
  const clPastStall = isLiftPastStall(liveCL, aoaDeg, aero);
  cockpitHudState.ldTextHUD.text = `L/D ${formatHudNumber(liveLD, 1)}`;
  cockpitHudState.clTextHUD.text = `CL ${formatHudNumber(liveCL, 2)}`;
  cockpitHudState.ldTextHUD.color = isGreenMode ? "#00ff00" : "white";
  cockpitHudState.clTextHUD.color = clPastStall ? "red" : (isGreenMode ? "#00ff00" : "white");

  // The center of the container is 0, the bottom is 208
  // Compute height from the stall line down to the bottom of the container
  const h = Math.max(0, 208 - stallTapeY);
  cockpitHudState.redStallTape.height = `${h.toFixed(1)}px`;
  // Position is centered relative to the drawn height
  cockpitHudState.redStallTape.top = `${(stallTapeY + h / 2).toFixed(1)}px`;

  const altitudeMid = Math.floor(cockpitHudState.altitudeTickMarks.length / 2);
  const altitudeRounded = Math.round(altitudeFt / COCKPIT_HUD_ALTITUDE_STEP_FT) * COCKPIT_HUD_ALTITUDE_STEP_FT;
  cockpitHudState.altitudeTickMarks.forEach((tick, idx) => {
    const markValue = altitudeRounded + (idx - altitudeMid) * COCKPIT_HUD_ALTITUDE_STEP_FT;
    const yPx = -((markValue - altitudeFt) / COCKPIT_HUD_ALTITUDE_STEP_FT) * COCKPIT_HUD_TAPE_PIXELS_PER_STEP;
    const visible = Math.abs(yPx) <= 208;
    tick.line.isVisible = visible;

    // --- Phase 20: Slip/Skid Ball Mathematics ---
    if (cockpitHudState.slipSkidBall) {
      let currentNy = (typeof window.ny !== "undefined") ? window.ny : 0;
      // Clamp ny to exactly [-1, 1] as requested
      const clampedNy = Math.max(-1, Math.min(1, currentNy));
      // ny proportional shift; ball moves opposite side of turn inside the container bounds (~40px)
      cockpitHudState.slipSkidBall.left = `${(clampedNy * 40).toFixed(1)}px`;
    }
    // --------------------------------------------
    tick.label.isVisible = visible;
    if (!visible) return;
    tick.line.top = `${yPx.toFixed(1)}px`;
    tick.label.top = `${yPx.toFixed(1)}px`;
    const isMajor = Math.abs(Math.round(markValue)) % 100 === 0;
    tick.line.width = isMajor ? "20px" : "10px";
    tick.label.text = isMajor ? `${Math.round(markValue)}` : "";
  });

  // Apply units here
  cockpitHudState.speedValueText.text = `${Math.max(0, speedKt).toFixed(0)} kt`;
  cockpitHudState.altitudeValueText.text = `${altitudeFt.toFixed(0)} ft`;
  cockpitHudState.vsiText.text = `${Math.round(vsiFpm)} fpm`;

  // Phase 5/8: VSI Bar (+1000 to -1000 fpm over 160px half-height)
  const vsiScale = 160.0 / 1000.0;
  const clampedVsi = clamp(vsiFpm, -1000, 1000);
  const vsiHeightPx = Math.abs(clampedVsi * vsiScale);
  cockpitHudState.vsiBar.height = `${vsiHeightPx.toFixed(1)}px`;
  cockpitHudState.vsiBar.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  // "the VSI bar should be blue when VSI is positive" (and orange when negative)
  if (isGreenMode) {
    cockpitHudState.vsiBar.background = "#00ff00";
  } else {
    cockpitHudState.vsiBar.background = clampedVsi >= 0 ? "blue" : "orange";
  }
  if (clampedVsi >= 0) {
    cockpitHudState.vsiBar.top = `${(-vsiHeightPx / 2).toFixed(1)}px`;
  } else {
    cockpitHudState.vsiBar.top = `${(vsiHeightPx / 2).toFixed(1)}px`;
  }

  // Phase 7: Trend Vectors (10 seconds prediction)
  if (typeof window.accelKtS === 'undefined') {
    window.accelKtS = 0;
    window.prevSpeedKt = speedKt;
  }
  const speedDelta = speedKt - window.prevSpeedKt;
  const dt = Math.max(0.016, (typeof engine !== 'undefined' ? engine.getDeltaTime() : 16) / 1000.0);
  window.accelKtS = window.accelKtS * 0.95 + (speedDelta / dt) * 0.05;
  window.prevSpeedKt = speedKt;

  const speedTrendKt = window.accelKtS * 10.0;
  const speedTrendPx = Math.abs(speedTrendKt / COCKPIT_HUD_SPEED_STEP_KT) * COCKPIT_HUD_TAPE_PIXELS_PER_STEP;
  cockpitHudState.speedTrendLine.height = `${clamp(speedTrendPx, 1, 160).toFixed(1)}px`;
  cockpitHudState.speedTrendLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  if (speedTrendKt >= 0) {
    cockpitHudState.speedTrendLine.top = `${(-clamp(speedTrendPx, 1, 160) / 2).toFixed(1)}px`;
  } else {
    cockpitHudState.speedTrendLine.top = `${(clamp(speedTrendPx, 1, 160) / 2).toFixed(1)}px`;
  }

  const altDelta10s = (vsiFpm / 60.0) * 10.0;
  const altTrendPx = Math.abs(altDelta10s / COCKPIT_HUD_ALTITUDE_STEP_FT) * COCKPIT_HUD_TAPE_PIXELS_PER_STEP;
  cockpitHudState.altitudeTrendLine.height = `${clamp(altTrendPx, 1, 160).toFixed(1)}px`;
  cockpitHudState.altitudeTrendLine.verticalAlignment = BABYLON.GUI.Control.VERTICAL_ALIGNMENT_CENTER;
  if (altDelta10s >= 0) {
    cockpitHudState.altitudeTrendLine.top = `${(-clamp(altTrendPx, 1, 160) / 2).toFixed(1)}px`;
  } else {
    cockpitHudState.altitudeTrendLine.top = `${(clamp(altTrendPx, 1, 160) / 2).toFixed(1)}px`;
  }

  // Phase 4/6/15: Alpha and Beta Pointers & Stall Indicator Texts
  const aeroDynamicData = typeof window.aeroData !== "undefined" ? window.aeroData : fallbackAero;

  // Pivot Alpha indicator locally (no left/right scaling per degrees anymore, pure rotation)
  cockpitHudState.alphaZeroLine.top = "0px";
  cockpitHudState.alphaPointer.top = "0px";
  cockpitHudState.alphaPointer.rotation = -alpha_RAD;

  // Track AoA and adjust AoA Text Position
  cockpitHudState.aoaTextHUD.text = `AoA ${aoaDeg.toFixed(1)}`;

  // Feed stall values mapped continuously
  cockpitHudState.alphaStallLineTop.top = "0px";
  cockpitHudState.alphaStallLineTop.rotation = -(aeroDynamicData.alpha_stall_positive * Math.PI / 180.0);
  cockpitHudState.alphaStallLineBottom.top = "0px";
  cockpitHudState.alphaStallLineBottom.rotation = -(aeroDynamicData.alpha_stall_negative * Math.PI / 180.0);
  const betaPx = betaDeg * 6.0; // scale factor
  cockpitHudState.betaPointer.left = `${clamp(betaPx, -160, 160).toFixed(1)}px`;
  cockpitHudState.aosTextHUD.text = `AoS ${betaDeg.toFixed(1)}`;
  cockpitHudState.aosTextHUD.left = cockpitHudState.betaPointer.left;

  if (cockpitHudState.betaStallLineLeft) {
    cockpitHudState.betaStallLineLeft.left = `${-9 * 6.0}px`;
    cockpitHudState.betaStallLineRight.left = `${9 * 6.0}px`;
  }

  cockpitHudState.gForceTextHUD.text = `G ${nz.toFixed(1)}`;
  if (nz < -1.0) {
    cockpitHudState.gForceTextHUD.color = "red";
  } else if (nz > 7.0) {
    cockpitHudState.gForceTextHUD.color = "#ff00ff";
  } else {
    cockpitHudState.gForceTextHUD.color = isGreenMode ? "#00ff00" : "white";
  }

  const headingMid = Math.floor(cockpitHudState.headingTicks.length / 2);
  const headingRounded = Math.round(headingDeg / 10.0) * 10.0;
  cockpitHudState.headingTicks.forEach((tick, idx) => {
    const markHeading = normalizeHeadingDeg(headingRounded + (idx - headingMid) * 10.0);
    const deltaHeading = wrapAngle180Deg(markHeading - headingDeg);
    const xPx = deltaHeading * COCKPIT_HUD_HEADING_PIXELS_PER_DEG;
    const visible = Math.abs(deltaHeading) <= 45.0; // narrow heading visibility to match 320px
    tick.line.isVisible = visible;
    tick.label.isVisible = visible;
    if (!visible) return;
    tick.line.left = `${xPx.toFixed(1)}px`;
    tick.label.left = `${xPx.toFixed(1)}px`;
    const isMajor = Math.round(markHeading) % 10 === 0; // Tick and label every 10 degrees instead of 30
    tick.line.height = isMajor ? "16px" : "8px";
    // Divide logic for display "as they are now" means 30 => 3, 330 => 33
    // E.g formatHeadingScaleLabel(120) -> "12"
    tick.label.text = isMajor ? formatHeadingScaleLabel(markHeading) : "";
  });
  const headingInt = Math.round(normalizeHeadingDeg(headingDeg)) % 360;
  cockpitHudState.headingValueText.text = `${headingInt.toString().padStart(3, "0")}`;
}

/**
 * Updates all GUI information elements with compact, formatted text.
 */
function updateInfo() {
  // Check if aircraft and all text elements are initialized
  if (!aircraft || !aircraft.position || !positionText || !velocityText || !timeText || !alpha_beta_Text || !joystickText || !fpsText || !loadFactorText) {
    return;
  }

  positionText.text =
    `Location: N:${(-aircraft.position.z).toFixed(0)} | E:${(-aircraft.position.x).toFixed(0)}\nAlt: ${(3.2808399 * aircraft.position.y).toFixed(0)} ft / ${aircraft.position.y.toFixed(0)} m`;

  const speed = Math.sqrt(velocity.x ** 2 + velocity.y ** 2 + velocity.z ** 2);
  velocityText.text =
    `Speed: ${(speed * 1.94384449).toFixed(0)} kt / ${(speed * 3.6).toFixed(0)} km/h / ${speed.toFixed(0)} m/s\nVario: ${velocity.y.toFixed(1)} m/s`;

  timeText.text = `Flight time: ${(window.serverElapsedTime || 0).toFixed(1)} s`;

  alpha_beta_Text.text = `α: ${(alpha_RAD * 180 / Math.PI).toFixed(1)}°  β: ${(beta_RAD * 180 / Math.PI).toFixed(1)}°`;

  loadFactorText.text = `Load Factor (G): ${nz.toFixed(2)}`;
  joystickText.text = `Controls: ${joystickAxes.map(v => v.toFixed(2)).join(", ")}`;

  // Update ATC Status
  if (typeof window.atcStatusText !== "undefined") {
    if (window.isATCConnected) {
      if (window.isPTTActive) {
        atcStatusText.text = "ATC: 🎙️ TRANSMITTING";
        atcStatusText.color = "#ffff00"; // Yellow 
      } else if (window.isATCReceiving) {
        atcStatusText.text = "ATC: 🔊 RECEIVING";
        atcStatusText.color = "#00ffff"; // Cyan
      } else {
        atcStatusText.text = "ATC: 🟢 CONNECTED (Hold Enter to Talk)";
        atcStatusText.color = "#00ff00"; // Green
      }
    } else {
      atcStatusText.text = "ATC: 🔴 OFFLINE (Press C)";
      atcStatusText.color = "#ff0000"; // Red
    }
  }

  // Update FPS counter
  const currentFPS = calculateFPS();
  fpsText.text = `FPS: ${currentFPS}`;

  if (currentFPS > 45) {
    fpsText.color = "#00ff00";
  } else if (currentFPS > 30) {
    fpsText.color = "#ffff00";
  } else {
    fpsText.color = "#ff0000";
  }

  // === G-Force Overlay Logic using nz ===
  if (gForceOverlay) {
    const positiveGStart = 3.0;
    const positiveGMax = 9.0;
    const negativeGStart = -1.5;
    const negativeGMax = -3.0;
    const maxAlpha = 0.75;

    if (nz > positiveGStart) {
      let alpha = (nz - positiveGStart) / (positiveGMax - positiveGStart);
      alpha = Math.min(Math.max(alpha, 0), 1.0) * maxAlpha;
      gForceOverlay.background = "black";
      gForceOverlay.alpha = alpha;
    } else if (nz < negativeGStart) {
      let alpha = (nz - negativeGStart) / (negativeGMax - negativeGStart);
      alpha = Math.min(Math.max(alpha, 0), 1.0) * maxAlpha;
      gForceOverlay.background = "red";
      gForceOverlay.alpha = alpha;
    } else {
      gForceOverlay.alpha = 0;
    }
  }
  // === END ===

  // === Recording Dot Logic ===
  if (typeof recordingDot !== "undefined" && recordingDot) {
    if (window.serverElapsedTime >= start_flight_data_recording_at &&
      window.serverElapsedTime <= finish_flight_data_recording_at) {
      recordingDot.isVisible = true;
    } else {
      recordingDot.isVisible = false;
    }
  }

  // Cockpit HUD appears only when cockpit camera is active.
  updateCockpitHUD(speed);
}
