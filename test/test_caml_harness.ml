(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Regressions for the contracts the OCaml port enforces (Python: tests/test_workflow.py). *)

open Caml_harness

let failures = ref 0

let check name cond =
  Printf.printf "%s %s\n%!" (if cond then "ok  " else "FAIL") name;
  if not cond then incr failures

let raises f = match f () with _ -> false | exception _ -> true

let tmp () =
  let d = Filename.temp_file "h2ml-test" "" in
  Sys.remove d;
  Fs.mkdir_p d;
  d

let tree kv = List.fold_left (fun t (k, v) -> Tree.SMap.add k v t) Tree.SMap.empty kv

let budget () =
  List.iter
    (fun mode ->
      List.iter
        (fun k ->
          let p = Budget.plan mode k in
          check (Printf.sprintf "plan %s k=%d is R=4k P=3k" (Spec.mode_name mode) k)
            (List.length p.rollouts = 4 * k && List.length p.sessions = 3 * k
            && List.length (List.sort_uniq compare p.rollouts) = 4 * k))
        [ 1; 2; 5 ])
    Spec.all_modes;
  check "k=0 is refused" (raises (fun () -> Budget.plan Spec.Parallel 0));
  let l = Budget.Ledger.create (Budget.plan Spec.Parallel 1) ~task_id:"t" in
  Budget.Ledger.record l Budget.Rollout "base1";
  check "a duplicate rollout label is refused" (raises (fun () -> Budget.Ledger.record l Budget.Rollout "base1"));
  check "a label outside the plan is refused" (raises (fun () -> Budget.Ledger.record l Budget.Rollout "agg2"));
  check "closing an incomplete ledger is refused" (raises (fun () -> Budget.Ledger.close l))

let ids () =
  let got = Selection.assign_ids [ "agg1"; "agg2"; "agg3" ] ~task_id:"ledger-1" ~k:3 ~mode:Spec.Parallel in
  check "anonymous ids match the Python release" (got = [ ("A", "agg3"); ("B", "agg1"); ("C", "agg2") ]);
  check "anon id 26 is AA" (Selection.anon_id 26 = "AA");
  check "sha1 known vector" (Sha1.hex "abc" = "a9993e364706816aba3e25717850c26c9cd0d89d")

let surface () =
  let s = Tree.opencode in
  check "systemprompt.md is c1" (Tree.classify s "systemprompt.md" = Some Tree.System_prompt);
  check "skills/x/SKILL.md is a skill" (Tree.classify s "skills/doc_review/SKILL.md" = Some (Tree.Skill "doc_review"));
  check "plugin/guard.ts is c8" (Option.map Tree.component_id (Tree.classify s "plugin/guard.ts") = Some "c8");
  check "uppercase script names are off the surface" (Tree.classify s "scripts/Check.py" = None);
  check "path escapes are off the surface" (Tree.classify s "../systemprompt.md" = None);
  let bad = tree [ ("systemprompt.md", "Use python scripts/missing.py"); ("scripts/broken.py", "def f(:\n") ] in
  (match Tree.validate s bad with
   | Ok _ -> check "invalid tree is rejected" false
   | Error es ->
       check "a script that does not compile is reported" (List.exists (Fs.contains ~sub:"does not compile") es);
       check "an invoked but missing script is reported" (List.exists (Fs.contains ~sub:"scripts/missing.py") es));
  let skill = tree [ ("systemprompt.md", "Be careful."); ("skills/totals/SKILL.md", "---\nname: totals\ndescription: a ledger has credits\n---\n") ] in
  check "an untriggered skill is rejected" (Result.is_error (Tree.validate s skill));
  let repaired, fixed = Tree.autotrigger s skill in
  check "autotrigger adds the trigger line" (fixed = [ "totals" ] && Result.is_ok (Tree.validate s repaired))

