# Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
# Part of caml-harness, an OCaml re-implementation of Harness2 (Google LLC, Apache-2.0); see NOTICE.

"""Render one Harness2 stage prompt exactly as the Python release builds it.

caml-harness calls this when Prompts.source is Python_export, so model-backed runs see
the same prompt text as the Python release without re-typing it. Set HARNESS2_ROOT to a
Harness2 checkout.

    HARNESS2_ROOT=/path/to/harness2 python3 scripts/export_prompt.py --work "..." propose INV 2 1 none
"""

import argparse
import os
import sys

if not os.environ.get("HARNESS2_ROOT"):
    sys.exit("set HARNESS2_ROOT to a Harness2 checkout")
sys.path.insert(0, os.environ["HARNESS2_ROOT"])

from harness2.core import prompts  # noqa: E402
from harness2.core.spec import BenchPrompts  # noqa: E402
from harness2.substrate.opencode import OPENCODE_SURFACE  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--work", required=True)
    p.add_argument("stage")
    p.add_argument("rest", nargs="*")
    a = p.parse_args()
    bp = BenchPrompts(work=a.work)
    r = a.rest
    if a.stage == "propose":
        round_t = None if r[3] == "none" else int(r[3])
        text = prompts.propose(
            bp, r[0], OPENCODE_SURFACE, k=int(r[1]), index=int(r[2]), round_t=round_t
        )
    elif a.stage == "aggregate":
        text = prompts.aggregate(bp, OPENCODE_SURFACE, k=int(r[0]), index=int(r[1]))
    elif a.stage == "compose_round":
        text = prompts.compose_round(bp, OPENCODE_SURFACE, t=int(r[0]), k=int(r[1]))
    elif a.stage == "select":
        text = prompts.select(bp, int(r[0]), pool_kind="finals")
    elif a.stage == "experience":
        text = prompts.experience(bp)
    else:
        p.error(f"unknown stage {a.stage!r}")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
