# Name a section parent through a line

A Go method takes its indent from the type that the file declares
above it, and the listing keeps source order.  A function may sit
between the type row and the method row, so the nearest row above a
method is not its parent.  The listing measured a child by `:level`
alone, and that measurement reads the nearest row above with a
smaller level as the parent.  A fold on such a row then hid the
methods below it, and the user saw rows collapse under a function
that does not hold them.

`tired-section` therefore carries a `parent` slot: the line of the
section row that holds this one.  The listing builds the fold chain
and the depth from that line, and it keeps the level stack for a
handler that names no parent.  Org, Emacs Lisp, Rust, Python,
Markdown, Cargo, SQLite and tar nest their rows through the walk, so
their level already follows the row above and they need no parent.
Only the Go handler names one.

The line is the parent identity, and the fold set already keys on
`(PATH . LINE)`, so a handler gives no second key and a fold state
survives a re-parse.

Alternatives were rejected.  A stack of levels fixes nothing: the
level of a method still names the row above it as the parent, so a
fold on that row hides the method.  Dropping the indent for a
method loses the grouping that the receiver type gives.  Sorting the
methods under their type breaks source order, and a region over the
listing then copies rows in an order that the file does not have.

Consequences: a handler that names a parent must give the line of a
row that the walk meets earlier.  A parent line that names a later
row falls back to the level rule, so the row stays in place.  The
level stack ignores a row that names a parent, because the nearest
shallower row can sit between a parent and its child.
