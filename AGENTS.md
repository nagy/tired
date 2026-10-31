# AGENTS.md — tired.el

## Overview

A directory editor on `tabulated-list-mode`.  Entries come from
`directory-files-and-attributes`, never from `ls -l` output.  A row is
a `tired-entry` or a `tired-section`, where a section belongs to a file
that a handler can read.  `tired.el` is the entry point and requires
four libraries, so a user command, a key and a lisp caller stay the
same.

Minimum Emacs 31.1, because `tabulated-list-print-entry` wants a
vector row there.

`README.org` holds the user view: keys, options, handlers, the shell
command.  `docs/adr/` records why the design looks like this.  Read the
README before you document a command.

## Files

- `tired.el` — entry point: commentary, the four requires, the public
  commands (`tired`, `tired-other-window`, `tired-noselect`,
  `tired-find-file-mode`, `tired-jump`), the evil hook
- `tired-core.el` — entries, section framework, display, selection,
  redraw, watches, `tired-mode`
- `tired-sections.el` — the Org, Emacs Lisp, Rust, Markdown, Cargo and
  SQLite handlers
- `tired-file-ops.el` — copy, move, rename, delete, undo, mkdir,
  touch, shell
- `tired-export.el` — the CSV, text and `rclone lsjson` exports and
  their read-only buffers
- `tired-evil.el` — optional evil bindings
- `tired-tests.el` — loads the suites
- `tired-tests-fixtures.el` — shared fixtures, helpers and setup
- `tired-tests-core.el`, `tired-tests-sections.el`,
  `tired-tests-file-ops.el`, `tired-tests-export.el`,
  `tired-tests-evil.el` — one suite per library
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
  the six libraries, and `relint` on the same six.  `checkdoc` and
  `relint` exit 0 while they report, so the check gates on output.
- Systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
  `aarch64-darwin`.  `meta.platforms` is `lib.platforms.unix`.
- `nix fmt` formats the repo through `treefmt-nix` (nixfmt only).
- The version string is `0.1.0-unstable-<commit date>`, derived from the
  flake source info.  `postPatch` rewrites the `;; Version:` header, so
  package.el, package-lint and the store path agree.

## Architecture

Dependencies point one way: `tired-core` requires no sibling,
`tired-sections`, `tired-file-ops` and `tired-export` require
`tired-core`, and `tired` requires all four.  When `tired-core` names a
command from another library, as `tired-mode-map` does, it adds a
`declare-function`.

Every `;;;###autoload` cookie for a command sits in `tired.el`, because
the file that holds a cookie names the file that its autoload loads.
A cookie in `tired-core` would load the core alone, so `M-x tired` from
a `package.el` install would reach a void `tired-file-sections-elisp`
and a void `tired-delete`.  A command that other libraries call, such
as `tired-noselect`, stays in `tired.el` for that reason, and
`tired-mode` carries no cookie at all: `tired-noselect` runs the mode.
`tired-evil.el` keeps its own cookie, because the file requires
`tired`.

1. `tired--read-entries` builds one hash table per shown directory from
   `directory-files-and-attributes`, so a file costs one stat and no
   second name expansion.  `tired--tables` holds the tables,
   `tired--inserted` the directories whose children show.
2. `tired--sorted-directory-entries` filters and sorts one directory in
   Elisp (`tired--lessp`), so directories stay first under every key.
   With `tired-sort-by-extension` set, `tired--name-before-p` compares
   the case-folded extension first, the way `ls -X` does, and the whole
   name second.
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
   modification time, so a redraw does not re-parse.  A handler
   fontifies its buffer and returns propertized labels, and
   `tired--section-cell` mirrors each `face` into `font-lock-face`.
   `tired--paint-missing-face` drops every label property except
   `face', paints `tired-section-face' or `tired-section-heading-face'
   on every part of a label that carries no source face, so a plain kind
   prefix keeps the section color, and mirrors each face into
   `font-lock-face'.
6. `tired--redraw` walks the tree once into `tired--rows`, sizes the name
   column, prints vector rows, restores point by row key, the mark and
   the window views, repaints the selection, syncs the watches and
   rebuilds the mode line.  A row that left the listing leaves point on
   its old line, clamped to the last row, so a removal never sends point
   to the first line.  A view change (filter, sort, dotfile, hidden,
   insert, expand, fold) calls it.  `tired-refresh` re-reads the tables,
   prunes dead state and then redraws.
7. Selection and region share one target path.  `tired--selection`
   holds paths and `tired--selection-set` mirrors it.
   `tired--targets` commits an active region into the selection, then
   reads the selection, the region and the row at point.  Every command
   body reads `tired--targets`.  `tired--selection-targets` reads the
   same rows and changes nothing, so a menu `:active` form and an
   interactive spec call it and a canceled prompt leaves no selection.
   A section row stands for its file, and one file joins once.
   `tired--apply-to-rows` runs one view function over the targets and
   keeps the selection, because a user selects a directory, inserts it
   and then adds a child row.  A file command clears both sources.
   The mode line prints the count and the byte sum of the selection or
   the region through `tired--entries-size'.
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
12. `tired--paint-row-help` runs after `tabulated-list-print` and gives
    every printed line the `help-echo` from `tired--mouse-help`, so the
    whole row explains the mouse.  It sets no `mouse-face`: the pointer
    leaves a row alone.  Bind `inhibit-read-only`, because the listing
    buffer is read-only.
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
14. `tired--export` picks the targets, renders them in the format of
    the command, and fills a read-only buffer.  The selection comes
    first, then the region, then `tired--visible-entries`, so an
    export never uses the row at point.  Section rows stay out, because
    a section is not a file.  A whole-view export reuses one buffer per
    format and directory.  A partial export makes a new buffer, because
    another selection holds other rows.

