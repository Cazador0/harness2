# Harness²: Technical and Business Value Assessment

*Repository:* `cazador0/harness2` · *Version:* 0.1.0 (3 commits; first open-source release) · *License:* Apache 2.0 · *Origin:* Google LLC research release (paper: arXiv 2610.14224)
*Assessed:* 2026-10-27, from the source code, docs, a local test run, and the credential-free demo.

---

## 1. Executive summary

Harness² is a research framework that **makes an AI agent better at a task without retraining the model**. It does this by rewriting the agent's *harness*: the prompts, guardrails, memory, tool guidance, subagents, skills, scripts and plugins around a fixed model. It does the rewriting automatically and per task, and it carries what it learns forward to later tasks in the same domain.

Two ideas set it apart:

1. **Improvement without answers.** The refinement loop never sees ground truth, rubrics or grader output. It runs several harness variants on the same task and compares how they behaved. That makes it usable on new, real-world work where no answer key exists ("open world").
2. **Learning across tasks.** Each adopted harness and the lesson behind it go into a per-domain library, so task N+1 in "antitrust law" starts from what worked on tasks 1..N.

**Reported results (from the README/paper, not reproduced here):** one refinement step improved GLM-5 and Gemini 3.5 Flash over their base harnesses by up to **+11.5 points on WorkBuddy-Bench, +4.5 on JobBench, and +11.8 pp partial-pass on LAB (legal)**. A bigger recursion budget brought further gains.

**Bottom line:**
- *Technical value:* high. The code is small (~12.7k lines of Python), has no runtime dependencies in the core, is well partitioned, and has strong integrity guards around answer leakage and budget accounting.
- *Business value:* the method moves agent-quality spend from model training to cheaper, auditable configuration (text and script files). Its weak points are compute cost per task, research-grade operations (Linux only, Vertex AI by default, no hosted service) and dependence on public benchmarks for evidence.

---

## 2. What problem it solves

| Today's common approach | Limitation | Harness² approach |
|---|---|---|
| Hand-tune the system prompt and tools | Slow, expert-only, doesn't scale across domains | Model-driven editor proposes edits to 8 harness components |
| Fine-tune or RL the model | Expensive, needs labeled data, opaque, vendor lock-in | Model weights stay fixed; the improvements are readable files |
| Optimize the harness against a benchmark score | Overfits; impossible when there is no grader | Selection is "blind": it compares executions, never sees scores |
| Static harness for all tasks | Same harness for a tax memo and a spreadsheet | Per-task refinement plus per-domain memory |

---

## 3. Technical architecture

### 3.1 Three separate axes

The code separates three concerns (stated in `harness2/core/spec.py`), so each can change on its own:

| Axis | What it is | Where |
|---|---|---|
| **Method** | Recursion, prompts, selection, experience library | `harness2/core/` |
| **Substrate** (executor) | The agent framework that runs a rollout: **OpenCode** (default) or **Codex** | `harness2/substrate/` (`base.py` defines the `Substrate` protocol) |
| **Benchmark** | A `BenchSpec` value plus an adapter: **JobBench, LAB, WorkBuddy-Bench** | `harness2/benchmarks/` |

Adding a new agent framework means implementing the `Substrate` protocol (`surface`, `materialise`, `execute`, `read_trajectory`, `preflight`). Adding a new workload means writing a `BenchmarkAdapter`. The demo adapter (`harness2/demo.py`, ~160 lines) shows how small an adapter can be.

### 3.2 The harness as an editable tree (components c1–c8)

`harness2/core/tree.py` models a harness as a file tree with eight component types:

- **Context construction:** system prompt, guardrails, memory, skills
- **Tool interface:** tool guidance, scripts
- **Orchestration:** subagents
- **Middleware:** plugins (hooks)

Every proposed tree is **validated before use**. Paths must be on an allowlist, Python scripts must compile, skill and subagent references must resolve, hooks are checked, and reserved script names are protected. An invalid proposal gets one retry and then falls back to the current harness, so a bad edit can never crash the run.

### 3.3 Task-level recursion: Propose → Probe → Compose

`harness2/core/recursion.py` implements two modes with **the same budget**:

- **Parallel ("width"):** propose *k* general (INV) and *k* domain-specific (DOM) candidate harnesses, run them all, then build *k* independent compositions from the shared evidence.
- **Sequential ("depth"):** *k* successive propose/probe/compose rounds, each building on the last refined harness and the evidence gathered so far.

`harness2/core/ledger.py` enforces a **budget identity**: every mode uses exactly **R = 4k rollouts** (k base + 2k candidates + k finals) and **P = 3k improvement sessions**. A run that drifts from this raises `BudgetError`. This makes comparisons fair and costs predictable, which matters for both research and procurement.

