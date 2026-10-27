(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Blind, answer-free selection and post-adoption reflection (Python: core/selection.py). *)

open Fs

type t = {
  task_id : string;
  mode : Spec.mode;
  k : int;
  mutable chosen_id : string;
  mutable chosen_label : string;
  mutable chosen_run_id : string;
  mutable why : string;
  mutable id_map : (string * string) list; (* anonymous id -> label *)
  mutable dropped : string list;
  mutable n_candidates : int;
  mutable ok : bool;
  mutable fallback : bool;
  mutable error : string;
  mutable usd : float;
  mutable experience : (string * string) list;
  trivial : bool;
}

let create ?(trivial = false) task_id mode k =
  { task_id; mode; k; chosen_id = ""; chosen_label = ""; chosen_run_id = ""; why = ""; id_map = []; dropped = [];
    n_candidates = 0; ok = false; fallback = false; error = ""; usd = 0.; experience = []; trivial }

(* A..Z, AA..AZ, BA... *)
let anon_id index =
  let rec go n acc = if n = 0 then acc else let n, rem = (Stdlib.( / ) (n - 1) 26, (n - 1) mod 26) in go n (String.make 1 (Char.chr (65 + rem)) ^ acc) in
  go (index + 1) ""

(* anon id -> label, by canonical sort then a seeded shuffle: identical to the Python release. *)
let assign_ids labels ~task_id ~k ~mode =
  let digest = Sha1.hex (Printf.sprintf "%s|%d|%s" task_id k (Spec.mode_token mode)) in
  let seed = int_of_string ("0x" ^ String.sub digest 0 12) in
  let ordered = Array.of_list (List.sort compare labels) in
  Py_random.shuffle (Py_random.of_int seed) ordered;
  Array.to_list (Array.mapi (fun i l -> (anon_id i, l)) ordered)

let is_base label = starts_with ~prefix:"base" label

(* Exactly the k finals of the mode; reference executions are never in the pool. *)
let selection_pool mode k (rollouts : (string * Spec.run_view) list) =
  List.filter_map (fun l -> Option.map (fun r -> (l, r)) (List.assoc_opt l rollouts)) (Budget.finals mode k)

let render_pool (candidates : (string * Spec.run_view) list) (adapter : Spec.adapter) sel =
  List.filter_map
    (fun (lbl, (rv : Spec.run_view)) ->
      if not (rv.ok && rv.delivered) then (sel.dropped <- sel.dropped @ [ lbl ]; None)
      else
        match adapter.deliverable_text rv.run_dir with
        | exception e -> sel.dropped <- sel.dropped @ [ lbl ^ " (render failed: " ^ Printexc.to_string e ^ ")" ]; None
        | text when trim text = "" -> sel.dropped <- sel.dropped @ [ lbl ]; None
        | text -> Some (lbl, (rv, text)))
    candidates

let to_json ?(chosen_run_dir = "") s =
  let open Json in
  Assoc
    [
      ("task_id", String s.task_id); ("mode", String (Spec.mode_token s.mode)); ("k", Int s.k);
      ("chosen_id", String s.chosen_id); ("chosen_label", String s.chosen_label); ("chosen_run_id", String s.chosen_run_id);
      ("chosen_is_base", Bool (is_base s.chosen_label)); ("why", String s.why);
      ("id_map", Assoc (List.map (fun (a, l) -> (a, String l)) s.id_map)); ("dropped", strings s.dropped);
      ("n_candidates", Int s.n_candidates); ("ok", Bool s.ok); ("fallback", Bool s.fallback); ("error", String s.error);
      ("usd", Float s.usd); ("experience", Assoc (List.map (fun (k, v) -> (k, String v)) s.experience));
      ("trivial", Bool s.trivial); ("evidence", String "deliverable"); ("chosen_run_dir", String chosen_run_dir);
    ]

let persist sel root run_dir = write (root / "selection.json") (Json.to_string (to_json ~chosen_run_dir:run_dir sel))
let sel_dir work_dir sel = work_dir / "selection" / (Spec.mode_token sel.mode ^ string_of_int sel.k)

