/*************************************************************
 * 3.1_joystick_gamepad.js
 *
 * Allows:
 * 1) Keyboard controls for flight:
 *    - Pitch Up/Down:  A / Q
 *    - Roll Left/Right: O / P
 *    - Yaw Left/Right: K / L
 *    - Camera Select:  I / U / Y / T
 *    - Thrust Level:   0..9
 *    - Reset (Reload): R
 *    - Pause/Resume:   Space
 * 2) Gamepad/joystick controls for:
 *    - pitch / roll / yaw / thrust
 *    - camera selection
 *    - reset / pause
 *
 * The browser Gamepad API exposes a canonical "standard" mapping for
 * Xbox/PlayStation style pads when it can identify the device. We prefer
 * that mapping first, then fall back to legacy/raw layouts for joysticks
 * and older devices.
 *************************************************************/

// --- Function called by Main Loop (6.1_...) ---
function handleGamepadPauseControls() {
    // Block every path that could unpause the simulator until the startup
    // "Loading…" overlay has cleared. The overlay is gated on first valid
    // server data AND completion of any GLB aircraft model upload (see
    // 6.1_..._MAIN_render_loop.js). Before that point the physics loop is
    // mid-handshake and pilot inputs feel dead for the first second.
    if (!window.simReadyToPlay) {
        return;
    }

    if (typeof handleGamepadPause === 'function') {
        handleGamepadPause();
    } else {
        console.warn("handleGamepadPause function not found when called by handleGamepadPauseControls.");
        const valid = getValidGamepad();
        if (!valid) return;
        const { gamepad, type } = valid;
        const checkButtons = getPauseButtonCandidates(type);
        if (checkButtons.some((btnIndex) => buttonIsPressed(gamepad, btnIndex))) {
            if (typeof pauseSimulation === 'function') {
                pauseSimulation();
            }
        }
    }

    // Auto-start simulation on any gamepad input if it's the very first play.
    if (typeof isPaused !== 'undefined' && isPaused && typeof hasStartedOnce !== 'undefined' && !hasStartedOnce) {
        const valid = getValidGamepad();
        if (valid) {
            const { gamepad } = valid;
            let inputDetected = false;

            if (gamepad.axes) {
                for (let i = 0; i < gamepad.axes.length; i++) {
                    if (Math.abs(applyAxisDeadzone(getAxisValue(gamepad.axes, i))) > 0.05) {
                        inputDetected = true;
                    }
                }
            }

            if (gamepad.buttons) {
                for (let i = 0; i < gamepad.buttons.length; i++) {
                    // Ignore pause/reset buttons so they keep their normal behavior.
                    if (i === 8 || i === 9 || i === 10 || i === 11) continue;
                    if (buttonIsPressed(gamepad, i)) {
                        inputDetected = true;
                    }
                }
            }

            if (inputDetected) {
                hasStartedOnce = true;
                if (typeof pauseSimulation === 'function') pauseSimulation();
            }
        }
    }
}
// --- END Function called by Main Loop ---


// Track last state of buttons to detect "just pressed" events
let previousButtonStates = {};
let lastPauseToggleTime = 0;

const STANDARD_GAMEPAD_BUTTONS = Object.freeze({
    FACE_DOWN: 0,
    FACE_RIGHT: 1,
    FACE_LEFT: 2,
    FACE_UP: 3,
    LEFT_CENTER: 8,
    RIGHT_CENTER: 9,
    LEFT_STICK: 10,
    RIGHT_STICK: 11
});

function clamp01(value) {
    return Math.max(0, Math.min(1, value));
}

function getAxisValue(axes, axisIndex) {
    if (!axes || axisIndex < 0 || axisIndex >= axes.length) return 0;
    const value = Number(axes[axisIndex]);
    return Number.isFinite(value) ? value : 0;
}

function applyAxisDeadzone(value, deadzone = 0.08) {
    const magnitude = Math.abs(value);
    if (magnitude <= deadzone) return 0;
    const scaled = (magnitude - deadzone) / (1 - deadzone);
    return Math.sign(value) * Math.min(scaled, 1);
}

function axisToThrottle(value) {
    return clamp01((1 - value) / 2);
}

function buttonIsPressed(gamepad, buttonIndex) {
    if (!gamepad || !gamepad.buttons || buttonIndex < 0 || buttonIndex >= gamepad.buttons.length) {
        return false;
    }
    const button = gamepad.buttons[buttonIndex];
    if (!button) return false;
    return button.pressed || (typeof button.value === 'number' && button.value > 0.5);
}

