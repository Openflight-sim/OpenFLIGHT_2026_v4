/********************************************
 * FILE: results-panel.js
 * Results visualization with Chart.js and
 * YAML/JSON export
 ********************************************/

window.aeroModel = null;
window.aeroChart = null;
window.currentChartType = 'clAlpha';

// Mach color palette
var machColors = [
  'rgb(52, 152, 219)',   // blue
  'rgb(231, 76, 60)',    // red
  'rgb(46, 204, 113)',   // green
  'rgb(155, 89, 182)',   // purple
  'rgb(243, 156, 18)',   // orange
  'rgb(26, 188, 156)',   // teal
  'rgb(241, 196, 15)',   // yellow
  'rgb(142, 68, 173)'    // dark purple
];

// Distinct markers per dataset so curves are distinguishable
var POINT_STYLES = ['circle', 'triangle', 'rect', 'rectRot', 'star', 'cross', 'crossRot', 'dash'];

// ---- Panel toggle ----
function showResultsPanel() {
  document.body.classList.add('show-results');
}

function hideResultsPanel() {
  document.body.classList.remove('show-results');
}

function showProgress() {
  document.getElementById('analysisProgress').style.display = 'block';
}

document.getElementById('toggleResultsBtn').addEventListener('click', function() {
  if (document.body.classList.contains('show-results')) {
    hideResultsPanel();
  } else {
    showResultsPanel();
  }
});

document.getElementById('closeResultsBtn').addEventListener('click', function() {
  hideResultsPanel();
});

// ---- Chart tab switching ----
document.querySelectorAll('.chart-tab').forEach(function(tab) {
  tab.addEventListener('click', function() {
    document.querySelectorAll('.chart-tab').forEach(function(t) { t.classList.remove('active'); });
    tab.classList.add('active');
    window.currentChartType = tab.dataset.chart;

    if (tab.dataset.chart === 'derivatives') {
      document.querySelector('.chart-container').style.display = 'none';
      document.getElementById('derivativesTable').style.display = 'block';
      if (window.aeroModel) renderDerivativesTable(window.aeroModel);
    } else {
      document.querySelector('.chart-container').style.display = 'block';
      document.getElementById('derivativesTable').style.display = 'none';
      if (window.aeroModel) drawChart(window.aeroModel, tab.dataset.chart);
    }
  });
});

// ---- Show results after analysis ----
function showResultsCharts(model) {
  document.getElementById('resultsCharts').style.display = 'block';
  window.aeroModel = model;
  drawChart(model, window.currentChartType);

  // Show a prominent alert for critical validation errors (e.g. pitch
  // instability) so the user can't miss them.
  checkAndAlertCriticalErrors(model);
}

function checkAndAlertCriticalErrors(model) {
  if (!model || !model.quality || !model.quality.validation) return;
  var v = model.quality.validation;
  if (v.passed || !v.issues || v.issues.length === 0) return;

  var errorMessages = [];
  var warningMessages = [];
  var infoMessages = [];

  for (var i = 0; i < v.issues.length; i++) {
    var issue = v.issues[i];
    var msg = (issue.message || 'Unknown issue');
    if (issue.detail) msg += '\n' + issue.detail;

    if (issue.severity === 'error') {
      errorMessages.push('❌  ' + msg);
    } else if (issue.severity === 'warning') {
      warningMessages.push('⚠️  ' + msg);
    } else if (issue.severity === 'info') {
      infoMessages.push('ℹ️  ' + msg);
    }
  }

  // Only show the modal if there are errors or warnings (skip info-only)
  if (errorMessages.length === 0 && warningMessages.length === 0) return;

  var sections = [];
  if (errorMessages.length > 0) {
    sections.push(
      '❌  ERRORS (' + errorMessages.length + ')\n' +
      '─'.repeat(45) + '\n\n' +
      errorMessages.join('\n\n')
    );
  }
  if (warningMessages.length > 0) {
    sections.push(
      '⚠️  WARNINGS (' + warningMessages.length + ')\n' +
      '─'.repeat(45) + '\n\n' +
      warningMessages.join('\n\n')
    );
  }
  if (infoMessages.length > 0) {
    sections.push(
      'ℹ️  INFO\n' +
      '─'.repeat(45) + '\n\n' +
      infoMessages.join('\n\n')
    );
  }

  var header = '═'.repeat(50) + '\n';
  header += '   VALIDATION REPORT\n';
  header += '═'.repeat(50) + '\n\n';
  var footer = '\n\n' + '═'.repeat(50);
  if (errorMessages.length > 0) {
    footer += '\nFix errors before exporting. The aircraft may be unflyable.';
  }

  alert(header + sections.join('\n\n') + footer);
}

// ---- Extract data from model for plotting ----
function getStaticData(model, coeffName, configIdx, betaIdx) {
  configIdx = configIdx || 0;
  betaIdx = betaIdx || 0; // default to beta=0

  var aero = model.aerodynamics;
  if (!aero || !aero.static_coefficients) return null;

  var sc = aero.static_coefficients;
  var coeff = sc[coeffName];
  if (!coeff || !coeff.values) return null;

  var configs = sc.axes.config;
  var machs = sc.axes.mach;
  var alphas = sc.axes.alpha_deg;
  var betas = sc.axes.beta_deg || [0];

  var configKey = configs[configIdx] || configs[0];
  var configData = coeff.values[configKey];
  if (!configData) return null;

  // configData[mach_idx][alpha_idx][beta_idx]
  var datasets = [];
  machs.forEach(function(mach, mi) {
    var points = [];
    alphas.forEach(function(alpha, ai) {
      var val;
      if (Array.isArray(configData[mi]) && Array.isArray(configData[mi][ai])) {
        val = configData[mi][ai][betaIdx] || configData[mi][ai][0];
      } else if (Array.isArray(configData[mi])) {
        val = configData[mi][ai]; // 2D: [mach][alpha]
      } else {
        val = null;
      }
      if (val !== null && val !== undefined) {
        points.push({ x: alpha, y: val });
      }
    });
    datasets.push({
      label: 'M=' + mach.toFixed(2),
      data: points,
      borderColor: machColors[mi % machColors.length],
      backgroundColor: 'transparent',
      showLine: true,
      borderWidth: 2,
      pointRadius: 4,
      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],
      tension: 0.3
    });
  });

  return { alphas: alphas, machs: machs, datasets: datasets };
}

