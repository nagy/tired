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

- `tired.el` — entry point: commentary, the five requires, the public
  commands (`tired`, `tired-other-window`, `tired-noselect`,
  `tired-find-file-mode`, `tired-jump`, `tired-clear-caches`), the
  evil hook
- `tired-core.el` — entries, section framework, display, selection,
  redraw, watches, the size caches, `tired-mode`
- `tired-sections.el` — the Org, Emacs Lisp, Rust, Go, Markdown,
  Cargo, SQLite and tar handlers
- `tired-elements.el` — the Elements column, its dissector hook, the
  global count caches and the idle queue
- `tired-file-ops.el` — copy, move, rename, delete, undo, mkdir,
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
  tree-sitter Rust, Go, Markdown and TOML grammars, and `checkPhase`
  exports `TREESIT_EXTRA_LOAD_PATH` and puts `zstd` on the path for the
  archive fixtures; a missing grammar skips its test instead of
  failing.
- `checks.lint` is `mkLint`: `package-lint` on `tired.el`, `checkdoc` on
  the seven libraries, and `relint` on the same seven.  `checkdoc` and
  `relint` exit 0 while they report, so the check gates on output.
- Systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
  `aarch64-darwin`.  `meta.platforms` is `lib.platforms.unix`.
- `nix fmt` formats the repo through `treefmt-nix` (nixfmt only).
- The version string is `0.1.0-unstable-<commit date>`, derived from the
  flake source info.  `postPatch` rewrites the `;; Version:` header, so
  package.el, package-lint and the store path agree.

## Architecture

Dependencies point one way: `tired-core` requires no sibling,
`tired-sections`, `tired-elements`, `tired-file-ops` and
`tired-export` require `tired-core`, and `tired` requires all five.
When `tired-core` names a command from another library, as
`tired-mode-map` does, it adds a `declare-function`.

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
2. `tired--sorted-directory-rows` filters and sorts one directory in
   Elisp.  It decorates every entry as a `tired-sort-row' with the sort
   value and the name, so one redraw parses each extension once, and
   `tired--lessp` compares the decorations.  Directories stay first
   under every key while `tired-group-directories' holds.  With
   `tired-sort-by-extension' set, the name value holds the case-folded
   extension, the way `ls -X' does, and the name breaks a tie.
   `tired--sorted-directory-entries` maps the same rows back to entries.
   The sorter of `tabulated-list` reads the flat entry list at print
   time, and a column predicate or `tabulated-list-groups` cannot
   keep the tree, so the sort runs here.  `docs/adr/0002-sort-in-elisp.md`
   holds the reasons.
   `tired-sort-states` names the states that `tired-sort` cycles: one
   symbol per column and direction, such as `name-asc`.
   `tired--sort-step` wraps the relative walk and `tired--sort-select`
   applies one position, so a numeric prefix selects a state by its
   place in the list.  A column that the option leaves out gives way
   to the first state forward and to the last state back.  The
   default list follows the column order, name then size then
   elements then modified, and leaves the mode column out.
3. `tired--display-rows` walks depth-first and returns `(ROW . DEPTH)`
   conses.  A `file-truename` set stops symlink cycles.
   `tired--directory-entry-p` decides whether a row takes children and
   counts a symlink that resolves to a directory.
4. `tired--collapsed-display-entry` swaps a directory row for the leaf
   of a single-entry chain, a file or a directory.  It runs before the
   sort, so the row sorts by the size, the time and the mode that it
   shows, and it caches per refresh in `tired--collapse-cache`,
   together with the directories that the chain walk visited.
