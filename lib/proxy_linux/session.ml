module Foundation = Tessera_foundation
module Observer = Tessera_proxy_observer

module Make (Platform : Tessera_proxy_platform.Platform.S) = struct
  module Loop = Resize_loop.Make (Platform)

  type t = {
    loop : Loop.t;
    ring : Observer.Ring.t;
    terminal_in : Unix.file_descr;
    terminal_out : Unix.file_descr;
    master_buffer : bytes;
    terminal_buffer : bytes;
  }

  let create ~argv ~env ~lineage_id ~policy ~terminal_in ~terminal_out ~observer_capacity ~observer_start_position
      ~read_buffer_bytes =
    match Loop.startup ~argv ~env ~lineage_id ~policy with
    | Error _ as error -> error
    | Ok loop ->
        Ok
          {
            loop;
            ring = Observer.Ring.create ~capacity:observer_capacity ~start_position:observer_start_position;
            terminal_in;
            terminal_out;
            master_buffer = Bytes.create read_buffer_bytes;
            terminal_buffer = Bytes.create read_buffer_bytes;
          }

  let loop t = t.loop
  let ring t = t.ring

  type event =
    | Application_bytes of Tessera.outcome
    | Application_ingest_failed of Tessera_unix.Unix_adapter.error Err.Error.t
    | Application_eof of Tessera.outcome
    | Terminal_input_relayed of int
    | Terminal_input_eof
    | Resized of Loop.outcome

  let zero_uint = match Foundation.UInt.of_int 0 with Ok value -> value | Error _ -> assert false

  (* [len] is always the count of a [Unix.read] into a buffer this module itself allocated (in
     [create]), so it is always representable and within bounds; a failure here would mean that
     invariant broke. *)
  let must_slice buffer ~len =
    match Foundation.UInt.of_int len with
    | Error _ -> assert false
    | Ok len -> (
        match Foundation.Types.slice buffer ~off:zero_uint ~len with Ok slice -> slice | Error _ -> assert false)

  let rec write_all fd buffer ~len =
    let rec loop offset = if offset < len then loop (offset + Unix.write fd buffer offset (len - offset)) in
    try loop 0 with Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd buffer ~len

  let rec read_once fd buffer =
    try Unix.read fd buffer 0 (Bytes.length buffer) with Unix.Unix_error (Unix.EINTR, _, _) -> read_once fd buffer

  (* On Linux, once every slave-side descriptor of a PTY has closed (the child exited and nothing else
     holds the slave open), a read on the master returns EIO, not the ordinary EOF (0). This is the
     master-side end-of-life signal for a real PTY, so it is treated exactly like a 0-byte read here --
     never surfaced as a fatal I/O error. *)
  let rec read_master fd buffer =
    try Unix.read fd buffer 0 (Bytes.length buffer) with
    | Unix.Unix_error (Unix.EINTR, _, _) -> read_master fd buffer
    | Unix.Unix_error (Unix.EIO, _, _) -> 0

  let publish_effects t outcome =
    Tessera.Effect.Item_sequence.fold_left
      (fun () item ->
        match item with
        | Tessera.Effect.Observation item ->
            Observer.Ring.publish t.ring
              (Observer.Record.effect_observation ~sequence:(Observer.Ring.next_sequence t.ring) ~item)
        | Tessera.Effect.Update _ -> ())
      () (Tessera.outcome_items outcome)

  let convert_pixels = function
    | None -> None
    | Some { Tessera_proxy_platform.Winsize.width; height; unit } ->
        let unit =
          match unit with
          | Tessera_proxy_platform.Winsize.Device_pixels -> Observer.Record.Pixels.Device_pixels
          | Tessera_proxy_platform.Winsize.Css_pixels -> Observer.Record.Pixels.Css_pixels
          | Tessera_proxy_platform.Winsize.Unspecified -> Observer.Record.Pixels.Unspecified
        in
        Some { Observer.Record.Pixels.width; height; unit }

  let on_master_readable t =
    let master = Platform.master_fd (Loop.pty t.loop) in
    let count = read_master master t.master_buffer in
    if count = 0 then
      match Tessera_unix.Unix_adapter.finish (Loop.adapter t.loop) with
      | Ok outcome -> Application_eof outcome
      | Error error -> Application_ingest_failed error
    else (
      write_all t.terminal_out t.master_buffer ~len:count;
      let slice = must_slice t.master_buffer ~len:count in
      Observer.Ring.publish t.ring
        (Observer.Record.traffic ~sequence:(Observer.Ring.next_sequence t.ring)
           ~direction:Foundation.Types.Application_to_terminal ~bytes:(Bytes.sub t.master_buffer 0 count));
      match Tessera_unix.Unix_adapter.ingest_slice (Loop.adapter t.loop) slice with
      | Error error -> Application_ingest_failed error
      | Ok outcome ->
          publish_effects t outcome;
          Application_bytes outcome)

  let on_terminal_readable t =
    let count = read_once t.terminal_in t.terminal_buffer in
    if count = 0 then Terminal_input_eof
    else
      let master = Platform.master_fd (Loop.pty t.loop) in
      write_all master t.terminal_buffer ~len:count;
      Observer.Ring.publish t.ring
        (Observer.Record.traffic ~sequence:(Observer.Ring.next_sequence t.ring)
           ~direction:Foundation.Types.Terminal_to_application ~bytes:(Bytes.sub t.terminal_buffer 0 count));
      Terminal_input_relayed count

  let on_wakeup t =
    let outcome = Loop.on_wakeup t.loop in
    (match outcome with
    | Loop.Resized tessera_outcome ->
        let size =
          match Tessera.Patch.size (Tessera.outcome_patch tessera_outcome) with
          | Tessera.Patch.Set size -> size
          | Tessera.Patch.Keep -> assert false (* a Resized outcome always sets Patch.size *)
        in
        let pixels = convert_pixels (Tessera_proxy_platform.Winsize.pixels (Loop.last_applied t.loop)) in
        Observer.Ring.publish t.ring
          (Observer.Record.resize ~sequence:(Observer.Ring.next_sequence t.ring) ~size ~pixels);
        publish_effects t tessera_outcome
    | Loop.Reported _ -> ());
    Resized outcome

  type ready = Wakeup | Master | Terminal_input | Extra_read of Unix.file_descr | Extra_write of Unix.file_descr

  let select t ~extra_read_fds ~extra_write_fds ~timeout =
    let master = Platform.master_fd (Loop.pty t.loop) in
    Loop.select t.loop ~other_read_fds:([ master; t.terminal_in ] @ extra_read_fds) ~write_fds:extra_write_fds ~timeout
    |> List.map (function
      | Loop.Wakeup -> Wakeup
      | Loop.Fd fd when fd = master -> Master
      | Loop.Fd fd when fd = t.terminal_in -> Terminal_input
      | Loop.Fd fd -> Extra_read fd
      | Loop.Writable fd -> Extra_write fd)
end