// ─── Schema v3.0: component overlay datasets ─────────────────────
// Return Chart.js datasets for the wing_body coefficient alongside each
// tail surface's contribution, swept against α (at β index = betaIdx).
// Colors are dimmed / dashed so they sit visually behind the total curve.
function getWingBodyDatasetsVsAlpha(model, coeffName, configIdx, betaIdx) {
  configIdx = configIdx || 0; betaIdx = betaIdx || 0;
  var aero = model.aerodynamics; if (!aero || !aero.wing_body) return [];
  var wb = aero.wing_body;
  var coeff = wb[coeffName]; if (!coeff || !coeff.values) return [];
  var configs = wb.axes.config, machs = wb.axes.mach, alphas = wb.axes.alpha_deg;
  var configKey = configs[configIdx] || configs[0];
  var configData = coeff.values[configKey]; if (!configData) return [];
  var datasets = [];
  machs.forEach(function(mach, mi) {
    var points = [];
    alphas.forEach(function(alpha, ai) {
      var v = (configData[mi] && configData[mi][ai]) ? configData[mi][ai][betaIdx] : null;
      if (v !== null && v !== undefined) points.push({ x: alpha, y: v });
    });
    datasets.push({
      label: 'wing+body M=' + mach.toFixed(2),
      data: points, borderColor: '#1a3a8a', backgroundColor: 'transparent',
      showLine: true, borderWidth: 1.5, borderDash: [5, 3], pointRadius: 2, tension: 0.3
    });
  });
  return datasets;
}

function getTailDatasetsVsAlpha(model, coeffName, configIdx, betaIdx) {
  configIdx = configIdx || 0; betaIdx = betaIdx || 0;
  var aero = model.aerodynamics; if (!aero || !aero.tail) return [];
  var tail = aero.tail;
  var configs = tail.axes ? tail.axes.config : ['clean'];
  var machs   = tail.axes ? tail.axes.mach   : [0.2];
  var alphas  = tail.axes ? tail.axes.alpha_h_deg : [];
  var surfaces = tail.surfaces || [];
  var configKey = configs[configIdx] || configs[0];
  var palette = ['#8a1a1a', '#0a6b2b', '#8a6b1a', '#6b1a8a'];
  var datasets = [];
  var tailKey = coeffName;
  if (coeffName === 'Cm') tailKey = 'Cm_at_AC';
  if (coeffName === 'Cl') tailKey = 'Cl_at_AC';
  if (coeffName === 'Cn') tailKey = 'Cn_at_AC';
  surfaces.forEach(function(surf, si) {
    var coeff = surf[tailKey]; if (!coeff || !coeff.values) return;
    var configData = coeff.values[configKey]; if (!configData) return;
    machs.forEach(function(mach, mi) {
      var points = [];
      alphas.forEach(function(alpha, ai) {
        var v = (configData[mi] && configData[mi][ai]) ? configData[mi][ai][betaIdx] : null;
        if (v !== null && v !== undefined) points.push({ x: alpha, y: v });
      });
      datasets.push({
        label: 'tail:' + (surf.name || ('tail'+si)) + ' M=' + mach.toFixed(2),
        data: points, borderColor: palette[si % palette.length],
        backgroundColor: 'transparent',
        showLine: true, borderWidth: 1.5, borderDash: [2, 4], pointRadius: 2, tension: 0.3
      });
    });
  });
  return datasets;
}

// Same pattern for β-swept lateral plots (CY/Cl/Cn vs β).
function getWingBodyDatasetsVsBeta(model, coeffName, configIdx, alphaIdx) {
  configIdx = configIdx || 0;
  var aero = model.aerodynamics; if (!aero || !aero.wing_body) return [];
  var wb = aero.wing_body;
  var coeff = wb[coeffName]; if (!coeff || !coeff.values) return [];
  var configs = wb.axes.config, machs = wb.axes.mach;
  var alphas = wb.axes.alpha_deg, betas = wb.axes.beta_deg;
  var aIdx = alphaIdx;
  if (aIdx === undefined || aIdx === null) {
    var best = 999;
    alphas.forEach(function(a, i) { if (Math.abs(a) < best) { best = Math.abs(a); aIdx = i; } });
  }
  var configKey = configs[configIdx] || configs[0];
  var configData = coeff.values[configKey]; if (!configData) return [];
  var datasets = [];
  machs.forEach(function(mach, mi) {
    var points = [];
    betas.forEach(function(beta, bi) {
      var v = (configData[mi] && configData[mi][aIdx]) ? configData[mi][aIdx][bi] : null;
      if (v !== null && v !== undefined) points.push({ x: beta, y: v });
    });
    datasets.push({
      label: 'wing+body M=' + mach.toFixed(2),
      data: points, borderColor: '#1a3a8a', backgroundColor: 'transparent',
      showLine: true, borderWidth: 1.5, borderDash: [5, 3], pointRadius: 2, tension: 0.3
    });
  });
  return datasets;
}

function getTailDatasetsVsBeta(model, coeffName, configIdx, alphaIdx) {
  configIdx = configIdx || 0;
  var aero = model.aerodynamics; if (!aero || !aero.tail) return [];
  var tail = aero.tail;
  var configs = tail.axes ? tail.axes.config : ['clean'];
  var machs   = tail.axes ? tail.axes.mach   : [0.2];
  var alphas  = tail.axes ? tail.axes.alpha_h_deg : [];
  var betas   = tail.axes ? tail.axes.beta_v_deg  : [];
  var aIdx = alphaIdx;
  if (aIdx === undefined || aIdx === null) {
    var best = 999;
    alphas.forEach(function(a, i) { if (Math.abs(a) < best) { best = Math.abs(a); aIdx = i; } });
  }
  var surfaces = tail.surfaces || [];
  var configKey = configs[configIdx] || configs[0];
  var palette = ['#8a1a1a', '#0a6b2b', '#8a6b1a', '#6b1a8a'];
  var datasets = [];
  var tailKey = coeffName;
  if (coeffName === 'Cm') tailKey = 'Cm_at_AC';
  if (coeffName === 'Cl') tailKey = 'Cl_at_AC';
  if (coeffName === 'Cn') tailKey = 'Cn_at_AC';
  surfaces.forEach(function(surf, si) {
    var coeff = surf[tailKey]; if (!coeff || !coeff.values) return;
    var configData = coeff.values[configKey]; if (!configData) return;
    machs.forEach(function(mach, mi) {
      var points = [];
      betas.forEach(function(beta, bi) {
        var v = (configData[mi] && configData[mi][aIdx]) ? configData[mi][aIdx][bi] : null;
        if (v !== null && v !== undefined) points.push({ x: beta, y: v });
      });
      datasets.push({
        label: 'tail:' + (surf.name || ('tail'+si)) + ' M=' + mach.toFixed(2),
        data: points, borderColor: palette[si % palette.length],
        backgroundColor: 'transparent',
        showLine: true, borderWidth: 1.5, borderDash: [2, 4], pointRadius: 2, tension: 0.3
      });
    });
  });
  return datasets;
}

