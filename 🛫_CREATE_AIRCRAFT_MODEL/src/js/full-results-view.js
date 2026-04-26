/********************************************
 * FILE: full-results-view.js
 * Opens a comprehensive results dashboard
 * in a new browser tab with all coefficient
 * charts and tabular data.
 ********************************************/

function openFullResultsView() {
  var model = window.aeroModel;
  if (!model) {
    alert('No analysis results available. Run an analysis first.');
    return;
  }

  var w = window.open('', '_blank');
  if (!w) {
    alert('Pop-up blocked. Please allow pop-ups for this page.');
    return;
  }

  var aero = model.aerodynamics;
  if (!aero || !aero.static_coefficients) {
    w.document.write('<html><body><h2>No aerodynamic data available</h2></body></html>');
    return;
  }

  var sc = aero.static_coefficients;
  var configs = sc.axes.config || ['clean'];
  var machs = sc.axes.mach || [0.2];
  var alphas = sc.axes.alpha_deg || [];
  var betas = sc.axes.beta_deg || [0];

  var configKey = configs[0];

  // Find beta closest to 0
  var beta0Idx = 0;
  betas.forEach(function(b, i) { if (Math.abs(b) < Math.abs(betas[beta0Idx])) beta0Idx = i; });

  // Find alpha closest to 0
  var alpha0Idx = 0;
  alphas.forEach(function(a, i) { if (Math.abs(a) < Math.abs(alphas[alpha0Idx])) alpha0Idx = i; });

  // Build the HTML content
  var html = buildFullResultsHTML(model, sc, configKey, machs, alphas, betas, beta0Idx, alpha0Idx);
  w.document.write(html);
  w.document.close();
}

function buildFullResultsHTML(model, sc, configKey, machs, alphas, betas, beta0Idx, alpha0Idx) {
  var modelName = model.model_name || 'Aircraft Model';
  var aero = model.aerodynamics;

  // Color palette for Mach traces
  var colors = [
    'rgb(52,152,219)', 'rgb(231,76,60)', 'rgb(46,204,113)',
    'rgb(155,89,182)', 'rgb(243,156,18)', 'rgb(26,188,156)',
    'rgb(241,196,15)', 'rgb(142,68,173)'
  ];
  // Color palette for beta traces
  var betaColors = [
    'rgb(231,76,60)', 'rgb(243,156,18)', 'rgb(241,196,15)',
    'rgb(46,204,113)', 'rgb(52,152,219)', 'rgb(155,89,182)',
    'rgb(26,188,156)', 'rgb(142,68,173)'
  ];

  var coeffNames = ['CL', 'CD', 'CY', 'Cl', 'Cm', 'Cn'];
  var coeffLabels = {
    CL: 'Lift Coefficient', CD: 'Drag Coefficient', CY: 'Side Force Coefficient',
    Cl: 'Roll Moment Coefficient', Cm: 'Pitch Moment Coefficient', Cn: 'Yaw Moment Coefficient'
  };

  // Extract data helper
  function getSectionCoeffData(section, name) {
    var c = section && section[name];
    if (!c || !c.values) return null;
    return c.values[configKey];
  }

  // Serialize data for the new window
  var chartDataJSON = JSON.stringify({
    machs: machs,
    alphas: alphas,
    betas: betas,
    beta0Idx: beta0Idx,
    alpha0Idx: alpha0Idx,
    colors: colors,
    betaColors: betaColors,
    coeffNames: coeffNames,
    coeffLabels: coeffLabels,
    configKey: configKey,
    modelName: modelName
  });

  // Serialize coefficient data per coefficient
  var coeffDataParts = [];
  coeffNames.forEach(function(name) {
    var data = getSectionCoeffData(sc, name);
    coeffDataParts.push('"' + name + '":' + JSON.stringify(data));
  });
  var coeffDataJSON = '{' + coeffDataParts.join(',') + '}';

  var wbSource = aero.wing_body || sc;
  var wbCoeffDataParts = [];
  coeffNames.forEach(function(name) {
    var data = getSectionCoeffData(wbSource, name);
    wbCoeffDataParts.push('"' + name + '":' + JSON.stringify(data));
  });
  var wbCoeffDataJSON = '{' + wbCoeffDataParts.join(',') + '}';

  // Serialize dynamic derivatives if available
  var ddJSON = 'null';
  if (aero.dynamic_derivatives) {
    ddJSON = JSON.stringify(aero.dynamic_derivatives);
  }

  // Serialize control effectiveness if available
  var ceJSON = 'null';
  if (aero.control_effectiveness) {
    ceJSON = JSON.stringify(aero.control_effectiveness);
  }

  // Serialize control drag increments if available
  var cdiJSON = 'null';
  if (aero.control_drag_increments) {
    cdiJSON = JSON.stringify(aero.control_drag_increments);
  }

  // Serialize local flow if available
  var lfJSON = 'null';
  if (aero.local_flow) {
    lfJSON = JSON.stringify(aero.local_flow);
  }

  // Serialize post-stall model if available
  var psJSON = 'null';
  if (aero.poststall) {
    psJSON = JSON.stringify(aero.poststall);
  }

  // Serialize tail aerodynamics if available
  var taJSON = 'null';
  if (model.tail_aerodynamics) {
    taJSON = JSON.stringify(model.tail_aerodynamics);
  }

  var html = '<!DOCTYPE html>\n<html>\n<head>\n';
  html += '<meta charset="UTF-8">\n';
  html += '<title>' + modelName + ' \u2014 Full Aerodynamic Results</title>\n';
  html += '<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"><\/script>\n';
  html += '<style>\n';
  html += getFullResultsCSS();
  html += '\n</style>\n</head>\n<body>\n';

  // Header
  html += '<div class="header">\n';
  html += '  <h1>' + modelName + ' \u2014 Aerodynamic Analysis Results</h1>\n';
  html += '  <div class="header-info">';
  html += '    <span>Config: ' + configKey + '</span>';
  html += '    <span>Alpha: [' + alphas[0] + ', ' + alphas[alphas.length - 1] + ']\u00b0</span>';
  html += '    <span>Beta: [' + betas[0] + ', ' + betas[betas.length - 1] + ']\u00b0</span>';
  html += '    <span>Mach: ' + machs.map(function(m) { return m.toFixed(2); }).join(', ') + '</span>';
  html += '  </div>\n';

  // Tab navigation
  html += '  <div class="tab-nav">\n';
  html += '    <button class="tab-btn active" onclick="showTab(\'charts\')">Wing+Body</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'dynamics\')">Dynamic Deriv. (Total)</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'controls\')">Control Eff. (Total)</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'localflow\')">Local Flow</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'tailaero\')">Tails (Isolated)</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'total\')">Total Aircraft</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'carpet\')">Carpet Plots (W+B)</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'tables\')">Tables (W+B)</button>\n';
  html += '    <button class="tab-btn" onclick="showTab(\'summary\')">Summary</button>\n';
  html += '  </div>\n';
  html += '</div>\n';

  // ===== TAB 1: STATIC COEFFICIENTS =====
  html += '<div id="tab-charts" class="tab-content active">\n';

  html += '<h2>Wing+Body \u2014 Longitudinal Coefficients vs Alpha (\u03b2 = ' + betas[beta0Idx].toFixed(1) + '\u00b0)</h2>\n';
  html += '<div class="chart-grid">\n';
  ['CL', 'CD', 'Cm', 'LD'].forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_' + name + '_alpha"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Wing+Body \u2014 Lateral Coefficients vs Beta (\u03b1 = ' + alphas[alpha0Idx].toFixed(1) + '\u00b0)</h2>\n';
  html += '<div class="chart-grid">\n';
  ['CY', 'Cl', 'Cn', 'CD_beta'].forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_' + name + '_beta"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Wing+Body \u2014 Drag Characteristics</h2>\n';
  html += '<div class="chart-grid two-col">\n';
  html += '  <div class="chart-cell"><canvas id="chart_drag_polar"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_CD_alpha"></canvas></div>\n';
  html += '</div>\n';

  html += '</div>\n'; // end static tab

  // ===== TAB 2: DYNAMIC DERIVATIVES =====
  html += '<div id="tab-dynamics" class="tab-content">\n';

  html += '<h2>Total Aircraft \u2014 Dynamic Stability Derivatives vs Alpha</h2>\n';
  html += '<div class="chart-grid">\n';
  var ddNames = ['Cl_p_hat', 'Cm_q_hat', 'Cn_r_hat', 'CL_q_hat', 'CY_p_hat', 'CY_r_hat', 'Cm_alpha_dot_hat', 'Cn_beta_dot_hat'];
  var totalControlNames = ['Cl_da_per_deg', 'Cn_da_per_deg', 'Cd_da_per_deg', 'Cm_de_per_deg', 'Cn_dr_per_deg', 'Cl_dr_per_deg'];
  ddNames.forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_dd_' + name + '"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Total Aircraft \u2014 Dynamic Derivatives Table</h2>\n';
  html += '<div id="ddTableContainer" class="table-scroll"></div>\n';

  html += '</div>\n'; // end dynamics tab

  // ===== TAB 3: CONTROL EFFECTIVENESS =====
  html += '<div id="tab-controls" class="tab-content">\n';

  html += '<h2>Total Aircraft \u2014 Control Effectiveness vs Alpha (per degree deflection)</h2>\n';
  html += '<div id="ceChartGrid" class="chart-grid"></div>\n';

  html += '<h2>Total Aircraft \u2014 Control Drag Increments vs Alpha</h2>\n';
  html += '<div id="cdiChartGrid" class="chart-grid"></div>\n';

  html += '<h2>Total Aircraft \u2014 Control Effectiveness Table</h2>\n';
  html += '<div id="ceTableContainer" class="table-scroll"></div>\n';

  html += '</div>\n'; // end controls tab

  // ===== TAB 4: LOCAL FLOW =====
  html += '<div id="tab-localflow" class="tab-content">\n';

  html += '<h2>Downwash, Sidewash &amp; Tail Dynamic Pressure</h2>\n';
  html += '<div class="chart-grid">\n';
  html += '  <div class="chart-cell"><canvas id="chart_downwash"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_sidewash"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_tail_dpr"></canvas></div>\n';
  html += '</div>\n';

  html += '<h2>Post-Stall Model Parameters</h2>\n';
  html += '<div id="psContainer"></div>\n';

  html += '</div>\n'; // end localflow tab

  // ===== TAB 5: TAIL AERODYNAMICS =====
  html += '<div id="tab-tailaero" class="tab-content">\n';

  html += '<h2>Horizontal Tail (HTP) \u2014 Isolated Characteristics (coefficients normalized by aircraft S<sub>ref</sub>)</h2>\n';
  html += '<div class="chart-grid two-col">\n';
  html += '  <div class="chart-cell"><canvas id="chart_CLh_alpha"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_Cm_HTP_alpha"></canvas></div>\n';
  html += '</div>\n';

  html += '<h2>HTP Control — Elevator Effectiveness</h2>\n';
  html += '<div class="chart-grid two-col">\n';
  html += '  <div class="chart-cell"><canvas id="chart_dCDh_de"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_dCm_de"></canvas></div>\n';
  html += '</div>\n';

  html += '<h2>Vertical Tail (VTP) \u2014 Isolated Characteristics (coefficients normalized by aircraft S<sub>ref</sub>)</h2>\n';
  html += '<div class="chart-grid two-col">\n';
  html += '  <div class="chart-cell"><canvas id="chart_CYv_beta"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_Cn_VTP_beta"></canvas></div>\n';
  html += '</div>\n';

  html += '<h2>VTP Control — Rudder Effectiveness</h2>\n';
  html += '<div class="chart-grid two-col">\n';
  html += '  <div class="chart-cell"><canvas id="chart_dCYv_dr"></canvas></div>\n';
  html += '  <div class="chart-cell"><canvas id="chart_dCDv_dr"></canvas></div>\n';
  html += '</div>\n';

  html += '<div id="tailAeroSummary"></div>\n';

  html += '</div>\n'; // end tailaero tab

  // ===== TAB: TOTAL AIRCRAFT =====
  html += '<div id="tab-total" class="tab-content">\n';

  html += '<p style="color:#888;margin:12px 24px 0;font-size:0.9em;">Total charts use the exported whole-aircraft static and dynamic tables, including tail effects. Wing+Body and isolated tail curves are still shown separately above for diagnosis.</p>\n';
  html += '<h2>Total Aircraft \u2014 Longitudinal Coefficients vs Alpha (\u03b2 = ' + betas[beta0Idx].toFixed(1) + '\u00b0)</h2>\n';
  html += '<div class="chart-grid">\n';
  ['CL', 'CD', 'Cm', 'LD'].forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_total_' + name + '_alpha"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Total Aircraft \u2014 Lateral Coefficients vs Beta (\u03b1 = ' + alphas[alpha0Idx].toFixed(1) + '\u00b0)</h2>\n';
  html += '<div class="chart-grid">\n';
  ['CY', 'Cl', 'Cn'].forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_total_' + name + '_beta"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Total Aircraft \u2014 Dynamic Stability Derivatives vs Alpha</h2>\n';
  html += '<div class="chart-grid">\n';
  ddNames.forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_total_dd_' + name + '"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Total Aircraft \u2014 Control Derivatives vs Alpha</h2>\n';
  html += '<div class="chart-grid">\n';
  totalControlNames.forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_total_ce_' + name + '"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '</div>\n'; // end total tab

  // ===== TAB 6: CARPET PLOTS =====
  html += '<div id="tab-carpet" class="tab-content">\n';

  html += '<h2>Wing+Body \u2014 All Coefficients vs Alpha (multiple Beta slices, M=' + machs[0].toFixed(2) + ')</h2>\n';
  html += '<div class="chart-grid">\n';
  coeffNames.forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_' + name + '_multibeta"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '<h2>Wing+Body \u2014 All Coefficients vs Beta (multiple Alpha slices, M=' + machs[0].toFixed(2) + ')</h2>\n';
  html += '<div class="chart-grid">\n';
  coeffNames.forEach(function(name) {
    html += '  <div class="chart-cell"><canvas id="chart_' + name + '_multialpha"></canvas></div>\n';
  });
  html += '</div>\n';

  html += '</div>\n'; // end carpet tab

  // ===== TAB 6: TABLES =====
  html += '<div id="tab-tables" class="tab-content">\n';
  html += '<h2>Wing+Body \u2014 Coefficient Tables (\u03b1 \u00d7 \u03b2)</h2>\n';
  html += '<div class="table-controls">\n';
  html += '  <label>Mach: <select id="tableMachSelect"></select></label>\n';
  html += '  <label>Coefficient: <select id="tableCoeffSelect">';
  coeffNames.forEach(function(n) { html += '<option value="' + n + '">' + n + '</option>'; });
  html += '</select></label>\n';
  html += '  <button class="action-btn" onclick="updateTable()">Update Table</button>\n';
  html += '  <button class="action-btn" onclick="copyTableCSV()">Copy as CSV</button>\n';
  html += '</div>\n';
  html += '<div id="tableContainer" class="table-scroll"></div>\n';
  html += '</div>\n'; // end tables tab

  // ===== TAB 7: SUMMARY =====
  html += '<div id="tab-summary" class="tab-content">\n';
  html += '<div id="summaryContainer"></div>\n';
  html += '</div>\n'; // end summary tab

  // ===== SCRIPT =====
  html += '<script>\n';
  html += 'var CFG = ' + chartDataJSON + ';\n';
  html += 'var COEFF = ' + coeffDataJSON + ';\n';
  html += 'var WB_COEFF = ' + wbCoeffDataJSON + ';\n';
  html += 'var DD = ' + ddJSON + ';\n';
  html += 'var CE = ' + ceJSON + ';\n';
  html += 'var CDI = ' + cdiJSON + ';\n';
  html += 'var LF = ' + lfJSON + ';\n';
  html += 'var PS = ' + psJSON + ';\n';
  html += 'var TA = ' + taJSON + ';\n';
  html += getFullResultsScript();
  html += '\n<\/script>\n';
  html += '</body>\n</html>';

  return html;
}

