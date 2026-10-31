# Let one click select a row and the middle click open it

Dired answers a click on a file name with a visit: it binds
`follow-link` to `mouse-face`, so `mouse-1-click-follows-link` turns
the click into a `mouse-2` event, and `mouse-2` opens the name.  A
Tired row is a tree node, not a link.  The listing binds `follow-link`
to `tired--click-selects-row`, a predicate that returns nil, binds
`mouse-2` to `tired-mouse-find-file-other-window`, and binds
`double-mouse-1` to `tired-mouse-toggle`, which runs
`tired-toggle-subdir`.

Why: a click that opens a row fights the tree.  A directory row that
opens on the first click replaces the listing that a reader wants to
walk, and a directory row that collapses costs a second click to bring
back.  A drag that starts on a name must make a region, because
`tired--region-entries` feeds that region to every file command.  A
double click that inserts or removes children, expands or collapses
sections and folds headings gives the mouse the one action that the
tree has no other gesture for, and it keeps the keys of TAB and `e`.
The middle button opens a row in another window and reads that row
only, so the selection survives the click.

Rejected: dired's `follow-link` value.  `tabulated-list-mode-map`
installs it and it needs no code, but with the default
`mouse-1-click-follows-link` every click that lands on a name opens a
second buffer.  Rejected as well: a `keymap` property on the name cell
for `double-mouse-1`, because that property hides the mode map for
every other key on the row.

Consequences: the name column and the indent carry `mouse-face
highlight`, so a hover lights the whole row.  The help text names the
two mouse commands, because no key list shows them.  No click follows
a link, so a plain click and a touch both select.  `tired-evil.el`
keeps evil's `down-mouse-1`, so under evil a double click selects text
and TAB or `e` toggles a row, while normal state takes `mouse-2` from
`mouse-yank-primary`, because a read-only listing has nothing to paste.