5. `tired-file-sections` picks a handler through `tired-file-handlers`,
   runs it in a temporary buffer, and turns the plists into
   `tired-section` structs.  A file above
   `tired-section-file-size-limit` runs no handler, and it writes no
   cache entry, because a handler reads the whole file first.  The
   result caches in `tired--sections` by
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
   prunes dead state and then redraws.  A redraw reads the size memo
   table alone, so it blocks on no subtree, and `tired--size-queue'
   then queues the visible directory rows for an idle walk.  The name
   column width comes from `tired--pin-width-window`,
   which pins the window that renders the listing in
   `tired--width-window` and returns it.
7. Selection and region share one target path.  `tired--selection`
   holds paths and `tired--selection-set` mirrors it.
   `tired--targets` commits an active region into the selection, then
   reads the selection, the region and the row at point.  Every command
   body reads `tired--targets`.  `tired--selection-targets` reads the
   same rows and changes nothing, so a menu `:active` form and an
   interactive spec call it and a canceled prompt leaves no selection.
   A section row stands for its file, and one file joins once.
   `tired--region-entries` reads the lines from the earlier of point
   and mark through the later, so both ends join and the indent of a
   row decides nothing.  A linewise evil range ends with the newline
   of the row at point, so the function reads point and mark, never
   `region-end`, or that newline would name one row too many.
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
    path first, then clears the selection, refreshes, repairs point and
    reports.  The report is one line: the verb, the count, the
    destination, and the first failed path when a target failed.  A row
    that leaves the listing under point keeps its line.
    Otherwise point takes the row below the nearest row that stays
    above point, so a removed block above point does not push it down.
    Each command pushes one undo function.  `tired-rename` stays outside
    that helper: it reads the row at point alone, so the selection and
    the region stay untouched.
    `tired-copy` and `tired-move` read their destination from another
    Tired window when `tired-dwim-target` holds, through
    `tired--other-tired-directory`, so neither asks a question then and
    both keep one undo step.  The helper returns no directory that the
    shown buffer already lists, because a copy or a move into that
    directory would change nothing.
11. `tired-evil.el` is a second library.  `tired.el` installs its hook
    after `provide`, so both load orders work.
12. `tired-edit-names` turns `tired-name-edit-mode` on, and the mode
    marks every character outside a name leaf with a `read-only` text
    property.  The start and the end of each name live in
    `tired--name-edit-regions` as markers, because the printed column
    vector is stale after an edit, and `tired--name-edit-sticky`
    holds every region whose sticky property the edit changed, so
    `tired--stop-name-edit` reads both.  `tired-commit-edits` reads
    the text between the markers, checks it, and renames through
    `tired--name-target` and `tired--replace-with-trash`.  One undo
    action holds the commit.  A rename that fails keeps its row
    editable and turns the rows that succeeded read only.
13. `tired--paint-row-help` runs after `tabulated-list-print` and gives
    every printed line the `help-echo` from `tired--mouse-help`, so the
    whole row explains the mouse.  It paints `mouse-face' on the region
    that `tired--name-region` returns, the way Dired paints the name of
    a file, so the pointer highlights the name alone and the indent, the
    directory slash, the symlink arrow and the other columns stay plain.
    Bind `inhibit-read-only`, because the listing buffer is read-only.
    `tired--click-row` reads the row under a click from the buffer of the
    clicked window.  `tired-mouse-find-file-other-window` opens that row
    in another window and `tired-mouse-toggle` runs `tired-toggle-subdir`
    on it.  `tired--click-selects-row` returns nil
    and takes the `follow-link` binding, so one click selects.
14. `tired-context-menu` fills the `mouse-3` menu from the row under the
    click.  `tired-mode` adds it to `context-menu-functions` with a
    buffer-local hook, and the guard reads `(boundp
    'context-menu-functions)`, because `mouse.el` owns the variable.  A
    menu click leaves point alone, so each row command goes through
    `tired--context-command` and moves to the clicked position first.
15. `tired--export` picks the targets, renders them in the format of
    the command, and fills a read-only buffer.  The selection comes
    first, then the region, then `tired--visible-entries`, so an
    export never uses the row at point.  Section rows stay out, because
    a section is not a file.  A whole-view export reuses one buffer per
    format and directory.  A partial export makes a new buffer, because
    another selection holds other rows.
16. The Elements column sits between Size and Modified.  The column,
    its sort key and its cell live in `tired-core`, and the count lives
    in `tired-elements.el`.  Core reads three variables that the
    library fills at load time: `tired--elements-value-function`,
    `tired--elements-queue-function` and
    `tired--elements-prune-function`.  A nil value prints an empty
    cell, so core redraws alone.  `tired--redraw-buffer` queues the
    visible rows after the print, and `tired--reload-tables` prunes the
    cache.  The number comes from `tired-elements-functions`, an
    abnormal hook that `run-hook-with-args-until-success` walks.  A
    dissector returns nil, an integer, or a `tired--elements-job`.
    The library keeps the count state of a job in a
    `tired--elements-job` and wraps that in a `tired--job` of kind
    `elements`, so the shared queue carries it.  A dissector that hands
    its own job over costs one extra step, because
    `tired--elements-dispatch` returns `:more` and the next pass
    advances the new step.
