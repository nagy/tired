# Bound directory sizes with a time window, not with the collector

The recursive total of a directory changes when any file below it
changes.  No cheap check covers that, so the size column reuses a
total until a countdown ends.

Alternatives were rejected.  A `post-gc-hook` that empties the table
sounds exact, but one walk of a 35k-file tree triggers five garbage
collections itself, so the hook empties the table inside the walk that
fills it and the next refresh walks again.  Weak keys fail for the
same reason plus a second one: the walk builds a fresh key string per
directory, so every entry dies at the first collection, and a key that
a buffer holds instead keeps its entry forever.  Both mechanisms tie
freshness to reachability, and freshness needs a clock.

Consequences: one global `equal` table in `tired--size-cache` that
every buffer shares, values as `(TOTAL . STAMP)` pairs, the defcustom
`tired-size-cache-ttl` at 60 seconds, a prune of expired totals on
refresh instead of a refill, and no buffer-local size table.  A stale
total stays on screen for at most one window between two refreshes, and
a refresh re-walks a directory that it shows, as ADR 0018 records.
