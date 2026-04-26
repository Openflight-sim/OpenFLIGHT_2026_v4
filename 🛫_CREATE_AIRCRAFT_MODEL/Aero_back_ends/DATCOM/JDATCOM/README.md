# JDATCOM

Pure Julia implementation of the DATCOM workflow used in this workspace.

This README is the main technical entry point for users and maintainers.

## 1. What This Project Is

`JDATCOM` is a Julia port of the DATCOM analysis flow previously handled through Python wrappers and legacy tooling.

Core objective:

- run aerodynamic analysis from DATCOM-style input decks using Julia code as the runtime solver;
- validate parity against legacy DATCOM outputs;
- provide a reproducible qualification process for releases.

## 2. What "Pure Julia" Means Here

The aerodynamic runtime path is pure Julia:

- parsing;
- state building;
- geometry derivation;
- aerodynamic coefficient evaluation.

Legacy DATCOM executable usage is restricted to validation/parity scripts only.

## 3. Current Qualification Status

Release baseline date: `2026-02-27`.

Canonical gate result:

- `1.0%` tolerance, full 30-seed qualification:
  - combined comparable blocks: `206/206` passed.

Strict quality track:

- `0.5%` tolerance, full 30-seed qualification:
  - combined comparable blocks: `118/206` passed.
  - remaining misses are concentrated in low-Mach auto-body `Cm` quantization-scale residuals.

Frozen baseline artifacts:

- `JDATCOM/validation/release_baseline/`

## 4. Project Structure

Top-level project folders:

- `JDATCOM/src/`:
  - `io/`: parser + state manager.
  - `geometry/`: body/wing/tail geometry routines.
  - `aerodynamics/`: coefficient models and calculator.
  - `legacy/`: legacy DATCOM execution/parsing helpers for validation.
  - `utils/`: interpolation, constants, atmosphere, table utilities.
- `JDATCOM/bin/jdatcom.jl`: CLI entry point.
- `JDATCOM/docs/user_manual.html`: end-user manual.
- `JDATCOM/validation/`: parity suites, diagnostics, qualification orchestration, baseline checks.
- `JDATCOM/data/reference_oracle.json`: optional local reference cache used by analytic mode unless disabled.

## 5. Runtime Data Flow

Typical run flow:

1. Parse DATCOM input deck (`.inp`) into case dictionaries.
2. Convert namelist data into normalized state dictionaries.
3. Compute derived geometry properties.
4. Build flight condition combinations (Mach/alt/Reynolds).
5. Evaluate aerodynamic coefficients per alpha point.
6. Emit structured JSON report.

Main solver API entry:

- `AerodynamicCalculator` + `calculate_at_condition`.

## 6. CLI Reference

CLI script:

- `JDATCOM/bin/jdatcom.jl`

Usage:

```text
jdatcom.jl parse <input.inp> [-v|--verbose] [--state]
jdatcom.jl run <input.inp> [-o <output.json>] [--backend legacy|analytic] [--no-oracle]
jdatcom.jl convert <input.inp> -f <yaml|json> [-o <output>]
```

### 6.1 Parse

```powershell
julia --project=JDATCOM JDATCOM/bin/jdatcom.jl parse tests/fixtures/ex1.inp --state
```

Use this to inspect case IDs, namelists, and normalized state keys.

### 6.2 Run (analytic, default)

```powershell
julia --project=JDATCOM JDATCOM/bin/jdatcom.jl run tests/fixtures/ex1.inp -o JDATCOM/validation/ex1.jdatcom.json
```

### 6.3 Run (analytic, oracle disabled)

```powershell
julia --project=JDATCOM JDATCOM/bin/jdatcom.jl run tests/fixtures/ex1.inp --no-oracle -o JDATCOM/validation/ex1.no_oracle.json
```

### 6.4 Run (legacy backend, validation use)

```powershell
julia --project=JDATCOM JDATCOM/bin/jdatcom.jl run tests/fixtures/ex1.inp --backend legacy -o JDATCOM/validation/ex1.legacy.json
```

Legacy backend requires a DATCOM executable. Resolution order includes:

- environment variable `JDATCOM_DATCOM_EXE`;
- local `datcom-legacy/datcom.exe` (or `datcom-legacy/datcom`).

### 6.5 Convert