// Interference 1-D plots.
function buildInterferenceChart(model, key, xAxisName, xUnits, yLabel) {
  var aero = model.aerodynamics; if (!aero || !aero.interference) return null;
  var ifb = aero.interference;
  var coeff = ifb[key]; if (!coeff || !coeff.values) return null;
  var configs = (ifb.axes && ifb.axes.config) || ['clean'];
  var machs   = (ifb.axes && ifb.axes.mach)   || [0.2];
  var xs      = (ifb.axes && ifb.axes[xAxisName]) || [];
  var datasets = [];
  configs.forEach(function(cfg) {
    var configData = coeff.values[cfg]; if (!configData) return;
    machs.forEach(function(mach, mi) {
      var row = Array.isArray(configData[mi]) ? configData[mi] : configData;
      var points = [];
      xs.forEach(function(x, i) {
        var v = Array.isArray(row) ? row[i] : null;
        if (v !== null && v !== undefined) points.push({ x: x, y: v });
      });
      datasets.push({
        label: cfg + ' M=' + mach.toFixed(2),
        data: points, backgroundColor: 'transparent',
        borderColor: machColors[mi % machColors.length],
        showLine: true, borderWidth: 2, pointRadius: 3, tension: 0.3
      });
    });
  });
  return {
    type: 'scatter',
    data: { datasets: datasets },
    options: {
      responsive: true, maintainAspectRatio: false,
      plugins: { title: { display: true, text: key + ' vs ' + xAxisName + ' (interference)' } },
      scales: {
        x: { title: { display: true, text: xAxisName + ' (' + xUnits + ')' } },
        y: { title: { display: true, text: yLabel } }
      }
    }
  };
}

function getDynamicData(model, derivName, configIdx) {
  configIdx = configIdx || 0;
  var aero = model.aerodynamics;
  if (!aero || !aero.dynamic_derivatives) return null;

  var dd = aero.dynamic_derivatives;
  var deriv = dd[derivName];
  if (!deriv || !deriv.values) return null;

  var configs = dd.axes.config;
  var machs = dd.axes.mach;
  var alphas = dd.axes.alpha_deg;
  var configKey = configs[configIdx] || configs[0];
  var configData = deriv.values[configKey];
  if (!configData) return null;

  var datasets = [];
  machs.forEach(function(mach, mi) {
    var points = [];
    alphas.forEach(function(alpha, ai) {
      var val = configData[mi] ? configData[mi][ai] : null;
      if (val !== null && val !== undefined) {
        points.push({ x: alpha, y: val });
      }
    });
    datasets.push({
      label: 'M=' + mach.toFixed(2),
      data: points,
      borderColor: machColors[mi % machColors.length],
      backgroundColor: 'transparent',
      showLine: true,
      borderWidth: 2,
      pointRadius: 4,
      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],
      tension: 0.3
    });
  });

  return { alphas: alphas, datasets: datasets };
}

// ---- Draw charts ----
function drawChart(model, chartType) {
  var canvas = document.getElementById('aeroChart');
  if (!canvas) return;

  if (window.aeroChart) {
    window.aeroChart.destroy();
    window.aeroChart = null;
  }

  var config = null;

  switch (chartType) {
    case 'clAlpha':
      config = buildCLAlphaChart(model);
      break;
    case 'dragPolar':
      config = buildDragPolarChart(model);
      break;
    case 'cmAlpha':
      config = buildCmAlphaChart(model);
      break;
    case 'lateral':
      config = buildLateralChart(model);
      break;
    case 'controls':
      config = buildControlsChart(model);
      break;
    case 'downwash':
      config = buildInterferenceChart(model, 'downwash_deg', 'alpha_deg', 'deg', 'ε (deg)');
      break;
    case 'etaH':
      config = buildInterferenceChart(model, 'eta_h', 'alpha_deg', 'deg', 'η_h');
      break;
    case 'sidewash':
      config = buildInterferenceChart(model, 'sidewash_deg', 'beta_deg', 'deg', 'σ (deg)');
      break;
    case 'etaV':
      config = buildInterferenceChart(model, 'eta_v', 'beta_deg', 'deg', 'η_v');
      break;
  }

  if (config) {
    window.aeroChart = new Chart(canvas, config);
  }
}

function buildCLAlphaChart(model) {
  var data = getStaticData(model, 'CL');
  if (!data) return null;
  var overlay = getWingBodyDatasetsVsAlpha(model, 'CL').concat(getTailDatasetsVsAlpha(model, 'CL'));
  return {
    type: 'scatter',
    data: { datasets: data.datasets.concat(overlay) },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { title: { display: true, text: 'CL vs Alpha — total · wing+body · tails' } },
      scales: {
        x: { title: { display: true, text: 'Alpha (deg)' } },
        y: { title: { display: true, text: 'CL' } }
      }
    }
  };
}

function buildDragPolarChart(model) {
  var clData = getStaticData(model, 'CL');
  var cdData = getStaticData(model, 'CD');
  if (!clData || !cdData) return null;

  var datasets = [];
  clData.datasets.forEach(function(clDs, i) {
    var cdDs = cdData.datasets[i];
    if (!cdDs) return;
    var points = [];
    for (var j = 0; j < clDs.data.length && j < cdDs.data.length; j++) {
      points.push({ x: cdDs.data[j].y, y: clDs.data[j].y });
    }
    datasets.push({
      label: clDs.label,
      data: points,
      borderColor: machColors[i % machColors.length],
      backgroundColor: 'transparent',
      showLine: true,
      borderWidth: 2,
      pointRadius: 4,
      pointStyle: POINT_STYLES[i % POINT_STYLES.length],
      tension: 0.3
    });
  });

  return {
    type: 'scatter',
    data: { datasets: datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { title: { display: true, text: 'Drag Polar (CL vs CD) — Total Aircraft' } },
      scales: {
        x: { title: { display: true, text: 'CD' } },
        y: { title: { display: true, text: 'CL' } }
      }
    }
  };
}

function buildCmAlphaChart(model) {
  var data = getStaticData(model, 'Cm');
  if (!data) return null;
  var overlay = getWingBodyDatasetsVsAlpha(model, 'Cm').concat(getTailDatasetsVsAlpha(model, 'Cm'));
  return {
    type: 'scatter',
    data: { datasets: data.datasets.concat(overlay) },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { title: { display: true, text: 'Cm vs Alpha — total · wing+body · tails' } },
      scales: {
        x: { title: { display: true, text: 'Alpha (deg)' } },
        y: { title: { display: true, text: 'Cm' } }
      }
    }
  };
}

