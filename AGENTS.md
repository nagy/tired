# AGENTS.md — tired.el

## Overview

Emacs package that shows a directory as a `tabulated-list-mode`
buffer.  `tired.el` is the entry point and requires three libraries:
`tired-core.el` (listing and display), `tired-sections.el` (section
handlers) and `tired-file-ops.el` (file and shell commands).
Entries come from `directory-files` and `file-attributes`.  The package never parses `ls -l` output.  Entry
points are `M-x tired`, `M-x tired-other-window` and
`tired-noselect`.  A file row can
also expand into the sections that a handler extracts from that file,
so the listing holds two row types: `tired-entry` and `tired-section`.

Minimum Emacs version is 31.1.  Emacs 31 changed
`tabulated-list-print-entry` to require a vector of column descriptors
in `tabulated-list-entries`; a list row is a type error.  The code uses
that vector form, so earlier Emacs versions cannot run it.

The file commands act at once, without a confirmation question.  A
removed path goes into a session trash, so `tired-undo` reverses the
last operation.  `tired-do-shell-command` is the one command that runs
a shell and the one command that can ask a question.  Inline rename
editing and asynchronous loading live in git-bug issues, not in code.

## Build & test

```sh
nix build                       # package
nix flake check                 # package + ERT suite + lint check
nix develop                     # Emacs with evil, git and treefmt
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile *.el
emacs --batch -L . -l tired-tests.el -f ert-run-tests-batch-and-exit
```

Nix outputs:

- `packages.tired` (= `default`) is a `melpaBuild` call that
  `perSystem` writes inline and wraps in `pkgs.lib.makeOverridable`.
  A consumer therefore swaps one argument:
  `tired.override { emacs = pkgs.emacs-nox; }` or
  `tired.override { treesitGrammars = null; }`.  The `emacs` argument
  (default `pkgs.emacs`) supplies the grammar set and evil from
  `emacs.pkgs`, so one override moves every dependency.  The flake
  passes the commit-derived `version`, because the inline expression
  has no default for it.  `melpaBuild` closes over the Emacs of its
  package set, so an `emacs` argument on the build itself does
  nothing.  The `emacsPackages` argument therefore defaults to
  `pkgs.emacsPackagesFor (emacs.pkgs.withPackages (_: [ evil ]))`, so
  the set's own `emacs`, and the `melpaBuild` that closes over it,
  carry evil.  That wrapper puts evil on the load path of the install
  and check Emacs, so `tired-evil.el` byte-compiles and the evil ERT
  tests run without an `EMACSLOADPATH` export.  Evil is always
  present, because `melpaBuild` compiles every installed file.  Its
  `checkPhase` byte-compiles with warnings as errors and runs the ERT
  suite.  `checkInputs` holds the tree-sitter Rust, Markdown and TOML
  grammars and the phase exports `TREESIT_EXTRA_LOAD_PATH` for them,
  so the section tests run instead of skipping.  The suite reads that
  variable itself; a developer machine without a grammar skips the
  matching test.  Evil stays out of `packageRequires`, which
  `melpaBuild` leaves at its empty default, so the package metadata
  names no elisp dependency at all.
- `checks.lint` is `mkLint` in `flake.nix`: `package-lint` and
  `checkdoc`.
- Systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
  `aarch64-darwin`.  `meta.platforms` is `lib.platforms.unix` because
  the package is pure Elisp.
- `devShells.default` provides an Emacs with evil, git and the
  treefmt wrapper, so the evil tests run outside Nix too.
- `nix fmt` formats the repo through `treefmt-nix` (nixfmt only).
  `treefmt-nix.flakeModule` also adds the `checks.treefmt` check.

Version string is `0.1.0-unstable-<commit date>`, derived from the flake
source info.  A commit changes the version.  `postPatch` rewrites the
`;; Version:` header to the same string before `melpaBuild` derives the
ELPA package version from the build argument.

## Architecture

Files:

- `tired.el` — the entry point: the user commentary, the requires of
  the three libraries and the evil hook
- `tired-core.el` — entries, sorting, section framework, rows,
  selection, redraw, watches and `tired-mode`
- `tired-sections.el` — the section handlers (Org, Emacs Lisp, Rust,
  Markdown, Cargo, SQLite)
- `tired-file-ops.el` — copy, move, delete, undo, mkdir, touch and the
  shell command
- `tired-evil.el` — optional evil bindings, a separate library
- `tired-tests.el` — the ERT loader
- `tired-tests-fixtures.el` — shared fixtures, helpers and setup
- `tired-tests-core.el`, `tired-tests-sections.el`,
  `tired-tests-file-ops.el`, `tired-tests-evil.el` — the suites, one
  per library
- `flake.nix` — flake outputs, the inline overridable `melpaBuild`
  expression and the checkdoc + package-lint check (`mkLint`)
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
   `(ROW . DEPTH)` conses, where ROW is an entry or a section.  Children
   of inserted directories follow their parent row.
   `tired--directory-entry-p` decides whether a row can hold children,
   and it counts a symbolic link that resolves to a directory, so an
   inserted symlink shows its children while the row keeps its symlink
   name and face.  The sections of an expanded file follow the file row.  A `file-truename` set stops
   symlink cycles, so a link to a directory that already appears in the
   walk shows no children.  `tired--collapsed-display-entry` replaces a
   directory entry
   with a clone of the file at the end of a single-entry chain.  Collapse
   runs after sorting, so the row keeps the directory's position.
   Results cache in `tired--collapse-cache`, keyed by the chain's top
   directory.  A collapsed row suppresses its inserted children, but it
   expands its file sections when the user expands that file, so the
   sections of a deep single file stay reachable.
