(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(** The fixed compute budget of one recursion mode on one task (Python: core/ledger.py).

    Python records rollouts and sessions as they happen and checks [R = 4k], [P = 3k] at the
    end. Here the recursion first derives a {!plan} from [k] -- the exact labels it is allowed
    to run -- and a {!Ledger} only accepts labels from that plan, each once. Over-spending or a
    duplicate label is refused at the moment it happens; [close] then checks nothing is
    missing. *)

type kind = Rollout | Session

type plan = private {
  mode : Spec.mode;
  k : int;
  rollouts : string list;  (** base1..k, then candidates, then finals: 4k labels *)
  sessions : string list;  (** proposals and compositions: 3k labels *)
}

val plan : Spec.mode -> int -> plan
(** Raises [Invalid_argument] for [k < 1]. *)

val expected_rollouts : int -> int
val expected_sessions : int -> int
val finals : Spec.mode -> int -> string list

exception Budget_error of string

module Ledger : sig
  type t

  val create : plan -> task_id:string -> t
  val record : t -> kind -> ?usd:float -> ?cached:bool -> ?attempts:int -> string -> unit
  (** Raises {!Budget_error} for a label outside the plan or one already recorded. *)

  val close : t -> unit
  (** Raises {!Budget_error} unless every planned label was recorded. *)

  val r : t -> int
  val p : t -> int
  val usd : t -> float
  val labels : t -> kind -> string list
  val to_json : t -> Json.t
end
