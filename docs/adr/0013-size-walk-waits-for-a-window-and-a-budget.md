# Walk a directory size only for a window, and only inside a budget

A recursive total reads one directory per directory in the subtree, so
a large tree blocks the redraw that asks for it.  An asynchronous walk
needs a worker, a generation counter and a repaint per finished
directory.  That work comes later.  Two cheap limits shrunk the block
first.

A redraw that no window shows walks nothing.  The buffer still prints,
because the filter, the insert set and the fold set change without a
refresh, and the reprint keeps point and the mark on their rows.  The
size cell then stays empty and the empty-directory mark stays plain.
A cached total still serves such a redraw, because the cache read costs
no directory read.  The display that follows walks the sizes.

A visible redraw stops walking when `tired-directory-size-budget`
seconds end.  Rows that it reaches keep their total, rows that it leaves
print empty, and an idle timer redraws.  The next pass reads the cache
for the finished rows, so every pass moves forward and no row costs two
walks.

Alternatives were rejected.  Skipping only the offscreen rows needs the
window range inside the printer, and a printed cell of another width
breaks the column alignment.  A blocking walk with no budget keeps the
hitch, which the visibility test alone does not touch.  A full
asynchronous walk brings the worker and the staleness problem now,
before the simpler limits show their cost.

Consequences: `tired--directory-total` returns nil for a walk that
waits, so its callers branch on nil and print an empty cell.  Three
sites gate the walk: the size column, the empty-directory mark and the
mode line sum.  A buffer-local `window-buffer-change-functions` entry
redraws once a window shows the buffer, and `tired--size-redraw` runs
the idle pass.  A pass that finished no walk schedules nothing, so a
budget too small for one subtree costs one reprint and ends.  The walk
of one single subtree still runs to its end, because the budget counts
whole walks.