5. `tired-file-sections` turns one file into `tired-section` structs.
   `tired-file-handler` matches `tired-file-handlers` against the
   absolute file name, first rule wins.  `tired--call-handler` runs the
   handler in a `with-temp-buffer` that holds the file contents, read
   with `insert-file-contents` and its VISIT argument, so the buffer
   carries `buffer-file-name` and no modified flag; the handler selects
   its own major mode and
   returns plists.  `tired--section-plist` normalises each plist.  The
   result caches in `tired--sections` as `(MTIME . LIST)`, so a redraw
   does not re-parse.  `tired--section-rows` turns the list into
   `(SECTION . DEPTH)` conses.  The declared `:level` sets depth relative
   to the first section, and a folded section in `tired--folded` hides
   its children.  `tired--name-visible-p` decides whether a file row and
   its sections pass the filter.
   The Rust, Markdown and Cargo handlers share `tired--treesit-sections`.
   A language contributes a spec plist: `:language`, `:mode`, `:kinds`,
   `:containers`, `:fields`, and an optional `:label`, `:level`,
   `:require` and `:filter`.  `:filter` receives a node and returns nil
   to drop that node's section.  The Cargo handler uses it, so only the
   four tables that `tired--cargo-tables` names and their pairs show.
   The SQLite handler opens the file read-only through the
   built-in `sqlite' support and gives its sections synthetic line
   ordinals.  The org handler gives every heading the action
   `tired--org-open-heading`, which calls `tired--visit-section` and
   then narrows to the subtree when `tired-org-narrow-on-open` holds.
6. `tired--tabulated-entries` renders each row as a vector, indented by
   its depth.  Emacs 31 requires the vector form.  A section row fills
   the name column only.
   `tabulated-list-print` draws the buffer.  `tired--size-cell` fills
   the size column.  With `tired-directory-size' on, it calls
   `tired--directory-total', which walks the subtree through
   `tired--subtree-size' and leaves `(TOTAL . STAMP)' in `tired--size-cache'.
   That table is global, so every Tired buffer shares one total, and
   `tired--reload-tables' prunes the expired totals.
   A nested directory costs one read per cache window.  A redraw reuses
   every total the previous redraw computed.
