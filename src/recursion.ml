(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Parallel and sequential task-level recursion (Python: core/recursion.py).

   Each mode runs exactly the labels of [Budget.plan mode k]: 4k rollouts and 3k
   improvement stages, including the k shared base executions. An invalid proposal gets one
   retry before the stage keeps the harness it started from. *)

open Fs

let stage_attempts = 2
let phase_width = 2

type stage = {
  label : string;
  dim : string;
  tree : Tree.t;
  kept_base : bool;
  fell_back : bool;
  error : string;
  usd : float;
  attempts : int;
  notes : string;
}

type result = {
  mode : Spec.mode;
  task_id : string;
  k : int;
  stages : stage list;
  trees : (string * Tree.t) list;
  rollouts : (string * Spec.run_view) list;
  finals : string list;
  ledger : Budget.Ledger.t;
  similarity : (int * int * float) option;
}

let clip n s = if String.length s > n then String.sub s 0 n else s

(* Repair, then validate a proposed tree: Ok kept_base, or the rejection to send back. *)
let accept_tree (adapter : Spec.adapter) tree ~fallback ~label =
  let tree, triggered = Tree.autotrigger adapter.surface tree in
  if triggered <> [] then Printf.printf "  [%s] auto-triggered skill(s): %s\n%!" label (String.concat ", " triggered);
  let kept = Tree.unchanged adapter.surface fallback tree in
  match
    Tree.validate ~allow_subagents:adapter.spec.allow_subagents
      ~reserved:(Tree.reserved_scripts @ adapter.spec.reserved_scripts) adapter.surface tree
  with
  | Error es -> (tree, Error (String.concat " | " es))
  | Ok _ -> (
      match adapter.validate_tree tree with
      | Error e -> (tree, Error e)
      | Ok () -> (
          match Context.tree_grader_verdict tree with Some e -> (tree, Error e) | None -> (tree, Ok kept)))

let run_stage ~label ~dim ~job ~fallback ~(adapter : Spec.adapter) ~(prop : Proposer.t) ~ctx_dir ~task_id ~rollouts
    ~harness_dir ~library_dir ?(pool = []) ?(decisions = []) () =
  let fell_back error attempts usd = { label; dim; tree = fallback; kept_base = false; fell_back = true; error = clip 400 error; usd; attempts; notes = "" } in
  match Context.build (ctx_dir / label) adapter task_id rollouts ~harness_dir ?library_dir ~pool ~decisions () with
  | Error e -> fell_back ("could not build evidence: " ^ e) 0 0.
  | Ok ctx ->
      let mission = Context.mission ctx ~job in
      let rec attempt i err usd calls =
        if i > stage_attempts then fell_back err calls usd
        else begin
          let m = if err = "" then mission else mission ^ "\n\n# YOUR PREVIOUS ATTEMPT WAS REJECTED\n\n" ^ err ^ "\n\nFix it in `context/harness/` and reply again." in
          match Proposer.call prop ~harvest:"context/harness" ~mission:m ctx ~label:(Printf.sprintf "%s.a%d" label i) with
          | exception Proposer.Proposer_error e -> fell_back e.message (calls + e.attempts) (usd +. e.cost_usd)
          | reply -> (
              let usd = usd +. reply.cost_usd and calls = calls + if reply.cached then 0 else max 1 reply.attempts in
              match reply.workspace with
              | None -> attempt (i + 1) "the harness directory did not come back from the session; edit the files in `context/harness/` in place" usd calls
              | Some ws -> (
                  let rejected = ref [] in
                  let proposed = Tree.read_tree ~rejected adapter.surface ws in
                  if Tree.SMap.is_empty proposed then attempt (i + 1) "`context/harness/` came back empty -- edit the files, do not delete them all" usd calls
                  else if !rejected <> [] then
                    attempt (i + 1)
                      ("these files are off the editable surface and were not applied: " ^ String.concat ", " (List.filteri (fun j _ -> j < 6) (List.sort compare !rejected))
                     ^ ". Component names must be lowercase letters, digits, `_` or `-`.")
                      usd calls
                  else
                    match accept_tree adapter proposed ~fallback ~label with
                    | repaired, Error e ->
                        ignore (Tree.write_tree adapter.surface repaired (Context.root ctx / "harness"));
                        attempt (i + 1) e usd calls
                    | repaired, Ok kept ->
                        let notes = match Rx.between ~open_:"<notes>" ~close:"</notes>" reply.text with Some n -> Fs.trim n | None -> Fs.trim reply.text in
                        { label; dim; tree = repaired; kept_base = kept; fell_back = false; error = ""; usd; attempts = calls; notes }))
        end
      in
      attempt 1 "" 0. 0

