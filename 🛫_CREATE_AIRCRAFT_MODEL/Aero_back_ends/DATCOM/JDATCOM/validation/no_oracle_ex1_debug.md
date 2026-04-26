# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 1
- Total blocks: 6
- Comparable blocks (finite legacy reference): 5
- Passed blocks: 0
- Failed blocks: 5
- Skipped blocks: 1
- Pass rate: 0.0%
- Comparable pass rate: 0.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 0 | 5 | 1 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | HYPERSONIC BODY SOLUTION,  EXAMPLE PROBLEM 1, CASE 4 | 2.5 | 267.533% | 57.982% | 74.462% |
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 3 | 1.4 | 135.023% | 67.646% | 38.543% |
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 3 | 2.5 | 105.646% | 47.952% | 62.43% |
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 2 | 0.6 | 42.996% | 21.598% | 19.457% |
| tests/fixtures/ex1.inp | APPROXIMATE AXISYMMETRIC BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 1 | 0.6 | 1.908% | 3.217% | 0.543% |
