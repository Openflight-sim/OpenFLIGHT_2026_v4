/********************************************
 * FILE: websocket-client.js
 * WebSocket client for Julia AeroModel server
 ********************************************/

window.aeroClient = {
  ws: null,
  url: 'ws://localhost:8765',
  onProgressCallback: null,
  onResultsCallback: null,
  onErrorCallback: null,
  reconnectTimer: null,

  connect: function(url) {
    if (url) this.url = url;
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    this.updateStatus('connecting');

    try {
      this.ws = new WebSocket(this.url);
    } catch (e) {
      console.error('WebSocket connection error:', e);
      this.updateStatus('disconnected');
      return;
    }

    var self = this;

    this.ws.onopen = function() {
      console.log('WebSocket connected to', self.url);
      self.updateStatus('connected');
      if (self.reconnectTimer) {
        clearTimeout(self.reconnectTimer);
        self.reconnectTimer = null;
      }
    };

    this.ws.onmessage = function(event) {
      try {
        var msg = JSON.parse(event.data);
        self.handleMessage(msg);
      } catch (e) {
        console.error('Failed to parse WebSocket message:', e);
      }
    };

    this.ws.onclose = function(event) {
      console.log('WebSocket closed:', event.code, event.reason);
      self.updateStatus('disconnected');
    };

    this.ws.onerror = function(error) {
      console.error('WebSocket error:', error);
      self.updateStatus('disconnected');
    };
  },

  disconnect: function() {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.updateStatus('disconnected');
  },

  isConnected: function() {
    return this.ws && this.ws.readyState === WebSocket.OPEN;
  },

  runAnalysis: function(aircraftData) {
    if (!this.isConnected()) {
      console.error('WebSocket not connected');
      if (this.onErrorCallback) {
        this.onErrorCallback({ message: 'WebSocket not connected. Start the Julia server first.' });
      }
      return false;
    }

    var message = JSON.stringify({
      type: 'run_analysis',
      aircraft: aircraftData
    });

    this.ws.send(message);
    return true;
  },

  handleMessage: function(msg) {
    switch (msg.type) {
      case 'progress':
        if (this.onProgressCallback) {
          this.onProgressCallback(msg);
        }
        break;

      case 'results':
        if (this.onResultsCallback) {
          this.onResultsCallback(msg.model);
        }
        break;

      case 'error':
        console.error('Server error:', msg.message);
        if (this.onErrorCallback) {
          this.onErrorCallback(msg);
        }
        break;

      case 'status':
        console.log('Server status:', msg.message);
        break;

      default:
        console.log('Unknown message type:', msg.type);
    }
  },

  onProgress: function(callback) {
    this.onProgressCallback = callback;
  },

  onResults: function(callback) {
    this.onResultsCallback = callback;
  },

  onError: function(callback) {
    this.onErrorCallback = callback;
  },

  updateStatus: function(status) {
    var indicator = document.getElementById('wsStatus');
    if (!indicator) return;

    indicator.className = 'ws-status';
    switch (status) {
      case 'connected':
        indicator.classList.add('ws-connected');
        indicator.title = 'Connected to ' + this.url;
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
  }
};
