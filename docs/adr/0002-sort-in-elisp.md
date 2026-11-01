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
