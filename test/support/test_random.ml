(* A deliberately small, test-only deterministic replacement for the subset of
   [Random.State] used by checked-in generated corpora.  Unlike [Random.State],
   its sequence is specified here and therefore does not vary with the OCaml
   release that runs the test suite. *)

module State = struct
  type t = int32 ref

  let make seed =
    let state = ref 0l in
    Array.iter (fun value -> state := Int32.add (Int32.mul !state 1103515245l) (Int32.of_int value)) seed;
    state

  let int state bound =
    if bound <= 0 then invalid_arg "Test_random.State.int";
    state := Int32.add (Int32.mul !state 1103515245l) 12345l;
    Int32.to_int (Int32.logand !state 0x7fffffffl) mod bound
end
