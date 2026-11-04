# Recompute a shown size on refresh, keep it between redraws

A refresh reads the disk, so it must not show a size or an empty-directory
mark that a young memo entry left behind.  `tired--size-cache-ttl` still
serves every redraw, but a refresh queues one walk per shown directory
through `tired--size-enqueue`, which takes a FORCE argument for that.

Alternatives were rejected.  Dropping the totals of the shown directories
on refresh costs the same walk and empties the size column until the walk
lands, so a plain `g` blinks.  Reading only the modification time of a row
catches a file that arrives beside it, but no deep change, and the ignored
face would dim a directory that holds bytes.  Checking the children of a
zero-total directory fixes the face alone, so the mark and the number
disagree.

## Consequences

The total stays on screen while the forced walk runs, so the mark and the
cell correct themselves in one idle pass instead of one cache window.  A
refresh of a large tree therefore repeats the subtree walk, and the idle
queue spreads that read over several passes.  A walk that started before
the refresh is dropped, because its scan can still store a number that
predates the change, and a walk that started after it stays, so one
refresh never restarts itself.
