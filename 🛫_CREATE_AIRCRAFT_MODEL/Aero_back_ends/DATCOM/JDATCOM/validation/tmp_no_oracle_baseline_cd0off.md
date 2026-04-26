# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 5
- Total blocks: 70
- Comparable blocks (finite legacy reference): 26
- Passed blocks: 21
- Failed blocks: 5
- Skipped blocks: 44
- Pass rate: 30.0%
- Comparable pass rate: 80.77%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 5 | 0 | 1 |
| tests/fixtures/ex2.inp | ok | 12 | 7 | 0 | 5 |
| tests/fixtures/ex3.inp | ok | 38 | 6 | 0 | 32 |
| tests/fixtures/ex4.inp | ok | 2 | 2 | 0 | 0 |
| JDATCOM/validation/cases/generated_suite.inp | ok | 12 | 1 | 5 | 6 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 14.286% | 0.0% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 12.5% | 0.0% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 11.111% | 0.0% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 3 | 0.4 | 0.0% | 10.0% | 0.0% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 9.091% | 0.0% |
