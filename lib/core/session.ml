type error = [ `Decode of Tessera_decoder.Decoder.error | `Render of Tessera_renderer.Renderer.error ]
type byte_input = Tessera_foundation.Types.slice
type out_of_band = Resize of Tessera_foundation.Types.Size.t
type input = Bytes of byte_input | Out_of_band of out_of_band

type t = {
  decoder : Tessera_decoder.Decoder.continuation;
  input_state : Tessera_model.Input_state.t;
  policy : Tessera_foundation.Policy.t;
  renderer : Tessera_renderer.Renderer.state;
}

type outcome = {
  input_state : Tessera_model.Input_state.t;
  items : Tessera_model.Effect.Item_sequence.t;
  patch : Tessera_renderer.Patch.t;
  session : t;
  snapshot : Tessera_renderer.Renderer.snapshot;
}

let pp_error ppf = function
  | `Decode error -> Format.fprintf ppf "decode(%a)" Tessera_decoder.Decoder.pp_error error
  | `Render error -> Format.fprintf ppf "render(%a)" Tessera_renderer.Renderer.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let initial ~lineage_id ~policy ~size =
  {
    decoder = Tessera_decoder.Decoder.initial;
    input_state = Tessera_model.Input_state.default;
    policy;
    renderer = Tessera_renderer.Renderer.initial ~lineage_id ~policy ~size;
  }

let updates items =
  Tessera_model.Effect.Item_sequence.fold_left
    (fun batch item ->
      match item with
      | Tessera_model.Effect.Observation _ -> batch
      | Tessera_model.Effect.Update (Tessera_model.Update.Set_input_state _) -> batch
      | Tessera_model.Effect.Update update ->
          Tessera_model.Update.Batch.append batch (Tessera_model.Update.Batch.singleton update))
    Tessera_model.Update.Batch.empty items

let apply_decoded value (decoded : Tessera_decoder.Decoder.decoded) =
  match Tessera_renderer.Renderer.apply value.policy value.renderer (updates decoded.items) with
  | Error error -> E.fail (`Render (Err.Error.kind error))
  | Ok applied ->
      let input_state =
        Tessera_model.Effect.Item_sequence.fold_left
          (fun state -> function
            | Tessera_model.Effect.Update (Tessera_model.Update.Set_input_state delta) ->
                Tessera_model.Input_state.apply_delta state delta
            | Tessera_model.Effect.Update Tessera_model.Update.Reset -> Tessera_model.Input_state.default
            | Tessera_model.Effect.Observation _ | Tessera_model.Effect.Update _ -> state)
          value.input_state decoded.items
      in
      let session =
        { value with decoder = decoded.continuation; input_state; renderer = Tessera_renderer.Renderer.state applied }
      in
      Ok
        {
          input_state;
          items = decoded.items;
          patch = Tessera_renderer.Renderer.patch applied;
          session;
          snapshot = Tessera_renderer.Renderer.snapshot applied;
        }

let ingest_bytes value slice =
  match Tessera_decoder.Decoder.feed value.policy value.decoder slice with
  | Error error -> E.fail (`Decode (Err.Error.kind error))
  | Ok decoded -> apply_decoded value decoded

let ingest_resize value size =
  match
    Tessera_renderer.Renderer.apply value.policy value.renderer
      (Tessera_model.Update.Batch.singleton (Tessera_model.Update.Resize size))
  with
  | Error error -> E.fail (`Render (Err.Error.kind error))
  | Ok applied ->
      let session = { value with renderer = Tessera_renderer.Renderer.state applied } in
      Ok
        {
          input_state = value.input_state;
          items =
            Tessera_model.Effect.Item_sequence.singleton
              (Tessera_model.Effect.Observation (Tessera_model.Effect.Resize size));
          patch = Tessera_renderer.Renderer.patch applied;
          session;
          snapshot = Tessera_renderer.Renderer.snapshot applied;
        }

let ingest value = function
  | Bytes slice -> ingest_bytes value slice
  | Out_of_band (Resize size) -> ingest_resize value size

let finish value =
  match Tessera_decoder.Decoder.finish value.policy value.decoder with
  | Error error -> E.fail (`Decode (Err.Error.kind error))
  | Ok decoded -> apply_decoded value decoded

let items value = value.items
let patch value = value.patch
let snapshot value = value.snapshot
let input_state (value : outcome) = value.input_state
let successor value = value.session
let make ~decoder ~input_state ~policy ~renderer = { decoder; input_state; policy; renderer }
let decoder value = value.decoder
let input_state_of_session (value : t) = value.input_state
let policy value = value.policy
let renderer value = value.renderer

let pp ppf value =
  Format.fprintf ppf "session(decoder=%a; input-state=%a; renderer=%a)" Tessera_decoder.Decoder.pp value.decoder
    Tessera_model.Input_state.pp value.input_state Tessera_renderer.Renderer.pp value.renderer

let pp_outcome ppf value =
  Format.fprintf ppf "{items=%a; patch=%a; snapshot=%a}" Tessera_model.Effect.Item_sequence.pp value.items
    Tessera_renderer.Patch.pp value.patch Tessera_renderer.Renderer.pp_snapshot value.snapshot