6. `tired--apply-selection-overlays` highlights paths listed in
   `tired--selection`.  The selection is buffer-local and transient.
   `tired--selection-set` mirrors it as a hash set for O(1) membership.
   `tired--selection-size` sums the sizes of selected non-directory
   entries for the mode line.  `tired--mode-line` collects one part
   per piece of optional state and wraps them in one bracket group,
   so a plain listing shows no group at all.  `tired--redraw` stores
   that string in `tired--mode-line-cache` and appends it to
   `tired--mode-line-base`, so redisplay reads one string and runs no
   code.  A `:eval` element would walk the tree for the selection
   size on every redisplay.  The region count changes with no redraw,
   so a buffer-local `post-command-hook' calls
   `tired--mode-line-maybe-update', which compares
   `tired--region-signature' against the signature behind the
   cache.
   `tired--selection-targets` reads the
   selection first, then `tired--region-entries`, then the row at point;
   a command that acts on the region deactivates it.  A section row
   resolves to the file entry that owns it, and `tired-select-toggle`
   refuses a section row.  `tired--toggle-selection` flips the
   membership of a list of paths in one pass, and both
   `tired-select-toggle` and `tired-select-all` call it.
   `tired-select-all` toggles every visible entry: an unselected entry
   joins the selection, a selected entry leaves it, and a selected
   entry that the filter or the narrow snapshot hides stays selected.
   The old all-selected branch is gone, so `tired-select-none` is the
   only way to clear the whole selection.
7. `tired--in-narrow-p`, `tired--name-visible-p` and
   `tired--entry-visible-p` apply the narrow snapshot, the dotfile
   setting, the hidden regexps and the name filter.
   `tired--hidden-p` matches `tired-hidden-regexps' against the entry
   name and holds the result nil while `tired--show-hidden' is set, so
   `tired-toggle-hidden' on `~` shows the hidden entries again.
   `tired--display-rows' drops a hidden row before it reads
   the sections, so a hidden file takes its sections with it and a
   hidden directory skips its inserted children.
   `tired--narrow-ancestors` adds the
   directories that contain a narrowed path, so inserted sections keep
   their parent rows.  A file row stays visible when a section label
   matches the filter, and that file then shows only the matching
   sections.
8. `tired--reload-tables` re-reads the root directory and every inserted
   directory, and drops inserted directories and expanded files that
   vanished.
   `tired-refresh` calls it, prunes dead selection and narrow paths and
   then calls `tired--redraw`.
9. `tired--redraw` walks the tree once and leaves the visible rows in
   `tired--rows`.  The width pass and the printer both read that list
   through `tired--visible-rows`, so a redraw costs one walk, not two.
   The redraw sizes the name column from the longest visible row,
   clamped between `tired-name-column-min-width` and the window width
   minus the fixed columns.  It rebuilds the header line, prints the
   rows, restores point by row key (`tired--row-key`: path for an entry,
   path and line for a section) and reapplies the selection overlays.
   Commands that only change the view (filter, sort, dotfiles, hidden,
   insert, expand, fold) call `tired--redraw`, not `tired-refresh`.
10. `tired--window-size-changed` runs from `window-size-change-functions`
    and redraws every visited Tired buffer with the width of its own
    window, so a resize refits the name column.  The hook fires once
    per changed window of a frame, and it also fires when the echo
    area grows, for example on `M-x`.  `tired--width-changed-p`
    therefore skips a window whose name column width already matches,
    so an echo area growth redraws nothing.  A real redraw still runs
    while the selected window holds the minibuffer, so `tired--redraw`
    reads the point row through `tired--point-row`, which takes the
    window point of a window that lost the selection.  It then calls
    `tired--restore-window-views`, which puts the point and the display
    start of every window back.  Both markers need that repair,
    because `tabulated-list-print` erases the buffer and the erase
    collapses each one of them to the first line.  A second redraw in
    the same display cycle would read the collapsed start back, so the
    width guard also keeps the saved view intact.
11. `tired--sync-watches` keeps one file notification watch per path in
    `tired--watch-paths`: the root, every inserted directory and every
    expanded file.  A file needs its own watch because a directory watch
    does not report an edit to a file inside it.  The function runs at
    the end of `tired--redraw`, so inserting, expanding or removing a
    subtree updates the watch set.  A notification schedules
    `tired--auto-revert-now` through a debounce timer.  The callback
    captures its buffer, and `kill-buffer-hook` calls
    `tired--stop-watching`.
12. `tired-filter` opens a minibuffer, hooks `after-change-functions`,
   and schedules a redraw on every keystroke.
   `tired--filter-changed` reads `minibuffer-contents` before it
   switches to the listed buffer, then starts an idle timer of
   `tired-filter-delay` seconds and cancels the pending one, so a
   typed word costs one redraw.  A delay of 0 applies at once.  RET
   and C-g call `tired--filter-flush`, which cancels the timer and
   applies at once, so the final text never waits.  RET keeps the
   value, C-g restores the previous filter and moves point back to the
   row that held it when `tired-filter` started.  The timer lives in
   the listed buffer as `tired--filter-timer`, and `tired--apply-filter`
   cancels it, so a direct call supersedes a pending redraw.
13. `tired-noselect` returns the buffer for a directory and never shows
   it.  It sets `tired--directory` and `default-directory`, then
   refreshes.  Loading the library changes nothing global.  The
   global minor mode `tired-find-file-mode` puts `tired-noselect` into
   `find-directory-functions`, so `find-file` and the commands built on
   it visit a directory in tired.  Turning the mode off removes the
   function again, and dired stays in the list as the fallback.  `tired`
   and `tired-other-window` call `tired-noselect` and show the buffer.
   `tired-find-directory` no longer exists.

Jumping and bookmarks:

- `tired-jump` derives the target directory from the current buffer:
  `tired--directory` in a Tired buffer, `buffer-file-name` in a file
  buffer, `default-directory` otherwise.  From a Tired buffer the target
  is the parent directory and the anchor is the shown directory, so
  point lands on the directory that was left.  `tired-mode-map`
  remaps `dired-jump` to `tired-jump`, so `C-x C-j` reaches Tired in a
  Tired buffer.  Use the `"<remap> <dired-jump>"` key string:
  `key-parse` reads the bracket form as literal characters.
- `tired-bookmark-make-record` stores the directory in the record and
  `tired-bookmark-jump` reopens it.
- `tired-find-file` visits the target entries at once, without a
  confirmation, the way `dired-find-file` does.  Without a selection
  or an active region the row at point is the target, so a section row
  visits its own file position.  A directory opens as a Tired buffer.
  `tired-find-file-other-window` passes the other-window flag through,
  the way `dired-find-file-other-window` does.  The command clears the
  selection afterwards.  There is no completion command: a path below
  the shown directory is reached by inserting it.

Copy commands:

- `tired-copy-path` copies absolute paths.  `tired-copy-relative-path`
  makes paths relative to `tired--directory`.  `tired-copy-project-path`
  makes paths relative to `(project-root (project-current nil dir))` and
  raises `user-error` outside a project.  All three share
  `tired--copy-targets`, so selection handling stays in one place.

Browsing:

- `tired-browse-url-of-file` follows `browse-url-of-dired-file`: it
  reads `tired--selection-targets`, binds `browse-url-browser-function`
  to `browse-url-secondary-browser-function` on a prefix argument and
  empties `browse-url-default-handlers`, so no Emacs handler takes the
  file back.  It runs `browse-url-of-file` on each target.  The name
  keeps the `tired-` prefix, because package-lint rejects a
  `browse-url-` name and rejects an alias with that name.  The command
  has no key.  `browse-url` joins the top-level requires, so
  byte-compile knows `browse-url-of-file`.

Motion:

- `tired-goto-last-entry` moves point to the last row of the listing.
  `tired--last-row-position` starts at `point-max`, walks up over
  lines that hold no row and returns the position of the first line
  that does, so a trailing empty line and a blank line left by a
  filter cannot stop the motion.  `tired-mode-map` remaps
  `end-of-buffer` to the command, so `M->` reaches the last row, and
  `tired-evil.el` remaps `evil-goto-line`, so `G` does too.  A
  numeric prefix above one keeps the `evil-goto-line` meaning and
  moves to that line, because a row is one buffer line and the
  header line lives outside the buffer.  An empty listing raises
  `user-error`.

File operations:

- `tired--apply-to-targets` runs one function over the targets, deepest
  path first, then clears the selection, refreshes and reports.  A
  failing target does not stop the rest, and
  `tired--report-operation` lists every failure in the *Warnings*
  buffer.  When the refresh drops the row at point, the command puts
  point on the next surviving row, not on the first line.
  `tired--next-surviving-row` reads that row before the operation and
  skips every row of the target path and below it, so a removed
  directory takes its children and a removed file takes its sections.
  `tired--path-under-p` holds the path test.
- `tired-delete` moves each target to `tired-trash-directory`.
  `tired-copy` and `tired-move` move a replaced destination there
  first, and roll the destination back when the copy or the move
  fails.  `tired--trash-name` appends a timestamp and a counter, so a
  repeated name stays unique.  `tired--restore-path` moves a path back
  and does nothing when the original exists again.
- `tired-copy` prompts for a directory.  `tired-move` prompts for a
  full path when it has one target and the typed name is no directory,
  otherwise for a directory.  With `tired-dwim-target` set,
  `tired-move` first asks `tired--other-tired-directory`, which scans
  the windows of the frame from the one after the selected window, as
  `dired-dwim-target-next` does.  A Tired buffer in another window
  gives the destination, so the move runs at once and asks no
  question.  The helper returns nil for the shown directory itself,
  because a move into it would change nothing, and that case keeps the
  prompt.  The immediate move pushes the same undo action as a typed
  move, so `tired-undo` reverses it.  `tired-mkdir` and `tired-touch` start
  from `tired--creation-directory`: the directory at point when point
  names one, else `tired--directory`.
- Every command calls `tired--push-undo` with a description and one
  function that reverts the whole operation.  The function moves
  paths back from the trash, so no byte is destroyed.  With
  `tired-undo-push-functions` (a `defcustom` of type `hook`) set,
  that hook takes the pair and
  `tired--undo-actions` stays empty.  Otherwise `tired-undo` pops and
  runs the pair, and `tired--refresh-buffers` redraws every Tired
  buffer.

Shell commands:

- `tired-do-shell-command` (`!`) runs the user's shell command on the
  targets.  It is the one command that calls a shell and the one
  command that can ask a question.  It pushes no undo action, because
  the shell owns the result, and it still clears the selection and the
  region.
- `tired--shell-regexp` matches one substitution mark: `*`, `?` or a
  `?` wrapped in backquote signs that whitespace isolates, at the start
  or the end of the string.  Group 2 holds the mark, so the helpers
  replace and count it alone.  Do not match a bare `[*?]`: a glob
  pattern such as `*.txt` must reach the shell unchanged.
- `tired--shell-marks` scans with `(match-end 2)` as the next start.
  The trailing whitespace of group 3 then serves as the leading
  whitespace of the next mark, so `mv * *` fills both marks.  A scan
  that advances to `(match-end 0)` sees one blank only once and leaves
  the second mark in place.
- `tired--shell-fill-marks` fills the marks with a quoted name and
  never rescans the inserted text, so a name that holds a mark cannot
  loop.  `tired--shell-mark-count` and `tired--shell-keeps-mark-p`
  subtract the substituted marks from the total, which decides whether
  `tired-confirm-shell-command` asks.
- `tired--shell-file-name` makes a target name relative to
  `tired--directory`, so a target below the shown directory reads as
  `sub/file`, and prefixes a leading dash with `./`.  Never pass the
  absolute path: the command runs in the shown directory.
- `tired--shell-parts` splits a trailing `&` and a trailing `;` or
  `;&`.  The first backgrounds the run, and the second makes the
  per-file runs wait for each other.  A trailing `;` alone also
  backgrounds, because a sequential set of files wants no blocking
  Emacs.
- `tired--shell-command-line` joins the runs.  A `*` mark gives one
  run with the whole list, a `?` mark gives one run per file, and a
  command without a mark appends one name per file.  Background runs
  use `&` between the per-file bodies and end with `& wait`, and a
  sequential run wraps the `;` list in a subshell before the `&`.
  `shell-command` reads the last `&` as an asynchronous run.
- A synchronous run calls `tired-refresh`; a background run does not,
  because the shell decides when the paths change.

Sorting is implemented in `tired--lessp`, not in `tabulated-list`,
because tabulated-list cannot keep directories first while sorting other
columns.  `tabulated-list-format` therefore marks every column as
unsortable and the header line stays plain.  `tired-sort` prompts for a
column and redraws.

Evil integration:

- `tired-evil.el` is a second library, so `tired` never requires evil.
  It requires evil and Tired, and it binds keys in normal and visual
  state only.
- `tired.el` turns the evil bindings on by itself.  The last form
  adds `tired--enable-evil-bindings` to `after-load-functions`, right
  after `provide 'tired`, and that hook runs at the end of the Tired
  load too, so both load orders work.  The position after `provide`
  matters, because `tired-evil' requires `tired', and Emacs signals
  "Recursive require" when a file requires its own feature while that
  file still loads.  Do not replace the hook with
  `with-eval-after-load`: package-lint fails the check on that macro.
  The hook checks `(featurep 'evil)` before the require, so a plain
  Emacs never loads evil, and the hook removes itself once done.
