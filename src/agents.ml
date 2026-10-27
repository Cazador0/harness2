(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* The Harness2 roles as A2A agents.

   [improver] proposes and composes harness edits, [selector] picks a final blind, and
   [reflector] distils the lesson after adoption. [via_bus] turns a bus into a
   [Proposer.t], so the recursion runs unchanged while every exchange becomes a logged A2A
   message. [serve] wraps any proposer (a model channel, Jev, the demo editor) as an agent.

   Evidence crosses the boundary as a path in a Data part. The receiving agent seals it
   again ([Context.seal]) before acting, so the leak guard holds at every hop rather than
   only where the evidence was built. *)

let improver = "improver"
let selector = "selector"
let reflector = "reflector"

let role_of_label label =
  if Fs.starts_with ~prefix:"select." label then selector
  else if Fs.starts_with ~prefix:"experience." label then reflector
  else improver

let skill id name description tags = { A2a.skill_id = id; skill_name = name; skill_description = description; tags }

let card_for role ~url =
  let description, skills =
    match role with
    | r when r = selector -> ("Blind selection over anonymous candidate deliverables.", [ skill "select" "Select a final" "Choose one candidate by anonymous id, with reasons." [ "selection"; "blind" ] ])
    | r when r = reflector -> ("Distils a transferable lesson after a harness is adopted.", [ skill "reflect" "Reflect on adoption" "Explain each edit's effect and write a cue/lesson/evidence entry." [ "reflection"; "library" ] ])
    | _ -> ("Proposes and composes harness edits from execution contrasts.", [ skill "propose" "Propose harness edits" "Edit context/harness/ in place and explain in <notes>." [ "harness"; "propose" ]; skill "compose" "Compose a harness" "Combine probed candidates into one refined harness." [ "harness"; "compose" ] ])
  in
  { A2a.name = role; description; version = "0.1.0"; url; skills }

let request_data ~label ~context_dir ~harvest =
  Json.Assoc ([ ("label", Json.String label); ("context_dir", Json.String context_dir) ] @ match harvest with Some h -> [ ("harvest", Json.String h) ] | None -> [])

(* Serve a proposer as an agent: the inverse of [via_bus]. *)
let serve ?(leak_globs = []) ~card (prop : Proposer.t) : A2a.agent =
  let handle (m : A2a.message) =
    match A2a.data_of m.parts with
    | None -> A2a.failed m "request carries no Data part with label and context_dir"
    | Some d -> (
        let label = A2a.str "label" d and dir = A2a.str "context_dir" d in
        let harvest = match A2a.str "harvest" d with "" -> None | h -> Some h in
        match Context.seal dir ~leak_globs with
        | Error e -> { (A2a.failed m ("refused evidence: " ^ e)) with state = A2a.Rejected }
        | Ok ctx -> (
            match Proposer.call prop ?harvest ~mission:(A2a.text_of m.parts) ctx ~label with
            | exception Proposer.Proposer_error e -> A2a.failed m e.message
            | r ->
                A2a.reply_task m
                  [ A2a.Text r.text;
                    A2a.Data
                      (Json.Assoc
                         ([ ("attempts", Json.Int r.attempts); ("cost_usd", Json.Float r.cost_usd); ("cached", Json.Bool r.cached) ]
                         @ match r.workspace with Some w -> [ ("workspace", Json.String w) ] | None -> [])) ]))
  in
  { A2a.card; handle }

(* A proposer whose every call is an A2A message to the agent for that role. *)
let via_bus ?(from_ = "orchestrator") (bus : A2a.Bus.t) (channel : Spec.channel) : Proposer.t =
  let bump, calls = Proposer.counter () in
  let context_id = A2a.fresh "ctx" in
  let call ~mission ctx ~label ~harvest =
    bump ();
    let to_ = role_of_label label in
    let msg = A2a.user_message ~context_id [ A2a.Text mission; A2a.Data (request_data ~label ~context_dir:(Context.root ctx) ~harvest) ] in
    let task = A2a.Bus.send bus ~from_ ~to_ msg in
    match task.state with
    | A2a.Completed ->
        let parts = List.concat_map (fun (a : A2a.artifact) -> a.parts) task.artifacts in
        let meta = Option.value (A2a.data_of parts) ~default:Json.Null in
        { Proposer.label; text = A2a.text_of parts; attempts = (match Json.member "attempts" meta with Some (Json.Int n) -> n | _ -> 1);
          cost_usd = Json.to_float (Json.member "cost_usd" meta); cached = Json.member "cached" meta = Some (Json.Bool true);
          workspace = (match A2a.str "workspace" meta with "" -> None | w -> Some w) }
    | _ -> raise (Proposer.Proposer_error { message = Printf.sprintf "[%s] agent %s: %s (%s)" label to_ (A2a.state_name task.state) task.detail; attempts = 1; cost_usd = 0. })
  in
  { Proposer.channel; call; calls }

(* Register the three Harness2 roles on a bus, each served by [prop]. *)
let register_roles ?leak_globs bus (prop : Proposer.t) =
  List.iter (fun role -> A2a.Bus.register bus (serve ?leak_globs ~card:(card_for role ~url:("local:" ^ role)) prop)) [ improver; selector; reflector ]
