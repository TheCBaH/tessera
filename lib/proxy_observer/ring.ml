type t = { capacity : int; buffer : Record.t option array; mutable total : int; mutable next : Record.sequence }

let create ~capacity =
  if capacity <= 0 then invalid_arg "Ring.create: capacity must be positive";
  { capacity; buffer = Array.make capacity None; total = 0; next = Record.initial_sequence }

let next_sequence t =
  let sequence = t.next in
  t.next <- Record.next_sequence sequence;
  sequence

let publish t record =
  t.buffer.(t.total mod t.capacity) <- Some record;
  t.total <- t.total + 1

type cursor = int

let cursor t = t.total

type read = Record of Record.t * cursor | Gap of { skipped : int; resume : cursor }

let read t cursor =
  if cursor >= t.total then None
  else
    let oldest_retained = max 0 (t.total - t.capacity) in
    if cursor < oldest_retained then Some (Gap { skipped = oldest_retained - cursor; resume = oldest_retained })
    else
      match t.buffer.(cursor mod t.capacity) with
      | None -> assert false (* unreachable: within [oldest_retained, total) is always populated *)
      | Some record -> Some (Record (record, cursor + 1))

let authoritative_snapshot t outcome = (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome), cursor t)
