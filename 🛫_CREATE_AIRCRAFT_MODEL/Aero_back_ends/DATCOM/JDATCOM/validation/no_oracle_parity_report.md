# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 5
- Total blocks: 70
- Comparable blocks (finite legacy reference): 26
- Passed blocks: 2
- Failed blocks: 24
- Skipped blocks: 44
- Pass rate: 2.86%
- Comparable pass rate: 7.69%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 2 | 3 | 1 |
| tests/fixtures/ex2.inp | ok | 12 | 0 | 7 | 5 |
| tests/fixtures/ex3.inp | ok | 38 | 0 | 6 | 32 |
| tests/fixtures/ex4.inp | ok | 2 | 0 | 2 | 0 |
| JDATCOM/validation/cases/generated_suite.inp | ok | 12 | 0 | 6 | 6 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 2 | 0.6 | 45.0% | 22.857% | 19.0% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 0.6 | 31.818% | 20.0% | 20.0% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.6 | 11.233% | 28.571% | 29.865% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 13.74% | 28.571% | 29.146% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 13.74% | 18.667% | 29.146% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 8.38% | 20.0% | 21.591% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 8.38% | 11.111% | 21.591% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.6 | 10.484% | 11.765% | 19.932% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.6 | 10.484% | 11.765% | 19.932% |
| tests/fixtures/ex4.inp | BODY PLUS WING PLUS CANARD, EXAMPLE PROBLEM 4, CASE 1 | 0.6 | 1.961% | 8.654% | 17.614% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 1.4 | 8.0% | 13.725% | 16.0% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 4 | 0.4 | 0.0% | 14.286% | 1.205% |
| tests/fixtures/ex4.inp | BODY PLUS WING PLUS CANARD, EXAMPLE PROBLEM 4, CASE 2 | 2.0 | 1.456% | 12.5% | 3.57% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 5 | 0.4 | 0.0% | 12.5% | 0.617% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 6 | 0.4 | 0.0% | 11.111% | 1.081% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 3 | 0.4 | 10.0% | 10.0% | 5.66% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 1.5 | 2.851% | 9.524% | 1.633% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 2 | 0.4 | 0.0% | 9.091% | 0.548% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 1.5 | 2.851% | 9.091% | 1.633% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 1.5 | 2.851% | 9.091% | 1.633% |
