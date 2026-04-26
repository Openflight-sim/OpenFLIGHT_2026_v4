# Parity Qualification Report

- Generated at: 2026-02-26T21:59:53.638
- Target relative tolerance: 0.5%
- Overall gate pass: false

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 26 | 0 | 44 | 100.0% |
| generated | 3 | 18 | 3 | 15 | 18 | 16.67% |
| combined | 8 | 44 | 29 | 15 | 62 | 65.91% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | false | 15 | 0 |
| comparable_volume | true | 44 | 20 |
| body_only_cases | true | 29 | > 0 |
| wing_only_cases | true | 28 | > 0 |
| full_config_cases | true | 30 | > 0 |
| canard_cases | true | 10 | > 0 |
| wing_type_1 | true | 65 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 123 | > 0 |
| transonic_regime | true | 59 | > 0 |
| supersonic_regime | true | 137 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 29 |
| canard_cases | 10 |
| cases_total | 97 |
| expr_cases | 5 |
| full_config_cases | 30 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 8 |
| mach_points_total | 319 |
| subsonic_regime | 123 |
| supersonic_regime | 137 |
| transonic_regime | 59 |
| wing_only_cases | 28 |
| wing_type_1 | 65 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| legacy component buildup block not selected for full-configuration parity | 31 |
| insufficient finite legacy reference points for parity (need >= 4) | 31 |

## Generated Inputs

- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 4 | 0.4 | 5.0% | 0.0% | 2.273% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 6 | 0.4 | 4.348% | 0.0% | 1.667% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.183% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 1.058% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 1.0% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 0.893% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 0.87% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260301.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 0.867% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 0.862% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 1 | 0.4 | 0.0% | 0.0% | 0.82% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260302.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 0.794% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 0.0% | 0.772% |
| F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260303.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 0.0% | 0.656% |
