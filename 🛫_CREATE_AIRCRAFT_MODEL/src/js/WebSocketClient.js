/**
 * WebSocketClient.js
 * 
 * Generic, reusable WebSocket client for browser use.
 * No Node.js or build tools required - works directly in browser.
 * 
 * Usage: Include this file with <script src="WebSocketClient.js"></script>
 * Access via window.WebSocketClient
 */

(function(window) {
    'use strict';
    
    class WebSocketClient {
        constructor(config = {}) {
            this.config = {
                url: config.url || 'ws://localhost:8081',
                reconnectDelay: config.reconnectDelay || 3000,
                maxReconnectAttempts: config.maxReconnectAttempts || 5,
                connectionTimeout: config.connectionTimeout || 10000,
                autoReconnect: config.autoReconnect !== undefined ? config.autoReconnect : true,
                ...config
            };
            
            this.ws = null;
            this.reconnectAttempts = 0;
            this.manualClose = false;
            this.reconnectTimer = null;
            this.connectionTimeout = null;
            this.isConnecting = false;
            
            // Callbacks
            this.onOpenCallback = null;
            this.onCloseCallback = null;
            this.onErrorCallback = null;
            this.onMessageCallback = null;
            this.onReconnectCallback = null;
        }
        
        onOpen(callback) {
            this.onOpenCallback = callback;
            return this;
        }
        
        onClose(callback) {
            this.onCloseCallback = callback;
            return this;
        }
        
        onError(callback) {
            this.onErrorCallback = callback;
            return this;
        }
        
        onMessage(callback) {
            this.onMessageCallback = callback;
            return this;
        }
        
        onReconnect(callback) {
            this.onReconnectCallback = callback;
            return this;
        }
        
        connect() {
            if (this.isConnecting) {
                console.log('[WebSocketClient] Connection attempt already in progress');
                return;
            }
            
            this._clearTimers();
            
            if (this.reconnectAttempts >= this.config.maxReconnectAttempts) {
                console.error('[WebSocketClient] Maximum reconnection attempts reached');
                this._triggerClose(false);
                return;
            }
            
            this._closeExistingConnection();
            this.isConnecting = true;
            
            try {
                console.log(`[WebSocketClient] Connecting to ${this.config.url} (attempt ${this.reconnectAttempts + 1}/${this.config.maxReconnectAttempts})`);
                
                this.ws = new WebSocket(this.config.url);
                this.ws.binaryType = 'arraybuffer';
                
                this.connectionTimeout = setTimeout(() => {
                    console.error('[WebSocketClient] Connection timeout');
                    if (this.ws && this.ws.readyState === WebSocket.CONNECTING) {
                        this.ws.close(); // onclose will trigger _handleReconnect
                    }
                }, this.config.connectionTimeout);
                
                this.ws.onopen = () => this._handleOpen();
                this.ws.onmessage = (event) => this._handleMessage(event);
                this.ws.onerror = (error) => this._handleError(error);
                this.ws.onclose = (event) => this._handleClose(event);
                
            } catch (error) {
                console.error('[WebSocketClient] Failed to create WebSocket:', error);
                this.isConnecting = false;
                this._handleReconnect();
            }
        }
        
        send(data) {
            if (!this.isConnected()) {
                console.error('[WebSocketClient] Cannot send: not connected');
                throw new Error('WebSocket is not connected');
            }
            
            try {
                this.ws.send(data);
                return true;
            } catch (error) {
                console.error('[WebSocketClient] Send failed:', error);
                return false;
            }
        }
        
        close() {
            console.log('[WebSocketClient] Closing connection');
            this.manualClose = true;
            this._clearTimers();
            
            if (this.ws) {
                try {
                    this.ws.close(1000, 'Client closing connection');
                } catch (error) {
                    console.error('[WebSocketClient] Error closing connection:', error);
                }
            }
        }
        
        reconnect() {
            console.log('[WebSocketClient] Manual reconnection requested');
            this.manualClose = false;
            this.reconnectAttempts = 0;
            this.connect();
        }
        
        isConnected() {
            return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
        }
        
        getState() {
            if (!this.ws) return 'DISCONNECTED';
            
            switch (this.ws.readyState) {
                case WebSocket.CONNECTING: return 'CONNECTING';
                case WebSocket.OPEN: return 'CONNECTED';
                case WebSocket.CLOSING: return 'CLOSING';
                case WebSocket.CLOSED: return 'DISCONNECTED';
                default: return 'UNKNOWN';
            }
        }
        
        _clearTimers() {
            if (this.reconnectTimer) {
                clearTimeout(this.reconnectTimer);
                this.reconnectTimer = null;
            }
            
            if (this.connectionTimeout) {
                clearTimeout(this.connectionTimeout);
                this.connectionTimeout = null;
            }
        }
        
        _closeExistingConnection() {
            if (this.ws) {
                try {
                    this.ws.onopen = null;
                    this.ws.onmessage = null;
                    this.ws.onerror = null;
                    this.ws.onclose = null;
                    
                    if (this.ws.readyState === WebSocket.OPEN || 
                        this.ws.readyState === WebSocket.CONNECTING) {
                        this.ws.close();
                    }
                } catch (error) {
                    console.warn('[WebSocketClient] Error closing existing connection:', error);
                }
                this.ws = null;
            }
        }
        
        _handleOpen() {
            console.log('[WebSocketClient] Connected successfully');
            this._clearTimers();
            this.isConnecting = false;
            this.reconnectAttempts = 0;
            
            if (this.onOpenCallback) {
                this.onOpenCallback();
            }
        }
        
        _handleMessage(event) {
            if (this.onMessageCallback) {
                this.onMessageCallback(event.data);
            }
        }
        
        _handleError(error) {
            console.error('[WebSocketClient] WebSocket error:', error);
            this.isConnecting = false;
            
            if (this.onErrorCallback) {
                this.onErrorCallback(error);
            }
        }
        
        _handleClose(event) {
            console.log(`[WebSocketClient] Connection closed (code: ${event.code})`);
            this._clearTimers();
            this.isConnecting = false;
            this.ws = null;
            
            const wasCleanClose = event.wasClean;
            
            if (!this.manualClose && this.config.autoReconnect) {
                this._handleReconnect();
            } else {
                this._triggerClose(wasCleanClose);
            }
        }
        
        _handleReconnect() {
            this.reconnectAttempts++;
            
            if (this.reconnectAttempts >= this.config.maxReconnectAttempts) {
                console.error('[WebSocketClient] Maximum reconnection attempts reached');
                this._triggerClose(false);
                return;
            }
            
            const baseDelay = this.config.reconnectDelay;
            const exponentialDelay = baseDelay * Math.pow(1.5, this.reconnectAttempts - 1);
            const jitter = Math.random() * 1000;
            const delay = Math.min(exponentialDelay + jitter, 30000);
            
            console.log(`[WebSocketClient] Reconnecting in ${Math.round(delay)}ms`);
            
            if (this.onReconnectCallback) {
                this.onReconnectCallback(this.reconnectAttempts, this.config.maxReconnectAttempts, delay);
            }
            
            this.reconnectTimer = setTimeout(() => {
                this.connect();
            }, delay);
        }
        
        _triggerClose(wasClean) {
            if (this.onCloseCallback) {
                this.onCloseCallback(wasClean, this.reconnectAttempts, this.config.maxReconnectAttempts);
            }
        }
    }
    
    // Export to window for browser use
    window.WebSocketClient = WebSocketClient;
    
})(window);