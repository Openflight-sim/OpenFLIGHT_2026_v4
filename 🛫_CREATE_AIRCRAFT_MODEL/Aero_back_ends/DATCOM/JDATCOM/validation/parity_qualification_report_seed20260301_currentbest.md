# Parity Qualification Report

- Generated at: 2026-02-26T21:02:25.781
- Target relative tolerance: 0.5%
- Overall gate pass: false

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 26 | 0 | 44 | 100.0% |
| generated | 1 | 6 | 1 | 5 | 6 | 16.67% |
| combined | 6 | 32 | 27 | 5 | 50 | 84.38% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | false | 5 | 0 |
| comparable_volume | true | 32 | 20 |
| body_only_cases | true | 17 | > 0 |
| wing_only_cases | true | 16 | > 0 |
| full_config_cases | true | 18 | > 0 |
| canard_cases | true | 6 | > 0 |
| wing_type_1 | true | 37 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 71 | > 0 |
| transonic_regime | true | 31 | > 0 |
| supersonic_regime | true | 81 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 17 |
| canard_cases | 6 |
| cases_total | 57 |
| expr_cases | 5 |
| full_config_cases | 18 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 6 |
| mach_points_total | 183 |
| subsonic_regime | 71 |
| supersonic_regime | 81 |
| transonic_regime | 31 |
| wing_only_cases | 16 |
| wing_type_1 | 37 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| legacy component buildup block not selected for full-configuration parity | 31 |
| insufficient finite legacy reference points for parity (need >= 4) | 19 |

## Generated Inputs

- JDATCOM\validation\cases\qualification\generated_seed_20260301.inp

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 4 | 0.4 | 5.0% | 0.0% | 2.273% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 6 | 0.4 | 4.348% | 0.0% | 2.5% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 2.0% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.058% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 1.0% |
