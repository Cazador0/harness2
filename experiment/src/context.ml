open Fs

type t = { root : string; layout : string }

let root t = t.root
let layout t = t.layout

type pool_entry = { label : string; harness_dir : string; rollout : Spec.run_view option }

let grader_verdict_markers =
  [
    "deterministic_eval_summary";
    "deterministic_eval_result";
    "judge_scope_and_deterministic_status";
    "Judge findings on the rendered result";
    "\"passed_count\"";
    "\"pass_rate\"";
    "\"test_pass_rate\"";
  ]

let scan_suffixes =
  [ ".md"; ".txt"; ".json"; ".csv"; ".tsv"; ".yaml"; ".yml"; ".html"; ".htm"; ".log"; ".py"; ".js";
    ".sh"; ".xml"; ".ini"; ".toml"; ".patch"; ".diff"; "" ]

let leak_paths dir patterns =
  if patterns = [] || not (is_dir dir) then []
  else List.filter (fun rel -> List.exists (fun pattern -> Glob.leak_match ~pattern rel) patterns) (walk dir)

let excerpt body where =
  let a = max 0 (where - 60) in
  String.sub body a (min (String.length body - a) (where + 120 - a))

let verdict_in ~what rel body =
  match List.find_opt (fun m -> contains ~sub:m rel) grader_verdict_markers with
  | Some m -> Some (Printf.sprintf "grader verdict would enter model context: %S matched marker %S in its NAME" rel m)
  | None when not (List.mem (suffix rel) scan_suffixes) -> None
  | None ->
      List.find_map
        (fun m ->
          Option.map
            (fun i -> Printf.sprintf "%s %S contains grader-verdict marker %S at offset %d (%S)" what rel m i (excerpt (body ()) i))
            (index_of ~sub:m (body ())))
        grader_verdict_markers

let grader_verdict dir =
  if not (is_dir dir) then None
  else List.find_map (fun rel -> verdict_in ~what:"context file" rel (fun () -> read (dir / rel))) (walk dir)

let tree_grader_verdict tree =
  Tree.SMap.fold
    (fun rel body acc -> match acc with Some _ -> acc | None -> verdict_in ~what:"harness file" rel (fun () -> body))
    tree None

let seal dir ~leak_globs =
  match leak_paths dir leak_globs with
  | _ :: _ as hits ->
      Error ("answer-key path(s) would enter model context: " ^ String.concat ", " (List.filteri (fun i _ -> i < 8) hits))
  | [] -> (
      match grader_verdict dir with
      | Some e -> Error (e ^ ". The tripwire fired -- this is a leak, not a false positive to widen around.")
      | None -> Ok { root = dir; layout = "" })

let copy_source (adapter : Spec.adapter) task_id root =
  match adapter.task_files task_id with
  | Some src when is_dir src ->
      List.fold_left
        (fun n rel ->
          if has_part "__pycache__" rel || List.exists (fun pattern -> Glob.leak_match ~pattern rel) adapter.spec.leak_globs then n
          else (write (root / "source" / rel) (read (src / rel)); n + 1))
        0 (walk src)
  | _ -> 0

let protect f = try Ok (f ()) with e -> Error (Printexc.to_string e)

let write_rollout dest (adapter : Spec.adapter) (r : Spec.run_view) =
  let failure =
    match protect (fun () -> adapter.trajectory r.run_dir ~obs_trunc:adapter.spec.obs_trunc) with
    | Ok text -> write (dest / "rollouts" / (r.label ^ ".md")) text; None
    | Error e -> write (dest / "rollouts" / (r.label ^ ".md")) ("(trajectory unavailable: " ^ e ^ ")"); Some (r.label ^ ": " ^ e)
  in
  let per_file = match adapter.deliverable_files with Some f -> (try f r.run_dir with _ -> []) | None -> [] in
  (match per_file with
   | [] ->
       let text = match protect (fun () -> adapter.deliverable_text r.run_dir) with Ok "" -> "(no deliverable produced)" | Ok t -> t | Error e -> "(deliverable unavailable: " ^ e ^ ")" in
       write (dest / "deliverables" / (r.label ^ ".md")) text
   | files ->
       let d = dest / "deliverables" / r.label in
       List.iter
         (fun (name, body) ->
           let safe = match replace_all ~sub:"/" ~by:"__" name with "" -> "unnamed" | s -> s in
           write (d / (safe ^ if ends_with ~suffix:".txt" safe then "" else ".txt")) body)
         files;
       write (d / "INDEX.md")
         (Printf.sprintf "# %s produced %d file(s)\n\n%s\n\nEach `.txt` is the artifact converted to text by the SAME reader the work\nis assessed through, so reason about correctness from these.\n"
            r.label (List.length files)
            (String.concat "\n" (List.map (fun (n, b) -> Printf.sprintf "- `%s`  (%d chars extracted)" n (String.length b)) files))));
  failure

(* A line diff (longest common subsequence) between the current harness and a candidate. *)
let line_diff ~from_name ~to_name a b =
  let a = Array.of_list (lines a) and b = Array.of_list (lines b) in
  let n = Array.length a and m = Array.length b in
  if a = b then ""
  else begin
    let l = Array.make_matrix (n + 1) (m + 1) 0 in
    for i = n - 1 downto 0 do
      for j = m - 1 downto 0 do
        l.(i).(j) <- (if a.(i) = b.(j) then l.(i + 1).(j + 1) + 1 else max l.(i + 1).(j) l.(i).(j + 1))
      done
    done;
    let buf = Buffer.create 256 in
    Buffer.add_string buf (Printf.sprintf "--- %s\n+++ %s\n" from_name to_name);
    let rec go i j =
      if i < n && j < m && a.(i) = b.(j) then (Buffer.add_string buf (" " ^ a.(i) ^ "\n"); go (i + 1) (j + 1))
      else if j < m && (i = n || l.(i).(j + 1) >= l.(i + 1).(j)) then (Buffer.add_string buf ("+" ^ b.(j) ^ "\n"); go i (j + 1))
      else if i < n then (Buffer.add_string buf ("-" ^ a.(i) ^ "\n"); go (i + 1) j)
    in
    go 0 0;
    Buffer.contents buf
  end

