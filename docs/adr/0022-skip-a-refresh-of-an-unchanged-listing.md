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

A matching stamp set does not end the pass.  A directory stamp moves
only when a child arrives or leaves, so a write to an existing file
changes no stamp that the listing reads.  The first draft trusted the
stamps alone, and a `log.txt` that a shell `>` filled kept the size
of zero through `g`, `revert-buffer` and an inotify event.  A refresh
now reads `tired--read-tables` on a stamp match and compares it with
`tired--tables`, and it keeps the printed rows only while the entries
match.  The read costs alone.  The sort, the print and the help text
of every row stay away, which is what the 8.7 seconds held.

On a `/nix/store` of 45,000 entries the read and the compare cost
about 0.45 seconds and a pass that sorts and prints costs about 3.9
seconds.

The chain levels belong in the set, because a collapsed row hides the
directories below it: a new child deep in a chain breaks the row while
no directory that the tables hold reports a change.  The first draft
left them out, and a delete of a collapsed leaf kept its stale row.

Rejected: reuse `tired--size-cache` age alone.  A young total says
nothing about a new child, so a refresh would print a row that left the
disk.  Rejected as well: a stamp for every file row.  A file stamp
costs one read of its whole directory, so the comparison would pay the
read that it hopes to avoid and then hold the entries anyway.

## Consequences

`g` of a static directory costs the read of that directory, and the
same `g` of a directory that changed costs the old pass.

An unchanged listing keeps the printed element cells until the prune
drops a count.  A refresh runs the prune, and a count that another
`tired-elements-functions` value produced leaves the cache, so the rows
queue again and the idle reprint shows the new number.

`tired-refresh-keeps-an-unchanged-listing` turns the comparison off.
A user who does not trust a stamp, or who wants `g` to redraw the
buffer, sets it to nil.

A path that reaches a printed row and misses `tired--shown-stamps` makes
a refresh skip a change.  A new read path joins that function in the
same commit that teaches the listing to print it.  The entry compare
covers a change that no stamp reports, so a new read path also adds
its directory to `tired--read-tables`.
