# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 38
- Comparable blocks (finite legacy reference): 9
- Passed blocks: 0
- Failed blocks: 9
- Skipped blocks: 29
- Pass rate: 0.0%
- Comparable pass rate: 0.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex3.inp | ok | 38 | 0 | 9 | 29 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.8 | 695.0% | 98.468% | 96.135% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.8 | 695.0% | 98.468% | 96.135% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.8 | 695.0% | 98.468% | 96.135% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.6 | 91.572% | 98.57% | 336.0% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.6 | 91.572% | 98.57% | 336.0% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 1.5 | 75.035% | 98.798% | 135.739% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 1.5 | 75.035% | 98.798% | 135.739% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 1.5 | 75.035% | 98.798% | 135.739% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.6 | 64.305% | 116.667% | 102.486% |
