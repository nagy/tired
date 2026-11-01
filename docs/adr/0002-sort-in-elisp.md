# Sort in Elisp instead of tabulated-list

`tabulated-list-mode` can sort columns, but its sorter compares the
printed cell strings and cannot keep directories before files.  The
package decorates each row with its sort value and sorts the
`tired-sort-row` structs in `tired--lessp`, and it marks every column
unsortable in `tabulated-list-format`.  Directories therefore stay
first in both sort directions, and the name column is the tie-breaker
for equal keys.  Rejected alternative: a `tabulated-list` sorter run
over the flat entry list, which interleaves the inserted subtree.  See
`0014-sort-on-the-value-the-row-prints.md` for the sort value itself.

Consequence: because `tabulated-list-mode` sorts no Tired column, it
writes no arrow either.  `tired--column-label` adds the arrow itself,
and it reads `tabulated-list-gui-sort-indicator-asc` and
`tabulated-list-gui-sort-indicator-desc`, so the marker stays an Emacs
option and not a Tired constant.  A text terminal shows the two tty
options, through the buffer-local `glyphless-char-display` table that
`tabulated-list-mode` installs for its own header line.
