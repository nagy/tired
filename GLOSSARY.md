# tired.el

A directory editor that shows one directory as a tabulated list.
It reads the directory with Emacs primitives and never parses `ls -l`
output.

## Language

**Entry**:
One file, directory or symlink inside the shown directory.
_Avoid_: Item, row, file

**Listing**:
The ordered set of visible entries in a Tired buffer.
_Avoid_: Index, table

**Directory buffer**:
A buffer in `tired-mode` that shows one directory.
_Avoid_: Dired buffer, folder view

**Sort key**:
The entry attribute that orders the listing: name, size, modification
time or mode.
_Avoid_: Sort column, order

**Sort state**:
One column and one direction together, named by a symbol such as
`name-desc`.  `tired-sort-states` lists the states that `tired-sort`
cycles, and a numeric prefix selects one by its position in that
list.  `tired--sort-by-column` sets a column directly.
_Avoid_: Sort mode, order, preset

**Selection**:
The transient set of entry paths that commands act on in a directory
buffer.  An active region joins it before a command acts.
_Avoid_: Marks, region, highlight

**Extension group**:
The visible files that share the extension of the row at point.  A
name without an extension and a dotfile name share one empty key.
`tired-select-extension` adds the whole group to the selection and
leaves point on its row.
_Avoid_: File type, suffix set

**Target**:
The entries a command acts on: the selection when it is non-empty,
else the active region, else the entry at point.  A command commits
the region into the selection first, so its body reads one source.
_Avoid_: Operand, subject

**Export**:
The read-only buffer that `tired-export-csv`, `tired-export-text` or
`tired-export-json` writes from the targets or the whole visible
listing.  A section row never joins, because a section is not a file.
_Avoid_: Dump, report, save

**Shell command**:
The shell line that `tired-do-shell-command` builds from the targets
and the substitution marks of the typed command.  The shell owns the
result, so no undo action covers it.
_Avoid_: Job, process, filter

**Region**:
The Emacs region between mark and point, used as a target source.
Every row between the two positions joins, including the rows that
mark and point show, and a section row stands for the file that holds
it.
_Avoid_: Range, block, span

**Filter**:
A name substring that limits which entries appear in the listing.
_Avoid_: Search, query

**Narrow**:
A listing limited to a snapshot of the selection plus the directories
that contain the selected entries.
_Avoid_: Filter, focus

**Watch**:
A file notification registration for one shown directory, used by
automatic refresh.
_Avoid_: Monitor, poll

**Size cache**:
The global table `tired--size-cache` that holds one recursive directory
total with the stamp of the walk that computed it.  All Tired buffers
share it.  `tired-size-cache-ttl` bounds the age of a total, and a
refresh drops the expired ones.
_Avoid_: Du cache, memo, total table

**Size walk**:
The recursive read of one directory subtree for its byte count.
`tired--subtree-size` runs the walk and `tired--directory-total` starts
it, so one walk caches every directory that it reaches.
_Avoid_: Scan, size pass

**Deferred size**:
A size whose walk waits.  No window shows the listing, or
`tired-directory-size-budget` ended.  The cell prints empty, and
`tired--size-deferred` holds the state until a display or an idle pass
walks the size.
_Avoid_: Pending total, lazy size, unknown size

**Size budget**:
The `tired-directory-size-budget` seconds that one redraw spends on size
walks.  A spent budget stops the walk and defers the rest.
_Avoid_: Timeout, walk limit, quota

**Element**:
One item that an entry holds, such as an immediate child of a
directory, an item of a top-level JSON array, or a top-level Markdown
heading.  An entry is a row of the listing, and an element is what that
row counts.
_Avoid_: Item, child, member

**Dissector**:
A function in `tired-elements-functions` that counts the elements of one
path.  It returns nil for no opinion, an integer for a count that it
knows now, or an element job for a count that it reads in steps.
_Avoid_: Counter, analyzer, extractor, parser

**Element count**:
The number that a dissector returns for one path, printed in the
Elements column.  Nil means no count, and the cell stays empty.
_Avoid_: Size, total, tally

**Element job**:
One incremental read of one path for its element count.  A step reads a
chunk, keeps its state, and ends with a count or with no count.
_Avoid_: Task, work item, worker, background job

**Element cache**:
The global table `tired--elements-cache` that holds one element count per
path with the modification time, the size and the hook value that the
count came from.  Every Tired buffer shares it.
_Avoid_: Memo, count table, tally cache

**Section fallback**:
The last dissector, which counts the sections that print at depth zero.
It reaches every file that a section handler claims.
_Avoid_: Default dissector, generic count

**Collapse**:
One row that represents a directory chain whose subtree holds exactly
one file.
_Avoid_: Flatten, fold, compress

**Empty directory**:
A directory whose subtree holds no byte.  Its name row takes
`tired-ignored-face', and the slash follows the name.
_Avoid_: Zero size, blank folder

**Name rule**:
One element of `tired-name-faces' that colors an entry name.  A rule
paints the whole name, or only the text of one submatch when its third
element holds an integer.
_Avoid_: Highlight, font-lock keyword

**Name edit**:
The state that `tired-edit-names' starts, in which the leaf of every
name is editable and the rest of the listing is read only.  A commit
renames the rows that hold a new name, and an abort drops every
change.  A collapsed chain row edits its leaf alone.
_Avoid_: Wdired mode, inline rename mode

**Name span**:
The text of one submatch that a partial name rule paints.
_Avoid_: Highlight range, overlay

**Hidden entry**:
An entry whose name matches one regexp in `tired-hidden-regexps`.  It
leaves the listing with its sections, and a hidden directory skips the
children that the user inserted.  `tired-toggle-hidden` shows the
hidden entries until the next toggle.  The mode line counts the hidden
entries of the shown directories.
_Avoid_: Ignored file, filtered file

**Section**:
One item that a handler extracted from a file, such as a heading, a
declaration or a PDF bookmark.  A section row follows the row of its
file.
_Avoid_: Subtree, outline item, node, chunk

**Label**:
The text of one section row in the name column.  A handler builds it
from the source text and keeps the faces of its major mode, so a row
colors like its file.  A part of a label without a source face takes
the face of its section kind.
_Avoid_: Title, caption, row text

**Expand**:
Show the sections of a file under its row.  Insert shows the children
of a directory, and expand shows the sections of a file.
_Avoid_: Open, unfold, drill, zoom

**Handler**:
A function in `tired-file-handlers' that turns one file into sections.
_Avoid_: Parser, provider, extractor

**Section spec**:
A plist that names the tree-sitter language, mode, node types, container
types and label fields that `tired--treesit-sections` uses to build the
sections of one language.
_Avoid_: Config, node table, grammar rule

**Synthetic line**:
The ordinal that a handler gives a section when its file has no lines,
such as a database table.  The ordinal keeps fold state and point
restore apart.
_Avoid_: Fake line, dummy line

**Fold**:
Hide the child sections of one section row.  A fold is local to a
section.  A collapse concerns a directory chain.
_Avoid_: Collapse, close, hide

**Trash**:
The session directory `tired-trash-directory' under
`temporary-file-directory' that holds every path a Tired command
removed.  Undo moves a path back from the trash.
_Avoid_: Wastebasket, deleted items

**Undo action**:
A description and a function that reverts one file operation.  Tired
hands the pair to `tired-undo-push-functions' or keeps it on
`tired--undo-actions' for `tired-undo'.
_Avoid_: Rollback, revert, history entry
