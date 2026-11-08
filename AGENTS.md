# AGENTS.md — tired.el

## Overview

A directory editor on `tabulated-list-mode`.  Entries come from
`directory-files-and-attributes`, never from `ls -l` output.  A row is
a `tired-entry` or a `tired-section`, where a section belongs to a file
that a handler can read.  A user command, a key and a lisp caller stay
the same because `tired.el` requires every library.

Minimum Emacs 31.1, because `tabulated-list-print-entry` wants a vector
row there.  `README.org` holds the user view and `docs/adr/` the
reasons.

## Files

- `tired.el` — entry point: commentary, the five requires, the public
  commands (`tired`, `tired-other-window`, `tired-noselect`,
  `tired-find-file-mode`, `tired-jump`, `tired-project`,
  `tired-clear-caches`), the
  evil hook
- `tired-core.el` — entries, section framework, display, selection,
  redraw, watches, the size caches, `tired-mode`
- `tired-sections.el` — the Org, Emacs Lisp, Rust, Python, Go,
  Markdown, Cargo, SQLite and tar handlers
- `tired-elements.el` — the Elements column, its dissector hook, the
  global count caches and the idle queue
- `tired-file-ops.el` — copy, move, rename, delete, undo and redo, mkdir,
  touch, shell, and the in-place name edit
- `tired-export.el` — the CSV, text and `rclone lsjson` exports and
  their read-only buffers
- `tired-evil.el` — optional evil bindings
- `tired-tests.el` — loads the suites
- `tired-tests-fixtures.el` — shared fixtures, helpers and setup
- `tired-tests-core.el`, `tired-tests-sections.el`,
  `tired-tests-elements.el`, `tired-tests-file-ops.el`,
  `tired-tests-export.el`, `tired-tests-evil.el` — one suite per
  library
- `flake.nix`, `README.org`, `GLOSSARY.md`, `docs/adr/`, `LICENSE`

Each library keeps a "Design notes" list in its `;;; Commentary:`.  Read
the notes of the file that you change.  This file holds only the rules
that span more than one file.

## Build & test

```sh
nix build                       # package
nix flake check                 # package + ERT suite + lint check
nix develop                     # Emacs with evil, git and treefmt
nix fmt                         # nixfmt only
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile *.el
emacs --batch -L . -l tired-tests.el -f ert-run-tests-batch-and-exit
```

Run `nix flake check` before a commit.  A new file must be `git add`-ed
first, because the flake sources take git-tracked files alone.

- `packages.tired` (= `default`) is an inline `melpaBuild` wrapped in
  `makeOverridable`.  Arguments: `emacs`, `emacsPackages`, `melpaBuild`,
  `version`, `treesitGrammars`, `evil`.  One Emacs package set supplies
  every dependency.  `melpaBuild` closes over the Emacs of its package
  set, so an `emacs` argument on the build does nothing.
  `packageRequires` stays empty, so the metadata names no elisp
  dependency.  `checkInputs` holds the tree-sitter Rust, Python, Go, Markdown
  and TOML grammars, and `checkPhase` exports
  `TREESIT_EXTRA_LOAD_PATH` and puts `zstd` on the path for the archive
  fixtures.  A missing grammar skips its test instead of failing.
- `checks.lint` is `mkLint`: `package-lint` on `tired.el`, `checkdoc` on
  the seven libraries, and `relint` on the same seven.  `checkdoc` and
  `relint` exit 0 while they report, so the check gates on output.
- Systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
  `aarch64-darwin`.  `meta.platforms` is `lib.platforms.unix`.
- The version string is `0.1.0-unstable-<commit date>`, derived from the
  flake source info.  `postPatch` rewrites the `;; Version:` header, so
  package.el, package-lint and the store path agree.

## Architecture

Dependencies point one way: `tired-core` requires no sibling,
`tired-sections`, `tired-elements`, `tired-file-ops` and
`tired-export` require `tired-core`, and `tired` requires all five.
`tired-evil` requires `tired`.  A call into another library takes a
`declare-function`, so no load-time dependency forms.  `tired.el`
installs the evil hook after `provide`, so both load orders work.

