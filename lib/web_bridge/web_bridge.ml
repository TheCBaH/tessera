module Adapter = Tessera_js_adapter.Js_adapter
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json

let ( let* ) = Result.bind

type target = Html | Canvas
type error = [ `Adapter of Adapter.error | `Frame of Frame.error | `Json of Json.error ]

let pp_error ppf = function
  | `Adapter error -> Format.fprintf ppf "adapter(%a)" Adapter.pp_error error
  | `Frame error -> Format.fprintf ppf "frame(%a)" Frame.pp_error error
  | `Json error -> Format.fprintf ppf "json(%a)" Json.E.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

type t = { adapter : Adapter.t; target : target; mutable attached : bool }

let create ~target ~lineage_id ~policy ~size =
  { adapter = Adapter.create ~lineage_id ~policy ~size; target; attached = true }

(* The very first frame this [t] ever emits has no prior browser-visible state to diff against, so it must be a
   full [reset] ([patch:None]) regardless of which adapter call produced it. Every later frame carries the
   outcome's own patch; {!Frame.of_outcome} decides for itself whether that patch still describes a plain delta or
   must be upgraded to a reset (resize, active-screen switch). *)
let render t outcome =
  let patch = if t.attached then None else Some (Tessera.outcome_patch outcome) in
  t.attached <- false;
  let* frame =
    E.map_error ~pos:__POS__
      (fun error -> `Frame error)
      (Frame.of_outcome ~patch ~snapshot:(Tessera.outcome_snapshot outcome))
  in
  match t.target with
  | Html -> E.map_error ~pos:__POS__ (fun error -> `Json error) (Json.encode_html_frame (Json.html_envelope_of frame))
  | Canvas ->
      E.map_error ~pos:__POS__ (fun error -> `Json error) (Json.encode_canvas_frame (Json.canvas_envelope_of frame))

let push t text =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Adapter error) (Adapter.push t.adapter text) in
  render t outcome

let resize t ~columns ~rows =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Adapter error) (Adapter.resize t.adapter ~columns ~rows) in
  render t outcome

let finish t =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Adapter error) (Adapter.finish t.adapter) in
  render t outcome