17. `tired--queue-enqueue` holds the idle jobs of the process, one per
    kind and key.  A job holds a kind, a key, a step function that
    returns `:more' or `:done', a finish function, a budget in
    seconds, the buffers that wait for a repaint and a data slot for
    the job kind.  The kind joins the key in `tired--queue-index`, so
    a size walk and an element count of one directory stay two jobs.
    A pass advances the head job, rotates it to the tail, and stops on
    its budget or on `input-pending-p`.  A pass that leaves work
    schedules its own successor through an idle timer, because an idle
    timer fires once for one transition into the idle state.  A
    finished job marks its owners dirty, and one timer repaints them
    after `tired-queue-reprint-delay'.  `tired--queue-forget-current`
    drops the jobs of a killed buffer from `kill-buffer-hook`, and
    `tired--reload-tables` drops every size walk through
    `tired--queue-drop-where` and `tired--size-walk-job-p`.
18. Two memo tables answer a directory size.  `tired--size-store`
    routes a total through `tired--persistent-p`: a path that
    `tired-persistent-directories` matches lands in
    `tired--size-cache-permanent`, every other path in
    `tired--size-cache`.  `tired--directory-total` reads both tables
    and matches no rule, and `tired--size-enqueue` skips a key that
    the permanent table holds before the FORCE argument and before the
    age test, so a refresh walks no persistent directory.
    `tired-elements-cache-permanent` holds the counts of the same
    paths, and `tired--elements-entry` reads it first.  Each prune
    compares the rule value that it filled under, so a changed rule
    flushes its own permanent table once, and `tired-clear-caches`
    empties all four.  `tired--sync-watches` drops every path that a
    rule matches, because no change arrives under it.

## Conventions

- Package prefix `tired-`, private helpers `tired--`.
- The Elements number has one owner: `tired--elements-value-function`.
  Do not read `tired-elements-functions` from `tired-core`, and do not
  call a dissector from a redraw.  A redraw reads the cache alone.
- Public commands carry `;;;###autoload` only as entry points (`tired`,
  `tired-other-window`, `tired-noselect`, `tired-find-file-mode`,
  `tired-jump`) and as the cache command `tired-clear-caches`.  Keep
  every cookie in `tired.el`: the autoload of a cookie in
  `tired-core` would load that library alone, and the section
  handlers and the file commands would stay unbound.
- Every function has a docstring, `checkdoc` passes, and byte
  compilation with warnings as errors passes.
- A helper whose value comes from its arguments alone carries
  `(declare (pure t) (side-effect-free t))`.  A helper that reads
  state, or that calls a file system function, but writes nothing
  carries `(declare (side-effect-free t))`.
  `tired--shell-regexp`, `tired--parquet-le32` and
  `tired--face-properties` hold the first form, so the compiler folds
  a call with constant arguments.  Do not declare a function that
  sets match data through `string-match`, fills a cache, prints, or
  moves point: the byte compiler drops an unused call of a
  side-effect-free function.
- `tired-mode-menu` mirrors the key map on the menu bar.  Add a command
  when its key alone does not explain it.  An `:active` form reads the
  listing when the menu opens; use `(bound-and-true-p VARIABLE)` for a
  variable that another library owns.
- A new key belongs in `tired-mode-map` and in `tired-evil-keys`, and in
  `tired-evil-visual-keys` when it reads the region.  A mouse event
  belongs in `tired-mode-map`, and in `tired-evil-keys` only when evil
  shadows it.  `tired-mode-map` puts the sort cycling on `>` alone,
  and `tired-evil-keys` puts it on the down arrow character `↓`,
  because evil binds the arrow keys and the two bracket keys to its
  own commands.  `<` keeps the `beginning-of-buffer` of
  `special-mode-map`, and a negative prefix of `tired-sort` moves
  back.