- The automatic call exists because evil shadows the whole major mode
  map.  Evil keeps its state maps in `emulation-mode-map-alists', and
  Emacs checks that list before the major mode map, so `evil-ret' on
  RET wins over `tired-mode-map' and moves down one line.
  `evil-define-minor-mode-key` installs the maps ahead of the state
  maps, which restores `tired-find-file' and every other Tired key.
- `tired-evil-keys` and `tired-evil-visual-keys` hold the key tables.
  `tired-evil--bind` feeds them to `evil-define-minor-mode-key` for the
  private minor mode `tired-evil-local-mode`.
- `tired-evil-mode` is the global switch.  It adds
  `tired-evil--enable-buffer` to `tired-mode-hook` and turns the local
  mode on in every existing Tired buffer.  Turning it off removes the
  hook and the local mode, so the buffer falls back to
  `tired-mode-map`.
- The visual table is short on purpose: visual state needs its text
  objects, and the region already targets files for every command.
  The normal table leaves `j`, `k`, `gg`, `C-d`, `C-u`, `n` and
  `N` to evil, the way `evil-collection-dired` does.  It shadows
  `w`, `W` and `P`, so the four copy commands keep their
  `tired-mode-map` keys in normal state too.  It also shadows `!`, so
  `evil-shell-command` does not filter the listing through a shell,
  and it puts `f` on
  `tired-find-file` and keeps `gf` as the same command.  The table
  remaps `evil-replace` to `revert-buffer-quick`, because a listing
  is read-only and `r` has no other use there.  It remaps
  `evil-goto-line` to `tired-goto-last-entry`, because the plain
  motion stops on the empty line that closes the last row.  It remaps
  `evil-ex-search-forward` and `evil-search-forward` to
  `tired-filter`, because a filter narrows the listing and a search
  does not, and because evil binds `/` to one of the two depending on
  `evil-search-module`.  Spell every remap entry
  `"<remap> <evil-replace>"`, `"<remap> <evil-goto-line>"` and
  `"<remap> <evil-ex-search-forward>"`,
  because `key-parse` reads the bracket form as literal characters.