function isButtonJustPressed(gamepad, buttonIndex) {
    if (!gamepad || !gamepad.buttons || buttonIndex < 0 || buttonIndex >= gamepad.buttons.length || !gamepad.buttons[buttonIndex]) {
        return false;
    }
    const pressedNow = buttonIsPressed(gamepad, buttonIndex);
    const buttonId = `${gamepad.index}-${buttonIndex}`;
    const wasPressed = previousButtonStates[buttonId] === true;
    previousButtonStates[buttonId] = pressedNow;
    return pressedNow && !wasPressed;
}

function isAnyButtonJustPressed(gamepad, buttonIndices) {
    return buttonIndices.some((buttonIndex) => isButtonJustPressed(gamepad, buttonIndex));
}

function detectControllerType(gamepad) {
    if (!gamepad) return 'UNKNOWN';
    if (gamepad.mapping === 'standard') return 'STANDARD_GAMEPAD';
    if (!gamepad.id) return 'UNKNOWN';

    const id = gamepad.id.toLowerCase();
    if (id.includes('xbox') || id.includes('xinput')) {
        return 'XBOX_LEGACY';
    }
    if (
        id.includes('playstation') ||
        id.includes('ps4') ||
        id.includes('ps5') ||
        id.includes('dualshock')
    ) {
        return 'PLAYSTATION_LEGACY';
    }
    if (id.includes('joystick') || id.includes('hotas') || id.includes('flight') || id.includes('stick')) {
        return 'JOYSTICK';
    }
    if (
        id.includes('gamepad') ||
        ((gamepad.buttons ? gamepad.buttons.length : 0) >= 10 && (gamepad.axes ? gamepad.axes.length : 0) >= 4)
    ) {
        return 'GENERIC_GAMEPAD';
    }
    return 'JOYSTICK';
}

function getConnectedGamepads() {
    try {
        const gps = navigator.getGamepads ? navigator.getGamepads() : [];
        return Array.from(gps).filter((gp) => gp && gp.connected);
    } catch (e) {
        console.error("Error accessing gamepads:", e);
        return [];
    }
}

function getValidGamepad() {
    const connectedGamepads = getConnectedGamepads();
    if (!connectedGamepads.length) return null;

    let gamepad = null;
    if (gamepadIndex !== null) {
        gamepad = connectedGamepads.find((gp) => gp.index === gamepadIndex) || null;
    }

    if (!gamepad) {
        gamepad = connectedGamepads.find((gp) => gp.mapping === 'standard') || connectedGamepads[0];
        gamepadIndex = gamepad.index;
    }

    return {
        gamepad,
        type: detectControllerType(gamepad)
    };
}

function getPauseButtonCandidates(type) {
    if (type === 'STANDARD_GAMEPAD' || type === 'GENERIC_GAMEPAD' || type === 'XBOX_LEGACY') {
        return [STANDARD_GAMEPAD_BUTTONS.LEFT_CENTER];
    }
    if (type === 'PLAYSTATION_LEGACY') {
        return [STANDARD_GAMEPAD_BUTTONS.LEFT_STICK];
    }
    if (type === 'JOYSTICK') {
        return [11];
    }
    return [STANDARD_GAMEPAD_BUTTONS.LEFT_CENTER, STANDARD_GAMEPAD_BUTTONS.RIGHT_CENTER];
}

function getResetButtonCandidates(type) {
    if (type === 'STANDARD_GAMEPAD' || type === 'GENERIC_GAMEPAD' || type === 'XBOX_LEGACY') {
        return [STANDARD_GAMEPAD_BUTTONS.RIGHT_CENTER];
    }
    if (type === 'PLAYSTATION_LEGACY') {
        return [STANDARD_GAMEPAD_BUTTONS.RIGHT_STICK];
    }
    if (type === 'JOYSTICK') {
        return [10];
    }
    return [STANDARD_GAMEPAD_BUTTONS.RIGHT_CENTER, STANDARD_GAMEPAD_BUTTONS.RIGHT_STICK];
}

function respawnAircraftOrReload() {
    if (typeof window.respawnAircraft === 'function') {
        window.respawnAircraft();
    } else {
        location.reload();
    }
}