function getFullResultsCSS() {
  return [
    '* { margin: 0; padding: 0; box-sizing: border-box; }',
    'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;',
    '       background: #1a1a2e; color: #e0e0e0; }',
    '.header { background: #16213e; padding: 16px 24px; border-bottom: 2px solid #0f3460;',
    '          position: sticky; top: 0; z-index: 100; }',
    '.header h1 { font-size: 18px; color: #e94560; margin-bottom: 6px; }',
    '.header-info { display: flex; gap: 20px; font-size: 13px; color: #8899aa; margin-bottom: 10px; }',
    '.tab-nav { display: flex; gap: 4px; flex-wrap: wrap; }',
    '.tab-btn { background: #0f3460; color: #8899aa; border: none; padding: 8px 14px;',
    '           cursor: pointer; border-radius: 4px 4px 0 0; font-size: 12px; font-weight: 600; }',
    '.tab-btn.active { background: #1a1a2e; color: #e94560; }',
    '.tab-btn:hover { color: #fff; }',
    '.tab-content { display: none; padding: 20px 24px; }',
    '.tab-content.active { display: block; }',
    'h2 { font-size: 15px; color: #53a8b6; margin: 20px 0 12px 0; padding-bottom: 4px;',
    '     border-bottom: 1px solid #2a2a4a; }',
    'h2:first-child { margin-top: 0; }',
    '.chart-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 24px; }',
    '.chart-grid.two-col { grid-template-columns: repeat(2, 1fr); }',
    '.chart-grid.four-col { grid-template-columns: repeat(4, 1fr); }',
    '.chart-cell { background: #16213e; border-radius: 6px; padding: 10px;',
    '              border: 1px solid #2a2a4a; min-height: 280px; }',
    '.chart-cell canvas { width: 100% !important; height: 260px !important; }',
    '.table-controls { display: flex; gap: 12px; align-items: center; margin-bottom: 14px; flex-wrap: wrap; }',
    '.table-controls label { font-size: 13px; color: #8899aa; }',
    '.table-controls select { background: #16213e; color: #e0e0e0; border: 1px solid #2a2a4a;',
    '                         padding: 4px 8px; border-radius: 4px; font-size: 13px; }',
    '.action-btn { background: #0f3460; color: #e0e0e0; border: 1px solid #2a2a4a;',
    '              padding: 6px 14px; border-radius: 4px; cursor: pointer; font-size: 13px; }',
    '.action-btn:hover { background: #e94560; color: #fff; }',
    '.table-scroll { overflow: auto; max-height: calc(100vh - 200px); }',
    'table.coeff-table { border-collapse: collapse; font-size: 12px; font-family: "Consolas", monospace; }',
    'table.coeff-table th, table.coeff-table td { padding: 3px 8px; border: 1px solid #2a2a4a;',
    '                                              text-align: right; white-space: nowrap; }',
    'table.coeff-table th { background: #0f3460; color: #53a8b6; position: sticky; top: 0; }',
    'table.coeff-table th.row-header { text-align: left; }',
    'table.coeff-table td.row-header { text-align: left; background: #16213e; color: #8899aa;',
    '                                   font-weight: 600; position: sticky; left: 0; }',
    'table.coeff-table tr:nth-child(even) { background: #1a1a3e; }',
    'table.coeff-table tr:hover { background: #2a2a5e; }',
    'td.pos { color: #46d369; } td.neg { color: #e94560; } td.zero { color: #666; }',
    '.deriv-table { border-collapse: collapse; font-size: 13px; margin-bottom: 20px; width: auto; }',
    '.deriv-table th, .deriv-table td { padding: 6px 14px; border: 1px solid #2a2a4a; }',
    '.deriv-table th { background: #0f3460; color: #53a8b6; text-align: left; }',
    '.deriv-table td { text-align: right; font-family: "Consolas", monospace; }',
    'h3 { font-size: 14px; color: #e94560; margin: 16px 0 8px; }',
    '.summary-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-bottom: 20px; }',
    '.summary-card { background: #16213e; border-radius: 8px; padding: 16px; border: 1px solid #2a2a4a; }',
    '.summary-card h4 { color: #53a8b6; font-size: 13px; margin-bottom: 8px; }',
    '.summary-card .value { font-size: 22px; font-weight: 700; color: #e94560; font-family: "Consolas", monospace; }',
    '.summary-card .unit { font-size: 12px; color: #8899aa; margin-left: 4px; }',
    '@media (max-width: 1200px) { .chart-grid { grid-template-columns: repeat(2, 1fr); }',
    '  .summary-grid { grid-template-columns: repeat(2, 1fr); } }',
    '@media (max-width: 600px) { .chart-grid, .chart-grid.two-col, .chart-grid.four-col { grid-template-columns: 1fr; }',
    '  .summary-grid { grid-template-columns: 1fr; } }'
  ].join('\n');
}

