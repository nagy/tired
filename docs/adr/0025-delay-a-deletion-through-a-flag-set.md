# Delay a deletion through a flag set

`tired-delete` asks no question, so a misplaced `D` costs bytes.  The
option `tired-delete-delay` holds 3 seconds by default.  A positive
value moves the targets out of the selection into a buffer-local flag
set, paints each row through an overlay with `tired-flagged-deletion`,
and starts a countdown of that many seconds.  A nil or zero value
deletes at once, as the command always did.

The flag set stays apart from the selection.  A flagged path never
joins `tired--selection`: `tired--set-selection` drops it,
`tired-select-toggle` on a flagged row drops the flag instead of
selecting the row, `tired-select-none-at-point` on a flagged row
drops that flag alone, and `tired-select-all`, `tired-select-invert`,
`tired-select-extension` and `tired--region-entries` skip it.  The
user asked for a separation: a copy of the selected rows must never
carry a row that waits for deletion.  A file command clears the
selection as bookkeeping, and that clear keeps the flags, because
`tired--apply-to-targets` calls `tired--clear-selection` rather than
`tired-select-none`.

Every selection change starts the countdown again from zero, so a user
who keeps working pushes the removal back.  The flag set carries its
own membership: a second `tired-delete` adds its targets and restarts
the countdown, and a later selection change never adds a flag.  The
countdown stops when the last flag leaves.  `tired-select-none` drops
every flag at once, a kill of the buffer cancels the timer through
`kill-buffer-hook`, and `tired-edit-names` drops the flags because the
edit freezes the buffer text.  A refresh prunes a flagged path that no
longer exists on the disk, and it stops the countdown when no flag
remains.

When the countdown ends, `tired--delete-flagged` removes exactly the
flagged paths through `tired-delete-flagged`, keeps the rest of the
selection, pushes one undo action and prints one report line.  A
countdown that ends while a minibuffer prompt is active retries after
`tired--delete-retry-delay`, so a pending deletion never erases files
while the user types a destination.

Rejected alternatives: a timer per row, because a selection of many
rows would schedule many deletions and one clear would have to cancel
each; a flag that mirrors the selection, because selecting a row for a
copy would then arm its deletion; a flag that a selection edit never
touches, because `U` would stop clearing the pending deletion; an
immediate `tired-delete` as the default, because the delay protects
the user without a confirmation question.

Consequences: the mode line names the flag count, so a pending deletion
stays visible while the rows scroll out of the window; a narrow
snapshot includes the flagged paths, so a narrowed listing keeps a
pending row on screen; the countdown lives in the buffer, so two Tired
buffers keep two flag sets and two timers; and a command that reaches
point on a flagged row still acts on that row, because the row at
point is its own target source.  The countdown alone owns the flag,
and a copy or a move of that row changes neither the flag nor the
countdown.
