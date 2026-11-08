# Name one chain component through the filename thing

A collapsed row prints a chain as one text, for example
`chain/a/b/leaf.txt`.  The `filename` thing answered the leaf path for
every position inside that text, so the top directory of the chain
answered a file that sits two levels below it.  A reader who asks for the
name under the cursor expects the component under the cursor.

`tired--filename-at-point` now splits the name text at the slashes and
answers the absolute path of the component under point.  Point on `a`
answers `<shown>/chain/a`, and point on the leaf answers the leaf path.
Point on a slash answers the component that the slash closes, because a
bounds cons keeps its end and the next component starts after the slash.
`bounds-of-thing-at-point` follows the same split, so the region covers
one component alone.  Every other row keeps the whole name and the row
path.  `tired--name-region` keeps the whole name text, because the mouse
face and the in-place name edit read that region.

Embark reads `filename` for its file target, but its two built-in
finders ask `ffap-file-at-point`.  That function resolves the printed
text against `default-directory`, so it answers nothing for a row inside
an inserted directory, and it answers the whole chain for a collapsed
row.  Tired therefore gives `embark-target-finders` a buffer-local
finder that reads `tired--filename-at-point` and `tired--name-bounds`,
and drops both built-in file finders from that buffer-local list.  One
finder keeps one target per row.

Rejected: one value for the whole chain.  The leaf path answers a
question that the cursor does not ask, and a tool that acts on the
answer visits a file two levels away from the name under the cursor.
Rejected: a new `tired-chain-component` thing.  No existing reader asks
for that name, so the useful reader would stay on `filename` and keep
the wrong answer.  Rejected: a `directory` thing.  Emacs core knows no
such thing, so the name would serve Tired alone while `filename` keeps
the old answer for every other tool.  Rejected: an advice on
`ffap-file-at-point`.  A major mode that advises a core function of
another package changes the answer for every caller in the buffer, and
`ffap-file-at-point` runs its existence test before any hook, so no
alist entry can pre-empt the whole-chain text.  Rejected: a
`with-eval-after-load` form that only prepends the Tired finder.  The
built-in finder then answers a second file target for the same row, and
Embark asks the reader which one to act on.

## Consequences

`embark-act` on a collapsed row reaches the component under point, and a
row inside an inserted directory reaches its own file.  A reader without
Embark sees the same answers through `thing-at-point` alone, because the
finder reads the provider and adds no logic of its own.  The finder list
waits for a late Embark load through `after-load-functions`, so a listing
that started first still takes the finder.  A byte-compiled `tired.el`
names `embark-target-finders` in a `defvar` and checks `boundp` before a
write, so a session without Embark keeps no finder variable.