### 3.4 Blind selection

`harness2/core/selection.py` picks the final output from the candidate pool:

- Candidates are given **anonymous IDs**, so the selector can't favor "the refined one".
- The selector sees the task, the deliverables and the trajectories, never scores.
- If the selector fails, the code falls back to a delivered base output; it never invents a winner.

### 3.5 Harnessing-level recursion: the experience library

`harness2/core/library.py` keeps, per domain, the **full adopted harness tree** (never a summary) plus an `EXPERIENCE.md` explaining why it was picked and what lesson to carry forward. Tasks in one domain run in order and read only earlier entries; different domains run concurrently (`--workers N`). Libraries are scoped by benchmark, executor, mode, budget and seed, so experiments don't contaminate each other.

### 3.6 Integrity and anti-leakage controls

This is the strongest engineering feature for anyone who needs to trust the numbers:

- `context.assert_no_leak_paths` refuses any model context containing benchmark-declared answer-key paths.
- `context.assert_no_grader_verdicts` scans file names *and contents* for grader output markers (`pass_rate`, `deterministic_eval_result`, and so on) and refuses the context if any appear. The code comments tell maintainers to fix the leak, not widen the marker list.
- `BenchPrompts.__post_init__` checks benchmark-supplied prompt text for leaked grading language.
- Adopted trees are checked for grader verdicts before entering the library.
- Upstream benchmark repositories are **pinned to exact commits** (`config.DEPENDENCY_PINS`), and setup refuses a checkout at another revision. Patches are listed and explained in `dependencies/PINNED.md`.

**Known gap, disclosed by the authors:** executors have unrestricted network access, and Codex runs with its sandbox disabled. In one validation run, a Codex agent downloaded a JobBench rubric from Hugging Face without being told to. The docs say to block `huggingface.co` and `github.com` at the network level before evaluating. Anyone reproducing the results should do this and report it.

### 3.7 Operations and developer experience

- **CLI surface:** `harness2` (run), `harness2-setup`, `harness2-check` (preflight), `harness2-judge`, `harness2-report`, `harness2-demo`, `harness2-bridge` (LiteLLM proxy for Codex).
- **Resume:** repeat the same command to resume. Completed work is fingerprinted (`core/runmark.py`), and the saved config blocks incompatible resumes.
- **Caching:** proposer calls are fingerprinted and cached, so reruns don't pay twice.
- **Preflight:** substrates must fail health checks *before* any model is called ("before money is spent").
- **Dry run:** `--dry-run` previews task selection with no model calls.
- **Reproducibility:** `--seed`, stratified train/test splits (`scripts/split_tasks.py`), and a recorded dataset revision for JobBench.

### 3.8 Code quality snapshot

| Metric | Observation |
|---|---|
| Size | ~12.7k LOC Python in `harness2/`; largest files are benchmark adapters (~1k lines each) and prompts (~1.2k) |
| Core dependencies | **None** (`dependencies = []`); optional `render` (openpyxl, python-pptx) and `bridge` (litellm, fastapi) extras |
| Python | 3.12–3.13; ruff configured |
| Tests | `tests/test_workflow.py`: 5 focused regression tests (budget identity, resume, evidence, adoption). **Verified: all 5 pass (7.4 s).** |
| Demo | `harness2-demo --k 2` runs both recursion modes with deterministic editors and real Python execution, no credentials. **Verified: 2/2 tasks completed.** |
| Gaps | Thin test coverage of benchmark adapters and substrates; no CI config in the repo; Linux/POSIX only |

---

## 4. Business value

### 4.1 Value levers

1. **Better agents without training costs.** Gains come from configuration, not GPUs. A team can lift an existing model (including cheaper "Flash"-class models) on its own workloads without a fine-tuning pipeline or labeled data.
2. **Smaller models doing bigger work.** If a refined harness closes part of the gap between a cheap model and a frontier model, inference spend drops while quality holds. *This needs validation on your own workload and model mix.*
3. **Readable, auditable improvements.** Output is plain files (prompts, guardrails, skills, scripts). Legal, compliance and security reviewers can read, diff and approve them, which they can't do with model weights. This suits regulated domains; LAB is legal work.
4. **Institutional memory that compounds.** The per-domain library turns each completed task into reusable knowledge, like a playbook that writes itself. Value grows with volume in a domain.
5. **Works where there is no grader.** Most real business tasks (memos, analyses, reports) have no automatic scorer. A method that improves without one fits real work better than score-driven optimizers.
6. **Vendor and framework portability.** Model-agnostic (Gemini, GLM, Claude routes appear in config) and executor-agnostic (OpenCode, Codex), so it doesn't lock you into one agent stack.

