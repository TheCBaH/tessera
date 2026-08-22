(* Dune/Melange overlay for the Uucp modules used by Tessera and Uuseg.

   Uucp's generic value trie uses recursive types, which Melange does not
   support. The Unicode properties below use the upstream specialised tries
   and are the complete set needed by the shared terminal implementation. *)

let unicode_version = Uucp_version_data.unicode_version

module Break = Uucp__break
module Emoji = Uucp__emoji
module Gc = Uucp__gc
module White = Uucp__white
