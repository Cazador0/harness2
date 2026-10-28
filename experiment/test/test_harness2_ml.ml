(* Regressions for the contracts the OCaml port enforces (Python: tests/test_workflow.py). *)

open Harness2_ml

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

let jev_unwired () =
  Unix.putenv Jev.env_cmd "";
  let root = tmp () in
  let adapter, _ = Demo.make root in
  let lib = { Library.root = Fs.( / ) root "lib"; domain = "accounting"; surface = adapter.surface } in
  let r =
    Schedule.run_task "ledger-1" 2 ~adapter ~prop:(Jev.proposer ()) ~runs_root:adapter.spec.runs_root
      ~libraries:[ (Spec.Parallel, lib) ] ~modes:[ Spec.Parallel ] ()
  in
  check "an unwired Jev channel degrades to fallbacks, not a crash" (r.status = "partial" && List.length r.modes = 1)

let () =
  budget ();
  ids ();
  surface ();
  guards ();
  demo_runs ();
  jev_unwired ();
  if !failures > 0 then (Printf.printf "%d FAILED\n" !failures; exit 1) else print_endline "all passed"
