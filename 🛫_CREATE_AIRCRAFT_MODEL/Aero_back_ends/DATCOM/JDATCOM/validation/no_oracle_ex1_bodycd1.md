# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 6
- Comparable blocks (finite legacy reference): 5
- Passed blocks: 2
- Failed blocks: 3
- Skipped blocks: 1
- Pass rate: 33.33%
- Comparable pass rate: 40.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 2 | 3 | 1 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 2 | 0.6 | 45.0% | 22.857% | 19.0% |
| tests/fixtures/ex1.inp | HYPERSONIC BODY SOLUTION,  EXAMPLE PROBLEM 1, CASE 4 | 2.5 | 5.0% | 1.667% | 2.75% |
| tests/fixtures/ex1.inp | APPROXIMATE AXISYMMETRIC BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 1 | 0.6 | 0.0% | 0.0% | 1.0% |
