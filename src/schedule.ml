(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Task stream scheduling (Python: core/schedule.py): k shared reference executions per
   task, every mode over them, blind selection per mode, reflection, library update. *)

open Fs

type namespace = { benchmark : string; substrate : string; mode : Spec.mode; k : int; seed : int option; tag : string }

let ns_string n =
  Printf.sprintf "%s-%s-%s%d" n.benchmark n.substrate (Spec.mode_token n.mode) n.k
  ^ (match n.seed with Some s -> Printf.sprintf "-s%d" s | None -> "")
  ^ if n.tag <> "" then "-" ^ n.tag else ""

let run_id n task_id label = Printf.sprintf "%s/%s/%s" (ns_string n) task_id label
let task_dir n root task_id = root / ns_string n / replace_all ~sub:"/" ~by:"__" task_id

let roll_bases (adapter : Spec.adapter) task_id pending dead_dir =
  let one (label, rid) : Spec.run_view =
    match adapter.execute ~task_id ~harness_dir:None ~run_id:rid with
    | rd -> { label; run_id = rid; run_dir = rd; ok = true; delivered = adapter.delivered rd; cost_usd = 0.; error = "" }
    | exception e -> { label; run_id = rid; run_dir = dead_dir; ok = false; delivered = false; cost_usd = 0.; error = Printexc.to_string e }
  in
  Fs.parallel_map ~width:Recursion.phase_width one pending