let write_pool dest (adapter : Spec.adapter) pool =
  List.map
    (fun (p : pool_entry) ->
      let d = dest / "pool" / p.label in
      mkdir_p d;
      if is_dir p.harness_dir then begin
        ignore (copy_tree p.harness_dir (d / "harness"));
        let reference = Tree.read_tree adapter.surface (dest / "harness") in
        let candidate = Tree.read_tree adapter.surface p.harness_dir in
        let names = List.sort_uniq compare (List.map fst (Tree.SMap.bindings reference @ Tree.SMap.bindings candidate)) in
        let get t k = Option.value (Tree.SMap.find_opt k t) ~default:"" in
        write (d / "harness.diff")
          (String.concat "" (List.map (fun k -> line_diff ~from_name:("current/" ^ k) ~to_name:(p.label ^ "/" ^ k) (get reference k) (get candidate k)) names))
      end;
      Option.iter
        (fun (r : Spec.run_view) ->
          match protect (fun () -> (adapter.trajectory r.run_dir ~obs_trunc:adapter.spec.obs_trunc, adapter.deliverable_text r.run_dir)) with
          | Ok (traj, produced) ->
              write (d / "rollout.md") traj;
              write (d / "produced.md") (if produced = "" then "(nothing produced)" else produced)
          | Error e -> write (d / "rollout.md") ("(unavailable: " ^ e ^ ")"))
        p.rollout;
      p.label)
    pool

let make_layout ~source ~decisions ~rollouts ~deliverables ~harness_files ~pool ~library =
  let ls = ref [ "context/task.md                  the task as the agent received it" ] in
  let add s = ls := s :: !ls in
  if source > 0 then add "context/source/                 task source materials";
  if decisions > 0 then add "context/decisions/              earlier edits and composition decisions";
  if rollouts <> [] then begin
    let shown = List.filteri (fun i _ -> i < 6) rollouts in
    let more = if List.length rollouts > 6 then Printf.sprintf " (+%d more)" (List.length rollouts - 6) else "" in
    add ("context/rollouts/               FULL trajectories: " ^ String.concat ", " (List.map (fun r -> r ^ ".md") shown) ^ more)
  end;
  if deliverables then add "context/deliverables/<label>/    the files each rollout produced, one per artifact (browse INDEX.md for the set)";
  if harness_files > 0 then add (Printf.sprintf "context/harness/                the harness you are editing (%d files)" harness_files);
  if pool <> [] then add (Printf.sprintf "context/pool/                   %d candidates, each with its harness and its rollout" (List.length pool));
  if library then add "context/library/                earlier tasks in this area -- browse INDEX.md first, then open what looks relevant";
  String.concat "\n" (List.rev !ls)

let build dest (adapter : Spec.adapter) task_id rollouts ?harness_dir ?library_dir ?(pool = []) ?(decisions = []) () =
  match
    protect (fun () ->
        rm_rf dest;
        mkdir_p dest;
        write (dest / "task.md") (adapter.task_prompt task_id);
        let source = copy_source adapter task_id dest in
        List.iter (fun (label, notes) -> write (dest / "decisions" / (label ^ ".md")) (if notes = "" then "No decision notes returned." else notes)) decisions;
        if rollouts <> [] then (mkdir_p (dest / "rollouts"); mkdir_p (dest / "deliverables"));
        let results = List.map (fun (r : Spec.run_view) -> (r.label, write_rollout dest adapter r)) rollouts in
        let got_r = List.filter_map (fun (l, f) -> if f = None then Some l else None) results in
        let failed = List.filter_map snd results in
        let harness_files = match harness_dir with Some h when is_dir h -> copy_tree h (dest / "harness") | _ -> 0 in
        let got_p = write_pool dest adapter pool in
        let library =
          match library_dir with
          | Some l when is_dir l && Sys.readdir l <> [||] -> ignore (copy_tree l (dest / "library")); true
          | _ -> false
        in
        if rollouts <> [] && got_r = [] then
          failwith ("no trajectory could be rendered for ANY rollout: " ^ String.concat "; " failed);
        make_layout ~source ~decisions:(List.length decisions) ~rollouts:got_r ~deliverables:(rollouts <> []) ~harness_files ~pool:got_p ~library)
  with
  | Error e -> Error e
  | Ok layout -> Result.map (fun t -> { t with layout }) (seal dest ~leak_globs:adapter.spec.leak_globs)

let mission t ~job =
  String.concat "\n"
    [
      Fs.trim job;
      "";
      "# YOUR EVIDENCE";
      "";
      "It is on disk, in `context/`. Read it -- do not answer from this message alone.";
      "";
      t.layout;
      "";
      "Every trajectory EVENT is present: the trajectory was not clipped to fit this mission. An \
       individual observation may contain an explicit renderer-truncation marker; that marker is \
       ours, not behavior by the solver. Do not diagnose it as a solver failure.";
      "";
      "Read `task.md` and the current harness first. Inventory every available rollout or candidate \
       and inspect each at least once before deciding. For a candidate, compare what changed from \
       its editing baseline, what behavior changed in its rollout, what improved, and what \
       regressed or remained unresolved. Then deep-read the evidence relevant to any edit. Cite the \
       specific trajectory moment behind every change; one you cannot trace to a moment is \
       speculation.";
    ]
