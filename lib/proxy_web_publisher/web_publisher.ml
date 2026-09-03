module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json

type target = Html | Canvas
type client = { target : target; mutable needs_reset : bool; pending : string Queue.t; mutable pending_bytes : int }
type t = { max_pending_bytes : int; mutable clients : client list; mutable last_outcome : Tessera.outcome option }

let create ~max_pending_bytes = { max_pending_bytes; clients = []; last_outcome = None }
let client_count t = List.length t.clients

type error = [ `Frame of Frame.error | `Json of Json.error ]

let pp_error ppf = function
  | `Frame error -> Format.fprintf ppf "frame(%a)" Frame.pp_error error
  | `Json error -> Format.fprintf ppf "json(%a)" Json.E.pp_error error

module Error_domain = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error_domain)

let frame_of ~patch ~snapshot = E.map_error ~pos:__POS__ (fun error -> `Frame error) (Frame.of_outcome ~patch ~snapshot)

let encode_json target (frame : Frame.t) =
  match target with
  | Html -> E.map_error ~pos:__POS__ (fun error -> `Json error) (Json.encode_html_frame (Json.html_envelope_of frame))
  | Canvas ->
      E.map_error ~pos:__POS__ (fun error -> `Json error) (Json.encode_canvas_frame (Json.canvas_envelope_of frame))

let ( let* ) = Result.bind

let build target kind ~snapshot ~patch =
  let* frame =
    match kind with `Reset -> frame_of ~patch:None ~snapshot | `Delta -> frame_of ~patch:(Some patch) ~snapshot
  in
  encode_json target frame

let enqueue client messages =
  List.iter (fun json -> Queue.push json client.pending) messages;
  client.pending_bytes <-
    client.pending_bytes + List.fold_left (fun total json -> total + String.length json) 0 messages

let clear client =
  Queue.clear client.pending;
  client.pending_bytes <- 0

let prepend_pending _t client message =
  let queued = Queue.to_seq client.pending |> List.of_seq in
  Queue.clear client.pending;
  Queue.push message client.pending;
  List.iter (fun json -> Queue.push json client.pending) queued;
  client.pending_bytes <- client.pending_bytes + String.length message

let attach t ~target =
  let client = { target; needs_reset = true; pending = Queue.create (); pending_bytes = 0 } in
  (match t.last_outcome with
  | None -> ()
  | Some outcome -> (
      let snapshot = Tessera.outcome_snapshot outcome in
      match frame_of ~patch:None ~snapshot with
      | Error _ -> ()
      | Ok frame -> (
          match encode_json target frame with
          | Error _ -> ()
          | Ok json ->
              enqueue client [ json ];
              client.needs_reset <- false)));
  t.clients <- client :: t.clients;
  client

let detach t client = t.clients <- List.filter (fun c -> c != client) t.clients

(* Keyed by (target, kind); at most 4 distinct (target, kind) combinations exist, so a small assoc list beats
   pulling in a Hashtbl for one call's lifetime. *)
let note_outcome t ?before outcome =
  t.last_outcome <- Some outcome;
  match t.clients with
  | [] -> Ok ()
  | clients ->
      let snapshot = Tessera.outcome_snapshot outcome in
      let patch = Tessera.outcome_patch outcome in
      let cache = ref [] in
      let get target kind =
        match List.assoc_opt (target, kind) !cache with
        | Some result -> result
        | None ->
            let result = build target kind ~snapshot ~patch in
            cache := ((target, kind), result) :: !cache;
            result
      in
      let first_error = ref None in
      let note_error e = match !first_error with Some _ -> () | None -> first_error := Some e in
      List.iter
        (fun client ->
          let kind = if client.needs_reset then `Reset else `Delta in
          match get client.target kind with
          | Error e -> note_error e
          | Ok json ->
              let messages = Option.to_list (Option.map (fun make -> make client.target) before) @ [ json ] in
              if client.needs_reset then (
                enqueue client messages;
                client.needs_reset <- false)
              else if
                client.pending_bytes + List.fold_left (fun total message -> total + String.length message) 0 messages
                > t.max_pending_bytes
              then (
                clear client;
                match get client.target `Reset with
                | Error e -> note_error e
                | Ok reset_json ->
                    enqueue client (Option.to_list (Option.map (fun make -> make client.target) before) @ [ reset_json ]))
              else enqueue client messages)
        clients;
      (match !first_error with None -> Ok () | Some e -> Error e : (unit, error) Err.t)

let pending_length _t client = client.pending_bytes

let take_one_pending _t client =
  match Queue.take_opt client.pending with
  | None -> None
  | Some json ->
      client.pending_bytes <- client.pending_bytes - String.length json;
      Some json
