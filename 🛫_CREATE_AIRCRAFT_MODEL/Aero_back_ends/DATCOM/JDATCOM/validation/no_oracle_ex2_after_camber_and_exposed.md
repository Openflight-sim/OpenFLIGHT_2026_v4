# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 12
- Comparable blocks (finite legacy reference): 7
- Passed blocks: 6
- Failed blocks: 1
- Skipped blocks: 5
- Pass rate: 50.0%
- Comparable pass rate: 85.71%
- Target relative tolerance: 1.0%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex2.inp | ok | 12 | 6 | 1 | 5 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 0.0% | 5.556% | 0.0% |
