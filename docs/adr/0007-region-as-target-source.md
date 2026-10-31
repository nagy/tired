# Use the Emacs region for range selection

A run of rows becomes a target through the Emacs region.  Emacs
already moves the mark with shift-arrow keys, mouse drag, `C-SPC` and
`M-h`, so the package binds no key of its own and keeps no anchor
variable.

Every command reads `tired--targets`.  That function turns an active
region into the transient selection before it returns, so one source
feeds the command body and no command holds a second region branch.
`tired--selection-targets` reads the same three sources and changes
nothing, so a menu `:active` form and an interactive spec can call it
and a canceled prompt leaves no selection behind.  The selection
keeps its place across commands, so a run costs one motion and the
next command reuses it.

Every row whose line begins before `region-end` joins, so a region
that ends at a line start leaves that row out and a shift-down from
row one covers two rows.  A section row stands for the file that
holds it, and one file joins once, so a region over the headings of a
file reaches that file, the way point on a heading does.

The region paints the `region` face while it is active.  A command
deactivates the mark, so the same rows stay painted with
`tired-selected-face` and the user sees the range survive as a
selection.  `tired-select-none` clears both sources.  A view command
keeps the selection, because a user selects a directory, inserts it,
and then adds a child row.  A file command clears it, because the row
that it acted on may be gone.

`tired--redraw` records the mark path and puts the mark back after the
reprint, because `tabulated-list-print` erases the buffer and leaves
the mark on line one.

Rejected alternative: a selection anchor plus explicit shift key
bindings, because the mark is already an anchor, and because a
terminal may not deliver the shift modifier.  Rejected as well: two
independent target sources, because `tired-select-none`,
`tired-narrow-to-selection` and the mode line then need a region
branch each, and a region over headings reaches nothing.

Consequences: `transient-mark-mode` must be on before the region
reaches the targets, which is the default in an interactive session; a
narrow or a filter changes which rows lie inside a region, so a
refresh can leave a region shorter than before; and the mode line
reports the count and the size of a region, as it does for a
selection.
