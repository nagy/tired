# AGENTS.md — tired.el

## Overview

Single-file Emacs package (`tired.el`) that shows a directory as a
`tabulated-list-mode` buffer.  Entries come from `directory-files` and
`file-attributes`.  The package never parses `ls -l` output.  Entry
points are `M-x tired` and `M-x tired-find-directory`.

Minimum Emacs version is 31.1.  Emacs 31 changed
`tabulated-list-print-entry` to require a vector of column descriptors
in `tabulated-list-entries`; a list row is a type error.  The code uses
that vector form, so earlier Emacs versions cannot run it.

The file commands act at once, without a confirmation question.  A
removed path goes into a session trash, so `tired-undo` reverses the
last operation.  Inline rename editing and asynchronous loading live
in git-bug issues, not in code.

## Build & test

```sh
nix build                       # package
nix flake check                 # package + ERT suite + lint check
nix develop                     # Emacs and git
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile tired.el tired-tests.el
emacs --batch -L . -l tired-tests.el -f ert-run-tests-batch-and-exit
```

Nix outputs:

- `packages.tired` (= `default`) is `nix/default.nix` (`melpaBuild`).
  Its `checkPhase` byte-compiles with warnings as errors and runs the
  ERT suite.
- `checks.lint` is `nix/lint.nix`: `package-lint` and `checkdoc`.
- Systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
  `aarch64-darwin`.  `meta.platforms` is `lib.platforms.unix` because
  the package is pure Elisp.
- `devShells.default` provides Emacs, git and the treefmt wrapper.
- `nix fmt` formats the repo through `treefmt-nix` (nixfmt only).
  `treefmt-nix.flakeModule` also adds the `checks.treefmt` check.

Version string is `0.1.0-unstable-<commit date>`, derived from the flake
source info.  A commit changes the version.  `postPatch` rewrites the
`;; Version:` header to the same string before `melpaBuild` derives the
ELPA package version from the build argument.

## Architecture

Files:

- `tired.el` — the whole package
- `tired-tests.el` — ERT suite
- `nix/default.nix` — `melpaBuild` expression
- `nix/lint.nix` — checkdoc + package-lint check
- `flake.nix` — flake outputs
- `README.org` — user documentation
- `GLOSSARY.md` — domain terms
- `docs/adr/` — architectural decision records
- `LICENSE` — AGPLv3

Data flow:

1. `tired--read-entries` calls `directory-files-and-attributes` and
   builds a hash table of `tired-entry` structs.  `tired--make-entry`
   fills each struct from those attributes, so each file takes one
   directory read and one stat, with no second `expand-file-name` call.
2. `tired--tables` holds one such table per shown directory.  The root
   directory is always present.  `tired--inserted` holds the directories
   whose children appear in the listing; the user adds them with
   `tired-insert-subdir` or `tired-toggle-subdir`.
3. `tired--sorted-directory-entries` selects visible entries (dotfile
   and name filter) and sorts them for one directory.  Directories
   always come first.
4. `tired--display-rows` walks the tree depth-first and returns
   `(ENTRY . DEPTH)` conses.  Children of inserted directories follow
   their parent row.  A `file-truename` set stops symlink cycles.
   `tired--collapsed-display-entry` replaces a directory entry with a
   clone of the file at the end of a single-entry chain.  Collapse runs
   after sorting, so the row keeps the directory's position.  Results
   cache in `tired--collapse-cache`, keyed by the chain's top directory.
   A collapsed row suppresses its inserted children.
5. `tired--tabulated-entries` renders each row as a vector, indented by
   its depth.  Emacs 31 requires the vector form.
   `tabulated-list-print` draws the buffer.  `tired--size-cell` fills
   the size column.  With `tired-directory-size' on, it calls
   `tired--directory-total', which walks the subtree through
   `tired--subtree-size' and leaves the result in `tired--size-cache'.
   The binding in `tired--tabulated-entries` covers one redraw, so a
   nested directory costs one read per redraw.
