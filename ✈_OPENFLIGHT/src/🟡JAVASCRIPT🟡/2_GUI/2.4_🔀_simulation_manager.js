// ------------------------------------------------------------
// simulation/simulationManager.js
// Description: Manages the simulation pause state.
// Relies on createControlsHelpPanel from gui/pauseMenu.js
// Relies on global vars: isPaused, pauseButton, advancedTexture, etc.
// ------------------------------------------------------------

function pauseSimulation() {
  // Refuse to un-pause while the startup "Loading…" overlay is still up.
  // Defensive: all known unpause entry points (keyboard, gamepad) already
  // check window.simReadyToPlay, but the in-GUI pause button and any future
  // caller funnel through here, so keep the guard in one place too.
  if (isPaused && !window.simReadyToPlay) {
    console.log("Simulator not ready yet — unpause request ignored.");
    return;
  }
  isPaused = !isPaused;
  console.log(`Simulation ${isPaused ? "paused" : "resumed"}`);

  // Mark the sim as "has started at least once" whenever we un-pause.
  // The overlay state machine in 6.1_... uses this flag to pick the
  // right prompt: before the first un-pause it says "Simulation ready,
  // press space to start"; after it says "Paused, press space to
  // continue".  Keeping the flip here (rather than at each call site in
  // 3.1_...) guarantees spacebar-first unpauses also flip it — the old
  // auto-start paths only set it on non-space keys / gamepad buttons.
  if (!isPaused && typeof hasStartedOnce !== 'undefined') {
    hasStartedOnce = true;
  }

  // If you have a global "pauseButton" in your GUI, update it
  if (typeof pauseButton !== "undefined" && pauseButton && pauseButton.textBlock) {
    pauseButton.textBlock.text = isPaused ? "Resume" : "Pause Simulation";
    pauseButton.background = isPaused ? "#f44336" : "#4CAF50";
  }

  // On resume, reset timing to avoid large deltaTime spikes
  if (!isPaused) {
    if (typeof window.resetServerDataTimer === 'function') {
      window.resetServerDataTimer(); // Safely resets the internal exchange timer
    }
  }

  // Show/hide the "FLIGHT CONTROLS" help panel
  // Check if advancedTexture exists before creating GUI elements
  if (isPaused && typeof advancedTexture !== 'undefined' && advancedTexture) {
    if (!window.controlsHelp) {
      // It doesn't exist, so create it.
      createControlsHelpPanel(advancedTexture);
    }
    // Now that we're sure it exists, make it visible.
    window.controlsHelp.isVisible = true;

  } else { // If not paused
    if (window.controlsHelp) { // Only hide if it exists
      window.controlsHelp.isVisible = false;
    }
  }
}