// --- Keyboard State & Listeners ---
const keysPressed = {};
window.addEventListener('keydown', (event) => {
    // Block any pause/unpause or auto-start path until the startup loading
    // overlay has cleared. Keystrokes that ONLY toggle visualization flags
    // (F/V/S/C/R) and shift combos still work because they live after this
    // check.
    const simReady = window.simReadyToPlay === true;

    if (simReady && event.code === 'Space' && !event.repeat) {
        if (typeof pauseSimulation === 'function') {
            pauseSimulation();
        } else {
            console.warn("pauseSimulation function not found for spacebar.");
        }
    }

    // Auto-start simulation on any non-spacebar keypress if it's the very first play
    if (simReady && typeof isPaused !== 'undefined' && isPaused && typeof hasStartedOnce !== 'undefined' && !hasStartedOnce) {
        if (event.code !== 'Space') {
            hasStartedOnce = true;
            if (typeof pauseSimulation === 'function') pauseSimulation();
        }
    }

    if (!event.repeat) {
        if (event.code === 'KeyF') {
            show_force_vectors = (show_force_vectors === "true" || show_force_vectors === true) ? "false" : "true";
        }
        if (event.code === 'KeyV') {
            show_velocity_vectors = (show_velocity_vectors === "true" || show_velocity_vectors === true) ? "false" : "true";
        }
        if (event.code === 'KeyS') {
            show_trajectory = (show_trajectory === "true" || show_trajectory === true) ? "false" : "true";
        }
        if (event.code === 'KeyC') {
            if (typeof window.connectGeminiATC === 'function') {
                window.connectGeminiATC();
            } else {
                console.warn("Gemini ATC interface is not loaded.");
            }
        }
        // R = respawn aircraft at initial conditions (+ reload data), Shift+R = full page reload
        if (event.code === 'KeyR') {
            if (event.shiftKey) {
                location.reload();
            } else if (typeof window.respawnAircraft === 'function') {
                window.respawnAircraft();
            } else {
                location.reload();
            }
        }
    }

    keysPressed[event.code] = true;
});

window.addEventListener('keyup', (event) => {
    keysPressed[event.code] = false;
});

// --- Keyboard Flight Controls ---
//
// Slew-rate-limited target seeker.  A pressed key sets a TARGET (±AUTHORITY,
// or 0 if both opposing keys are held).  The live demand slews toward that
// target at a bounded rate (degrees of "virtual stick" per second), computed
// against the real browser-frame dt so the ramp is frame-rate independent.
// Releasing all keys retargets 0 at a faster (centring) rate, matching the
// feel of a spring-loaded stick.
//
// This replaces the previous binary "key → 0.8 / 0" assignment.  Without
// client-side smoothing, every press/release was a step change that the
// server-side actuator (default 1.0 /s) could not track without visible
// sawtooth/jitter — especially under variable frame time.
//
// The ±0.8 authority ceiling is preserved so overall aircraft handling
// matches the previous build.
const KEY_AUTHORITY = 0.8;

// deflect_rate: target-approach speed per second when a key is held.
// center_rate:  target-approach speed per second when no key is held
//               (spring-back is typically snappier than active deflect).
const KEY_PITCH_RATES = { deflect: 4.0, center: 6.0 };
const KEY_ROLL_RATES  = { deflect: 5.0, center: 8.0 };
const KEY_YAW_RATES   = { deflect: 3.0, center: 5.0 };

let _keyCtrlLastTimeSec = null;

function _keyAxisTarget(posKey, negKey) {
    const hasPos = !!keysPressed[posKey];
    const hasNeg = !!keysPressed[negKey];
    if (hasPos && hasNeg) return 0;       // opposing keys cancel, as before
    if (hasPos) return +KEY_AUTHORITY;
    if (hasNeg) return -KEY_AUTHORITY;
    return 0;
}

function _slewToward(current, target, rates, dt) {
    const rate = (target === 0) ? rates.center : rates.deflect;
    const maxStep = rate * dt;
    const delta = target - current;
    if (Math.abs(delta) <= maxStep) return target;
    return current + Math.sign(delta) * maxStep;
}

