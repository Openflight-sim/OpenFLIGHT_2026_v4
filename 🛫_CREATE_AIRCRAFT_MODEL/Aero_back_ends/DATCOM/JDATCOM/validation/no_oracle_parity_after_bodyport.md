# Pure Julia Parity Report

- Oracle enabled: false
- Inputs: 5
- Total blocks: 70
- Comparable blocks (finite legacy reference): 28
- Passed blocks: 0
- Failed blocks: 28
- Skipped blocks: 42
- Pass rate: 0.0%
- Comparable pass rate: 0.0%
- Target relative tolerance: 0.5%

## Inputs

| Input | Status | Blocks | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex1.inp | ok | 6 | 0 | 5 | 1 |
| tests/fixtures/ex2.inp | ok | 12 | 0 | 7 | 5 |
| tests/fixtures/ex3.inp | ok | 38 | 0 | 8 | 30 |
| tests/fixtures/ex4.inp | ok | 2 | 0 | 2 | 0 |
| JDATCOM/validation/cases/generated_suite.inp | ok | 12 | 0 | 6 | 6 |

## Worst Failing Blocks

| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |
|---|---:|---:|---:|---:|---:|
| tests/fixtures/ex4.inp | BODY PLUS WING PLUS CANARD, EXAMPLE PROBLEM 4, CASE 2 | 2.0 | 3.486999511e6% | 1.03366227310619e11% | 8.265806804e6% |
| tests/fixtures/ex4.inp | BODY PLUS WING PLUS CANARD, EXAMPLE PROBLEM 4, CASE 1 | 0.6 | 48.828% | 53.275% | 6049.994% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 0.6 | 3019.906% | 508.932% | 458.633% |
| tests/fixtures/ex3.inp | CONFIGURATION BUILDUP, EXAMPLE PROBLEM 3, CASE 1 | 1.5 | 2555.984% | 1066.248% | 463.564% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.8 | 695.604% | 98.512% | 96.13% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.8 | 695.604% | 98.512% | 96.13% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 0.6 | 91.545% | 98.599% | 336.02% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 0.6 | 91.545% | 98.599% | 336.02% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 2 | 1.5 | 75.048% | 98.757% | 135.737% |
| tests/fixtures/ex3.inp | INCLUDES BODY AND WING-BODY EXPERIMENTAL DATA, EX.PROB. 3, CASE 3 | 1.5 | 75.048% | 98.757% | 135.737% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 19.44% | 55.06% | 36.63% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 17.969% | 54.974% | 31.355% |
| tests/fixtures/ex1.inp | ASYMMETRIC (CAMBERED) BODY SOLUTION, EXAMPLE PROBLEM 1, CASE 2 | 0.6 | 42.996% | 21.598% | 19.457% |
| tests/fixtures/ex2.inp | EXPOSED CRANKED WING SOLUTION, EXAMPLE PROBLEM 2, CASE 2 | 0.6 | 19.44% | 34.208% | 36.63% |
| tests/fixtures/ex2.inp | EXPOSED DOUBLE DELTA WING SOLUTION, EXAMPLE PROBLEM 2, CASE 3 | 0.6 | 17.969% | 34.123% | 31.355% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 2.5 | 6.892% | 31.145% | 1.398% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 0.6 | 30.254% | 28.723% | 20.151% |
| tests/fixtures/ex2.inp | STRAIGHT TAPERED EXPOSED WING SOLUTION, EXAMPLE PROBLEM 2,CASE 1 | 1.4 | 8.349% | 16.049% | 15.692% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 3 | 0.4 | 8.901% | 7.291% | 5.586% |
| JDATCOM/validation/cases/generated_suite.inp | AUTO BODY CASE 4 | 0.4 | 2.016% | 8.389% | 1.133% |