Package prefix `tired-`, private helpers `tired--`.

Every `;;;###autoload` cookie for a command sits in `tired.el`, because
the file that holds a cookie names the file that its autoload loads.  A
cookie in `tired-core` would load the core alone, so `M-x tired` from a
`package.el` install would reach a void `tired-file-sections-elisp` and
a void `tired-delete`.  A command that other libraries call, such as
`tired-noselect`, stays in `tired.el` for that reason, and `tired-mode`
carries no cookie at all: `tired-noselect` runs the mode.
`tired-evil.el` keeps its own cookie, because the file requires
`tired`.

## Cross-file rules

- Every function has a docstring, and `checkdoc`, `relint` and byte
  compilation with `byte-compile-error-on-warn` pass.  A
  `define-minor-mode` form defines a defcustom, so it needs
  `:group 'tired` or byte compilation fails.  Every Elisp file carries
  the AGPL3+ header.
- `tired-mode-menu` mirrors the key map on the menu bar.  Add a command
  when its key alone does not explain it.  An `:active` form reads the
  listing when the menu opens, and it uses `(bound-and-true-p VARIABLE)`
  for a variable that another library owns.
- The mode map remaps `csv-mode`, `text-mode` and `js-json-mode` to the
  three export commands.  The JSON mode reads `js-json-mode`.  A remap
  reaches a key that runs the major mode command, not `M-x`.
- A new key belongs in `tired-mode-map` and in `tired-evil-keys`, and in
  `tired-evil-visual-keys` when it reads the region.  A mouse event
  belongs in `tired-mode-map`, and in `tired-evil-keys` only when evil
  shadows it.  Evil shadows `i`, `e`, `E` and `TAB` in visual state, so
  that table never names a subdir, expand, collapse or toggle command.
- Some commands carry no binding on purpose: `tired-clear-caches`,
  `tired-edit-names`, `tired-commit-edits`, `tired-abort-edits`,
  `tired-insert-subdir`, `tired-expand-file`, `tired-collapse-file` and
  `tired-project` take `M-x` and the menu alone.  `tired-undo` and
  `tired-redo` take the `<undo>` and `<redo>` keysyms alone, so no
  printable key and no menu entry reaches them.  `tired-tests-core` and
  `tired-tests-file-ops` fail when a binding returns.
- Every file command clears the selection through
  `tired--clear-selection`.  Only the interactive `tired-select-none`
  clears the deletion flags too, so a copy or a move never cancels a
  pending deletion.  A flagged path never joins the selection:
  `tired--set-selection` drops it, and a selection command that touches
  a flagged row either drops the flag or skips the row.
- A section row is not selectable and stands for its file.  Do not add
  one to `tired--selection`: the selection and the narrow snapshot key
  by path alone, so change them only through `tired--set-selection` and
  `tired--set-narrowed`.  A region over a section row reaches that row's
  file instead, through `tired--display-entry-table`.
- A name cell carries `face` and `font-lock-face`.  `tired--section-cell`
  mirrors the faces of a handler label the same way.  A name face
  inherits its `dired-` partner, and `tired-selected-face` inherits
  `dired-marked`, so a Dired theme reaches a Tired row.  A face for a
  flagged row writes `:extend t`, because its overlay covers the line
  and the newline.  A handler face writes `:group 'tired`, because
  `tired-sections` holds no `defgroup`.
- A collapsed row answers the `filename` thing one chain component at
  a time: `tired--filename-at-point` and `tired--name-bounds` split the
  name at the slashes, and point on a slash names the component that
  the slash closes.  `tired--name-region` keeps the whole name, because
  the mouse face and the in-place name edit read that region.
- `embark` reads the `filename` thing for its file target, so
  `tired.el` gives `embark-target-finders` a buffer-local Tired finder
  and drops the two built-in file finders.  The swap runs from
  `tired-mode-hook` and from `after-load-functions`, so both load
  orders work, and it checks `boundp` because Embark stays optional.
  One finder per row keeps `embark-act` unambiguous.
