# Expand a file into sections inside the listing

A file row can show the items that a handler extracts from that file.
The user presses `TAB` on the file row.  The sections appear under the
row and indent by one level.  The feature mirrors
`tired-insert-subdir`, which shows the children of a directory in the
same buffer.  No second buffer and no second major mode exist.

The user option `tired-file-handlers` maps a regexp to a handler.  The
registry matches the regexp against the absolute file name, and the
first match wins.  An absolute name allows a rule that covers one
directory only.

A handler receives the file path and runs in a temporary buffer.  The
buffer holds the file contents and sets `buffer-file-name`.  The
handler selects its own major mode, so a tree-sitter handler gets a
parser and an org handler gets the org parser.  The handler returns a
list of plists.  Each plist holds `:label`, `:line`, `:level`, `:kind`
and an optional `:action`.  The framework converts each plist into a
`tired-section` struct.

The display depth follows the declared `:level` through a running
stack, so a file whose first heading is `**` still renders at the top.
`TAB` on a file row expands or collapses every section.  `TAB` on a
section row folds that section alone.  A section row fills the name
column only, because the listing has one table format for every row.

A section is not selectable.  The path commands act on the file that
owns the section, because the section carries that path.  A selection
command raises `user-error` on a section row.  Point and mark restore
use a `(PATH . LINE)` key inside the listing, so a redraw returns to
the same section row.

The section list caches by modification time.  `tired-refresh` drops
the cache entry of a changed file.  Every expanded file gets its own
file notification watch, because a directory watch does not report an
edit to a file inside that directory.

Rejected alternatives: a separate `tired-file-mode` buffer, because
it duplicates the keymap, the state variables and the redraw path, and
because the user asked to open a file the way a directory opens today.
A flat list with the indentation inside the label, because `TAB`
cannot fold a flat row.  Parsing from the live visiting buffer,
because the framework would create buffers the user never asked for
and would mix unsaved text into the listing.  A selectable section,
because a delete or a move command then needs a rule for a partial
file.

Consequences: the row type is a union of `tired-entry` and
`tired-section`, so the command layer reads paths and keys through two
new helper functions.  Sections never sort, because handler order is
document order.  A collapsed single-directory chain shows the file
row, and expansion still works because the state keys the real path.
The action slot stays unused for a text file and carries the first
real use for a PDF page target.  `tired-section` is also the row type
that the item provider idea in git-bug 6a20664 needs.  The filter
matches a file name against the whole file, so a matched file keeps
every section.  A file row whose name fails the filter stays visible
when one of its labels matches, and then only the matching sections
show.  The Rust handler needs the tree-sitter grammar, so the Nix
check supplies the grammar and the ERT test skips itself when the
grammar is absent.
