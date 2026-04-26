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
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 13.74% | 28.571% | 54.0% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 13.74% | 18.667% | 54.0% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 8.38% | 20.0% | 33.203% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 8.38% | 11.111% | 33.203% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 0.6 | 31.818% | 20.0% | 20.0% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 1.4 | 8.0% | 13.725% | 16.0% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 2.5 | 6.667% | 2.5% | 1.0% |