let fallback sel pool exn_msg =
  (* finals-only pool: the neutral stand-in is the first final by label *)
  match List.sort compare (List.map fst pool) with
  | [] -> sel.error <- exn_msg; false
  | first :: _ ->
      sel.chosen_label <- first;
      sel.chosen_id <- (match List.find_opt (fun (_, l) -> l = first) sel.id_map with Some (a, _) -> a | None -> "");
      sel.fallback <- true;
      sel.error <- Recursion.clip 400 exn_msg;
      true

let choice_rx = Str.regexp "```choice[ \t\n]*\\([A-Za-z0-9_-]+\\)[ \t\n]*```"

let run_selection ~task_id ~k ~mode candidates ~(adapter : Spec.adapter) ~(prop : Proposer.t) ~work_dir =
  let sel = create task_id mode k in
  let pool = render_pool candidates adapter sel in
  sel.n_candidates <- List.length pool;
  if pool = [] then (sel.error <- "no candidate produced an artifact"; sel)
  else begin
    sel.id_map <- assign_ids (List.map fst pool) ~task_id ~k ~mode;
    let root = sel_dir work_dir sel in
    rm_rf root;
    mkdir_p root;
    write (root / "task.md") (adapter.task_prompt task_id);
    ignore (Context.copy_source adapter task_id root);
    List.iter
      (fun (anon, lbl) ->
        let _, text = List.assoc lbl pool in
        let header =
          Printf.sprintf "<!-- candidate %s: %d chars, %d lines. COMPLETE -- nothing trimmed. Navigate with grep/offsets; evaluating a candidate means opening the part that determines whether it works.\n-->\n"
            anon (String.length text) (List.length (String.split_on_char '\n' text))
        in
        write (root / "candidates" / (anon ^ ".md")) (header ^ text))
      sel.id_map;
    let ids = String.concat ", " (List.sort compare (List.map fst sel.id_map)) in
    let mission =
      Prompts.render adapter.spec.prompts (Select { n = List.length pool })
      ^ "\n\n# YOUR EVIDENCE\n\nIt is on disk. Read it -- do not answer from this message alone.\n\n"
      ^ "context/task.md                 the instructions\ncontext/source/                 task source materials, when supplied\n"
      ^ "context/candidates/<id>.md      one file per candidate: " ^ ids ^ "\n\nOpen every candidate before choosing. Choose exactly one of: " ^ ids ^ "."
    in
    let outcome =
      match Context.seal root ~leak_globs:adapter.spec.leak_globs with
      | Error e -> Error e
      | Ok ctx -> (
          match Proposer.call prop ~mission ctx ~label:(Printf.sprintf "select.%s%d" (Spec.mode_token mode) k) with
          | exception Proposer.Proposer_error e -> sel.usd <- sel.usd +. e.cost_usd; Error e.message
          | reply -> (
              sel.usd <- sel.usd +. reply.cost_usd;
              match Rx.search_group choice_rx reply.text with
              | None -> Error "no ```choice block in the reply"
              | Some anon when not (List.mem_assoc anon sel.id_map) -> Error (Printf.sprintf "chose %S, which is not one of %s" anon ids)
              | Some anon ->
                  sel.why <- Recursion.clip 2000 (match Rx.between ~open_:"<why>" ~close:"</why>" reply.text with Some w -> trim w | None -> "");
                  sel.chosen_id <- anon;
                  sel.chosen_label <- List.assoc anon sel.id_map;
                  sel.ok <- true;
                  Ok ()))
    in
    let proceed = match outcome with Ok () -> true | Error e -> fallback sel pool e in
    if proceed then begin
      let rv, _ = List.assoc sel.chosen_label pool in
      sel.chosen_run_id <- rv.run_id;
      persist sel root rv.run_dir
    end;
    sel
  end

(* Deliver the single k=1 final without a selector session. *)
let trivial_selection ~task_id ~k ~mode candidates ~adapter ~work_dir =
  let sel = create ~trivial:true task_id mode k in
  let pool = render_pool candidates adapter sel in
  sel.n_candidates <- List.length pool;
  (match pool with
   | [] -> sel.error <- "no candidate produced an artifact (finals-only pool has no base fallback)"
   | (label, ((rv : Spec.run_view), _)) :: _ ->
       sel.ok <- true;
       sel.chosen_id <- "A";
       sel.chosen_label <- label;
       sel.id_map <- [ ("A", label) ];
       sel.chosen_run_id <- rv.run_id;
       sel.why <- "trivial pool: single final at k=1; delivered without a selector session";
       let root = sel_dir work_dir sel in
       rm_rf root;
       mkdir_p root;
       persist sel root rv.run_dir);
  sel