- The mode map remaps `csv-mode`, `text-mode` and `js-json-mode` to the
  three export commands.  The JSON mode reads `js-json-mode`; no
  `json-js-mode` exists.  A remap reaches a key that runs the major
  mode command, not `M-x`.
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
- Color follows Dired.  A name face inherits its `dired-` partner, and
  `tired-selected-face` inherits `dired-marked`, so a Dired theme
  reaches a Tired row and the transient selection without further work.
  `tired--mode-cell` paints the group and the world `w` with
  `tired-perm-write-face`, which inherits `dired-perm-write`, and it
  reads the write bit at column 5 and at column 8 of the mode string
  alone, as `dired-font-lock-keywords` does.  The first character must
  read `-` or `d`, so a symlink keeps its mode plain, and the cell
  carries `face` and `font-lock-face` like a name cell.
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
- No key and no evil binding runs `tired-expand-file` or
  `tired-collapse-file`.  `TAB` reaches both through
  `tired-toggle-subdir`, and the menu bar keeps the two entries, so
  `M-x` and the menu hold the only paths.  A test fails when a listing
  or an evil binding returns.
- `tired-clear-caches` carries no key, no menu entry and no evil
  binding: `M-x` alone reaches it, like `tired-undo`.  It empties all
  four caches, so a wrong `tired-persistent-directories` rule costs one
  command.  A test in `tired-tests-core` fails when a binding returns.
- `tired-edit-names`, `tired-commit-edits` and `tired-abort-edits`
  carry no key in `tired-mode-map`, no menu entry and no evil binding:
  `M-x` alone reaches them.  The edit mode binds `C-c C-c` and
  `C-c C-k` in its own key map, and that map goes away with the mode.
  A test in `tired-tests-file-ops` fails when a listing binding
  returns.
- An export command keeps the selection and the region, writes a
  read-only buffer, and leaves the buffer unmodified.  The buffer takes
  the listing directory as `default-directory`, so a later `C-x C-w`
  starts in the shown directory.  Read a buffer-local variable before
  `with-current-buffer`, or the target buffer supplies its own value.
- AGPL3+ header in every Elisp file.
- `tired-copy-name` alternates between the name and the abbreviated
  path through the buffer-local `tired--copy-name-absolute`.  The
  next call copies the other form, so one key reaches both, and both
  forms stay on the kill ring.

## Gotchas

- A signal from `before-change-functions` clears that buffer-local
  hook, so the hook cannot guard the name edit: the first refused key
  would leave every later key unguarded.  The edit mode guards with a
  `read-only` text property instead.
- A `read-only` property alone keeps a name from growing and from
  coming back after a deletion: insertion next to read-only text is an
  error only when the new text inherits the property.  Mark the
  character before a name `rear-nonsticky` for `read-only`, so a user
  retypes a deleted name at the same place, and mark the first
  character of a read-only line `front-sticky` for it, so no insertion
  lands in an indent or in front of a section label.
- `special-mode-map` remaps `self-insert-command` to `undefined`, and
  `tired-mode-map` inherits that remap.  A key map that types needs its
  own `<remap> <self-insert-command>` and an explicit binding for every
  printable character, because the listing key map binds most letters
  to a command.  `tired--name-self-insert` is that remap.
- `tired-evil-local-mode` puts its normal state map ahead of the name
  edit key map, and that map binds every row key, so a name edit could
  never type a letter.  `tired-evil.el` adds
  `tired-evil--name-edit` to `tired-name-edit-mode-hook` in each
  buffer: the edit starts in the insert state, and its end returns to
  the normal state.  The edit mode never calls an evil function, so a
  user without evil runs the same code.
- `tired--redraw` draws nothing while `tired--name-edit` holds, or a
  reprint would erase the typed names.  `tired-refresh` still reloads
  the tables, so a commit and an abort show the disk as it is.
- `tired--rename-region` reads `tired--name-region` and then narrows a
  collapsed chain row to its leaf, so a rename moves the leaf and
  never the chain above it.
