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
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 8.38% | 60.0% | 68.0% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 8.38% | 40.625% | 68.0% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 13.74% | 60.0% | 68.0% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 13.74% | 30.0% | 68.0% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 0.6 | 31.818% | 29.032% | 20.0% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 2.5 | 6.667% | 28.571% | 1.0% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 1.4 | 8.0% | 15.686% | 16.0% |
