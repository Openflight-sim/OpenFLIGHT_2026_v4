/***************************************************************
 * 1.1_ðŸ”_exchange_aircraft_state_with_server.js
 *
 * **MODIFIED FOR MsgPack & DOMContentLoaded**
 * **MODIFIED TO USE nz FOR LOAD FACTOR**
 * Manages the WebSocket connection with the Julia server using
 * binary MsgPack format for high performance. The code is wrapped
 * in a DOMContentLoaded listener to ensure libraries are loaded first.
 ***************************************************************/

// Authoritative last-known-server pose. The render loop draws from a short
// visual-only pose buffer derived from these samples to hide variable
// WebSocket/solver cadence jitter, while sendStateToServer() echoes the
// authoritative pose (NOT the smoothed visual pose) back to Julia so the
// physics feedback loop stays on the server's own output.
window.authoritativePosition = { x: 0, y: 0, z: 0 };
window.authoritativeOrientation = { x: 0, y: 0, z: 0, w: 1 };
window.authoritativeVelocity = { x: 0, y: 0, z: 0 };
window.authoritativePoseBuffer = [];
window.authoritativePoseBufferHasServerSample = false;
window.authoritativePoseSampleServerTimeS = null;
window.authoritativePoseResetToken = 0;
window.aircraftRenderSettingsSignature = null;

function stablePayloadSignature(value) {
    if (value === null || typeof value !== 'object') {
        return JSON.stringify(value);
    }
    if (Array.isArray(value)) {
        return "[" + value.map(stablePayloadSignature).join(",") + "]";
    }
    const keys = Object.keys(value).sort();
    return "{" + keys.map((key) => JSON.stringify(key) + ":" + stablePayloadSignature(value[key])).join(",") + "}";
}

function makeAuthoritativePoseSample(position, quaternion, clientTimeMs, linearVelocity = null) {
    return {
        clientTimeMs,
        x: position.x,
        y: position.y,
        z: position.z,
        vx: linearVelocity && Number.isFinite(linearVelocity.x) ? linearVelocity.x : null,
        vy: linearVelocity && Number.isFinite(linearVelocity.y) ? linearVelocity.y : null,
        vz: linearVelocity && Number.isFinite(linearVelocity.z) ? linearVelocity.z : null,
        qx: quaternion.x,
        qy: quaternion.y,
        qz: quaternion.z,
        qw: quaternion.w
    };
}

window.resetAuthoritativePoseBuffer = function (position, quaternion, clientTimeMs = performance.now(), linearVelocity = null) {
    window.authoritativePoseBuffer = [
        makeAuthoritativePoseSample(position, quaternion, clientTimeMs, linearVelocity)
    ];
    if (linearVelocity &&
        Number.isFinite(linearVelocity.x) &&
        Number.isFinite(linearVelocity.y) &&
        Number.isFinite(linearVelocity.z)) {
        window.authoritativeVelocity.x = linearVelocity.x;
        window.authoritativeVelocity.y = linearVelocity.y;
        window.authoritativeVelocity.z = linearVelocity.z;
    }
    window.authoritativePoseResetToken = (window.authoritativePoseResetToken || 0) + 1;
};

window.pushAuthoritativePoseSample = function (position, quaternion, clientTimeMs = performance.now(), linearVelocity = null) {
    const buffer = Array.isArray(window.authoritativePoseBuffer)
        ? window.authoritativePoseBuffer
        : [];
    const last = buffer.length > 0 ? buffer[buffer.length - 1] : null;
    const monotonicTimeMs = (last && clientTimeMs <= last.clientTimeMs)
        ? last.clientTimeMs + 0.001
        : clientTimeMs;
    buffer.push(makeAuthoritativePoseSample(position, quaternion, monotonicTimeMs, linearVelocity));
    if (linearVelocity &&
        Number.isFinite(linearVelocity.x) &&
        Number.isFinite(linearVelocity.y) &&
        Number.isFinite(linearVelocity.z)) {
        window.authoritativeVelocity.x = linearVelocity.x;
        window.authoritativeVelocity.y = linearVelocity.y;
        window.authoritativeVelocity.z = linearVelocity.z;
    }
    while (buffer.length > 80) buffer.shift();
    window.authoritativePoseBuffer = buffer;
};

