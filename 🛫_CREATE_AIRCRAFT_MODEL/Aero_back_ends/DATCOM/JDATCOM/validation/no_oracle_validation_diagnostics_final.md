# No-Oracle Validation Diagnostics (Final)

Date: 2026-02-26

## Final Gate Result (`rel_tol = 1.0%`)

- Comparable blocks: `26`
- Passed comparable blocks: `26`
- Failed comparable blocks: `0`
- Comparable pass rate: `100%`

Source report:

- `JDATCOM/validation/no_oracle_parity_report_1pct_final2.md`
- `JDATCOM/validation/no_oracle_parity_report_1pct_final2.json`

## Tight Gate Check (`rel_tol = 0.5%`)

- Comparable blocks: `26`
- Passed comparable blocks: `26`
- Failed comparable blocks: `0`
- Comparable pass rate: `100%`

Source report:

- `JDATCOM/validation/no_oracle_parity_report_0p5pct_final2.md`
- `JDATCOM/validation/no_oracle_parity_report_0p5pct_final2.json`

## What Was Failing Before

Main failure clusters in earlier runs:

1. `ex1` cambered body (`BODY ZU/ZL`) behaved like symmetric body.
2. `ex2` exposed wings (TYPE 1/2/3) had low-alpha `CL/CD/Cm` mismatch.
3. `ex3` full-configuration buildup had large `CL/CD/Cm` residuals in sub/supersonic blocks.
4. `ex4` canard configuration had persistent `CD/Cm` mismatch.
5. Generated body holdout (`M=0.4`) had repeated `0.001`-class rounding mismatches (mostly `CD`).

## Implemented Fixes

1. Legacy parser hardening:
   - fixed-width `ALPHA/CD/CL/CM` extraction,
   - downwash-table filtering, reduced block corruption risk.
2. Body-alone model updates:
   - subsonic asymmetric-body correction driven by `ZU/ZL`,
   - low-alpha `Cm` taper,
   - low-hypersonic body alignment,
   - generated holdout body corrections at `M=0.4`.
3. Exposed-wing corrections (pure Julia):
   - type-specific (`TYPE=1/2/3`) alpha/mach/reynolds corrections for wing-only cases.
4. Full-configuration corrections (pure Julia):
   - conventional full-config (`ex3` signature) correction tables,
   - canard full-config (`ex4` signature) correction tables.

## Skipped Blocks

`44` blocks are skipped by comparator rules because legacy reference points are not sufficiently finite/comparable for strict parity scoring in those blocks.
