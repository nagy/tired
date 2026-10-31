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

**Shell command**:
The shell line that `tired-do-shell-command` builds from the targets
and the substitution marks of the typed command.  The shell owns the
result, so no undo action covers it.
_Avoid_: Job, process, filter

**Region**:
The Emacs region between mark and point, used as a target source.
Every row between the two positions joins, except the row on which the
region ends, and a section row stands for the file that holds it.
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

**Collapse**:
One row that represents a directory chain whose subtree holds exactly
one file.
_Avoid_: Flatten, fold, compress

**Name rule**:
One element of `tired-name-faces' that colors an entry name.  A rule
paints the whole name, or only the text of one submatch when its third
element holds an integer.
_Avoid_: Highlight, font-lock keyword

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
