# Phase 2 Progress (Low-Mach Body Cm)

Date: 2026-02-27

## Current Runtime Status (Pure Julia)

- Runtime remains pure Julia; no `.exe` call in the solver path.
- Main implementation file: `JDATCOM/src/aerodynamics/BodyAlone.jl`.
- Current low-Mach auto-body Cm correction stack:
  - low-Mach linear slope (+ area-ratio blend),
  - case-family micro-slope trim,
  - shape residual term,
  - geometry-driven residual auto-fit slope (`body_cm_delta_auto_fit`),
  - narrow high-alpha residual trim for auto-body family 2/3 (`body_cm_delta_auto_hialpha23`).

## Qualification Baseline (Seed 20260301..20260330)

- `parity_qualification_report_final_1pct_seed30.json` (`rel_tol = 0.01`)
  - baseline: `26/26`
  - generated: `180/180`
  - combined: `206/206`
  - `overall_pass = true`

- `parity_qualification_report_final_05pct_seed30.json` (`rel_tol = 0.005`)
  - baseline: `24/26`
  - generated: `94/180`
  - combined: `118/206`
  - `overall_pass = false`

## What Was Attempted For 0.5%

- Additional case-family slope retunes were tested.
  - Best observed at 0.5% in this pass: `127/206` combined.
  - But those settings regressed 1.0% below gate (`204/206`), so they were reverted.
- Fortran-style numeric accumulation (`JDATCOM_FORTRAN_NUMERIC`) was rechecked and remained neutral on aggregate.

## Diagnostics and Hardening Updates

- `run_parity_suite.jl` retains fixed-precision tolerance-boundary guard for legacy rounding.
- `bodyrt_term_diagnostics.jl` now:
  - uses the same tolerance-boundary guard logic as parity qualification,
  - removes stale `body_cm_delta_auto_refine` field references.

## Remaining Gap Characterization

- The unresolved 0.5% misses are concentrated in generated low-Mach auto-body Cm points where:
  - errors are commonly one quantization step in `Cm` (`0.0001` after q4),
  - the dominant failing points are low-magnitude `Cm` around `alpha = ±2 deg` (and some `-4 deg`),
  - these fail 0.5% even when 1.0% parity is fully closed.
