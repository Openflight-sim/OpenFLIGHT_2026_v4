// 7.2_📡_gemini_live_api_websocket.js
// This script manages the WebSocket connection to the Gemini Multimodal Live API,
// handles Push-To-Talk audio capture, streams audio via a Biquad radio effect, 
// and natively intercepts and processes MCP tool calls.

// =========================================================================
// Configuration
// =========================================================================
const GEMINI_HOST = "generativelanguage.googleapis.com";
const MODEL = "models/gemini-2.5-flash-native-audio-latest";

// Will be populated from localStorage or prompt
let GEMINI_API_KEY = localStorage.getItem("openflight_gemini_key") || "";

let ws = null;
let audioContext = null;
let mediaStream = null;
let workletNode = null;
let isPTTActive = false;
let isConnected = false;

// Expose these for the HUD
window.isATCConnected = false;
window.isPTTActive = false;
window.isATCReceiving = false;
let receivingTimeout = null;
let pttReleaseTime = 0;

// =========================================================================
// Definitions: The tools Gemini is allowed to call
// =========================================================================
const GEMINI_TOOLS = [
    {
        "functionDeclarations": [
            {
                "name": "get_aircraft_state",
                "description": "Returns current altitude (meters), speed (meters/sec), heading (degrees true), alpha (radians), and vertical speed (meters/sec) from the simulator.",
                // Schema can be empty if it takes no arguments
            },
            {
                "name": "set_comms_freq",
                "description": "Changes the aircraft's active VHF radio frequency.",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "frequency": {
                            "type": "NUMBER",
                            "description": "The new VHF frequency (e.g., 118.2)"
                        }
                    },
                    "required": ["frequency"]
                }
            }
        ]
    }
];

const SYSTEM_PROMPT = {
    "parts": [{
        "text": "You are a realistic approach and tower Air Traffic Controller (ATC). You provide highly immersive, professional aviation instructions using proper phraseology. Start short and direct. Wait for the pilot's request. You have access to real-time simulator tools. You MUST call the 'get_aircraft_state' tool to check the pilot's altitude and speed before providing instructions. Always base your auditory response on the flight data retrieved from the tool."
    }]
};

// =========================================================================
// 1. WebSocket Connection Logic
// =========================================================================
function connectGemini() {
    // Prevent multiple connection attempts
    if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) {
        console.warn("ATC: Already connecting or connected.");
        return;
    }

    if (!GEMINI_API_KEY) {
        GEMINI_API_KEY = prompt("Enter your Gemini API Key to enable Voice ATC. (Stored locally only)");
        if (!GEMINI_API_KEY) return;
        localStorage.setItem("openflight_gemini_key", GEMINI_API_KEY);
    }

    const url = `wss://${GEMINI_HOST}/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${GEMINI_API_KEY}`;

    console.log("Connecting to Gemini Live API...");
    ws = new WebSocket(url);

    ws.onopen = () => {
        isConnected = true;
        window.isATCConnected = true;
        console.log("ATC: Connected to Gemini");

        const setupMsg = {
            setup: {
                model: MODEL,
                generationConfig: {
                    responseModalities: ["AUDIO"],
                    speechConfig: {
                        voiceConfig: {
                            prebuiltVoiceConfig: {
                                voiceName: "Aoede"
                            }
                        }
                    }
                },
                systemInstruction: SYSTEM_PROMPT,
                tools: GEMINI_TOOLS
            }
        };

        // Ensure we send on the specific websocket instance that just opened
        const currentWs = event.target || ws;
        if (currentWs.readyState === WebSocket.OPEN) {
            currentWs.send(JSON.stringify(setupMsg));
        }

        initMicrophone();
        initAudioPlayback();
    };

    ws.onclose = (event) => {
        isConnected = false;
        window.isATCConnected = false;
        window.isPTTActive = false;
        window.isATCReceiving = false;
        console.log("ATC: Disconnected from Gemini. Code:", event.code, "Reason:", event.reason);

        // If the API key is invalid (Code 1007), clear it so the next connection prompts again
        if (event.code === 1007 && event.reason.includes("API key not valid")) {
            console.warn("ATC: API Key was invalid! Clearing saved key from Local Storage.");
            localStorage.removeItem("openflight_gemini_key");
            GEMINI_API_KEY = "";
            alert("Your Gemini API Key was invalid or expired. Please reload and press C to enter a new one.");
        }
    };

    ws.onmessage = handleGeminiMessage;
}