function getFullResultsScript() {
  // Build the script as a single template string for clarity
  return '\
function showTab(name) {\
  document.querySelectorAll(".tab-content").forEach(function(el) { el.classList.remove("active"); });\
  document.querySelectorAll(".tab-btn").forEach(function(el) { el.classList.remove("active"); });\
  var tab = document.getElementById("tab-" + name);\
  if (tab) tab.classList.add("active");\
  var idx = ["charts","dynamics","controls","localflow","tailaero","total","carpet","tables","summary"].indexOf(name);\
  var btns = document.querySelectorAll(".tab-btn");\
  if (idx >= 0 && btns[idx]) btns[idx].classList.add("active");\
}\
\
Chart.defaults.color = "#8899aa";\
Chart.defaults.borderColor = "#2a2a4a";\
Chart.defaults.font.size = 11;\
\
var POINT_STYLES = ["circle", "triangle", "rect", "rectRot", "star", "cross", "crossRot", "dash"];\
\
function makeChart(canvasId, title, xLabel, yLabel, datasets) {\
  var ctx = document.getElementById(canvasId);\
  if (!ctx) { console.warn("Canvas not found: " + canvasId); return; }\
  if (!datasets || datasets.length === 0) { console.warn("No datasets for: " + canvasId); return; }\
  new Chart(ctx, {\
    type: "scatter",\
    data: { datasets: datasets },\
    options: {\
      responsive: true, maintainAspectRatio: false,\
      plugins: { title: { display: true, text: title, color: "#e0e0e0", font: { size: 13 } },\
                 legend: { labels: { boxWidth: 12, font: { size: 10 }, usePointStyle: true } } },\
      scales: {\
        x: { title: { display: true, text: xLabel }, grid: { color: "#2a2a4a" } },\
        y: { title: { display: true, text: yLabel }, grid: { color: "#2a2a4a" } }\
      }\
    }\
  });\
}\
\
function extractVsAlpha(coeffName, betaIdx) {\
  var data = WB_COEFF[coeffName]; if (!data) return [];\
  var ds = [];\
  CFG.machs.forEach(function(mach, mi) {\
    var pts = [];\
    CFG.alphas.forEach(function(alpha, ai) {\
      var val = data[mi] && data[mi][ai] ? data[mi][ai][betaIdx] : null;\
      if (val === undefined) val = null;\
      if (val !== null) pts.push({ x: alpha, y: val });\
    });\
    ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
             borderColor: CFG.colors[mi % CFG.colors.length],\
             backgroundColor: "transparent", showLine: true, pointRadius: 3,\
             pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
             borderWidth: 2, tension: 0.2 });\
  });\
  return ds;\
}\
\
function extractVsBeta(coeffName, alphaIdx) {\
  var data = WB_COEFF[coeffName]; if (!data) return [];\
  var ds = [];\
  CFG.machs.forEach(function(mach, mi) {\
    var pts = [];\
    CFG.betas.forEach(function(beta, bi) {\
      var val = data[mi] && data[mi][alphaIdx] ? data[mi][alphaIdx][bi] : null;\
      if (val === undefined) val = null;\
      if (val !== null) pts.push({ x: beta, y: val });\
    });\
    ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
             borderColor: CFG.colors[mi % CFG.colors.length],\
             backgroundColor: "transparent", showLine: true, pointRadius: 3,\
             pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
             borderWidth: 2, tension: 0.2 });\
  });\
  return ds;\
}\
\
function extractMultiBeta(coeffName) {\
  var data = WB_COEFF[coeffName]; if (!data) return [];\
  var mi = 0; var ds = [];\
  var step = Math.max(1, Math.floor(CFG.betas.length / 7));\
  for (var bi = 0; bi < CFG.betas.length; bi += step) {\
    var pts = [];\
    CFG.alphas.forEach(function(alpha, ai) {\
      var val = data[mi] && data[mi][ai] ? data[mi][ai][bi] : null;\
      if (val === undefined) val = null;\
      if (val !== null) pts.push({ x: alpha, y: val });\
    });\
    ds.push({ label: "\\u03b2=" + CFG.betas[bi].toFixed(0) + "\\u00b0", data: pts,\
             borderColor: CFG.betaColors[ds.length % CFG.betaColors.length],\
             backgroundColor: "transparent", showLine: true, pointRadius: 2,\
             pointStyle: POINT_STYLES[ds.length % POINT_STYLES.length],\
             borderWidth: 1.5, tension: 0.2 });\
  }\
  return ds;\
}\
\
function extractMultiAlpha(coeffName) {\
  var data = WB_COEFF[coeffName]; if (!data) return [];\
  var mi = 0; var ds = [];\
  var step = Math.max(1, Math.floor(CFG.alphas.length / 7));\
  for (var ai = 0; ai < CFG.alphas.length; ai += step) {\
    var pts = [];\
    CFG.betas.forEach(function(beta, bi) {\
      var val = data[mi] && data[mi][ai] ? data[mi][ai][bi] : null;\
      if (val === undefined) val = null;\
      if (val !== null) pts.push({ x: beta, y: val });\
    });\
    ds.push({ label: "\\u03b1=" + CFG.alphas[ai].toFixed(0) + "\\u00b0", data: pts,\
             borderColor: CFG.colors[ds.length % CFG.colors.length],\
             backgroundColor: "transparent", showLine: true, pointRadius: 2,\
             pointStyle: POINT_STYLES[ds.length % POINT_STYLES.length],\
             borderWidth: 1.5, tension: 0.2 });\
  }\
  return ds;\
}\
\
function extract1D(section, key, cfg, mi, xArr) {\
  if (!section || !section[key]) return [];\
  var entry = section[key];\
  var cv = null;\
  if (entry.values) { cv = entry.values[cfg]; }\
  else if (entry[cfg]) { cv = entry[cfg]; }\
  else { return []; }\
  if (!cv) return [];\
  var arr = Array.isArray(cv[mi]) ? cv[mi] : (typeof cv[mi] === "number" ? [cv[mi]] : null);\
  if (!arr) return [];\
  var pts = [];\
  xArr.forEach(function(x, i) {\
    if (i < arr.length && arr[i] !== null && arr[i] !== undefined) pts.push({x: x, y: arr[i]});\
  });\
  return pts;\
}\
\
function getWingBodyControlKeys(section) {\
  var preferred = ["Cl_da_per_deg", "Cn_da_per_deg", "Cd_da_per_deg", "Cm_de_per_deg", "Cn_dr_per_deg", "Cl_dr_per_deg"];\
  return preferred.filter(function(name) {\
    return section && section[name] && section[name].values;\
  });\
}\
\
function showNoData(containerId, msg) {\
  var el = document.getElementById(containerId);\
  if (el) el.innerHTML = \'<p style="color:#8899aa;padding:20px;">\' + (msg || "No data available for this section.") + "</p>";\
}\
\
/* Replace a <canvas> element with an in-cell placeholder message so the\
   user sees "why this chart is blank" instead of empty space. Used for the\
   HTP elevator / VTP rudder effectiveness charts — they were previously\
   silently skipped when the aircraft input had no matching control\
   surface, which looked like a rendering bug in the Full View. */\
function replaceCanvasWithMessage(canvasId, msg) {\
  var canvas = document.getElementById(canvasId);\
  if (!canvas) return;\
  var parent = canvas.parentElement;\
  if (!parent) return;\
  parent.innerHTML = \'<p style="color:#8899aa;padding:20px;text-align:center;\' +\
                      \'font-style:italic;line-height:1.4;">\' +\
                      (msg || "No data available.") + "</p>";\
}\
\
window.addEventListener("load", function() {\
  console.log("[FullView] DD:", DD ? Object.keys(DD) : "null");\
  console.log("[FullView] CE:", CE ? Object.keys(CE) : "null");\
  console.log("[FullView] CDI:", CDI ? Object.keys(CDI) : "null");\
  console.log("[FullView] LF:", LF ? Object.keys(LF) : "null");\
  console.log("[FullView] PS:", PS ? Object.keys(PS) : "null");\
\
  /* ======== TAB 1: STATIC COEFFICIENTS ======== */\
  try {\
    ["CL", "CD", "Cm"].forEach(function(name) {\
      makeChart("chart_" + name + "_alpha",\
        name + " vs \\u03b1 \\u2014 Wing+Body (\\u03b2=" + CFG.betas[CFG.beta0Idx].toFixed(1) + "\\u00b0)",\
        "\\u03b1 (deg)", name, extractVsAlpha(name, CFG.beta0Idx));\
    });\
    var clLD = WB_COEFF["CL"], cdLD = WB_COEFF["CD"];\
    if (clLD && cdLD) {\
      var ldDs = [];\
      CFG.machs.forEach(function(mach, mi) {\
        var pts = [];\
        CFG.alphas.forEach(function(alpha, ai) {\
          var cl = clLD[mi] && clLD[mi][ai] ? clLD[mi][ai][CFG.beta0Idx] : null;\
          var cd = cdLD[mi] && cdLD[mi][ai] ? cdLD[mi][ai][CFG.beta0Idx] : null;\
          if (cl !== null && cd !== null && Math.abs(cd) > 1e-6) pts.push({ x: alpha, y: cl / cd });\
        });\
        ldDs.push({ label: "M=" + mach.toFixed(2), data: pts,\
                    borderColor: CFG.colors[mi % CFG.colors.length],\
                    backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                    pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                    borderWidth: 2, tension: 0.2 });\
      });\
      makeChart("chart_LD_alpha", "L/D vs \\u03b1 \\u2014 Wing+Body (\\u03b2=" + CFG.betas[CFG.beta0Idx].toFixed(1) + "\\u00b0)",\
        "\\u03b1 (deg)", "L/D", ldDs);\
    }\
    ["CY", "Cl", "Cn"].forEach(function(name) {\
      makeChart("chart_" + name + "_beta",\
        name + " vs \\u03b2 \\u2014 Wing+Body (\\u03b1=" + CFG.alphas[CFG.alpha0Idx].toFixed(1) + "\\u00b0)",\
        "\\u03b2 (deg)", name, extractVsBeta(name, CFG.alpha0Idx));\
    });\
    makeChart("chart_CD_beta_beta",\
      "CD vs \\u03b2 \\u2014 Wing+Body (\\u03b1=" + CFG.alphas[CFG.alpha0Idx].toFixed(1) + "\\u00b0)",\
      "\\u03b2 (deg)", "CD", extractVsBeta("CD", CFG.alpha0Idx));\
    if (clLD && cdLD) {\
      var dpDs = [];\
      CFG.machs.forEach(function(mach, mi) {\
        var pts = [];\
        CFG.alphas.forEach(function(alpha, ai) {\
          var cl = clLD[mi] && clLD[mi][ai] ? clLD[mi][ai][CFG.beta0Idx] : null;\
          var cd = cdLD[mi] && cdLD[mi][ai] ? cdLD[mi][ai][CFG.beta0Idx] : null;\
          if (cl !== null && cd !== null) pts.push({ x: cd, y: cl });\
        });\
        dpDs.push({ label: "M=" + mach.toFixed(2), data: pts,\
                    borderColor: CFG.colors[mi % CFG.colors.length],\
                    backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                    pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                    borderWidth: 2, tension: 0.2 });\
      });\
      makeChart("chart_drag_polar", "Drag Polar \\u2014 Wing+Body (CL vs CD)", "CD", "CL", dpDs);\
    }\
    makeChart("chart_CD_alpha",\
      "CD vs \\u03b1 \\u2014 Wing+Body (\\u03b2=" + CFG.betas[CFG.beta0Idx].toFixed(1) + "\\u00b0)",\
      "\\u03b1 (deg)", "CD", extractVsAlpha("CD", CFG.beta0Idx));\
  } catch(e) { console.error("[Tab1 Static] Error:", e); }\
\
  /* ======== TAB 2: DYNAMIC DERIVATIVES ======== */\
  try {\
    if (DD && DD.axes) {\
      var ddAlphas = DD.axes.alpha_deg || [];\
      var ddMachs = DD.axes.mach || [];\
      var ddCfg = (DD.axes.config || ["clean"])[0];\
      var ddKeys = Object.keys(DD).filter(function(k){ return k!=="axis_order"&&k!=="axes"; });\
      console.log("[Tab2] DD keys:", ddKeys, "cfg:", ddCfg, "machs:", ddMachs.length, "alphas:", ddAlphas.length);\
      ddKeys.forEach(function(dname) {\
        var ds = [];\
        ddMachs.forEach(function(mach, mi) {\
          var pts = extract1D(DD, dname, ddCfg, mi, ddAlphas);\
          if (pts.length > 0) {\
            ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
                      borderColor: CFG.colors[mi % CFG.colors.length],\
                      backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                      borderWidth: 2, tension: 0.2 });\
          }\
        });\
        makeChart("chart_dd_" + dname, dname + " vs \\u03b1 \\u2014 Total Aircraft", "\\u03b1 (deg)", dname, ds);\
      });\
      var ddHtml = \'<table class="deriv-table"><thead><tr><th>\\u03b1 (deg)</th>\';\
      ddKeys.forEach(function(n) { ddHtml += "<th>" + n + "</th>"; });\
      ddHtml += "</tr></thead><tbody>";\
      ddAlphas.forEach(function(alpha, ai) {\
        ddHtml += "<tr><td>" + alpha.toFixed(1) + "</td>";\
        ddKeys.forEach(function(n) {\
          var pts = extract1D(DD, n, ddCfg, 0, ddAlphas);\
          var val = ai < pts.length ? pts[ai].y : null;\
          ddHtml += "<td>" + (val !== null ? val.toFixed(4) : "--") + "</td>";\
        });\
        ddHtml += "</tr>";\
      });\
      ddHtml += "</tbody></table>";\
      document.getElementById("ddTableContainer").innerHTML = ddHtml;\
    } else {\
      showNoData("ddTableContainer", "No dynamic derivatives data available. DD=" + (DD ? "exists, axes=" + !!DD.axes : "null"));\
    }\
  } catch(e) { console.error("[Tab2 DD] Error:", e); showNoData("ddTableContainer", "Error rendering: " + e.message); }\
\
  /* ======== TAB 3: CONTROL EFFECTIVENESS ======== */\
  try {\
    if (CE && CE.axes) {\
      var ceAlphas = CE.axes.alpha_deg || [];\
      var ceMachs = CE.axes.mach || [];\
      var ceCfg = (CE.axes.config || ["clean"])[0];\
      var ceKeys = getWingBodyControlKeys(CE);\
      console.log("[Tab3] CE keys:", ceKeys, "cfg:", ceCfg);\
      var ceGrid = document.getElementById("ceChartGrid");\
      if (ceKeys.length === 0) {\
        showNoData("ceChartGrid", "No total-aircraft control-effectiveness data available.");\
        document.getElementById("ceTableContainer").innerHTML = "";\
      } else {\
      ceKeys.forEach(function(cname) {\
        var cell = document.createElement("div"); cell.className = "chart-cell";\
        var canvas = document.createElement("canvas"); canvas.id = "chart_ce_" + cname;\
        cell.appendChild(canvas); ceGrid.appendChild(cell);\
        var ds = [];\
        ceMachs.forEach(function(mach, mi) {\
          var pts = extract1D(CE, cname, ceCfg, mi, ceAlphas);\
          if (pts.length > 0) {\
            ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
                      borderColor: CFG.colors[mi % CFG.colors.length],\
                      backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                      borderWidth: 2, tension: 0.2 });\
          }\
        });\
        makeChart("chart_ce_" + cname, cname + " vs \\u03b1 \\u2014 Total Aircraft", "\\u03b1 (deg)", cname, ds);\
      });\
      var ceHtml = \'<table class="deriv-table"><thead><tr><th>\\u03b1 (deg)</th>\';\
      ceKeys.forEach(function(n) { ceHtml += "<th>" + n + "</th>"; });\
      ceHtml += "</tr></thead><tbody>";\
      ceAlphas.forEach(function(alpha, ai) {\
        ceHtml += "<tr><td>" + alpha.toFixed(1) + "</td>";\
        ceKeys.forEach(function(n) {\
          var pts = extract1D(CE, n, ceCfg, 0, ceAlphas);\
          var val = ai < pts.length ? pts[ai].y : null;\
          ceHtml += "<td>" + (val !== null ? val.toFixed(5) : "--") + "</td>";\
        });\
        ceHtml += "</tr>";\
      });\
      ceHtml += "</tbody></table>";\
      document.getElementById("ceTableContainer").innerHTML = ceHtml;\
      }\
    } else {\
      showNoData("ceChartGrid", "No control effectiveness data available.");\
    }\
  } catch(e) { console.error("[Tab3 CE] Error:", e); showNoData("ceTableContainer", "Error rendering: " + e.message); }\
\
  /* Control drag increments */\
  try {\
    if (CDI && CDI.axes) {\
      var cdiAlphas = CDI.axes.alpha_deg || [];\
      var cdiDefl = CDI.axes.abs_deflection_deg || [];\
      var cdiCfg = (CDI.axes.config || ["clean"])[0];\
      var cdiKeys = Object.keys(CDI).filter(function(k){ return k!=="axis_order"&&k!=="axes"; });\
      var cdiGrid = document.getElementById("cdiChartGrid");\
      cdiKeys.forEach(function(cname) {\
        var cell = document.createElement("div"); cell.className = "chart-cell";\
        var canvas = document.createElement("canvas"); canvas.id = "chart_cdi_" + cname;\
        cell.appendChild(canvas); cdiGrid.appendChild(cell);\
        var d = CDI[cname]; if(!d||!d.values) return;\
        var cv = d.values[cdiCfg]; if(!cv||!cv[0]) return;\
        var ds = [];\
        cdiDefl.forEach(function(defl, di) {\
          var pts = [];\
          cdiAlphas.forEach(function(alpha, ai) {\
            var row = cv[0] && cv[0][ai] ? cv[0][ai][di] : null;\
            if (row !== null && row !== undefined) pts.push({x: alpha, y: row});\
          });\
          if (pts.length > 0) {\
            ds.push({ label: "|\\u03b4|=" + defl.toFixed(0) + "\\u00b0", data: pts,\
                      borderColor: CFG.colors[di % CFG.colors.length],\
                      backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                      borderWidth: 2, tension: 0.2 });\
          }\
        });\
        makeChart("chart_cdi_" + cname, cname.replace(/_/g," ") + " vs \\u03b1", "\\u03b1 (deg)", "\\u0394CD", ds);\
      });\
    }\
  } catch(e) { console.error("[Tab3 CDI] Error:", e); }\
\
  /* ======== TAB 4: LOCAL FLOW ======== */\
  try {\
    if (LF) {\
      if (LF.downwash_deg && LF.downwash_deg.values) {\
        var dwAlphas = (LF.downwash_deg.axes || {}).alpha_deg || CFG.alphas;\
        var dwCfgs = (LF.downwash_deg.axes || {}).config || ["clean"];\
        var ds = [];\
        dwCfgs.forEach(function(cfg, ci) {\
          var arr = LF.downwash_deg.values[cfg]; if(!arr) return;\
          var pts = [];\
          dwAlphas.forEach(function(a, i) { if(i<arr.length) pts.push({x:a,y:arr[i]}); });\
          ds.push({ label: cfg, data: pts, borderColor: CFG.colors[ci % CFG.colors.length],\
                    backgroundColor: "transparent", showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 });\
        });\
        makeChart("chart_downwash", "Downwash \\u03b5 vs \\u03b1", "\\u03b1 (deg)", "\\u03b5 (deg)", ds);\
      }\
      if (LF.sidewash_deg && LF.sidewash_deg.values) {\
        var swBetas = (LF.sidewash_deg.axes || {}).beta_deg || CFG.betas;\
        var swCfgs = (LF.sidewash_deg.axes || {}).config || ["clean"];\
        var ds2 = [];\
        swCfgs.forEach(function(cfg, ci) {\
          var arr = LF.sidewash_deg.values[cfg]; if(!arr) return;\
          var pts = [];\
          swBetas.forEach(function(b, i) { if(i<arr.length) pts.push({x:b,y:arr[i]}); });\
          ds2.push({ label: cfg, data: pts, borderColor: CFG.colors[ci % CFG.colors.length],\
                     backgroundColor: "transparent", showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 });\
        });\
        makeChart("chart_sidewash", "Sidewash \\u03c3 vs \\u03b2", "\\u03b2 (deg)", "\\u03c3 (deg)", ds2);\
      }\
      if (LF.tail_dynamic_pressure_ratio && LF.tail_dynamic_pressure_ratio.values) {\
        var tdAlphas = (LF.tail_dynamic_pressure_ratio.axes || {}).alpha_deg || CFG.alphas;\
        var tdCfgs = (LF.tail_dynamic_pressure_ratio.axes || {}).config || ["clean"];\
        var ds3 = [];\
        tdCfgs.forEach(function(cfg, ci) {\
          var arr = LF.tail_dynamic_pressure_ratio.values[cfg]; if(!arr) return;\
          var pts = [];\
          tdAlphas.forEach(function(a, i) { if(i<arr.length) pts.push({x:a,y:arr[i]}); });\
          ds3.push({ label: cfg, data: pts, borderColor: CFG.colors[ci % CFG.colors.length],\
                     backgroundColor: "transparent", showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 });\
        });\
        makeChart("chart_tail_dpr", "Tail Dynamic Pressure Ratio vs \\u03b1", "\\u03b1 (deg)", "\\u03b7_t", ds3);\
      }\
    } else { console.warn("[Tab4] LF is null"); }\
  } catch(e) { console.error("[Tab4 LF] Error:", e); }\
\
  /* Post-stall parameters display */\
  try {\
    if (PS && PS.alpha_on_deg) {\
      var psHtml = \'<table class="deriv-table"><thead><tr><th>Parameter</th>\';\
      var psCfgs = Object.keys(PS.alpha_on_deg || {});\
      psCfgs.forEach(function(c) { psHtml += "<th>" + c + "</th>"; });\
      psHtml += "</tr></thead><tbody>";\
      var psParams = [\
        ["Model", function(c){ return PS.model || "--"; }],\
        ["\\u03b1 stall onset (deg)", function(c){ return PS.alpha_on_deg ? PS.alpha_on_deg[c] : "--"; }],\
        ["\\u03b1 stall off (deg)", function(c){ return PS.alpha_off_deg ? PS.alpha_off_deg[c] : "--"; }],\
        ["Sideforce scale", function(c){ return PS.sideforce_scale ? PS.sideforce_scale[c] : "--"; }],\
        ["Drag floor", function(c){ return PS.drag_floor ? PS.drag_floor[c] : "--"; }],\
        ["CD at 90\\u00b0", function(c){ return PS.drag_90deg ? PS.drag_90deg[c] : "--"; }]\
      ];\
      psParams.forEach(function(row) {\
        psHtml += "<tr><td>" + row[0] + "</td>";\
        psCfgs.forEach(function(c) { psHtml += "<td>" + row[1](c) + "</td>"; });\
        psHtml += "</tr>";\
      });\
      psHtml += "</tbody></table>";\
      document.getElementById("psContainer").innerHTML = psHtml;\
    } else { showNoData("psContainer", "No post-stall data. PS=" + JSON.stringify(PS)); }\
  } catch(e) { console.error("[Tab4 PS] Error:", e); }\
\
  /* ======== TAB 5: TAIL AERODYNAMICS ======== */\
  try {\
    if (TA) {\
      var taColors = ["#e94560", "#0f3460", "#00b4d8", "#e07000"];\
      /* HTP: CLh vs alpha */\
      if (TA.HTP && TA.HTP.CLh) {\
        var pts1 = TA.HTP.alphas_deg.map(function(a, i) { return {x: a, y: TA.HTP.CLh[i]}; });\
        makeChart("chart_CLh_alpha", "CLh vs \\u03b1 (HTP in isolation)", "\\u03b1 (deg)", "CLh",\
          [{ label: "CLh", data: pts1, borderColor: taColors[0], backgroundColor: "transparent",\
             showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 }]);\
      }\
      /* HTP: Cm due to HTP vs alpha */\
      if (TA.HTP && TA.HTP.Cm_due_to_HTP) {\
        var pts2 = TA.HTP.alphas_deg.map(function(a, i) { return {x: a, y: TA.HTP.Cm_due_to_HTP[i]}; });\
        makeChart("chart_Cm_HTP_alpha", "Cm due to HTP vs \\u03b1", "\\u03b1 (deg)", "Cm (HTP)",\
          [{ label: "Cm_HTP", data: pts2, borderColor: taColors[1], backgroundColor: "transparent",\
             showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 }]);\
      }\
      /* HTP: Elevator effectiveness */\
      /* HTP elevator effectiveness — always renders something so the\
         user can see the section exists. A clear placeholder is shown if\
         the aircraft input has no `elevator` control surface (the most\
         common reason these charts used to come up blank). */\
      function _plotElevator(canvasId, title, yLabel, data2D, lineColor) {\
        if (!TA.HTP || !data2D || !TA.HTP.delta_e_deg) {\
          replaceCanvasWithMessage(canvasId,\
            "No elevator control surface defined on the HTP. " +\
            "Add a `control_surfaces` entry with type=\\"elevator\\" " +\
            "to the horizontal stabilizer in the aircraft input to populate this chart.");\
          return;\
        }\
        /* dCLh_de / dCm_de may be 1D [delta] (legacy) or 2D [alpha][delta].\
           Pick the α≈0 slice when 2D. */\
        var slice = data2D;\
        if (Array.isArray(slice[0])) {\
          var a0 = 0; var alphas = TA.HTP.alphas_deg || [0];\
          for (var k = 0; k < alphas.length; k++) {\
            if (Math.abs(alphas[k]) < Math.abs(alphas[a0])) a0 = k;\
          }\
          slice = slice[a0] || [];\
        }\
        var pts = TA.HTP.delta_e_deg.map(function(d, i) {\
          return { x: d, y: (typeof slice[i] === "number") ? slice[i] : 0 };\
        });\
        makeChart(canvasId, title, "\\u03b4e (deg)", yLabel,\
          [{ label: yLabel, data: pts, borderColor: lineColor,\
             backgroundColor: "transparent",\
             showLine: true, pointRadius: 2, borderWidth: 2, tension: 0.3 }]);\
      }\
      _plotElevator("chart_dCDh_de",\
        "\\u0394CDh vs \\u03b4e (" + ((TA.HTP && TA.HTP.elevator_name) || "elevator") + ")",\
        "\\u0394CDh", TA.HTP && TA.HTP.dCDh_de, "#26c6da");\
      _plotElevator("chart_dCm_de",\
        "\\u0394Cm vs \\u03b4e (" + ((TA.HTP && TA.HTP.elevator_name) || "elevator") + ")",\
        "\\u0394Cm", TA.HTP && TA.HTP.dCm_de, "#ab47bc");\
      /* VTP: CYv vs beta */\
      if (TA.VTP && TA.VTP.CYv) {\
        var pts3 = TA.VTP.betas_deg.map(function(b, i) { return {x: b, y: TA.VTP.CYv[i]}; });\
        makeChart("chart_CYv_beta", "CYv vs \\u03b2 (VTP in isolation)", "\\u03b2 (deg)", "CYv",\
          [{ label: "CYv", data: pts3, borderColor: taColors[2], backgroundColor: "transparent",\
             showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 }]);\
      }\
      /* VTP: Cn due to VTP vs beta */\
      if (TA.VTP && TA.VTP.Cn_due_to_VTP) {\
        var pts4 = TA.VTP.betas_deg.map(function(b, i) { return {x: b, y: TA.VTP.Cn_due_to_VTP[i]}; });\
        makeChart("chart_Cn_VTP_beta", "Cn due to VTP vs \\u03b2", "\\u03b2 (deg)", "Cn (VTP)",\
          [{ label: "Cn_VTP", data: pts4, borderColor: taColors[3], backgroundColor: "transparent",\
             showLine: true, pointRadius: 3, borderWidth: 2, tension: 0.2 }]);\
      }\
      /* VTP rudder effectiveness — same placeholder-on-missing-data pattern\
         as the HTP elevator charts above. */\
      function _plotRudder(canvasId, title, yLabel, data1D, lineColor) {\
        if (!TA.VTP || !data1D || !TA.VTP.delta_r_deg) {\
          replaceCanvasWithMessage(canvasId,\
            "No rudder control surface defined on the VTP. " +\
            "Add a `control_surfaces` entry with type=\\"rudder\\" " +\
            "to the vertical stabilizer in the aircraft input to populate this chart.");\
          return;\
        }\
        var pts = TA.VTP.delta_r_deg.map(function(d, i) {\
          return { x: d, y: (typeof data1D[i] === "number") ? data1D[i] : 0 };\
        });\
        makeChart(canvasId, title, "\\u03b4r (deg)", yLabel,\
          [{ label: yLabel, data: pts, borderColor: lineColor,\
             backgroundColor: "transparent",\
             showLine: true, pointRadius: 2, borderWidth: 2, tension: 0.3 }]);\
      }\
      _plotRudder("chart_dCYv_dr",\
        "\\u0394CYv vs \\u03b4r (" + ((TA.VTP && TA.VTP.rudder_name) || "rudder") + ")",\
        "\\u0394CYv", TA.VTP && TA.VTP.dCYv_dr, "#66bb6a");\
      _plotRudder("chart_dCDv_dr",\
        "\\u0394CDv vs \\u03b4r (" + ((TA.VTP && TA.VTP.rudder_name) || "rudder") + ")",\
        "\\u0394CDv", TA.VTP && TA.VTP.dCDv_dr, "#ffa726");\
      /* Summary table */\
      var taHtml = \'<h3 style="margin:16px 0 8px;">Tail Aerodynamics Summary</h3>\';\
      taHtml += \'<table class="deriv-table"><thead><tr><th>Parameter</th><th>Value</th><th>Unit</th></tr></thead><tbody>\';\
      if (TA.HTP) {\
        taHtml += "<tr><td>CLh\\u03b1 (HTP lift-curve slope)</td><td>" + (TA.HTP.CLh_alpha_per_deg != null ? TA.HTP.CLh_alpha_per_deg.toFixed(4) : "--") + "</td><td>1/deg</td></tr>";\
        taHtml += "<tr><td>HTP \\u03b1 stall</td><td>" + (TA.HTP.alpha_stall_deg != null ? TA.HTP.alpha_stall_deg.toFixed(1) : "--") + "</td><td>deg</td></tr>";\
        taHtml += "<tr><td>CLh max (ref Sref)</td><td>" + (TA.HTP.CLh_max != null ? TA.HTP.CLh_max.toFixed(4) : "--") + "</td><td>--</td></tr>";\
        taHtml += "<tr><td>HTP area / Sref</td><td>" + (TA.HTP.area_ratio_to_sref != null ? TA.HTP.area_ratio_to_sref.toFixed(4) : "--") + "</td><td>--</td></tr>";\
        taHtml += "<tr><td>HTP moment arm / c\\u0304</td><td>" + (TA.HTP.moment_arm_over_cref != null ? TA.HTP.moment_arm_over_cref.toFixed(3) : "--") + "</td><td>--</td></tr>";\
        if (TA.HTP.elevator_tau != null) {\
          taHtml += "<tr><td>Elevator \\u03c4 (flap effectiveness)</td><td>" + TA.HTP.elevator_tau.toFixed(4) + "</td><td>--</td></tr>";\
          taHtml += "<tr><td>dCm/d\\u03b4e (linear)</td><td>" + (TA.HTP.dCm_de_per_deg != null ? TA.HTP.dCm_de_per_deg.toFixed(5) : "--") + "</td><td>1/deg</td></tr>";\
          taHtml += "<tr><td>dCDh/d|\\u03b4e| (near trim)</td><td>" + (TA.HTP.dCDh_de_per_deg != null ? TA.HTP.dCDh_de_per_deg.toFixed(5) : "--") + "</td><td>1/deg</td></tr>";\
        }\
      }\
      if (TA.VTP) {\
        taHtml += "<tr><td>CYv\\u03b2 (VTP side-force slope)</td><td>" + (TA.VTP.CYv_beta_per_deg != null ? TA.VTP.CYv_beta_per_deg.toFixed(4) : "--") + "</td><td>1/deg</td></tr>";\
        taHtml += "<tr><td>VTP \\u03b2 stall</td><td>" + (TA.VTP.beta_stall_deg != null ? TA.VTP.beta_stall_deg.toFixed(1) : "--") + "</td><td>deg</td></tr>";\
        taHtml += "<tr><td>CYv max (ref Sref)</td><td>" + (TA.VTP.CYv_max != null ? TA.VTP.CYv_max.toFixed(4) : "--") + "</td><td>--</td></tr>";\
        taHtml += "<tr><td>VTP area / Sref</td><td>" + (TA.VTP.area_ratio_to_sref != null ? TA.VTP.area_ratio_to_sref.toFixed(4) : "--") + "</td><td>--</td></tr>";\
        taHtml += "<tr><td>VTP moment arm / b</td><td>" + (TA.VTP.moment_arm_over_bref != null ? TA.VTP.moment_arm_over_bref.toFixed(3) : "--") + "</td><td>--</td></tr>";\
        if (TA.VTP.rudder_tau != null) {\
          taHtml += "<tr><td>Rudder \\u03c4 (flap effectiveness)</td><td>" + TA.VTP.rudder_tau.toFixed(4) + "</td><td>--</td></tr>";\
          taHtml += "<tr><td>dCYv/d\\u03b4r (linear)</td><td>" + (TA.VTP.dCYv_dr_per_deg != null ? TA.VTP.dCYv_dr_per_deg.toFixed(5) : "--") + "</td><td>1/deg</td></tr>";\
          taHtml += "<tr><td>dCDv/d|\\u03b4r| (near trim)</td><td>" + (TA.VTP.dCDv_dr_per_deg != null ? TA.VTP.dCDv_dr_per_deg.toFixed(5) : "--") + "</td><td>1/deg</td></tr>";\
        }\
      }\
      taHtml += "</tbody></table>";\
      document.getElementById("tailAeroSummary").innerHTML = taHtml;\
    } else {\
      showNoData("tailAeroSummary", "No tail aerodynamics data available.");\
    }\
  } catch(e) { console.error("[Tab5 TailAero] Error:", e); }\
\
  /* ======== TAB 6: CARPET PLOTS ======== */\
  try {\
    CFG.coeffNames.forEach(function(name) {\
      makeChart("chart_" + name + "_multibeta",\
        name + " vs \\u03b1 \\u2014 Wing+Body (multi-\\u03b2, M=" + CFG.machs[0].toFixed(2) + ")",\
        "\\u03b1 (deg)", name, extractMultiBeta(name));\
    });\
    CFG.coeffNames.forEach(function(name) {\
      makeChart("chart_" + name + "_multialpha",\
        name + " vs \\u03b2 \\u2014 Wing+Body (multi-\\u03b1, M=" + CFG.machs[0].toFixed(2) + ")",\
        "\\u03b2 (deg)", name, extractMultiAlpha(name));\
    });\
  } catch(e) { console.error("[Tab6 Carpet] Error:", e); }\
\
  /* ======== TOTAL AIRCRAFT TAB ======== */\
  try {\
    function interp1D(xArr, yArr, xTarget) {\
      if (!xArr || !yArr || xArr.length === 0) return 0;\
      if (xTarget <= xArr[0]) return yArr[0];\
      if (xTarget >= xArr[xArr.length-1]) return yArr[yArr.length-1];\
      for (var i = 0; i < xArr.length - 1; i++) {\
        if (xTarget >= xArr[i] && xTarget <= xArr[i+1]) {\
          var t = (xTarget - xArr[i]) / (xArr[i+1] - xArr[i]);\
          return yArr[i] + t * (yArr[i+1] - yArr[i]);\
        }\
      }\
      return yArr[yArr.length-1];\
    }\
    function tailCLh(alpha) {\
      if (TA && TA.HTP && TA.HTP.CLh) return interp1D(TA.HTP.alphas_deg, TA.HTP.CLh, alpha);\
      return 0;\
    }\
    function tailCmHTP(alpha) {\
      if (TA && TA.HTP && TA.HTP.Cm_due_to_HTP) return interp1D(TA.HTP.alphas_deg, TA.HTP.Cm_due_to_HTP, alpha);\
      return 0;\
    }\
    function tailCYv(beta) {\
      if (TA && TA.VTP && TA.VTP.CYv) return interp1D(TA.VTP.betas_deg, TA.VTP.CYv, beta);\
      return 0;\
    }\
    function tailCnVTP(beta) {\
      if (TA && TA.VTP && TA.VTP.Cn_due_to_VTP) return interp1D(TA.VTP.betas_deg, TA.VTP.Cn_due_to_VTP, beta);\
      return 0;\
    }\
    function extractTotalVsAlpha(coeffName, betaIdx) {\
      var data = COEFF[coeffName]; if (!data) return [];\
      var ds = [];\
      CFG.machs.forEach(function(mach, mi) {\
        var pts = [];\
        CFG.alphas.forEach(function(alpha, ai) {\
          var total = data[mi] && data[mi][ai] ? data[mi][ai][betaIdx] : null;\
          if (total === null || total === undefined) return;\
          pts.push({ x: alpha, y: total });\
        });\
        ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
                   borderColor: CFG.colors[mi % CFG.colors.length],\
                   backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                   pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                   borderWidth: 2, tension: 0.2 });\
      });\
      return ds;\
    }\
    function extractTotalVsBeta(coeffName, alphaIdx) {\
      var data = COEFF[coeffName]; if (!data) return [];\
      var ds = [];\
      CFG.machs.forEach(function(mach, mi) {\
        var pts = [];\
        CFG.betas.forEach(function(beta, bi) {\
          var total = data[mi] && data[mi][alphaIdx] ? data[mi][alphaIdx][bi] : null;\
          if (total === null || total === undefined) return;\
          pts.push({ x: beta, y: total });\
        });\
        ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
                   borderColor: CFG.colors[mi % CFG.colors.length],\
                   backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                   pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                   borderWidth: 2, tension: 0.2 });\
      });\
      return ds;\
    }\
    /* Longitudinal: CL, CD, Cm, L/D total */\
    ["CL", "CD", "Cm"].forEach(function(name) {\
      makeChart("chart_total_" + name + "_alpha",\
        name + " vs \\u03b1 \\u2014 Total Aircraft (\\u03b2=" + CFG.betas[CFG.beta0Idx].toFixed(1) + "\\u00b0)",\
        "\\u03b1 (deg)", name, extractTotalVsAlpha(name, CFG.beta0Idx));\
    });\
    /* L/D total */\
    var clT = COEFF["CL"], cdT = COEFF["CD"];\
    if (clT && cdT) {\
      var ldTDs = [];\
      CFG.machs.forEach(function(mach, mi) {\
        var pts = [];\
        CFG.alphas.forEach(function(alpha, ai) {\
          var clTotal = clT[mi] && clT[mi][ai] ? clT[mi][ai][CFG.beta0Idx] : null;\
          var cdTotal = cdT[mi] && cdT[mi][ai] ? cdT[mi][ai][CFG.beta0Idx] : null;\
          if (clTotal === null || cdTotal === null) return;\
          if (Math.abs(cdTotal) > 1e-6) pts.push({ x: alpha, y: clTotal / cdTotal });\
        });\
        ldTDs.push({ label: "M=" + mach.toFixed(2), data: pts,\
                     borderColor: CFG.colors[mi % CFG.colors.length],\
                     backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                     pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                     borderWidth: 2, tension: 0.2 });\
      });\
      makeChart("chart_total_LD_alpha",\
        "L/D vs \\u03b1 \\u2014 Total Aircraft (\\u03b2=" + CFG.betas[CFG.beta0Idx].toFixed(1) + "\\u00b0)",\
        "\\u03b1 (deg)", "L/D", ldTDs);\
    }\
    /* Lateral: CY, Cl, Cn total */\
    ["CY", "Cl", "Cn"].forEach(function(name) {\
      makeChart("chart_total_" + name + "_beta",\
        name + " vs \\u03b2 \\u2014 Total Aircraft (\\u03b1=" + CFG.alphas[CFG.alpha0Idx].toFixed(1) + "\\u00b0)",\
        "\\u03b2 (deg)", name, extractTotalVsBeta(name, CFG.alpha0Idx));\
    });\
    var totalDdNames = ["Cl_p_hat", "Cm_q_hat", "Cn_r_hat", "CL_q_hat", "CY_p_hat", "CY_r_hat", "Cm_alpha_dot_hat", "Cn_beta_dot_hat"];\
    if (DD && DD.axes) {\
      var totalDdAlphas = DD.axes.alpha_deg || [];\
      var totalDdMachs = DD.axes.mach || [];\
      var totalDdCfg = (DD.axes.config || ["clean"])[0];\
      totalDdNames.forEach(function(dname) {\
        var ds = [];\
        totalDdMachs.forEach(function(mach, mi) {\
          var pts = extract1D(DD, dname, totalDdCfg, mi, totalDdAlphas);\
          if (pts.length > 0) {\
            ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
                      borderColor: CFG.colors[mi % CFG.colors.length],\
                      backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                      borderWidth: 2, tension: 0.2 });\
          }\
        });\
        if (ds.length > 0) {\
          makeChart("chart_total_dd_" + dname, dname + " vs \\u03b1 \\u2014 Total Aircraft", "\\u03b1 (deg)", dname, ds);\
        } else {\
          replaceCanvasWithMessage("chart_total_dd_" + dname, "No data for " + dname + ".");\
        }\
      });\
    } else {\
      totalDdNames.forEach(function(dname) {\
        replaceCanvasWithMessage("chart_total_dd_" + dname, "No total-aircraft dynamic derivative data available.");\
      });\
    }\
    var totalControlNames = ["Cl_da_per_deg", "Cn_da_per_deg", "Cd_da_per_deg", "Cm_de_per_deg", "Cn_dr_per_deg", "Cl_dr_per_deg"];\
    if (CE && CE.axes) {\
      var totalCeAlphas = CE.axes.alpha_deg || [];\
      var totalCeMachs = CE.axes.mach || [];\
      var totalCeCfg = (CE.axes.config || ["clean"])[0];\
      totalControlNames.forEach(function(cname) {\
        var ds = [];\
        totalCeMachs.forEach(function(mach, mi) {\
          var pts = extract1D(CE, cname, totalCeCfg, mi, totalCeAlphas);\
          if (pts.length > 0) {\
            ds.push({ label: "M=" + mach.toFixed(2), data: pts,\
                      borderColor: CFG.colors[mi % CFG.colors.length],\
                      backgroundColor: "transparent", showLine: true, pointRadius: 3,\
                      pointStyle: POINT_STYLES[mi % POINT_STYLES.length],\
                      borderWidth: 2, tension: 0.2 });\
          }\
        });\
        if (ds.length > 0) {\
          makeChart("chart_total_ce_" + cname, cname + " vs \\u03b1 \\u2014 Total Aircraft", "\\u03b1 (deg)", cname, ds);\
        } else {\
          replaceCanvasWithMessage("chart_total_ce_" + cname, "No total-aircraft control-derivative data for " + cname + ".");\
        }\
      });\
    } else {\
      totalControlNames.forEach(function(cname) {\
        replaceCanvasWithMessage("chart_total_ce_" + cname, "No total-aircraft control-derivative data available.");\
      });\
    }\
  } catch(e) { console.error("[Total Aircraft] Error:", e); }\
