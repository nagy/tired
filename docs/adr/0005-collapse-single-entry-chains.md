# Collapse single-entry directory chains eagerly

A directory whose chain holds one entry per level shows as one row for
the last entry of that chain, named relative to the listed directory.
The chain stops at the first branch, and the row that ends it counts
as the leaf.  A file leaf keeps the row shape it always had, so
`sub/deep/leaf.txt` replaces the `sub` row.  A directory leaf shows
`docs/adr/` when `docs` holds only `adr`, so a branch one level down
loses no row and no name.

The row uses the leaf attributes and keeps the directory's sort
position.  A directory leaf keeps the directory type, so `TAB`
inserts its children, `RET` opens a Tired buffer for it, and the
inserted children indent below the collapsed row.  A directory leaf
closes its name with a slash.

Every listed directory gets inspected on refresh, and the inspection
stops at the first branch.  An empty directory ends its chain too, so
`a/b` shows when `a` holds only `b`.  A hidden name ends the chain
before that level, so `tired-hidden-regexps` and the dotfile toggle
keep the reach they have on a real row.  A remote directory never
collapses.

The watch list carries every skipped level of every collapsed row,
because a new sibling there breaks the chain.  That costs one watch
per skipped level.  Removing an inserted directory drops its chain
results, so a stale chain leaves no watch behind.

Alternatives were rejected: inspecting only inserted sections hides
the collapse until the user expands a path; an on-demand command keeps
the tree noisy by default; ending the chain before a branch directory
costs a special case and hides the name of the branch.  Consequences:
one `directory-files` call per listed directory per refresh, a cache
that lives until the next refresh, and a row whose sort key follows
the first directory while its columns show the leaf.