// =========================================================================
// 2. Handling Incoming Gemini Data (Audio and Tool Calls)
// =========================================================================
async function handleGeminiMessage(event) {
    let response;
    // Bidi Live API streams responses as JSON strings or JSON stringified representations of server content
    try {
        if (event.data instanceof Blob) {
            const text = await event.data.text();
            response = JSON.parse(text);
        } else {
            response = JSON.parse(event.data);
        }
    } catch (e) {
        console.error("Failed to parse Gemini message", e);
        return;
    }

    if (response.setupComplete) {
        console.log("ATC Setup Complete. Ready for PTT.");
        return;
    }

    // Log the raw server response to see exactly what we're getting back
    console.log("ATC Received:", response);

    if (response.toolCall && response.toolCall.functionCalls) {
        response.toolCall.functionCalls.forEach(call => {
            console.log("ATC AI requested a Tool Call payload from the Simulator:", call);
            executeTool(call);
        });
    }

    if (response.serverContent) {
        const { modelTurn } = response.serverContent;

        // --- Output Voice Audio ---
        if (modelTurn && modelTurn.parts) {
            modelTurn.parts.forEach(part => {
                if (part.inlineData && part.inlineData.data) {
                    window.isATCReceiving = true;
                    if (receivingTimeout) clearTimeout(receivingTimeout);
                    receivingTimeout = setTimeout(() => { window.isATCReceiving = false; }, 500);

                    console.log("ATC: Playing received audio chunk...");
                    playAudioChunk(part.inlineData.data);
                } else if (part.text) {
                    console.log("ATC Text Transcript:", part.text);
                }
            });
        }
    }
}

// =========================================================================
// 3. MCP Tool Executor
// =========================================================================
function executeTool(functionCall) {
    const { id, name, args } = functionCall;
    console.log(`ATC executing tool: ${name}`);

    let result = {};

    if (name === "get_aircraft_state") {
        // Compute heading based on quaternion (simplification for display)
        let heading = 0;
        if (typeof aircraft !== 'undefined' && aircraft && aircraft.rotationQuaternion) {
            const eul = aircraft.rotationQuaternion.toEulerAngles();
            heading = (eul.y * 180 / Math.PI + 360) % 360;
        }

        result = {
            altitude_meters: (typeof aircraft !== 'undefined' && aircraft && aircraft.position) ? Math.round(aircraft.position.y) : 0,
            speed_mps: (typeof velocity !== 'undefined' && velocity) ? Math.round(velocity.x) : 0,
            heading_deg: Math.round(heading),
            alpha_rad: (typeof alpha_RAD !== 'undefined') ? parseFloat(alpha_RAD.toFixed(2)) : 0
        };
    }
    else if (name === "set_comms_freq") {
        // In a real sim you'd update an internal variable. Here we just mock it for now.
        result = {
            success: true,
            new_frequency: args.frequency
        };
        console.log(`[SYS] VHF Radio tuned to ${args.frequency}`);
    } else {
        result = { error: "Unknown function" };
    }

    // Send the result back to Gemini
    const toolResponse = {
        toolResponse: {
            functionResponses: [{
                id: id,
                name: name,
                response: {
                    result: result
                }
            }]
        }
    };
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(toolResponse));
    }
}

// =========================================================================
// 4. Microphone Input (Push-To-Talk)
// =========================================================================
async function initMicrophone() {
    try {
        const AudioContext = window.AudioContext || window.webkitAudioContext;
        // Use 16kHz as expected by Gemini
        audioContext = new AudioContext({ sampleRate: 16000 });

        mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        const source = audioContext.createMediaStreamSource(mediaStream);

        // Load the AudioWorklet using a base64 Data URI string to bypass CORS on local file:/// execution
        const workletCode = `
class GeminiAudioProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        this.initialized = false;
        this.outBuffer = new Int16Array(2048);
        this.bufferIndex = 0;
        this.port.onmessage = (event) => {
            if (event.data.command === 'init') {
                this.initialized = true;
            }
        };
    }
    process(inputs, outputs, parameters) {
        if (!this.initialized) return true;
        const input = inputs[0];
        if (input.length > 0) {
            const channelData = input[0];
            for (let i = 0; i < channelData.length; i++) {
                let s = Math.max(-1, Math.min(1, channelData[i]));
                s = s < 0 ? s * 0x8000 : s * 0x7FFF;
                this.outBuffer[this.bufferIndex++] = s;
                if (this.bufferIndex >= this.outBuffer.length) {
                    const chunk = new Int16Array(this.outBuffer);
                    this.port.postMessage(chunk);
                    this.bufferIndex = 0;
                }
            }
        }
        return true;
    }
}
registerProcessor('gemini-audio-processor', GeminiAudioProcessor);
        `;

        const base64Code = window.btoa(workletCode);
        const dataUri = 'data:application/javascript;base64,' + base64Code;
        await audioContext.audioWorklet.addModule(dataUri);

        workletNode = new AudioWorkletNode(audioContext, 'gemini-audio-processor');
        source.connect(workletNode);

        // Listen for chunks from the processor
        workletNode.port.onmessage = (event) => {
            if ((isPTTActive || Date.now() - pttReleaseTime < 2000) && isConnected) {
                // event.data is Int16Array
                sendRealtimeAudioMsg(event.data);
            }
        };
        workletNode.port.postMessage({ command: 'init' });

        // Wire up PTT key (Enter)
        window.addEventListener('keydown', (e) => {
            if (e.code === 'Enter' && !e.repeat && !isPTTActive) {
                console.log("PTT: ON");
                isPTTActive = true;
                window.isPTTActive = true;
            }
        });

        window.addEventListener('keyup', (e) => {
            if (e.code === 'Enter' && isPTTActive) {
                console.log("PTT: OFF");
                isPTTActive = false;
                window.isPTTActive = false;
                pttReleaseTime = Date.now();
                // We let the trailing 2s window trigger native VAD instead of explicit turn ends.
            }
        });

    } catch (err) {
        console.error("Microphone access denied or error:", err);
    }
}