```powershell
julia --project=JDATCOM JDATCOM/bin/jdatcom.jl convert tests/fixtures/ex2.inp -f json -o JDATCOM/validation/ex2.state.json
```

## 7. Install and Environment Setup

From repository root:

```powershell
julia --project=JDATCOM -e "using Pkg; Pkg.instantiate()"
```

Optional precompile:

```powershell
julia --project=JDATCOM -e "using JDATCOM"
```

## 8. Validation Strategy

Validation is split into:

1. release-gate qualification (`1.0%`, blocking);
2. strict trend tracking (`0.5%`, non-blocking);
3. targeted diagnostics for remaining gaps.

Primary validation guide:

- `JDATCOM/validation/README.md`

## 9. Release Validation Runbook

### 9.1 One-command bundle (recommended)

```powershell
julia --project=JDATCOM JDATCOM/validation/run_release_validation.jl
```

Default behavior:

- full 30-seed qualification at `1.0%`;
- 5-seed smoke qualification at `0.5%`;
- summary generation in `JDATCOM/validation/release_current/`.

Outputs:

- `parity_qualification_report_1pct_seed30.json`
- `parity_qualification_report_1pct_seed30.md`
- `parity_qualification_report_05pct_smoke_seed5.json`
- `parity_qualification_report_05pct_smoke_seed5.md`
- `release_validation_summary.md`

### 9.2 Full qualification command (manual)

```powershell
$seeds = (20260301..20260330) -join ','
julia --project=JDATCOM JDATCOM/validation/run_parity_qualification.jl --seeds $seeds --rel-tol 0.01 --json JDATCOM/validation/parity_qualification_report_manual_1pct_seed30.json --md JDATCOM/validation/parity_qualification_report_manual_1pct_seed30.md
```

### 9.3 Baseline regression check

```powershell
julia --project=JDATCOM JDATCOM/validation/check_frozen_baseline.jl --current JDATCOM/validation/parity_qualification_report_manual_1pct_seed30.json --baseline JDATCOM/validation/release_baseline/parity_qualification_report_1pct_seed30.json --scope combined
```

## 10. CI Gate Definition

Workflow file:

- `.github/workflows/jdatcom-parity.yml`

CI jobs:

1. `1.0% Qualification Gate` (blocking):
  - runs full seed range;
  - enforces report quality and frozen baseline non-regression.
2. `0.5% Smoke Trend` (non-blocking):
  - runs shorter strict test;
  - publishes summary and artifacts for tracking.

## 11. Documentation Set

- Main technical overview:
  - `JDATCOM/README.md` (this file).
- End-user HTML manual:
  - `JDATCOM/docs/user_manual.html`.
- Validation user guide:
  - `JDATCOM/validation/README.md`.
- Baseline manifest:
  - `JDATCOM/validation/release_baseline/BASELINE_MANIFEST.json`.

## 12. Notes on Oracle Usage

Analytic backend behavior:

- default: if a matching case exists in `reference_oracle.json`, the CLI can serve from oracle data;
- `--no-oracle`: forces analytic Julia model path.

For parity qualification scripts used as release gates, the process runs with oracle disabled to validate the pure analytic model against legacy outputs.

## 13. Known Limitations

- `0.5%` full parity is not yet closed.
- Most residual misses are in generated low-Mach body-alone `Cm` blocks near low absolute magnitude values where q4 quantization is dominant.

These do not break the current release gate (`1.0%`) but remain an active improvement target.

## 14. Troubleshooting

### 14.1 "Could not locate DATCOM executable"

Set:

```powershell
$env:JDATCOM_DATCOM_EXE = "C:\\path\\to\\datcom.exe"
```

### 14.2 Floating-point underflow notes during validation

These notes can appear during parity/legacy-compatible paths and are expected in this workflow unless accompanied by run failure.

### 14.3 No output report generated

Check:

- input file exists;
- `--project=JDATCOM` is used;
- output directory is writable.

## 15. Preparing the Standalone GitHub Repository

When extracting `JDATCOM` into its own repository:

1. keep the current docs set (`README`, `docs/user_manual.html`, `validation/README.md`);
2. keep `validation/release_baseline` and `BASELINE_MANIFEST.json`;
3. keep `.github/workflows/jdatcom-parity.yml`;
4. preserve seed ranges and tolerance policies to maintain continuity of historical parity metrics.

This ensures new contributors can clone, run, and verify parity immediately.