## Conventions

- Package prefix `tired-`, private helpers `tired--`.
- Public commands carry `;;;###autoload` only as entry points (`tired`,
  `tired-other-window`, `tired-noselect`, `tired-find-file-mode`,
  `tired-jump`).  Keep every cookie in `tired.el`: the autoload of a
  cookie in `tired-core` would load that library alone, and the section
  handlers and the file commands would stay unbound.
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
- `tired` goes through `tired--show-buffer`: it hands
  `tired-display-buffer-action` to `display-buffer` and then selects
  the returned window, because `tired-jump` moves point in the listing
  after the call.  Keep that action value a cons cell: `display-buffer`
  reads any value that is not a cons cell as the old request for
  another window, drops the action function and adds
  `inhibit-same-window`, so a bare symbol puts the listing in the
  wrong window and defeats a `display-buffer-alist' rule that asks for
  the selected window.  `tired--show-buffer` wraps such a value in a
  list, and the defcustom does not offer one.
- `tired-other-window` and every directory row that opens with
  OTHER-WINDOW call `switch-to-buffer-other-window`, as
  `dired-other-window` and `dired-find-file-other-window` do.  The
  `pop-up-windows` binding of that function makes a split obey
  `split-height-threshold` and `split-width-threshold`.  Do not route
  this path through a display action: an action that only reuses an
  existing window finds none on a one-window frame, falls through to
  `display-buffer-pop-up-frame` and pops a new frame.
- Name cells carry `face` and `font-lock-face`, so a name keeps its color
  with font-lock off and after `font-lock-unfontify-region`.  A section
  label follows the same rule through `tired--section-cell`.
- `tired-mode` sets no `font-lock-defaults`: the printer built the
  strings, so color belongs in the entry data.
- File commands never ask a confirmation and never call a shell, except
  `tired-do-shell-command`.  Removal goes through `tired--trash-move`,
  never through `delete-file`, so undo can restore the path.
- No key, no menu entry and no evil binding runs `tired-undo`.  The
  command changes paths, so the user reaches it through `M-x` alone.
  The autoload form in `tired.el` keeps that path, because
  `tired-file-ops` carries no cookie.  A test in
  `tired-tests-file-ops` fails when a binding returns.
- An export command keeps the selection and the region, writes a
  read-only buffer, and leaves the buffer unmodified.  The buffer takes
  the listing directory as `default-directory`, so a later `C-x C-w`
  starts in the shown directory.  Read a buffer-local variable before
  `with-current-buffer`, or the target buffer supplies its own value.
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
  single click would open a row.  A printed row sets no `mouse-face`,
  but the binding stays: `tired-mode-map` binds `follow-link` to
  `tired--click-selects-row`, which returns nil, and `mouse-on-link-p`
  calls that binding as a predicate.  Do not drop the binding, or a
  `mouse-face` from another source opens a row on one click.
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
- `tired-select-extension` keys a group with `file-name-extension` and
  an empty fallback, so an extensionless name and a dotfile share one
  group.  It adds to the selection instead of toggling, and its body
  runs in `save-excursion`, because point must stay on the row that
  started the command.
- A section row is not selectable.  Do not add one to
  `tired--selection`: the selection and the narrow snapshot key by path
  alone, so change them only through `tired--set-selection` and
  `tired--set-narrowed`.  A region over a section row reaches that
  row's file instead, through `tired--display-entry-table`, because a
  collapsed chain hides the file row from its parent table.
- A command body reads `tired--targets`, never `tired--selection-targets`,
  or the region never becomes a selection and `tired-select-none`
  leaves it in place.  A menu `:active` form and an interactive spec
  read `tired--selection-targets`, so a canceled prompt changes no
  state.
- `tired--entries-size` counts a directory by its subtree, and it
  reads no `tired-directory-size`, because that option governs the
  size column alone.  A remote directory adds nothing.  The walk goes
  through `tired--directory-total', so `tired--size-cache' serves a
  second read inside `tired-size-cache-ttl'.  The mode line still
  rebuilds on a region change, through `post-command-hook', and a new
  directory inside the region starts one walk per cache window.
