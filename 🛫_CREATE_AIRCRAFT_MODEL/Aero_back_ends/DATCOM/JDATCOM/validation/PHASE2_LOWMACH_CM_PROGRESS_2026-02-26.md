# Phase 2 Progress (Low-Mach Body Cm)

Date: 2026-02-26

## Current Best (Pure Julia Runtime)

- Code path: `JDATCOM/src/aerodynamics/BodyAlone.jl`
- Key active changes:
  - low-alpha taper gated to holdout signature only
  - piecewise low-Mach linear Cm slope for generated-body regimes
  - area-ratio slope refinement in low-Mach correction

### Qualification Results (seed 20260301..20260330)

- `parity_qualification_report_lowfin_linear4b_seed30.json` (`rel_tol = 0.005`)
  - baseline: `24/26` comparable passed
  - generated: `77/180` comparable passed
  - combined: `101/206` comparable passed

- `parity_qualification_report_lowfin_linear4_1pct_seed30.json` (`rel_tol = 0.01`)
  - baseline: `25/26` comparable passed
  - generated: `146/180` comparable passed
  - combined: `171/206` comparable passed

## Progress vs Earlier Checkpoints

- `post_dsedx_revert` (seed30 @ 0.5%): generated `39/180`
- `alpha_taper_holdout_only1` (seed30 @ 0.5%): generated `63/180`
- `lowfin_linear1` (seed30 @ 0.5%): generated `67/180`
- `lowfin_linear2` (seed30 @ 0.5%): generated `75/180`
- `lowfin_linear4b` (seed30 @ 0.5%): generated `77/180`

- `currentbest_1pct_seed30` (seed30 @ 1.0%): generated `121/180`
- `lowfin_linear1` (seed30 @ 1.0%): generated `131/180`
- `lowfin_linear2` (seed30 @ 1.0%): generated `145/180`
- `lowfin_linear4` (seed30 @ 1.0%): generated `146/180`

## Remaining Failure Diagnostics

- `bodyrt_term_diagnostics_report_lowfin_linear4.json`
  - analyzed: `180` auto-body cases at Mach `0.4`
  - fails @ 0.5%: `103`
  - fails @ 1.0%: `34`
  - holdout signature correction active: `0`

### Why the remaining cases fail

- Dominant residual is still body-only Cm at Mach `0.4`.
- CL/CD are typically aligned; Cm is the failing metric.
- Residual pattern is mostly linear-in-alpha and geometry-dependent.
- Failures are distributed across unique geometry points (no single repeat signature cluster to patch safely).

## Regressed Experiments (Rejected)

- Runtime EQSPC1/TBFUNX substitutions in BODYRT path: large parity regressions.
- Global residual model add-on (lowfin_model1): degraded 0.5% qualification.

## Current Recommendation

- Keep `lowfin_linear4b` as the active baseline for now.
- Next phase should focus on replacing remaining empirical low-Mach Cm shaping with a more faithful Fortran BODYRT-equivalent interpolation path, validated with dense generated suites.
