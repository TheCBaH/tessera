(** A bounded, single-producer, multi-consumer record log (proxy.md section 4). Fixes its record budget up front; there
    is no unbounded growth path. A slow observer never applies backpressure to {!publish} -- publishing into a full ring
    overwrites the oldest retained record instead, and a lagging reader recovers from {!authoritative_snapshot} rather
    than stalling the producer. *)

type t

val create : capacity:int -> t
(** [capacity] must be positive. *)

val next_sequence : t -> Record.sequence
(** Mints the next sequence for this ring, shared across all three {!Record.t} kinds -- call once per record about to be
    published, immediately before constructing it. *)

val publish : t -> Record.t -> unit
(** Never blocks and never raises. Publishing into a full ring overwrites the oldest retained record. *)

type cursor
(** One observer's read position. *)

val cursor : t -> cursor
(** A cursor starting after every record currently retained -- a fresh observer must resync from
    {!authoritative_snapshot} first, not replay history it never subscribed to. *)

type read =
  | Record of Record.t * cursor
  | Gap of { skipped : int; resume : cursor }
      (** [Gap] is returned instead of silently skipping: the caller learns exactly how many records were dropped and
          receives a cursor positioned after the gap, so it knows to resynchronise. *)

val read : t -> cursor -> read option
(** [None] means caught up to the producer; not an error. *)

val authoritative_snapshot : t -> Tessera.outcome -> Tessera_model.Collection.Snapshot_cells.t * cursor
(** The current renderer snapshot carried by [outcome], paired with a cursor positioned to read every record published
    after it. A client that receives a {!Gap} discards what it has and rebuilds from this pair instead of trying to
    patch around the hole.

    Takes [Tessera.outcome], not [Tessera.session]: only an outcome carries a renderer snapshot in the public facade
    ({!Tessera.outcome_snapshot}) -- [session] is deliberately opaque input to the next {!Tessera.ingest}. Callers hold
    the latest outcome for exactly this reason, the same way [test/conformance]'s [Reference.run] does. The pairing is
    only coherent when [outcome] is the most recent one applied and no other publish has interleaved between it and this
    call -- true by construction in a single-threaded proxy loop, since {!publish} for the matching {!Record.resize} and
    {!Record.effect}s happens synchronously right after the core accepts each ingest. *)