6. `tired--apply-selection-overlays` highlights paths listed in
   `tired--selection`.  The selection is buffer-local and transient.
   `tired--selection-set` mirrors it as a hash set for O(1) membership.
   `tired--selection-size` sums the sizes of selected non-directory
   entries for the mode line.  `tired--selection-targets` reads the
   selection first, then `tired--region-entries`, then the entry at
   point; a command that acts on the region deactivates it.
7. `tired--entry-visible-p` applies the narrow snapshot, then the
   dotfile setting, then the name filter.  `tired--narrow-ancestors`
   adds the directories that contain a narrowed path, so inserted
   sections keep their parent rows.
8. `tired--reload-tables` re-reads the root directory and every inserted
   directory, and drops inserted directories that vanished.
   `tired-refresh` calls it, prunes dead selection and narrow paths and
   then calls `tired--redraw`.
9. `tired--redraw` sizes the name column from the longest visible row,
   clamped between `tired-name-column-min-width' and the window width
   minus the fixed columns.  It rebuilds the header line, prints the
   rows, restores point by entry path and reapplies the selection
   overlays.  Commands that only change the view (filter, sort,
   dotfiles, insert) call `tired--redraw`, not `tired-refresh`.
10. `tired--window-size-changed` runs from `window-size-change-functions`
    and redraws every visited tired buffer with the width of its own
    window, so a resize refits the name column.
11. `tired--sync-watches` keeps one file notification watch per shown
    directory: the root plus every inserted directory.  It runs at the
    end of `tired--redraw`, so inserting or removing a section updates
    the watch set.  A notification schedules `tired--auto-revert-now`
    through a debounce timer.  The callback captures its buffer, and
    `kill-buffer-hook` calls `tired--stop-watching`.
12. `tired-filter` opens a minibuffer, hooks `after-change-functions`,
   and calls `tired--apply-filter` on every keystroke.  RET keeps the
   value, C-g restores the previous filter.

Jumping and bookmarks:

- `tired-jump` derives the target directory from the current buffer:
  `tired--directory` in a tired buffer, `buffer-file-name` in a file
  buffer, `default-directory` otherwise.  From a tired buffer the target
  is the parent directory and the anchor is the shown directory, so
  point lands on the directory that was left.
- `tired-bookmark-make-record` stores the directory in the record and
  `tired-bookmark-jump` reopens it.

Copy commands:

- `tired-copy-path` copies absolute paths.  `tired-copy-relative-path`
  makes paths relative to `tired--directory`.  `tired-copy-project-path`
  makes paths relative to `(project-root (project-current nil dir))` and
  raises `user-error` outside a project.  All three share
  `tired--copy-targets`, so selection handling stays in one place.

File operations:

- `tired--apply-to-targets` runs one function over the targets, deepest
  path first, then clears the selection, refreshes and reports.  A
  failing target does not stop the rest, and
  `tired--report-operation` lists every failure in the *Warnings*
  buffer.
- `tired-delete` moves each target to `tired-trash-directory`.
  `tired-copy` and `tired-move` move a replaced destination there
  first, and roll the destination back when the copy or the move
  fails.  `tired--trash-name` appends a timestamp and a counter, so a
  repeated name stays unique.  `tired--restore-path` moves a path back
  and does nothing when the original exists again.
- `tired-copy` prompts for a directory.  `tired-move` prompts for a
  full path when it has one target and the typed name is no directory,
  otherwise for a directory.  `tired-mkdir` and `tired-touch` start
  from `tired--creation-directory`: the directory at point when point
  names one, else `tired--directory`.
- Every command calls `tired--push-undo` with a description and one
  function that reverts the whole operation.  The function moves
  paths back from the trash, so no byte is destroyed.  With
  `tired-undo-push-functions` set, that hook takes the pair and
  `tired--undo-actions` stays empty.  Otherwise `tired-undo` pops and
  runs the pair, and `tired--refresh-buffers` redraws every tired
  buffer.

Sorting is implemented in `tired--lessp`, not in `tabulated-list`,
because tabulated-list cannot keep directories first while sorting other
columns.  `tabulated-list-format` therefore marks every column as
unsortable and the header line stays plain.  `tired-sort` prompts for a
column and redraws.

## Conventions

- Package prefix is `tired-`.  Private helpers use `tired--`.
- Public commands carry an `;;;###autoload` cookie only when they are
  entry points (`tired`, `tired-mode`, `tired-find-directory`).
