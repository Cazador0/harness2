# experiment/: Harness² method core in OCaml (prototype)

**Status: temporary prototype.** It re-implements the Harness² *method core* (recursion,
budget, harness tree, leak guards, blind selection, reflection, experience library,
scheduling) in OCaml, and leaves a seam for Jev. Nothing outside this folder was changed;
the Python release is untouched and remains the reference.

## Verified result

`scripts/parity.py` runs the Python demo and the OCaml demo on the same tasks and compares
every artifact both produce:

```
k=1: IDENTICAL  (28 execution files, 26 library files, 2 task summaries compared)
k=2: IDENTICAL  (56 execution files, 26 library files, 2 task summaries compared)
k=3: IDENTICAL  (84 execution files, 26 library files, 2 task summaries compared)
```

The comparison covers execution answers and trajectories, every selection (chosen label,
anonymous ID map, reasoning, experience), each mode's ledger (R, P and the exact label
order), harness fingerprints, and every library file (`INDEX.md`, `EXPERIENCE.md`, adopted
harness trees). Changing one word in one OCaml library file makes it report a difference,
so the comparison is not vacuous.

`dune test` runs 31 regression checks (budget, IDs, surface, guards, demo, Jev fallback).

## Run it

Requires OCaml ≥ 4.14, dune ≥ 3.0, and `python3` (the demo's executor runs Python scripts,
as the Python demo does). On Ubuntu: `apt-get install ocaml-nox ocaml-dune`.

```bash
cd experiment
dune build && dune test
./_build/default/bin/main.exe demo --output runs/demo --k 2       # same as harness2-demo
./_build/default/bin/main.exe plan --k 2                          # the exact budget labels
./_build/default/bin/main.exe ids --task ledger-1 --k 3 --mode parallel agg1 agg2 agg3
cd .. && python3 experiment/scripts/parity.py --k 1 2 3           # Python vs OCaml
```

`demo --prompts python` renders every stage prompt through `scripts/export_prompt.py`, so
the text is byte-identical to the Python release.

## Module map (Python → OCaml)

| Python (`harness2/`) | OCaml (`experiment/src/`) | What changed in the port |
|---|---|---|
| `core/tree.py` | `tree.ml` | Paths are classified into a `component` variant (c1–c8). An off-surface path has no constructor, and every `match` over components is checked for exhaustiveness. `validate` returns `result` instead of raising. |
| `core/ledger.py` | `budget.ml/.mli` | A `plan` is derived from `k` first: the exact 4k rollout and 3k session labels. The ledger refuses an unplanned or duplicate label **when it is recorded**; `close` refuses a missing one. Python checks only at the end. `plan` is `private`, so no code can build a plan with other labels. |
| `core/context.py` | `context.ml/.mli` | `Context.t` is **abstract**: only `build` and `seal` create one, and both run the answer-key and grader-verdict scans first. A proposer accepts only `Context.t`, so handing a model unscanned evidence does not compile. |
| `core/spec.py` | `spec.ml` | Mode, channel kind and deliverables policy are variants rather than strings checked at runtime. The adapter is a record of functions. |
| `core/recursion.py` | `recursion.ml` | Same control flow: retry once, then fall back; INV/DOM probes; parallel compositions or sequential rounds. Threads (width 2) as in Python. |
| `core/selection.py` | `selection.ml` | Same blind selection, trivial k=1 path, fallback and reflection parsing. |
| `random.Random` + `hashlib.sha1` | `py_random.ml`, `sha1.ml` | Re-implemented bit for bit, so the anonymous IDs match Python, and with them which candidate is adopted. |
| `core/library.py` | `library.ml` | Same layout and same INDEX/EXPERIENCE text. |
| `core/schedule.py` | `schedule.ml` | Shared bases, every mode, selection, reflection, summary, domain loop. |
| `core/runmark.py` | `runmark.ml` | Fingerprints only (resume marks not ported). |
| `core/proposer.py` | `proposer.ml` | `claude_cli` and `opencode` channels, transport retries, harvest. Untested against live services. |
| `core/prompts.py` | `prompts.ml` + `scripts/export_prompt.py` | Prompt text is data, so it isn't re-typed; it is either built in (short) or exported from Python. |
| `demo.py` | `demo.ml` | One-to-one port. |
| — | `jev.ml` | New: the Jev channel seam (below). |

## Jev

The Jev announcement (typesafe.ai) could not be fetched from the session that built this
(the host is outside its network allow-list), so **nothing here assumes Jev's API**.
`jev.ml` defines where Jev plugs in: a fourth channel kind, `Spec.Jev`, alongside
`opencode` and `claude_cli`. It serves any of the three model roles (improver, selector,
reflector) through one contract:

- **in:** the mission on stdin; working directory = a scratch copy of the sealed context
- **out:** the reply text on stdout, with the same tags the other channels use
- **effect:** harness edits made in place under `context/harness/`, harvested after

Set `HARNESS2_JEV_CMD` to the Jev command. Until then every Jev call fails cleanly. The
test `an unwired Jev channel degrades to fallbacks, not a crash` shows the recursion keeps
its budget and falls back, as it would for any failing channel.

## Not ported (prototype scope)

- Benchmark adapters (`benchmarks/jobbench.py`, `lab.py`, `workbuddy.py`; ~3.8k lines), the
  OpenCode and Codex substrate materialisation (`substrate/*.py`), the judge and report CLIs,
  setup and preflight, and the LiteLLM bridge. These mostly drive Python, TypeScript and
  Docker tooling, so they are the parts that benefit least from a port.
- Resume from `summary.json`, the proposer response cache, and audit logs.
- Codex's hooks-file validation (the OpenCode surface has no hooks file).
- The pool's `harness.diff` is a plain LCS line diff, not `difflib.unified_diff` hunks. It is
  evidence text for the model, not compared by the parity check.
- OCaml 4.14 (system threads) rather than OCaml 5 domains/Eio. That is enough here, since
  stages wait on subprocesses.