- The commit checks every name before it touches the disk: blank, a
  directory part, a control character, a repeated name, a name that
  the same commit also moves away, a destination that names a
  directory, and a row that left the disk.  It keeps display order, so
  a renamed parent runs before a renamed child, and the child then
  reports a failure instead of losing bytes.  A blank name reads
  through `string-trim', so a name of spaces alone counts as empty.
- Build every new path with `tired--name-target`, never with
  `expand-file-name`: that function reads a name of `~` as the home
  directory, so the commit would move the home directory into the
  trash and rename the row onto it.  The helper joins the directory
  and the name as plain text.
- A destination that names a directory signals a user error, in
  `tired--check-name-edits` and in `tired-rename`.  The trash step
  would otherwise take the whole subtree out of the listing.
- `tired--same-name-entry-p` drops the trash step when the source and
  the destination differ in case alone, and the file system resolves
  them to one entry.  `tired-undo` cannot move such a path back,
  because the old spelling names the same file.
- A file command signals a user error while `tired--name-edit` holds:
  `tired--apply-to-targets` refreshes, `tired--redraw` draws nothing
  then, and the listing would disagree with the disk.
- A rename that fails after the check keeps its row editable and turns
  the rows that succeeded read only, so a second commit retries the
  failed names and no typed name vanishes.
- Changing a text property sets the modified flag, and
  `tired--paint-row-help` adds properties after every print, so a
  listing buffer counts as modified.  Do not read that flag as a sign
  of an unsaved name edit.
- A printed row carries `mouse-face' on its name alone, so
  `tabulated-list-mode` turns a click there into a link click unless
  `follow-link` says no.  `tired-mode-map` keeps its
  `tired--click-selects-row` binding, which returns nil, so the
  highlight costs no click.  Do not paint `mouse-face' on the whole
  line, or a hover hides the row that the pointer reads.
- `evil-define-key` is a macro, so `tired-evil.el` uses the function
  `evil-define-minor-mode-key` with `key-parse`.  `define-key` reads
  `"RET"` as three characters.  A remap entry reads
  `"<remap> <evil-replace>"`, because `key-parse` treats the bracket form
  as literal characters.  The table of `tired-evil-keys` types the
  sort cycling as the literal character `↓`, so `key-parse` reads
  one character event.  The normal table remaps `evil-replace`,
  `evil-goto-line`, `evil-next-line` and `evil-previous-line`, so `r`
  renames and `j`, `k` and `G` stop on a row.  `j` and `k` keep their
  key through the remap.  A remap reaches the visual state, because
  the normal table of a minor mode stays active there, so
  `tired-evil.el` gives the three motion commands the `:keep-visual`
  property: `evil-visual-pre-command` expands the region for every
  other command, and an expanded region turns the line motion into no
  motion, so `V j` would never grow the range.
- `define-minor-mode` defines a defcustom, so a mode without
  `:group 'tired` fails byte compilation.
- `tabulated-list-mode` binds `follow-link` to `mouse-face`, and with
  that value a click on a `mouse-face` region arrives as `mouse-2`, so a
  single click would open a row.  A printed row carries `mouse-face` on
  its name, so the binding decides that path: `tired-mode-map` binds
  `follow-link` to `tired--click-selects-row`, which returns nil, and
  `mouse-on-link-p` calls that binding as a predicate.  Do not drop the
  binding, or the name highlight opens a row on one click.
- `tired--column-label` propertizes each header label with a key map for
  `[header-line mouse-1]` and `[header-line mouse-2]`.  Emacs 31 builds
  the header line from those labels and keeps their text properties, so
  the clicks reach `tired--sort-by-column`.  Bind both buttons:
  `follow-link` can
  turn a click into the second one.
- `tired--sort-indicator` reads `tabulated-list-gui-sort-indicator-asc`
  and `tabulated-list-gui-sort-indicator-desc`, so the user sets the
  sort arrow through the Emacs options and Tired hardcodes no
  character.  A text terminal shows the two tty options in its place,
  because `tabulated-list-mode` installs a buffer-local
  `glyphless-char-display` table that maps each GUI character to its
  tty partner.  Do not test the feature with a literal `^` or `v`: the
  header string holds the GUI character, and no display runs in batch
  Emacs.
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
  size column alone.  A remote directory adds nothing, and so does a
  directory that `tired-directory-size-exclude` names.  The walk goes
  through `tired--directory-total', so `tired--size-cache' serves the
  sum and a directory whose walk has not landed adds zero until the
  idle pass fills it.  The mode line still
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
- A sort key must read the value that the row prints, or the column
  reads out of order.  `tired--sort-row` builds three subjects from one
  entry: the table entry, the collapse clone and the sort value.  The
  name key reads the table entry, so a chain row keeps the group and
  the name place of its directory.  Size, time and mode read the clone.
  The directory group tests the table entry, so `C=` never moves a row
  across the group border.  The size key reads `tired--shown-size`,
  the same function that fills the size cell, so a directory sorts by
  the total that the column prints.
- Use `tired--directory-entry-p`, not `tired-entry-dirp`, to decide
  whether a row takes children.  `DIRP` covers real directories only, and
  the sort group, the size column and the directory face read it.