(* Materialise a harness and roll it once. A dead rollout is recorded, never raised. *)
let roll (adapter : Spec.adapter) ~task_id ~work_dir ~run_id_of label tree : Spec.run_view =
  let hdir = Tree.write_tree adapter.surface tree (work_dir / "harnesses" / label) in
  let run_id = run_id_of label in
  match adapter.execute ~task_id ~harness_dir:(Some hdir) ~run_id with
  | rd ->
      let exists = Sys.file_exists rd in
      { label; run_id; run_dir = rd; ok = exists; delivered = exists && adapter.delivered rd; cost_usd = 0.; error = (if exists then "" else "adapter returned a missing run directory") }
  | exception e -> { label; run_id; run_dir = work_dir / "missing"; ok = false; delivered = false; cost_usd = 0.; error = Printexc.to_string e }

(* Roll concurrently, then record in the caller's order so the ledger is deterministic. *)
let roll_many adapter ledger ~task_id ~work_dir ~run_id_of items =
  let got = Fs.parallel_map ~width:phase_width (fun (label, tree) -> roll adapter ~task_id ~work_dir ~run_id_of label tree) items in
  List.map2 (fun (label, _) rv -> Budget.Ledger.record ledger Budget.Rollout label; (label, rv)) items got

let record_sessions ledger stages =
  List.iter (fun s -> Budget.Ledger.record ledger Budget.Session ~usd:s.usd ~attempts:s.attempts s.label) stages

let decisions_of stages = List.map (fun s -> (s.label, if s.notes <> "" then s.notes else s.error)) stages

let start mode ~task_id ~k base =
  let ledger = Budget.Ledger.create (Budget.plan mode k) ~task_id in
  List.iter (fun (r : Spec.run_view) -> Budget.Ledger.record ledger Budget.Rollout r.label) base;
  ledger

(* WIDTH: 2k candidates from shared evidence, then k independent compositions. *)
let run_parallel ~task_id ~k ~(base : Spec.run_view list) ~(adapter : Spec.adapter) ~prop ~work_dir ~run_id_of ~base_tree ?library_dir () =
  let ledger = start Spec.Parallel ~task_id ~k base in
  let ctx_dir = work_dir / "context" and bp = adapter.spec.prompts in
  let base_dir = Tree.write_tree adapter.surface base_tree (work_dir / "harnesses" / "base") in
  let specs = List.concat (List.init k (fun i -> [ (Printf.sprintf "inv%d" (i + 1), `Inv, i + 1); (Printf.sprintf "dom%d" (i + 1), `Dom, i + 1) ])) in
  let stages =
    Fs.parallel_map ~width:phase_width
      (fun (label, dim, index) ->
        run_stage ~label ~dim:(if dim = `Inv then "INV" else "DOM")
          ~job:(Prompts.render bp (Propose { dim; k; index; round_t = None }))
          ~fallback:base_tree ~adapter ~prop ~ctx_dir ~task_id ~rollouts:base ~harness_dir:base_dir ~library_dir ())
      specs
  in
  record_sessions ledger stages;
  let cand_rolls = roll_many adapter ledger ~task_id ~work_dir ~run_id_of (List.map (fun s -> (s.label, s.tree)) stages) in
  let pool = List.map (fun s -> { Context.label = s.label; harness_dir = work_dir / "harnesses" / s.label; rollout = List.assoc_opt s.label cand_rolls }) stages in
  let aggs =
    Fs.parallel_map ~width:phase_width
      (fun index ->
        run_stage ~label:(Printf.sprintf "agg%d" index) ~dim:"AGG" ~job:(Prompts.render bp (Aggregate { k; index }))
          ~fallback:base_tree ~adapter ~prop ~ctx_dir ~task_id ~rollouts:base ~harness_dir:base_dir ~library_dir ~pool
          ~decisions:(decisions_of stages) ())
      (List.init k (fun i -> i + 1))
  in
  record_sessions ledger aggs;
  let final_rolls = roll_many adapter ledger ~task_id ~work_dir ~run_id_of (List.map (fun s -> (s.label, s.tree)) aggs) in
  Budget.Ledger.close ledger;
  let all = stages @ aggs in
  {
    mode = Spec.Parallel; task_id; k; stages = all; ledger;
    trees = List.map (fun s -> (s.label, s.tree)) all;
    rollouts = List.map (fun (r : Spec.run_view) -> (r.label, r)) base @ cand_rolls @ final_rolls;
    finals = List.map (fun s -> s.label) aggs;
    similarity = Some (Tree.diversity (List.map (fun s -> (s.label, s.tree)) aggs));
  }

(* DEPTH: k nested Propose-Probe-Compose passes over the same shared base evidence. *)
let run_sequential ~task_id ~k ~(base : Spec.run_view list) ~(adapter : Spec.adapter) ~prop ~work_dir ~run_id_of ~base_tree ?library_dir () =
  let ledger = start Spec.Sequential ~task_id ~k base in
  let ctx_dir = work_dir / "context" and bp = adapter.spec.prompts in
  let stages = ref [] and rollouts = ref (List.map (fun (r : Spec.run_view) -> (r.label, r)) base) in
  let rec round t current history =
    if t > k then ()
    else begin
      let current_label = if t > 1 then Printf.sprintf "c%d" (t - 1) else "base" in
      let current_dir = Tree.write_tree adapter.surface current (work_dir / "harnesses" / current_label) in
      let earlier = decisions_of !stages in
      let probes =
        Fs.parallel_map ~width:2
          (fun (label, dim) ->
            run_stage ~label ~dim:(if dim = `Inv then "INV" else "DOM")
              ~job:(Prompts.render bp (Propose { dim; k; index = t; round_t = (if k > 1 then Some t else None) }))
              ~fallback:current ~adapter ~prop ~ctx_dir ~task_id ~rollouts:base ~harness_dir:current_dir ~library_dir ~pool:history
              ~decisions:earlier ())
          [ (Printf.sprintf "inv%d" t, `Inv); (Printf.sprintf "dom%d" t, `Dom) ]
      in
      record_sessions ledger probes;
      stages := !stages @ probes;
      let rolled = roll_many adapter ledger ~task_id ~work_dir ~run_id_of (List.map (fun s -> (s.label, s.tree)) probes) in
      rollouts := !rollouts @ rolled;
      let round_pool = history @ List.map (fun s -> { Context.label = s.label; harness_dir = work_dir / "harnesses" / s.label; rollout = List.assoc_opt s.label rolled }) probes in
      let ck = Printf.sprintf "c%d" t in
      let job = if k = 1 then Prompts.render bp (Aggregate { k = 1; index = 1 }) else Prompts.render bp (Compose_round { t; k }) in
      let comp =
        run_stage ~label:ck ~dim:"COMPOSE" ~job ~fallback:current ~adapter ~prop ~ctx_dir ~task_id ~rollouts:base ~harness_dir:current_dir
          ~library_dir ~pool:round_pool ~decisions:(decisions_of !stages) ()
      in
      record_sessions ledger [ comp ];
      stages := !stages @ [ comp ];
      let rv = roll adapter ~task_id ~work_dir ~run_id_of ck comp.tree in
      Budget.Ledger.record ledger Budget.Rollout ck;
      rollouts := !rollouts @ [ (ck, rv) ];
      round (t + 1) comp.tree (round_pool @ [ { Context.label = ck; harness_dir = work_dir / "harnesses" / ck; rollout = Some rv } ])
    end
  in
  round 1 base_tree [];
  Budget.Ledger.close ledger;
  {
    mode = Spec.Sequential; task_id; k; stages = !stages; ledger; rollouts = !rollouts;
    trees = List.map (fun s -> (s.label, s.tree)) !stages;
    finals = Budget.finals Spec.Sequential k;
    similarity = None;
  }

let run_mode = function Spec.Parallel -> run_parallel | Spec.Sequential -> run_sequential

let stage_json s =
  Json.Assoc
    [
      ("label", Json.String s.label); ("dim", Json.String s.dim); ("fell_back", Json.Bool s.fell_back);
      ("kept_base", Json.Bool s.kept_base); ("attempts", Json.Int s.attempts); ("usd", Json.Float s.usd);
      ("notes", Json.String s.notes); ("error", Json.String (clip 400 s.error));
    ]

let to_json r =
  let similarity = match r.similarity with
    | None -> Json.Null
    | Some (n, distinct, jac) -> Json.Assoc [ ("n", Json.Int n); ("n_distinct", Json.Int distinct); ("mean_line_jaccard", Json.Float jac) ] in
  Json.Assoc
    [
      ("mode", Json.String (Spec.mode_token r.mode)); ("task_id", Json.String r.task_id); ("k", Json.Int r.k);
      ("finals", Json.strings r.finals);
      ("fell_back", Json.strings (List.filter_map (fun s -> if s.fell_back then Some s.label else None) r.stages));
      ("kept_base", Json.strings (List.filter_map (fun s -> if s.kept_base then Some s.label else None) r.stages));
      ("stages", Json.List (List.map stage_json r.stages));
      ("similarity", similarity);
      ("ledger", Budget.Ledger.to_json r.ledger);
    ]
