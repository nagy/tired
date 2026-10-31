# AGENTS.md — tired.el

## Overview

A directory editor on `tabulated-list-mode`.  Entries come from
`directory-files-and-attributes`, never from `ls -l` output.  A row is
a `tired-entry` or a `tired-section`, where a section belongs to a file
that a handler can read.  `tired.el` is the entry point and requires
three libraries, so a user command, a key and a lisp caller stay the
same.

Minimum Emacs 31.1, because `tabulated-list-print-entry` wants a
vector row there.

`README.org` holds the user view: keys, options, handlers, the shell
command.  `docs/adr/` records why the design looks like this.  Read the
README before you document a command.

## Files

- `tired.el` — entry point: commentary, the three requires, the evil hook
- `tired-core.el` — entries, section framework, display, selection,
  redraw, watches, `tired-mode`
- `tired-sections.el` — the Org, Emacs Lisp, Rust, Markdown, Cargo and
  SQLite handlers
- `tired-file-ops.el` — copy, move, rename, delete, undo, mkdir,
  touch, shell
- `tired-evil.el` — optional evil bindings
- `tired-tests.el` — loads the suites
- `tired-tests-fixtures.el` — shared fixtures, helpers and setup
- `tired-tests-core.el`, `tired-tests-sections.el`,
  `tired-tests-file-ops.el`, `tired-tests-evil.el` — one suite per library
- `flake.nix`, `README.org`, `GLOSSARY.md`, `docs/adr/`, `LICENSE`

## Build & test

```sh
nix build                       # package
nix flake check                 # package + ERT suite + lint check
nix develop                     # Emacs with evil, git and treefmt
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile *.el
emacs --batch -L . -l tired-tests.el -f ert-run-tests-batch-and-exit
```

- `packages.tired` (= `default`) is an inline `melpaBuild` wrapped in
  `makeOverridable`.  Arguments: `emacs`, `emacsPackages`, `melpaBuild`,
  `version`, `treesitGrammars`, `evil`.  One Emacs package set supplies
  every dependency, so an `emacs` override moves all of them.
  `melpaBuild` closes over the Emacs of its package set, so an `emacs`
  argument on the build does nothing; the default `emacsPackages` builds
  a wrapper that carries evil instead.  `packageRequires` stays empty, so
  the metadata names no elisp dependency.  `checkInputs` holds the
  tree-sitter Rust, Markdown and TOML grammars, and `checkPhase` exports
  `TREESIT_EXTRA_LOAD_PATH`; a missing grammar skips its test instead of
  failing.
- `checks.lint` is `mkLint`: `package-lint` on `tired.el`, `checkdoc` on
  the five libraries.
- Systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
  `aarch64-darwin`.  `meta.platforms` is `lib.platforms.unix`.
- `nix fmt` formats the repo through `treefmt-nix` (nixfmt only).
- The version string is `0.1.0-unstable-<commit date>`, derived from the
  flake source info.  `postPatch` rewrites the `;; Version:` header, so
  package.el, package-lint and the store path agree.

## Architecture

Dependencies point one way: `tired-core` requires no sibling,
`tired-sections` and `tired-file-ops` require `tired-core`, and `tired`
requires all three.  When `tired-core` names a command from another
library, as `tired-mode-map` does, it adds a `declare-function`.

1. `tired--read-entries` builds one hash table per shown directory from
   `directory-files-and-attributes`, so a file costs one stat and no
   second name expansion.  `tired--tables` holds the tables,
   `tired--inserted` the directories whose children show.
2. `tired--sorted-directory-entries` filters and sorts one directory in
   Elisp (`tired--lessp`), so directories stay first under every key.
3. `tired--display-rows` walks depth-first and returns `(ROW . DEPTH)`
   conses.  A `file-truename` set stops symlink cycles.
   `tired--directory-entry-p` decides whether a row takes children and
   counts a symlink that resolves to a directory.