- An empty directory row takes `tired-ignored-face`, and its slash
  follows the name through `tired--directory-slash-face`.  Empty means
  that `tired--directory-total` returns zero, so `tired--name-face`
  reads the size cache and the idle queue walks a subtree even with
  `tired-directory-size` nil.  A directory without a total keeps the
  directory face until the walk lands.  A remote directory keeps the
  directory face and costs no walk, and so does a directory that
  `tired-directory-size-exclude` names.
- A size walk runs in the idle queue, one directory read per step.
  `tired--size-walk-step` scans the head frame, visits each child
  frame in turn, and stores a total when a frame closes, so a nested
  directory keeps its own number and a partial walk writes nothing.
  `tired--directory-total` reads the table alone: a nil total prints
  an empty cell, keeps the plain directory face and counts as no byte.
  A walk that signals stores a zero total for its root, so a broken
  tree costs one pass and not one pass per redraw.
- `tired--size-queue` queues the topmost visible directory row of a
  chain alone, because a walk covers the subtree of its row, and it
  skips a remote directory, a directory that
  `tired-directory-size-exclude` names and a directory with a young
  total.  It queues nothing while no window shows the listing, and
  sets `tired--size-deferred`, so the next display walks the sizes.
- `tired--size-skip-p` answers every size question about one
  directory: the size cell, the empty-directory mark, the mode line
  byte sum, the queue and the walk itself read it.  It holds
  `file-remote-p` and `tired-directory-size-exclude` together, so a
  mounted network directory that `file-remote-p` does not reach costs
  no walk.  `tired--size-excluded-p` matches the absolute name both
  with and without a trailing slash, so one rule covers a whole
  subtree.  `tired--size-walk-scan` tests the child alone, not the
  remote check, because one per-child `file-remote-p` would cost one
  handler lookup per directory.  Add no new remote check to a size
  path: read `tired--size-skip-p`, or the two options disagree.
  `docs/adr/0019-exclude-a-directory-from-the-size-walk.md` holds the
  reasons.
- A size reads two tables, so never read `tired--size-cache` alone in
  a path that answers the column, the empty-directory mark or the
  mode line sum: a persistent directory keeps its total in
  `tired--size-cache-permanent` and would print an empty cell.
  `tired--directory-total` reads both and matches no rule, because the
  match runs once per walk at the write site of `tired--size-store`,
  and one match in a redraw would cost one `expand-file-name` per row.
  `docs/adr/0020-keep-a-cache-for-a-persistent-directory.md` holds the
  reasons.
- A path that `tired-persistent-directories` matches takes no watch,
  so no event reports a new child there.  A fresh store path reaches
  the listing of a watched root through `tired-refresh` alone.  The
  rule states that no change arrives under the path, and a rule that
  contradicts the disk keeps a stale total until `tired-clear-caches`
  or a change of the rule value, which each prune reads once.
- A refresh forces a walk of every directory that it shows.
  `tired--reload-tables` sets `tired--size-forced` to the refresh
  time, and `tired--size-queue` reads the flag once and passes it to
  `tired--size-enqueue`, so a young total cannot keep a size cell or
  an ignored face that the refresh just contradicted.  The old total
  stays on screen while the walk runs, so no cell empties.  A nil
  flag keeps the cache of a plain redraw.  `docs/adr/0018-refresh-recomputes-a-shown-size.md`
  holds the reasons.  A refresh of a hidden listing keeps the flag
  until a window shows the listing.
- `tired--size-enqueue` drops a queued walk that started before the
  forced time, because that walk can still store a scan that predates
  the change, and keeps a walk that started after it, so one refresh
  never restarts itself.
- `tired-directory-size-budget` limits one idle pass, not one redraw.
  A zero budget leaves the job in the queue, and a nil budget walks
  every queued directory in one pass.
- `tabulated-list-format` is buffer-local and permanent-local, so one
  name column width serves every window and every frame that shows the
  listing.  `tired--pin-width-window` pins the window that renders the
  listing in `tired--width-window`, and `tired--redraw-buffer` calls it.
  The pin serves every later redraw, including the idle size pass, so a
  timer or a frame event never restyles the columns from a window of
  another size.  The selected window alone is no answer: it can show
  another buffer in another frame, with another width.  Only a window
  that decides the width repaints through `tired--width-changed-p`, so a
  frame that holds the listing in a window of another size keeps the
  column that the pin asked for.  Do not call `get-buffer-window` with
  ALL-FRAMES set to pick the width, and do not re-pin from
  `window-selection-change-functions`, or a mouse move between frames
  restyles the column again.  A window that does not show the listing
  never pins itself, so `tired-noselect` keeps its stale pin out of the
  way until a window shows the buffer.