let experience_keys = [ "cue"; "lesson"; "evidence"; "confidence" ]

(* Learn from harness edits, decisions, trajectories and deliverables after adoption. *)
let reflect_adoption ~task_id sel (candidates : (string * Spec.run_view) list) ~(adapter : Spec.adapter) ~(prop : Proposer.t) ~work_dir ~decisions =
  match List.assoc_opt sel.chosen_label candidates with
  | None -> ()
  | Some _ when not sel.ok -> ()
  | Some chosen -> (
      let tok = Spec.mode_token sel.mode ^ string_of_int sel.k in
      let root = work_dir / "reflection" / tok and harnesses = work_dir / "harnesses" in
      let pool =
        List.filter_map
          (fun (label, rv) -> if is_base label then None else Some { Context.label; harness_dir = harnesses / label; rollout = Some rv })
          candidates
      in
      match Context.build root adapter task_id (List.map snd candidates) ~harness_dir:(harnesses / sel.chosen_label) ~pool ~decisions () with
      | Error e -> sel.error <- "reflection evidence: " ^ e
      | Ok evidence -> (
          ignore (copy_tree (adapter.base_harness ()) (root / "base_harness"));
          write (root / "adoption.json")
            (Json.to_string
               (Json.Assoc
                  [ ("chosen_label", Json.String sel.chosen_label); ("candidate_ids", Json.Assoc (List.map (fun (a, l) -> (a, Json.String l)) sel.id_map)); ("reason", Json.String sel.why) ]));
          let mission =
            Prompts.render adapter.spec.prompts Experience
            ^ "\n\n# WHAT HAPPENED\n\nHarness " ^ sel.chosen_label ^ " was adopted. The selection reasoning was:\n\n" ^ sel.why
            ^ "\n\ncontext/adoption.json maps any anonymous IDs in that reasoning to rollout labels. Compare context/harness/ with context/base_harness/ and the candidates in context/pool/. Read the decisions and execution contrasts before writing.\n\n"
            ^ Context.layout evidence
          in
          let exp_root = root ^ ".experience" in
          rm_rf exp_root;
          ignore (copy_tree root exp_root);
          (try Sys.remove (exp_root / "selection.json") with Sys_error _ -> ());
          match Context.seal exp_root ~leak_globs:adapter.spec.leak_globs with
          | Error e -> sel.error <- "reflection evidence: " ^ e
          | Ok ctx -> (
              match Proposer.call prop ~mission ctx ~label:("experience." ^ tok) with
              | exception Proposer.Proposer_error e -> sel.usd <- sel.usd +. e.cost_usd
              | reply ->
                  sel.usd <- sel.usd +. reply.cost_usd;
                  let edits = Option.map trim (Rx.between ~open_:"<edits>" ~close:"</edits>" reply.text) in
                  Option.iter (fun e -> write (root / "edits.md") (e ^ "\n")) edits;
                  (match Rx.between ~open_:"<experience>" ~close:"</experience>" reply.text with
                   | None -> ()
                   | Some block ->
                       let fields =
                         List.filter_map
                           (fun line ->
                             match String.index_opt line ':' with
                             | None -> None
                             | Some i ->
                                 let key = String.lowercase_ascii (trim (String.sub line 0 i)) in
                                 let v = trim (String.sub line (i + 1) (String.length line - i - 1)) in
                                 if List.mem key experience_keys then Some (key, v) else None)
                           (lines (trim block))
                       in
                       let has k = match List.assoc_opt k fields with Some v -> v <> "" | None -> false in
                       if has "cue" && has "lesson" && has "evidence" then
                         sel.experience <- fields @ (match edits with Some e -> [ ("edits", e) ] | None -> []));
                  persist sel (sel_dir work_dir sel) chosen.run_dir)))
