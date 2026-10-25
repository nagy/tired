# Transient selection instead of Dired marks

Dired marks are persistent flags stored per line.  This package keeps a
buffer-local list of selected paths and highlights those lines with an
overlay.  Commands act on the selection when it is non-empty, otherwise
on the entry at point.  The selection is pruned whenever the listing is
rebuilt, and commands that act on it clear it.  This keeps the listing
read-only and leaves no stale flags after a refresh.  Rejected
alternative: Dired-style marks, which need explicit clearing rules and a
mark column.
