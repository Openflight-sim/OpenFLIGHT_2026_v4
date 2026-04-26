# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 38
- Comparable blocks (finite legacy reference): 6
- Passed blocks: 0
- Failed blocks: 6
- Skipped blocks: 32
- Pass rate: 0.0%
- Comparable pass rate: 0.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex3.inp | ok | 38 | 0 | 6 | 32 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.6 | 10.484% | 56.522% | 42.096% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.6 | 10.484% | 56.522% | 42.096% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 1.5 | 2.851% | 40.909% | 1.633% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 1.5 | 2.851% | 40.909% | 1.633% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 1.5 | 2.851% | 38.095% | 1.633% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.6 | 11.233% | 28.571% | 29.865% |
