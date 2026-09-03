(* Pure, no Lwt/socket tests for the attach/reset/delta/backpressure state machine. *)
module Publisher = Tessera_proxy_web_publisher.Web_publisher
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json
open Tessera_test_support.Support

let or_fail = function Ok value -> value | Error message -> failwith message
let or_fail_err pp = function Ok value -> value | Error error -> failwith (Format.asprintf "%a" pp error)
let publisher_pp ppf error = Publisher.pp_error ppf (Err.Error.kind error)
let frame_pp ppf error = Frame.pp_error ppf (Err.Error.kind error)
let json_pp ppf error = Json.E.pp_error ppf (Err.Error.kind error)

let make_session ?(columns = 4) ?(rows = 2) () =
  let policy = or_fail (policy ()) in
  let lineage_id = Tessera_foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  Tessera.initial ~lineage_id ~policy ~size:(or_fail (size columns rows))

let session_pp ppf error = Tessera.Session.pp_error ppf (Err.Error.kind error)
let ingest_text session text = or_fail_err session_pp (Tessera.ingest session (Tessera.Bytes (or_fail (slice text))))

let ingest_resize session columns rows =
  or_fail_err session_pp (Tessera.ingest session (Tessera.Out_of_band (Tessera.Resize (or_fail (size columns rows)))))

let note_outcome publisher outcome = ignore (or_fail_err publisher_pp (Publisher.note_outcome publisher outcome))

let kind_of ~target text =
  match target with
  | Publisher.Html -> (
      match Json.decode_html_frame text with
      | Ok env -> Format.asprintf "%a" Frame.pp_kind env.meta.kind
      | Error _ -> "decode-error")
  | Publisher.Canvas -> (
      match Json.decode_canvas_frame text with
      | Ok env -> Format.asprintf "%a" Frame.pp_kind env.meta.kind
      | Error _ -> "decode-error")

let%expect_test "attach before any outcome has nothing pending; attach after receives an immediate reset" =
  let publisher = Publisher.create ~max_pending_bytes:1_000_000 in
  let before = Publisher.attach publisher ~target:Publisher.Html in
  Format.printf "before-attach pending_length=%d@." (Publisher.pending_length publisher before);
  let session = make_session () in
  note_outcome publisher (ingest_text session "hi");
  (match Publisher.take_one_pending publisher before with
  | None -> print_endline "before: no message after outcome (unexpected)"
  | Some text -> Format.printf "before: %s@." (kind_of ~target:Publisher.Html text));
  let after = Publisher.attach publisher ~target:Publisher.Html in
  (match Publisher.take_one_pending publisher after with
  | None -> print_endline "after: no message (unexpected)"
  | Some text ->
      Format.printf "after: %s, pending_length_now=%d@." (kind_of ~target:Publisher.Html text)
        (Publisher.pending_length publisher after));
  [%expect {|
    before-attach pending_length=0
    before: reset
    after: reset, pending_length_now=0 |}]

let%expect_test "an ordinary delta's content matches a directly-computed Web_frame/Web_json projection" =
  let publisher = Publisher.create ~max_pending_bytes:1_000_000 in
  let client = Publisher.attach publisher ~target:Publisher.Html in
  let session = make_session () in
  note_outcome publisher (ingest_text session "hi");
  ignore (Publisher.take_one_pending publisher client);
  let second = ingest_text session "!!" in
  note_outcome publisher second;
  let got = Option.get (Publisher.take_one_pending publisher client) in
  let expected =
    let frame =
      or_fail_err frame_pp
        (Frame.of_outcome ~patch:(Some (Tessera.outcome_patch second)) ~snapshot:(Tessera.outcome_snapshot second))
    in
    or_fail_err json_pp (Json.encode_html_frame (Json.html_envelope_of frame))
  in
  Format.printf "kind=%s equal=%b@." (kind_of ~target:Publisher.Html got) (String.equal got expected);
  [%expect {| kind=delta equal=true |}]