4. `tired--collapsed-display-entry` swaps a directory row for the leaf
   of a single-entry chain, a file or a directory.  It runs after
   sorting, so the row keeps the directory position, and it caches per
   refresh in `tired--collapse-cache`, together with the directories
   that the chain walk visited.
5. `tired-file-sections` picks a handler through `tired-file-handlers`,
   runs it in a temporary buffer, and turns the plists into
   `tired-section` structs.  The result caches in `tired--sections` by
   modification time, so a redraw does not re-parse.
6. `tired--redraw` walks the tree once into `tired--rows`, sizes the name
   column, prints vector rows, restores point by row key, the mark and
   the window views, repaints the selection, syncs the watches and
   rebuilds the mode line.  A view change (filter, sort, dotfile,
   hidden, insert, expand, fold) calls it.  `tired-refresh` re-reads the
   tables, prunes dead state and then redraws.
7. Selection and region stay apart.  `tired--selection` holds paths and
   `tired--selection-set` mirrors it; `tired--region-entries` reads the
   region.  `tired--selection-targets` takes the selection first, then
   the region, then the row at point.
8. `tired--sync-watches` watches the root, every inserted directory,
   every expanded file and every skipped chain level.  `tired--file-changed`
   debounces into `tired--auto-revert-now`, and `kill-buffer-hook` stops
   the watches.  `tired--auto-revert-enabled-p` reads both
   `tired-auto-revert` and `tired-auto-revert-remote`, so a remote
   buffer stays unwatched unless the user opts in.
9. `tired-filter` reads the minibuffer and schedules a redraw through
   `tired-filter-delay`; the exit and quit paths flush at once.
10. `tired--apply-to-targets` runs one function over the targets, deepest
    path first, then clears the selection, refreshes and reports.  Each
    command pushes one undo function.  `tired-rename` stays outside that
    helper: it reads the row at point alone, so the selection and the
    region stay untouched.
11. `tired-evil.el` is a second library.  `tired.el` installs its hook
    after `provide`, so both load orders work.
12. `tired--paint-row-mouse` runs after `tabulated-list-print` and gives
    every printed line `mouse-face` and the `help-echo` from
    `tired--mouse-help`, so the whole row reacts.  Bind
    `inhibit-read-only`, because the listing buffer is read-only.
    `tired--click-row` reads the row under a click from the buffer of the
    clicked window.  `tired-mouse-find-file-other-window` opens that row
    in another window and `tired-mouse-toggle` runs `tired-toggle-subdir`
    on it.  `tired--click-selects-row` returns nil
    and takes the `follow-link` binding, so one click selects.
13. `tired-context-menu` fills the `mouse-3` menu from the row under the
    click.  `tired-mode` adds it to `context-menu-functions` with a
    buffer-local hook, and the guard reads `(boundp
    'context-menu-functions)`, because `mouse.el` owns the variable.  A
    menu click leaves point alone, so each row command goes through
    `tired--context-command` and moves to the clicked position first.

## Conventions

- Package prefix `tired-`, private helpers `tired--`.
- Public commands carry `;;;###autoload` only as entry points (`tired`,
  `tired-other-window`, `tired-mode`, `tired-noselect`,
  `tired-find-file-mode`, `tired-jump`).
- Every function has a docstring, `checkdoc` passes, and byte
  compilation with warnings as errors passes.
- `tired-mode-menu` mirrors the key map on the menu bar.  Add a command
  when its key alone does not explain it.  An `:active` form reads the
  listing when the menu opens; use `(bound-and-true-p VARIABLE)` for a
  variable that another library owns.
- A new key belongs in `tired-mode-map` and in `tired-evil-keys`, and in
  `tired-evil-visual-keys` when it reads the region.  A mouse event
  belongs in `tired-mode-map`, and in `tired-evil-keys` only when evil
  shadows it.
