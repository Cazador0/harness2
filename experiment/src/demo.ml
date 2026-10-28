(* The deterministic local benchmark (Python: harness2/demo.py), ported one to one: two
   ledger tasks, a base harness whose script drops credits, real Python executions, and a
   scripted editor/selector/reflector in place of a model. *)

open Fs

let base_script =
  "import csv\n\
   import sys\n\
   from decimal import Decimal\n\
   \n\
   with open(sys.argv[1]) as source:\n\
  \    amounts = [Decimal(row['amount']) for row in csv.DictReader(source)]\n\
   total = sum((amount for amount in amounts if amount > 0), Decimal(0))\n\
   print(f'Total: {total:.2f}')\n"

let ledgers = [ ("ledger-1", "100.25\n-20.10\n5.00\n"); ("ledger-2", "35.50\n-10.25\n-5.00\n") ]

let make root =
  let executions = ref 0 and m = Mutex.create () in
  let task_files id = root / "sources" / id in
  let base_harness () = root / "base" in
  let surface = Tree.opencode in
  let base =
    List.fold_left (fun t (a, _) -> Tree.SMap.add a "" t) Tree.SMap.empty surface.always_on
    |> Tree.SMap.add "systemprompt.md" "Reconcile the ledger using python scripts/summarize.py.\n"
    |> Tree.SMap.add "scripts/summarize.py" base_script
  in
  ignore (Tree.write_tree ~stubs:false surface base (base_harness ()));
  List.iter (fun (id, amounts) -> write (task_files id / "ledger.csv") ("amount\n" ^ amounts)) ledgers;
  let execute ~task_id ~harness_dir ~run_id =
    Mutex.lock m;
    incr executions;
    Mutex.unlock m;
    let run_dir = root / "executions" / run_id in
    mkdir_p run_dir;
    let script = Option.value harness_dir ~default:(base_harness ()) / "scripts/summarize.py" in
    let code, out, err = run [ "python3"; script; task_files task_id / "ledger.csv" ] in
    if code <> 0 then failwith (Printf.sprintf "CalledProcessError: exit %d: %s" code (trim err));
    write (run_dir / "answer.txt") out;
    write (run_dir / "trajectory.md") ("[ACTION] Run scripts/summarize.py on ledger.csv\n[OBSERVATION]\n" ^ out);
    run_dir
  in
  let adapter : Spec.adapter =
    {
      spec =
        {
          name = "demo"; runs_root = root / "runs"; prompts = Spec.prompts "reconcile signed amounts in a transaction ledger";
          leak_globs = [ "reference_answer.txt" ]; obs_trunc = 50_000; allow_subagents = false; reserved_scripts = [];
          proposer_deliverables = Spec.Contents;
        };
      substrate = "oc"; surface;
      tasks = (fun () -> List.map fst ledgers);
      domain_of = (fun _ -> "accounting");
      task_prompt = (fun _ -> "Sum every signed amount in ledger.csv. Return Total: with two decimal places.");
      task_files = (fun id -> Some (task_files id));
      base_harness;
      validate_tree = (fun t -> if Tree.SMap.mem "scripts/summarize.py" t then Ok () else Error "The local executor requires scripts/summarize.py");
      execute;
      delivered = (fun rd -> is_file (rd / "answer.txt"));
      trajectory = (fun rd ~obs_trunc:_ -> read (rd / "trajectory.md"));
      deliverable_text = (fun rd -> read (rd / "answer.txt"));
      deliverable_files = Some (fun rd -> [ ("answer.txt", read (rd / "answer.txt")) ]);
    }
  in
  (adapter, fun () -> !executions)

(* Exact two-decimal arithmetic, so the selector computes the same total as Python's Decimal. *)
let cents s =
  let s = trim s in
  let neg = starts_with ~prefix:"-" s in
  let s = if neg || starts_with ~prefix:"+" s then String.sub s 1 (String.length s - 1) else s in
  let whole, frac = match String.index_opt s '.' with Some i -> (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)) | None -> (s, "") in
  let frac = String.sub (frac ^ "00") 0 2 in
  let v = (int_of_string (if whole = "" then "0" else whole) * 100) + int_of_string frac in
  if neg then -v else v

let format_cents c = Printf.sprintf "%s%d.%02d" (if c < 0 then "-" else "") (Stdlib.( / ) (abs c) 100) (abs c mod 100)

let proposer () : Proposer.t =
  let bump, calls = Proposer.counter () in
  let channel = { Spec.kind = Spec.Opencode; model = "local/deterministic"; effort = "high"; steps = 120; timeout = 3600 } in
  let call ~mission:_ ctx ~label ~harvest:_ =
    bump ();
    let context = Context.root ctx in
    let reply ?workspace text = { Proposer.label; text; attempts = 1; cost_usd = 0.; cached = false; workspace } in
    if starts_with ~prefix:"select." label then begin
      let rows = List.tl (lines (read (context / "source/ledger.csv"))) in
      let expected = List.fold_left (fun a r -> a + cents r) 0 rows in
      let want = "Total: " ^ format_cents expected in
      let candidates = List.filter (fun f -> Filename.check_suffix f ".md") (List.sort compare (Array.to_list (Sys.readdir (context / "candidates")))) in
      let chosen = List.find (fun f -> contains ~sub:want (read (context / "candidates" / f))) candidates in
      reply (Printf.sprintf "<why>The signed total matches the source ledger.</why>\n```choice\n%s\n```" (Filename.chop_suffix chosen ".md"))
    end
    else if starts_with ~prefix:"experience." label then begin
      let changed = read (context / "harness/scripts/summarize.py") <> read (context / "base_harness/scripts/summarize.py") in
      reply
        ("<edits>\ncomponent: scripts/summarize.py\ncandidates: inv1\nchange: dropped the positive-only filter from the amount sum\nobserved: the probe total included the credits the base run omitted\nverdict: "
        ^ (if changed then "helped" else "no observed effect")
        ^ "\n</edits>\n\n"
        ^
        if changed then
          "<experience>\ncue: When a ledger includes credits and debits\nlesson: Include both signs when summing in scripts/summarize.py.\nevidence: The scripts/summarize.py row -- removing the positive-only filter changed the probe total to include the credits omitted by the base trajectory.\nconfidence: high for this observed arithmetic contrast\n</experience>"
        else "NO_ENTRY")
    end
    else begin
      let workspace = context / "harness" in
      let script = workspace / "scripts/summarize.py" in
      write script (replace_all ~sub:" if amount > 0" ~by:"" (read script));
      reply ~workspace "<notes>Keep signed amounts: the base total omitted credits in the source ledger.</notes>"
    end
  in
  { Proposer.channel; call; calls }