type task_result = {
  task_id : string;
  domain : string;
  k : int;
  mutable status : string;
  mutable base : Json.t;
  mutable modes : (string * Json.t) list;
  mutable selections : (string * Json.t) list;
  mutable mode_ok : (string * bool) list;
  mutable errors : string list;
  mutable base_runs : Spec.run_view list;
  mutable chosen : (Spec.mode * Spec.run_view) list; (* each mode's adopted final, for evals *)
}

let summary_json r =
  Json.Assoc
    [
      ("task_id", Json.String r.task_id); ("domain", Json.String r.domain); ("k", Json.Int r.k); ("status", Json.String r.status);
      ("base", r.base); ("modes", Json.Assoc r.modes); ("selections", Json.Assoc r.selections); ("errors", Json.strings r.errors);
    ]

let write_summary path r = write path (Json.to_string (summary_json r))

let run_one_mode mode ~task_id ~k ~base ~(adapter : Spec.adapter) ~prop ~selector ~n ~runs_root ~(lib : Library.t option) ~base_tree res =
  let tok = Spec.mode_token mode in
  let work_dir = task_dir n runs_root task_id in
  let library_dir = Option.bind lib Library.context_dir in
  let r = (Recursion.run_mode mode) ~task_id ~k ~base ~adapter ~prop ~work_dir ~run_id_of:(run_id n task_id) ~base_tree ?library_dir () in
  res.modes <- res.modes @ [ (tok, Recursion.to_json r) ];
  let candidates = Selection.selection_pool mode k r.rollouts in
  let sel =
    if k = 1 then Selection.trivial_selection ~task_id ~k ~mode candidates ~adapter ~work_dir
    else Selection.run_selection ~task_id ~k ~mode candidates ~adapter ~prop:selector ~work_dir
  in
  if lib <> None && sel.ok then
    Selection.reflect_adoption ~task_id sel r.rollouts ~adapter ~prop:selector ~work_dir ~decisions:(Recursion.decisions_of r.stages);
  let chosen_tree = Option.value (List.assoc_opt sel.chosen_label r.trees) ~default:base_tree in
  let chosen = List.assoc_opt sel.chosen_label candidates in
  let extra =
    [ ("chosen_tree_is_base", Json.Bool (Tree.unchanged adapter.surface base_tree chosen_tree));
      ("harness_fingerprint", Json.String (if sel.chosen_label = "" then "" else Runmark.fingerprint (work_dir / "harnesses" / sel.chosen_label))) ]
  in
  let sel_json = match Selection.to_json ~chosen_run_dir:(match chosen with Some c -> c.run_dir | None -> "") sel with Json.Assoc kv -> Json.Assoc (kv @ extra) | j -> j in
  res.selections <- res.selections @ [ (tok, sel_json) ];
  res.mode_ok <- res.mode_ok @ [ (tok, sel.ok && sel.chosen_label <> "") ];
  Option.iter (fun c -> res.chosen <- res.chosen @ [ (mode, c) ]) chosen;
  if not sel.ok then res.errors <- res.errors @ [ tok ^ ": selection failed: " ^ sel.error ];
  (match chosen with
   | Some c when sel.ok && not c.delivered -> res.errors <- res.errors @ [ Printf.sprintf "%s: selected run %s produced no deliverable" tok c.run_id ]
   | _ -> ());
  match lib with
  | Some lib when sel.ok && Library.has_experience sel.experience -> (
      match Library.add lib task_id chosen_tree ~why:sel.why ~label:sel.chosen_label ~run_id:sel.chosen_run_id ~experience:sel.experience with
      | Ok _ -> ()
      | Error e -> res.errors <- res.errors @ [ tok ^ ": library: " ^ e ])
  | _ -> ()

let run_task task_id k ~(adapter : Spec.adapter) ~(prop : Proposer.t) ?selector ~runs_root ?(modes = Spec.all_modes) ?seed ?(tag = "") ~libraries () =
  let selector = Option.value selector ~default:prop in
  let domain = adapter.domain_of task_id in
  let res = { task_id; domain; k; status = "running"; base = Json.List []; modes = []; selections = []; mode_ok = []; errors = []; base_runs = []; chosen = [] } in
  let mk mode = { benchmark = adapter.spec.name; substrate = adapter.substrate; mode; k; seed; tag } in
  let base_ns = mk Spec.Parallel in
  let work = task_dir base_ns runs_root task_id in
  mkdir_p work;
  let summary = work / "summary.json" in
  let base_tree = Tree.read_tree adapter.surface (adapter.base_harness ()) in
  let labels = List.init k (fun i -> Printf.sprintf "base%d" (i + 1)) in
  let base = roll_bases adapter task_id (List.map (fun l -> (l, run_id base_ns task_id l)) labels) (work / "missing") in
  res.base_runs <- base;
  res.base <- Json.List (List.map (fun (b : Spec.run_view) -> Json.Assoc [ ("label", Json.String b.label); ("run_id", Json.String b.run_id); ("run_dir", Json.String b.run_dir) ]) base);
  if not (List.exists (fun (b : Spec.run_view) -> b.ok) base) then begin
    res.status <- "base-failed";
    res.errors <- [ "no base rollout produced anything" ];
    write_summary summary res;
    res
  end
  else begin
    List.iter
      (fun mode ->
        let tok = Spec.mode_token mode in
        (try run_one_mode mode ~task_id ~k ~base ~adapter ~prop ~selector ~n:(mk mode) ~runs_root ~lib:(List.assoc_opt mode libraries) ~base_tree res
         with e ->
           res.modes <- res.modes @ [ (tok, Json.Assoc [ ("ok", Json.Bool false); ("error", Json.String (Printexc.to_string e)) ]) ];
           res.mode_ok <- res.mode_ok @ [ (tok, false) ];
           res.errors <- res.errors @ [ tok ^ ": " ^ Printexc.to_string e ]);
        res.status <- "partial";
        write_summary summary res)
      modes;
    res.status <- (if res.errors = [] && res.mode_ok <> [] && List.for_all snd res.mode_ok then "ok" else "partial");
    write_summary summary res;
    res
  end

(* Every task in one domain, in order, threading the library forward. *)
let run_domain ?(on_task = fun (_ : task_result) -> ()) domain task_ids k ~(adapter : Spec.adapter) ~prop ?selector ~runs_root ~library_root ?(modes = Spec.all_modes) ?seed ?(tag = "") () =
  let libs = List.map (fun m -> (m, { Library.root = library_root / Spec.mode_token m; domain; surface = adapter.surface })) modes in
  let done_ = ref 0 and failed = ref 0 and rows = ref [] in
  List.iteri
    (fun i tid ->
      let before = List.filteri (fun j _ -> j < i) task_ids in
      List.iter (fun (_, lib) -> Library.retain lib before) libs;
      let entries_before = Json.Assoc (List.map (fun (m, lib) -> (Spec.mode_token m, Json.Int (List.length (Library.entries lib)))) libs) in
      let row =
        match run_task tid k ~adapter ~prop ?selector ~runs_root ~modes ?seed ~tag ~libraries:libs () with
        | r when r.status = "ok" || r.status = "skipped" ->
            on_task r;
            incr done_;
            [ ("task", Json.String tid); ("status", Json.String r.status); ("library_entries_before", entries_before) ]
        | r ->
            on_task r;
            incr failed;
            [ ("task", Json.String tid); ("status", Json.String r.status); ("error", Json.String (if r.errors = [] then r.status else String.concat "; " r.errors));
              ("library_entries_before", entries_before) ]
        | exception e ->
            incr failed;
            [ ("task", Json.String tid); ("status", Json.String "exception"); ("error", Json.String (Printexc.to_string e)) ]
      in
      rows := !rows @ [ Json.Assoc row ];
      let status = match List.assoc "status" row with Json.String s -> s | _ -> "" in
      let err = match List.assoc_opt "error" row with Some (Json.String e) -> "  :: " ^ e | _ -> "" in
      Printf.printf "  [%s] %d/%d %-12s %s%s\n%!" domain (i + 1) (List.length task_ids) status tid err)
    task_ids;
  Json.Assoc
    [
      ("domain", Json.String domain); ("n_tasks", Json.Int (List.length task_ids));
      ("seed", match seed with Some s -> Json.Int s | None -> Json.Null);
      ("done", Json.Int !done_); ("failed", Json.Int !failed); ("tasks", Json.List !rows);
    ]
