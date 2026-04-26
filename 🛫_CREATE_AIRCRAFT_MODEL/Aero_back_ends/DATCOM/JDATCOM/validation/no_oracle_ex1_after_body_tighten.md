# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 6
- Comparable blocks (finite legacy reference): 5
- Passed blocks: 4
- Failed blocks: 1
- Skipped blocks: 1
- Pass rate: 66.67%
- Comparable pass rate: 80.0%
- Target relative tolerance: 1.0%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 4 | 1 | 1 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | HYPERSONIC BODY SOLUTION,  EXAMPLE PROBLEM 1, CASE 4 | 2.5 | 5.0% | 5.263% | 2.0% |
