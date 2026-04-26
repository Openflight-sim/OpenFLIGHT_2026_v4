# Parity Qualification Report

- Generated at: 2026-02-26T23:57:38.256
- Target relative tolerance: 1.0%
- Overall gate pass: false

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 25 | 1 | 44 | 96.15% |
| generated | 10 | 60 | 50 | 10 | 60 | 83.33% |
| combined | 15 | 86 | 75 | 11 | 104 | 87.21% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | false | 11 | 0 |
| comparable_volume | true | 86 | 20 |
| body_only_cases | true | 71 | > 0 |
| wing_only_cases | true | 70 | > 0 |
| full_config_cases | true | 72 | > 0 |
| canard_cases | true | 24 | > 0 |
| wing_type_1 | true | 163 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 305 | > 0 |
| transonic_regime | true | 157 | > 0 |
| supersonic_regime | true | 333 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 71 |
| canard_cases | 24 |
| cases_total | 237 |
| expr_cases | 5 |
| full_config_cases | 72 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 15 |
| mach_points_total | 795 |
| subsonic_regime | 305 |
| supersonic_regime | 333 |
| transonic_regime | 157 |
| wing_only_cases | 70 |
| wing_type_1 | 163 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| insufficient finite legacy reference points for parity (need >= 4) | 73 |
| legacy component buildup block not selected for full-configuration parity | 31 |

## Generated Inputs

- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260304.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260305.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260306.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260307.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260308.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260309.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260310.inp

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 0.0% | 1.674% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260309.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 1.434% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260306.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 1.119% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260304.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 0.0% | 1.031% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 1.014% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260306.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260309.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\tests\fixtures\ex1.inp | APPROXIMATE AXISYMMETRIC BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 1 | 0.6 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260304.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260306.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260306.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 0.0% | 1.0% |
