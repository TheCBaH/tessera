(** The checked capability-program subset used by controlled output.

    A source capability is accepted only when it consists of literal bytes and the following terminfo operations:

    - [%%] emits one literal percent byte.
    - [%p1] and [%p2] select the first or second supplied parameter.
    - [%d] emits the selected parameter in decimal.
    - [%i] increments the first two supplied parameters.

    Every other percent operation is rejected while compiling. In particular, this language has no variables,
    arithmetic, conditionals, string arguments, or recursive evaluation. *)

type instruction
type t

val compile : string -> t option
(** Compile a terminfo capability into the restricted program language. *)

val execute : t -> int list -> string option
(** Execute a compiled program with its integer parameters. *)
