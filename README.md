# caml-harness

**Recursive agent harnessing in OCaml, with agent evals and agent-to-agent (A2A) messaging.**

caml-harness re-implements the method of [Harness²](https://arxiv.org/abs/2610.14224)
(Google, Apache-2.0) in OCaml, then extends it for agentic workflows:

- **Harness refinement:** improve an agent by rewriting its *harness* (system prompt,
  guardrails, memory, tool guidance, subagents, skills, scripts, plugins) while the model
  stays fixed. Each task runs a Propose → Probe → Compose loop in parallel or sequential
  mode, with no access to answers. A per-domain library carries lessons forward.
- **Agent evals:** criteria-based grading of what a workflow delivered. Scores are
  Partial and All-pass, and a criterion nobody could judge is unscored, never zero. A
  base-versus-refined report compares the two. Checks can be deterministic or done by an
  eval agent.
- **Agent-to-agent communication:** the workflow's roles (improver, selector, reflector,
  judge) are agents with A2A-shaped cards, messages and tasks, carried over JSON-RPC. They
  run in-process or as subprocesses over stdio, and every exchange is logged to a JSONL
  transcript.

> Status: v0.1, a working reference of the method core with a deterministic demo.
> Benchmark adapters (JobBench, LAB, WorkBuddy-Bench) are not ported yet; see
> [Roadmap](#roadmap).

## Quick start

Needs OCaml ≥ 4.14, dune ≥ 3.0 and `python3`. The demo's executor runs small Python
scripts.

```bash
opam install . --deps-only --with-test      # or: apt-get install ocaml-nox ocaml-dune
dune build && dune test
dune exec caml-harness -- demo --output runs/demo --k 2
```

```
Local demo: 2 tasks completed; 0 failed.
A2A: 38 messages, transcript runs/demo/a2a/transcript.jsonl
group           n  scored   partial  all-pass
base            2       2     50.0%      0.0%
parallel        2       2    100.0%    100.0%
sequential      2       2    100.0%    100.0%
parallel vs base: +50.0 points partial
sequential vs base: +50.0 points partial
```

The demo's base harness ships a script that silently drops credits from a ledger total.
Refinement finds and fixes this from execution contrasts alone; the reference totals live
only in the eval suite. The evals then show the improvement.

Other commands: `caml-harness agents` prints the A2A agent cards, `caml-harness plan --k 3`
prints the exact budget, and `caml-harness ids` shows the anonymous candidate IDs.

## How it fits together

```
                    ┌──────────── A2A bus (JSON-RPC message/send, JSONL transcript) ───────────┐
  orchestrator ───► │ improver      selector      reflector      judge      <any stdio agent>  │
  (Schedule,        └──────▲────────────▲────────────▲─────────────▲──────────────▲────────────┘
   Recursion)              │ sealed     │ blind      │ adoption    │ deliverable  │ e.g. Jev
                           │ evidence   │ candidates │ record      │ + rubric     │
  per task:  k base runs ─► propose INV/DOM ─► probe ─► compose ─► select ─► reflect ─► library
                                                                               │
                                       after selection, outside the runs tree: evals ─► report
```

| Module | Role |
|---|---|
| `tree.ml` | The harness as a tree of files; each path is classified into a `component` variant (c1–c8), and validation returns `result`. |
| `budget.ml` | `plan mode k` lists the exact 4k rollouts and 3k sessions. The ledger refuses an unplanned or duplicate label when it is recorded. |
| `context.ml` | **Abstract** `Context.t`: evidence can reach an agent only after the answer-key and grader-verdict scans pass. |
| `recursion.ml` | Parallel (width) and sequential (depth) recursion with retry-then-fallback stages. |
| `selection.ml` | Blind selection with anonymous IDs bit-identical to Harness², the trivial k=1 path, and reflection. |
| `library.ml`, `schedule.ml` | Per-domain experience library; task and domain scheduling. |
| `a2a.ml` | Cards, messages, parts, tasks, states; JSON-RPC encoding; the `Bus`; `stdio` agents. |
| `agents.ml` | Harness² roles as agents (`serve`) and a bus-backed proposer (`via_bus`). Receivers re-seal evidence. |
| `eval.ml` | Criteria, checks (contains / matches / equals / command / agent judge), scoring, reports. |
| `jev.ml` | Jev as an A2A stdio agent (see below). |
| `proposer.ml` | Model channels: `claude_cli`, `opencode`, plus `of_session` for others. |

## Guarantees and how they're enforced

- **No agent sees answers or grader output.** `Context.t` is abstract, and only `build` or
  `seal` (which scan first) can create one. Every receiving agent seals again, so a leak
  is refused at each hop (test: *a receiving agent rejects evidence carrying an answer
  key*). Eval records use the guard's own marker keys, so eval output can never be sealed
  into evidence.
- **Fixed, comparable cost.** Both modes spend exactly 4k rollouts and 3k improvement
  stages, and the plan is a `private` type derived from `k`.
- **Failures degrade, never crash.** An unknown or failing agent returns a `Failed` task;
  the stage retries once, then keeps its harness. An unconfigured Jev agent leaves the
  whole workflow running on fallbacks (tested).

## Faithful to Harness²

`scripts/parity.py --harness2 /path/to/harness2` runs the Python Harness² demo and the
caml-harness demo (with every role call over the A2A bus) and compares every artifact:
executions, selections and anonymous ID maps, ledgers and label order, fingerprints, and
library files. Result: **identical at k = 1, 2 and 3.** `scripts/export_prompt.py`
(`demo --prompts python`, with `HARNESS2_ROOT` set) renders the exact Harness² stage
prompts, so the prompt text doesn't drift.

## Jev

Jev (typesafe.ai) joins as an A2A agent over stdio: one JSON-RPC `message/send` request on
stdin, one response whose `result` is an A2A task on stdout.
`scripts/stdio_agent_example.py` is a working template; replace its `answer()` with a call
to Jev.

```bash
# Jev as the eval judge
CAML_HARNESS_JEV_CMD="python3 my_jev_agent.py" dune exec caml-harness -- demo --judge jev
```

To use Jev in the refinement workflow, register `Jev.agent ~as_:"improver" ()` (or
`"selector"` / `"reflector"`) on the bus. The session that wrote this could not reach
typesafe.ai, so no Jev-specific API is assumed; the stdio contract is the integration
point.

## Writing an eval suite

```json
{ "name": "my-suite",
  "cases": [ { "task_id": "ledger-1",
               "criteria": [
                 { "id": "total", "description": "Signed total", "weight": 2,
                   "check": { "kind": "equals", "value": "Total: 85.15" } },
                 { "id": "tone", "description": "Professional tone", "weight": 1,
                   "check": { "kind": "agent", "agent": "judge", "rubric": "..." } } ] } ] }
```

Load it with `Eval.load`, then score runs with `Eval.score ~bus case ~subject run ~adapter`.

## Roadmap

1. Benchmark adapters: LAB first (legal, rubric-graded), then JobBench and WorkBuddy-Bench.
2. Executor substrates: OpenCode and Codex harness materialisation.
3. Resume from `summary.json`, a proposer reply cache, audit logs.
4. A2A over HTTP (agent card at `/.well-known/agent.json`) next to stdio.
5. OCaml 5 domains / Eio for structured concurrency and cancellation.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). caml-harness re-implements
Harness² (Copyright 2026 Google LLC, Apache-2.0) and is not affiliated with or endorsed by
Google.