function handleKeyboardControls(scene) {
    // Real browser dt, clamped so a missed frame or a tab-switch pause
    // doesn't snap the stick through a big jump.
    const nowSec = performance.now() / 1000.0;
    let dt = 1.0 / 60.0;
    if (_keyCtrlLastTimeSec !== null) {
        dt = Math.min(Math.max(nowSec - _keyCtrlLastTimeSec, 0.001), 0.1);
    }
    _keyCtrlLastTimeSec = nowSec;

    // Axis targets from current key state.  Sign convention preserved from
    // the previous implementation (KeyA=+pitch, KeyQ=−pitch; KeyO=+roll,
    // KeyP=−roll; KeyL=+yaw, KeyK=−yaw).
    const pitchTarget = _keyAxisTarget('KeyA', 'KeyQ');
    const rollTarget  = _keyAxisTarget('KeyO', 'KeyP');
    const yawTarget   = _keyAxisTarget('KeyL', 'KeyK');

    // Slew the live demands.  `|| 0` guards against any initial undefined.
    pitch_demand = _slewToward(pitch_demand || 0, pitchTarget, KEY_PITCH_RATES, dt);
    roll_demand  = _slewToward(roll_demand  || 0, rollTarget,  KEY_ROLL_RATES,  dt);
    yaw_demand   = _slewToward(yaw_demand   || 0, yawTarget,   KEY_YAW_RATES,   dt);

    for (let digit = 0; digit <= 9; digit++) {
        if (keysPressed[`Digit${digit}`]) {
            thrust_setting_demand = digit * 0.1;
        }
    }
}

// --- Keyboard camera selection (runs every frame) ---
function handleKeyboardCameraKeys(scene) {
    if (typeof setActiveCamera !== 'function') return;

    if (keysPressed['KeyI'] && !previousButtonStates['KeyI']) setActiveCamera(0, scene);
    if (keysPressed['KeyU'] && !previousButtonStates['KeyU']) setActiveCamera(1, scene);
    if (keysPressed['KeyY'] && !previousButtonStates['KeyY']) setActiveCamera(2, scene);
    if (keysPressed['KeyT'] && !previousButtonStates['KeyT']) setActiveCamera(3, scene);

    previousButtonStates['KeyI'] = keysPressed['KeyI'];
    previousButtonStates['KeyU'] = keysPressed['KeyU'];
    previousButtonStates['KeyY'] = keysPressed['KeyY'];
    previousButtonStates['KeyT'] = keysPressed['KeyT'];
}


// --- Gamepad Pause Handling ---
function handleGamepadPause() {
    const valid = getValidGamepad();
    if (!valid) return;
    const { gamepad, type } = valid;

    if (typeof pauseSimulation !== 'function') {
        console.warn("pauseSimulation function not available for gamepad.");
        return;
    }

    if (isAnyButtonJustPressed(gamepad, getPauseButtonCandidates(type))) {
        const now = Date.now();
        if (now - lastPauseToggleTime > 500) {
            pauseSimulation();
            lastPauseToggleTime = now;
        }
    }
}

