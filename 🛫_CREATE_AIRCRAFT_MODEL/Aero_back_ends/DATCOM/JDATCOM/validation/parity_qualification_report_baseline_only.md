# Parity Qualification Report

- Generated at: 2026-02-26T20:24:18.180
- Target relative tolerance: 0.5%
- Overall gate pass: true

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 26 | 0 | 44 | 100.0% |
| generated | 0 | 0 | 0 | 0 | 0 | 0.0% |
| combined | 5 | 26 | 26 | 0 | 44 | 100.0% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | true | 0 | 0 |
| comparable_volume | true | 26 | 20 |
| body_only_cases | true | 11 | > 0 |
| wing_only_cases | true | 10 | > 0 |
| full_config_cases | true | 12 | > 0 |
| canard_cases | true | 4 | > 0 |
| wing_type_1 | true | 23 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 45 | > 0 |
| transonic_regime | true | 17 | > 0 |
| supersonic_regime | true | 53 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 11 |
| canard_cases | 4 |
| cases_total | 37 |
| expr_cases | 5 |
| full_config_cases | 12 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 5 |
| mach_points_total | 115 |
| subsonic_regime | 45 |
| supersonic_regime | 53 |
| transonic_regime | 17 |
| wing_only_cases | 10 |
| wing_type_1 | 23 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| legacy component buildup block not selected for full-configuration parity | 31 |
| insufficient finite legacy reference points for parity (need >= 4) | 13 |

## Generated Inputs


## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