function buildLateralChart(model) {
  // CY vs beta at zero alpha
  var aero = model.aerodynamics;
  if (!aero || !aero.static_coefficients) return null;

  var sc = aero.static_coefficients;
  var configs = sc.axes.config || ['clean'];
  var machs = sc.axes.mach || [0.2];
  var alphas = sc.axes.alpha_deg || [0];
  var betas = sc.axes.beta_deg || [0];

  var cy = sc.CY;
  if (!cy || !cy.values) return null;

  var configKey = configs[0];
  var configData = cy.values[configKey];
  if (!configData) return null;

  // Find alpha closest to 0
  var bestAlphaIdx = 0;
  var bestDist = 999;
  alphas.forEach(function(a, i) {
    if (Math.abs(a) < bestDist) { bestDist = Math.abs(a); bestAlphaIdx = i; }
  });

  var datasets = [];
  machs.forEach(function(mach, mi) {
    var points = [];
    betas.forEach(function(beta, bi) {
      var val = configData[mi] && configData[mi][bestAlphaIdx] ? configData[mi][bestAlphaIdx][bi] : null;
      if (val !== null && val !== undefined) {
        points.push({ x: beta, y: val });
      }
    });
    datasets.push({
      label: 'CY M=' + mach.toFixed(2),
      data: points,
      borderColor: machColors[mi % machColors.length],
      backgroundColor: 'transparent',
      showLine: true,
      borderWidth: 2,
      pointRadius: 4,
      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],
      tension: 0.3
    });
  });

  // v3.0 overlay: wing+body & per-tail CY vs β at closest-to-zero α.
  var overlay = getWingBodyDatasetsVsBeta(model, 'CY').concat(getTailDatasetsVsBeta(model, 'CY'));
  return {
    type: 'scatter',
    data: { datasets: datasets.concat(overlay) },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { title: { display: true, text: 'CY vs Beta — total · wing+body · tails (α≈0°)' } },
      scales: {
        x: { title: { display: true, text: 'Beta (deg)' } },
        y: { title: { display: true, text: 'CY' } }
      }
    }
  };
}

function buildControlsChart(model) {
  var aero = model.aerodynamics;
  if (!aero || !aero.control_effectiveness) return null;

  var ce = aero.control_effectiveness;
  var alphas = ce.axes.alpha_deg || [];
  var machs = ce.axes.mach || [0.2];
  var configs = ce.axes.config || ['clean'];
  var configKey = configs[0];

  var datasets = [];
  var derivNames = ['Cl_da_per_deg', 'Cd_da_per_deg', 'Cn_da_per_deg'].filter(function(name) {
    return ce[name] && ce[name].values;
  });
  if (derivNames.length === 0) return null;
  var colorIdx = 0;

  derivNames.forEach(function(name) {
    var data = ce[name];
    if (!data || !data.values) return;
    var configData = data.values[configKey];
    if (!configData) return;

    // Use first Mach
    var machData = configData[0];
    if (!machData) return;

    var points = [];
    alphas.forEach(function(alpha, ai) {
      var val = machData[ai];
      if (val !== null && val !== undefined) {
        points.push({ x: alpha, y: val });
      }
    });

    datasets.push({
      label: name,
      data: points,
      borderColor: machColors[colorIdx % machColors.length],
      backgroundColor: 'transparent',
      showLine: true,
      borderWidth: 2,
      pointRadius: 4,
      pointStyle: POINT_STYLES[colorIdx % POINT_STYLES.length],
      tension: 0.3
    });
    colorIdx++;
  });

  return {
    type: 'scatter',
    data: { datasets: datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { title: { display: true, text: 'Control Effectiveness vs Alpha — Total Aircraft' } },
      scales: {
        x: { title: { display: true, text: 'Alpha (deg)' } },
        y: { title: { display: true, text: 'per degree' } }
      }
    }
  };
}

// ---- Derivatives table ----
function renderDerivativesTable(model) {
  var aero = model.aerodynamics;
  var table = document.getElementById('derivTable');
  if (!table) return;

  var thead = table.querySelector('thead tr');
  var tbody = table.querySelector('tbody');
  thead.innerHTML = '<th>Derivative</th>';
  tbody.innerHTML = '';

  if (!aero || !aero.dynamic_derivatives) {
    tbody.innerHTML = '<tr><td colspan="2">No derivative data available</td></tr>';
    return;
  }

  var dd = aero.dynamic_derivatives;
  var machs = dd.axes.mach || [0.2];
  var alphas = dd.axes.alpha_deg || [0];
  var configs = dd.axes.config || ['clean'];
  var configKey = configs[0];

  machs.forEach(function(m) {
    thead.innerHTML += '<th>M=' + m.toFixed(2) + '</th>';
  });

  var derivNames = Object.keys(dd).filter(function(k) { return k !== 'axis_order' && k !== 'axes'; });

  // Find alpha index closest to a reference (e.g., 5 deg)
  var refAlpha = 5;
  var bestIdx = 0;
  var bestDist = 999;
  alphas.forEach(function(a, i) {
    if (Math.abs(a - refAlpha) < bestDist) { bestDist = Math.abs(a - refAlpha); bestIdx = i; }
  });

  derivNames.forEach(function(name) {
    var data = dd[name];
    if (!data || !data.values) return;
    var configData = data.values[configKey];
    if (!configData) return;

    var row = '<tr><td>' + name + '</td>';
    machs.forEach(function(m, mi) {
      var val = configData[mi] ? configData[mi][bestIdx] : null;
      if (val !== null && val !== undefined) {
        var cls = val >= 0 ? 'deriv-positive' : 'deriv-negative';
        row += '<td class="' + cls + '">' + val.toFixed(4) + '</td>';
      } else {
        row += '<td>--</td>';
      }
    });
    row += '</tr>';
    tbody.innerHTML += row;
  });

  // Also add control effectiveness if available
  if (aero.control_effectiveness) {
    var ce = aero.control_effectiveness;
    var ceNames = ['Cl_da_per_deg', 'Cd_da_per_deg', 'Cn_da_per_deg'].filter(function(name) {
      return ce[name] && ce[name].values;
    });
    ceNames.forEach(function(name) {
      var data = ce[name];
      if (!data || !data.values) return;
      var configData = data.values[configKey];
      if (!configData) return;

      var ceMachs = ce.axes.mach || machs;
      var ceAlphas = ce.axes.alpha_deg || alphas;
      var ceBestIdx = 0;
      var ceBestDist = 999;
      ceAlphas.forEach(function(a, i) {
        if (Math.abs(a - refAlpha) < ceBestDist) { ceBestDist = Math.abs(a - refAlpha); ceBestIdx = i; }
      });

      var row = '<tr><td>' + name + '</td>';
      ceMachs.forEach(function(m, mi) {
        var val = configData[mi] ? configData[mi][ceBestIdx] : null;
        if (val !== null && val !== undefined) {
          var cls = val >= 0 ? 'deriv-positive' : 'deriv-negative';
          row += '<td class="' + cls + '">' + val.toFixed(5) + '</td>';
        } else {
          row += '<td>--</td>';
        }
      });
      row += '</tr>';
      tbody.innerHTML += row;
    });
  }
}

