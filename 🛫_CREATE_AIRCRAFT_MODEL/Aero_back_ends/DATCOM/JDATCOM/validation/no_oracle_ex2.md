# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 12
- Comparable blocks (finite legacy reference): 7
- Passed blocks: 0
- Failed blocks: 7
- Skipped blocks: 5
- Pass rate: 0.0%
- Comparable pass rate: 0.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex2.inp | ok | 12 | 0 | 7 | 5 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 19.44% | 55.06% | 36.63% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 17.969% | 54.974% | 31.355% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 19.44% | 34.208% | 36.63% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 17.969% | 34.123% | 31.355% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 2.5 | 6.892% | 31.145% | 1.398% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 0.6 | 30.254% | 28.723% | 20.151% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 1.4 | 8.349% | 16.049% | 15.692% |
