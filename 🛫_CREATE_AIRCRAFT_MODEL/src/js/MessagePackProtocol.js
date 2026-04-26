/**
 * MessagePackProtocol.js
 * 
 * MessagePack encoding/decoding for browser use.
 * Requires MessagePack library from CDN (loaded in HTML).
 * 
 * Usage: Include this file AFTER MessagePack CDN script
 * Access via window.MessagePackProtocol
 */

(function(window) {
    'use strict';
    
    // Check if MessagePack is available
    if (typeof MessagePack === 'undefined') {
        console.error('MessagePack library not loaded! Include it before this script.');
        return;
    }
    
    class MessagePackProtocol {
        static encode(data) {
            try {
                return MessagePack.encode(data);
            } catch (error) {
                console.error('[MessagePack] Encoding failed:', error);
                throw new Error(`MessagePack encoding failed: ${error.message}`);
            }
        }
        
        static decode(data) {
            try {
                const uint8Data = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
                return MessagePack.decode(uint8Data);
            } catch (error) {
                console.error('[MessagePack] Decoding failed:', error);
                throw new Error(`MessagePack decoding failed: ${error.message}`);
            }
        }
        
        static isMessagePackData(data) {
            return data instanceof ArrayBuffer || data instanceof Uint8Array;
        }
    }
    
    class MessagePackClient {
        constructor(wsClient) {
            this.wsClient = wsClient;
        }
        
        send(data) {
            try {
                const encoded = MessagePackProtocol.encode(data);
                return this.wsClient.send(encoded);
            } catch (error) {
                console.error('[MessagePackClient] Send failed:', error);
                return false;
            }
        }
        
        onMessage(callback) {
            this.wsClient.onMessage((rawData) => {
                try {
                    const decoded = MessagePackProtocol.decode(rawData);
                    callback(decoded);
                } catch (error) {
                    console.error('[MessagePackClient] Failed to decode message:', error);
                }
            });
            return this;
        }
        
        onOpen(callback) {
            this.wsClient.onOpen(callback);
            return this;
        }
        
        onClose(callback) {
            this.wsClient.onClose(callback);
            return this;
        }
        
        onError(callback) {
            this.wsClient.onError(callback);
            return this;
        }
        
        onReconnect(callback) {
            this.wsClient.onReconnect(callback);
            return this;
        }
        
        connect() {
            this.wsClient.connect();
            return this;
        }
        
        close() {
            this.wsClient.close();
            return this;
        }
        
        reconnect() {
            this.wsClient.reconnect();
            return this;
        }
        
        isConnected() {
            return this.wsClient.isConnected();
        }
        
        getState() {
            return this.wsClient.getState();
        }
        
        get client() {
            return this.wsClient;
        }
    }
    
    // Export to window
    window.MessagePackProtocol = MessagePackProtocol;
    window.MessagePackClient = MessagePackClient;
    
})(window);