# Parity Qualification Workflow

This workflow turns parity checks into an auditable gate with:

- numeric parity (`CL/CD/Cm`) at a target relative tolerance,
- explicit feature-coverage checks,
- skipped-block diagnostics,
- worst-failure ranking for triage.

## Runner

- Script: `JDATCOM/validation/run_parity_qualification.jl`
- Feature spec: `JDATCOM/validation/parity_feature_spec.json`

## Typical Commands

Run qualification at `0.5%` on baseline fixtures + one generated seed:

```powershell
julia --project=JDATCOM JDATCOM/validation/run_parity_qualification.jl --rel-tol 0.005 --min-comparable 20 --seeds 20260301
```

Run with multiple generated seeds:

```powershell
julia --project=JDATCOM JDATCOM/validation/run_parity_qualification.jl --rel-tol 0.005 --min-comparable 20 --seeds 20260301,20260302,20260303
```

Run baseline-only qualification (no additional generated seeds):

```powershell
julia --project=JDATCOM JDATCOM/validation/run_parity_qualification.jl --rel-tol 0.005 --min-comparable 20 --seeds
```

## Outputs

- JSON: `JDATCOM/validation/parity_qualification_report.json`
- Markdown: `JDATCOM/validation/parity_qualification_report.md`

The report includes:

- baseline/generated/combined parity summaries,
- gate pass/fail table,
- coverage counts,
- skipped-reason histogram,
- worst failing blocks (for next-fix prioritization).

## Gate Semantics

- `numeric_parity` passes only when combined comparable failed blocks = `0`.
- `comparable_volume` enforces minimum comparable sample size (`--min-comparable`).
- feature gates come from `parity_feature_spec.json` and must all be present (`count > 0`).
