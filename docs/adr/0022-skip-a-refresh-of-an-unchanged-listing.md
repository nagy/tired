# Skip the reprint of a listing that the disk did not change

`g` re-read every shown directory, sorted every entry in Elisp, printed
every row and painted its help text.  On a Nix store of 39,000 entries
that pass cost 8.7 seconds, and the work repeated whatever the disk did
in between.  A user who presses `g` twice pays twice.

A refresh now compares stamps first.  `tired--shown-stamps` reads the
modification time and the size of the shown directory, of every inserted
directory, of every level that a single-entry chain read and of every
expanded file.  A listing whose stamps all match reads no directory,
sorts no row and prints nothing.  It still sets `tired--size-forced`,
prunes the element cache, queues the size walks and rebuilds the mode
line, so a total that the disk changed below an unchanged directory
lands through the idle reprint, as
`0018-refresh-recomputes-a-shown-size.md` asks.

The chain levels belong in the set, because a collapsed row hides the
directories below it: a new child deep in a chain breaks the row while
no directory that the tables hold reports a change.  The first draft
left them out, and a delete of a collapsed leaf kept its stale row.

Rejected: reuse `tired--size-cache` age alone.  A young total says
nothing about a new child, so a refresh would print a row that left the
disk.  Rejected as well: compare the entry tables after re-reading them.
The read costs 0.44 seconds and every later step still runs, so the
saving would be small.

## Consequences

`g` of a static directory costs about 60 milliseconds, and the same `g`
of a directory that changed costs the old pass.  A file edit changes its
own directory stamp, so a section or an element count of that file
follows.

An unchanged listing keeps the printed element cells until the prune
drops a count.  A refresh runs the prune, and a count that another
`tired-elements-functions` value produced leaves the cache, so the rows
queue again and the idle reprint shows the new number.

`tired-refresh-keeps-an-unchanged-listing` turns the comparison off.
A user who does not trust a stamp, or who wants `g` to redraw the
buffer, sets it to nil.

A path that reaches a printed row and misses `tired--shown-stamps` makes
a refresh skip a change.  A new read path joins that function in the
same commit that teaches the listing to print it.
