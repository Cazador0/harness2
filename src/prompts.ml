(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Stage prompts (Python: core/prompts.py, ~1,160 lines of prompt text).

   The prompt text is data, not method logic, so this port does not re-type it. Two sources:

   - [Builtin]: a short job statement per stage, enough for the deterministic demo (whose
     scripted editor ignores the wording) and for reading the control flow.
   - [Python_export]: runs experiment/scripts/export_prompt.py, which renders the exact
     Python prompt for the same stage, so a model-backed run sees byte-identical text. *)

type stage =
  | Propose of { dim : [ `Inv | `Dom ]; k : int; index : int; round_t : int option }
  | Aggregate of { k : int; index : int }
  | Compose_round of { t : int; k : int }
  | Select of { n : int }
  | Experience

type source = Builtin | Python_export of { script : string }

let source = ref Builtin

let builtin (bp : Spec.bench_prompts) = function
  | Propose { dim = `Inv; index; _ } ->
      Printf.sprintf "Propose candidate inv%d: one GENERAL (task-invariant) improvement to the harness for agents that %s. Edit context/harness/ in place; explain in <notes>." index bp.work
  | Propose { dim = `Dom; index; _ } ->
      Printf.sprintf "Propose candidate dom%d: one %s-SPECIFIC improvement to the harness for agents that %s. Edit context/harness/ in place; explain in <notes>." index bp.domain_word bp.work
  | Aggregate { index; k } ->
      Printf.sprintf "Compose final harness %d of %d from the candidates in context/pool/ and their execution contrasts. Edit context/harness/; explain in <notes>." index k
  | Compose_round { t; k } -> Printf.sprintf "Round %d of %d: compose the refined harness from this round's probes. Edit context/harness/; explain in <notes>." t k
  | Select { n } -> Printf.sprintf "Choose the best of %d anonymous candidate %ss. Answer with <why>...</why> and a ```choice block." n bp.deliverable_word
  | Experience -> "Write what the adopted harness changed and why, as <edits> and an <experience> block (cue, lesson, evidence, confidence), or NO_ENTRY."

let args = function
  | Propose { dim; k; index; round_t } ->
      [ "propose"; (match dim with `Inv -> "INV" | `Dom -> "DOM"); string_of_int k; string_of_int index;
        (match round_t with Some t -> string_of_int t | None -> "none") ]
  | Aggregate { k; index } -> [ "aggregate"; string_of_int k; string_of_int index ]
  | Compose_round { t; k } -> [ "compose_round"; string_of_int t; string_of_int k ]
  | Select { n } -> [ "select"; string_of_int n ]
  | Experience -> [ "experience" ]

let render (bp : Spec.bench_prompts) stage =
  match !source with
  | Builtin -> builtin bp stage
  | Python_export { script } ->
      let code, out, err = Fs.run ([ "python3"; script; "--work"; bp.work ] @ args stage) in
      if code <> 0 then failwith ("prompt export failed: " ^ Fs.trim err) else out
