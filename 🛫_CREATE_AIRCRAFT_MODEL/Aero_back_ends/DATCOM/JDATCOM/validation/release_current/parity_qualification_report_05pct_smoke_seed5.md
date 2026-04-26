# Parity Qualification Report

- Generated at: 2026-02-27T12:08:28.919
- Target relative tolerance: 0.5%
- Overall gate pass: false

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 24 | 2 | 44 | 92.31% |
| generated | 5 | 30 | 19 | 11 | 30 | 63.33% |
| combined | 10 | 56 | 43 | 13 | 74 | 76.79% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | false | 13 | 0 |
| comparable_volume | true | 56 | 20 |
| body_only_cases | true | 41 | > 0 |
| wing_only_cases | true | 40 | > 0 |
| full_config_cases | true | 42 | > 0 |
| canard_cases | true | 14 | > 0 |
| wing_type_1 | true | 93 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 175 | > 0 |
| transonic_regime | true | 87 | > 0 |
| supersonic_regime | true | 193 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 41 |
| canard_cases | 14 |
| cases_total | 137 |
| expr_cases | 5 |
| full_config_cases | 42 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 10 |
| mach_points_total | 455 |
| subsonic_regime | 175 |
| supersonic_regime | 193 |
| transonic_regime | 87 |
| wing_only_cases | 40 |
| wing_type_1 | 93 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| insufficient finite legacy reference points for parity (need >= 4) | 43 |
| legacy component buildup block not selected for full-configuration parity | 31 |

## Generated Inputs

- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260304.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260305.inp

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
| F:\WORK\CAPAS\DATCOM\python-datcom-master\tests\fixtures\ex1.inp | APPROXIMATE AXISYMMETRIC BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 1 | 0.6 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260304.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\tests\fixtures\ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 2 | 0.6 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260304.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260305.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260305.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 0.0% | 0.837% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 0.794% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 0.671% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260305.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 0.621% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 0.571% |
