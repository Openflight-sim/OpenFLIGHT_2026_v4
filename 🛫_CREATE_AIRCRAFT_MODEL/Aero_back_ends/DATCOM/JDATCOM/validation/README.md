# JDATCOM Validation User Guide

This folder contains scripts and artifacts to reproduce and track parity between the pure Julia runtime and legacy DATCOM reference behavior.

## Validation Goals

1. Keep the `1.0%` qualification gate fully passing (release gate).
2. Track `0.5%` parity as a strict, non-blocking quality metric.

## Canonical Baseline (Frozen)

Frozen release baseline artifacts are committed in:

- `JDATCOM/validation/release_baseline/`

Key files:

- `parity_qualification_report_1pct_seed30.json`
- `parity_qualification_report_05pct_seed30.json`
- `bodyrt_term_diagnostics_report_mach04_seed30.json`
- `BASELINE_MANIFEST.json`

These are the comparison anchor for regression checks.

## One-Command Reproduction

Run the release validation bundle:

```powershell
julia --project=JDATCOM JDATCOM/validation/run_release_validation.jl
```

Outputs:

- `JDATCOM/validation/release_current/parity_qualification_report_1pct_seed30.json`
- `JDATCOM/validation/release_current/parity_qualification_report_05pct_smoke_seed5.json`
- `JDATCOM/validation/release_current/release_validation_summary.md`

## Manual Reproduction Commands

### Full qualification gate (blocking)

```powershell
$seeds = (20260301..20260330) -join ','
julia --project=JDATCOM JDATCOM/validation/run_parity_qualification.jl --seeds $seeds --rel-tol 0.01 --json JDATCOM/validation/parity_qualification_report_manual_1pct_seed30.json --md JDATCOM/validation/parity_qualification_report_manual_1pct_seed30.md
```

### 0.5% smoke trend (non-blocking)

```powershell
$seeds = (20260301..20260305) -join ','
julia --project=JDATCOM JDATCOM/validation/run_parity_qualification.jl --seeds $seeds --rel-tol 0.005 --json JDATCOM/validation/parity_qualification_report_manual_05pct_smoke_seed5.json --md JDATCOM/validation/parity_qualification_report_manual_05pct_smoke_seed5.md
```

## Frozen Baseline Check

Compare a new `1.0%` report against the frozen baseline:

```powershell
julia --project=JDATCOM JDATCOM/validation/check_frozen_baseline.jl --current JDATCOM/validation/parity_qualification_report_manual_1pct_seed30.json --baseline JDATCOM/validation/release_baseline/parity_qualification_report_1pct_seed30.json --scope combined
```

Expected behavior:

- exits `0` when no regression is detected;
- exits non-zero when gate quality drops below baseline.

## CI Workflow

Workflow file:

- `.github/workflows/jdatcom-parity.yml`

CI behavior:

1. Run full `1.0%` gate on 30 seeds (blocking).
2. Compare the generated report against frozen baseline (blocking).
3. Run `0.5%` smoke on 5 seeds (non-blocking; summary + artifacts).
