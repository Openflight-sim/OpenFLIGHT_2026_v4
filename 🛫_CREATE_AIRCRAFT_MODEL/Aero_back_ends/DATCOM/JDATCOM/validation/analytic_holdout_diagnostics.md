# Analytic Holdout Diagnostics (No Oracle)

Input:

- `JDATCOM/validation/cases/holdout_suite.inp` (seed `20260225`)
- run mode: `--no-oracle`

Summary from `analytic_holdout_report.md`:

- Comparable blocks: `6`
- Passed: `0`
- Failed: `6`
- Skipped: `6` (legacy had no finite reference points)

Observed failure pattern:

- All comparable failures are body-only blocks at `M=0.4`.
- Post-fix residual max relative errors:
  - `CL`: up to `2.495%`
  - `CD`: up to `7.777%`
  - `Cm`: up to `1.011%` (improved from ~`5.83%` after low-Mach/fineness correction)

Why this is failing:

1. Printed-reference quantization limit:
   - Legacy values in `datcom.out` are quantized (typically 3 decimals).
   - Current comparator threshold is `0.5%` with floors:
     - `CL`: `0.02` -> absolute budget `1e-4`
     - `CD`: `0.002` -> absolute budget `1e-5`
     - `Cm`: `0.01` -> absolute budget `5e-5`
   - Quantization alone can introduce several `1e-4` absolute error, which maps to `>0.5%` on these floors.

2. Residual low-Mach drag/lift bias:
   - Even after the low-Mach correction, analytic `CD0` at `M=0.4` is still slightly high vs legacy in holdout cases.
   - `CL` differences are small in absolute terms (typically `3e-4` to `5e-4`) but exceed the `0.5%` criterion due the low comparator floor.

3. Skipped blocks are not comparable:
   - Legacy returns non-finite outputs (`NDM`/null-equivalent) for half the holdout blocks, so those blocks are excluded from numeric parity.

Next phase targets:

- Add DATCOM print-precision-aware comparator mode for strict reportability vs printed references.
- Continue translating low-speed body drag/lift internals to reduce remaining `CD0` and `CL` bias at `M<0.5`.
- Add a curated holdout deck constrained to comparable finite legacy outputs for wing/full configurations.