- `tired` and `tired-other-window` go through `tired--display`: it
  hands `tired-display-buffer-action` or `tired-other-window-action` to
  `display-buffer` and then selects the returned window, because
  `tired-jump` moves point in the listing after the call.
- Name cells carry `face` and `font-lock-face`, so a name keeps its color
  with font-lock off and after `font-lock-unfontify-region`.
- `tired-mode` sets no `font-lock-defaults`: the printer built the
  strings, so color belongs in the entry data.
- File commands never ask a confirmation and never call a shell, except
  `tired-do-shell-command`.  Removal goes through `tired--trash-move`,
  never through `delete-file`, so undo can restore the path.
- AGPL3+ header in every Elisp file.

## Gotchas

- `evil-define-key` is a macro, so `tired-evil.el` uses the function
  `evil-define-minor-mode-key` with `key-parse`.  `define-key` reads
  `"RET"` as three characters.  A remap entry reads
  `"<remap> <evil-replace>"`, because `key-parse` treats the bracket form
  as literal characters.
- `define-minor-mode` defines a defcustom, so a mode without
  `:group 'tired` fails byte compilation.
- `tabulated-list-mode` binds `follow-link` to `mouse-face`, and with
  that value a click on a `mouse-face` row arrives as `mouse-2`, so a
  single click would open a row.  `tired-mode-map` binds `follow-link`
  to `tired--click-selects-row`, which returns nil, and `mouse-on-link-p`
  calls that binding as a predicate.  Do not drop the binding.
- `tired--column-label` propertizes each header label with a key map for
  `[header-line mouse-1]` and `[header-line mouse-2]`.  Emacs 31 builds
  the header line from those labels and keeps their text properties, so
  the clicks reach `tired-sort`.  Bind both buttons: `follow-link` can
  turn a click into the second one.
- Evil binds `down-mouse-1` in its motion state map, so a double click
  selects text and never reaches `tired-mouse-toggle`.  Only `mouse-2`
  needs a key in `tired-evil-keys`, and no mouse event goes in
  `tired-evil-visual-keys`.
- Rows must be vectors.  Emacs 31 calls `aref` on them.
- A section row is not selectable.  Do not add one to
  `tired--selection`: the selection and the narrow snapshot key by path
  alone, so change them only through `tired--set-selection` and
  `tired--set-narrowed`.
- `tired-entry-path` reads an entry struct.  Test `tired-entry-p` before
  the call, or a section row signals `wrong-type-argument`.
- Evil remaps `evil-replace` to `tired-rename`, so `r` renames a row and
  `R` keeps `tired-move`.
- Use `tired--directory-entry-p`, not `tired-entry-dirp`, to decide
  whether a row takes children.  `DIRP` covers real directories only, and
  the sort key, the size column and the directory face read it.
- `minibuffer-contents` returns the current buffer text outside a
  minibuffer, so read it before `with-current-buffer`.
- `tabulated-list-print` erases the buffer, and the erase strands the
  mark, the window point and the display start on line one.
  `tired--redraw` repairs all three and sets the window point before the
  window start.  Use `set-marker`, not `push-mark`, or every redraw grows
  the mark ring.
- The section read passes VISIT to `insert-file-contents`, so the buffer
  carries `buffer-file-name` and no modified flag; without it every
  expand raises a kill question.  A handler selects its own major mode
  and returns plists.
- A handler takes no hard dependency: it requires its grammar at run
  time and returns nil without it, and byte compilation needs a
  `declare-function` for every outside function it calls.
- Section depth subtracts the level of the first section, or an Org file
  whose first heading is `**` indents from a phantom parent.  A fold
  hides descendants until a section of equal or lower level appears.
- A handler with no real line gives each section a distinct synthetic
  `:line` and an `:action`.  Fold state and point restore key on
  `(PATH . LINE)`.
- The org narrow option stays out of the parsed section, so
  `tired--org-open-heading` reads it at open time and a change needs no
  re-parse.
