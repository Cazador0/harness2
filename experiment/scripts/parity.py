"""Run the Python release and the OCaml port on the same demo, and compare what they produce.

    python3 experiment/scripts/parity.py [--k 1 2 3] [--work DIR]

Compared, per k: the demo summary; every execution's answer; each selection's chosen
label, anonymous id map, reasoning and experience; each mode's ledger (R, P and the exact
rollout and session labels in order); harness fingerprints; and every library file
(INDEX.md, EXPERIENCE.md, adopted harness trees). Absolute paths are normalised.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
EXPERIMENT = HERE.parents[1]
REPO = HERE.parents[2]
OCAML = EXPERIMENT / "_build" / "default" / "bin" / "main.exe"

SELECTION_KEYS = (
    "chosen_id", "chosen_label", "chosen_run_id", "chosen_is_base", "why", "id_map",
    "dropped", "n_candidates", "ok", "fallback", "experience", "trivial",
    "chosen_tree_is_base", "harness_fingerprint",
)
LEDGER_KEYS = ("R", "expected_R", "P", "expected_P", "rollouts", "sessions")


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{cmd[0]} failed ({p.returncode}):\n{p.stdout}\n{p.stderr}")


def files(root: Path, sub: str) -> dict[str, str]:
    base = root / sub
    if not base.is_dir():
        return {}
    return {
        str(p.relative_to(base)): p.read_text(errors="replace").replace(str(root), "<ROOT>")
        for p in sorted(base.rglob("*"))
        if p.is_file() and "__pycache__" not in p.parts
    }


def summaries(root: Path) -> dict[str, dict]:
    out = {}
    for path in sorted((root / "runs").rglob("summary.json")):
        s = json.loads(path.read_text())
        key = str(path.relative_to(root / "runs").parent)
        row = {"status": s["status"], "errors": s["errors"], "modes": {}, "selections": {}}
        for mode, rec in (s.get("modes") or {}).items():
            led = rec.get("ledger") or {}
            row["modes"][mode] = {
                "finals": rec.get("finals"),
                "fell_back": rec.get("fell_back"),
                "kept_base": rec.get("kept_base"),
                "stage_labels": [st["label"] for st in rec.get("stages", [])],
                "similarity": rec.get("similarity"),
                "ledger": {k: led.get(k) for k in LEDGER_KEYS},
            }
        for mode, sel in (s.get("selections") or {}).items():
            row["selections"][mode] = {k: sel.get(k) for k in SELECTION_KEYS}
        out[key] = row
    return out


def demo_summary(root: Path) -> dict:
    return json.loads((root / "demo.json").read_text())


def compare(name, a, b, problems):
    if a == b:
        return
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                problems.append(f"{name}/{key}: only in {'python' if key in a else 'ocaml'}")
            else:
                compare(f"{name}/{key}", a[key], b[key], problems)
    else:
        problems.append(f"{name}: python={json.dumps(a)[:300]} ocaml={json.dumps(b)[:300]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, nargs="+", default=[1, 2, 3])
    ap.add_argument("--work", type=Path)
    a = ap.parse_args()
    if not OCAML.is_file():
        run(["dune", "build"], EXPERIMENT)
    work = a.work or Path(tempfile.mkdtemp(prefix="harness2-parity-"))
    total = 0
    for k in a.k:
        py, ml = work / f"py-k{k}", work / f"ml-k{k}"
        for d in (py, ml):
            shutil.rmtree(d, ignore_errors=True)
        run([sys.executable, "-m", "harness2.cli.demo", "--output", str(py), "--k", str(k)], REPO)
        run([str(OCAML), "demo", "--output", str(ml), "--k", str(k)], EXPERIMENT)
        problems: list[str] = []
        compare("demo.json", demo_summary(py), demo_summary(ml), problems)
        compare("summaries", summaries(py), summaries(ml), problems)
        compare("executions", files(py, "executions"), files(ml, "executions"), problems)
        compare("library", files(py, "library"), files(ml, "library"), problems)
        compare("base", files(py, "base"), files(ml, "base"), problems)
        n_exec = len(files(py, "executions"))
        n_lib = len(files(py, "library"))
        status = "IDENTICAL" if not problems else f"{len(problems)} DIFFERENCES"
        print(f"k={k}: {status}  ({n_exec} execution files, {n_lib} library files, "
              f"{len(summaries(py))} task summaries compared)")
        for line in problems[:40]:
            print("   ", line)
        total += len(problems)
    print(f"work dir: {work}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