- A library that paints overlays on the printed rows uses
  `tired-after-redraw-hook` and no call from `tired-core`.  A body of the
  hook never runs a view command, because the redraw calls the hook.
- A command that changes the disk prints exactly one line through
  `message`, and no `display-warning` runs beside it.  The line names the
  verb, the count, the destination and the first failed path.
- A file command signals a user error while `tired--name-edit` holds:
  `tired--apply-to-targets` refreshes, `tired--redraw` draws nothing
  then, and the listing would disagree with the disk.
- A shown directory that left the disk keeps no entry table, so a
  refresh and a timer print an empty listing and never a
  `file-missing`.  A command that acts on one path, such as
  `tired-rename`, signals a `user-error` for a path that left the disk,
  and `tired--apply-to-targets` counts that path as a failure.
- A file command never asks a confirmation and never calls a shell,
  except `tired-do-shell-command`.  Removal goes through
  `tired--trash-move`, never through `delete-file`, so undo restores the
  path.
- `tired` goes through `tired--show-buffer`, which hands
  `tired-display-buffer-action` to `display-buffer` and selects the
  returned window, because `tired-jump` moves point afterwards.  Keep
  that action value a cons cell: `display-buffer` reads any other value
  as the old request for another window.  `tired-other-window` and every
  directory row that opens with OTHER-WINDOW call
  `switch-to-buffer-other-window`, never a display action, because an
  action that only reuses a window finds none on a one-window frame and
  pops a new frame.
- A helper whose value comes from its arguments alone carries
  `(declare (pure t) (side-effect-free t))`.  A helper that reads state
  or the file system, but writes nothing, carries
  `(declare (side-effect-free t))`.  Do not declare a function that sets
  match data, fills a cache, prints or moves point: the byte compiler
  drops an unused call of a side-effect-free function.  A function that
  reads a user option stays out of the pure form, or the compiler folds
  a call under a `let` that binds the option.

## Testing

`tired-tests-fixtures.el` holds the macros.  Read their docstrings
before you write a test.

- Batch Emacs runs no idle timer and no reprint timer.
  `tired-tests--with-fixture` binds a private element cache and an empty
  idle queue, stubs the two schedulers and binds
  `tired-delete-delay` to nil.  `tired-tests--flush-sizes` and
  `tired-tests--flush-elements` both run the queue and then the reprint.
  A test that needs the real scheduler stubs `run-with-idle-timer`.
- Batch Emacs opens a window for `tired`.  A test that needs a hidden
  listing binds `tired-tests--with-deferred-sizes`, which stubs
  `tired--size-window-p`.  Bind `tired-tests--window-shown` to t inside
  that macro to act as the display does.
- Batch Emacs dispatches no file notification event during `sit-for`,
  so a test stubs `file-notify-add-watch`.
- Batch Emacs sends no mouse event, so a test builds one with
  `tired-tests--click`.
- The region needs `transient-mark-mode`, which starts off, and no
  command loop runs `post-command-hook`, so a test enables the first or
  runs the second.
- A test never reaches the network.  `tired-tests--with-remote` stubs
  `file-remote-p` for a real temporary directory.
- `tired-tests--with-trash` binds a private trash, an empty undo stack,
  an empty redo stack and an empty `tired-undo-push-functions`.  Use it
  to remove or replace a path.
- `tired-tests-core` holds
  `tired-autoload-cookies-stay-in-a-loading-entry-point`, so a cookie in
  a sub-library fails the suite.

## Where to write things

- A user-visible command, key or option goes in `README.org`.  Read the
  README before you document a command.
- A design decision that a future reader may undo goes in `docs/adr/`.
  Record the reason and the trade-off, not the code.
- A term goes in `GLOSSARY.md` when the code and the README disagree on
  its meaning.  An ADR takes the next free number, `NNNN-title.md`.
- A file-local invariant goes in that library's "Design notes", and a
  narrow trap goes in a comment beside the function that it guards.
