# Redo through a symmetric action pair

Each file command hands two functions to `tired--push-undo`: the undo
step and the redo step.  `tired-undo` moves one action from
`tired--undo-actions` to `tired--redo-actions` and runs the undo step.
`tired-redo` moves it back and runs the redo step.  A new action
empties `tired--redo-actions`, because the session history after an
undo and a new command has one branch.

The two steps share one lexical state, and every path that a step
parks in the trash keeps one name for the whole session.  The pair
`(PATH . TRASH-NAME)` of `tired--parking-slot` decides that name once.
A cycle of undo and redo therefore moves each path between the same two
names: the trash holds one entry per path, and no byte leaves it.  Both
steps run through `tired--move-path`, which refuses a move onto an
existing path, so a redo that a user made stale changes nothing instead
of overwriting a new file.

`tired-undo-push-functions` keeps its old two-argument shape, so an
existing global undo system still takes every action.  That hook takes
the undo step alone, so `tired-redo` signals a user error while the hook
holds.

Rejected alternatives: a redo that re-runs the command body, because the
body reads the selection and the row at point, which the user changed
in the meantime; a redo that copies the source path again, because the
copy in the trash carries the bytes, the time and the mode that the
first copy made, and a second read could see a changed source; a single
undo function that parks at a fresh trash name on each run, because the
trash would then collect one dead entry per undo and redo cycle.

Consequences: every file command records both directions, so a new
command that reaches the undo stack without a redo step stays
unredoable; the undo of a `touch` of an existing file cannot restore the
time that the touch set, so its redo sets the time again and stores no
stamp; the session history stays global, so a redo can act on a
directory that no window shows; and a path that a keep-rule of
`tired-persistent-directories` covers makes no difference here, because
the trash move reads the file system and no cache.