function sendRealtimeAudioMsg(pcm16Array) {
    // Convert Int16Array to base64
    const base64 = bufferToBase64(pcm16Array.buffer);
    const msg = {
        realtimeInput: {
            mediaChunks: [{
                mimeType: "audio/pcm;rate=16000",
                data: base64
            }]
        }
    };
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg));
    }
}

function sendTurnEnd() {
    // Explicitly signify the end of the user's turn
    const msg = {
        clientContent: {
            turns: [{
                role: "user",
                parts: []
            }],
            turnComplete: true
        }
    };
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg));
    }
}

// Helper: Fast arraybuffer to Base64
function bufferToBase64(buffer) {
    let binary = '';
    const bytes = new Uint8Array(buffer);
    const len = bytes.byteLength;
    for (let i = 0; i < len; i++) {
        binary += String.fromCharCode(bytes[i]);
    }
    return window.btoa(binary);
}

// =========================================================================
// 5. Audio Playback (Aviation Radio Effect)
// =========================================================================
// Re-use the existing context or create a new one for playback
let playContext = null;
let bandpassFilter = null;
// Keep track of audio time to sequence chunks without gaps
let nextPlayTime = 0;

function initAudioPlayback() {
    playContext = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 24000 }); // Gemini replies at 24kHz

    // Create the "Aviation Radio" Bandpass filter 
    bandpassFilter = playContext.createBiquadFilter();
    bandpassFilter.type = 'bandpass';
    bandpassFilter.frequency.value = 1500; // Center frequency
    bandpassFilter.Q.value = 1.0; // Defines bandwidth approx 300Hz-3000Hz

    // Optional distortion for extra realism
    const waveshaper = playContext.createWaveShaper();
    waveshaper.curve = makeDistortionCurve(10);
    waveshaper.oversample = '4x';

    bandpassFilter.connect(waveshaper);
    waveshaper.connect(playContext.destination);

    nextPlayTime = playContext.currentTime;
}

function playAudioChunk(base64Data) {
    if (!playContext) return;

    // Decode base64 to arrayBuffer
    const binary = window.atob(base64Data);
    const length = binary.length;
    // Data is PCM16 (2 bytes per sample)
    const buffer = new ArrayBuffer(length);
    const view = new Uint8Array(buffer);
    for (let i = 0; i < length; i++) {
        view[i] = binary.charCodeAt(i);
    }

    const int16data = new Int16Array(buffer);
    const float32Data = new Float32Array(int16data.length);
    for (let i = 0; i < int16data.length; i++) {
        float32Data[i] = int16data[i] / 32768.0;
    }

    // Create AudioBuffer
    const audioBuffer = playContext.createBuffer(1, float32Data.length, 24000);
    audioBuffer.getChannelData(0).set(float32Data);

    const source = playContext.createBufferSource();
    source.buffer = audioBuffer;
    source.connect(bandpassFilter);

    // Ensure chunks play gaplessly
    if (nextPlayTime < playContext.currentTime) {
        nextPlayTime = playContext.currentTime;
    }
    source.start(nextPlayTime);
    nextPlayTime += audioBuffer.duration;
}

// Helper: Make distortion curve
function makeDistortionCurve(amount) {
    let k = typeof amount === 'number' ? amount : 50;
    let n_samples = 44100;
    let curve = new Float32Array(n_samples);
    let deg = Math.PI / 180;
    for (let i = 0; i < n_samples; ++i) {
        let x = i * 2 / n_samples - 1;
        curve[i] = (3 + k) * x * 20 * deg / (Math.PI + k * Math.abs(x));
    }
    return curve;
}

// Expose connection launcher to window
window.connectGeminiATC = connectGemini;