let guards () =
  let adapter, _ = Demo.make (tmp ()) in
  let d = tmp () in
  Fs.write (Fs.( / ) d "task.md") "work";
  check "a clean directory seals" (Result.is_ok (Context.seal d ~leak_globs:adapter.spec.leak_globs));
  Fs.write (Fs.( / ) d "nested/reference_answer.txt") "42";
  check "an answer-key path is refused" (Result.is_error (Context.seal d ~leak_globs:adapter.spec.leak_globs));
  let d2 = tmp () in
  Fs.write (Fs.( / ) d2 "rollouts/base1.md") "{\"pass_rate\": 1.0}";
  check "a grader verdict in content is refused" (Result.is_error (Context.seal d2 ~leak_globs:[]));
  check "a grader verdict in a harness tree is caught" (Context.tree_grader_verdict (tree [ ("guardrails.md", "deterministic_eval_result") ]) <> None)

let demo_runs () =
  let root = tmp () in
  let adapter, executions = Demo.make root in
  let prop = Demo.proposer () in
  let out = Schedule.run_domain "accounting" (adapter.tasks ()) 1 ~adapter ~prop ~runs_root:adapter.spec.runs_root ~library_root:(Fs.( / ) root "library") () in
  let field k = match out with Json.Assoc kv -> List.assoc k kv | _ -> Json.Null in
  check "demo k=1 completes both tasks" (field "done" = Json.Int 2 && field "failed" = Json.Int 0);
  (* k=1: per task 1 base + 3 per mode = 7 executions; 3 stages + 1 reflection per mode = 8 calls *)
  check "demo k=1 execution and call counts" (executions () = 14 && prop.calls () = 16)

let roles_on bus agent_for =
  List.iter (fun role -> A2a.Bus.register bus (agent_for role)) [ Agents.improver; Agents.selector; Agents.reflector ]

let jev_unwired () =
  Unix.putenv Jev.env_cmd "";
  let root = tmp () in
  let adapter, _ = Demo.make root in
  let bus = A2a.Bus.create () in
  roles_on bus (fun role -> Jev.agent ~as_:role ());
  let prop = Agents.via_bus bus { Spec.kind = Spec.Jev; model = "jev"; effort = "high"; steps = 1; timeout = 1 } in
  let lib = { Library.root = Fs.( / ) root "lib"; domain = "accounting"; surface = adapter.surface } in
  let r = Schedule.run_task "ledger-1" 2 ~adapter ~prop ~runs_root:adapter.spec.runs_root ~libraries:[ (Spec.Parallel, lib) ] ~modes:[ Spec.Parallel ] () in
  check "an unconfigured Jev agent degrades to fallbacks, not a crash" (r.status = "partial" && List.length r.modes = 1);
  check "every failed exchange is still on the bus" (List.for_all (fun (e : A2a.Bus.entry) -> e.response.state = A2a.Failed) (A2a.Bus.entries bus) && A2a.Bus.entries bus <> [])

let a2a () =
  let m = A2a.user_message ~context_id:"ctx-1" [ A2a.Text "hi"; A2a.Data (Json.Assoc [ ("x", Json.Int 1) ]); A2a.File { name = "a.txt"; uri = "file:///a.txt" } ] in
  let t = A2a.reply_task { m with task_id = Some "task-1" } [ A2a.Text "done" ] in
  let back = A2a.task_of_json (Json.parse (Json.to_string (A2a.task_json t))) in
  check "a task survives a JSON round trip" (back = t);
  let bus = A2a.Bus.create () in
  check "a message to an unknown agent is a failed task" ((A2a.Bus.send bus ~from_:"t" ~to_:"nobody" m).state = A2a.Failed);
  let leaky = tmp () in
  Fs.write (Fs.( / ) leaky "reference_answer.txt") "85.15";
  let adapter, _ = Demo.make (tmp ()) in
  roles_on bus (fun role -> Agents.serve ~leak_globs:adapter.spec.leak_globs ~card:(Agents.card_for role ~url:"local:test") (Demo.proposer ()));
  let req = A2a.user_message ~context_id:"c" [ A2a.Text "edit"; A2a.Data (Agents.request_data ~label:"inv1.a1" ~context_dir:leaky ~harvest:None) ] in
  check "a receiving agent rejects evidence carrying an answer key" ((A2a.Bus.send bus ~from_:"t" ~to_:Agents.improver req).state = A2a.Rejected);
  let script = Filename.concat (Filename.concat (Sys.getcwd ()) "../scripts") "stdio_agent_example.py" in
  let remote = A2a.stdio ~card:(Jev.card ~as_:"remote") [ "python3"; "-I"; script ] in
  A2a.Bus.register bus remote;
  let ask = A2a.user_message ~context_id:"e" [ A2a.Text "DELIVERABLE:\nTotal: 1.00\n\nAnswer with a verdict" ] in
  let t = A2a.Bus.send bus ~from_:"t" ~to_:"remote" ask in
  check "a subprocess agent answers over JSON-RPC stdio" (t.state = A2a.Completed && Fs.contains ~sub:"pass" (A2a.text_of (List.concat_map (fun (a : A2a.artifact) -> a.parts) t.artifacts)))

