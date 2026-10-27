(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* caml-harness: command line. *)

open Caml_harness

let usage =
  "caml-harness demo   [--output DIR] [--k K] [--mode parallel|sequential|both] [--a2a on|off]\n\
  \                    [--prompts builtin|python] [--judge local|jev]\n\
   caml-harness agents                 print the A2A agent cards of a demo workflow\n\
   caml-harness plan   --k K [--mode parallel|sequential|both]\n\
   caml-harness ids    --task ID --k K --mode parallel|sequential LABEL...\n"

let rec flags acc = function
  | f :: v :: rest when String.length f > 2 && String.sub f 0 2 = "--" -> flags ((f, v) :: acc) rest
  | rest -> (acc, rest)

let die msg = prerr_string (msg ^ "\n" ^ usage); exit 2
let get fs name default = Option.value (List.assoc_opt name fs) ~default
let modes_of = function "both" -> Spec.all_modes | s -> (match Spec.mode_of_string s with Ok m -> [ m ] | Error e -> die e)
let int_flag fs name default = match int_of_string_opt (get fs name default) with Some k when k >= 1 -> k | _ -> die (name ^ " must be a positive integer")
let abs_path p = if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p
let ( / ) = Filename.concat

(* The demo editor behind the three Harness2 roles, plus the eval judge, on one bus. *)
let demo_bus ~transcript ~judge (adapter : Spec.adapter) (editor : Proposer.t) =
  let bus = A2a.Bus.create ~transcript () in
  Agents.register_roles ~leak_globs:adapter.spec.leak_globs bus editor;
  A2a.Bus.register bus (match judge with "jev" -> Jev.agent ~as_:"judge" () | _ -> Demo.judge_agent ());
  bus

let demo fs =
  let k = int_flag fs "--k" "2" and modes = modes_of (get fs "--mode" "both") in
  let a2a = match get fs "--a2a" "on" with "on" -> true | "off" -> false | s -> die ("--a2a takes on|off, got " ^ s) in
  (match get fs "--prompts" "builtin" with
   | "builtin" -> ()
   | "python" -> Prompts.source := Prompts.Python_export { script = Filename.dirname Sys.executable_name / ".." / ".." / ".." / "scripts" / "export_prompt.py" }
   | s -> die ("unknown --prompts " ^ s));
  let root = abs_path (get fs "--output" "runs/demo") in
  let adapter, executions = Demo.make root in
  let editor = Demo.proposer () in
  let bus = demo_bus ~transcript:(root / "a2a" / "transcript.jsonl") ~judge:(get fs "--judge" "local") adapter editor in
  let prop = if a2a then Agents.via_bus bus editor.channel else editor in
  let finished = ref [] in
  let result =
    Schedule.run_domain ~on_task:(fun r -> finished := !finished @ [ r ]) "accounting" (adapter.tasks ()) k ~adapter ~prop
      ~runs_root:adapter.spec.runs_root ~library_root:(root / "library" / Printf.sprintf "k%d" k) ~modes ()
  in
  let result = match result with Json.Assoc kv -> Json.Assoc (kv @ [ ("execution_count", Json.Int (executions ())); ("editor_calls", Json.Int (editor.calls ())) ]) | j -> j in
  Fs.write (root / "demo.json") (Json.to_string result);
  (* Evals run after selection, from outside the runs tree, so no agent's evidence sees them. *)
  let suite = Demo.eval_suite () in
  Fs.write (root / "evals" / "suite.json") (Json.to_string (Eval.suite_json suite));
  let rows =
    List.concat_map
      (fun (r : Schedule.task_result) ->
        match List.find_opt (fun (c : Eval.case) -> c.task_id = r.task_id) suite.cases with
        | None -> []
        | Some case ->
            List.filter_map (fun (b : Spec.run_view) -> if b.label = "base1" then Some (Eval.score ~bus case ~subject:"base1" b ~adapter) else None) r.base_runs
            @ List.map (fun (m, (c : Spec.run_view)) -> Eval.score ~bus case ~subject:(Spec.mode_name m ^ ":" ^ c.label) c ~adapter) r.chosen)
      !finished
  in
  let summaries = Eval.report rows in
  Fs.write (root / "evals" / "judged.json")
    (Json.to_string (Json.Assoc [ ("suite", Json.String suite.name); ("rows", Json.List (List.map Eval.row_json rows)); ("report", Json.List (List.map Eval.summary_json summaries)) ]));
  let n key = match result with Json.Assoc kv -> (match List.assoc key kv with Json.Int i -> i | _ -> 0) | _ -> 0 in
  Printf.printf "Local demo: %d tasks completed; %d failed. %s\n" (n "done") (n "failed") (root / "demo.json");
  Printf.printf "A2A: %d messages%s\n" (List.length (A2a.Bus.entries bus)) (if a2a then ", transcript " ^ (root / "a2a" / "transcript.jsonl") else " (refinement ran in-process)");
  Printf.printf "Evals (%s):\n" (root / "evals" / "judged.json");
  Eval.print_report summaries;
  exit (if n "failed" > 0 then 1 else 0)

let agents () =
  let adapter, _ = Demo.make (Filename.get_temp_dir_name () / "caml-harness-cards") in
  let bus = demo_bus ~transcript:(Filename.get_temp_dir_name () / "caml-harness-cards.jsonl") ~judge:"local" adapter (Demo.proposer ()) in
  print_string (Json.to_string (Json.List (List.map A2a.card_json (A2a.Bus.cards bus))))

let plan fs =
  let k = int_flag fs "--k" "1" in
  List.iter
    (fun mode ->
      let p = Budget.plan mode k in
      Printf.printf "%s k=%d  R=%d  P=%d\n  rollouts: %s\n  sessions: %s\n" (Spec.mode_name mode) k (List.length p.rollouts) (List.length p.sessions)
        (String.concat " " p.rollouts) (String.concat " " p.sessions))
    (modes_of (get fs "--mode" "both"))

let ids fs labels =
  let mode = match modes_of (get fs "--mode" "parallel") with [ m ] -> m | _ -> die "--mode must be parallel or sequential" in
  List.iter (fun (a, l) -> Printf.printf "%s %s\n" a l) (Selection.assign_ids labels ~task_id:(get fs "--task" "") ~k:(int_flag fs "--k" "1") ~mode)

let () =
  match Array.to_list Sys.argv with
  | _ :: "demo" :: rest -> demo (fst (flags [] rest))
  | _ :: "agents" :: _ -> agents ()
  | _ :: "plan" :: rest -> plan (fst (flags [] rest))
  | _ :: "ids" :: rest -> let fs, labels = flags [] rest in ids fs labels
  | _ -> print_string usage
