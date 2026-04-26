// 7.1_🎤_mic_audio_worklet.js
// This script runs an AudioWorkletProcessor to convert the raw microphone 
// input to 16kHz PCM16 data, which is required by the Gemini Live API.

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
            const channelData = input[0]; // Mono audio only
            
            for (let i = 0; i < channelData.length; i++) {
                // Convert Float32 [-1.0, 1.0] to Int16 [-32768, 32767]
                let s = Math.max(-1, Math.min(1, channelData[i]));
                s = s < 0 ? s * 0x8000 : s * 0x7FFF;
                
                this.outBuffer[this.bufferIndex++] = s;

                // Send chunk back to main thread when full
                if (this.bufferIndex >= this.outBuffer.length) {
                    // We must copy the buffer because we transfer it or overwrite it
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
