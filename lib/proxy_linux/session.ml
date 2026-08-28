module Foundation = Tessera_foundation
module Observer = Tessera_proxy_observer

module Make (Platform : Tessera_proxy_platform.Platform.S) = struct
  module Loop = Resize_loop.Make (Platform)

  type t = {
    loop : Loop.t;
    ring : Observer.Ring.t;
    master_lwt : Lwt_unix.file_descr;
    terminal_in_lwt : Lwt_unix.file_descr;
    terminal_out_lwt : Lwt_unix.file_descr;
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
            master_lwt = Lwt_unix.of_unix_file_descr ~blocking:false (Platform.master_fd (Loop.pty loop));
            terminal_in_lwt = Lwt_unix.of_unix_file_descr ~blocking:false terminal_in;
            terminal_out_lwt = Lwt_unix.of_unix_file_descr ~blocking:false terminal_out;
            master_buffer = Bytes.create read_buffer_bytes;
            terminal_buffer = Bytes.create read_buffer_bytes;
          }

  let loop t = t.loop
  let ring t = t.ring

  type event =
    | Application_bytes of Tessera.outcome
    | Application_ingest_failed of Tessera_lwt.Lwt_adapter.error Err.Error.t
    | Application_eof of Tessera.outcome
    | Terminal_input_relayed of int
    | Terminal_input_eof
    | Resized of Loop.outcome

  let zero_uint = match Foundation.UInt.of_int 0 with Ok value -> value | Error _ -> assert false

  (* [len] is always the count of an [Lwt_unix.read] into a buffer this module itself allocated (in
     [create]), so it is always representable and within bounds; a failure here would mean that
     invariant broke. *)
  let must_slice buffer ~len =
    match Foundation.UInt.of_int len with
    | Error _ -> assert false
    | Ok len -> (
        match Foundation.Types.slice buffer ~off:zero_uint ~len with Ok slice -> slice | Error _ -> assert false)

  let write_all fd buffer ~len =
    let rec loop offset =
      if offset < len then
        Lwt.bind (Lwt_unix.write fd buffer offset (len - offset)) (fun written -> loop (offset + written))
      else Lwt.return_unit
    in
    loop 0

  (* On Linux, once every slave-side descriptor of a PTY has closed (the child exited and nothing else
     holds the slave open), a read on the master returns EIO, not the ordinary EOF (0). This is the
     master-side end-of-life signal for a real PTY, so it is treated exactly like a 0-byte read here --
     never surfaced as a fatal I/O error. [Lwt_unix.read] already retries internally on EINTR/EAGAIN, so
     only EIO needs catching here. *)
  let read_master fd buffer =
    Lwt.catch
      (fun () -> Lwt_unix.read fd buffer 0 (Bytes.length buffer))
      (function Unix.Unix_error (Unix.EIO, _, _) -> Lwt.return 0 | exn -> Lwt.reraise exn)

  let read_once fd buffer = Lwt_unix.read fd buffer 0 (Bytes.length buffer)

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
    Lwt.bind (read_master t.master_lwt t.master_buffer) (fun count ->
        if count = 0 then
          Lwt.map
            (function Ok outcome -> Application_eof outcome | Error error -> Application_ingest_failed error)
            (Tessera_lwt.Lwt_adapter.finish (Loop.adapter t.loop))
        else
          Lwt.bind (write_all t.terminal_out_lwt t.master_buffer ~len:count) (fun () ->
              let slice = must_slice t.master_buffer ~len:count in
              Observer.Ring.publish t.ring
                (Observer.Record.traffic ~sequence:(Observer.Ring.next_sequence t.ring)
                   ~direction:Foundation.Types.Application_to_terminal ~bytes:(Bytes.sub t.master_buffer 0 count));
              Lwt.map
                (function
                  | Error error -> Application_ingest_failed error
                  | Ok outcome ->
                      publish_effects t outcome;
                      Application_bytes outcome)
                (Tessera_lwt.Lwt_adapter.ingest_slice (Loop.adapter t.loop) slice)))

  let on_terminal_readable t =
    Lwt.bind (read_once t.terminal_in_lwt t.terminal_buffer) (fun count ->
        if count = 0 then Lwt.return Terminal_input_eof
        else
          Lwt.bind (write_all t.master_lwt t.terminal_buffer ~len:count) (fun () ->
              Observer.Ring.publish t.ring
                (Observer.Record.traffic ~sequence:(Observer.Ring.next_sequence t.ring)
                   ~direction:Foundation.Types.Terminal_to_application ~bytes:(Bytes.sub t.terminal_buffer 0 count));
              Lwt.return (Terminal_input_relayed count)))

  let on_wakeup t =
    Lwt.map
      (fun outcome ->
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
        Resized outcome)
      (Loop.on_wakeup t.loop)

  (* Three independent, self-looping tasks in place of the old single fd-classifying [select]: Lwt multiplexing is
     implicit in how many of these are running under [Lwt_main.run], not an explicit fd-set union. Each calls
     [on_event] once per iteration (including on a failure that doesn't stop the loop), so a composition root can
     drive an observer server's [note_outcome]/[drain] exactly as it did from the old dispatch loop. *)

  let rec run_master_loop t ~on_event =
    Lwt.bind (on_master_readable t) (fun event ->
        on_event event;
        match event with Application_eof _ -> Lwt.return_unit | _ -> run_master_loop t ~on_event)

  let rec run_terminal_loop t ~on_event =
    Lwt.bind (on_terminal_readable t) (fun event ->
        on_event event;
        match event with Terminal_input_eof -> Lwt.return_unit | _ -> run_terminal_loop t ~on_event)

  (* proxy.md/the old [select] loop's session-lifetime rule: the session ends the instant *either*
     direction reaches EOF, not when both have. [Lwt.join] would wait for both, so a child that exits
     while the real terminal stays open (or vice versa) would leave the proxy hung forever -- this must
     be [Lwt.pick]. [Lwt.pick] does not merely abandon the losing loop: as soon as one promise in the
     list settles, it calls [Lwt.cancel] on every promise in the list, including the still-pending one.
     [Lwt_unix.read]'s promise is built with [Lwt.task] specifically so it supports this -- cancelling it
     deregisters the pending read from Lwt's reactor immediately and rejects it with [Lwt.Canceled],
     which [read_master]/[read_once] do not (and must not) catch, so it propagates up and ends the
     loser's loop right away rather than leaving it registered until process exit. *)
  let run_relay t ~on_event = Lwt.pick [ run_master_loop t ~on_event; run_terminal_loop t ~on_event ]

  (* Has no EOF of its own (a resize wake-up source never "ends"), so it runs until [stop] resolves -- the
     composition root signals that once the master or terminal loop above has ended the session. *)
  let rec run_resize_loop t ~on_event ~stop =
    Lwt.bind
      (Lwt.pick [ Lwt.map (fun () -> `Wakeup) (Loop.wait_for_wakeup t.loop); Lwt.map (fun () -> `Stop) stop ])
      (function
        | `Stop -> Lwt.return_unit
        | `Wakeup ->
            Lwt.bind (on_wakeup t) (fun event ->
                on_event event;
                run_resize_loop t ~on_event ~stop))
end
