# Walk directory sizes and count elements on one idle queue

ADR 0013 kept the recursive size walk out of a hidden listing and
bounded it with `tired-directory-size-budget`, and it recorded the
asynchronous walk as later work.  The bound alone did not hold: the
deadline was read once per top-level row, so the recursion below that
row ran to its end.  A listing of twenty directories, each with a
large tree, walked every tree inside one redraw, and the redraw of a
listing with many directory rows paid that cost again after each cache
window.  The empty-directory mark reads a total for every directory
row, so a redraw walked subtrees even with `tired-directory-size` nil.

The size walk now runs on the idle queue, and that queue became the
one queue of the package.  A job holds a kind, a key, a step function
that returns `:more` or `:done`, a finish function, a budget, the
owner buffers and a data slot for the kind.  The index keys on the kind
and the key, because a size walk and an element count of one directory
name the same absolute path.  A pass advances the head job, rotates it
to the tail, and stops on the budget of the head job or on
`input-pending-p`.  A pass that leaves work schedules its own
successor, because an idle timer fires once for one transition into the
idle state.  A finished job marks its owner buffers dirty, and one
timer repaints them after `tired-queue-reprint-delay`.

The walk itself keeps frames on a stack instead of the call stack.  One
frame holds a directory, whether it was scanned, its file bytes and the
subdirectories that it still visits.  One step scans one directory:
it counts the regular files and records the subdirectories in the order
of the directory.  A frame stores its total when it closes, so a nested
directory keeps its own cache entry, a partial walk writes nothing, and
the parent adds the total of each child that finished.  A walk that
signals stores a zero total for its root, which matches the old
`ignore-errors` read per directory and keeps a broken tree from running
again on every redraw.

`tired--directory-total` now reads the memo table alone, so no redraw
walks a tree.  `tired--size-queue` runs after the print and queues the
topmost visible directory row of a chain, because a walk covers the
subtree of its row.  It skips a remote directory and a directory with a
young total, and a listing that no window shows queues nothing and
sets `tired--size-deferred`, so the next display starts the walk.  A
refresh drops the running size walks and keeps the table, so no total
arrives from a tree that changed under the walk.

## Considered options

A worker thread with `make-thread` keeps the reads off the main thread.
Emacs threads share one global lock, so a redraw would wait for the
worker anyway, and the walk would still need a resumable shape.

A `find` or `du` subprocess answers in one call.  Tired calls no shell,
and the package reads attributes itself for every other column.

A deadline inside the recursion, checked per directory, keeps the
redraw bounded and stays synchronous.  The redraw still pays one full
walk per cache window, and the listing still waits at its first print,
which is the cost that a user feels.

A second queue for the sizes keeps the two kinds apart without a
namespace.  Two queues mean two idle passes, two successor timers and
two reprint windows for one buffer, and the Elements queue already had
exactly the shape that the walk needs.

A generation counter per directory guards a stale walk the way bug
755e495 guards a stale entry read.  Dropping the job on refresh answers
the same question: a walk that is gone cannot write a total.  The
counter earns its keep when a load cannot be cancelled, and this one
can.

## Consequences

One queue serves both kinds, and a new kind costs a step function, a
finish function and a data struct.  `tired-tests--with-fixture` binds a
private queue and stubs both schedulers, and a test flushes the queue by
hand with `tired-tests--flush-sizes`.

`tired-directory-size-budget` limits one idle pass, not one redraw.  A
zero budget leaves the job in the queue and a nil budget walks every
queued directory in one pass.

A directory size cell, and the empty-directory mark, stay plain until
the walk lands and the reprint shows it.  A total shows until a
refresh prunes it by `tired-size-cache-ttl`, so a zero TTL empties the
column at every refresh and the walk fills it again.
