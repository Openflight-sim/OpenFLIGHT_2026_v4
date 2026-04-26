/********************************************
 * FILE: AeroModelClient.js
 *
 * Domain-specific WebSocket client for the AeroModel analysis server.
 * Wraps WebSocketClient + MessagePackClient (MsgPack binary protocol).
 *
 * Follows the same layered pattern as the example_msgpack framework:
 *   WebSocketClient → MessagePackClient → AeroModelClient
 *
 * Usage:
 *   <script src="https://cdn.jsdelivr.net/npm/@msgpack/msgpack@3.0.0-beta2/dist.es5+umd/msgpack.min.js"></script>
 *   <script src="src/js/WebSocketClient.js"></script>
 *   <script src="src/js/MessagePackProtocol.js"></script>
 *   <script src="src/js/AeroModelClient.js"></script>
 *   <script>
 *     var aero = new AeroModelClient({ url: 'ws://localhost:8765' });
 *     aero
 *       .onProgress(function(msg) { console.log(msg); })
 *       .onResults(function(model) { console.log(model); })
 *       .onError(function(err) { console.error(err); })
 *       .connect();
 *   </script>
 ********************************************/

(function(window) {
  'use strict';

  /**
   * AeroModelClient — high-level client for the AeroModel WebSocket server.
   *
   * @param {Object} config
   * @param {string} config.url  WebSocket URL (default: 'ws://localhost:8765')
   * @param {number} config.reconnectDelay        (default: 3000)
   * @param {number} config.maxReconnectAttempts   (default: 5)
   * @param {boolean} config.autoReconnect         (default: true)
   */
  function AeroModelClient(config) {
    config = config || {};
    var wsUrl = config.url || 'ws://localhost:8765';

    // 1) Create generic WebSocket client
    this._wsClient = new WebSocketClient({
      url: wsUrl,
      reconnectDelay: config.reconnectDelay || 3000,
      maxReconnectAttempts: config.maxReconnectAttempts || 5,
      connectionTimeout: config.connectionTimeout || 10000,
      autoReconnect: config.autoReconnect !== undefined ? config.autoReconnect : true
    });

    // 2) Wrap with MessagePack protocol
    this._msgpack = new MessagePackClient(this._wsClient);

    // Callbacks
    this._onProgressCb          = null;
    this._onResultsCb           = null;
    this._onErrorCb             = null;
    this._onStatusCb            = null;
    this._onDirectoryListingCb  = null;
    this._onFileSavedCb         = null;

    // Wire up the onMessage handler to route by message type
    var self = this;
    this._msgpack.onMessage(function(data) {
      self._handleMessage(data);
    });
  }

  // ---- Connection methods ----

  AeroModelClient.prototype.connect = function(url) {
    if (url) {
      // Allow changing URL before connecting
      this._wsClient.config.url = url;
    }
    this._msgpack.connect();
    return this;
  };

  AeroModelClient.prototype.close = function() {
    this._msgpack.close();
    return this;
  };

  AeroModelClient.prototype.reconnect = function() {
    this._msgpack.reconnect();
    return this;
  };

  AeroModelClient.prototype.isConnected = function() {
    return this._msgpack.isConnected();
  };

  AeroModelClient.prototype.getState = function() {
    return this._msgpack.getState();
  };

  // ---- Callback registration (chainable) ----

  AeroModelClient.prototype.onOpen = function(callback) {
    this._msgpack.onOpen(callback);
    return this;
  };

  AeroModelClient.prototype.onClose = function(callback) {
    this._msgpack.onClose(callback);
    return this;
  };

  AeroModelClient.prototype.onReconnect = function(callback) {
    this._msgpack.onReconnect(callback);
    return this;
  };

  AeroModelClient.prototype.onConnectionError = function(callback) {
    this._msgpack.onError(callback);
    return this;
  };

  AeroModelClient.prototype.onProgress = function(callback) {
    this._onProgressCb = callback;
    return this;
  };

  AeroModelClient.prototype.onResults = function(callback) {
    this._onResultsCb = callback;
    return this;
  };

  AeroModelClient.prototype.onError = function(callback) {
    this._onErrorCb = callback;
    return this;
  };

  AeroModelClient.prototype.onStatus = function(callback) {
    this._onStatusCb = callback;
    return this;
  };

  AeroModelClient.prototype.onDirectoryListing = function(callback) {
    this._onDirectoryListingCb = callback;
    return this;
  };

  AeroModelClient.prototype.onFileSaved = function(callback) {
    this._onFileSavedCb = callback;
    return this;
  };

  // ---- Domain-specific actions ----

  /**
   * Send an analysis request to the server.
   * @param {Object} aircraftData — the extended aircraft JSON with analysis params
   * @returns {boolean} true if sent
   */
  AeroModelClient.prototype.runAnalysis = function(aircraftData) {
    if (!this.isConnected()) {
      console.error('[AeroModelClient] Cannot send: not connected');
      if (this._onErrorCb) {
        this._onErrorCb({ message: 'WebSocket not connected. Start the Julia server first.' });
      }
      return false;
    }

    this._msgpack.send({
      type: 'run_analysis',
      aircraft: aircraftData
    });
    return true;
  };

  /**
   * Send a ping to the server.
   */
  AeroModelClient.prototype.ping = function() {
    if (!this.isConnected()) return false;
    this._msgpack.send({ type: 'ping' });
    return true;
  };

  /**
   * Request a directory listing from the server.
   * @param {string} path  Absolute path to list; empty string = workspace root.
   */
  AeroModelClient.prototype.listDirectory = function(path) {
    if (!this.isConnected()) return false;
    this._msgpack.send({ type: 'list_directory', path: path || '' });
    return true;
  };

  /**
   * Ask the server to write a file.
   * @param {string} dir       Absolute directory path
   * @param {string} filename  File name (no path separators)
   * @param {string} content   Text content to write
   */
  AeroModelClient.prototype.saveFile = function(dir, filename, content) {
    if (!this.isConnected()) return false;
    this._msgpack.send({ type: 'save_file', path: dir, filename: filename, content: content });
    return true;
  };

  // ---- Internal message routing ----

  AeroModelClient.prototype._handleMessage = function(data) {
    if (!data || typeof data !== 'object') {
      console.warn('[AeroModelClient] Received non-object message:', data);
      return;
    }

    var msgType = data.type || data['type'];

    switch (msgType) {
      case 'progress':
        if (this._onProgressCb) this._onProgressCb(data);
        break;

      case 'results':
        if (this._onResultsCb) this._onResultsCb(data.model || data['model']);
        break;

      case 'error':
        console.error('[AeroModelClient] Server error:', data.message || data['message']);
        if (this._onErrorCb) this._onErrorCb(data);
        break;

      case 'status':
        console.log('[AeroModelClient] Status:', data.message || data['message']);
        if (this._onStatusCb) this._onStatusCb(data);
        break;

      case 'directory_listing':
        if (this._onDirectoryListingCb) this._onDirectoryListingCb(data);
        break;

      case 'file_saved':
        if (this._onFileSavedCb) this._onFileSavedCb(data);
        break;

      default:
        console.log('[AeroModelClient] Unknown message type:', msgType, data);
    }
  };

  // ---- Status indicator helper ----

  /**
   * Update the WebSocket status indicator dot in the UI.
   * @param {string} status — 'connected', 'connecting', or 'disconnected'
   */
  AeroModelClient.prototype.updateStatusIndicator = function(status) {
    var indicator = document.getElementById('wsStatus');
    if (!indicator) return;

    indicator.className = 'ws-status';
    switch (status) {
      case 'connected':
        indicator.classList.add('ws-connected');
        indicator.title = 'Connected to ' + this._wsClient.config.url;
        break;
      case 'connecting':
        indicator.classList.add('ws-connecting');
        indicator.title = 'Connecting...';
        break;
      case 'disconnected':
        indicator.classList.add('ws-disconnected');
        indicator.title = 'Disconnected';
        break;
    }
  };

  // Export to window
  window.AeroModelClient = AeroModelClient;

})(window);
