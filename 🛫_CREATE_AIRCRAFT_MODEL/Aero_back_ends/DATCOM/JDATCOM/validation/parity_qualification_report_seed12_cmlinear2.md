# Parity Qualification Report

- Generated at: 2026-02-26T21:05:40.918
- Target relative tolerance: 0.5%
- Overall gate pass: false

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 26 | 0 | 44 | 100.0% |
| generated | 2 | 12 | 3 | 9 | 12 | 25.0% |
| combined | 7 | 38 | 29 | 9 | 56 | 76.32% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | false | 9 | 0 |
| comparable_volume | true | 38 | 20 |
| body_only_cases | true | 23 | > 0 |
| wing_only_cases | true | 22 | > 0 |
| full_config_cases | true | 24 | > 0 |
| canard_cases | true | 8 | > 0 |
| wing_type_1 | true | 51 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 97 | > 0 |
| transonic_regime | true | 45 | > 0 |
| supersonic_regime | true | 109 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 23 |
| canard_cases | 8 |
| cases_total | 77 |
| expr_cases | 5 |
| full_config_cases | 24 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 7 |
| mach_points_total | 251 |
| subsonic_regime | 97 |
| supersonic_regime | 109 |
| transonic_regime | 45 |
| wing_only_cases | 22 |
| wing_type_1 | 51 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| legacy component buildup block not selected for full-configuration parity | 31 |
| insufficient finite legacy reference points for parity (need >= 4) | 25 |

## Generated Inputs

- JDATCOM\validation\cases\qualification\generated_seed_20260301.inp
- JDATCOM\validation\cases\qualification\generated_seed_20260302.inp

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 4 | 0.4 | 5.0% | 0.0% | 2.273% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 6 | 0.4 | 4.348% | 0.0% | 1.667% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.058% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 1.0% |
| JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 0.893% |
| JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 0.877% |
| JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 0.867% |
| JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 0.82% |
| JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 0.794% |
