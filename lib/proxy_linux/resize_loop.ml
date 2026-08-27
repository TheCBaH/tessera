module Foundation = Tessera_foundation

module Make (Platform : Tessera_proxy_platform.Platform.S) = struct
  module Winsize = Tessera_proxy_platform.Winsize

  type t = { pty : Platform.pty; adapter : Tessera_unix.Unix_adapter.t; mutable last_applied : Winsize.t }

  type diagnostic =
    | Physical_query_failed of Platform.error
    | Unmodelled_resize of { columns : Foundation.UInt.t; rows : Foundation.UInt.t }
    | Set_winsize_failed of Platform.error
    | Notify_unchanged_failed of Platform.error
    | Adapter_resize_failed of Tessera_unix.Unix_adapter.error Err.Error.t

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
        Format.fprintf ppf "adapter-resize-failed(%a)" (Err.Error.pp_kind Tessera_unix.Unix_adapter.pp_error) error

  let pp_error ppf = function
    | `Initial_query_failed error -> Format.fprintf ppf "initial-query-failed(%a)" Platform.pp_error error
    | `Invalid_initial_size error ->
        Format.fprintf ppf "invalid-initial-size(%a)" (Err.Error.pp_kind Foundation.Types.pp_error) error
    | `Spawn_failed error -> Format.fprintf ppf "spawn-failed(%a)" Platform.pp_error error

  let startup ~argv ~lineage_id ~policy =
    match Platform.physical_winsize () with
    | Error error -> Error (`Initial_query_failed error)
    | Ok raw -> (
        match Winsize.size raw with
        | Error error -> Error (`Invalid_initial_size error)
        | Ok size -> (
            match Platform.spawn ~argv ~initial_winsize:raw with
            | Error error -> Error (`Spawn_failed error)
            | Ok pty ->
                let adapter = Tessera_unix.Unix_adapter.create ~lineage_id ~policy ~size in
                Ok { pty; adapter; last_applied = raw }))

  let pty t = t.pty
  let adapter t = t.adapter
  let last_applied t = t.last_applied

  (* proxy.md section 2, steps 1-4. A failure at any step leaves the child PTY and the renderer at
     their last known values and is reported as a diagnostic, never fabricated into a core update --
     extended consistently to every step, not only the query in step 1: if we cannot confirm the new
     geometry actually reached the child PTY, we do not tell the core it changed either. *)
  let requery t =
    match Platform.physical_winsize () with
    | Error error -> Reported (Physical_query_failed error)
    | Ok raw -> (
        match Winsize.size raw with
        | Error _ -> (
            match Platform.set_winsize t.pty raw with
            | Error error -> Reported (Set_winsize_failed error)
            | Ok () ->
                t.last_applied <- raw;
                Reported (Unmodelled_resize { columns = Winsize.columns raw; rows = Winsize.rows raw }))
        | Ok size -> (
            let distinct = not (Winsize.same_geometry raw t.last_applied) in
            let applied =
              if distinct then Platform.set_winsize t.pty raw else Platform.notify_unchanged_winsize t.pty
            in
            match applied with
            | Error error -> Reported (if distinct then Set_winsize_failed error else Notify_unchanged_failed error)
            | Ok () -> (
                t.last_applied <- raw;
                let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns size) in
                let rows = Foundation.UInt.to_int (Foundation.Types.Size.rows size) in
                match Tessera_unix.Unix_adapter.resize t.adapter ~columns ~rows with
                | Error error -> Reported (Adapter_resize_failed error)
                | Ok outcome -> Resized outcome)))

  let drain t =
    let fd = Platform.resize_wakeup_fd t.pty in
    let buffer = Bytes.create 256 in
    let rec loop () =
      match Unix.read fd buffer 0 (Bytes.length buffer) with
      | 0 -> ()
      | _ -> loop ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    in
    loop ()

  let on_wakeup t =
    drain t;
    requery t

  type ready = Wakeup | Fd of Unix.file_descr | Writable of Unix.file_descr

  let rec select_rw read_fds write_fds timeout =
    try Unix.select read_fds write_fds [] timeout
    with Unix.Unix_error (Unix.EINTR, _, _) -> select_rw read_fds write_fds timeout

  let select t ~other_read_fds ~write_fds ~timeout =
    let wakeup_fd = Platform.resize_wakeup_fd t.pty in
    let ready_read_fds, ready_write_fds, _ = select_rw (wakeup_fd :: other_read_fds) write_fds timeout in
    let wakeup_ready = List.mem wakeup_fd ready_read_fds in
    let other_ready = List.filter (fun fd -> List.mem fd ready_read_fds) other_read_fds in
    (if wakeup_ready then [ Wakeup ] else [])
    @ List.map (fun fd -> Fd fd) other_ready
    @ List.map (fun fd -> Writable fd) ready_write_fds
end
