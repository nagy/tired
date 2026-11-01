# Count elements off the print, through one hook and one cache

The Elements column needs one number per row that describes the
content of a file or the children of a directory.  That number costs a
file read, and a redraw must not pay for it.  A redraw therefore prints
the cached count alone, and one global idle queue fills the cache after
the print.

The queue holds one job per path, and one job serves every Tired buffer
that shows that path.  A step ends on a time budget, on pending input,
or when the job finishes.  A fresh timer starts the next step at the
next idle period, because an idle timer fires once for one transition
into the idle state.  A finished count marks its buffers dirty, and one
short timer repaints them together.

`tired-elements-functions` is an abnormal hook, so a user extends the
column with `add-hook`.  A function receives the path and returns nil
for no opinion, an integer for a count that it knows now, or a job for
a count that it reads in chunks.  The built-in order runs the directory
count first, then the streaming dissectors, then the section fallback.  A file with a handler therefore counts without its own
dissector.  The fallback runs only below `tired-elements-sync-limit`,
because `tired-file-sections` parses a whole file in one call.

A count keys on the absolute path, the modification time, the size and
the value of `tired-elements-functions`.  One global table serves every
buffer, so one file costs one read.  The size catches a rewrite inside
one modification time tick, and the hook value drops every count when
the user edits the hook.

## Considered options

A worker thread with `make-thread` keeps the file read off the main
thread and needs no resumable parser.  Emacs threads share one global
lock, and tree-sitter plus font-lock off the main thread are untested
here, so the tests would guard a code path that a user cannot reason
about.

A helper process with `make-process` streams a count from `tar -tf` or
`jq` and never blocks.  It breaks the rule that Tired calls no shell,
and it adds one tool dependency per format.

A bounded prefix read in the redraw costs no queue.  A large file then
shows no number, and the count never arrives.

A regexp alist, as `tired-file-handlers` has, dispatches in one match
and cannot count one file in two ways.  The hook wins because a user
asked to extend a column, and `run-hook-with-args-until-success`
already chains the built-in dissectors.

An immediate reprint per count costs one print per file, and each print
restores point, mark, views and watches.  A listing of 500 files
repainted 500 times.  The dirty list and one timer make it one print.

## Consequences

The column lives in `tired-core`, because the format, the row vector and
the sort value belong to the listing.  The count lives in
`tired-elements.el`, which fills three variables that the core reads:
`tired--elements-value-function`, `tired--elements-queue-function` and
`tired--elements-prune-function`.  Core loads alone with empty cells.

A directory count includes every name that `directory-files` returns,
dotfiles included, so the filter, the narrow and the dotfile toggle
never change a cell.  An inserted directory still holds every name in
its table, so its count costs no read.

The section fallback counts the sections that print at depth zero, so
the first section sets the base and a later shallower section joins the
top level.  The Markdown dissector keeps one bucket per level and
applies the same rule, so the column agrees with the tree that TAB
shows.  The CSV dissector counts records rather than lines, because a
quoted field may hold a newline, and a record that starts with `#` is a
comment.

A sort on the column places an unknown count last in both directions.
A sort that reads a count that is still pending moves its row when the
count arrives, and the redraw keeps point on its row by key.

The exports keep their four disk columns.  CSV mirrors the entry
attributes, and the `rclone lsjson` shape has no place for a derived
count.

Deferred: a tar top-level member count, a WASM section count, and async
directory sizes.  Each one joins this queue as one more dissector, or as
one more kind of job.