### 4.2 Fitting use cases

| Segment | Example | Why it fits |
|---|---|---|
| Legal / professional services | Contract review, regulatory memos by practice area | Domain-grouped tasks, rubric-like quality, need for auditable guardrails |
| Enterprise back office | Spreadsheets, decks, reporting (WorkBuddy office subset) | High-volume repeated task families; the library compounds |
| Software / web automation | Code and web subsets | Executor-native skills and scripts are directly editable |
| AI platform teams | Internal "agent quality" function | A repeatable method to tune harnesses per business unit |
| Researchers / evaluators | Harness-engineering studies | Fixed-budget comparisons, leak guards, pinned benchmarks |

### 4.3 Cost model (how to think about spend)

Per task, the budget is **4k executor rollouts + 3k improvement sessions** (with k=1: 4 rollouts + 3 sessions), plus judging if you evaluate. Compared with running a base harness once, that is roughly **4× the execution cost plus improver cost** at k=1, growing linearly with k. The economics work when:

- the refined harness gets **reused** (through the library) across many later tasks, which spreads the cost, or
- the task is valuable enough that a few points of quality are worth several rollouts (legal, finance, high-stakes analysis).

The docs say the full LAB stream is 1,143 tasks and warn to start small. Use `--max-tasks`, `--only-domains` and `--dry-run` to control spend.

### 4.4 Risks and limitations

| Risk | Severity | Mitigation |
|---|---|---|
| Per-task compute multiplier (~4k rollouts) | Medium–High | Use k=1; get value from reuse via the library; route only high-value tasks |
| Benchmark gains may not transfer to private workloads | Medium | Pilot on your own task families with your own evaluation |
| Results depend on the judge model ("changing the judge changes the measurement") | Medium | Fix the judge; report the configuration |
| Network leakage of public rubrics during evaluation | Medium (for credibility) | Egress firewall / DNS blocks, as documented |
| Research-grade release: v0.1.0, "not an officially supported Google product", Linux, Vertex-first defaults | Medium | Treat as reference implementation; wrap in your own ops |
| Codex executor runs unsandboxed | Medium–High in production | Run in isolated containers/VMs only |
| Third-party benchmark licenses (e.g. a territorial limit in the Tencent WorkBuddy license) | Legal review needed | Check `third_party/licenses/` before commercial use |
| Contributions require a Google CLA | Low | Standard for Google OSS |

### 4.5 Strategic positioning

Harness² sits in the space between **prompt engineering** (manual, cheap, fragile) and **model training** (automated, expensive, opaque). It automates harness engineering while keeping the output human-readable. That matches the wider shift your preferences describe: software as assembled, programmable patterns run by an agent through ordered tool calls rather than static apps. Here, even the *patterns themselves* (the harness) are written and improved by the system.

---

## 5. Recommendations

**To evaluate it (1–2 weeks):**
1. Run `harness2-demo` and the unit tests (both work offline; verified here).
2. Pick one benchmark subset and one domain, set k=1, `--max-tasks 1–5`, with network blocks on, to measure real cost per task.
3. Compare `harness2-judge --bases` (base harness) with the refined harness on the same tasks.

**To adopt it for a business workload:**
1. Write a `BenchmarkAdapter` for one internal task family (the demo adapter is the template).
2. Define a quality yardstick even if it isn't automatic (human review rubric), used only for *evaluation*, never fed to the loop.
3. Run tasks in domain order to build the library, then measure whether later tasks improve as the library grows.
4. Treat adopted harness trees as code: review, version and promote the good ones to production.

**Engineering gaps to close before production:** add CI; broaden tests for adapters and substrates; add sandboxing and egress policy by default; add a non-Vertex default model path; add cost reporting per task in dollars to the report command (the ledger already tracks `usd`).

---

## 6. Repository map (quick reference)

```
harness2/
  core/         recursion.py, schedule.py, selection.py, library.py, proposer.py,
                context.py (leak guards), tree.py (c1–c8 + validation), ledger.py (budget), judge.py, report.py
  substrate/    base.py (protocol), opencode.py, codex.py
  benchmarks/   jobbench.py, lab.py, workbuddy.py, wb_render.py, tasks.py
  cli/          run_sweep, setup, check, judge, report, demo, bridge
  demo.py       credential-free end-to-end demo adapter
third_party/    pinned runner overlays and patches for upstream benchmarks, with licenses
scripts/        run_{lab,jobbench,workbuddy}.sh, split_tasks.py, check_setup.py, check_provenance.py
docs/           SETUP.md, BENCHMARKS.md, EXPERIMENTS.md
tests/          test_workflow.py (5 regression tests)
```
