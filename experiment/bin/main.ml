(* harness2-ml: the OCaml prototype's command line (Python: harness2-demo, harness2 --help). *)

open Harness2_ml

let usage =
  "harness2-ml demo [--output DIR] [--k K] [--mode parallel|sequential|both] [--prompts builtin|python]\n\
   harness2-ml plan --k K [--mode parallel|sequential]\n\
   harness2-ml ids --task ID --k K --mode parallel|sequential LABEL...\n"

let rec flags acc = function
  | f :: v :: rest when String.length f > 2 && String.sub f 0 2 = "--" -> flags ((f, v) :: acc) rest
  | rest -> (acc, rest)

let die msg = prerr_string (msg ^ "\n" ^ usage); exit 2
let get fs name default = Option.value (List.assoc_opt name fs) ~default
let modes_of = function
  | "both" -> Spec.all_modes
  | s -> (match Spec.mode_of_string s with Ok m -> [ m ] | Error e -> die e)

let int_flag fs name default = match int_of_string_opt (get fs name default) with Some k when k >= 1 -> k | _ -> die (name ^ " must be a positive integer")

let demo fs =
  let k = int_flag fs "--k" "2" in
  let modes = modes_of (get fs "--mode" "both") in
  (match get fs "--prompts" "builtin" with
   | "builtin" -> ()
   | "python" -> Prompts.source := Prompts.Python_export { script = Filename.concat (Filename.dirname Sys.executable_name) "../../../scripts/export_prompt.py" }
   | s -> die ("unknown --prompts " ^ s));
  let root =
    let o = get fs "--output" "runs/demo" in
    if Filename.is_relative o then Filename.concat (Sys.getcwd ()) o else o
  in
  let adapter, executions = Demo.make root in
  let prop = Demo.proposer () in
  let result =
    Schedule.run_domain "accounting" (adapter.tasks ()) k ~adapter ~prop ~runs_root:adapter.spec.runs_root
      ~library_root:(Filename.concat (Filename.concat root "library") (Printf.sprintf "k%d" k)) ~modes ()
  in
  let result = match result with Json.Assoc kv -> Json.Assoc (kv @ [ ("execution_count", Json.Int (executions ())); ("editor_calls", Json.Int (prop.calls ())) ]) | j -> j in
  let report = Filename.concat root "demo.json" in
  Fs.write report (Json.to_string result);
  let n key = match result with Json.Assoc kv -> (match List.assoc key kv with Json.Int i -> i | _ -> 0) | _ -> 0 in
  Printf.printf "Local demo: %d tasks completed; %d failed. %s\n" (n "done") (n "failed") report;
  exit (if n "failed" > 0 then 1 else 0)

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
  let task_id = get fs "--task" "" and k = int_flag fs "--k" "1" in
  List.iter (fun (a, l) -> Printf.printf "%s %s\n" a l) (Selection.assign_ids labels ~task_id ~k ~mode)

let () =
  match Array.to_list Sys.argv with
  | _ :: "demo" :: rest -> demo (fst (flags [] rest))
  | _ :: "plan" :: rest -> plan (fst (flags [] rest))
  | _ :: "ids" :: rest -> let fs, labels = flags [] rest in ids fs labels
  | _ -> print_string usage
