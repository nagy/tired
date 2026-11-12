# Expand a whole tree only when it fits the window

A user who wants density asks for every subdirectory to appear on the
screen, and no scroll bar that the user did not ask for.  The listing
therefore tries a whole-tree expansion when a window first shows it.
`tired-expand-all-if-fits` gates the attempt and starts on.  The
listing keeps the new rows only when the whole result fits the window
body.  A tree that would scroll stays as it is, because a partial
fill hides the shape of the tree and leaves the user with a listing
that neither fits nor shows everything.

The fit check has two steps.  The trial walks the listing with a row
budget and inserts one directory at a time, so it reads a directory
only until the budget runs out.  A tree that holds thousands of
directories costs at most one window of reads, and a walk that passes
the budget throws `tired--row-overflow` from
`tired--display-rows`.  The budget divides the body pixels by
`default-line-height`, so `line-spacing` and the frame font reach it.
A row whose face stands taller than the default face, such as a theme
that boxes `dired-directory`, still fits fewer rows than the budget,
so the print itself is measured with `window-text-pixel-size` and the
listing goes back to collapsed when it overflows.

Canonical lines alone are not enough: `window-body-height` counts
multiples of the frame character height, ignores `line-spacing`, and
takes no face into account (bug#43105).  `count-screen-lines` counts
screen lines, not pixels, and a tall face stays one line there.  A
remote directory and a directory that fails to read stay collapsed.

The attempt runs once per buffer, so a collapse that the user makes
afterwards stays in place.  `tired` and `tired-other-window` attempt
after `display-buffer` picks the window and before the frame redraws,
so the user never sees the collapsed listing first.
`tired-noselect` sets `tired--expand-fits-pending` when no window
shows the buffer, and the `window-buffer-change-functions` entry
finishes that attempt through a zero delay timer, because `find-file`
displays the buffer after `tired-noselect` returns.

Alternatives were rejected: expanding as deep as the window takes
hides which subtrees the user lost; re-running on a resize fights a
user who collapsed a row and then grew the frame; expanding file
sections parses every file before the cheap check has a chance;
and a trial that builds a clone of the listing costs a second full
print on every entry.

Consequences: `tired--display-rows` carries an optional row limit that
throws `tired--row-overflow`.  A failed trial restores
`tired--tables` and `tired--inserted`, so it leaves no row behind.  A
theme with tall rows costs one extra print and then stays collapsed.
The shared test fixture binds the option to nil, so a listing in a test
stays collapsed until a test of the expansion binds it to t.