\
  /* ======== TAB 6: TABLES ======== */\
  try {\
    var machSel = document.getElementById("tableMachSelect");\
    CFG.machs.forEach(function(m, i) {\
      var opt = document.createElement("option"); opt.value = i; opt.text = "M=" + m.toFixed(2);\
      machSel.appendChild(opt);\
    });\
    updateTable();\
  } catch(e) { console.error("[Tab6 Tables] Error:", e); }\
\
  /* ======== TAB 7: SUMMARY ======== */\
  try { buildSummary(); } catch(e) { console.error("[Tab7 Summary] Error:", e); }\
\
});\
\
function updateTable() {\
  var mi = parseInt(document.getElementById("tableMachSelect").value) || 0;\
  var coeff = document.getElementById("tableCoeffSelect").value || "CL";\
  var data = COEFF[coeff];\
  var container = document.getElementById("tableContainer");\
  if (!data || !data[mi]) { container.innerHTML = "<p>No data</p>"; return; }\
  var t = \'<table class="coeff-table"><thead><tr><th class="row-header">\\u03b1 \\\\ \\u03b2</th>\';\
  CFG.betas.forEach(function(b) { t += "<th>" + b.toFixed(1) + "\\u00b0</th>"; });\
  t += "</tr></thead><tbody>";\
  CFG.alphas.forEach(function(alpha, ai) {\
    t += \'<tr><td class="row-header">\' + alpha.toFixed(1) + "\\u00b0</td>";\
    CFG.betas.forEach(function(beta, bi) {\
      var val = data[mi][ai] ? data[mi][ai][bi] : null;\
      if (val === null || val === undefined) { t += "<td>--</td>"; return; }\
      var cls = val > 0.0001 ? "pos" : (val < -0.0001 ? "neg" : "zero");\
      t += \'<td class="\' + cls + \'">\' + val.toFixed(4) + "</td>";\
    });\
    t += "</tr>";\
  });\
  t += "</tbody></table>";\
  container.innerHTML = t;\
}\
\
function copyTableCSV() {\
  var mi = parseInt(document.getElementById("tableMachSelect").value) || 0;\
  var coeff = document.getElementById("tableCoeffSelect").value || "CL";\
  var data = COEFF[coeff];\
  if (!data || !data[mi]) return;\
  var csv = "Alpha\\\\Beta," + CFG.betas.map(function(b){return b.toFixed(1);}).join(",") + "\\n";\
  CFG.alphas.forEach(function(alpha, ai) {\
    csv += alpha.toFixed(1);\
    CFG.betas.forEach(function(beta, bi) {\
      var val = data[mi][ai] ? data[mi][ai][bi] : "";\
      csv += "," + (val !== null && val !== undefined ? val.toFixed(6) : "");\
    });\
    csv += "\\n";\
  });\
  navigator.clipboard.writeText(csv).then(function() { alert("Copied to clipboard"); });\
}\
\
function buildSummary() {\
  var html = "";\
  var cl0 = null, cd0 = null, cm0 = null, ldMax = null, ldAlpha = null;\
  var clData = COEFF["CL"], cdData = COEFF["CD"], cmData = COEFF["Cm"];\
  if (clData && clData[0] && clData[0][CFG.alpha0Idx]) cl0 = clData[0][CFG.alpha0Idx][CFG.beta0Idx];\
  if (cdData && cdData[0] && cdData[0][CFG.alpha0Idx]) cd0 = cdData[0][CFG.alpha0Idx][CFG.beta0Idx];\
  if (cmData && cmData[0] && cmData[0][CFG.alpha0Idx]) cm0 = cmData[0][CFG.alpha0Idx][CFG.beta0Idx];\
  if (clData && cdData && clData[0]) {\
    var maxLD = -Infinity;\
    CFG.alphas.forEach(function(a, ai) {\
      if (!clData[0][ai] || !cdData[0][ai]) return;\
      var cl = clData[0][ai][CFG.beta0Idx];\
      var cd = cdData[0][ai][CFG.beta0Idx];\
      if (cd > 1e-6) { var ld = cl / cd; if (ld > maxLD) { maxLD = ld; ldAlpha = a; } }\
    });\
    if (maxLD > -Infinity) ldMax = maxLD;\
  }\
  var clMax = null, clMaxAlpha = null;\
  if (clData && clData[0]) {\
    var maxCL = -Infinity;\
    CFG.alphas.forEach(function(a, ai) {\
      if (!clData[0][ai]) return;\
      var cl = clData[0][ai][CFG.beta0Idx];\
      if (cl > maxCL) { maxCL = cl; clMaxAlpha = a; }\
    });\
    if (maxCL > -Infinity) clMax = maxCL;\
  }\
  html += "<h2>Wing+Body \\u2014 Key Aerodynamic Parameters (M=" + CFG.machs[0].toFixed(2) + ", \\u03b2=0\\u00b0)</h2>";\
  html += \'<div class="summary-grid">\';\
  var cards = [\
    ["CL\\u2080", cl0 !== null ? cl0.toFixed(4) : "--", ""],\
    ["CD\\u2080", cd0 !== null ? cd0.toFixed(5) : "--", ""],\
    ["Cm\\u2080", cm0 !== null ? cm0.toFixed(4) : "--", ""],\
    ["CL max", clMax !== null ? clMax.toFixed(3) : "--", clMaxAlpha !== null ? "at \\u03b1=" + clMaxAlpha.toFixed(1) + "\\u00b0" : ""],\
    ["(L/D) max", ldMax !== null ? ldMax.toFixed(1) : "--", ldAlpha !== null ? "at \\u03b1=" + ldAlpha.toFixed(1) + "\\u00b0" : ""],\
    ["Grid Size", CFG.alphas.length + " \\u00d7 " + CFG.betas.length, "\\u03b1 \\u00d7 \\u03b2 points"]\
  ];\
  cards.forEach(function(c) {\
    html += \'<div class="summary-card"><h4>\' + c[0] + "</h4>";\
    html += \'<span class="value">\' + c[1] + "</span>";\
    if (c[2]) html += \'<span class="unit">\' + c[2] + "</span>";\
    html += "</div>";\
  });\
  html += "</div>";\
  if (PS && PS.alpha_on_deg) {\
    html += "<h2>Post-Stall Parameters</h2>";\
    var cfg0 = Object.keys(PS.alpha_on_deg)[0] || "clean";\
    html += \'<div class="summary-grid">\';\
    html += \'<div class="summary-card"><h4>Stall Onset</h4><span class="value">\' + (PS.alpha_on_deg[cfg0] || "--") + \'</span><span class="unit">deg</span></div>\';\
    html += \'<div class="summary-card"><h4>Stall Recovery</h4><span class="value">\' + (PS.alpha_off_deg[cfg0] || "--") + \'</span><span class="unit">deg</span></div>\';\
    html += \'<div class="summary-card"><h4>CD at 90\\u00b0</h4><span class="value">\' + (PS.drag_90deg[cfg0] || "--") + \'</span><span class="unit"></span></div>\';\
    html += "</div>";\
  }\
  if (DD && DD.axes) {\
    var ddAlphas2 = DD.axes.alpha_deg || [];\
    var ddCfg2 = (DD.axes.config || ["clean"])[0];\
    var a0i = 0; ddAlphas2.forEach(function(a,i){ if(Math.abs(a)<Math.abs(ddAlphas2[a0i])) a0i=i; });\
    var ddKeys2 = Object.keys(DD).filter(function(k){ return k!=="axis_order"&&k!=="axes"; });\
    html += "<h2>Wing+Body \\u2014 Stability Derivatives at \\u03b1 \\u2248 0\\u00b0</h2>";\
    html += \'<div class="summary-grid">\';\
    ddKeys2.forEach(function(n) {\
      var pts = extract1D(DD, n, ddCfg2, 0, ddAlphas2);\
      var val = a0i < pts.length ? pts[a0i].y : null;\
      html += \'<div class="summary-card"><h4>\' + n + "</h4>";\
      html += \'<span class="value">\' + (val !== null ? val.toFixed(4) : "--") + "</span></div>";\
    });\
    html += "</div>";\
  }\
  if (CE && CE.axes) {\
    var ceAlphas2 = CE.axes.alpha_deg || [];\
    var ceCfg2 = (CE.axes.config || ["clean"])[0];\
    var ca0i = 0; ceAlphas2.forEach(function(a,i){ if(Math.abs(a)<Math.abs(ceAlphas2[ca0i])) ca0i=i; });\
    var ceKeys2 = Object.keys(CE).filter(function(k){ return k!=="axis_order"&&k!=="axes"; });\
    html += "<h2>Wing+Body \\u2014 Control Effectiveness at \\u03b1 \\u2248 0\\u00b0</h2>";\
    html += \'<div class="summary-grid">\';\
    ceKeys2.forEach(function(n) {\
      var pts = extract1D(CE, n, ceCfg2, 0, ceAlphas2);\
      var val = ca0i < pts.length ? pts[ca0i].y : null;\
      html += \'<div class="summary-card"><h4>\' + n + "</h4>";\
      html += \'<span class="value">\' + (val !== null ? val.toFixed(5) : "--") + \'</span><span class="unit">per deg</span></div>\';\
    });\
    html += "</div>";\
  }\
  document.getElementById("summaryContainer").innerHTML = html;\
}\
';
}
