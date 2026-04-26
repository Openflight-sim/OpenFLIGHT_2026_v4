# No-Oracle Diagnostics: `ex2`

Input:

- `tests/fixtures/ex2.inp`
- run mode: `--no-oracle`
- tolerance target: `0.5%` relative (`CL/CD/Cm`)

Current summary (`JDATCOM/validation/no_oracle_ex2.md`):

- Comparable blocks: `7`
- Passed: `0`
- Failed: `7`
- Skipped: `5`

Observed residual pattern:

1. Case 1 (straight tapered wing), `M=1.4`:
   - major improvement after type-aware supersonic lift/drag updates.
   - current worst block residuals are down to about:
     - `CL`: `~8.35%`
     - `CD`: `~18.96%`
     - `Cm`: `~21.10%`

2. Case 1, `M=0.6`:
   - subsonic negative-alpha correction reduced bias.
   - remaining maxima are around:
     - `CL`: `~30.25%`
     - `CD`: `~28.72%`
     - `Cm`: `~20.11%`

3. Cases 2 and 3 (cranked/double-delta), `M=0.6`:
   - `CL` now within roughly `18-19%` max relative.
   - remaining dominant error is still `CD` (`~34-55%`) with `Cm` around `31-37%`, concentrated in low-to-mid alpha.

4. Comparator behavior fix:
   - block matching now uses one-to-one Mach/altitude matching without reusing a single analytic block for many legacy blocks.
   - this removed artificial mega-failures from unmatched repeated legacy buildup sections and improves diagnostic fidelity.

Why this is still failing:

- The current strict no-oracle model is still a reduced-order surrogate for DATCOM wing routines (`CLMCH0`, `CSLOPE`, `CDRAG`, `CMALPH`) and does not yet port full table/interference logic.
- Cranked/delta subsonic drag and pitching-moment trends still require deeper method-level porting from DATCOM routines.
- For low absolute coefficients near zero, the `0.5%` threshold with comparator floors is very tight and magnifies small absolute bias.

Next technical targets:

- Replace remaining empirical `Cm(alpha)` fit with explicit `CMALPH/CMALPO` pathway for exposed-wing cases.
- Port low-AR cranked/delta drag buildup logic from DATCOM `CDRAG` flow for `TYPE=2/3`.
- Continue tuning subsonic negative-alpha branch for conventional swept wing so near-zero points match printed DATCOM values more tightly.
