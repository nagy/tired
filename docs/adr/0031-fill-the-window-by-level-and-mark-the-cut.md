# Fill the window by level and mark the cut tree

ADR 0027 kept a whole-tree expansion only when the entire tree fit
the window.  A repository with a large subtree therefore opened
completely collapsed, and the user saw no expansion at all, because
one early subtree owned the whole row budget.  The listing now fills
the window with as much of the tree as the rows allow.  It takes one
depth level at a time, so every sibling of a level gains its children
before any child of the level gains its own.  A deep subtree thus
never takes the rows that its siblings earn.  The fill drops the
single insert that would pass the window body and keeps the rest.

A cut tree looks like a small tree, so the listing must say that it
holds a prefix.  `tired--expand-fits-cut' sets a `[tree cut]' part in
the mode line.  That marker is the reason this decision reverses
ADR 0027: the rejected alternative there was a fill that hides which
subtrees the user lost, and the marker answers that objection without
giving up the rows.

The fill keeps a partial last level, not a whole one.  A whole-level
rule fills the window with nothing below the deepest complete level,
and a budget of forty rows then prints twenty-three.  Uniform depth
reads more honestly, and the marker already tells the user that rows
stay out, so the rows win.

A directory that `tired-hidden-regexps' or `tired-hide-dotfiles'
matches stays collapsed during the fill.  A version-control directory
such as `.git' sorts among the first rows, and its object store holds
hundreds of entries, so it claimed the budget of every repository and
the fill reached no other row.  The rule reads the two options alone
and not `tired--hidden-p', so `tired-toggle-hidden' never changes
which directories the fill reads.  The row still shows, and a click
still expands it by hand.  This extends the sentence that ADR 0027
records for a remote directory: one directory that a user does not
read costs the fill no row.

The fill tracks its inserts in a journal of directory keys, newest
first, so a failed insert leaves the listing again through two
`remhash' calls.  That replaces the whole-table copies of ADR 0027,
and the printed check drops rows from the tail of the same journal
when a face stands taller than the row budget expects.  A quit or an
error still restores the two tables that the attempt began with.

Consequences: `tired--expand-all-fits-p` becomes
`tired--expand-by-level`, and it returns the journal and a cut flag.
A buffer holds `tired--expand-fits-cut` for the mode line.  The
attempt still runs once per buffer, so a cut tree stays cut when the
frame grows later.
