# Inserted directories stay in one table

`i` and `TAB` insert the children of a subdirectory as indented rows in
the same `tabulated-list-mode` buffer.  The listing is a depth-first walk
over a set of per-directory entry tables, and every row stays a real
`tired-entry` with a depth.  Rejected alternatives: a synthetic header
row per section (which needs nil IDs and breaks selection), and a
separate buffer per insert (which loses the tree view).  Consequences:
sorting runs per directory, so sections never interleave, and the tree
walk needs a `file-truename` guard against symlink cycles.