// ════════════════════════════════════════════════════════════════
// Custom YAML serializer — one array per line with axis comments
// Mirrors the Julia output.jl format (schema v2.1)
// ════════════════════════════════════════════════════════════════

var YAML_MODEL_KEYS = ['schema_version','model_name','meta','conventions','reference',
  'limits','configurations','aerodynamics','per_surface_data','runtime_model',
  'visual_geometry','propulsion','actuators','failures','quality','vlm_mesh'];

var YAML_AERO_KEYS = ['interpolation',
  'coefficient_tuning',
  'static_coefficients',
  'wing_body',            // schema v3.0: wing + fuselage contribution
  'tail',                 // schema v3.0: per-tail-surface in local angles @ AC
  'interference',         // schema v3.0: downwash, sidewash, eta_h, eta_v
  'dynamic_derivatives',
  'control_effectiveness','control_drag_increments','local_flow','poststall'];

var YAML_PROP_KEYS = ['engine_count','throttle_input_mode','engines',
  'thrust_map_shared','aero_propulsion_coupling'];

var YAML_LOOKUP_SET = {static_coefficients:1, wing_body:1, dynamic_derivatives:1,
  control_effectiveness:1, control_drag_increments:1};

// Key ordering patterns (matches Julia sort_dict_keys)
var YAML_KEY_PATTERNS = [
  {m:'aircraft_id', o:['aircraft_id','created_utc','author','notes']},
  {m:'angles', o:['angles','rates','forces','moments','coeff_axes','body_axes','coefficient_order','nondim_rates']},
  {m:'mass_kg', x:'geometry', o:['mass_kg','geometry','cg_ref_m','inertia']},
  {m:'S_ref_m2', o:['S_ref_m2','b_ref_m','c_ref_m']},
  {m:'principal_moments_kgm2', o:['principal_moments_kgm2','principal_axes_rotation_deg']},
  {m:'Ixx_p', o:['Ixx_p','Iyy_p','Izz_p']},
  {m:'p_hat', o:['p_hat','q_hat','r_hat']},
  {m:'controls_deg', o:['mach','alpha_deg','beta_deg','controls_deg']},
  {m:'id', x:'flap_deg', o:['id','flap_deg','gear']},
  {m:'method', x:'out_of_range', o:['method','out_of_range']},
  {m:'global', x:'groups', o:['global','groups','families','coefficients','constant_offsets']},
  {m:'alpha_on_deg', o:['alpha_on_deg','alpha_off_deg','model','sideforce_scale','drag_floor','drag_90deg']},
  {m:'surface_rate_limit_deg_s', o:['surface_rate_limit_deg_s','position_limit_deg']},
  {m:'allow_engine_out', o:['allow_engine_out','default_failed_engines','failure_ramp_time_s']},
  {m:'missing_term_policy', o:['missing_term_policy','provenance','confidence']},
  {m:'linear_core', o:['linear_core','nonlinear_surfaces','nonlinear','propulsion','poststall']}
];

function yOrdKeys(obj) {
  var ks = Object.keys(obj);
  for (var i = 0; i < YAML_KEY_PATTERNS.length; i++) {
    var p = YAML_KEY_PATTERNS[i];
    if (ks.indexOf(p.m) >= 0) {
      if (p.x && ks.indexOf(p.x) < 0) continue;
      return ySortBy(ks, p.o);
    }
  }
  return ks.slice().sort();
}

function ySortBy(ks, order) {
  var out = [];
  order.forEach(function(k) { if (ks.indexOf(k) >= 0) out.push(k); });
  ks.slice().sort().forEach(function(k) { if (out.indexOf(k) < 0) out.push(k); });
  return out;
}

function yIsScalar(v) {
  return v === null || v === undefined || typeof v === 'number' ||
         typeof v === 'string' || typeof v === 'boolean';
}

function yIsLeaf(arr) {
  if (!Array.isArray(arr)) return false;
  for (var i = 0; i < arr.length; i++) { if (!yIsScalar(arr[i])) return false; }
  return true;
}

function yIsInline(obj) {
  if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) return false;
  var ks = Object.keys(obj);
  if (ks.length > 4) return false;
  for (var i = 0; i < ks.length; i++) { if (!yIsScalar(obj[ks[i]])) return false; }
  return true;
}

function yNum(v) {
  if (typeof v !== 'number') return String(v);
  if (isNaN(v)) return '.nan';
  if (!isFinite(v)) return v > 0 ? '.inf' : '-.inf';
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v);
  if (v === 0) return '0.0';
  if (v === Math.round(v) && Math.abs(v) < 1e8) return v.toFixed(1);
  if (Math.abs(v) >= 0.0001) {
    var s = v.toFixed(6).replace(/0+$/, '').replace(/\.$/, '.0');
    return s;
  }
  return v.toExponential(6);
}

