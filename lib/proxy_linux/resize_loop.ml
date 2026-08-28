module Foundation = Tessera_foundation

module Make (Platform : Tessera_proxy_platform.Platform.S) = struct
  module Winsize = Tessera_proxy_platform.Winsize

  type t = {
    pty : Platform.pty;
    adapter : Tessera_lwt.Lwt_adapter.t;
    mutable last_applied : Winsize.t;
    wakeup_fd : Lwt_unix.file_descr;
  }

  type diagnostic =
    | Physical_query_failed of Platform.error
    | Unmodelled_resize of { columns : Foundation.UInt.t; rows : Foundation.UInt.t }
    | Set_winsize_failed of Platform.error
    | Notify_unchanged_failed of Platform.error
    | Adapter_resize_failed of Tessera_lwt.Lwt_adapter.error Err.Error.t

  type outcome = Resized of Tessera.outcome | Reported of diagnostic

  type error =
    [ `Initial_query_failed of Platform.error
    | `Invalid_initial_size of Foundation.Types.error Err.Error.t
    | `Spawn_failed of Platform.error ]

  let pp_diagnostic ppf = function
    | Physical_query_failed error -> Format.fprintf ppf "physical-query-failed(%a)" Platform.pp_error error
    | Unmodelled_resize { columns; rows } ->
        Format.fprintf ppf "unmodelled-resize(%a×%a)" Foundation.UInt.pp columns Foundation.UInt.pp rows
    | Set_winsize_failed error -> Format.fprintf ppf "set-winsize-failed(%a)" Platform.pp_error error
    | Notify_unchanged_failed error -> Format.fprintf ppf "notify-unchanged-failed(%a)" Platform.pp_error error
    | Adapter_resize_failed error ->
        Format.fprintf ppf "adapter-resize-failed(%a)" (Err.Error.pp_kind Tessera_lwt.Lwt_adapter.pp_error) error

  let pp_error ppf = function
    | `Initial_query_failed error -> Format.fprintf ppf "initial-query-failed(%a)" Platform.pp_error error
    | `Invalid_initial_size error ->
        Format.fprintf ppf "invalid-initial-size(%a)" (Err.Error.pp_kind Foundation.Types.pp_error) error
    | `Spawn_failed error -> Format.fprintf ppf "spawn-failed(%a)" Platform.pp_error error

  let startup ~argv ~env ~lineage_id ~policy =
    match Platform.physical_winsize () with
    | Error error -> Error (`Initial_query_failed error)
    | Ok raw -> (
        match Winsize.size raw with
        | Error error -> Error (`Invalid_initial_size error)
        | Ok size -> (
            match Platform.spawn ~argv ~env ~initial_winsize:raw with
            | Error error -> Error (`Spawn_failed error)
            | Ok pty ->
                let adapter = Tessera_lwt.Lwt_adapter.create ~lineage_id ~policy ~size in
                let wakeup_fd = Lwt_unix.of_unix_file_descr ~blocking:false (Platform.resize_wakeup_fd pty) in
                Ok { pty; adapter; last_applied = raw; wakeup_fd }))

  let pty t = t.pty
  let adapter t = t.adapter
  let last_applied t = t.last_applied

  (* proxy.md section 2, steps 1-4. A failure at any step leaves the child PTY and the renderer at
     their last known values and is reported as a diagnostic, never fabricated into a core update --
     extended consistently to every step, not only the query in step 1: if we cannot confirm the new
     geometry actually reached the child PTY, we do not tell the core it changed either. *)
  let requery t =
    match Platform.physical_winsize () with
    | Error error -> Lwt.return (Reported (Physical_query_failed error))
    | Ok raw -> (
        match Winsize.size raw with
        | Error _ -> (
            match Platform.set_winsize t.pty raw with
            | Error error -> Lwt.return (Reported (Set_winsize_failed error))
            | Ok () ->
                t.last_applied <- raw;
                Lwt.return (Reported (Unmodelled_resize { columns = Winsize.columns raw; rows = Winsize.rows raw })))
        | Ok size -> (
            let distinct = not (Winsize.same_geometry raw t.last_applied) in
            let applied =
              if distinct then Platform.set_winsize t.pty raw else Platform.notify_unchanged_winsize t.pty
            in
            match applied with
            | Error error ->
                Lwt.return (Reported (if distinct then Set_winsize_failed error else Notify_unchanged_failed error))
            | Ok () ->
                t.last_applied <- raw;
                let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns size) in
                let rows = Foundation.UInt.to_int (Foundation.Types.Size.rows size) in
                Lwt.map
                  (function Error error -> Reported (Adapter_resize_failed error) | Ok outcome -> Resized outcome)
                  (Tessera_lwt.Lwt_adapter.resize t.adapter ~columns ~rows)))

  (* Drains every byte currently buffered on [wakeup_fd] without ever waiting for a future one: {!Lwt_unix.readable}
     is a non-blocking poll (unlike {!Lwt_unix.read}, which would suspend until more data arrives once the buffer is
     empty), so this loop stops the instant the descriptor has nothing left to offer right now. *)
  let drain t =
    let buffer = Bytes.create 256 in
    let rec loop () =
      if Lwt_unix.readable t.wakeup_fd then
        Lwt.bind (Lwt_unix.read t.wakeup_fd buffer 0 (Bytes.length buffer)) (fun _count -> loop ())
      else Lwt.return_unit
    in
    loop ()

  let on_wakeup t = Lwt.bind (drain t) (fun () -> requery t)
  let wait_for_wakeup t = Lwt_unix.wait_read t.wakeup_fd
end
