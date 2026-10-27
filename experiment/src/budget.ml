type kind = Rollout | Session
type plan = { mode : Spec.mode; k : int; rollouts : string list; sessions : string list }

let expected_rollouts k = 4 * k
let expected_sessions k = 3 * k
let range k f = List.init k (fun i -> f (i + 1))

let finals mode k =
  match mode with Spec.Parallel -> range k (Printf.sprintf "agg%d") | Spec.Sequential -> range k (Printf.sprintf "c%d")

let plan mode k =
  if k < 1 then invalid_arg (Printf.sprintf "k must be positive, got %d" k);
  let bases = range k (Printf.sprintf "base%d") in
  let candidates =
    List.concat (range k (fun i -> [ Printf.sprintf "inv%d" i; Printf.sprintf "dom%d" i ]))
  in
  let sessions =
    match mode with
    | Spec.Parallel -> candidates @ finals mode k
    | Spec.Sequential ->
        List.concat (range k (fun t -> [ Printf.sprintf "inv%d" t; Printf.sprintf "dom%d" t; Printf.sprintf "c%d" t ]))
  in
  let rollouts =
    match mode with
    | Spec.Parallel -> bases @ candidates @ finals mode k
    | Spec.Sequential -> bases @ sessions
  in
  assert (List.length rollouts = expected_rollouts k && List.length sessions = expected_sessions k);
  { mode; k; rollouts; sessions }

exception Budget_error of string

module Ledger = struct
  type entry = { kind : kind; label : string; usd : float; cached : bool; attempts : int }
  type t = { plan : plan; task_id : string; lock : Mutex.t; mutable entries : entry list }

  let create plan ~task_id = { plan; task_id; lock = Mutex.create (); entries = [] }
  let kind_name = function Rollout -> "rollout" | Session -> "session"
  let planned t = function Rollout -> t.plan.rollouts | Session -> t.plan.sessions

  let fail t msg =
    raise
      (Budget_error
         (Printf.sprintf "%s%d %s: %s" (Spec.mode_token t.plan.mode) t.plan.k t.task_id msg))

  let record t kind ?(usd = 0.) ?(cached = false) ?(attempts = 1) label =
    Mutex.lock t.lock;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.lock) @@ fun () ->
    if not (List.mem label (planned t kind)) then
      fail t (Printf.sprintf "%s %S is not in the plan (%s)" (kind_name kind) label (String.concat ", " (planned t kind)));
    if List.exists (fun e -> e.kind = kind && e.label = label) t.entries then
      fail t
        (Printf.sprintf
           "DUPLICATE %s label %S -- two stages wrote the same run id and one silently overwrote the other"
           (kind_name kind) label);
    t.entries <- { kind; label; usd; cached; attempts } :: t.entries

  let labels t kind = List.rev (List.filter_map (fun e -> if e.kind = kind then Some e.label else None) t.entries)
  let r t = List.length (labels t Rollout)
  let p t = List.length (labels t Session)
  let sum t f = Float.round (List.fold_left (fun a e -> if f e then a +. e.usd else a) 0. t.entries *. 1e6) /. 1e6
  let usd t = sum t (fun _ -> true)

  let close t =
    let missing kind = List.filter (fun l -> not (List.mem l (labels t kind))) (planned t kind) in
    match (missing Rollout, missing Session) with
    | [], [] -> ()
    | mr, ms ->
        fail t
          (Printf.sprintf "R=%d (want %d), P=%d (want %d); missing rollouts [%s], sessions [%s]" (r t)
             (expected_rollouts t.plan.k) (p t) (expected_sessions t.plan.k) (String.concat ", " mr)
             (String.concat ", " ms))

  let to_json t =
    Json.Assoc
      [
        ("mode", Json.String (Spec.mode_token t.plan.mode));
        ("task_id", Json.String t.task_id);
        ("k", Json.Int t.plan.k);
        ("R", Json.Int (r t));
        ("expected_R", Json.Int (expected_rollouts t.plan.k));
        ("P", Json.Int (p t));
        ("session_attempts", Json.Int (List.fold_left (fun a e -> if e.kind = Session then a + e.attempts else a) 0 t.entries));
        ("expected_P", Json.Int (expected_sessions t.plan.k));
        ("usd", Json.Float (usd t));
        ("rollout_usd", Json.Float (sum t (fun e -> e.kind = Rollout)));
        ("session_usd", Json.Float (sum t (fun e -> e.kind = Session)));
        ("rollouts", Json.strings (labels t Rollout));
        ("sessions", Json.strings (labels t Session));
      ]
end
