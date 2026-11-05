# Focus one subtree through a thing and a redraw hook

A listing indents by depth, so a row three levels down shows a name and no
mark of the entry that owns it.  `focus-mode` dims everything outside one
region, and in a listing that region belongs to the subtree of point: the
depth-zero entry with every row that it prints below itself.  A reader who
inserts a directory, then its child, then a grandchild reads one column of
names and loses the entry at the top of that column.

Tired answers the question as a thing, not as a focus setting.
`bounds-of-thing-at-point 'tired-subtree` returns the start of the
depth-zero row and the start of the line after its last printed row, so
every reader of `thingatpt` gets that region: `focus-mode`, `embark`, and
a later evil text object.  `thing-at-point` answers the text through the
same provider, because it falls back to the bounds.  `forward-thing` gets
a provider too, and it mirrors the `line` thing: forward moves to the
start of the next depth-zero row, and backward moves to the start of the
subtree above.  The provider reads the BACKWARD argument that
`forward-thing` passes, because that function takes the smallest non-zero
move of every provider for the symbol and calls it once per step.

`tired--redraw-buffer` records the start of every depth-zero row in a
vector of buffer positions while it walks `tired--rows`, and the print
order equals that walk order.  The provider then costs one search of that
vector and no line read.  A name edit sets the vector to nil, because a
longer name moves every later line start, and the next print fills it
again.

`tabulated-list-print` erases the buffer, and the erase collapses every
overlay that another library put on the text, so a library that dims a
region needs a second chance after each print.
`tired-after-redraw-hook` gives that chance: it runs last, with the
listing buffer current, after the point restore, the selection overlays
and the mode line.

Rejected: three overlays inside tired that copy the dim.  Tired would own
a face that the reader customizes through `focus-unfocused`, and one
buffer would hold two dim layers.  Rejected: a call to `focus-move-focus`
from `tired--redraw-buffer`.  It costs three lines and no user setup, but
`tired-core` would name a package that a reader without focus never
loads.  Rejected: an entry in `focus-mode-to-thing` that a
`with-eval-after-load` form adds.  It reaches every user with no setup,
but it writes into the defcustom of another package, and the order of
that list alone would decide the reader's focus.  Rejected: bounds from
the printed indentation.  A name that starts with a space reads one level
deep, and a wide subtree costs one scan per command.  Rejected: the
nearest inserted ancestor instead of the depth-zero row.  That ancestor
changes with every fold, so the region would move while point holds
still.

## Consequences

A user enables the pair with three lines of init.  The first turns the
dim on in every listing, the second repairs the region after a print that
no command runs, and the third names the thing for
`focus-mode-to-thing`:

```elisp
(add-hook 'tired-mode-hook #'focus-mode)
(add-hook 'tired-after-redraw-hook
          (lambda () (when (bound-and-true-p focus-mode)
                       (focus-move-focus (current-buffer)))))
(add-to-list 'focus-mode-to-thing '(tired-mode . tired-subtree))
```

A hook that runs a view command redraws forever, so the docstring of
`tired-after-redraw-hook` forbids one.  A refresh of an unchanged listing
prints nothing and runs no hook, and the overlays keep the bounds of the
last print.  A name edit answers no bounds, and the commit and the
abort force that print through `tired--listing-stamps`, so the region
returns at once.  A listing without a row answers no bounds, so the dim
keeps the region of the last command.

`focus-change-thing` offers a fixed candidate list, so it cannot name the
new thing.  A reader sets `focus-current-thing` in the buffer instead.
`focus-read-only-mode` binds `n`, `SPC`, `p`, `i` and `q`, and a
minor-mode map wins over `tired-mode-map`, so that mode shadows five
listing keys.  The README names the trade.
