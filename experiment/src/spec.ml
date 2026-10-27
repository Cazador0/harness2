(* The benchmark seam (Python: core/spec.py). Strings that Python checks at runtime -- the
   mode token, the channel kind, the deliverables policy -- are variants here. *)

type mode = Parallel | Sequential

let all_modes = [ Parallel; Sequential ]
let mode_token = function Parallel -> "agg" | Sequential -> "seq"
let mode_name = function Parallel -> "parallel" | Sequential -> "sequential"

let mode_of_string = function
  | "agg" | "parallel" -> Ok Parallel
  | "seq" | "sequential" -> Ok Sequential
  | s -> Error (Printf.sprintf "unknown recursion mode %S; expected parallel or sequential" s)

(* `Jev` is the channel this port adds: see jev.ml. *)
type channel_kind = Opencode | Claude_cli | Jev

let channel_name = function Opencode -> "opencode" | Claude_cli -> "claude_cli" | Jev -> "jev"

type channel = { kind : channel_kind; model : string; effort : string; steps : int; timeout : int }

let channel ?(effort = "high") ?(steps = 120) ?(timeout = 3600) kind model =
  match kind with
  | Opencode when not (String.contains model '/') ->
      Error (Printf.sprintf "opencode channel needs a provider-prefixed model id, got %S" model)
  | Claude_cli when String.contains model '/' ->
      Error (Printf.sprintf "claude_cli channel takes a bare Anthropic id, got %S" model)
  | _ -> Ok { kind; model; effort; steps; timeout }

(* What the method knows about one finished rollout. Never carries a score. *)
type run_view = {
  label : string;
  run_id : string;
  run_dir : string;
  ok : bool;
  delivered : bool;
  cost_usd : float;
  error : string;
}

type deliverables_policy = Contents | Names

type bench_prompts = { work : string; domain_word : string; deliverable_word : string }

let prompts ?(domain_word = "domain") ?(deliverable_word = "deliverable") work = { work; domain_word; deliverable_word }

type bench_spec = {
  name : string;
  runs_root : string;
  prompts : bench_prompts;
  leak_globs : string list;
  obs_trunc : int;
  allow_subagents : bool;
  reserved_scripts : string list;
  proposer_deliverables : deliverables_policy;
}

(* A benchmark adapter: records of functions rather than a Python Protocol. [execute] raises
   on failure; the recursion turns that into a dead rollout, as Python does. *)
type adapter = {
  spec : bench_spec;
  substrate : string; (* namespace token: "oc" | "cx" *)
  surface : Tree.surface;
  tasks : unit -> string list;
  domain_of : string -> string;
  task_prompt : string -> string;
  task_files : string -> string option;
  base_harness : unit -> string;
  validate_tree : Tree.t -> (unit, string) result;
  execute : task_id:string -> harness_dir:string option -> run_id:string -> string;
  delivered : string -> bool;
  trajectory : string -> obs_trunc:int -> string;
  deliverable_text : string -> string;
  deliverable_files : (string -> (string * string) list) option;
}
