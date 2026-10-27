(* The improver/selector channel (Python: core/proposer.py).

   A proposer can only be called with a sealed [Context.t], never a bare path. Each call runs
   in a scratch copy of the context; [harvest] names the subdirectory (context/harness) that
   is copied out afterwards, which is how an edited harness comes back. *)

type reply = {
  label : string;
  text : string;
  attempts : int;
  cost_usd : float;
  cached : bool;
  workspace : string option;
}

exception Proposer_error of { message : string; attempts : int; cost_usd : float }

type t = {
  channel : Spec.channel;
  call : mission:string -> Context.t -> label:string -> harvest:string option -> reply;
  calls : unit -> int;
}

let call t ?harvest ~mission ctx ~label = t.call ~mission ctx ~label ~harvest

(* One agent session, run as an external command in [cwd]: (text, cost, error). *)
type session = cwd:string -> mission:string -> string * float * string

let claude_cli (ch : Spec.channel) : session =
 fun ~cwd ~mission ->
  let code, out, err =
    Fs.run ~stdin_text:mission
      [ "sh"; "-c"; "cd \"$0\" && exec claude --dangerously-skip-permissions -p --output-format json --effort \"$1\""; cwd; ch.effort ]
  in
  match Json.parse out with
  | exception _ -> ("", 0., Printf.sprintf "rc=%d: %s" code (Fs.trim err))
  | payload ->
      let text = Option.value (Json.to_string_opt (Json.member "result" payload)) ~default:"" in
      let cost = Json.to_float (Json.member "total_cost_usd" payload) in
      if Json.member "is_error" payload = Some (Json.Bool true) then ("", cost, "CLI error: " ^ text)
      else (text, cost, "")

let opencode (ch : Spec.channel) ~opencode_dir ~bun : session =
 fun ~cwd ~mission ->
  Fs.write (Fs.( / ) cwd "MISSION.md") mission;
  Fs.write (Fs.( / ) cwd "opencode.json") (Printf.sprintf "{\"agent\": {\"build\": {\"steps\": %d}}}" ch.steps);
  Fs.mkdir_p (Fs.( / ) cwd "output");
  let prompt =
    "Read MISSION.md first. Do what it asks. Reply with the requested output as your final \
     message AND save it verbatim to output/answer.md."
  in
  let code, _out, err =
    Fs.run
      [ bun; "run"; "--cwd"; Fs.(opencode_dir / "packages" / "opencode"); "--conditions=browser"; "src/index.ts";
        "run"; prompt; "--dir"; cwd; "--model"; ch.model; "--format"; "json"; "--variant"; ch.effort ]
  in
  let ans = Fs.(cwd / "output" / "answer.md") in
  if Fs.is_file ans && Fs.trim (Fs.read ans) <> "" then (Fs.read ans, 0., "")
  else ("", 0., Printf.sprintf "rc=%d: %s" code (Fs.trim err))

let counter () =
  let n = ref 0 and m = Mutex.create () in
  ((fun () -> Mutex.lock m; incr n; Mutex.unlock m), fun () -> !n)

let tmp_dir prefix =
  let f = Filename.temp_file prefix "" in
  Sys.remove f;
  Fs.mkdir_p f;
  f

(* A proposer over any session runner, with the transport retries of the Python release. *)
let of_session ?(max_attempts = 2) (channel : Spec.channel) (session : session) : t =
  let bump, calls = counter () in
  let call ~mission ctx ~label ~harvest =
    bump ();
    let rec attempt i spent last =
      if i > max_attempts then raise (Proposer_error { message = Printf.sprintf "[%s] %s/%s: %s" label (Spec.channel_name channel.kind) channel.model last; attempts = max_attempts; cost_usd = spent })
      else begin
        let tmp = tmp_dir "harness2-ml-prop-" in
        ignore (Fs.copy_tree (Context.root ctx) (Fs.( / ) tmp "context"));
        let text, cost, err = session ~cwd:tmp ~mission in
        let spent = spent +. cost in
        if Fs.trim text = "" then (Fs.rm_rf tmp; attempt (i + 1) spent (if err = "" then "empty reply" else err))
        else begin
          let workspace =
            Option.bind harvest (fun sub ->
                let src = Fs.( / ) tmp sub in
                if Fs.is_dir src then (let dest = tmp_dir "harness2-ml-harvest-" in ignore (Fs.copy_tree src dest); Some dest) else None)
          in
          Fs.rm_rf tmp;
          { label; text; attempts = i; cost_usd = spent; cached = false; workspace }
        end
      end
    in
    attempt 1 0. ""
  in
  { channel; call; calls }