// --- Gamepad Flight Controls & Camera ---
function handleGamepadFlightAndCamera(scene) {
    const valid = getValidGamepad();
    if (!valid) {
        handleKeyboardControls(scene);
        return;
    }

    const { gamepad, type } = valid;
    const axes = gamepad.axes || [];
    joystickAxes = Array.from(axes);
    joystickButtons = Array.from(gamepad.buttons || [], (button) => {
        if (!button) return 0;
        if (typeof button.value === 'number') return button.value;
        return button.pressed ? 1 : 0;
    });

    roll_demand = 0;
    pitch_demand = 0;
    yaw_demand = 0;

    const doSetActiveCamera = (idx, scn) => {
        if (typeof setActiveCamera === 'function') setActiveCamera(idx, scn);
    };

    // Sim convention:
    //   pitch_demand > 0 -> nose up
    //   yaw_demand   > 0 -> nose right
    //   roll_demand  > 0 -> right bank
    if (type === 'STANDARD_GAMEPAD' || type === 'GENERIC_GAMEPAD' || type === 'XBOX_LEGACY') {
        const leftX = applyAxisDeadzone(getAxisValue(axes, 0));
        const leftY = applyAxisDeadzone(getAxisValue(axes, 1));
        const rightX = applyAxisDeadzone(getAxisValue(axes, 2));
        const rightY = applyAxisDeadzone(getAxisValue(axes, 3));

        thrust_setting_demand = axisToThrottle(leftY);
        roll_demand = -rightX;
        pitch_demand = rightY;
        yaw_demand = leftX;

        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_DOWN)) doSetActiveCamera(0, scene);
        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_RIGHT)) doSetActiveCamera(2, scene);
        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_LEFT)) doSetActiveCamera(3, scene);
        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_UP)) doSetActiveCamera(1, scene);

        if (isAnyButtonJustPressed(gamepad, getResetButtonCandidates(type))) {
            respawnAircraftOrReload();
        }

    } else if (type === 'PLAYSTATION_LEGACY') {
        const rollAxis = applyAxisDeadzone(getAxisValue(axes, 0));
        const pitchAxis = applyAxisDeadzone(getAxisValue(axes, 1));
        const throttleAxis = applyAxisDeadzone(getAxisValue(axes, 2));
        const yawAxis = applyAxisDeadzone(axes.length > 5 ? getAxisValue(axes, 5) : getAxisValue(axes, 2));

        thrust_setting_demand = axisToThrottle(throttleAxis);
        roll_demand = -rollAxis;
        pitch_demand = -pitchAxis;
        yaw_demand = -yawAxis;

        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_DOWN)) doSetActiveCamera(0, scene);
        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_RIGHT)) doSetActiveCamera(2, scene);
        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_LEFT)) doSetActiveCamera(3, scene);
        if (isButtonJustPressed(gamepad, STANDARD_GAMEPAD_BUTTONS.FACE_UP)) doSetActiveCamera(1, scene);

        if (isAnyButtonJustPressed(gamepad, getResetButtonCandidates(type))) {
            respawnAircraftOrReload();
        }

    } else if (type === 'JOYSTICK') {
        const rollAxis = applyAxisDeadzone(getAxisValue(axes, 0));
        const pitchAxis = applyAxisDeadzone(getAxisValue(axes, 1));
        const yawAxis = applyAxisDeadzone(
            axes.length > 5 ? getAxisValue(axes, 5) :
            (axes.length > 3 ? getAxisValue(axes, 2) : 0)
        );
        const throttleAxis = applyAxisDeadzone(
            axes.length > 3 ? getAxisValue(axes, 3) : getAxisValue(axes, 2)
        );

        roll_demand = -rollAxis;
        pitch_demand = -pitchAxis;
        thrust_setting_demand = axisToThrottle(throttleAxis);
        yaw_demand = -yawAxis;

        if (isButtonJustPressed(gamepad, 2)) doSetActiveCamera(0, scene);
        if (isButtonJustPressed(gamepad, 1)) doSetActiveCamera(1, scene);
        if (isButtonJustPressed(gamepad, 0)) doSetActiveCamera(2, scene);
        if (isButtonJustPressed(gamepad, 3)) doSetActiveCamera(3, scene);

        if (isAnyButtonJustPressed(gamepad, getResetButtonCandidates(type))) {
            respawnAircraftOrReload();
        }

    } else {
        const leftX = applyAxisDeadzone(getAxisValue(axes, 0));
        const leftY = applyAxisDeadzone(getAxisValue(axes, 1));
        const rightX = applyAxisDeadzone(getAxisValue(axes, 2));
        const rightY = applyAxisDeadzone(getAxisValue(axes, 3));

        roll_demand = -rightX;
        pitch_demand = rightY;
        yaw_demand = leftX;
        thrust_setting_demand = axisToThrottle(leftY);

        for (let camBtn = 0; camBtn < 4; camBtn++) {
            if (isButtonJustPressed(gamepad, camBtn)) {
                doSetActiveCamera(camBtn, scene);
            }
        }

        if (isAnyButtonJustPressed(gamepad, getResetButtonCandidates(type))) {
            respawnAircraftOrReload();
        }
    }
}


// ------------------------------------------------------------
// 7) Master update function
//    Called each frame by the main render loop (6.1_...)
// ------------------------------------------------------------
function updateForcesFromJoystickOrKeyboard(scene) {
    if (typeof isPaused !== 'undefined' && isPaused) {
        return;
    }

    try {
        const connectedIndices = {};
        const gps = navigator.getGamepads ? navigator.getGamepads() : [];
        for (const gp of gps) {
            if (gp && gp.connected) {
                connectedIndices[gp.index] = true;
            }
        }
        for (const key in previousButtonStates) {
            if (key.includes('-')) {
                const index = parseInt(key.split('-')[0], 10);
                if (!isNaN(index) && !connectedIndices[index]) {
                    delete previousButtonStates[key];
                }
            } else if (!keysPressed[key]) {
                delete previousButtonStates[key];
            }
        }
    } catch (e) {
        console.error("Error cleaning up button states:", e);
    }

    handleGamepadFlightAndCamera(scene);
    handleKeyboardCameraKeys(scene);
}
