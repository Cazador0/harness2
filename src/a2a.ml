(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Agent-to-agent communication, shaped after the A2A protocol: agents publish an
   [Agent_card], exchange [message]s made of typed [part]s, and each request becomes a [task]
   with a lifecycle [state] and output [artifact]s. Requests travel as JSON-RPC 2.0
   ("message/send"), so an agent can live in-process or in another process (see [stdio]).

   The wire format follows the A2A shapes (kind-tagged parts, task status states, JSON-RPC
   methods). It has not been checked against an A2A conformance suite. *)

type role = User | Agent
type part = Text of string | Data of Json.t | File of { name : string; uri : string }

type message = {
  message_id : string;
  context_id : string;
  task_id : string option;
  role : role;
  parts : part list;
}

type state = Submitted | Working | Input_required | Completed | Failed | Canceled | Rejected
type artifact = { artifact_id : string; name : string; parts : part list }

type task = {
  id : string;
  context_id : string;
  state : state;
  history : message list;
  artifacts : artifact list;
  detail : string; (* the status message, e.g. why the task failed *)
}

type skill = { skill_id : string; skill_name : string; skill_description : string; tags : string list }

type card = {
  name : string;
  description : string;
  version : string;
  url : string; (* "local:<name>" in-process, "stdio:<cmd>" for a subprocess agent *)
  skills : skill list;
}

(* ---- JSON encoding ------------------------------------------------------------------- *)

let state_name = function
  | Submitted -> "submitted" | Working -> "working" | Input_required -> "input-required"
  | Completed -> "completed" | Failed -> "failed" | Canceled -> "canceled" | Rejected -> "rejected"

let state_of_name = function
  | "submitted" -> Submitted | "working" -> Working | "input-required" -> Input_required
  | "completed" -> Completed | "canceled" -> Canceled | "rejected" -> Rejected | _ -> Failed

let part_json = function
  | Text t -> Json.Assoc [ ("kind", Json.String "text"); ("text", Json.String t) ]
  | Data d -> Json.Assoc [ ("kind", Json.String "data"); ("data", d) ]
  | File { name; uri } -> Json.Assoc [ ("kind", Json.String "file"); ("file", Json.Assoc [ ("name", Json.String name); ("uri", Json.String uri) ]) ]

let str k j = Option.value (Json.to_string_opt (Json.member k j)) ~default:""
let list k j = match Json.member k j with Some (Json.List l) -> l | _ -> []

let part_of_json j =
  match str "kind" j with
  | "data" -> Data (Option.value (Json.member "data" j) ~default:Json.Null)
  | "file" -> let f = Option.value (Json.member "file" j) ~default:Json.Null in File { name = str "name" f; uri = str "uri" f }
  | _ -> Text (str "text" j)

let message_json m =
  Json.Assoc
    ([ ("kind", Json.String "message"); ("messageId", Json.String m.message_id); ("contextId", Json.String m.context_id);
       ("role", Json.String (match m.role with User -> "user" | Agent -> "agent")); ("parts", Json.List (List.map part_json m.parts)) ]
    @ match m.task_id with Some t -> [ ("taskId", Json.String t) ] | None -> [])

let message_of_json j =
  { message_id = str "messageId" j; context_id = str "contextId" j;
    task_id = (match str "taskId" j with "" -> None | t -> Some t);
    role = (if str "role" j = "agent" then Agent else User); parts = List.map part_of_json (list "parts" j) }

let artifact_json a = Json.Assoc [ ("artifactId", Json.String a.artifact_id); ("name", Json.String a.name); ("parts", Json.List (List.map part_json a.parts)) ]
let artifact_of_json j = { artifact_id = str "artifactId" j; name = str "name" j; parts = List.map part_of_json (list "parts" j) }

let task_json t =
  Json.Assoc
    [ ("kind", Json.String "task"); ("id", Json.String t.id); ("contextId", Json.String t.context_id);
      ("status", Json.Assoc [ ("state", Json.String (state_name t.state)); ("message", Json.String t.detail) ]);
      ("history", Json.List (List.map message_json t.history)); ("artifacts", Json.List (List.map artifact_json t.artifacts)) ]

let task_of_json j =
  let status = Option.value (Json.member "status" j) ~default:Json.Null in
  { id = str "id" j; context_id = str "contextId" j; state = state_of_name (str "state" status); detail = str "message" status;
    history = List.map message_of_json (list "history" j); artifacts = List.map artifact_of_json (list "artifacts" j) }

