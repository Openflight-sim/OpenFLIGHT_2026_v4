/********************************************
 * FILE: server-save.js
 *
 * Server-side file saving with an in-browser folder picker.
 * Uses the Julia server's list_directory / save_file WebSocket
 * messages so the user can save to any folder in the workspace.
 *
 * Public API (called by save buttons):
 *   saveViaServer(content, defaultFilename, extraFiles)
 ********************************************/

(function() {
  'use strict';

  // ---- Internal state ------------------------------------------------
  var _pendingContent  = '';
  var _pendingExtraFiles = [];   // [{content, filename}] saved alongside the primary
  var _pendingFilename = '';
  var _currentPath     = '';   // absolute path currently shown
  var _connectPollTimer = null;
  var _hasDirectorySelection = false;

  function _clearConnectPoll() {
    if (_connectPollTimer) {
      clearInterval(_connectPollTimer);
      _connectPollTimer = null;
    }
  }

  function _setSaveButtonEnabled(enabled) {
    var saveBtn = document.getElementById('fpSaveBtn');
    if (saveBtn) saveBtn.disabled = !enabled;
  }

  function _preparePendingSave(content, defaultFilename, extraFiles) {
    _pendingContent  = content;
    _pendingFilename = defaultFilename || 'output.txt';
    _pendingExtraFiles = Array.isArray(extraFiles)
      ? extraFiles
          .filter(function(file) {
            return file && typeof file.filename === 'string' && typeof file.content === 'string';
          })
          .map(function(file) {
            return { filename: file.filename, content: file.content };
          })
      : [];
  }

  function _showSaveModal() {
    var modal = document.getElementById('folderPickerModal');
    if (!modal) return false;

    _currentPath = '';
    _hasDirectorySelection = false;
    document.getElementById('fpFilename').value = _pendingFilename;
    document.getElementById('fpCurrentPath').value = '';
    document.getElementById('fpEntryList').innerHTML = '';
    _clearStatus();
    _setSaveButtonEnabled(false);
    modal.style.display = 'block';
    return true;
  }

  function _loadWorkspaceRoot() {
    if (!window.aeroClient || !window.aeroClient.isConnected()) {
      _setStatus('Save service is not connected.', true);
      _hasDirectorySelection = false;
      _setSaveButtonEnabled(false);
      return false;
    }
    _hasDirectorySelection = false;
    _setStatus('Loading folders...', false);
    _setSaveButtonEnabled(false);
    return window.aeroClient.listDirectory('');
  }

  function _connectForSaveOrFallback() {
    if (!window.aeroClient || typeof window.aeroClient.connect !== 'function') {
      _browserDownload(_pendingContent, _pendingFilename);
      return;
    }

    _setStatus('Connecting to save service...', false);
    _setSaveButtonEnabled(false);

    try {
      if (!window.aeroClient.isConnected()) {
        window.aeroClient.connect();
      }
    } catch (err) {
      console.error('[server-save] Failed to start save-service connection:', err);
      _browserDownload(_pendingContent, _pendingFilename);
      return;
    }

    _clearConnectPoll();
    var waitCount = 0;
    _connectPollTimer = setInterval(function() {
      waitCount++;
      if (window.aeroClient && window.aeroClient.isConnected()) {
        _clearConnectPoll();
        if (!_loadWorkspaceRoot()) {
          _browserDownload(_pendingContent, _pendingFilename);
        }
        return;
      }

      if (waitCount > 50) {
        _clearConnectPoll();
        _setStatus('Could not connect to save service. Falling back to browser download.', true);
        setTimeout(function() {
          var modal = document.getElementById('folderPickerModal');
          if (modal) modal.style.display = 'none';
          _browserDownload(_pendingContent, _pendingFilename);
        }, 250);
      }
    }, 100);
  }

  // ---- Open the folder picker ----------------------------------------

  /**
   * Show the folder picker modal and prepare a server-side save.
   * @param {string} content         Text content to write
   * @param {string} defaultFilename Suggested filename
   * @param {Array<{filename: string, content: string}>} extraFiles Additional files saved/downloaded alongside the primary file
   */
  window.saveViaServer = function(content, defaultFilename, extraFiles) {
    _preparePendingSave(content, defaultFilename, extraFiles);

    if (!window.aeroClient) {
      _browserDownload(_pendingContent, _pendingFilename);
      return;
    }

    // Allow callers to queue extra files AFTER this call returns but
    // BEFORE the user clicks Save (synchronous — runs before the modal
    // event loop).  Use: window.addPendingExtraFile(filename, content).

    if (!_showSaveModal()) {
      _browserDownload(_pendingContent, _pendingFilename);
      return;
    }

    if (window.aeroClient.isConnected()) {
      if (!_loadWorkspaceRoot()) {
        _browserDownload(_pendingContent, _pendingFilename);
      }
      return;
    }

    _connectForSaveOrFallback();
  };

  window.addPendingExtraFile = function(filename, content) {
    _pendingExtraFiles.push({ filename: filename, content: content });
  };

  function _aircraftIdentityToken(text) {
    return String(text || '')
      .replace(/\.tabular\.aero_prop\.yaml$/i, '')
      .replace(/\.linearized\.aero_prop\.yaml$/i, '')
      .replace(/\.ac_data\.yaml$/i, '')
      .replace(/\.aero_prop\.json$/i, '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '');
  }

  function _lastPathSegment(path) {
    var cleaned = String(path || '').replace(/\\/g, '/').replace(/\/+$/g, '');
    var parts = cleaned.split('/').filter(Boolean);
    return parts.length ? parts[parts.length - 1] : '';
  }

  function _looksLikeAircraftExport(filename) {
    return /\.(tabular|linearized)\.aero_prop\.yaml$/i.test(filename) ||
      /\.ac_data\.yaml$/i.test(filename) ||
      /\.aero_prop\.json$/i.test(filename);
  }

  function _confirmAircraftFolderMatch(filename, folderPath) {
    if (!_looksLikeAircraftExport(filename)) return true;
    var fileToken = _aircraftIdentityToken(filename);
    var folderToken = _aircraftIdentityToken(_lastPathSegment(folderPath));
    if (!fileToken || !folderToken || fileToken === folderToken) return true;
    if (fileToken.indexOf(folderToken) >= 0 || folderToken.indexOf(fileToken) >= 0) return true;
    return confirm(
      'You are saving aircraft files named "' + filename + '" into folder "' +
      _lastPathSegment(folderPath) + '".\n\n' +
      'OpenFLIGHT loads aero files from the selected hangar folder, so a name/folder mismatch can make the simulator fly the wrong aircraft model.\n\n' +
      'Continue anyway?'
    );
  }

  // ---- Directory listing response ------------------------------------

  function _onDirectoryListing(msg) {
    if (msg.error) {
      _setStatus('Error: ' + msg.error, true);
      _hasDirectorySelection = false;
      _setSaveButtonEnabled(false);
      return;
    }
    _clearConnectPoll();
    _currentPath = msg.path || '';
    _hasDirectorySelection = true;
    _renderListing(msg);
    _clearStatus();
    _setSaveButtonEnabled(true);
  }

  // ---- Render the listing in the modal -------------------------------

  function _renderListing(msg) {
    // Update path display
    document.getElementById('fpCurrentPath').value = _currentPath || '[workspace root]';

    // Up button: enabled unless at filesystem root
    var upBtn = document.getElementById('fpUpBtn');
    var isRoot = !msg.parent || msg.parent === _currentPath;
    upBtn.disabled = isRoot;

    // Populate entry list
    var list = document.getElementById('fpEntryList');
    list.innerHTML = '';

    var entries = msg.entries || [];
    if (entries.length === 0) {
      var empty = document.createElement('div');
      empty.className = 'fp-empty';
      empty.textContent = '(empty folder)';
      list.appendChild(empty);
      return;
    }

    entries.forEach(function(entry) {
      var item = document.createElement('div');
      item.className = entry.is_dir ? 'fp-entry fp-dir' : 'fp-entry fp-file';

      var icon = document.createElement('span');
      icon.className = 'fp-icon';
      icon.textContent = entry.is_dir ? '\uD83D\uDCC1' : '\uD83D\uDCC4';  // 📁 📄

      var name = document.createElement('span');
      name.className = 'fp-name';
      name.textContent = entry.name;

      item.appendChild(icon);
      item.appendChild(name);

      if (entry.is_dir) {
        item.title = 'Open: ' + entry.path;
        item.addEventListener('click', function() {
          _clearStatus();
          window.aeroClient.listDirectory(entry.path);
        });
      }

      list.appendChild(item);
    });
  }

  // ---- File saved response -------------------------------------------

  function _onFileSaved(msg) {
    if (msg.success) {
      _setStatus('\u2705 Saved: ' + (msg.path || ''), false);
      _setSaveButtonEnabled(true);
      setTimeout(function() {
        var modal = document.getElementById('folderPickerModal');
        if (modal) modal.style.display = 'none';
      }, 1800);
    } else {
      _setStatus('\u274C Save failed: ' + (msg.error || 'unknown error'), true);
      _setSaveButtonEnabled(true);
    }
  }

  // ---- Status helpers ------------------------------------------------

  function _setStatus(text, isError) {
    var el = document.getElementById('fpStatus');
    if (!el) return;
    el.textContent = text;
    el.style.color = isError ? '#e74c3c' : '#27ae60';
  }

  function _clearStatus() {
    var el = document.getElementById('fpStatus');
    if (el) { el.textContent = ''; }
  }

  // ---- Browser download fallback -------------------------------------

  function _browserDownload(content, filename) {
    var files = [{ content: content, filename: filename }].concat(_pendingExtraFiles);

    files.forEach(function(file, index) {
      setTimeout(function() {
        var blob = new Blob([file.content], { type: 'text/plain' });
        var url  = URL.createObjectURL(blob);
        var a    = document.createElement('a');
        a.href = url;
        a.download = file.filename || 'output.txt';
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
      }, index * 75);
    });

    _pendingExtraFiles = [];
  }

  // ---- Wire up modal buttons once DOM is ready ----------------------

  document.addEventListener('DOMContentLoaded', function() {

    // Register callbacks on the shared aeroClient
    // (aeroClient is created in analysis-setup.js which loads after this file,
    //  so we defer wiring until the first save request via a one-time check)
    var _callbacksWired = false;
    function _ensureCallbacks() {
      if (_callbacksWired) return;
      if (!window.aeroClient) return;
      window.aeroClient
        .onDirectoryListing(_onDirectoryListing)
        .onFileSaved(_onFileSaved);
      _callbacksWired = true;
    }

    // Override saveViaServer to ensure callbacks are wired first
    var _origSaveViaServer = window.saveViaServer;
    window.saveViaServer = function(content, defaultFilename, extraFiles) {
      _ensureCallbacks();
      _origSaveViaServer(content, defaultFilename, extraFiles);
    };

    // Up button
    var upBtn = document.getElementById('fpUpBtn');
    if (upBtn) {
      upBtn.addEventListener('click', function() {
        if (!_currentPath) return;
        _clearStatus();
        // Navigate to parent: get parent from last listing or compute it
        var parent = _currentPath.replace(/\/[^/]+\/?$/, '') || _currentPath;
        if (parent === _currentPath) return;
        window.aeroClient.listDirectory(parent);
      });
    }

    // Save button
    var saveBtn = document.getElementById('fpSaveBtn');
    if (saveBtn) {
      saveBtn.addEventListener('click', function() {
        var filename = (document.getElementById('fpFilename').value || '').trim();
        if (!filename) { _setStatus('Please enter a filename.', true); return; }
        if (!_hasDirectorySelection) { _setStatus('No folder selected.', true); return; }
        if (!_confirmAircraftFolderMatch(filename, _currentPath)) return;
        _setStatus('Saving...', false);
        window.aeroClient.saveFile(_currentPath, filename, _pendingContent);
        // Save any extra files queued alongside the primary (e.g. the
        // linearized companion to a tabular export). Uses the same folder
        // selected in the modal — no second dialog needed.
        for (var i = 0; i < _pendingExtraFiles.length; i++) {
          var extra = _pendingExtraFiles[i];
          window.aeroClient.saveFile(_currentPath, extra.filename, extra.content);
        }
        _pendingExtraFiles = [];
      });
    }

    // Cancel button
    var cancelBtn = document.getElementById('fpCancelBtn');
    if (cancelBtn) {
      cancelBtn.addEventListener('click', function() {
        _clearConnectPoll();
        document.getElementById('folderPickerModal').style.display = 'none';
      });
    }

    // Close (×) button
    var closeBtn = document.getElementById('fpCloseBtn');
    if (closeBtn) {
      closeBtn.addEventListener('click', function() {
        _clearConnectPoll();
        document.getElementById('folderPickerModal').style.display = 'none';
      });
    }

    // Click outside modal → close
    var modal = document.getElementById('folderPickerModal');
    if (modal) {
      modal.addEventListener('click', function(e) {
        if (e.target === modal) {
          _clearConnectPoll();
          modal.style.display = 'none';
        }
      });
    }
  });

})();
