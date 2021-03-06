open! Core_kernel
open Incr_dom
open Vdom

module Model : sig
  type t

  val create : id:Id.t -> t
end

module Action : sig
  type t [@@deriving sexp_of]
end

val apply_action : Model.t -> Action.t -> Model.t

val on_scroll : Model.t -> inject:(Action.t -> Event.t) -> Attr.t

val on_display : Model.t -> schedule:(Action.t -> unit) -> unit
