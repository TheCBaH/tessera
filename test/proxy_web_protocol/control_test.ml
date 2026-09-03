(* Round-trip and rejection tests for the [tessera.proxy-web] control-channel codec, independent of
   any transport. *)
module Control = Tessera_proxy_web_protocol.Control

let or_fail = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Control.E.Error.pp_kind error)

let%expect_test "client hello round-trips" =
  let message = Control.Hello { id = "abc"; target = Control.Html } in
  let text = Control.encode_client_message message in
  Format.printf "%s@." text;
  let decoded = or_fail (Control.decode_client_message ~max_bytes:1024 text) in
  Format.printf "%a@." Control.pp_client_message decoded;
  [%expect
    {|
    {"schema":"tessera.proxy-web","version":1,"type":"hello","id":"abc","target":"html"}
    hello(id="abc", target=html) |}]

let%expect_test "client resync/close round-trip with no target" =
  List.iter
    (fun message ->
      let text = Control.encode_client_message message in
      let decoded = or_fail (Control.decode_client_message ~max_bytes:1024 text) in
      Format.printf "%s -> %a@." text Control.pp_client_message decoded)
    [ Control.Resync { id = "r1" }; Control.Close { id = "c1" } ];
  [%expect
    {|
    {"schema":"tessera.proxy-web","version":1,"type":"resync","id":"r1"} -> resync(id="r1")
    {"schema":"tessera.proxy-web","version":1,"type":"close","id":"c1"} -> close(id="c1") |}]

let%expect_test "server ready/result/error round-trip, including a null id" =
  List.iter
    (fun message ->
      let text = Control.encode_server_message message in
      let decoded = or_fail (Control.decode_server_message ~max_bytes:1024 text) in
      Format.printf "%s -> %a@." text Control.pp_server_message decoded)
    [
      Control.Ready { id = "h1"; capabilities = { observe = true; input = false; resize = false } };
      Control.Result { id = "r1" };
      Control.Error { id = Some "h2"; message = "already attached" };
      Control.Error { id = None; message = "malformed json" };
    ];
  [%expect
    {|
    {"schema":"tessera.proxy-web","version":1,"type":"ready","id":"h1","capabilities":{"observe":true,"input":false,"resize":false}} -> ready(id="h1", capabilities(observe=true, input=false, resize=false))
    {"schema":"tessera.proxy-web","version":1,"type":"result","id":"r1"} -> result(id="r1")
    {"schema":"tessera.proxy-web","version":1,"type":"error","id":"h2","message":"already attached"} -> error(id="h2", "already attached")
    {"schema":"tessera.proxy-web","version":1,"type":"error","id":null,"message":"malformed json"} -> error(id=none, "malformed json") |}]

let%expect_test "malformed JSON is a Json error" =
  (match Control.decode_client_message ~max_bytes:1024 "not json" with
  | Error e -> (
      match Err.Error.kind e with
      | `Json _ -> print_endline "json"
      | other -> Format.printf "%a@." Control.pp_error other)
  | Ok _ -> print_endline "unexpectedly decoded");
  [%expect {| json |}]

let%expect_test "unknown schema/version/type are distinct typed errors" =
  let template ~schema ~version ~type_ =
    Printf.sprintf {|{"schema":%S,"version":%d,"type":%S,"id":"x"}|} schema version type_
  in
  List.iter
    (fun text ->
      match Control.decode_client_message ~max_bytes:1024 text with
      | Error e -> Format.printf "%a@." Control.E.Error.pp_kind e
      | Ok _ -> print_endline "unexpectedly decoded")
    [
      template ~schema:"tessera.other" ~version:1 ~type_:"resync";
      template ~schema:"tessera.proxy-web" ~version:2 ~type_:"resync";
      template ~schema:"tessera.proxy-web" ~version:1 ~type_:"bogus";
    ];
  [%expect {|
    unknown-schema(tessera.other)
    unknown-version(2)
    unknown-type(bogus) |}]

let%expect_test "oversize input is rejected without being parsed" =
  let text = Control.encode_client_message (Control.Resync { id = "r1" }) in
  (match Control.decode_client_message ~max_bytes:(String.length text - 1) text with
  | Error e -> (
      match Err.Error.kind e with
      | `Oversize -> print_endline "oversize"
      | _ -> Format.printf "unexpected error: %a@." Control.E.Error.pp_kind e)
  | Ok _ -> print_endline "unexpectedly decoded");
  [%expect {| oversize |}]

let%expect_test "a hello missing target, or a resync/close carrying one, is a Json error" =
  List.iter
    (fun text ->
      match Control.decode_client_message ~max_bytes:1024 text with
      | Error e -> Format.printf "%a@." Control.E.Error.pp_kind e
      | Ok _ -> print_endline "unexpectedly decoded")
    [
      {|{"schema":"tessera.proxy-web","version":1,"type":"hello","id":"x"}|};
      {|{"schema":"tessera.proxy-web","version":1,"type":"resync","id":"x","target":"html"}|};
    ];
  [%expect {|
    json(hello message missing target)
    json(resync message must not carry target) |}]
