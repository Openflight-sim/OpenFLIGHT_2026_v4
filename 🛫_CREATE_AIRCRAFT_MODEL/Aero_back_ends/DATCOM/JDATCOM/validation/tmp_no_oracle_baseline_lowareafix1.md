# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 5
- Total blocks: 70
- Comparable blocks (finite legacy reference): 26
- Passed blocks: 20
- Failed blocks: 6
- Skipped blocks: 44
- Pass rate: 28.57%
- Comparable pass rate: 76.92%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 5 | 0 | 1 |
| tests/fixtures/ex2.inp | ok | 12 | 7 | 0 | 5 |
| tests/fixtures/ex3.inp | ok | 38 | 6 | 0 | 32 |
| tests/fixtures/ex4.inp | ok | 2 | 2 | 0 | 0 |
| JDATCOM/validation/cases/generated_suite.inp | ok | 12 | 0 | 6 | 6 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 0.0% | 5.325% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 3 | 0.4 | 5.0% | 0.0% | 4.528% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 1 | 0.4 | 5.0% | 0.0% | 4.918% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 6 | 0.4 | 4.0% | 0.0% | 3.784% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 0.0% | 1.0% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 0.0% | 0.548% |