- `tired-noselect` redraws before a window exists, so it queues no
  size walk.  A buffer-local `window-buffer-change-functions` entry
  calls `tired--window-buffer-changed`, which schedules a redraw
  through `tired--schedule-size-redraw`.  Redisplay runs that hook, so
  the reprint goes through a timer, and `tired--size-redraw` clears
  the flag and redraws.
- Batch Emacs opens a window for `tired`, so a test that needs a hidden
  listing binds `tired-tests--with-deferred-sizes`, which stubs
  `tired--size-window-p`.  Bind `tired-tests--window-shown` to t inside
  that macro to act as the display does.  `tired--size-always` belongs
  to `tired-tests--with-fixture`, which also sets the budget to nil and
  stubs both schedulers, so a test flushes the idle queue through
  `tired-tests--flush-sizes`.
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
  `tired--apply-to-targets` repairs point too, because the print moved
  it: a row that leaves the listing under point keeps its line, so a
  collapsed chain row that still shows a path under a removed leaf
  keeps focus.  A point row that really left moves to the row below the
  nearest row that stays above it, so a removed block above point does
  not push point down.  When no row above stays, point stops on the
  first line, and a shorter listing clamps to the last row, never to
  the first line.
- The name column starts at the line start, and its cell holds two
  spaces per depth level.  `tired-next-line` and `tired-previous-line`
  reach the name through `tired--beginning-of-name`, which skips the
  spaces after `beginning-of-line`.  Call `forward-line` there, not
  `next-line`: the byte compiler rejects an interactive-only function.
  A name that starts with a space loses that space to the skip.
- A view command keeps the row at point, and `tired--redraw-buffer`
  keeps the name column of point: it records `tired--at-name-p' before
  the print and moves back through `tired--beginning-of-name' after it
  restores the window views, because the restore sets the point of the
  selected window and that window shares its point with the buffer.
  Every caller keeps the column that way: the sort, the dotfile and
  hidden toggles, the filter and the two idle repaints, which run a
  timer with no user command around them.  `tired--redraw-at-name`
  stays for a caller that starts from a line start, as
  `tired--apply-to-rows`, `tired--toggle-fold` and the PATH branches of
  `tired-insert-subdir`, `tired-expand-file` and `tired-collapse-file`
  do.  Point in the middle of a name still returns to the line start.
- A row name is the `filename` thing, through
  `tired--filename-at-point` and `tired--name-bounds` in the two
  provider alists that `tired-mode` fills.  The bounds cover the
  name text alone, without the depth indent, the directory slash and
  the symlink arrow.  A provider that returns nil cannot veto the
  plain Emacs guess, so `thing-at-point` outside the name column still
  reports what it reports in any buffer, while
  `tired--filename-at-point` stays nil.
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
- The Go handler keeps a declaration that sits at the top level of the
  file alone, so a `var`, a `const` or a `type` inside a function body
  stays out of the listing.  A method indents one level under the type
  that the file declares above it, through the map in
  `tired--go-type-starts`.  `tired-file-sections-go` binds that map to
  nil for one parse, and `tired--go-type-start` fills it on first use,
  so the level function walks the type declarations once.  A method
  that the file declares before its type stays at level zero, because
  an indent with no parent row above it would read as a child of the
  row before it.
- The tar handler reads raw bytes, so it sets the buffer unibyte before
  the walk.  A tar header holds NUL bytes, so the coding system that
  `insert-file-contents` detects is `no-conversion`, and the block
  offsets stay true.  `jka-compr` decompresses a `.tar.gz` or a
  `.tar.zst` archive during that read, so one parser serves every
  suffix and the handler carries no decompression code.  A member row
  carries a synthetic ordinal as its `:line`, because an archive has no
  lines.
- A pax record and a GNU long-name record change the name and the size
  of the member that follows them, so the walk clears both after it
  emits a member.  A GNU record pads its text with a NUL byte.  The
  extraction action re-reads the archive and slices the member bytes,
  so it needs no `tar` program, and it refuses a directory and a link.
  A member name that leaves the archive reads as no member.
