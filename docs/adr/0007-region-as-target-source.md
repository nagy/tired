# Use the Emacs region for range selection

A run of rows becomes a target through the Emacs region.  Emacs
already moves the mark with shift-arrow keys, mouse drag, `C-SPC` and
`M-h`, so the package binds no key of its own and keeps no anchor
variable.  `tired--selection-targets` reads the selection first, then
`tired--region-entries`, then the entry at point.  Every row whose
line begins before `region-end` joins, so a region that ends at a line
start leaves that row out and a shift-down from row one covers two
rows.  `tired--redraw` records the mark path and puts the mark back
after the reprint, because `tabulated-list-print` erases the buffer
and leaves the mark on line one.  Commands deactivate the region after
they act on it.

Rejected alternative: a selection anchor plus explicit shift key
bindings, because the mark is already an anchor, and because a
terminal may not deliver the shift modifier.  Rejected as well: the
region as the only selection, because the region dies on the next
plain motion, and a persistent selection still serves copy, then
navigate.

Consequences: two highlights exist side by side, `region` for the
region and `tired-selected-face` for the selection, with the
selection winning; a narrow or a filter changes which rows lie inside
a region, so a refresh can leave a region shorter than before; and
`transient-mark-mode` must be on before the region reaches the
targets, which is the default in an interactive session.