- Every function has a docstring.  `checkdoc` must pass.
- Byte-compilation with warnings as errors must pass.
- Faces inherit from Dired faces (`dired-directory`, `dired-symlink`,
  `dired-symlink-filename`, `dired-broken-symlink`, `dired-special`,
  `dired-ignored`), so a user Dired theme setting reaches tired rows.
  `dired-font-lock-keywords` itself stays unused: those keywords match
  the `ls` line layout and call `dired-move-to-filename`, which needs a
  mark column and an inode field on one line.  A tabulated-list row
  keeps its columns apart.
- Name cells carry both `face` and `font-lock-face`, as
  `package-menu--print-info-simple` does.  `face` covers a buffer with
  font-lock off.  `font-lock-face` survives
  `font-lock-unfontify-region`, which removes `face`.
- `tired-mode` does not set `font-lock-defaults`.  No upstream
  tabulated-list mode does: the printer already built the row strings,
  so colorization belongs in the entry data.  `proced` uses font-lock
  but derives from `special-mode`.  Do not add a global keyword set for
  the wdired-style editing issue (d7a0ef4): a suffix rule would
  recolour a half-typed name.  Recolour one name cell region instead if
  that feature wants it.
- AGPL3+ header in every Elisp file.
- File commands never ask a confirmation question and never call a
  shell.  Removal goes through `tired--trash-move`, never through
  `delete-file` or `delete-directory`, so undo can restore the path.

## Gotchas

- Flake sources are git-tracked files only.  `git add` a new file before
  `nix flake check`, or the build cannot see it.
- `tabulated-list-print` erases the buffer, so it strands the mark on
  line one.  `tired--redraw` records `(tired--entry-at (mark t))`
  before the print and `tired--restore-mark` sets the mark marker back
  on that entry's row.  Set the mark marker with `set-marker`, not
  `push-mark`, or every redraw grows the mark ring.  A deleted row
  leaves the mark where the reprint put it.
- `tired--region-entries` keeps the row on which the region ends out,
  because the region ends at that line's start.  Without the test the
  shift-down gesture would cover one row too many.  The region needs
  `transient-mark-mode`; batch Emacs starts with the mode off, so the
  region tests enable it first.
- Two highlights coexist: `region` for the active region and
  `tired-selected-face` for the selection.  Keep the selection
  precedence in `tired--selection-targets`; do not merge the region
  into `tired--selection`, because `tired--redraw` and
  `tired--prune-selection` would then prune rows the region covers.
- `tired-trash-directory` lives on `temporary-file-directory`, which is
  usually another file system than the listed directory.  `rename-file`
  then copies the bytes and deletes the source, so a delete of a large
  tree costs a copy.  A path deleted before a reboot does not come back.
- Undo of an overwriting copy leaves the replaced copy in the trash.
  Undo of a delete leaves nothing behind.  Do not try to empty the
  trash inside an undo function: the trash holds the previous bytes of
  the very path the undo restores.
- `tired--apply-to-targets` sorts targets deepest first, so a selection
  that holds a directory and its child deletes the child first.  The
  undo function walks the trash list in push order, parents first,
  because a child cannot move back before its parent exists.
- `tired--restore-path` stays silent when the original path exists
  again, so a user file at that path never loses its bytes.