- `tired-section-file-size-limit` guards every handler, because a
  handler reads the whole file into a temporary buffer.  A skipped file
  writes no section cache entry, so a raised limit takes effect on the
  next redraw.
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
  `tired-size-cache-ttl` bounds a redraw alone, because a refresh
  forces a new walk of every shown directory.
- `tired-noselect` owns `default-directory` and
  `list-buffers-directory`.  `tired-mode` runs before the directory
  is known, so it must not set either variable.  The function also
  feeds `recentf-add-file` while `recentf-mode` holds, because a Tired
  buffer visits a directory and no file name reaches
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
- A command that changes the disk prints exactly one line through
  `message`, and no `display-warning` runs beside it.  The line names the
  verb, the count, the destination and the first failed path.
  `tired--report-operation` builds it for copy, move, delete and commit,
  and the other commands print their own line.  An undo function returns
  the number of paths that it put back, and `tired-undo` prints that
  count.  `tired--undo-restore` counts the restores and stays silent on
  a failure.
- Single-child collapse and the size walk skip a remote directory,
  because every read there costs a network round trip.  The size walk
  also skips a directory that `tired-directory-size-exclude` names.
  Collapse does not, because a chain walk reads one directory per
  level and never recurses.- A collapsed row takes the leaf of the chain, so `tired-entry-path`
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
- A cached element count keys on the path, the modification time, the
  size and the hook value.  A redraw refreshes the last-read stamp, and
  `tired-elements-cache-ttl` drops an entry that no buffer read inside
  that window.  A cached nil count is a hit, not a miss: an unreadable
  file and a file without a dissector both store nil, and a miss would
  read the file on every redraw.
- A nil sort value lists last in both directions, and `tired--lessp`
  breaks a two-nil tie by name.  Without that branch two rows that wait
  for a count keep the hash order.
- The Elements header label with the sort arrow is ten characters wide,
  so the column and its share of `tired--fixed-column-width` are ten.
- A line scanner must copy `(match-end 0)` into its own binding before
  it calls a function, because that function runs its own regexp match
  and overwrites the match data.  `tired--markdown-scan` lost the end of
  its newline match to `tired--markdown-line` and looped forever.
- The Markdown scanner keeps the partial last line in its state, and a
  fence, a string and an escape all carry over a chunk boundary.  Do
  not decode the chunk: `tired--elements-read` returns the literal
  bytes, so only ASCII structure decides a count.
- The section fallback parses a whole file in one step, so it runs only
  below `tired-elements-sync-limit`.  Do not raise that limit without
  making the section handlers resumable, or one idle pass blocks Emacs
  for the length of a large parse.
- The Elements count follows the section tree: the first section or
  heading sets the top level, and a later shallower one joins it, so
  the number equals the rows that print at depth zero.  A count of the
  minimum level alone disagrees with the tree that TAB shows.
- The CSV scanner feeds one byte back to itself when a closing quote
  ends a field, so `tired--csv-scan` drops its index only on `:consumed'.
  A quote opens a field at a record start or after a comma alone, so an
  unquoted quote stays a literal byte.  A comment record ignores every
  quote up to its newline, so an unbalanced quote never swallows the
  rest of the file.
- A range read passes BEG first and END second.
  `tired--elements-read-range' wraps the call, so a dissector that reads
  a tail or a header names its offsets once.
- The Parquet footer holds `num_rows` before `row_groups`, so
  `tired--parquet-count' stops at field 3 and never walks a row group.
  A footer larger than one chunk grows its buffer and parses again from
  the start, so the Thrift reader needs no resumable state.  A compact
  field id uses the delta in the header, and a zero delta costs a
  zigzag varint instead.  A page codec such as ZSTD touches the pages
  alone, so no codec reaches the count, and the tail magic `PARE` marks
  an encrypted footer that the dissector refuses.
- Batch Emacs runs no idle timer and no reprint timer.
  `tired-tests--with-fixture` binds a private element cache and an
  empty idle queue, stubs the two schedulers and sets
  `tired-elements-always`, so no test leaks a timer.
  `tired-tests--flush-sizes` and `tired-tests--flush-elements` both
  call `tired--queue-run` and then `tired--queue-reprint`.  A test that
  needs the real scheduler stubs `run-with-idle-timer` itself.
