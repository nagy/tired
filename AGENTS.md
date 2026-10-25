# AGENTS.md — tired.el

## Overview

Single-file Emacs package (`tired.el`) that shows a directory as a
`tabulated-list-mode` buffer.  Entries come from `directory-files` and
`file-attributes`.  The package never parses `ls -l` output.  Entry
point is `M-x tired-find-directory`.

Minimum Emacs version is 31.1.  Emacs 31 changed
`tabulated-list-print-entry` to require a vector of column descriptors
in `tabulated-list-entries`; a list row is a type error.  The code uses
that vector form, so earlier Emacs versions cannot run it.

The package is read-only by design.  File operations, inline rename
editing and asynchronous loading live in git-bug issues, not in code.

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

1. `tired--read-entries` calls `directory-files` and builds a hash table
   of `tired-entry` structs.  `tired--make-entry` fills each struct from
   `file-attributes`.
2. `tired--sorted-entries` selects visible entries (dotfile and name
   filter) and sorts them.  Directories always come first.
3. `tired--tabulated-entries` renders each entry as a vector row.
   Emacs 31 requires the vector form.  `tabulated-list-print` draws the
   buffer.
4. `tired--apply-selection-overlays` highlights paths listed in
   `tired--selection`.  The selection is buffer-local and transient.
5. `tired-refresh` rebuilds the hash table, prunes dead selection paths,
   redraws the header line and restores point by entry path.

Sorting is implemented in `tired--lessp`, not in `tabulated-list`,
because tabulated-list cannot keep directories first while sorting other
columns.  `tabulated-list-format` therefore marks every column as
unsortable and the header line stays plain.  `tired-sort` prompts for a
column and redraws.

## Conventions

- Package prefix is `tired-`.  Private helpers use `tired--`.
- Public commands carry an `;;;###autoload` cookie only when they are
  entry points (`tired-mode`, `tired-find-directory`).
- Every function has a docstring.  `checkdoc` must pass.
- Byte-compilation with warnings as errors must pass.
- Faces inherit from built-in faces so themes keep working.
- AGPL3+ header in every Elisp file.

## Gotchas

- Flake sources are git-tracked files only.  `git add` a new file before
  `nix flake check`, or the build cannot see it.
- `tired--selection` stores absolute paths.  Pruning matches on both the
  base name (hash key) and the full path, so a renamed or recreated file
  drops out of the selection.
- `file-attributes` does not follow symlinks by default.  The struct
  records the link type and target, and commands use `file-directory-p`
  to follow directory symlinks.
- The header line is rebuilt on every refresh.  `tired--header-base`
  holds the string from `tabulated-list-init-header`, so the directory
  title can be prepended without losing the column labels.
- Rows must be vectors, not lists.  Emacs 31 `tabulated-list-print-entry`
  calls `aref` on them.  Do not "simplify" `tired--row` back to `list`.
- In batch Emacs, `pop-to-buffer` works but no window layout exists.
  Tests therefore assert buffer state, not window state.