let card_json c =
  Json.Assoc
    [ ("name", Json.String c.name); ("description", Json.String c.description); ("version", Json.String c.version);
      ("url", Json.String c.url); ("protocolVersion", Json.String "a2a-shaped/0.1");
      ("defaultInputModes", Json.strings [ "text/plain"; "application/json" ]); ("defaultOutputModes", Json.strings [ "text/plain"; "application/json" ]);
      ("skills", Json.List (List.map (fun s -> Json.Assoc [ ("id", Json.String s.skill_id); ("name", Json.String s.skill_name); ("description", Json.String s.skill_description); ("tags", Json.strings s.tags) ]) c.skills)) ]

let rpc_request ~id m = Json.Assoc [ ("jsonrpc", Json.String "2.0"); ("id", Json.Int id); ("method", Json.String "message/send"); ("params", Json.Assoc [ ("message", message_json m) ]) ]

(* ---- helpers --------------------------------------------------------------------------- *)

let counter = ref 0
let counter_lock = Mutex.create ()
let fresh prefix = Mutex.lock counter_lock; incr counter; let n = !counter in Mutex.unlock counter_lock; Printf.sprintf "%s-%06d" prefix n

let text_of parts = String.concat "\n" (List.filter_map (function Text t -> Some t | _ -> None) parts)
let data_of parts = List.find_map (function Data d -> Some d | _ -> None) parts
let user_message ?task_id ~context_id parts = { message_id = fresh "msg"; context_id; task_id; role = User; parts }

let reply_task (req : message) ?(state = Completed) ?(detail = "") parts =
  let answer = { message_id = fresh "msg"; context_id = req.context_id; task_id = req.task_id; role = Agent; parts } in
  { id = Option.value req.task_id ~default:(fresh "task"); context_id = req.context_id; state; detail;
    history = [ req; answer ]; artifacts = [ { artifact_id = fresh "artifact"; name = "reply"; parts } ] }

let failed (req : message) detail = { (reply_task req []) with state = Failed; detail; artifacts = [] }

(* ---- agents and the bus --------------------------------------------------------------- *)

type handler = message -> task

type agent = { card : card; handle : handler }

(* An agent in another process speaking JSON-RPC over stdio: one request on stdin, the
   JSON-RPC response (whose "result" is a task) on stdout. This is how Jev, or any
   non-OCaml agent, joins a workflow. *)
let stdio ~card argv : agent =
  let handle (m : message) =
    let req = Json.to_string (rpc_request ~id:1 m) in
    let code, out, err = Fs.run ~stdin_text:req argv in
    match Json.parse out with
    | exception _ -> failed m (Printf.sprintf "agent %s: rc=%d, no JSON-RPC response: %s" card.name code (Fs.trim err))
    | resp -> (
        match (Json.member "result" resp, Json.member "error" resp) with
        | Some r, _ -> task_of_json r
        | None, Some e -> failed m (card.name ^ ": " ^ str "message" e)
        | None, None -> failed m (card.name ^ ": response has neither result nor error"))
  in
  { card; handle }

module Bus = struct
  type entry = { at : float; from_ : string; to_ : string; request : message; response : task }

  type t = { agents : (string, agent) Hashtbl.t; lock : Mutex.t; mutable log : entry list; transcript : string option }

  let create ?transcript () = { agents = Hashtbl.create 8; lock = Mutex.create (); log = []; transcript }
  let register t (a : agent) = Hashtbl.replace t.agents a.card.name a
  let cards t = List.sort (fun a b -> compare a.name b.name) (Hashtbl.fold (fun _ a acc -> a.card :: acc) t.agents [])
  let find t name = Hashtbl.find_opt t.agents name

  let record t e =
    Mutex.lock t.lock;
    t.log <- e :: t.log;
    (match t.transcript with
     | Some path ->
         let line = Json.Assoc [ ("at", Json.Float e.at); ("from", Json.String e.from_); ("to", Json.String e.to_); ("request", message_json e.request); ("response", task_json e.response) ] in
         Fs.mkdir_p (Filename.dirname path);
         let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
         output_string oc (Json.compact line ^ "\n");
         close_out oc
     | None -> ());
    Mutex.unlock t.lock

  (* Deliver one message and wait for the task; an unknown agent or a crashed handler is a
     failed task, never an exception, so a workflow can fall back as Harness2 does. *)
  let send t ~from_ ~to_ (m : message) =
    let m = { m with task_id = Some (Option.value m.task_id ~default:(fresh "task")) } in
    let response =
      match find t to_ with
      | None -> failed m ("no agent named " ^ to_ ^ " on this bus")
      | Some a -> (try a.handle m with e -> failed m (Printexc.to_string e))
    in
    record t { at = Unix.gettimeofday (); from_; to_; request = m; response };
    response

  let entries t = List.rev t.log
end