- The Emacs Lisp handler skips whitespace and comments with
  `forward-comment` before it records a form start.
- A hidden row drops before its sections read, even when VISIBLE-ONLY is
  nil, so the width pass and the selection never see a hidden path.
- The percent sign needs doubling in the header title and in the cached
  mode line part, because both readers start a substitution at one sign.
  Do not escape `tired--header-base`: it holds the substitutions that
  `tabulated-list-init-header` wrote.
- `tired--rows` holds a row list for one redraw only.  Do not keep the
  value: the filter, the insert set and the fold set change without a
  refresh.
- Key the size memo with `tired--size-key`, never with `file-truename`,
  because one name expansion per component halves a cold walk.  Do not
  add a `post-gc-hook` clear or weak keys: one walk triggers several
  collections and the table would empty itself.  The time window in
  `tired-size-cache-ttl` is the one freshness rule.
- `tired-noselect` owns `default-directory`.  `tired-mode` runs before
  the directory is known, so it must not set the variable.  The
  function also feeds `recentf-add-file` while `recentf-mode` holds,
  because a Tired buffer visits a directory and no file name reaches
  `recentf-track-opened-file`.
- The buffer name keys the directory, so `tired-noselect` reuses the
  buffer.  A renamed buffer would make a second one.
- A nil `tired-trash-directory` means the per-process directory under
  `temporary-file-directory`.  Do not compute that default inside the
  `defcustom` form, so a user who sets nil still gets the session path.
- The trash usually sits on another file system, so `rename-file` copies
  and then deletes, and a reboot loses the path.  Undo of an
  overwriting copy leaves the replaced copy in the trash.  Never empty
  the trash inside an undo function: it holds the bytes the undo
  restores.
- `tired--apply-to-targets` sorts deepest first, and the undo function
  walks its trash list parents first, because a child cannot move back
  before its parent exists.  `tired--restore-path` stays silent when the
  original path exists again.
- Single-child collapse and the size walk skip a remote directory,
  because every read there costs a network round trip.- A collapsed row takes the leaf of the chain, so `tired-entry-path`
  names the leaf and the name holds the relative path.  The leaf can
  be a directory: `tired--display-rows` walks the children of `display`
  rather than of `entry`, or the insert of such a row shows nothing.
  `tired--entry-for-path` reads a parent table by file name and misses
  a collapsed row, so look the row up in `tired--display-rows`.
- A hidden name ends a chain before that level, so a hidden middle
  directory keeps its subtree out of the listing.  `tired--hidden-p`
  reads the whole joined name and cannot do that test.
- The collapse cache value is a cons of the leaf and the visited
  directories, and `tired--chain-paths` feeds the watched paths from
  the second part.  Drop a chain result when its directory leaves the
  tree, or the watch outlives the row.
- `tired-tests--with-trash` binds a private trash, an empty undo stack
  and an empty `tired-undo-push-functions`.  Use it for any test that
  removes or replaces a path.
- Batch Emacs dispatches no file notification event during `sit-for`, so
  the tests stub `file-notify-add-watch`.  Batch Emacs also has no window
  layout, so a test asserts buffer state, not window state.
- A test never reaches the network.  `tired-tests--with-remote` stubs
  `file-remote-p` for a real temporary directory, so the remote guards
  run without a TRAMP handler.  `tired-remote-listing-stays-offline`
  covers the watch, the collapse walk and the size walk at once.
- Batch Emacs sends no mouse event, so a test builds one with
  `tired-tests--click`: a posn of `(WINDOW POINT)` is enough for
  `event-start`, `posn-window` and `posn-point`, and `mouse-set-point`
  takes it.
- Flake sources are git-tracked files only.  `git add` a new file before
  `nix flake check`, or the build cannot see it.
- In batch Emacs the region needs `transient-mark-mode`, which starts
  off, and no command loop runs `post-command-hook`, so a test that needs
  either enables the first or runs the second.