// NEW: Wait for the DOM and all scripts to be loaded before executing.
window.addEventListener('DOMContentLoaded', (event) => {
    console.log("OpenFlight WS client version: 20260419_2258");
    let loggedTelemetryKeys = false;
    // Initialize WebSocket connection
    // freeport is a variable that holds the port number of the server, defined in
    // "src/ðŸŸ¡JAVASCRIPTðŸŸ¡/0_INITIALIZATION/0.1_ðŸ§¾_initializations.js" by the Julia code
    // "src/ðŸŸ£JULIAðŸŸ£/1_Maths_and_Auxiliary_Functions/1.0_ðŸ“š_Check_packages_and_websockets_port/ðŸ”Œ_Find_free_port.jl"
    let ws = null;
    let reconnectTimer = null;
    const reconnectDelayMs = 500;
    let loggedDisconnectedState = false;
    const telemetryChannel = (typeof BroadcastChannel !== "undefined")
        ? new BroadcastChannel("openflight_telemetry")
        : null;
    const telemetryBroadcastIntervalMs = 100;
    let lastTelemetryBroadcastMs = 0;

    // Keep track of the last update time to compute a variable deltaTime for server calls.
    let lastUpdateTime = performance.now();
    let accumulatedDeltaTime = 0.0;
    let isWaitingForServerResponse = false;
    let startupIterations = 0;

    window.addEventListener("beforeunload", () => {
        if (telemetryChannel) telemetryChannel.close();
    });

    function scheduleReconnect() {
        if (reconnectTimer !== null) return;
        reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            connectWebSocket();
        }, reconnectDelayMs);
    }

    function connectWebSocket() {
        const currentWs = new WebSocket(`ws://localhost:${freeport}`);
        currentWs.binaryType = "arraybuffer";
        ws = currentWs;

        currentWs.onopen = () => {
            loggedDisconnectedState = false;
            window.initialDataReceived = false;
            window.authoritativePoseSampleServerTimeS = null;
            console.log('Connected to WebSocket server (using MsgPack)');

            // Send an initial state immediately so the server's readguarded()
            // receives data right away and doesn't drop the idle connection.
            // Seed the authoritative buffer from aircraft.position so the
            // first render frames (before any server reply) have a valid
            // target to smooth toward.
            try {
                const seedX = aircraft ? aircraft.position.x : -250;
                const seedY = aircraft ? aircraft.position.y : (initial_altitude || 200);
                const seedZ = aircraft ? aircraft.position.z : 0;
                window.authoritativePosition.x = seedX;
                window.authoritativePosition.y = seedY;
                window.authoritativePosition.z = seedZ;
                window.authoritativeVelocity.x = velocity.x;
                window.authoritativeVelocity.y = velocity.y;
                window.authoritativeVelocity.z = velocity.z;
                window.authoritativeOrientation.x = orientation.x;
                window.authoritativeOrientation.y = orientation.y;
                window.authoritativeOrientation.z = orientation.z;
                window.authoritativeOrientation.w = orientation.w;
                if (typeof window.resetAuthoritativePoseBuffer === 'function') {
                    window.resetAuthoritativePoseBuffer(
                        window.authoritativePosition,
                        window.authoritativeOrientation,
                        performance.now(),
                        typeof velocity !== 'undefined' ? velocity : null
                    );
                }
                window.authoritativePoseBufferHasServerSample = false;
                const initState = {
                    x: seedX,
                    y: seedY,
                    z: seedZ,
                    vx: velocity.x, vy: velocity.y, vz: velocity.z,
                    qx: orientation.x, qy: orientation.y, qz: orientation.z, qw: orientation.w,
                    wx: angularVelocity.x, wy: angularVelocity.y, wz: angularVelocity.z,
                    fx: 0, fy: 0,
                    thrust_setting_demand: thrust_setting_demand,
                    roll_demand: 0, pitch_demand: 0, yaw_demand: 0,
                    thrust_attained: thrust_attained,
                    throttle_demand_vector: [thrust_setting_demand],
                    throttle_attained_vector: [thrust_attained],
                    configuration: configuration,
                    roll_demand_attained: 0, pitch_demand_attained: 0, yaw_demand_attained: 0,
                    deltaTime: 0.001
                };
                currentWs.send(msgpack.encode(initState));
                isWaitingForServerResponse = true;
                lastUpdateTime = performance.now();
                accumulatedDeltaTime = 0.0;
            } catch (e) {
                console.warn("Failed to send initial state on WS open:", e);
            }
        };

        currentWs.onerror = (error) => {
            console.error('WebSocket Error:', error);
        };

        currentWs.onclose = (event) => {
            if (ws === currentWs) {
                ws = null;
            }
            window.initialDataReceived = false;
            console.log(`WebSocket closed (code=${event.code}, reason=${event.reason || 'n/a'})`);
            scheduleReconnect();
        };

        currentWs.onmessage = handleServerMessage;
    }

    // --------------------------------------------------------------------------
    // Function to send aircraft state to server.
    // --------------------------------------------------------------------------
    function normalizeThrottleVector(vectorValue, demandedCount, fallbackValue) {
        const count = Math.max(1, parseInt(demandedCount || 1, 10));
        // Always fill with the fallbackValue (the scalar thrust setting)
        // since JS input controls only provide a single unified throttle.
        return Array(count).fill(fallbackValue);
    }

    function sendStateToServer() {
        const currentTime = performance.now();
        const deltaTime = (currentTime - lastUpdateTime) / 1000.0; // ms -> s
        lastUpdateTime = currentTime;
        accumulatedDeltaTime += deltaTime;

        if (!ws || ws.readyState !== WebSocket.OPEN) {
            if (!loggedDisconnectedState) {
                console.warn('WebSocket is not connected (waiting for reconnect)');
                loggedDisconnectedState = true;
            }
            return;
        }
        loggedDisconnectedState = false;

        if (!aircraft || !orientation) {
            return;
        }

        // Freeze simulation advance while a GLB aircraft model is being
        // downloaded/uploaded. The mesh upload + shader compile on the
        // first render frame after it becomes visible causes a visible
        // multi-hundred-ms stall; running physics through that window
        // would let the aircraft lurch forward when the gate is released.
        // resetServerDataTimer() will be called by _finishGlbGate() when
        // loading completes, so we don't need to reset here.
        if (window.isGlbLoading) {
            accumulatedDeltaTime = 0.0;
            return;
        }

        if (isWaitingForServerResponse) {
            return; // Wait for previous frame's physics response
        }

        // Force stabilization for the first 10 frames sent to the Julia physics server
        if (startupIterations < 10) {
            startupIterations++;

            velocity.x = typeof initial_velocity !== 'undefined' ? initial_velocity : 30;
            velocity.y = 0;
            velocity.z = 0;
            window.authoritativeVelocity.x = velocity.x;
            window.authoritativeVelocity.y = velocity.y;
            window.authoritativeVelocity.z = velocity.z;

            angularVelocity.x = 0;
            angularVelocity.y = 0;
            angularVelocity.z = 0;

            pitch_demand = 0;
            roll_demand = 0;
            yaw_demand = 0;
            throttle_demand_vector = normalizeThrottleVector(throttle_demand_vector, engine_count, thrust_setting_demand);
            throttle_attained_vector = normalizeThrottleVector(throttle_attained_vector, engine_count, thrust_attained);

            orientation.x = 0;
            orientation.y = 0;
            orientation.z = 0;
            orientation.w = 1;
        }

        // IMPORTANT: echo the AUTHORITATIVE server pose back, NOT aircraft.position.
        // aircraft.position is exponentially smoothed in the render loop (see
        // 6.1_...) and always lags the true server state by ~40 ms. Feeding
        // the smoothed pose back would inject a per-frame latency bias into
        // the physics, causing the aircraft to slowly drift behind reality.
        const aircraftState = {
            x: window.authoritativePosition.x,
            y: window.authoritativePosition.y,
            z: window.authoritativePosition.z,
            vx: velocity.x,
            vy: velocity.y,
            vz: velocity.z,
            qx: orientation.x,
            qy: orientation.y,
            qz: orientation.z,
            qw: orientation.w,
            wx: angularVelocity.x,
            wy: angularVelocity.y,
            wz: angularVelocity.z,
            fx: forceX,
            fy: forceY,
            thrust_setting_demand: thrust_setting_demand,
            roll_demand: roll_demand,
            pitch_demand: pitch_demand,
            yaw_demand: yaw_demand,
            thrust_attained: thrust_attained,
            throttle_demand_vector: normalizeThrottleVector(throttle_demand_vector, engine_count, thrust_setting_demand),
            throttle_attained_vector: normalizeThrottleVector(throttle_attained_vector, engine_count, thrust_attained),
            configuration: configuration,
            roll_demand_attained: roll_demand_attained,
            pitch_demand_attained: pitch_demand_attained,
            yaw_demand_attained: yaw_demand_attained,
            deltaTime: accumulatedDeltaTime
        };

        isWaitingForServerResponse = true;
        accumulatedDeltaTime = 0.0;

        // Send state as a binary MsgPack object
        ws.send(msgpack.encode(aircraftState));
    }

    // --------------------------------------------------------------------------
    // Message handler for receiving server updates.
    // --------------------------------------------------------------------------
    function handleServerMessage(event) {
        try {
            isWaitingForServerResponse = false;
            // Parse received binary data using MsgPack.decode
            const responseData = msgpack.decode(new Uint8Array(event.data));

            // ── Handle reload acknowledgment from server ────────────
            if (responseData.reload_ack) {
                if (responseData.reload_success) {
                    console.log("Server data reload SUCCESSFUL — aircraft & mission data updated");
                } else {
                    console.warn("Server data reload completed with errors — check server console");
                }
                // Reset stabilization so the next frames use the new data cleanly
                startupIterations = 0;
                return; // Skip normal state processing
            }

            if (telemetryChannel) {
                const nowMs = performance.now();
                if (nowMs - lastTelemetryBroadcastMs >= telemetryBroadcastIntervalMs) {
                    telemetryChannel.postMessage({
                        type: "telemetry",
                        data: responseData,
                        timestampMs: Date.now()
                    });
                    lastTelemetryBroadcastMs = nowMs;
                }
            }
            if (!loggedTelemetryKeys) {
                console.log("OpenFlight telemetry keys:", Object.keys(responseData));
                loggedTelemetryKeys = true;
            }
            let dataIsValid = true;
            let poseDataIsValid = true;
            let linearVelocityDataIsValid = true;
            const responseServerTimeS = ("server_time" in responseData)
                ? parseFloat(responseData.server_time)
                : NaN;
            const responseServerTimeIsValid = Number.isFinite(responseServerTimeS);
            const poseSampleReceiveTimeMs = performance.now();

            if (aircraft && aircraft.position) {
                const newX = parseFloat(responseData.x);
                const newY = parseFloat(responseData.y);
                const newZ = parseFloat(responseData.z);
                // Authoritative write — this is what the next send will echo
                // back to the server and what the render loop smooths toward.
                if (!isNaN(newX)) window.authoritativePosition.x = newX; else { dataIsValid = false; poseDataIsValid = false; }
                if (!isNaN(newY)) window.authoritativePosition.y = newY; else { dataIsValid = false; poseDataIsValid = false; }
                if (!isNaN(newZ)) window.authoritativePosition.z = newZ; else { dataIsValid = false; poseDataIsValid = false; }
                // On the first valid server frame, snap the visual aircraft
                // into place so we don't visibly ramp in from the placeholder
                // spawn position. Subsequent frames are smoothed by the
                // render loop (see 6.1_...).
                if (poseDataIsValid && !window.initialDataReceived) {
                    aircraft.position.x = window.authoritativePosition.x;
                    aircraft.position.y = window.authoritativePosition.y;
                    aircraft.position.z = window.authoritativePosition.z;
                }
            } else {
                dataIsValid = false;
            }

            const newVx = parseFloat(responseData.vx);
            const newVy = parseFloat(responseData.vy);
            const newVz = parseFloat(responseData.vz);
            if (!isNaN(newVx)) velocity.x = newVx; else { dataIsValid = false; linearVelocityDataIsValid = false; }
            if (!isNaN(newVy)) velocity.y = newVy; else { dataIsValid = false; linearVelocityDataIsValid = false; }
            if (!isNaN(newVz)) velocity.z = newVz; else { dataIsValid = false; linearVelocityDataIsValid = false; }
            if (linearVelocityDataIsValid) {
                window.authoritativeVelocity.x = velocity.x;
                window.authoritativeVelocity.y = velocity.y;
                window.authoritativeVelocity.z = velocity.z;
            }

            const newQx = parseFloat(responseData.qx);
            const newQy = parseFloat(responseData.qy);
            const newQz = parseFloat(responseData.qz);
            const newQw = parseFloat(responseData.qw);
            if (!isNaN(newQx)) orientation.x = newQx; else { dataIsValid = false; poseDataIsValid = false; }
            if (!isNaN(newQy)) orientation.y = newQy; else { dataIsValid = false; poseDataIsValid = false; }
            if (!isNaN(newQz)) orientation.z = newQz; else { dataIsValid = false; poseDataIsValid = false; }
            if (!isNaN(newQw)) orientation.w = newQw; else { dataIsValid = false; poseDataIsValid = false; }

            // Thrust Attained Mapping (Engine Delay Simulation)
            if ("thrust_attained" in responseData) {
                const newThrustAttained = parseFloat(responseData.thrust_attained);
                if (!isNaN(newThrustAttained)) window.thrust_attained = newThrustAttained;
            }

            if ("engine_count" in responseData) {
                const receivedEngineCount = parseInt(responseData.engine_count, 10);
                if (!isNaN(receivedEngineCount) && receivedEngineCount > 0) {
                    engine_count = receivedEngineCount;
                }
            }

            if ("throttle_demand_vector" in responseData && Array.isArray(responseData.throttle_demand_vector)) {
                throttle_demand_vector = normalizeThrottleVector(
                    responseData.throttle_demand_vector,
                    engine_count,
                    thrust_setting_demand
                );
            } else {
                throttle_demand_vector = normalizeThrottleVector(throttle_demand_vector, engine_count, thrust_setting_demand);
            }

            if ("throttle_attained_vector" in responseData && Array.isArray(responseData.throttle_attained_vector)) {
                throttle_attained_vector = normalizeThrottleVector(
                    responseData.throttle_attained_vector,
                    engine_count,
                    thrust_attained
                );
            } else {
                throttle_attained_vector = normalizeThrottleVector(throttle_attained_vector, engine_count, thrust_attained);
            }

            if ("configuration" in responseData && typeof responseData.configuration === "string") {
                configuration = responseData.configuration;
            }
            if ("available_configurations" in responseData && Array.isArray(responseData.available_configurations)) {
                available_configurations = responseData.available_configurations.map(String);
            }
            if ("aerodynamic_model_mode" in responseData && typeof responseData.aerodynamic_model_mode === "string") {
                window.aerodynamic_model_mode = responseData.aerodynamic_model_mode.toLowerCase();
            }

            const newWx = parseFloat(responseData.wx);
            const newWy = parseFloat(responseData.wy);
            const newWz = parseFloat(responseData.wz);
            if (!isNaN(newWx)) angularVelocity.x = newWx; else dataIsValid = false;
            if (!isNaN(newWy)) angularVelocity.y = newWy; else dataIsValid = false;
            if (!isNaN(newWz)) angularVelocity.z = newWz; else dataIsValid = false;

            const newFx = parseFloat(responseData.fx_global);
            const newFy = parseFloat(responseData.fy_global);
            const newFz = parseFloat(responseData.fz_global);
            if (!isNaN(newFx)) forceGlobalX = newFx; else dataIsValid = false;
            if (!isNaN(newFy)) forceGlobalY = newFy; else dataIsValid = false;
            if (!isNaN(newFz)) forceGlobalZ = newFz; else dataIsValid = false;

            // Aerodynamic component vectors and application points
            const newFxWing = parseFloat(responseData.fx_wing_global);
            const newFyWing = parseFloat(responseData.fy_wing_global);
            const newFzWing = parseFloat(responseData.fz_wing_global);
            if (!isNaN(newFxWing)) wingForceGlobalX = newFxWing;
            if (!isNaN(newFyWing)) wingForceGlobalY = newFyWing;
            if (!isNaN(newFzWing)) wingForceGlobalZ = newFzWing;

            const newFxTail = parseFloat(responseData.fx_tail_global);
            const newFyTail = parseFloat(responseData.fy_tail_global);
            const newFzTail = parseFloat(responseData.fz_tail_global);
            if (!isNaN(newFxTail)) tailForceGlobalX = newFxTail;
            if (!isNaN(newFyTail)) tailForceGlobalY = newFyTail;
            if (!isNaN(newFzTail)) tailForceGlobalZ = newFzTail;

            const newFxTailLift = parseFloat(responseData.fx_tail_lift_global);
            const newFyTailLift = parseFloat(responseData.fy_tail_lift_global);
            const newFzTailLift = parseFloat(responseData.fz_tail_lift_global);
            if (!isNaN(newFxTailLift)) tailLiftGlobalX = newFxTailLift;
            if (!isNaN(newFyTailLift)) tailLiftGlobalY = newFyTailLift;
            if (!isNaN(newFzTailLift)) tailLiftGlobalZ = newFzTailLift;

            const newWingOx = parseFloat(responseData.x_wing_force_origin_global);
            const newWingOy = parseFloat(responseData.y_wing_force_origin_global);
            const newWingOz = parseFloat(responseData.z_wing_force_origin_global);
            if (!isNaN(newWingOx)) wingForceOriginGlobalX = newWingOx;
            if (!isNaN(newWingOy)) wingForceOriginGlobalY = newWingOy;
            if (!isNaN(newWingOz)) wingForceOriginGlobalZ = newWingOz;

            const newTailOx = parseFloat(responseData.x_tail_force_origin_global);
            const newTailOy = parseFloat(responseData.y_tail_force_origin_global);
            const newTailOz = parseFloat(responseData.z_tail_force_origin_global);
            if (!isNaN(newTailOx)) tailForceOriginGlobalX = newTailOx;
            if (!isNaN(newTailOy)) tailForceOriginGlobalY = newTailOy;
            if (!isNaN(newTailOz)) tailForceOriginGlobalZ = newTailOz;

            const newWingLiftFx = parseFloat(responseData.fx_wing_lift_global);
            const newWingLiftFy = parseFloat(responseData.fy_wing_lift_global);
            const newWingLiftFz = parseFloat(responseData.fz_wing_lift_global);
            if (!isNaN(newWingLiftFx)) wingLiftGlobalX = newWingLiftFx;
            if (!isNaN(newWingLiftFy)) wingLiftGlobalY = newWingLiftFy;
            if (!isNaN(newWingLiftFz)) wingLiftGlobalZ = newWingLiftFz;

            const newHTailLiftFx = parseFloat(responseData.fx_htail_lift_global);
            const newHTailLiftFy = parseFloat(responseData.fy_htail_lift_global);
            const newHTailLiftFz = parseFloat(responseData.fz_htail_lift_global);
            if (!isNaN(newHTailLiftFx)) htailLiftGlobalX = newHTailLiftFx;
            if (!isNaN(newHTailLiftFy)) htailLiftGlobalY = newHTailLiftFy;
            if (!isNaN(newHTailLiftFz)) htailLiftGlobalZ = newHTailLiftFz;

            const newVTailLiftFx = parseFloat(responseData.fx_vtail_lift_global);
            const newVTailLiftFy = parseFloat(responseData.fy_vtail_lift_global);
            const newVTailLiftFz = parseFloat(responseData.fz_vtail_lift_global);
            if (!isNaN(newVTailLiftFx)) vtailLiftGlobalX = newVTailLiftFx;
            if (!isNaN(newVTailLiftFy)) vtailLiftGlobalY = newVTailLiftFy;
            if (!isNaN(newVTailLiftFz)) vtailLiftGlobalZ = newVTailLiftFz;

            const newHTailForceFx = parseFloat(responseData.fx_htail_force_global);
            const newHTailForceFy = parseFloat(responseData.fy_htail_force_global);
            const newHTailForceFz = parseFloat(responseData.fz_htail_force_global);
            if (!isNaN(newHTailForceFx)) htailForceGlobalX = newHTailForceFx; else htailForceGlobalX = htailLiftGlobalX;
            if (!isNaN(newHTailForceFy)) htailForceGlobalY = newHTailForceFy; else htailForceGlobalY = htailLiftGlobalY;
            if (!isNaN(newHTailForceFz)) htailForceGlobalZ = newHTailForceFz; else htailForceGlobalZ = htailLiftGlobalZ;

            const newVTailForceFx = parseFloat(responseData.fx_vtail_force_global);
            const newVTailForceFy = parseFloat(responseData.fy_vtail_force_global);
            const newVTailForceFz = parseFloat(responseData.fz_vtail_force_global);
            if (!isNaN(newVTailForceFx)) vtailForceGlobalX = newVTailForceFx; else vtailForceGlobalX = vtailLiftGlobalX;
            if (!isNaN(newVTailForceFy)) vtailForceGlobalY = newVTailForceFy; else vtailForceGlobalY = vtailLiftGlobalY;
            if (!isNaN(newVTailForceFz)) vtailForceGlobalZ = newVTailForceFz; else vtailForceGlobalZ = vtailLiftGlobalZ;

            const newHTailVelX = parseFloat(responseData.vx_htail_local_flow_global);
            const newHTailVelY = parseFloat(responseData.vy_htail_local_flow_global);
            const newHTailVelZ = parseFloat(responseData.vz_htail_local_flow_global);
            if (!isNaN(newHTailVelX)) htailLocalVelocityGlobalX = newHTailVelX;
            if (!isNaN(newHTailVelY)) htailLocalVelocityGlobalY = newHTailVelY;
            if (!isNaN(newHTailVelZ)) htailLocalVelocityGlobalZ = newHTailVelZ;

            const newVTailVelX = parseFloat(responseData.vx_vtail_local_flow_global);
            const newVTailVelY = parseFloat(responseData.vy_vtail_local_flow_global);
            const newVTailVelZ = parseFloat(responseData.vz_vtail_local_flow_global);
            if (!isNaN(newVTailVelX)) vtailLocalVelocityGlobalX = newVTailVelX;
            if (!isNaN(newVTailVelY)) vtailLocalVelocityGlobalY = newVTailVelY;
            if (!isNaN(newVTailVelZ)) vtailLocalVelocityGlobalZ = newVTailVelZ;

            const newWeightFx = parseFloat(responseData.fx_weight_global);
            const newWeightFy = parseFloat(responseData.fy_weight_global);
            const newWeightFz = parseFloat(responseData.fz_weight_global);
            if (!isNaN(newWeightFx)) weightForceGlobalX = newWeightFx;
            if (!isNaN(newWeightFy)) weightForceGlobalY = newWeightFy;
            if (!isNaN(newWeightFz)) weightForceGlobalZ = newWeightFz;

            const newWingLiftOx = parseFloat(responseData.x_wing_lift_origin_global);
            const newWingLiftOy = parseFloat(responseData.y_wing_lift_origin_global);
            const newWingLiftOz = parseFloat(responseData.z_wing_lift_origin_global);
            if (!isNaN(newWingLiftOx)) wingLiftOriginGlobalX = newWingLiftOx;
            if (!isNaN(newWingLiftOy)) wingLiftOriginGlobalY = newWingLiftOy;
            if (!isNaN(newWingLiftOz)) wingLiftOriginGlobalZ = newWingLiftOz;

            const newHTailLiftOx = parseFloat(responseData.x_htail_lift_origin_global);
            const newHTailLiftOy = parseFloat(responseData.y_htail_lift_origin_global);
            const newHTailLiftOz = parseFloat(responseData.z_htail_lift_origin_global);
            if (!isNaN(newHTailLiftOx)) htailLiftOriginGlobalX = newHTailLiftOx;
            if (!isNaN(newHTailLiftOy)) htailLiftOriginGlobalY = newHTailLiftOy;
            if (!isNaN(newHTailLiftOz)) htailLiftOriginGlobalZ = newHTailLiftOz;

            const newVTailLiftOx = parseFloat(responseData.x_vtail_lift_origin_global);
            const newVTailLiftOy = parseFloat(responseData.y_vtail_lift_origin_global);
            const newVTailLiftOz = parseFloat(responseData.z_vtail_lift_origin_global);
            if (!isNaN(newVTailLiftOx)) vtailLiftOriginGlobalX = newVTailLiftOx;
            if (!isNaN(newVTailLiftOy)) vtailLiftOriginGlobalY = newVTailLiftOy;
            if (!isNaN(newVTailLiftOz)) vtailLiftOriginGlobalZ = newVTailLiftOz;

            const newWeightOx = parseFloat(responseData.x_weight_origin_global);
            const newWeightOy = parseFloat(responseData.y_weight_origin_global);
            const newWeightOz = parseFloat(responseData.z_weight_origin_global);
            if (!isNaN(newWeightOx)) weightOriginGlobalX = newWeightOx;
            if (!isNaN(newWeightOy)) weightOriginGlobalY = newWeightOy;
            if (!isNaN(newWeightOz)) weightOriginGlobalZ = newWeightOz;

            if ("scale_tail_forces" in responseData) {
                const newScaleTailForces = parseFloat(responseData.scale_tail_forces);
                if (!isNaN(newScaleTailForces) && newScaleTailForces > 0) {
                    scale_tail_forces = newScaleTailForces;
                }
            }

            // --- Retrieve true local body offsets for accurate force visualization ---
            // Server sends each aerodynamic-center offset already converted to the
            // simulator/Babylon local body convention. Keep HTP and VTP independent.
            if (dataIsValid && typeof BABYLON !== 'undefined') {
                const vectorFromResponse = (xKey, yKey, zKey) => {
                    const x = parseFloat(responseData[xKey]);
                    const y = parseFloat(responseData[yKey]);
                    const z = parseFloat(responseData[zKey]);
                    if (![x, y, z].every(Number.isFinite)) return null;
                    return new BABYLON.Vector3(x, y, z);
                };

                const oxWing = parseFloat(responseData.x_wing_offset_body);
                const oyWing = parseFloat(responseData.y_wing_offset_body);
                const ozWing = parseFloat(responseData.z_wing_offset_body);
                if ([oxWing, oyWing, ozWing].every(Number.isFinite)) {
                    window.wingLiftLocalOffset = new BABYLON.Vector3(oxWing, oyWing, ozWing);
                }

                const htailOffset = vectorFromResponse("x_htail_offset_body", "y_htail_offset_body", "z_htail_offset_body");
                if (htailOffset) window.htailLiftLocalOffset = htailOffset;

                const vtailOffset = vectorFromResponse("x_vtail_offset_body", "y_vtail_offset_body", "z_vtail_offset_body");
                if (vtailOffset) window.vtailLiftLocalOffset = vtailOffset;

                window.weightLocalOffset = new BABYLON.Vector3(0, 0, 0); // Always at CoG
            }
            // ------------------------------------------------------------

            if (aircraft && aircraft.rotationQuaternion && poseDataIsValid) {
                // Normalize the authoritative orientation (the server should
                // send a unit quaternion, but network rounding can leak a
                // ULP-level norm error).  We normalize the authoritative
                // value itself so sendStateToServer echoes a unit quat back.
                const qNorm = Math.hypot(orientation.x, orientation.y, orientation.z, orientation.w);
                if (qNorm > 1e-12) {
                    orientation.x /= qNorm;
                    orientation.y /= qNorm;
                    orientation.z /= qNorm;
                    orientation.w /= qNorm;
                }
                window.authoritativeOrientation.x = orientation.x;
                window.authoritativeOrientation.y = orientation.y;
                window.authoritativeOrientation.z = orientation.z;
                window.authoritativeOrientation.w = orientation.w;
                // On the first valid frame, snap the visual quaternion so
                // the aircraft doesn't slerp in from the identity spawn
                // attitude.  Later frames are slerped by the render loop.
                if (!window.initialDataReceived) {
                    aircraft.rotationQuaternion.x = orientation.x;
                    aircraft.rotationQuaternion.y = orientation.y;
                    aircraft.rotationQuaternion.z = orientation.z;
                    aircraft.rotationQuaternion.w = orientation.w;
                }
                const pausedForPoseBuffer = (typeof isPaused !== 'undefined') ? !!isPaused : false;
                const previousPoseServerTimeS = Number(window.authoritativePoseSampleServerTimeS);
                const serverTimeAdvanced =
                    responseServerTimeIsValid &&
                    (!Number.isFinite(previousPoseServerTimeS) ||
                        responseServerTimeS > previousPoseServerTimeS + 1e-9);
                const poseVelocityForSample =
                    (!pausedForPoseBuffer && (!responseServerTimeIsValid || serverTimeAdvanced) && linearVelocityDataIsValid)
                        ? velocity
                        : null;

                if (pausedForPoseBuffer && typeof window.resetAuthoritativePoseBuffer === 'function') {
                    window.resetAuthoritativePoseBuffer(
                        window.authoritativePosition,
                        window.authoritativeOrientation,
                        poseSampleReceiveTimeMs,
                        null
                    );
                    window.authoritativePoseBufferHasServerSample = true;
                } else if (!window.authoritativePoseBufferHasServerSample && typeof window.resetAuthoritativePoseBuffer === 'function') {
                    window.resetAuthoritativePoseBuffer(
                        window.authoritativePosition,
                        window.authoritativeOrientation,
                        poseSampleReceiveTimeMs,
                        poseVelocityForSample
                    );
                    window.authoritativePoseBufferHasServerSample = true;
                } else if (typeof window.pushAuthoritativePoseSample === 'function') {
                    window.pushAuthoritativePoseSample(
                        window.authoritativePosition,
                        window.authoritativeOrientation,
                        poseSampleReceiveTimeMs,
                        poseVelocityForSample
                    );
                }
                if (responseServerTimeIsValid) {
                    window.authoritativePoseSampleServerTimeS = responseServerTimeS;
                }
            }

            const newAlpha = parseFloat(responseData.alpha_RAD);
            const newBeta = parseFloat(responseData.beta_RAD);
            if (!isNaN(newAlpha)) alpha_RAD = newAlpha; else dataIsValid = false;
            if (!isNaN(newBeta)) beta_RAD = newBeta; else dataIsValid = false;

            const newPitchAtt = parseFloat(responseData.pitch_demand_attained);
            const newRollAtt = parseFloat(responseData.roll_demand_attained);
            const newYawAtt = parseFloat(responseData.yaw_demand_attained);
            if (!isNaN(newPitchAtt)) pitch_demand_attained = newPitchAtt; else dataIsValid = false;
            if (!isNaN(newRollAtt)) roll_demand_attained = newRollAtt; else dataIsValid = false;
            if (!isNaN(newYawAtt)) yaw_demand_attained = newYawAtt; else dataIsValid = false;

            const newThrustAtt = parseFloat(responseData.thrust_attained);
            if (!isNaN(newThrustAtt)) thrust_attained = newThrustAtt; else dataIsValid = false;

            if ("server_time" in responseData) {
                if (responseServerTimeIsValid) {
                    window.serverElapsedTime = responseServerTimeS;
                } else {
                    dataIsValid = false;
                }
            } else {
                window.serverElapsedTime = window.serverElapsedTime || 0;
            }

            // --- MODIFIED: Load Factor using nz from server ---
            // The server should send 'nz' which is the load factor in body Z-axis
            if ("nz" in responseData) {
                const newNz = parseFloat(responseData.nz);
                if (!isNaN(newNz)) {
                    nz = newNz;
                } else {
                    nz = 1.0; // Default to 1G if invalid
                    dataIsValid = false;
                }
            } else {
                // If server doesn't send nz, default to 1G
                nz = 1.0;
            }
            // --- End Load Factor ---

            // --- Slip/Skid (ny lateral load factor) ---
            if ("ny" in responseData) {
                const newNy = parseFloat(responseData.ny);
                if (!isNaN(newNy)) {
                    window.ny = newNy;
                } else {
                    window.ny = 0.0;
                }
            } else {
                window.ny = 0.0;
            }
            // ------------------------------------------

            const newCL = parseFloat(responseData.CL);
            if (!isNaN(newCL)) currentCL = newCL;
            const newCD = parseFloat(responseData.CD);
            if (!isNaN(newCD)) currentCD = newCD;
            const newLD = parseFloat(responseData["CL/CD"]);
            if (!isNaN(newLD)) {
                currentLD = newLD;
            } else if (Math.abs(currentCD) > 1e-9) {
                currentLD = currentCL / currentCD;
            }

            if (!window.initialDataReceived && dataIsValid) {
                window.initialDataReceived = true;
                console.log("Initial VALID data received from server. Load factor nz enabled.");
            }

            // --- Extract Aerodynamic & Geometric Data for HUD ---
            if (!window.aeroData) {
                window.aeroData = {
                    aircraft_mass: 600, reference_area: 18.2, AR: 13.8, Oswald_factor: 0.8,
                    CD0: 0.013, CL_max: 1.2, alpha_stall_positive: 15.0, alpha_stall_negative: -15.0
                };
            }
            if ("CL_max" in responseData) window.aeroData.CL_max = parseFloat(responseData.CL_max);
            if ("CD0" in responseData) window.aeroData.CD0 = parseFloat(responseData.CD0);
            if ("AR" in responseData) window.aeroData.AR = parseFloat(responseData.AR);
            if ("Oswald_factor" in responseData) window.aeroData.Oswald_factor = parseFloat(responseData.Oswald_factor);
            if ("aircraft_mass" in responseData) window.aeroData.aircraft_mass = parseFloat(responseData.aircraft_mass);
            if ("reference_area" in responseData) window.aeroData.reference_area = parseFloat(responseData.reference_area);
            if ("alpha_stall_positive" in responseData) window.aeroData.alpha_stall_positive = parseFloat(responseData.alpha_stall_positive);
            if ("alpha_stall_negative" in responseData) window.aeroData.alpha_stall_negative = parseFloat(responseData.alpha_stall_negative);
            if ("recommended_initial_velocity_m_s" in responseData) {
                window.aeroData.recommended_initial_velocity_m_s = parseFloat(responseData.recommended_initial_velocity_m_s);
            }
            if ("stall_speed_analysis_altitude_m_s" in responseData) {
                window.aeroData.stall_speed_analysis_altitude_m_s = parseFloat(responseData.stall_speed_analysis_altitude_m_s);
            }

            // Guard against loading a high-wing-loading aircraft with the
            // default trainer/motor-glider launch speed. If the aircraft YAML
            // has no explicit recommendation yet, derive one from mass, Sref,
            // CLmax, and mission altitude.
            if (!window.initialSpeedGuardApplied && typeof initial_velocity !== 'undefined') {
                let recommendedSpeed = Number(window.aeroData.recommended_initial_velocity_m_s || 0);
                if (window.aeroData.aircraft_mass > 0 &&
                    window.aeroData.reference_area > 0 &&
                    window.aeroData.CL_max > 0) {
                    const h = Math.max(-500, Math.min(11000, Number(typeof initial_altitude !== 'undefined' ? initial_altitude : 0)));
                    const T0 = 288.15, p0 = 101325, L = 0.0065, R = 287.05, g = 9.80665;
                    const T = T0 - L * h;
                    const rho = p0 * Math.pow(T / T0, g / (R * L)) / (R * T);
                    const stall = Math.sqrt((2 * window.aeroData.aircraft_mass * g) /
                        (rho * window.aeroData.reference_area * window.aeroData.CL_max));
                    recommendedSpeed = Math.max(recommendedSpeed, 1.3 * stall);
                }
                if (recommendedSpeed > 0 && initial_velocity < 0.95 * recommendedSpeed) {
                    initial_velocity = Math.ceil(recommendedSpeed);
                    const currentSpeed = Math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z);
                    if (currentSpeed < 0.95 * recommendedSpeed) {
                        velocity.x = initial_velocity;
                        velocity.y = 0;
                        velocity.z = 0;
                        window.authoritativeVelocity.x = velocity.x;
                        window.authoritativeVelocity.y = velocity.y;
                        window.authoritativeVelocity.z = velocity.z;
                    }
                    window.initialSpeedGuardApplied = true;
                    console.warn("Initial velocity was below 1.3 x stall; raised to " + initial_velocity + " m/s for this aircraft.");
                }
            }
            // ----------------------------------------------------

            // --- Per-aircraft render overrides (if the aircraft folder ships
            // a `render_settings.yaml` next to its .glb, Julia parses it and
            // sends the resulting dict here). Consumed by the GLB loader
            // (4.3_🔼...) and the camera setup (6.4_🎦...).  Absence simply
            // means "use built-in defaults" — everything still works without
            // the YAML present, the overrides are strictly opt-in per
            // aircraft.  Captured before the glb_url handler below so the
            // GLB import sees the overrides on its first run.
            //
            // The server re-reads render_settings.yaml on every
            // respawn/reload_data, and this block fires on every incoming
            // frame that carries render_settings, so the following "edit
            // yaml → press restart → see the new values" workflow works
            // without restarting Julia:
            //   1. User edits render_settings.yaml in the aircraft folder.
            //   2. User presses respawn → respawnAircraft sends reload_data.
            //   3. Julia re-reads the file (see 3.1_...'s reload path).
            //   4. Next server reply carries the updated render_settings.
            //   5. This block stores them, re-places the cameras, and
            //      (via applyRenderSettingsToAircraft) re-places the GLB
            //      transform + lights + propeller on the already-loaded
            //      aircraft so the user sees the new values immediately.
            if ("render_settings" in responseData && responseData.render_settings &&
                typeof responseData.render_settings === 'object') {
                const renderSettingsSignature = stablePayloadSignature(responseData.render_settings);
                if (window.aircraftRenderSettingsSignature !== renderSettingsSignature) {
                    window.aircraftRenderSettingsSignature = renderSettingsSignature;
                    window.aircraftRenderSettings = responseData.render_settings;
                    // Re-place cameras against the (possibly new) camera_positions.
                    if (typeof aircraft !== 'undefined' && aircraft &&
                        window.scene && typeof window.scene.updateCamerasForAircraft === 'function') {
                        window.scene.updateCamerasForAircraft(aircraft);
                    }
                    // Re-apply GLB transform / lights / propeller to the live
                    // aircraft.  No-op if no GLB has been loaded (complexity 0
                    // or aircraft without a .glb).
                    if (typeof window.applyRenderSettingsToAircraft === 'function' && window.scene) {
                        window.applyRenderSettingsToAircraft(window.scene);
                    }
                }
            }

            // --- Auto-load GLB 3D model from server (once) ---
            // At scenery_complexity === 0 we intentionally skip the GLB download
            // and mesh upload. Even a "small" GLB triggers a multi-hundred-ms
            // stall on the render thread when Babylon uploads meshes/textures
            // and compiles materials, which shows up as a one-off jerk mid-flight.
            // The default simple aircraft (planeNode) stays visible instead.
            if (responseData.glb_url && !glbAutoLoaded &&
                typeof loadGLBFromURL === 'function' && window.scene &&
                scenery_complexity > 0) {
                console.log("GLB URL received from server:", responseData.glb_url);
                loadGLBFromURL(responseData.glb_url, window.scene, window.shadowGenerator);
            }

            // --- Apply Visual Geometry from server (once, only if no GLB) ---
            if ("visual_geometry" in responseData && responseData.visual_geometry &&
                typeof applyVisualGeometry === 'function' && window.scene) {
                applyVisualGeometry(responseData.visual_geometry, window.scene, window.shadowGenerator);
            }
            // ------------------------------------------------

        } catch (e) {
            console.error("Error processing WebSocket message:", e, "Data:", event.data);
        }
    }

    connectWebSocket();

    // **NEW: Make the sendStateToServer function globally accessible**
    // The main render loop in 6.1_...js needs to be able to call it.
    window.sendStateToServer = sendStateToServer;

    // **NEW: Request server to reload all external data (YAML files)**
    // Sends a special message with reload_data: true. The server re-reads
    // aircraft aero data and mission config, then sends an acknowledgment.
    window.requestServerDataReload = function () {
        if (!ws || ws.readyState !== WebSocket.OPEN) {
            console.warn("Cannot reload data — WebSocket is not connected");
            return;
        }
        window.initialSpeedGuardApplied = false;
        console.log("Requesting server data reload...");
        const reloadMsg = { reload_data: true };
        ws.send(msgpack.encode(reloadMsg));
    };

    // **NEW: Respawn aircraft at initial flight conditions**
    // Resets all client-side state and tells the server to reset dynamic stall.
    // Also reloads server data from YAML files.
    window.respawnAircraft = function () {
        console.log("Respawning aircraft to initial conditions...");
        window.initialSpeedGuardApplied = false;

        // Reset position — snap both visual and authoritative so the render
        // loop has a consistent target and doesn't smooth-interpolate from
        // the pre-respawn pose to the new spawn.
        const respawnX = -250;
        const respawnY = typeof initial_altitude !== 'undefined' ? initial_altitude : 200;
        const respawnZ = 0;
        if (aircraft && aircraft.position) {
            aircraft.position.x = respawnX;
            aircraft.position.y = respawnY;
            aircraft.position.z = respawnZ;
        }
        window.authoritativePosition.x = respawnX;
        window.authoritativePosition.y = respawnY;
        window.authoritativePosition.z = respawnZ;

        // Reset velocity to initial forward flight
        velocity.x = typeof initial_velocity !== 'undefined' ? initial_velocity : 30;
        velocity.y = 0;
        velocity.z = 0;
        window.authoritativeVelocity.x = velocity.x;
        window.authoritativeVelocity.y = velocity.y;
        window.authoritativeVelocity.z = velocity.z;

        // Reset orientation to level flight
        orientation.x = 0;
        orientation.y = 0;
        orientation.z = 0;
        orientation.w = 1;
        window.authoritativeOrientation.x = 0;
        window.authoritativeOrientation.y = 0;
        window.authoritativeOrientation.z = 0;
        window.authoritativeOrientation.w = 1;
        if (aircraft && aircraft.rotationQuaternion) {
            aircraft.rotationQuaternion.set(0, 0, 0, 1);
        }
        if (typeof window.resetAuthoritativePoseBuffer === 'function') {
            window.resetAuthoritativePoseBuffer(
                window.authoritativePosition,
                window.authoritativeOrientation,
                performance.now(),
                velocity
            );
        }
        window.authoritativePoseBufferHasServerSample = false;
        window.authoritativePoseSampleServerTimeS = null;

        // Reset angular velocity
        angularVelocity.x = 0;
        angularVelocity.y = 0;
        angularVelocity.z = 0;

        // Reset control demands
        roll_demand = 0;
        pitch_demand = 0;
        yaw_demand = 0;
        roll_demand_attained = 0;
        pitch_demand_attained = 0;
        yaw_demand_attained = 0;
        thrust_setting_demand = 0;
        thrust_attained = 0;
        forceX = 0;
        forceY = 0;

        // Reset timing to avoid physics explosions
        lastUpdateTime = performance.now();
        accumulatedDeltaTime = 0.0;
        // DO NOT reset `startupIterations` here. The initial-connect
        // stabilization zeroes pilot pitch/roll/yaw demands for 10 sends
        // (see sendStateToServer). Re-running that window on every respawn
        // blocks pilot input for ~10×RTT (up to ~1 s), which feels like the
        // controls are dead right after pressing the restart button on the
        // game controller. respawnAircraft already forces a clean state
        // (velocity, orientation, angular rates, demands) before the next
        // send, so the stabilization lockout is not needed on respawn.
        isWaitingForServerResponse = false;

        // Send a respawn + reload_data signal to the server so it resets
        // dynamic stall state and re-reads YAML files
        if (ws && ws.readyState === WebSocket.OPEN) {
            const respawnState = {
                x: window.authoritativePosition.x,
                y: window.authoritativePosition.y,
                z: window.authoritativePosition.z,
                vx: velocity.x, vy: 0, vz: 0,
                qx: 0, qy: 0, qz: 0, qw: 1,
                wx: 0, wy: 0, wz: 0,
                fx: 0, fy: 0,
                thrust_setting_demand: 0,
                roll_demand: 0, pitch_demand: 0, yaw_demand: 0,
                thrust_attained: 0,
                throttle_demand_vector: [0],
                throttle_attained_vector: [0],
                configuration: typeof configuration !== 'undefined' ? configuration : "clean",
                roll_demand_attained: 0, pitch_demand_attained: 0, yaw_demand_attained: 0,
                deltaTime: 0.001,
                respawn: true,
                reload_data: true
            };
            ws.send(msgpack.encode(respawnState));
            isWaitingForServerResponse = true;
        }

        console.log("Aircraft respawned at initial conditions.");
    };

    // **NEW: Expose a function to reset the delta time calculator**
    // Used when unpausing or after a heavy load to prevent physics explosions
    window.resetServerDataTimer = function () {
        lastUpdateTime = performance.now();
        accumulatedDeltaTime = 0.0;
        startupIterations = 0; // Restart stabilization forcing
    };

    // Keepalive: send a state update every 2 seconds when paused,
    // so the server's readguarded() doesn't time out the connection.
    setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN && isPaused && !isWaitingForServerResponse) {
            sendStateToServer.__keepalive = true;
            const keepaliveState = {
                x: window.authoritativePosition.x,
                y: window.authoritativePosition.y,
                z: window.authoritativePosition.z,
                vx: velocity.x, vy: velocity.y, vz: velocity.z,
                qx: orientation.x, qy: orientation.y, qz: orientation.z, qw: orientation.w,
                wx: 0, wy: 0, wz: 0,
                fx: 0, fy: 0,
                thrust_setting_demand: thrust_setting_demand,
                roll_demand: 0, pitch_demand: 0, yaw_demand: 0,
                thrust_attained: thrust_attained,
                throttle_demand_vector: [thrust_setting_demand],
                throttle_attained_vector: [thrust_attained],
                configuration: configuration,
                roll_demand_attained: 0, pitch_demand_attained: 0, yaw_demand_attained: 0,
                deltaTime: 0.0
            };
            ws.send(msgpack.encode(keepaliveState));
            isWaitingForServerResponse = true;
        }
    }, 2000);

}); // NEW: Close the DOMContentLoaded listener
