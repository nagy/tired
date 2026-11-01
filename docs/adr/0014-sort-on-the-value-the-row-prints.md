# Sort on the value that the row prints

A listing row can show a different entry from the table entry that it
came from.  A collapsed chain row shows a leaf inside the chain, and a
directory row shows the recursive total in the size column.  Sorting
the table entry then orders the column by a number that the column
never shows.  A modification time sort put a fresh leaf under the old
top directory, and a size sort put an 88k subtree below a 4-byte one.

The sort therefore decorates each row before the compare.  A
`tired-sort-row` holds the table entry, the collapse clone, the sort
value and the tie-break name.  The size value comes from
`tired--shown-size`, the function that fills the size cell, so the two
numbers stay one.  The time and the mode values come from the clone.
The name value comes from the table entry, because a leaf extension
would move a chain row out of the directory group, and a name sort
must keep that group.  The directory test reads the table entry, so
`tired-collapse-single-child` never moves a row across the group
border.

The decoration also removed a per-compare cost.  The extension and the
name were parsed on every comparison, which cost 270 ms for one
directory of 4000 files.  One decoration per row per redraw costs 56
ms.

Directories still lead every sort by default.  A `dired` time sort
interleaves them, so `tired-group-directories` turns the group off.
That option touches the group test alone, and the decoration carries
it.

Rejected alternatives: a printed-cell sorter, which `tabulated-list`
offers but which compares strings, so `9k` sorts above `88k`; sorting
the raw entry and letting the columns disagree; and disabling the
collapse on every key but the name.  Consequences: one struct per row
per level per redraw, a size key that reads the size cache, and a name
key that ignores the leaf of a collapsed row.