- The evil tables put the selection on `m`, not on `SPC`, and the move
  command on `R`, not on `m`.  Shadowing `m` costs the evil mark
  command, and shadowing `R` keeps the evil replace state out of a
  read-only listing.  Both tables use the same two keys.  The plain
  `tired-mode-map` keeps `SPC` for `tired-select-toggle-next` and `m`
  for `tired-move`.

## Conventions

- Package prefix is `tired-`.  Private helpers use `tired--`.
- The library dependencies point one way: `tired-core` requires
  nothing of this package, `tired-sections` and `tired-file-ops`
  require `tired-core`, and `tired` requires all three.  A cycle
  breaks the load, so never require a sibling back.  When
  `tired-core` names a command from another library, as
  `tired-mode-map` does, add a `declare-function` for it.  A test
  file requires `tired-tests-fixtures` and no sibling suite.
- `tired-evil.el` follows the same prefix.  Its key tables map a key
  description string to a command symbol, and `tired-evil--bind` calls
  `key-parse` before `evil-define-minor-mode-key`, because `define-key`
  reads a plain string as literal characters, so `"RET"` would bind
  three keys.  A new Tired command belongs in `tired-evil-keys`, and in
  `tired-evil-visual-keys` when it reads the region.
- Public commands carry an `;;;###autoload` cookie only when they are
  entry points (`tired`, `tired-other-window`, `tired-mode`,
  `tired-noselect`).
- Every function has a docstring.  `checkdoc` must pass.
- Byte-compilation with warnings as errors must pass.
- Faces inherit from Dired faces (`dired-directory`, `dired-symlink`,
  `dired-symlink-filename`, `dired-broken-symlink`, `dired-special`,
  `dired-ignored`), so a user Dired theme setting reaches Tired rows.
  `dired-font-lock-keywords` itself stays unused: those keywords match
  the `ls` line layout and call `dired-move-to-filename`, which needs a
  mark column and an inode field on one line.  A tabulated-list row
  keeps its columns apart.
- Name cells carry both `face` and `font-lock-face`, as
  `package-menu--print-info-simple` does.  `face` covers a buffer with
  font-lock off.  `font-lock-face` survives
  `font-lock-unfontify-region`, which removes `face`.
  The modification time cell carries both properties too, with
  `tired-date`.  That face inherits `org-date`, so a theme colors the
  stamp like an Org date.  Org may stay unloaded: an unloaded inherit
  face resolves to nothing, and the inherit appears when org loads.
  Do not require org for the face.  The stamp column is the only place
  that prints a date or a time.  The trash name uses a timestamp, but
  it stays invisible as a path component.
  The size cell carries both properties as well, with
  `tired-file-size', which inherits `marginalia-size'.  Marginalia may
  stay unloaded, for the same reason.  An empty size cell keeps no
  face.  `tired--size-column' adds the paint, and
  `tired--size-cell' stays a plain string, so the tests compare it
  with `string=' or `equal'.
  A directory row paints its trailing slash with
  `tired-directory-suffix-face', which inherits `parenthesis'.  The
  slash stays a separate `tired--propertize-name' call, so a theme
  colors the slash alone and the name keeps its own face.
  `tired--name-face' never returns that face, because it covers a
  suffix and not a name.
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
  `tired-do-shell-command` is the single exception: it runs the user's
  shell command, it asks about a mark that stays for the shell while
  `tired-confirm-shell-command` holds, and it takes no trash step.
