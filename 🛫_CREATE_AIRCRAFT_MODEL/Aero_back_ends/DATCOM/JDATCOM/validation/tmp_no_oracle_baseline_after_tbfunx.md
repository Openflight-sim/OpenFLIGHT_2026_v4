# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 5
- Total blocks: 70
- Comparable blocks (finite legacy reference): 26
- Passed blocks: 18
- Failed blocks: 8
- Skipped blocks: 44
- Pass rate: 25.71%
- Comparable pass rate: 69.23%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 3 | 2 | 1 |
| tests/fixtures/ex2.inp | ok | 12 | 7 | 0 | 5 |
| tests/fixtures/ex3.inp | ok | 38 | 6 | 0 | 32 |
| tests/fixtures/ex4.inp | ok | 2 | 2 | 0 | 0 |
| JDATCOM/validation/cases/generated_suite.inp | ok | 12 | 0 | 6 | 6 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 14.286% | 4.819% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 12.5% | 6.604% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 1 | 0.4 | 5.0% | 0.0% | 11.765% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 3 | 0.4 | 10.0% | 10.0% | 11.698% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 11.111% | 5.157% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 9.091% | 6.407% |
| tests/fixtures/ex1.inp | APPROXIMATE AXISYMMETRIC BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 1 | 0.6 | 0.0% | 0.0% | 0.73% |
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 2 | 0.6 | 0.0% | 0.0% | 0.641% |
