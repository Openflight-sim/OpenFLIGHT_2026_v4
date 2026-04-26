# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 38
- Comparable blocks (finite legacy reference): 7
- Passed blocks: 0
- Failed blocks: 7
- Skipped blocks: 31
- Pass rate: 0.0%
- Comparable pass rate: 0.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex3.inp | ok | 38 | 0 | 7 | 31 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.8 | 27.831% | 34.146% | 170.0% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 1.5 | 78.378% | 107.692% | 37.754% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 1.5 | 78.378% | 104.545% | 37.754% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 1.5 | 78.378% | 104.545% | 37.754% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.6 | 21.026% | 71.55% | 78.031% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.6 | 24.736% | 63.297% | 19.932% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.6 | 24.736% | 63.297% | 19.932% |
