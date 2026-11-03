# Sort in Elisp instead of tabulated-list

`tabulated-list-mode` can sort a column, but its sorter runs over the
flat `tabulated-list-entries` list at print time.  One Tired listing
holds a tree: a directory row, the row of an inserted child under it,
a file row, and the section rows of that file.  A flat sort moves a
child away from its parent and a section away from its file.  Tired
also reads a sorted level before any print exists, in the collapse
walk of `tired--display-rows`.

The package therefore decorates each row of one directory with its
sort value and sorts the `tired-sort-row` structs in `tired--lessp`.
The tree walk then reads the sorted level.  Directories stay first in
both sort directions while `tired-group-directories` holds, the name
breaks a tie, and one redraw parses each extension once.  See
`0014-sort-on-the-value-the-row-prints.md` for the sort value itself.

Rejected alternative: the `SORT` slot of `tabulated-list-format` takes
a predicate, so a column can compare a number and the built-in header
click and arrow follow.  A predicate receives two rows and nothing
else, so it cannot read the depth of a row and cannot keep the tree.
It also cannot hold two rules that the listing promises.
`tabulated-list--get-sorter` turns a descending sort into the same
predicate with the arguments swapped, so a nil element count would
list first in descending order, and the name tie-break would run
backwards.  Tired keeps a nil count last in both directions and the
tie-break ascending in both directions.

Rejected alternative: `tabulated-list-groups`, new in Emacs 30, sorts
each group alone.  One group per directory would therefore carry the
per-level order and the built-in arrow.  A group prints its own header
line, and the group name holds the path of its level with one `*` per
level, so the listing would show a header above every directory level.
Tired indents a child row instead and prints no header, so the two
layouts do not meet.

Consequence: because `tabulated-list-mode` sorts no Tired column, it
writes no arrow either.  `tired--column-label` adds the arrow itself,
and it reads `tabulated-list-gui-sort-indicator-asc` and
`tabulated-list-gui-sort-indicator-desc`, so the marker stays an Emacs
option and not a Tired constant.  A text terminal shows the two tty
options, through the buffer-local `glyphless-char-display` table that
`tabulated-list-mode` installs for its own header line.
