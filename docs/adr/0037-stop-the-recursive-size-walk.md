# Stop the recursive size walk through a global switch

The recursive size walk reads one directory per directory in a subtree,
and `tired-directory-size` hid its total but did not stop the walk.  A
redraw of a listing still queued the walk of every shown directory, so
a refresh warmed the memo table and the child cache for a column that
the user never asked to see.  A user who wanted no recursive I/O had to
name every mount point in `tired-directory-size-exclude`, a list that
states a per-path policy and says nothing about computation.

`tired-directory-size-walk`, a boolean that defaults to t, now decides
whether Tired queues a walk at all.  A nil value gates
`tired--size-queue`, so a redraw queues no row, and
`tired--size-enqueue`, so the refresh path and a direct caller queue
nothing either.  The scope stays global, because the idle queue, the
memo table and the child cache are global: a buffer-local flag would
make one job mean two things for two listings that share its key.

The Custom setter empties the tables, so a nil value leaves no total
behind: a directory answers nil, shows no size, keeps the plain
directory face and adds no byte to the mode line, and the child count
that the walk stored in `tired--child-cache` goes with it, so the
Elements column reads a directory again instead of a count from a walk
that the option stops.  The switch stops computation alone, and
`tired--size-skip-p` stays out of it: that predicate answers the
display questions too.  A plain `setq` runs no setter, so a total that
a walk computed before it still serves the size column, the
empty-directory mark and the mode line, because reading the table costs
no directory read.

Alternatives were rejected.  Turning `tired-directory-size` into a
`choice` of nil, `cached` and t would overload a boolean that already
means "show the column", and it would leave no way to show a cached
total without walking.  The exclude list can name every directory, but
that is a per-path statement with a regexp cost on every size question,
and it also drops the total of every path that it names.  One broad
option that turns off collapsing and the whole-tree fill as well would
couple a size computation with two view features that users set for
other reasons.

The Custom setter drops the walks that wait, empties the totals and the
child counts that they stored, and redraws every Tired buffer, so the
column empties at once instead of at the next redraw; when the value
turns back on, it queues every Tired buffer again: a shown listing
walks at once, and a hidden one keeps the deferred state that its next
display reads.  A plain `setq` reaches the next redraw alone, so a walk
that already waits runs to its end and its total stays on screen.  The
standard value must not run the setter while the library loads, because
the setter redraws listings that call functions the rest of the file
defines, so the option takes `custom-initialize-default`.

## Consequences

A user who turns the walk off through Customize or `setopt` loses every
total and every child count that a walk already computed, and the mode
line total drops with them, so turning the walk back on walks the tree
again.  The Elements column still counts the immediate children of a
directory, because that count reads no subtree, so an Elements cell can
fill while the size cell beside it stays empty; a count that a size
walk stored goes with the total, so the column reads the directory
itself once.  No idle pass reads a directory for a size, so a listing
on slow storage never pays a walk through this path.
