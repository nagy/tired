# tired.el

A directory editor that shows one directory as a tabulated list.
It reads the directory with Emacs primitives and never parses `ls -l`
output.

## Language

**Entry**:
One file, directory or symlink inside the shown directory.
_Avoid_: Item, row, file

**Listing**:
The ordered set of visible entries in a tired buffer.
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
buffer.
_Avoid_: Marks, region, highlight

**Target**:
The entries a command acts on.  The target is the selection when it is
non-empty, else the active region, else the entry at point.
_Avoid_: Operand, subject

**Region**:
The Emacs region between mark and point, used as a target source.
Every row between the two positions joins, except the row on which the
region ends.
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

**Collapse**:
One row that represents a directory chain whose subtree holds exactly
one file.
_Avoid_: Flatten, fold, compress

**Section**:
One item that a handler extracted from a file, such as a heading, a
declaration or a PDF bookmark.  A section row follows the row of its
file.
_Avoid_: Subtree, outline item, node, chunk

**Expand**:
Show the sections of a file under its row.  Insert shows the children
of a directory, and expand shows the sections of a file.
_Avoid_: Open, unfold, drill, zoom

**Handler**:
A function in `tired-file-handlers' that turns one file into sections.
_Avoid_: Parser, provider, extractor

**Fold**:
Hide the child sections of one section row.  A fold is local to a
section.  A collapse concerns a directory chain.
_Avoid_: Collapse, close, hide

**Trash**:
The session directory `tired-trash-directory' under
`temporary-file-directory' that holds every path a tired command
removed.  Undo moves a path back from the trash.
_Avoid_: Wastebasket, deleted items

**Undo action**:
A description and a function that reverts one file operation.  Tired
hands the pair to `tired-undo-push-functions' or keeps it on
`tired--undo-actions' for `tired-undo'.
_Avoid_: Rollback, revert, history entry