- Evil shadows `i` (text objects), `e` and `E` (word motion) and `TAB`
  (jump forward) in visual state.  Do not add `tired-insert-subdir`,
  `tired-expand-file`, `tired-collapse-file` or `tired-toggle-subdir`
  to `tired-evil-visual-keys`, or a visual selection loses its text
  objects and its motion.
- `tired-entry-path` reads an entry struct.  Test `tired-entry-p` before
  the call, or a section row signals `wrong-type-argument`.
- Evil remaps `evil-replace` to `tired-rename`, so `r` renames a row and
  `R` keeps `tired-move`.
- Use `tired--directory-entry-p`, not `tired-entry-dirp`, to decide
  whether a row takes children.  `DIRP` covers real directories only, and
  the sort key, the size column and the directory face read it.
- An empty directory row takes `tired-ignored-face`, and its slash
  follows the name through `tired--directory-slash-face`.  Empty means
  that `tired--directory-total` returns zero, so `tired--name-face`
  reads the size cache and a redraw walks a subtree even with
  `tired-directory-size` nil.  That cache bounds the cost.  A remote
  directory keeps the directory face and costs no walk.
- `minibuffer-contents` returns the current buffer text outside a
  minibuffer, so read it before `with-current-buffer`.
- `tabulated-list-print` erases the buffer, and the erase strands the
  mark, the window point and the display start on line one.
  `tired--redraw` repairs all three and sets the window point before the
  window start.  Use `set-marker`, not `push-mark`, or every redraw grows
  the mark ring.  The print also moves point to the first line when the
  row at point is gone, so `tired--redraw` calls `tired--goto-line` with
  the line it captured first.  That line clamps to the last row through
  `tired--last-row-position`, because the printer closes the last row
  with a newline and a plain `forward-line` would stop below every row.
  `tired--apply-to-targets` still prefers the next surviving row, so a
  delete goes down when a row stays below and up otherwise.
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
- A label takes its faces from the fontified temporary buffer, so the
  handler calls `font-lock-ensure` after it selects its major mode.
  Without that call a tree-sitter buffer holds no face and every row
  falls back to the section face.
- `treesit-node-text` keeps the buffer text properties unless the
  second argument is non-nil.  Leave the argument out for a label, and
  pass t for a key that a comparison or a column measurement reads.
- A source span may carry more than a face.  An org link brings a
  `keymap', a `mouse-face' and an `invisible' property, and the last one
  hides half a row.  `tired--face-only-string` rebuilds the label with
  `face' alone, so no handler has to filter its own text.
- A fenced Markdown block names another language, and its grammar may
  be absent.  `tired--treesit-sections` binds
  `treesit-auto-install-grammar' to nil around the parse, or
  `font-lock-ensure' raises an install question while the listing
  reads a file.
- The org label span comes from the title text, not from the stars, so
  a TODO keyword, a priority cookie and a tag list stay out.  Org 31
  gives `:title` as a string, and an older Org gives a list, so only a
  string reaches `search-forward`, and a miss falls back to
  `:raw-value`.
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
- `tired--export-json` follows the `rclone lsjson` object, so a field
  name or a directory size of -1 stays as rclone prints it.  The CSV
  export reports 0 for a directory, because that total needs a walk.
  Test a new field against an rclone listing before you add it.
- Batch Emacs dispatches no file notification event during `sit-for`, so
  the tests stub `file-notify-add-watch`.  Batch Emacs also has no window
  layout, so a test asserts buffer state, not window state.
- `tired-tests-core` holds
  `tired-autoload-cookies-stay-in-a-loading-entry-point`, so a cookie
  in a sub-library fails the suite.  The autoload file names the file
  that holds the cookie, not the file that holds the command.
- `tired-mode` carries no `;;;###autoload` cookie.  A package user
  reaches the mode through `tired-noselect`, which loads the whole
  package first.
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
