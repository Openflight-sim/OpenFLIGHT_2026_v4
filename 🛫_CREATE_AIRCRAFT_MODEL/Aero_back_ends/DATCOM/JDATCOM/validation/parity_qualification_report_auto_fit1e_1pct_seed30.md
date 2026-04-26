# Parity Qualification Report

- Generated at: 2026-02-27T10:05:12.200
- Target relative tolerance: 1.0%
- Overall gate pass: true

## Parity Summaries

| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 5 | 26 | 26 | 0 | 44 | 100.0% |
| generated | 30 | 180 | 180 | 0 | 180 | 100.0% |
| combined | 35 | 206 | 206 | 0 | 224 | 100.0% |

## Gate Status

| Gate | Pass | Value | Target |
|---|---:|---:|---:|
| numeric_parity | true | 0 | 0 |
| comparable_volume | true | 206 | 20 |
| body_only_cases | true | 191 | > 0 |
| wing_only_cases | true | 190 | > 0 |
| full_config_cases | true | 192 | > 0 |
| canard_cases | true | 64 | > 0 |
| wing_type_1 | true | 443 | > 0 |
| wing_type_2 | true | 1 | > 0 |
| wing_type_3 | true | 2 | > 0 |
| expr_cases | true | 5 | > 0 |
| subsonic_regime | true | 825 | > 0 |
| transonic_regime | true | 437 | > 0 |
| supersonic_regime | true | 893 | > 0 |
| hypersonic_flag | true | 1 | > 0 |

## Coverage Counts

| Metric | Count |
|---|---:|
| body_only_cases | 191 |
| canard_cases | 64 |
| cases_total | 637 |
| expr_cases | 5 |
| full_config_cases | 192 |
| hypersonic_cases | 1 |
| hypersonic_regime | 0 |
| inputs | 35 |
| mach_points_total | 2155 |
| subsonic_regime | 825 |
| supersonic_regime | 893 |
| transonic_regime | 437 |
| wing_only_cases | 190 |
| wing_type_1 | 443 |
| wing_type_2 | 1 |
| wing_type_3 | 2 |

## Skipped Block Reasons (Combined)

| Reason | Count |
|---|---:|
| insufficient finite legacy reference points for parity (need >= 4) | 193 |
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
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260311.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260312.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260313.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260314.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260315.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260316.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260317.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260318.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260319.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260320.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260321.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260322.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260323.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260324.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260325.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260326.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260327.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260328.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260329.inp
- F:\WORK\CAPAS\DATCOM\python-datcom-master\JDATCOM\validation\cases\qualification\generated_seed_20260330.inp

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---|---:|---:|---:|---:|
