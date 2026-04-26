# Release Baseline Artifacts

This folder freezes the canonical parity baseline used for regression detection.

## Included Reports

- `parity_qualification_report_1pct_seed30.json`
- `parity_qualification_report_1pct_seed30.md`
- `parity_qualification_report_05pct_seed30.json`
- `parity_qualification_report_05pct_seed30.md`
- `bodyrt_term_diagnostics_report_mach04_seed30.json`
- `bodyrt_term_diagnostics_report_mach04_seed30.md`
- `BASELINE_MANIFEST.json`

## How It Is Used

1. CI runs a new `1.0%` qualification report.
2. `JDATCOM/validation/check_frozen_baseline.jl` compares the current report against this baseline.
3. CI fails on any baseline regression in the configured scope.