function yNeedQ(s) {
  if (typeof s !== 'string') return false;
  if (s === '') return true;
  if (['true','false','null','yes','no','on','off'].indexOf(s) >= 0) return true;
  if (/[:{}\[\],&*?|>'"%@`#]/.test(s)) return true;
  if (s.charAt(0) === ' ' || s.charAt(s.length-1) === ' ') return true;
  if (!isNaN(parseFloat(s)) && isFinite(s)) return true;
  return false;
}

function yQ(s) { return '"' + String(s).replace(/\\/g,'\\\\').replace(/"/g,'\\"') + '"'; }

function yScalar(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'string') return yNeedQ(v) ? yQ(v) : v;
  if (typeof v === 'number') return yNum(v);
  return String(v);
}

function yFlow(arr) {
  return '[' + arr.map(function(v) {
    if (typeof v === 'number') return yNum(v);
    if (typeof v === 'string') return yNeedQ(v) ? yQ(v) : v;
    if (typeof v === 'boolean') return v ? 'true' : 'false';
    return String(v);
  }).join(', ') + ']';
}

function yInline(obj) {
  return '{' + Object.keys(obj).sort().map(function(k) {
    return k + ': ' + yScalar(obj[k]);
  }).join(', ') + '}';
}

function yP(n) { var s=''; for(var i=0;i<n;i++) s+=' '; return s; }

// ---- Top-level entry point ----

function customYamlDump(model) {
  var L = [];
  YAML_MODEL_KEYS.forEach(function(key) {
    if (!model.hasOwnProperty(key)) return;
    var val = model[key];
    if (key === 'schema_version') {
      L.push('schema_version: ' + yScalar(val));
    } else if (key === 'model_name') {
      L.push('model_name: ' + yQ(String(val || '')));
    } else if (key === 'aerodynamics') {
      L.push(''); L.push('aerodynamics:');
      yWriteAero(L, val, 2);
    } else if (key === 'propulsion') {
      L.push(''); L.push('propulsion:');
      yWriteProp(L, val, 2);
    } else {
      L.push(''); L.push(key + ':');
      yWriteVal(L, val, 2);
    }
  });
  return L.join('\n') + '\n';
}

// ---- Aerodynamics section ----

function yWriteAero(L, aero, ind) {
  var p = yP(ind);
  YAML_AERO_KEYS.forEach(function(key) {
    if (!aero.hasOwnProperty(key)) return;
    L.push(p + key + ':');
    if (YAML_LOOKUP_SET[key]) {
      yWriteLookup(L, aero[key], ind + 2);
    } else if (key === 'tail') {
      yWriteTailSection(L, aero[key], ind + 2);
    } else if (key === 'interference') {
      yWriteInterferenceSection(L, aero[key], ind + 2);
    } else {
      yWriteVal(L, aero[key], ind + 2);
    }
  });
}

// ---- Tail section (schema v3.0) ----
function yWriteTailSection(L, tail, ind) {
  var p = yP(ind);
  if (tail.axis_order_per_surface) {
    L.push(p + 'axis_order_per_surface: ' + yFlow(tail.axis_order_per_surface));
  }
  if (tail.axes) {
    L.push(p + 'axes:');
    ['config','mach','alpha_h_deg','beta_v_deg'].forEach(function(ak) {
      if (tail.axes.hasOwnProperty(ak)) L.push(p + '  ' + ak + ': ' + yFlow(tail.axes[ak]));
    });
  }
  var surfaces = tail.surfaces || [];
  L.push(p + 'surfaces:');
  var p2 = yP(ind + 2);
  var machs  = (tail.axes && tail.axes.mach) || [];
  var alphas = (tail.axes && tail.axes.alpha_h_deg) || [];
  var betas  = (tail.axes && tail.axes.beta_v_deg)  || [];
  var colComment = betas.length ? (', beta_v_deg: ' + yFlow(betas)) : '';
  surfaces.forEach(function(surf) {
    L.push(p2 + '- name: ' + yQ(surf.name || 'tail'));
    if (surf.role)      L.push(p2 + '  role: ' + yQ(surf.role));
    if (surf.component) L.push(p2 + '  component: ' + yQ(surf.component));
    if (surf.arm_m)     L.push(p2 + '  arm_m: ' + yFlow(surf.arm_m));
    if (surf.ac_xyz_m)  L.push(p2 + '  ac_xyz_m: ' + yFlow(surf.ac_xyz_m));
    ['CL','CD','CY','Cl_at_AC','Cm_at_AC','Cn_at_AC'].forEach(function(cn) {
      if (!surf.hasOwnProperty(cn)) return;
      L.push(p2 + '  ' + cn + ':');               // col ind+4
      var cv = surf[cn];
      if (cv && typeof cv === 'object' && cv.values) {
        L.push(p2 + '    values:');                // col ind+6
        yWriteLookupVals(L, cv.values, ind + 8, machs, alphas, colComment);  // cfg at col ind+8
      } else {
        yWriteVal(L, cv, ind + 4);
      }
    });
  });
}

// ---- Interference section (schema v3.0) ----
function yWriteInterferenceSection(L, ifb, ind) {
  var p = yP(ind);
  if (ifb.source) L.push(p + 'source: ' + yQ(ifb.source));
  ['axis_order_alpha','axis_order_beta'].forEach(function(k) {
    if (ifb[k]) L.push(p + k + ': ' + yFlow(ifb[k]));
  });
  if (ifb.axes) {
    L.push(p + 'axes:');
    ['config','mach','alpha_deg','beta_deg'].forEach(function(ak) {
      if (ifb.axes.hasOwnProperty(ak)) L.push(p + '  ' + ak + ': ' + yFlow(ifb.axes[ak]));
    });
  }
  L.push('');
  var machs  = (ifb.axes && ifb.axes.mach)      || [];
  var alphas = (ifb.axes && ifb.axes.alpha_deg) || [];
  var betas  = (ifb.axes && ifb.axes.beta_deg)  || [];
  ['downwash_deg','eta_h'].forEach(function(k) {
    if (!ifb[k]) return;
    L.push(p + k + ':');
    var dv = ifb[k];
    if (dv && typeof dv === 'object' && dv.values) {
      L.push(p + '  values:');
      yWriteLookupVals(L, dv.values, ind + 4, machs, alphas, '');
    }
  });
  ['sidewash_deg','eta_v'].forEach(function(k) {
    if (!ifb[k]) return;
    L.push(p + k + ':');
    var dv = ifb[k];
    if (dv && typeof dv === 'object' && dv.values) {
      L.push(p + '  values:');
      yWriteLookupVals(L, dv.values, ind + 4, machs, betas, '');
    }
  });
}

// ---- Propulsion section ----

function yWriteProp(L, prop, ind) {
  var p = yP(ind);
  YAML_PROP_KEYS.forEach(function(key) {
    if (!prop.hasOwnProperty(key)) return;
    var val = prop[key];
    if (yIsScalar(val)) {
      L.push(p + key + ': ' + yScalar(val));
    } else if (key === 'engines') {
      L.push(p + 'engines:');
      yWriteEngines(L, val, ind + 2);
    } else if (key === 'thrust_map_shared') {
      L.push(p + 'thrust_map_shared:');
      yWriteThrustMap(L, val, ind + 2);
    } else {
      L.push(p + key + ':');
      yWriteVal(L, val, ind + 2);
    }
  });
}

// ---- Lookup table section (static_coefficients etc.) ----

function yWriteLookup(L, sec, ind) {
  var p = yP(ind);

  // axis_order + axes
  if (sec.axis_order) L.push(p + 'axis_order: ' + yFlow(sec.axis_order));
  if (sec.axes) {
    L.push(p + 'axes:');
    ['config','mach','alpha_deg','beta_deg','abs_deflection_deg','ct_total'].forEach(function(ak) {
      if (sec.axes.hasOwnProperty(ak)) L.push(p + '  ' + ak + ': ' + yFlow(sec.axes[ak]));
    });
  }
  L.push('');

  var machs  = (sec.axes && sec.axes.mach)      || [];
  var alphas = (sec.axes && sec.axes.alpha_deg)  || [];

  // Build column-axis comment suffix (e.g. ", beta_deg: [-15, -10, ...]")
  var colComment = '';
  if (sec.axis_order && sec.axis_order.length >= 4) {
    var colName = sec.axis_order[3];
    if (sec.axes && sec.axes[colName]) {
      colComment = ', ' + colName + ': ' + yFlow(sec.axes[colName]);
    }
  }

  // Data keys (skip axis_order, axes)
  var skip = {axis_order:1, axes:1};
  var dkeys = Object.keys(sec).filter(function(k){return !skip[k];}).sort();

  dkeys.forEach(function(dk) {
    var dv = sec[dk];
    L.push(p + dk + ':');
    if (dv && typeof dv === 'object' && !Array.isArray(dv) && dv.values) {
      L.push(p + '  values:');
      yWriteLookupVals(L, dv.values, ind + 4, machs, alphas, colComment);
    } else {
      yWriteVal(L, dv, ind + 2);
    }
  });
}

function yWriteLookupVals(L, vals, ind, machs, alphas, colComment) {
  colComment = colComment || '';
  var p = yP(ind);
  if (vals && typeof vals === 'object' && !Array.isArray(vals)) {
    Object.keys(vals).sort().forEach(function(cfg) {
      L.push(p + cfg + ':');
      if (Array.isArray(vals[cfg])) {
        yWriteMachArr(L, vals[cfg], ind + 2, machs, alphas, colComment);
      } else {
        L.push(p + '  ' + yScalar(vals[cfg]));
      }
    });
  } else if (Array.isArray(vals)) {
    yWriteMachArr(L, vals, ind, machs, alphas, colComment);
  }
}

function yWriteMachArr(L, arr, ind, machs, alphas, colComment) {
  colComment = colComment || '';
  var p = yP(ind);

  arr.forEach(function(machData, mi) {
    var hasMach = machs.length > 0 && mi < machs.length;
    if (hasMach) L.push(p + '- # Mach ' + yNum(machs[mi]) + colComment);

    if (Array.isArray(machData) && machData.length > 0 && Array.isArray(machData[0])) {
      // 2D: alpha rows × beta/deflection columns
      machData.forEach(function(row, ai) {
        var comment = (alphas.length > 0 && ai < alphas.length)
          ? '  # alpha = ' + yNum(alphas[ai]) : '';
        if (hasMach) {
          L.push(p + '  - ' + yFlow(row) + comment);
        } else if (ai === 0) {
          L.push(p + '- - ' + yFlow(row) + comment);
        } else {
          L.push(p + '  - ' + yFlow(row) + comment);
        }
      });
    } else if (Array.isArray(machData)) {
      // 1D: alpha values (dynamic_derivatives, control_effectiveness)
      if (hasMach) {
        L.push(p + '  ' + yFlow(machData));
      } else {
        L.push(p + '- ' + yFlow(machData));
      }
    } else {
      if (hasMach) {
        L.push(p + '  ' + yScalar(machData));
      } else {
        L.push(p + '- ' + yScalar(machData));
      }
    }
  });
}

// ---- Engine list ----

function yWriteEngines(L, engines, ind) {
  var p = yP(ind);
  engines.forEach(function(eng) {
    L.push(p + '- id: ' + yQ(eng.id || 'ENG'));
    if (eng.position_m) {
      if (Array.isArray(eng.position_m)) {
        L.push(p + '  position_m: ' + yFlow(eng.position_m));
      } else {
        L.push(p + '  position_m: ' + yInline(eng.position_m));
      }
    }
    if (eng.orientation_deg) {
      if (Array.isArray(eng.orientation_deg)) {
        L.push(p + '  orientation_deg: ' + yFlow(eng.orientation_deg));
      } else {
        L.push(p + '  orientation_deg: ' + yInline(eng.orientation_deg));
      }
    }
    ['thrust_scale','spool_up_1_s','spool_down_1_s'].forEach(function(k) {
      if (eng.hasOwnProperty(k)) L.push(p + '  ' + k + ': ' + yNum(eng[k]));
    });
  });
}

// ---- Thrust map ----

function yWriteThrustMap(L, tmap, ind) {
  var p = yP(ind);
  if (tmap.axis_order) L.push(p + 'axis_order: ' + yFlow(tmap.axis_order));
  if (tmap.axes) {
    L.push(p + 'axes:');
    ['mach','altitude_m','throttle'].forEach(function(ak) {
      if (tmap.axes.hasOwnProperty(ak)) L.push(p + '  ' + ak + ': ' + yFlow(tmap.axes[ak]));
    });
  }
  L.push('');
  if (tmap.values) {
    var machs = (tmap.axes && tmap.axes.mach) || [];
    L.push(p + '# values[mach_index][altitude_index][throttle_index]');
    L.push(p + 'values:');
    yWriteMachArr(L, tmap.values, ind + 2, machs, []);
  }
}

// ---- Generic YAML value writer ----

function yWriteVal(L, val, ind) {
  var p = yP(ind);

  if (yIsScalar(val)) {
    L.push(p + yScalar(val));
    return;
  }

  if (Array.isArray(val)) {
    if (yIsLeaf(val)) {
      val.forEach(function(item) { L.push(p + '- ' + yScalar(item)); });
    } else if (val.length > 0 && typeof val[0] === 'object' && !Array.isArray(val[0])) {
      val.forEach(function(item) { yWriteDictItem(L, item, ind); });
    } else {
      yWriteBlockArr(L, val, ind);
    }
    return;
  }

  if (typeof val === 'object' && val !== null) {
    var ks = yOrdKeys(val);
    ks.forEach(function(k) {
      var v = val[k];
      if (yIsScalar(v)) {
        L.push(p + k + ': ' + yScalar(v));
      } else if (Array.isArray(v) && yIsLeaf(v)) {
        L.push(p + k + ': ' + yFlow(v));
      } else if (!Array.isArray(v) && typeof v === 'object' && v !== null && yIsInline(v)) {
        L.push(p + k + ': ' + yInline(v));
      } else if (Array.isArray(v) && v.length > 0 && typeof v[0] === 'object' && !Array.isArray(v[0])) {
        L.push(p + k + ':');
        v.forEach(function(item) {
          if (typeof item === 'object' && !Array.isArray(item) && item !== null) {
            yWriteDictItem(L, item, ind + 2);
          } else {
            L.push(p + '  - ' + yScalar(item));
          }
        });
      } else if (Array.isArray(v)) {
        L.push(p + k + ':');
        yWriteBlockArr(L, v, ind + 2);
      } else {
        L.push(p + k + ':');
        yWriteVal(L, v, ind + 2);
      }
    });
  }
}

function yWriteBlockArr(L, arr, ind) {
  var p = yP(ind);
  arr.forEach(function(item) {
    if (yIsScalar(item)) {
      L.push(p + '- ' + yScalar(item));
    } else if (Array.isArray(item) && yIsLeaf(item)) {
      L.push(p + '- ' + yFlow(item));
    } else if (Array.isArray(item)) {
      L.push(p + '-');
      yWriteBlockArr(L, item, ind + 2);
    } else if (typeof item === 'object' && item !== null) {
      yWriteDictItem(L, item, ind);
    }
  });
}

function yWriteDictItem(L, item, ind) {
  var p = yP(ind);
  if (typeof item !== 'object' || item === null) {
    L.push(p + '- ' + yScalar(item)); return;
  }
  var ks = yOrdKeys(item);
  if (ks.length === 0) return;

  // First key with "- " prefix
  var fk = ks[0], fv = item[fk];
  if (yIsScalar(fv)) {
    L.push(p + '- ' + fk + ': ' + yScalar(fv));
  } else if (!Array.isArray(fv) && typeof fv === 'object' && fv !== null && yIsInline(fv)) {
    L.push(p + '- ' + fk + ': ' + yInline(fv));
  } else if (Array.isArray(fv) && yIsLeaf(fv)) {
    L.push(p + '- ' + fk + ': ' + yFlow(fv));
  } else {
    L.push(p + '- ' + fk + ':');
    yWriteVal(L, fv, ind + 4);
  }

  // Remaining keys with "  " prefix
  for (var i = 1; i < ks.length; i++) {
    var k = ks[i], v = item[k];
    if (yIsScalar(v)) {
      L.push(p + '  ' + k + ': ' + yScalar(v));
    } else if (Array.isArray(v) && yIsLeaf(v)) {
      L.push(p + '  ' + k + ': ' + yFlow(v));
    } else if (!Array.isArray(v) && typeof v === 'object' && v !== null && yIsInline(v)) {
      L.push(p + '  ' + k + ': ' + yInline(v));
    } else {
      L.push(p + '  ' + k + ':');
      yWriteVal(L, v, ind + 4);
    }
  }
}

// ---- OpenFlight Export ----
// Wire up both the results panel button and the control bar button
['exportOpenFlightResultsBtn', 'exportOpenFlightBtn'].forEach(function(id) {
  var btn = document.getElementById(id);
  if (btn) {
    btn.addEventListener('click', function() {
      if (typeof showValidationAndExport === 'function') {
        showValidationAndExport();
      } else {
        alert('Export module not loaded.');
      }
    });
  }
});

// ---- Build a linearized-only model subset from the full model ----
// Keeps scalar derivatives, reference geometry, propulsion, actuators, and
// stall/configuration data — everything the simulator's linear aero model
// (0.3_🧮_linear_aerodynamic_model.jl) needs. Drops the large coefficient
// tables that only the table-mode path uses.
function cloneLinearizedExportValue(value) {
  return value === undefined ? value : JSON.parse(JSON.stringify(value));
}

function buildLinearizedRuntimeModel(runtimeModel) {
  if (!runtimeModel || typeof runtimeModel !== 'object' || Array.isArray(runtimeModel)) {
    return undefined;
  }

  var compact = {};
  Object.keys(runtimeModel).forEach(function(key) {
    var value = runtimeModel[key];
    if (value === undefined || value === null) return;

    // Linear mode only needs scalar runtime constants. The large lookup tables
    // are for table/component assembly and should not be copied into the
    // simplified export.
    if (key === 'CD0_table' || key === 'tail_CL' || key === 'tail_CS') return;

    if (typeof value === 'number' || typeof value === 'string' || typeof value === 'boolean') {
      compact[key] = value;
    } else if (!Array.isArray(value) && typeof value === 'object') {
      compact[key] = cloneLinearizedExportValue(value);
    }
  });

  return compact;
}

function buildLinearizedModel(full) {
  var lin = {};
  var copyKeys = [
    'schema_version', 'model_name', 'meta', 'conventions',
    'reference', 'limits', 'configurations',
    'visual_geometry', 'propulsion', 'actuators', 'failures', 'quality'
  ];
  for (var i = 0; i < copyKeys.length; i++) {
    if (full[copyKeys[i]] !== undefined) {
      lin[copyKeys[i]] = cloneLinearizedExportValue(full[copyKeys[i]]);
    }
  }

  var runtimeModel = buildLinearizedRuntimeModel(full.runtime_model);
  if (runtimeModel) {
    lin.runtime_model = runtimeModel;
  }

  if (full.aerodynamics && full.aerodynamics.coefficient_tuning) {
    lin.aerodynamics = {
      coefficient_tuning: cloneLinearizedExportValue(full.aerodynamics.coefficient_tuning)
    };
  }
  return lin;
}

// ---- YAML / JSON Export ----
// Exports TWO YAML files:
//   name.tabular.aero_prop.yaml    — full tables for table mode
//   name.linearized.aero_prop.yaml — scalar derivatives for linear mode
document.getElementById('exportYamlBtn').addEventListener('click', function() {
  if (!window.aeroModel) {
    alert('No results to export. Run an analysis first.');
    return;
  }
  var name = (window.aircraftData && window.aircraftData.general && window.aircraftData.general.aircraft_name
              ? window.aircraftData.general.aircraft_name.replace(/\s+/g, '_')
              : 'aero_model');

  // 1. Full tabular model (primary — shown in the folder picker modal)
  var tabularYaml = customYamlDump(window.aeroModel);

  // 2. Linearized subset (queued as an extra file — saved to the SAME
  //    folder automatically when the user clicks Save, no second dialog)
  var linModel = buildLinearizedModel(window.aeroModel);
  var linYaml = customYamlDump(linModel);

  // Open the folder picker for the tabular file. The linearized file is
  // queued as an extra — both are saved to the same folder on a single
  // "Save" click, no second dialog.
  saveViaServer(tabularYaml, name + '.tabular.aero_prop.yaml');
  if (typeof window.addPendingExtraFile === 'function') {
    window.addPendingExtraFile(name + '.linearized.aero_prop.yaml', linYaml);
  }
});

document.getElementById('exportJsonModelBtn').addEventListener('click', function() {
  if (!window.aeroModel) {
    alert('No results to export. Run an analysis first.');
    return;
  }
  var jsonStr = JSON.stringify(window.aeroModel, null, 2);
  var name = (window.aircraftData && window.aircraftData.general && window.aircraftData.general.aircraft_name
              ? window.aircraftData.general.aircraft_name.replace(/\s+/g, '_')
              : 'aero_model');
  saveViaServer(jsonStr, name + '.aero_prop.json');
});

function downloadFile(content, filename, mimeType) {
  var blob = new Blob([content], { type: mimeType });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.style.display = 'none';
  document.body.appendChild(a);
  setTimeout(function() {
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }, 0);
}

// ---- Load results from file (for offline use) ----
window.loadAeroModelFromFile = function(file) {
  var reader = new FileReader();
  reader.onload = function(e) {
    try {
      var model;
      if (file.name.endsWith('.yaml') || file.name.endsWith('.yml')) {
        if (typeof jsyaml !== 'undefined') {
          model = jsyaml.load(e.target.result);
        } else {
          alert('js-yaml not available for parsing YAML files.');
          return;
        }
      } else {
        model = JSON.parse(e.target.result);
      }
      window.aeroModel = model;
      showResultsPanel();
      showResultsCharts(model);
    } catch (err) {
      alert('Error loading model file: ' + err.message);
    }
  };
  reader.readAsText(file);
};
