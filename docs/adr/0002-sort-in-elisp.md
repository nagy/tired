# Sort in Elisp instead of tabulated-list

`tabulated-list-mode` can sort columns, but its sorter compares the
printed cell strings and cannot keep directories before files.  The
package sorts `tired-entry` structs in `tired--lessp` and marks every
column unsortable in `tabulated-list-format`.  Directories therefore
stay first in both sort directions, and the name column is the
tie-breaker for equal keys.  Rejected alternative: a custom
`tabulated-list` sorter, which the mode does not expose.
