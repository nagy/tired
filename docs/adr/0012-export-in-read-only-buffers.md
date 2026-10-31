# Export the view to a read-only buffer

`tired-export-csv`, `tired-export-text` and `tired-export-json` turn
the current listing into CSV, aligned plain text and the array that
`rclone lsjson` prints.  Each command reads the transient selection
first, then the active region, then `tired--visible-entries`.  It
writes a read-only buffer, gives that buffer the listing directory as
`default-directory`, and leaves it unmodified.  A whole-view export
reuses one buffer per format and directory.  A partial export takes a
fresh buffer.

Why: a listing is a view, and a view changes with the filter, the sort,
the inserted directories and the fold state.  An export that reads the
same `tired--visible-rows` keeps those choices.  The selection and the
region already feed every file command, so they feed the export too,
and no second target rule appears.  The buffer stays unmodified and
read-only, because the user decides when and where to write bytes, and
an accidental `C-x C-s` must not touch a file.  A reused whole-view
buffer matches the repeat: a second export of the same format and
directory gives roughly the same text, so the user switches to the
buffer instead of collecting copies.  A partial export is a different
question, so it gets its own buffer.

The name column of the text export holds the path relative to the
shown directory.  Tired indents a leaf under its parent, which reads
well on screen and badly in `grep`.  The relative path on every line
survives a grep, a sort and a copy into another tool, and it matches
the CSV path and the JSON `Path`, so every format names a file the
same way from the listing root.

Section rows stay out.  A section is a heading or a form inside a
file, and the three formats describe files.  The rclone schema has no
place for a heading, and a CSV row that names no file would break a
tool that reads a path.  A region over section rows still reaches the
files that hold them, through the existing region rule.

Rejected: write a file from the command.  A user who wants a file has
`C-x C-w` in the export buffer, and the command never guesses a name
or overwrites a path.  Rejected as well: a new JSON schema.  The
`rclone lsjson` object holds the fields that a directory listing
needs, and a script already reads it.  Rejected too: one buffer per
call.  A repeat export of an unchanged view would pile up identical
buffers.

Consequences: the JSON export reports a directory as `Size` -1 and
`MimeType` `inode/directory`, as rclone does.  The CSV export reports
a directory size as 0, because a recursive total costs one walk per
directory.  `tired-export-mime-fallback` covers a file that mailcap
does not know.  A new format adds one renderer and one command, and it
inherits the target rule, the buffer rule and the menu entry.
