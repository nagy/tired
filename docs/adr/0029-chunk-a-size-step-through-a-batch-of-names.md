# Chunk a directory size step through a batch of names

Emacs Lisp threads run on one operating system thread, so a single C
library call holds the whole interpreter, keystrokes included.  The
size walk asked for one `directory-files-and-attributes` call per
directory, so a directory with many names blocked Emacs for the length
of its own read.  Measured here on 120 000 names: that call took
0.33 s, and a timer with a 20 ms period waited the same 0.34 s.  The
`tired-directory-size-budget` check cannot reach inside a C call.

Emacs Lisp threads were measured as no answer.  A pure Lisp loop in a
second `make-thread` starved the main thread for the whole 2 s of the
test, and a `directory-files-and-attributes` call in that thread
delayed a timer by the full length of the call.  Concurrency stays
cooperative, and the call yields nothing.

So a step now reads one name list, one batch of attributes or one
frame, and the walk keeps its position in a frame between steps:

- `directory-files` takes the names alone.  On this tree that costs
  0.047 s per 120 000 names, 0.39 us per name.
- A directory above `tired--size-walk-single-read-limit` then reads
  `file-attributes` for one batch of `tired--size-walk-batch` names per
  step, 8.6 us per name.
- A directory up to that limit keeps the whole-directory call, 2.75 us
  per name, because the C loop over an already read directory beats one
  Lisp call per name by a factor of three.

Alternatives were rejected.  An operating system process, such as
`du` under `make-process`, gives real parallelism, and it costs an
external binary, a second view of the tree that races with changes,
and a parse of tool output.  A permanent return to one whole-directory
call keeps the freeze.  An always-batched walk costs three times the
time on every cold directory, which the size tree of a Nix store
cannot afford.

Consequences: a cold walk of a directory above the limit costs about
three times what it cost, and it never holds Emacs for longer than one
batch.  A keystroke stops a pass at the next step, so the delay that a
user sees follows the step, not the pass.  Every directory read costs
one extra `directory-files` call, 14 percent of the whole-directory
call.  `tired--child-cache` fills at the end of the read phase instead
of at the end of the read, because the count of a batched directory
grows across steps.  ADR 0030 reuses the same step for a table of
immutable file attributes, so the batched path pays off twice on a
Git object tree.