(* The same workflow over the A2A bus and in-process must adopt the same harnesses. *)
let a2a_parity () =
  let run via =
    let root = tmp () in
    let adapter, _ = Demo.make root in
    let editor = Demo.proposer () in
    let bus = A2a.Bus.create () in
    Agents.register_roles bus editor;
    let prop = if via then Agents.via_bus bus editor.channel else editor in
    ignore (Schedule.run_domain "accounting" (adapter.tasks ()) 2 ~adapter ~prop ~runs_root:adapter.spec.runs_root ~library_root:(Fs.( / ) root "lib") ());
    let lib = Fs.( / ) root "lib" in
    (List.map (fun rel -> (rel, Fs.read (Fs.( / ) lib rel))) (Fs.walk lib), List.length (A2a.Bus.entries bus))
  in
  let direct, n0 = run false and bused, n1 = run true in
  check "refinement over A2A adopts the same harnesses and lessons" (direct = bused && direct <> []);
  (* k=2, two tasks, two modes: 6 stages + 1 selection + 1 reflection per mode per task *)
  check "every role call went over the bus" (n0 = 0 && n1 = 32)

let evals () =
  let root = tmp () in
  let adapter, _ = Demo.make root in
  let bus = A2a.Bus.create () in
  Agents.register_roles bus (Demo.proposer ());
  A2a.Bus.register bus (Demo.judge_agent ());
  let suite = Demo.eval_suite () in
  let finished = ref [] in
  ignore (Schedule.run_domain ~on_task:(fun r -> finished := r :: !finished) "accounting" (adapter.tasks ()) 2 ~adapter ~prop:(Agents.via_bus bus (Demo.proposer ()).channel) ~runs_root:adapter.spec.runs_root ~library_root:(Fs.( / ) root "lib") ());
  let rows ?bus () =
    List.concat_map
      (fun (r : Schedule.task_result) ->
        let case = List.find (fun (c : Eval.case) -> c.task_id = r.task_id) suite.cases in
        Eval.score ?bus case ~subject:"base1" (List.hd r.base_runs) ~adapter :: List.map (fun (m, c) -> Eval.score ?bus case ~subject:(Spec.mode_name m ^ ":x") c ~adapter) r.chosen)
      !finished
  in
  let report = Eval.report (rows ~bus ()) in
  let g name = List.find (fun (s : Eval.summary) -> s.group = name) report in
  check "the base harness scores 50% partial, 0% all-pass" ((g "base").mean_partial = Some 0.5 && (g "base").all_pass_rate = Some 0.);
  check "both refined modes score 100%" ((g "parallel").mean_partial = Some 1.0 && (g "sequential").all_pass_rate = Some 1.0);
  let no_judge = Eval.report (rows ()) in
  check "a criterion with no judge is unscored, not zero" (List.for_all (fun (s : Eval.summary) -> s.scored = 0 && s.mean_partial = None) no_judge);
  let d = tmp () in
  Fs.write (Fs.( / ) d "judged.json") (Json.to_string (Json.List (List.map Eval.row_json (rows ~bus ()))));
  check "eval output can never be sealed into agent evidence" (Result.is_error (Context.seal d ~leak_globs:[]));
  let path = Fs.( / ) d "suite.json" in
  Fs.write path (Json.to_string (Eval.suite_json suite));
  check "an eval suite survives a file round trip" (Eval.load path = Ok suite)

let () =
  budget ();
  ids ();
  surface ();
  guards ();
  demo_runs ();
  jev_unwired ();
  a2a ();
  a2a_parity ();
  evals ();
  if !failures > 0 then (Printf.printf "%d FAILED\n" !failures; exit 1) else print_endline "all passed"