let%expect_test "a resize upgrades the next delivered message to a reset for an already-attached client" =
  let publisher = Publisher.create ~max_pending_bytes:1_000_000 in
  let client = Publisher.attach publisher ~target:Publisher.Html in
  let session = make_session () in
  note_outcome publisher (ingest_text session "hi");
  ignore (Publisher.take_one_pending publisher client);
  note_outcome publisher (ingest_resize session 6 3);
  let got = Option.get (Publisher.take_one_pending publisher client) in
  Format.printf "%s@." (kind_of ~target:Publisher.Html got);
  [%expect {| reset |}]

let%expect_test "an overflowing client is forced to a fresh reset, never a stray delta after the drop" =
  let publisher = Publisher.create ~max_pending_bytes:16 in
  let client = Publisher.attach publisher ~target:Publisher.Html in
  let session = make_session () in
  note_outcome publisher (ingest_text session "hi");
  ignore (Publisher.take_one_pending publisher client);
  let kinds = ref [] in
  for i = 1 to 5 do
    note_outcome publisher (ingest_text session (Printf.sprintf "x%d" i));
    match Publisher.take_one_pending publisher client with
    | None -> kinds := "none" :: !kinds
    | Some text -> kinds := kind_of ~target:Publisher.Html text :: !kinds
  done;
  Format.printf "%s@." (String.concat "," (List.rev !kinds));
  [%expect {| reset,reset,reset,reset,reset |}]

let%expect_test "two clients on different targets never see each other's target's content" =
  let publisher = Publisher.create ~max_pending_bytes:1_000_000 in
  let html_client = Publisher.attach publisher ~target:Publisher.Html in
  let canvas_client = Publisher.attach publisher ~target:Publisher.Canvas in
  let session = make_session () in
  note_outcome publisher (ingest_text session "hi");
  let html_text = Option.get (Publisher.take_one_pending publisher html_client) in
  let canvas_text = Option.get (Publisher.take_one_pending publisher canvas_client) in
  Format.printf
    "html decodes as html=%b canvas decodes as canvas=%b cross-decode-fails: html-as-canvas=%b canvas-as-html=%b@."
    (Result.is_ok (Json.decode_html_frame html_text))
    (Result.is_ok (Json.decode_canvas_frame canvas_text))
    (Result.is_error (Json.decode_canvas_frame html_text))
    (Result.is_error (Json.decode_html_frame canvas_text));
  [%expect
    {| html decodes as html=true canvas decodes as canvas=true cross-decode-fails: html-as-canvas=true canvas-as-html=true |}]

let%expect_test "take_one_pending pops exactly one message at a time and pending_length tracks the remainder" =
  let publisher = Publisher.create ~max_pending_bytes:1_000_000 in
  let client = Publisher.attach publisher ~target:Publisher.Html in
  let session = make_session () in
  let outcomes = List.init 3 (fun i -> ingest_text session (Printf.sprintf "line%d" i)) in
  List.iter (note_outcome publisher) outcomes;
  let accounted = ref [] in
  let rec drain () =
    let before = Publisher.pending_length publisher client in
    match Publisher.take_one_pending publisher client with
    | None -> ()
    | Some text ->
        let after = Publisher.pending_length publisher client in
        accounted := (before - after = String.length text) :: !accounted;
        drain ()
  in
  drain ();
  Format.printf "messages=%d all-length-accounted=%b final_pending_length=%d@." (List.length !accounted)
    (List.for_all Fun.id !accounted)
    (Publisher.pending_length publisher client);
  [%expect {| messages=3 all-length-accounted=true final_pending_length=0 |}]

let%expect_test "client_count tracks attach/detach, and detach is idempotent" =
  let publisher = Publisher.create ~max_pending_bytes:1024 in
  let a = Publisher.attach publisher ~target:Publisher.Html in
  let _b = Publisher.attach publisher ~target:Publisher.Canvas in
  Format.printf "%d@." (Publisher.client_count publisher);
  Publisher.detach publisher a;
  Format.printf "%d@." (Publisher.client_count publisher);
  Publisher.detach publisher a;
  Format.printf "%d@." (Publisher.client_count publisher);
  [%expect {|
    2
    1
    1 |}]
