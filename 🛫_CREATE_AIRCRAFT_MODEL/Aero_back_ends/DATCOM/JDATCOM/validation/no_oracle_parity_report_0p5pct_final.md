# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 5
- Total blocks: 70
- Comparable blocks (finite legacy reference): 26
- Passed blocks: 23
- Failed blocks: 3
- Skipped blocks: 44
- Pass rate: 32.86%
- Comparable pass rate: 88.46%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 5 | 0 | 1 |
| tests/fixtures/ex2.inp | ok | 12 | 6 | 1 | 5 |
| tests/fixtures/ex3.inp | ok | 38 | 6 | 0 | 32 |
| tests/fixtures/ex4.inp | ok | 2 | 2 | 0 | 0 |
| JDATCOM/validation/cases/generated_suite.inp | ok | 12 | 4 | 2 | 6 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 2.5 | 0.0% | 0.0% | 0.633% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 0.617% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 0.548% |
