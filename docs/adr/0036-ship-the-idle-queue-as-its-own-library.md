# Ship the idle queue as its own library

The idle queue is the one region of `tired-core.el` that is not about a
listing.  It holds a job record, a queue of jobs, a pass that runs one
step of every job, a timer chain that arms the next pass and a timer
that repaints the buffers that finished jobs marked dirty.  Nothing in
it reads a directory, a section or a row.

Two owners queue jobs on it: the core's size walks and the element
counts of `tired-elements.el`.  Both reached it only by loading the
core, because the queue had no name of its own.  A reader of
`tired-elements.el` therefore could not tell from its requires that it
depends on a generic scheduler, and a bug in the pass was filed under
"the listing", where the listing does not live.

`tired-queue.el` now holds the job record, the queue state, the pass,
its two delays, the reprint delay and the reprint itself.
`tired-core.el` requires it, and `tired-elements.el` and `tired.el`
still reach it through the core, so no sibling changed its require.

The trade-off is one more file in the lint gate and one upward call:
the reprint runs `tired--redraw`, which lives above the queue, so the
call takes a `declare-function` and no load-time dependency.  That is
the same direction the core already uses for `tired-file-ops`.

## Considered options

Split the whole core by subsystem.  The file is 6012 lines, which is an
ordinary size for one Emacs library, and an Elisp file boundary hides
no name: every `tired--` helper stays reachable from every file that
loads the package.  A split by size alone would cost a rule for
`defgroup` order, `declare-function` stubs for the dozen upward calls,
and a valueless `defvar` for every buffer-local that two files share.
Section headings in the core give the navigation that a split would
give, with a comment-only diff and no new load-order rule.

Leave the queue in the core.  It costs nothing to keep, but the queue
is the one region with a consumer outside the listing, so its home
says the wrong thing about what the core is.

Split the queue and the size walk together.  The size walk is
filesystem-only and owns its own options, so it is the next candidate.
It also calls up to the model, the row set and the redraw at seven
sites, which buys a declaration for each.  The queue alone needed one.

Move the queue into `tired-elements.el`.  The size walks of the core
queue on the same scheduler, so the file would sit below the core and
above nothing else, which is a worse place than a library of its own.

## Consequences

The queue loads before the core, so the queue sees no core variable at
load time.  Its only core reference is the reprint call, and that call
resolves at run time.

`tired-queue-reprint-delay` lives in the file that arms its timer.  The
`defgroup` stays in the core, and the option still reaches `M-x
customize-group tired`, because `custom-declare-group` keeps the
members that an earlier loaded file added to the group.

The names keep the `tired--queue-` and `tired--job-` prefixes, so the
suites, `tired-test--with-fixture` and `tired-elements.el` changed no
symbol.  The core's design notes now point here for the shape of a
pass, and this file carries the note that forbids chaining an idle
timer.
