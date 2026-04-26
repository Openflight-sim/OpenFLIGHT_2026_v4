"""
Compare JDATCOM (Julia) outputs against pydatcom (Python) on bundled fixtures.

Usage:
    python JDATCOM/validation/compare_with_python.py
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from pydatcom.io import NamelistParser, StateManager
from pydatcom.geometry import calculate_body_geometry, calculate_wing_geometry
from pydatcom.geometry import calculate_horizontal_tail, calculate_vertical_tail
from pydatcom.aerodynamics import AerodynamicCalculator, has_wing_or_tail


def as_float_list(value: Any) -> List[float]:
    if value is None:
        return []
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, (int, float)):
                out.append(float(item))
        return out
    return []


def python_state_for_case(case: Dict[str, Any]) -> StateManager:
    parser = NamelistParser()
    sm = StateManager()
    sm.update(parser.to_state_dict(case))

    state = sm.get_all()
    sm.update(calculate_body_geometry(state))

    state = sm.get_all()
    has_wing_input = any(
        state.get(k) is not None for k in ("wing_chrdr", "wing_sspn", "wing_chrdtp", "wing_sspne")
    )
    has_htail_input = any(
        state.get(k) is not None for k in ("htail_chrdr", "htail_sspn", "htail_chrdtp", "htail_sspne")
    )
    has_vtail_input = any(
        state.get(k) is not None for k in ("vtail_chrdr", "vtail_sspn", "vtail_chrdtp", "vtail_sspne")
    )

    if has_wing_input:
        wing_props = calculate_wing_geometry(state)
        sm.update(
            {
                "wing_area": wing_props.get("area", 0.0),
                "wing_span": wing_props.get("span", 0.0),
                "wing_aspect_ratio": wing_props.get("aspect_ratio", 0.0),
                "wing_taper_ratio": wing_props.get("taper_ratio", 0.0),
                "wing_mac": wing_props.get("mac", 0.0),
            }
        )

    state = sm.get_all()
    if has_htail_input:
        htail_props = calculate_horizontal_tail(state)
        sm.update(
            {
                "htail_area": htail_props.get("area", 0.0),
                "htail_span": htail_props.get("span", 0.0),
                "htail_aspect_ratio": htail_props.get("aspect_ratio", 0.0),
            }
        )

    state = sm.get_all()
    if has_vtail_input:
        vtail_props = calculate_vertical_tail(state)
        sm.update(
            {
                "vtail_area": vtail_props.get("area", 0.0),
                "vtail_span": vtail_props.get("span", 0.0),
                "vtail_aspect_ratio": vtail_props.get("aspect_ratio", 0.0),
            }
        )
    return sm


def run_python_fixture(input_path: Path) -> Dict[str, Any]:
    parser = NamelistParser()
    cases = parser.parse_file(input_path)
    out_cases = []

    for case in cases:
        sm = python_state_for_case(case)
        state = sm.get_all()
        calc = AerodynamicCalculator(state)

        mach_values = as_float_list(sm.get("flight_mach", [0.6])) or [0.6]
        alpha_values = as_float_list(sm.get("flight_alschd", [-2.0, 0.0, 2.0, 4.0, 8.0])) or [0.0]
        reynolds_values = as_float_list(sm.get("flight_rnnub", []))

        mach_results = []
        for mi, mach in enumerate(mach_values):
            reynolds = None
            if reynolds_values:
                reynolds = reynolds_values[min(mi, len(reynolds_values) - 1)]

            points = []
            for alpha in alpha_values:
                if reynolds is None:
                    r = calc.calculate_at_condition(alpha, mach)
                else:
                    r = calc.calculate_at_condition(alpha, mach, reynolds)
                points.append(
                    {
                        "alpha": alpha,
                        "cl": float(r.get("cl", 0.0)),
                        "cd": float(r.get("cd", 0.0)),
                        "cm": float(r.get("cm", 0.0)),
                        "regime": r.get("regime", ""),
                    }
                )

            mach_results.append({"mach": mach, "reynolds": reynolds, "points": points})

        out_cases.append(
            {
                "case_id": state.get("case_id", ""),
                "has_surfaces": bool(has_wing_or_tail(state)),
                "results": mach_results,
            }
        )

    return {"input": str(input_path), "num_cases": len(out_cases), "cases": out_cases}


def run_julia_fixture(input_path: Path, output_path: Path) -> Dict[str, Any]:
    script_path = REPO_ROOT / "JDATCOM" / "scripts" / "run_fixture.jl"
    cmd = [
        "julia",
        "--project=JDATCOM",
        str(script_path),
        str(input_path),
        str(output_path),
    ]
    subprocess.run(cmd, cwd=REPO_ROOT, check=True)
    return json.loads(output_path.read_text())


def compare_payloads(py: Dict[str, Any], jl: Dict[str, Any]) -> Dict[str, Any]:
    max_abs = {"cl": 0.0, "cd": 0.0, "cm": 0.0}
    max_rel = {"cl": 0.0, "cd": 0.0, "cm": 0.0}
    n_points = 0

    py_cases = py["cases"]
    jl_cases = jl["cases"]
    n_case = min(len(py_cases), len(jl_cases))

    for ci in range(n_case):
        py_case = py_cases[ci]
        jl_case = jl_cases[ci]
        py_machs = py_case["results"]
        jl_machs = jl_case["results"]
        n_m = min(len(py_machs), len(jl_machs))

        for mi in range(n_m):
            py_pts = py_machs[mi]["points"]
            jl_pts = jl_machs[mi]["points"]
            n_p = min(len(py_pts), len(jl_pts))

            for pi in range(n_p):
                p = py_pts[pi]
                j = jl_pts[pi]
                for key in ("cl", "cd", "cm"):
                    da = abs(float(p[key]) - float(j[key]))
                    max_abs[key] = max(max_abs[key], da)
                    denom = max(abs(float(p[key])), 1e-12)
                    dr = da / denom
                    max_rel[key] = max(max_rel[key], dr)
                n_points += 1

    return {"points_compared": n_points, "max_abs": max_abs, "max_rel": max_rel}


def main() -> int:
    fixtures = [
        REPO_ROOT / "tests" / "fixtures" / "ex1.inp",
        REPO_ROOT / "tests" / "fixtures" / "ex2.inp",
        REPO_ROOT / "tests" / "fixtures" / "ex3.inp",
        REPO_ROOT / "tests" / "fixtures" / "ex4.inp",
    ]

    reports = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for fixture in fixtures:
            py = run_python_fixture(fixture)
            jl_out = tmp / f"{fixture.stem}.julia.json"
            jl = run_julia_fixture(fixture, jl_out)
            cmp = compare_payloads(py, jl)

            report = {
                "fixture": fixture.name,
                "points_compared": cmp["points_compared"],
                "max_abs": cmp["max_abs"],
                "max_rel": cmp["max_rel"],
            }
            reports.append(report)

            print(f"\n{fixture.name}")
            print(f"  points: {report['points_compared']}")
            print(
                "  max abs: "
                f"CL={report['max_abs']['cl']:.6e}, "
                f"CD={report['max_abs']['cd']:.6e}, "
                f"Cm={report['max_abs']['cm']:.6e}"
            )
            print(
                "  max rel: "
                f"CL={report['max_rel']['cl']:.6e}, "
                f"CD={report['max_rel']['cd']:.6e}, "
                f"Cm={report['max_rel']['cm']:.6e}"
            )

    out_path = REPO_ROOT / "JDATCOM" / "validation" / "python_comparison_report.json"
    out_path.write_text(json.dumps({"reports": reports}, indent=2))
    print(f"\nWrote report: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