- A section row is not selectable.  It carries its file path, so the
  path commands reach the file.  Do not add section rows to
  `tired--selection`, because `tired--redraw` and
  `tired--prune-selection` key the selection by path alone.
- A section handler reads the file in a temporary buffer and selects
  its own major mode.  Do not parse from a visiting buffer and do not
  make the framework guess the mode.  The read passes VISIT to
  `insert-file-contents`, which sets `buffer-file-name` and leaves the
  modified flag clear.  Without VISIT the buffer starts modified, and
  `kill-buffer` on the discarded buffer asks the user whether to kill
  it, so every expand of a file raises a prompt.
- Section handlers stay free of a hard dependency.  The Rust,
  Markdown and Cargo handlers call `(require 'treesit)` at run time and
  return nil when the grammar is absent.  The Markdown handler also
  requires `markdown-ts-mode', because that mode has no autoload here.  The
  SQLite handler checks `(fboundp 'sqlite-available-p)` and wraps the
  open in `condition-case`, so a file that is not a database yields no
  sections and no warning.  Byte-compile needs a `declare-function` for
  every `treesit-function`, `org-element-function` and sqlite function
  it calls.
- A tree-sitter spec spells node types as strings, not symbols, so
  `tired--treesit-kind` compares against `treesit-node-type` with
  `equal`.  A new grammar costs one spec and one handler that calls
  `tired--treesit-sections`.
- `treesit-node-children` returns anonymous nodes too, so a TOML pair
  lists its `=` sign beside its key and its value.  Pass NAMED, or read
  the sign as the value.
- The Cargo handler keeps its own label format in
  `tired--cargo-section-label`.  A pair of `[features]` lists the
  members of the feature after an arrow.  A pair of another table
  holds the crate name, its version and the badges `[optional]` and
  `[no-default]`.  Two columns span the whole file:
  `tired-file-sections-cargo` binds `tired--cargo-columns` to nil,
  and `tired--cargo-measure` reads the widest key and the widest
  version of every listed table on first use.  So a feature arrow, a
  dependency version and a dependency badge each start in one
  column, the way elastic tabstops align a block.  A table row
  counts its entries.  The labels stay plain strings, so the filter,
  the copy commands and the tests read them.
- A handler with no real line gives every section a distinct synthetic
  `:line`.  The section fold state and the point restore key on
  `(PATH . LINE)`, so two sections that share a line fold together and
  the redraw lands on the wrong row.  The SQLite handler counts its
  sections for this reason.  Such a handler also supplies an `:action',
  because visiting the raw file at line 1 is meaningless.
- A `:label` may carry text properties.  `tired--section-cell` keeps
  them when the label has a `face` property somewhere and then mirrors
  each `face' run into `font-lock-face', the way a name cell carries
  both.  A label without a face takes the kind's section face.  The
  Emacs Lisp handler fontifies its temp buffer with `emacs-lisp-mode'
  and `font-lock-ensure', then copies the head and the symbol argument
  out of the source, so each part keeps the face the mode gave it.
  Copy source text, never re-derive the face: a `defvar' name and a
  `defun' name take different faces.  Fontify inside the handler, so
  the parsed sections stay cached by modification time and a redraw
  never fontifies again.
  The label text still equals `tired--elisp-label', so the filter and
  the tests compare plain strings.

## Gotchas

- `evil-define-key` is a macro, so a file that must compile without
  evil cannot call it.  `tired-evil.el` uses the function
  `evil-define-minor-mode-key` instead, and `key-parse` converts a key
  string, because `define-key` treats `"RET"` as three characters.
- `define-minor-mode` defines a defcustom, so a mode without
  `:group 'tired` fails byte-compilation with "fails to specify
  containing group".
- The evil minor-mode maps are kept in `evil-minor-mode-keymaps-alist`
  against the mode symbol, and Emacs activates a map only while that
  symbol holds a value.  Turning `tired-evil-local-mode` on or off in a
  buffer therefore needs no `evil-normalize-keymaps` call.
- The evil tests call `evil-local-mode` and then read `key-binding`, so
  they test what the keyboard sees, not the keymap directly.  They
  `skip-unless` on `(require 'evil nil t)`, and `tired-tests-evil.el`
  declares every evil function it calls, so a checkout without evil
  still byte-compiles.

- `tired-noselect` owns `default-directory`.  Do not set it in
  `tired-mode`, because the mode runs before the directory is known.
  Without it a relative `find-file`, `compile` or `project-current`
  resolves against the buffer that created the listing.
- The buffer name keys the directory, so `tired-noselect` reuses the
  buffer through `tired--buffer-name`.  A renamed buffer would make a
  second buffer for the same directory.
- The user-visible display names take a capital: the mode line string is
  "Tired", like "Dired", and `tired--buffer-name` starts with
  "Tired: ".  The function names, the feature symbol and the file names
  stay lowercase, because Emacs reads them as code.

- A listing row is either a `tired-entry` or a `tired-section`.  Use
  `tired--row-at-point` and `tired--row-key`, not `tired-entry-p`
  accessors, on a row from the buffer.  Point and mark restore compare
  row keys, because a section key is `(PATH . LINE)` and a path
  comparison would land on the file row.
- Sections never sort.  `tired--section-rows` keeps handler order, so
  document order survives every sort key.  A sort reorders the file
  rows only.
- `tired--sections` caches by modification time.  A redraw must not
  clear it, because the point restore runs inside the redraw.  A
  vanished file drops out in `tired--reload-tables`.
- An expanded file needs its own file notification watch.  A directory
  watch reports a create or a rename in that directory, not an edit to
  a file inside it.
- Section depth comes from the declared `:level`, minus the level of
  the first section.  Without that subtraction an org file whose first
  heading is `**` would indent from a phantom parent.
- A folded section hides its descendants until a section with an equal
  or lower level appears.  The test needs both halves of the
  comparison, or the fold swallows the rest of the file.
- The filter matches a file name against the whole file.  A file row
  that fails the filter stays visible when one of its labels matches,
  and then only the matching sections show.  Narrow does not use the
  label: a narrowed-out file hides all of its sections.
- `minibuffer-contents` returns the text of the current buffer when
  that buffer is not a minibuffer.  Read it before
  `with-current-buffer`, or the filter becomes the whole listing and
  the header line prints every row.  `tired--filter-changed` holds
  that order.
- `tired--call-handler` catches every error and reports through
  `display-warning`.  One broken handler must not break the listing.
- A section without an action visits its file through
  `tired--visit-section`, which returns the visited buffer.  An action
  that must post-process the buffer, such as the org narrow, calls that
  helper instead of repeating the `find-file` and `forward-line` code.
- The org narrow option stays out of the parsed section.  The handler
  always installs `tired--org-open-heading`, and that function reads
  `tired-org-narrow-on-open` when it runs, so a changed option needs no
  re-parse and no cache invalidation.  The narrow runs only in Org mode
  and only when `org-narrow-to-subtree` succeeds, so a file that opens
  in another mode stays wide.  A narrowed org buffer renumbers its
  lines, so a test that checks a line number widens first.
- The Emacs Lisp handler skips whitespace and comments with
  `forward-comment` before it records the start of a form.  A
  `skip-chars-forward` would leave point on a leading `;' line, so the
  span scan would see a comment character instead of an open paren and
  the row would lose its faces and its line number.
- The section tests skip themselves without a grammar.  The Nix check
  supplies the grammars and exports `TREESIT_EXTRA_LOAD_PATH`; the test
  reads that variable at load time.  The Markdown test needs both the
  `markdown` and `markdown-inline` grammars.

- Flake sources are git-tracked files only.  `git add` a new file before
  `nix flake check`, or the build cannot see it.
- `tabulated-list-print` erases the buffer, so it strands the mark on
  line one.  `tired--redraw` records `(tired--entry-at (mark t))`
  before the print and `tired--restore-mark` sets the mark marker back
  on that entry's row.  Set the mark marker with `set-marker`, not
  `push-mark`, or every redraw grows the mark ring.  A deleted row
  leaves the mark where the reprint put it.  A window point marker
  collapses the same way, and `tired--restore-window-views` repairs it
  with `set-window-point`, because the display copies that marker back
  into the buffer point when the window regains the selection.  The
  display start marker collapses too, and `set-window-start` puts it
  back, or point would sit at the bottom of a window that starts at
  the first line.  Set the window point before the window start.
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
- A nil `tired-trash-directory` makes `tired--trash-root` name a
  per-process directory under `temporary-file-directory`, so the default
  stays a plain `defcustom` value and two Emacs sessions never share one
  trash.  Do not compute the default in the `defcustom` form: a user who
  sets nil must get the session directory and not a captured path.  The
  trash directory usually sits on another file system than the listed
  directory.  `rename-file`
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
  it, a symlink back to an ancestor loops forever.  The same set makes a
  link to an already shown directory print its row and no children.
- Use `tired--directory-entry-p`, not `tired-entry-dirp`, to decide
  whether a row can hold children.  `DIRP` covers real directories only,
  because `tired--sort-key`, the size column and the directory face read
  it.  A symbolic link that resolves to a directory therefore expands
  while it keeps its symlink face, its ` -> target` suffix, its file
  sort position and its own link size.
- Single-child collapse inspects every listed directory on refresh, so a
  root with many subdirectories costs one `directory-files` call each.
  The cache lives only until the next refresh.  Chain inspection stops at
  the first branch, and hidden files count as entries.
- A collapsed row stores the real file path with a relative display name.
  Selection, narrow and copy use the path.  Do not derive the file from
  the display name.
- `tired--name-cell` paints a collapsed row in two parts.  Every
  directory component takes `tired-directory-face`, and the last
  component takes the face that the file takes on its own row, so the
  row looks like a directory chain that ends in a file.  The
  `COLLAPSED` slot marks the clone, because a plain file name never
  holds a slash.  `tired--name-face` takes an optional NAME for this
  case: the user rule and the ignored suffix must see the base name,
  not the relative path.
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
  suffix, symlink, special file.  The first whole-name rule that matches
  wins.  A directory never takes a user rule, because the directory
  face marks the tree structure.  A rule value goes straight into the
  `face' property, so it may also hold a list of faces and anonymous
  faces.  Such a rule adds an attribute to a color, and an earlier
  element has higher priority, so an underline rule names the color
  first and `(:underline t)' second.
- A rule whose third element is an integer paints one submatch and no
  whole name.  `tired--rule-subexp` reads that element, and the value
  must pass `integerp', because a face list also fills the third
  position.  `tired--user-name-spans` collects one (START END FACE)
  span per matching partial rule in list order, so a later rule paints
  over an earlier one.  `tired--paint-name-spans` copies the plain
  string before it puts a property, because a struct name must not
  change.  A span combines its face with the face already on the text
  and puts the new value first, so the span wins an attribute clash
  and the base face still adds its own attributes.  A directory takes
  no span, for the same reason it takes no whole-name rule, and a
  collapsed row takes a span on the base name only, never on the
  directory chain.
- Recursive directory sizes stay off by default, because the first
  walk reads every directory below the shown one.
  `tired--subtree-size` never follows a symbolic link, so a link cycle
  cannot loop.  `tired--size-cell` keeps the column empty for a remote
  directory, because the walk would cost one network round trip per
  file.  `tired--size-cache` is a global `equal` table of
  `(TOTAL . STAMP)` pairs, so filter, sort, insert, fold and resize
  redraws reuse a total, and so does a refresh inside the window.
  `tired--size-cache-valid-p` reads `tired-size-cache-ttl`, which makes
  an edit deep in the tree show up at most one window late.
  `tired--reload-tables` calls `tired--size-cache-prune`, so the table
  never holds more than one window of totals.
- `tired--rows` holds a row list for one redraw only.  `tired--redraw`
  fills it and an `unwind-protect` empties it after the print, so
  `tired--visible-rows` walks the tree for any other caller and never
  serves a stale row set.  Do not keep the value between redraws: the
  filter, the insert set and the fold set all change without a refresh.
- Do not put `tired--size-cache` on `post-gc-hook`, and do not give it
  weak keys.  One walk of a large tree triggers several garbage
  collections itself: measured 5 collections in a 0.3s walk over 35k
  files.  A `post-gc-hook` clear therefore empties the table inside
  the very walk that fills it, and the next refresh walks again.  Weak
  keys fail the same way, because `tired--size-key` conses a fresh
  string for every walk, so the table drops to zero entries at the
  first collection.  Key the table by a string that a buffer keeps
  instead, and an entry never expires.  The countdown in
  `tired--size-cache-valid-p` stays the one freshness rule.
- Key the size memo with `tired--size-key`, never with
  `file-truename`.  The walk starts on one directory and skips every
  link, so the absolute name stays unique, and `file-truename` would
  cost one file round trip per path component.  Removing it halves a
  cold walk.
- `tired--ignored-regexp` caches a regexp for
  `completion-ignored-extensions`, an autosave name and a lock file
  name.  `tired--ignored-source` holds the value the cache derives
  from, so a changed variable rebuilds the regexp.  The ignored face
  applies to files and links, never to directories.
- The header line is rebuilt on every refresh.  `tired--header-base`
  holds the string from `tabulated-list-init-header`, so the directory
  title can be prepended without losing the column labels.
- `tired-hidden-regexps` matches an entry name, never the full path,
  the way `tired-name-faces` does, and it matches without case
  sensitivity, the way the name filter does.  `tired--hidden-p` runs after the
  single-child collapse, so a chain that ends in a hidden file drops
  its collapsed row too.  `tired--display-rows` drops a hidden row even
  when its VISIBLE-ONLY argument is nil, so the name column width and
  `tired--selected-entries` never see a hidden path.
- `tired--count-hidden` scans every table in `tired--tables` and
  `tired--redraw` stores the result in `tired--hidden-total`, because
  the mode line renders on every redisplay.  Do not scan the tables
  from `tired--mode-line`.  The count uses `tired--hidden-name-p`, not
  `tired--hidden-p`, so it ignores `tired--show-hidden` and the mode
  line prints `N hidden` or `N hidden shown`.  The count includes an
  entry that the dotfile setting or the filter also hides, and it
  includes the children of a hidden directory while that directory
  stays inserted.  The count follows a redraw, so a change to the
  option needs a redraw before the mode line updates.
- `~` carries `tired-toggle-hidden`, not `tired-select-invert`, in
  both `tired-mode-map` and `tired-evil-keys`.  `tired-select-invert`
  stays callable by name and keeps no key.  Replacing the key costs
  nothing, because the region already selects a run of entries.
- Rows must be vectors, not lists.  Emacs 31 `tabulated-list-print-entry`
  calls `aref` on them.  Do not "simplify" `tired--row` back to `list`.
- `tired-mode` sets `tabulated-list-padding` to 0, so no blank column
  starts a row.  Emacs draws the sort arrow in that padding, and every
  tired column stays unsortable, so the padding carries nothing.
- In batch Emacs, `pop-to-buffer` works but no window layout exists.
  Tests therefore assert buffer state, not window state.
