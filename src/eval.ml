(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Evals for agents: criteria-based grading of what a workflow delivered.

   Three rules carried over from Harness2:
   - Grading happens AFTER selection and its output never enters an agent's evidence. Eval
     records use the same keys the leak guard treats as grader verdicts ("pass_rate", ...),
     so if one were ever copied into a context, sealing that context would fail.
   - A criterion that cannot be judged is [Unscored], and so is the run: it is reported
     separately, never counted as zero.
   - Scores are Partial (weighted fraction of criteria passed) and All-pass, as in LAB.

   A criterion can be checked deterministically or by an eval agent over A2A, which is
   where a model-backed judge (Jev, or any other) plugs in. *)

open Fs

type check =
  | Contains of string
  | Matches of string (* Str regular expression, searched anywhere in the deliverable *)
  | Equals of string (* exact match after trimming *)
  | Command of string list (* the deliverable's path is appended; exit 0 passes *)
  | Agent_judge of { agent : string; rubric : string }

type criterion = { id : string; description : string; weight : float; check : check }
type case = { task_id : string; criteria : criterion list }
type suite = { name : string; cases : case list }
type verdict = Pass | Fail | Unscored of string

type row = {
  task : string;
  subject : string; (* "base1", or "<mode>:<chosen label>" *)
  run_id : string;
  verdicts : (string * verdict) list;
  partial : float option; (* None = unscored *)
  all_pass : bool option;
}

(* ---- suite files ----------------------------------------------------------------------- *)

let check_json = function
  | Contains s -> Json.Assoc [ ("kind", Json.String "contains"); ("value", Json.String s) ]
  | Matches s -> Json.Assoc [ ("kind", Json.String "matches"); ("value", Json.String s) ]
  | Equals s -> Json.Assoc [ ("kind", Json.String "equals"); ("value", Json.String s) ]
  | Command argv -> Json.Assoc [ ("kind", Json.String "command"); ("argv", Json.strings argv) ]
  | Agent_judge { agent; rubric } -> Json.Assoc [ ("kind", Json.String "agent"); ("agent", Json.String agent); ("rubric", Json.String rubric) ]

let check_of_json j =
  let s = A2a.str in
  match s "kind" j with
  | "contains" -> Ok (Contains (s "value" j))
  | "matches" -> Ok (Matches (s "value" j))
  | "equals" -> Ok (Equals (s "value" j))
  | "command" -> Ok (Command (List.filter_map (function Json.String a -> Some a | _ -> None) (A2a.list "argv" j)))
  | "agent" -> Ok (Agent_judge { agent = s "agent" j; rubric = s "rubric" j })
  | k -> Error ("unknown check kind " ^ k)

let suite_json s =
  Json.Assoc
    [ ("name", Json.String s.name);
      ( "cases",
        Json.List
          (List.map
             (fun c ->
               Json.Assoc
                 [ ("task_id", Json.String c.task_id);
                   ( "criteria",
                     Json.List
                       (List.map (fun r -> Json.Assoc [ ("id", Json.String r.id); ("description", Json.String r.description); ("weight", Json.Float r.weight); ("check", check_json r.check) ]) c.criteria) ) ])
             s.cases) ) ]

let load path =
  match Json.parse (read path) with
  | exception e -> Error (Printexc.to_string e)
  | j -> (
      let crit c =
        Result.map
          (fun check -> { id = A2a.str "id" c; description = A2a.str "description" c; weight = (match Json.member "weight" c with Some _ as w -> Json.to_float w | None -> 1.); check })
          (check_of_json (Option.value (Json.member "check" c) ~default:Json.Null))
      in
      let rec all f = function [] -> Ok [] | x :: xs -> Result.bind (f x) (fun y -> Result.map (fun ys -> y :: ys) (all f xs)) in
      match all (fun c -> Result.map (fun criteria -> { task_id = A2a.str "task_id" c; criteria }) (all crit (A2a.list "criteria" c))) (A2a.list "cases" j) with
      | Ok cases -> Ok { name = A2a.str "name" j; cases }
      | Error e -> Error e)

(* ---- grading ---------------------------------------------------------------------------- *)

let verdict_rx = Str.regexp "```verdict[ \t\n]*\\(pass\\|fail\\)[ \t\n]*```"

let judge_with_agent bus ~agent ~rubric ~(c : criterion) ~deliverable =
  match bus with
  | None -> Unscored "no A2A bus for agent-judged criteria"
  | Some bus -> (
      let msg =
        A2a.user_message ~context_id:(A2a.fresh "eval")
          [ A2a.Text (Printf.sprintf "Judge one criterion.\n\nCRITERION: %s\n\nRUBRIC: %s\n\nDELIVERABLE:\n%s\n\nAnswer with a ```verdict block containing pass or fail." c.description rubric deliverable);
            A2a.Data (Json.Assoc [ ("criterion", Json.String c.id) ]) ]
      in
      let t = A2a.Bus.send bus ~from_:"eval" ~to_:agent msg in
      if t.state <> A2a.Completed then Unscored (Printf.sprintf "judge %s: %s %s" agent (A2a.state_name t.state) t.detail)
      else
        match Rx.search_group verdict_rx (A2a.text_of (List.concat_map (fun (a : A2a.artifact) -> a.parts) t.artifacts)) with
        | Some "pass" -> Pass
        | Some _ -> Fail
        | None -> Unscored ("judge " ^ agent ^ " returned no ```verdict block"))

let grade ?bus (c : criterion) ~deliverable_path ~deliverable =
  let bool b = if b then Pass else Fail in
  match c.check with
  | Contains s -> bool (contains ~sub:s deliverable)
  | Equals s -> bool (trim deliverable = trim s)
  | Matches re -> (
      match Str.regexp re with
      | exception e -> Unscored ("bad regex: " ^ Printexc.to_string e)
      | rx -> bool (Rx.locked (fun () -> match Str.search_forward rx deliverable 0 with _ -> true | exception Not_found -> false)))
  | Command argv -> (
      match run (argv @ [ deliverable_path ]) with
      | 0, _, _ -> Pass
      | 1, _, _ -> Fail
      | code, _, err -> Unscored (Printf.sprintf "command exited %d: %s" code (trim err)))
  | Agent_judge { agent; rubric } -> judge_with_agent bus ~agent ~rubric ~c ~deliverable

let score ?bus (case : case) ~subject (rv : Spec.run_view) ~(adapter : Spec.adapter) =
  let deliverable = if rv.delivered then (try Some (adapter.deliverable_text rv.run_dir) with _ -> None) else None in
  let verdicts =
    List.map
      (fun c ->
        ( c.id,
          match deliverable with
          | None -> Fail (* nothing delivered is a judged failure, not a judge failure *)
          | Some d -> grade ?bus c ~deliverable_path:(rv.run_dir / "answer.txt") ~deliverable:d ))
      case.criteria
  in
  let unscored = List.exists (fun (_, v) -> match v with Unscored _ -> true | _ -> false) verdicts in
  let total = List.fold_left (fun a c -> a +. c.weight) 0. case.criteria in
  let passed = List.fold_left (fun a c -> if List.assoc c.id verdicts = Pass then a +. c.weight else a) 0. case.criteria in
  { task = case.task_id; subject; run_id = rv.run_id; verdicts;
    partial = (if unscored || total = 0. then None else Some (passed /. total));
    all_pass = (if unscored then None else Some (List.for_all (fun (_, v) -> v = Pass) verdicts)) }

(* ---- reporting ---------------------------------------------------------------------------- *)

let verdict_json = function
  | Pass -> Json.String "pass"
  | Fail -> Json.String "fail"
  | Unscored why -> Json.Assoc [ ("unscored", Json.String why) ]

let row_json r =
  Json.Assoc
    [ ("task", Json.String r.task); ("subject", Json.String r.subject); ("run_id", Json.String r.run_id);
      ("verdicts", Json.Assoc (List.map (fun (k, v) -> (k, verdict_json v)) r.verdicts));
      ("pass_rate", match r.partial with Some p -> Json.Float p | None -> Json.Null);
      ("all_pass", match r.all_pass with Some b -> Json.Bool b | None -> Json.Null) ]

type summary = { group : string; n : int; scored : int; mean_partial : float option; all_pass_rate : float option }

let summarise group rows =
  let scored = List.filter_map (fun r -> Option.map (fun p -> (p, r.all_pass = Some true)) r.partial) rows in
  let ns = List.length scored in
  let mean f = if ns = 0 then None else Some (List.fold_left (fun a x -> a +. f x) 0. scored /. float ns) in
  { group; n = List.length rows; scored = ns; mean_partial = mean fst; all_pass_rate = mean (fun (_, b) -> if b then 1. else 0.) }

let group_of subject = match String.index_opt subject ':' with Some i -> String.sub subject 0 i | None -> "base"

let report rows =
  let groups = List.sort_uniq compare (List.map (fun r -> group_of r.subject) rows) in
  List.map (fun g -> summarise g (List.filter (fun r -> group_of r.subject = g) rows)) groups

let summary_json s =
  let f = function Some x -> Json.Float (Float.round (x *. 10000.) /. 10000.) | None -> Json.Null in
  Json.Assoc [ ("group", Json.String s.group); ("n", Json.Int s.n); ("scored", Json.Int s.scored); ("unscored", Json.Int (s.n - s.scored)); ("partial", f s.mean_partial); ("all_pass", f s.all_pass_rate) ]

let pct = function Some x -> Printf.sprintf "%5.1f%%" (100. *. x) | None -> "   n/a"

let print_report summaries =
  Printf.printf "%-12s %4s %7s %9s %9s\n" "group" "n" "scored" "partial" "all-pass";
  List.iter (fun s -> Printf.printf "%-12s %4d %7d %9s %9s\n" s.group s.n s.scored (pct s.mean_partial) (pct s.all_pass_rate)) summaries;
  match List.find_opt (fun s -> s.group = "base") summaries with
  | Some { mean_partial = Some b; _ } ->
      List.iter
        (fun s -> match s.mean_partial with Some p when s.group <> "base" -> Printf.printf "%s vs base: %+.1f points partial\n" s.group (100. *. (p -. b)) | _ -> ())
        summaries
  | _ -> ()
