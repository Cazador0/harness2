(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Jev as an agent in caml-harness workflows.

   STATUS: the Jev announcement (typesafe.ai) could not be read from the session that wrote
   this, so nothing here assumes Jev's own API, CLI flags or model names. Jev joins the way
   any external agent does: as an A2A agent over stdio (JSON-RPC "message/send" request on
   stdin, the response with a task "result" on stdout), via [A2a.stdio].

   Two roles were asked of Jev:
   - evals: register it as the agent named in an [Eval.Agent_judge] criterion;
   - agent-to-agent workflows: register it under a Harness2 role ("improver", "selector",
     "reflector") so the recursion's messages for that role go to Jev.

   Point CAML_HARNESS_JEV_CMD at a command that speaks that JSON-RPC, for example a small
   wrapper around Jev's CLI or SDK. *)

let env_cmd = "CAML_HARNESS_JEV_CMD"

let card ~as_ =
  { A2a.name = as_; description = "Jev (System One) agent over A2A stdio"; version = "unknown"; url = "stdio:" ^ env_cmd;
    skills = [ { skill_id = as_; skill_name = "Jev " ^ as_; skill_description = "Served by the command in " ^ env_cmd; tags = [ "jev" ] } ] }

(* The Jev agent under the given name, or an agent that fails every task (with a clear
   reason) while the command is not configured. *)
let agent ?(as_ = "jev") () : A2a.agent =
  match Sys.getenv_opt env_cmd with
  | Some cmd when String.trim cmd <> "" -> A2a.stdio ~card:(card ~as_) (List.filter (( <> ) "") (String.split_on_char ' ' cmd))
  | _ -> { A2a.card = card ~as_; handle = (fun m -> A2a.failed m (env_cmd ^ " is not set; Jev has no command to run (see src/jev.ml)")) }