- `tired-tests--with-trash` binds a private trash directory, an empty
  undo stack and an empty `tired-undo-push-functions'.  Use it for any
  test that removes or replaces a path, or the test writes into the
  real session trash.
- `tired--selection` stores absolute paths.  Pruning looks the path up
  in the table of its own directory, so a renamed or recreated file
  drops out of the selection.  `tired--selection-set` mirrors the list,
  and `tired--narrowed-set` mirrors the narrow snapshot.  Change either
  list only through `tired--set-selection` or `tired--set-narrowed`, or
  the hash set and the list disagree.
- `tired--narrowed` is a snapshot of the selection plus ancestor
  directories.  It does not follow later selection changes.  Pruning
  after refresh drops vanished paths and widens when the snapshot
  becomes empty.  Ancestors matter: the tree walk cannot reach a narrowed
  entry inside an inserted section unless the parent rows stay visible.
- Inserted sections are ordinary rows with a depth, not synthetic header
  rows.  Every row stays selectable and every ID is a real `tired-entry'.
  Do not add nil-ID header rows for dired parity.
- `tired--display-rows` guards recursion with `file-truename`.  Without
  it, a symlink back to an ancestor loops forever.
- Single-child collapse inspects every listed directory on refresh, so a
  root with many subdirectories costs one `directory-files` call each.
  The cache lives only until the next refresh.  Chain inspection stops at
  the first branch, and hidden files count as entries.
- A collapsed row stores the real file path with a relative display name.
  Selection, narrow and copy use the path.  Do not derive the file from
  the display name.
- Collapse runs after `tired--sorted-directory-entries`, so a collapsed
  row keeps the top directory's sort position.  Sorting by size or time
  therefore orders it by the directory's values while the columns show
  the file's values.  This trade-off keeps the tree stable.
- Auto-revert watches cover the root directory and inserted directories
  only.  Collapsed sections stay unwatched on purpose.  Emacs lock files
  (`.#name`) are filtered out of the notification callback.
- Batch Emacs does not dispatch file notification events during
  `sit-for' or `accept-process-output'.  The ERT tests stub
  `file-notify-add-watch` instead of waiting for real events.
- `file-attributes` does not follow symlinks by default.  The struct
  records the link type and target, and commands use `file-directory-p`
  to follow directory symlinks.
- `tired--make-entry` resolves each symbolic link once to fill the
  BROKEN flag, so a link that does not resolve gets
  `tired-broken-symlink-face`.  A circular link counts as broken.  The
  user option `tired-check-symlinks` turns the check off, because a
  remote directory costs one round trip per link.
- `tired-name-faces` colors a name from a regexp.  `tired--name-face`
  applies a fixed order: directory, broken link, user rule, ignored
  suffix, symlink, special file.  The first rule that matches wins.
  A directory never takes a user rule, because the directory face marks
  the tree structure.
- Recursive directory sizes stay off by default, because the option
  makes every refresh read every directory below the shown one.
  `tired--subtree-size` never follows a symbolic link, so a link cycle
  cannot loop.  Do not hoist `tired--size-cache` above one redraw:
  nothing invalidates an entry when a file changes.
- `tired--ignored-regexp` caches a regexp for
  `completion-ignored-extensions`, an autosave name and a lock file
  name.  `tired--ignored-source` holds the value the cache derives
  from, so a changed variable rebuilds the regexp.  The ignored face
  applies to files and links, never to directories.
- The header line is rebuilt on every refresh.  `tired--header-base`
  holds the string from `tabulated-list-init-header`, so the directory
  title can be prepended without losing the column labels.
- Rows must be vectors, not lists.  Emacs 31 `tabulated-list-print-entry`
  calls `aref` on them.  Do not "simplify" `tired--row` back to `list`.
- In batch Emacs, `pop-to-buffer` works but no window layout exists.
  Tests therefore assert buffer state, not window state.
