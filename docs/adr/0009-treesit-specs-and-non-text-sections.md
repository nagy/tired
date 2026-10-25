# One tree-sitter walker with per-language specs, and sections for non-text files

The Rust section handler grew a private walker: one alist of node types
to kinds, one list of container types, one label rule.  Markdown needs
the same shape and a different rule for its level, because Markdown
spells the level in a marker node and the grammar nests setext
headings under the previous section.  SQLite needs sections with no
node, no grammar and no line.

`tired--treesit-sections` now takes a spec plist.  The spec names the
language, the major mode, an optional library to load, the node types
that become sections, the node types whose children nest one level
deeper, and the fields that hold the label.  An optional `:label`
function and an optional `:level` function override the default
rules.  The walker returns `:label`, `:line`, `:level` and `:kind` for
every matching node in document order.

Markdown uses one spec and one label function.  The level function
counts the ATX hash markers and reads the setext underline, so the
grammar's own nesting does not matter.  The tree-sitter query never
sees a heading inside a fenced code block, because the grammar parses
that block as code.

The SQLite handler uses the built-in `sqlite` support, not an external
tool.  It opens the database read-only, lists tables and views in name
order, and lists each table's columns one level deeper.  A database has
no lines, so every section gets a synthetic ordinal as its `:line`.
The ordinal keeps the fold state and the point restore apart, because
both key on `(PATH . LINE)`.  The action slot, unused until now, holds
a function and the table name.  RET on a table or a column opens the
database in `sqlite-mode` and moves point to that table.

Rejected alternatives: one handler per language with a copied walker,
because the Rust and Markdown walkers differ only in data; a shared
walker with a keyword argument list, because a plist reads as data and
lets a user add a language from `tired-file-handlers` without a new
function; a SQLite handler through `sqlite3` on `exec-path`, because
Emacs 31 carries the library and the package then needs no external
tool; real line numbers for SQLite sections, because the format has
none, and placing every section on line one breaks fold and point
restore; a SQLite section that opens the raw file, because the bytes
below line one are meaningless.

Consequences: a grammar that is missing yields no sections, so the
file row stays plain and the ERT test skips itself.  The Markdown
handler needs both the `markdown` and `markdown-inline` grammars,
because `markdown-ts-mode` sets up parsers for both.  The spec keeps
`markdown-ts-mode` behind `:require`, because that mode has no
autoload in this Emacs.  The section cache still keys on the
modification time, so a database written through another connection
and not yet checkpointed can show stale tables.  Adding a language
costs one spec entry and one three-line handler.
