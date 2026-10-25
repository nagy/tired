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
non-empty, otherwise the entry at point.
_Avoid_: Operand, subject

**Filter**:
A name substring that limits which entries appear in the listing.
_Avoid_: Search, query
