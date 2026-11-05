;;; tired-core.el --- Core listing and display for Tired  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; URL: https://github.com/nagy/tired

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The listing itself: entries, sorting, single-child collapse, the
;; file section framework, name faces, sizes, rows, selection,
;; point restore, file notification watches, the redraw and
;; `tired-mode'.  `tired.el' is the entry point and requires this
;; library, so a user still loads `tired'.

;;; Code:

(require 'bookmark)
(require 'browse-url)
(require 'cl-lib)
(require 'dired)
(require 'filenotify)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'thingatpt)

;; `tired-mode-map' binds commands that `tired-file-ops' defines.  The
;; declaration keeps the keymap free of a load-time dependency on the
;; file commands.
(declare-function tired-copy "tired-file-ops" (directory))
(declare-function tired-delete "tired-file-ops" nil)
(declare-function tired-do-shell-command "tired-file-ops" (command))
(declare-function tired-mkdir "tired-file-ops" (directory))
(declare-function tired-move "tired-file-ops" (destination))
(declare-function tired-rename "tired-file-ops" (name))
(declare-function tired-touch "tired-file-ops" (file))

;; The entry points live in `tired', which requires this library.  The
;; declarations keep the commands below free of a load-time dependency
;; on the file above this one.
(declare-function tired "tired" (directory))
(declare-function tired-jump "tired" (&optional other-window))
(declare-function tired-other-window "tired" (directory))

(defgroup tired nil
  "Tabulated list directory editor."
  :group 'files
  :prefix "tired-")

(defcustom tired-hide-dotfiles nil
  "When non-nil, do not list entries whose name starts with a dot."
  :type 'boolean)

(defcustom tired-hidden-regexps nil
  "List of regexps that hide an entry from the listing.
Each regexp matches the entry name, and case does not matter.  A
matching entry leaves the listing, and the sections of a matching
file leave it too.  A matching directory hides its inserted children
as well.  The mode line reports how many entries the rules hide.
`tired-toggle-hidden' shows the entries that the rules hide."
  :type '(repeat regexp))

(defcustom tired-sort-by-extension t
  "When non-nil, sort a name by its file extension before its name.
The name sort compares extensions the way `ls -X' does and then
compares the whole name, so files of one kind group together.  The
comparison folds case, so a `.txt' group holds a `.TXT' file too.  A
name without an extension sorts before every extension, and a
dotfile counts as extensionless.  Directories stay first.  The
other sort keys keep the plain name order, in the tie-break too."
  :type 'boolean)

(defcustom tired-group-directories t
  "When non-nil, sort every directory before every file.
The rule holds for every sort column.  Set it to nil to interleave
directories and files, the way `dired' sorts by time.  A collapsed
chain row keeps the group of its entry, because the row stands for
that entry."
  :type 'boolean)

(defcustom tired-sort-states
  '(name-asc name-desc size-asc size-desc
    elements-asc elements-desc modified-asc modified-desc)
  "Sort states that `tired-sort' cycles.
Each state names a column and a direction.  The text before the
last hyphen is the column that `tired--sort-by-column' reads, and
the suffix `asc' or `desc' gives the direction.  `tired-sort'
selects a state by its position in this list, so one numeric
prefix names it.  The default leaves out the `mode' column, because
a mode sorts by a number that says little.  Add `mode-asc' and
`mode-desc' to cycle that column too."
  :type '(repeat (choice (const :tag "Name, ascending" name-asc)
                         (const :tag "Name, descending" name-desc)
                         (const :tag "Size, ascending" size-asc)
                         (const :tag "Size, descending" size-desc)
                         (const :tag "Elements, ascending" elements-asc)
                         (const :tag "Elements, descending" elements-desc)
                         (const :tag "Modified, ascending" modified-asc)
                         (const :tag "Modified, descending" modified-desc)
                         (const :tag "Mode, ascending" mode-asc)
                         (const :tag "Mode, descending" mode-desc))))

(defcustom tired-date-format "%Y-%m-%d %H:%M"
  "Format string for the modification time column.
See `format-time-string' for the available conversions."
  :type 'string)

(defcustom tired-refresh-keeps-an-unchanged-listing t
  "When non-nil, a refresh keeps the rows that the disk did not change.
`tired-refresh' compares the modification time and the size of every
directory that the listing reads and of every expanded file, and a
listing whose stamps all match reads no directory, sorts no row and
prints nothing again.  The size walks still run, so a total that the
disk changed below an unchanged directory lands through the idle
reprint.  Set the option to nil to re-read and reprint on every
refresh."
  :type 'boolean
  :group 'tired)

(defcustom tired-auto-revert t
  "When non-nil, refresh the listing when a watched directory changes."
  :type 'boolean)

(defcustom tired-auto-revert-remote nil
  "When non-nil, watch a remote directory too.
A remote directory costs a network round trip for every
notification, and `file-notify-add-watch' fails on some TRAMP
methods.  This option defaults to nil, so a remote listing starts
without watches even when `tired-auto-revert' holds.  The
toggle command still works in the buffer, and it reports the
effective state."
  :type 'boolean)

(defcustom tired-auto-revert-delay 0.5
  "Seconds to wait after a file notification before refreshing.
A delay coalesces bursts of events, such as a build writing many
files, into one refresh."
  :type 'number)

(defcustom tired-display-buffer-action
  '(display-buffer-same-window (inhibit-same-window . nil))
  "Display action that `tired' uses for the listing.
The value takes the form that `display-buffer' accepts: a list of
action functions and an action alist.  The default replaces the
current buffer, like `dired'.  Set it to a pop-up action to give
the listing its own window, and add a `display-buffer-alist' entry
for a rule that depends on the buffer name.

Keep the list.  `display-buffer' reads a value that is any other
than a cons cell as the old request for another window, drops the
action function and adds `inhibit-same-window', so a bare function
symbol puts the listing in the wrong window."
  :type 'display-buffer--action-custom-type)

(defcustom tired-filter-delay 0.15
  "Seconds to wait before a typed filter redraws the listing.
A redraw walks the tree and prints every row, so a fast typist would
pay one redraw per keystroke.  The delay coalesces a burst of
keystrokes into one redraw, and the exit and quit keys apply the
pending text at once.  Set the value to 0 to redraw on every
keystroke."
  :type 'number
  :group 'tired)

(defcustom tired-filter-quit-commands '(keyboard-quit keyboard-escape-quit)
  "Commands that clear the name filter before they run.
The listing reads `this-command' in `pre-command-hook', so one list
covers every key that runs such a command, `M-x' included, and a user
binding reaches the same clear.  `tired-evil.el' adds
`evil-force-normal-state' to the list, so the evil quit key clears
the filter too."
  :type '(repeat symbol)
  :group 'tired)

(defcustom tired-after-redraw-hook nil
  "Hook that runs at the end of every redraw of a listing.
The hook runs with the listing buffer current, after the redraw
restores point, paints the selection and updates the mode line, so
a body reads the printed rows and the final point.  A redraw that a
name edit suspends runs no hook, and a refresh of an unchanged
listing runs no hook either, because neither pass prints a row.
A library that paints overlays on the printed rows belongs here,
because `tabulated-list-print' erases the buffer and the erase
collapses every overlay that another library put on the text.
A body never runs a view command and never changes the buffer: the
redraw calls this hook, so a redraw here loops forever."
  :type 'hook
  :group 'tired)

(defcustom tired-collapse-single-child t
  "When non-nil, collapse a single-entry directory chain into one row.
The chain runs while a directory holds exactly one entry.  It stops
at the first branch, so the collapsed row names the last entry of
the chain, file or directory.  The row shows the path relative to
the listed directory, uses the attributes of the leaf, and keeps the
directory's position in the listing.  The row acts as the leaf for
open, selection and copy, and a directory leaf still expands."
  :type 'boolean)

(defcustom tired-name-column-min-width 20
  "Minimum width of the name column.
The column grows to the longest visible name, up to the window width
minus the other columns."
  :type 'integer)

(defcustom tired-check-symlinks t
  "When non-nil, check whether a symbolic link resolves.
A link that does not resolve gets `tired-broken-symlink-face'.
Set the value to nil for remote directories, where the check costs
one network round trip per link."
  :type 'boolean)

(defcustom tired-directory-size nil
  "When non-nil, show the recursive size of each directory.
The size column then sums the bytes of every regular file under the
directory.  Symbolic links stay unfollowed.  A deep tree costs one
directory read per directory, and the idle queue spreads those
reads over several passes.  `tired-size-cache-ttl' then serves every
later redraw from a global memo table, and a refresh re-walks the
directories that it shows.  A remote directory never
shows a total, because the walk would cost one network round trip
per file.  A directory that `tired-directory-size-exclude' names
costs no walk either."
  :type 'boolean)

(defcustom tired-directory-size-exclude nil
  "List of regexps that name directories without a recursive size.
A directory that matches one regexp costs no walk, the way a remote
directory costs none: its size cell stays empty, its subtree adds
nothing to the total of a parent directory, and it counts as no byte
in the mode line.  Each regexp matches the absolute directory name,
both with and without a trailing slash, so a rule that ends in a
slash covers the whole subtree below a mount point and a rule that
ends in a string-end anchor covers one directory alone.  Set this
option for a mounted network directory that `file-remote-p' does not
reach."
  :type '(repeat regexp))

(defcustom tired-persistent-directories nil
  "List of regexps that name directories with a permanent cache.
A directory that matches keeps its cached size and its cached element
counts for the whole Emacs session.  No redraw, no refresh and no
`tired-size-cache-ttl' window drops them, and no idle pass walks the
subtree again.  Each regexp matches the absolute directory name, both
with and without a trailing slash, the way
`tired-directory-size-exclude' does, so a rule that ends in a slash
covers every directory below a mount point and a rule that ends in a
string-end anchor covers one directory alone.  Set this option for a
directory whose content never changes, such as a Nix store or an IPFS
mount.  A directory without a cached total takes one walk, so the
first listing of such a root pays one walk of every directory that it
shows.  A rule takes the auto-revert watch of its subtree as well,
because no change arrives there: a new child reaches the listing
through `tired-refresh' alone.  The permanent tables hold one entry
per directory and per file that a read reached, for the session.
Leave the value nil to keep the memory bound of the cache windows."
  :type '(repeat regexp))

(defcustom tired-size-cache-ttl 60
  "Seconds a computed directory size stays valid.
A total sums a whole subtree, so an edit deep in the tree can change
a size that a listing already shows.  A cached total serves every
redraw inside this window, and a stale total stays on screen until
the window ends.  A refresh queues a walk of every directory that it
shows, so a change that a refresh reads from the disk reaches the
column and the empty-directory mark one idle pass later.  Set the
value to 0 to drop the total at every refresh, so the cell empties
until the walk fills it again.  A garbage collection hook cannot
replace this window: Emacs collects garbage several times during one
walk of a large tree, so such a hook would empty the table faster
than it fills."
  :type 'natnum)

(defcustom tired-directory-size-budget 0.2
  "Seconds one idle pass may spend on directory size walks.
The redraw itself reads the memo table alone, so it never walks a
tree.  A queue pass stops when this budget ends and leaves the
remaining totals for the next idle pass.  Set the value to nil to
walk every queued directory in one pass."
  :type '(choice (natnum :tag "Seconds") (const :tag "No budget" nil)))

(defcustom tired-dwim-target t
  "When non-nil, `tired-copy' and `tired-move' read a destination.
The commands scan the windows of the frame, the way
`dired-dwim-target-next' does.  When another window shows a Tired
buffer for another directory, a command copies or moves the
targets into that directory at once and asks no question.  When no
such window exists, the command prompts in the minibuffer."
  :type 'boolean)

(defcustom tired-name-faces nil
  "Alist of rules that colorize entry names.
Each rule starts with a REGEXP that matches the entry name.  A rule
whose third element is an integer paints only that submatch, so the
rest of the name keeps its own face.  Any other rule paints the whole
name, and the first such rule wins.  The integer form costs one group
in the regexp and paints the text of that group.

A rule reaches files, symbolic links and special files.  A directory
keeps its own face.  FACE holds a face name, or a list of face names
and anonymous faces, so a rule can add an attribute to a color.  An
earlier list element has higher priority.  Partial rules apply in
list order, so a later rule paints over an earlier one on text both
rules cover.  The default is nil, so only the Dired faces colorize a
name."
  :type '(alist :key-type regexp :value-type sexp))

(defcustom tired-file-handlers
  '(("\\.org\\'" . tired-file-sections-org)
    ("\\.el\\'" . tired-file-sections-elisp)
    ("\\.rs\\'" . tired-file-sections-rust)
    ("\\.go\\'" . tired-file-sections-go)
    ("\\.\\(?:md\\|markdown\\)\\'" . tired-file-sections-markdown)
    ("/Cargo\\.toml\\'" . tired-file-sections-cargo)
    ("\\.tar\\'" . tired-file-sections-tar)
    ("\\.tar\\.\\(?:gz\\|zst\\)\\'" . tired-file-sections-tar)
    ("\\.\\(?:db\\|sqlite\\|sqlite3\\)\\'" . tired-file-sections-sqlite))
  "Alist of regexp to a function that extracts sections from a file.
The regexp matches the absolute file name, and the first match wins.
The function receives the file name and runs in a temporary buffer
that holds the file contents.  It selects its own major mode, then
returns a list of plists with the keys `:label', `:line', `:level'
and `:kind', plus the optional keys `:column', `:action' and
`:count'.  An `:count' number fills the Elements cell of the
section row, and any other value leaves it empty.  An empty list
means the file has no sections."
  :type '(alist :key-type regexp :value-type function))

(defcustom tired-section-file-size-limit nil
  "Largest file size in bytes that a section handler reads.
A file above the limit keeps its plain row and runs no handler.  Nil
means no limit.  A handler reads the whole file into a temporary
buffer, so a very large file costs memory and a visible pause.  The
limit reads the size that the file system reports, before that read,
and a skipped file enters no section cache, so a larger limit takes
effect on the next redraw."
  :type '(choice (const :tag "No limit" nil) integer))

(defcustom tired-org-narrow-on-open t
  "When non-nil, narrow an org buffer to the subtree that RET visits.
RET on an org heading visits the file and then narrows to that
heading, so the visited buffer shows one subtree.  The narrow runs
only in Org mode and only when point sits on a heading.  A section
action keeps this option out of the parsed section, so a change
takes effect on the next open without a re-parse."
  :type 'boolean)

(defface tired-directory-face
  '((t :inherit dired-directory))
  "Face for directory names.")

(defface tired-directory-suffix-face
  '((t :inherit parenthesis))
  "Face for the slash that marks a directory row.
The slash stays a separate run of text, so a theme colors it alone.")

(defface tired-symlink-face
  '((t :inherit dired-symlink))
  "Face for the name of a symbolic link.")

(defface tired-symlink-target-face
  '((t :inherit dired-symlink-filename))
  "Face for the target of a symbolic link.")

(defface tired-broken-symlink-face
  '((t :inherit dired-broken-symlink))
  "Face for a symbolic link whose target does not exist.")

(defface tired-special-face
  '((t :inherit dired-special))
  "Face for sockets, pipes and device files.")

(defface tired-ignored-face
  '((t :inherit dired-ignored))
  "Face for names that match `completion-ignored-extensions'.
An empty directory takes the face too, so a row that holds no byte
dims as one run.")

(defface tired-perm-write-face
  '((t :inherit dired-perm-write))
  "Face for the write permission of a group- or world-writable file.
The face paints the `w' character alone, as
`dired-font-lock-keywords' paints it.")

(defface tired-selected-face
  '((t :inherit dired-marked :extend t))
  "Face for entries in the transient selection.
The face inherits `dired-marked', so a theme colors a selected row the
way it colors a marked row in Dired.")

(defface tired-section-face
  '((t :inherit default))
  "Face for a section row without a more specific face.")

(defface tired-section-heading-face
  '((t :inherit bold))
  "Face for a section row whose kind is `heading'.")

(defface tired-date
  '((t :inherit org-date))
  "Face for the modification time column.
The column takes the Org date face, so a theme colors the stamp the
way it colors a date in an Org file.")

(defface tired-file-size
  '((t :inherit default))
  "Face for the size column.
The face inherits `default', so a theme colors a size through this
face alone and Tired names no outside package.")

(cl-defstruct (tired-entry (:constructor tired--entry-create))
  "One entry of a directory listing.
NAME is the file name without its directory.  PATH is the absolute
file name.  TYPE is one of `directory', `file', `symlink' or
`special'.  DIRP is non-nil for real directories only.  SIZE is the
size in bytes.  MTIME is a float time value.  MODE is the permission
string as returned by `file-attribute-modes'.  LINK is the link
target for symbolic links.  BROKEN is non-nil when a symbolic link
does not resolve.  COLLAPSED is non-nil on a display clone of a
single-entry chain, whose NAME holds the relative path.  REMOTE is
non-nil for a row on a network file system, nil for a local row, and
the symbol `unknown' for a row that no directory read built, so the
code that needs the answer asks `file-remote-p' once."
  name
  path
  type
  dirp
  size
  mtime
  mode
  link
  broken
  collapsed
  (remote 'unknown))

(cl-defstruct (tired-section (:constructor tired--section-create))
  "One row that a file handler extracted from a file.
LABEL is the display string without indentation.  PATH is the
absolute file name that holds the section.  LINE is 1-based.  COLUMN
is 0-based, or nil.  LEVEL is the nesting level that the handler
declared.  KIND is a symbol such as `heading' or `function'.  ACTION
is nil for a plain visit, or a function, or a cons of a function and
its arguments.  COUNT is an optional number that the Elements column
prints, or nil for an empty cell."
  label
  path
  line
  column
  level
  kind
  action
  count)

(defvar-local tired--directory nil
  "Absolute name of the directory shown in the current buffer.")

(defvar-local tired--tables nil
  "Hash table mapping absolute directory names to entry tables.")

(defvar-local tired--inserted nil
  "Hash table of directories whose children appear in the listing.")

(defvar-local tired--sort-key 'name
  "Column used to sort the listing.
One of `name', `size', `modified', `elements' or `mode'.")

(defvar-local tired--sort-flip nil
  "When non-nil, sort the listing in descending order.")

(defvar-local tired--filter nil
  "Name substring used to filter the listing, or nil.")

(defvar-local tired--hide-dotfiles nil
  "When non-nil, hide entries whose name starts with a dot.")

(defvar-local tired--hidden-total 0
  "Number of entries that `tired-hidden-regexps' matches.
The redraw counts them, so the mode line reads one number.")

(defvar-local tired--show-hidden nil
  "When non-nil, show the entries that `tired-hidden-regexps' hides.")

(defvar-local tired--copy-name-absolute nil
  "When non-nil, `tired-copy-name' copies a full path.
The command flips the value after each call, so one key alternates
between the name and the path.")

(defvar-local tired--selection nil
  "List of absolute file names in the transient selection.")

(defvar-local tired--selection-set nil
  "Hash set of the paths in `tired--selection'.")

(defvar-local tired--narrowed nil
  "List of paths shown exclusively, or nil when the listing is wide.")

(defvar-local tired--narrowed-set nil
  "Hash set of the paths in `tired--narrowed'.")

(defvar-local tired--header-base nil
  "Header line string built by `tabulated-list-init-header'.")

(defvar-local tired--mode-line-base nil
  "Mode line format without the Tired part.
`tired--update-mode-line' appends the Tired string to this list.")

(defvar-local tired--mode-line-cache ""
  "Tired part of the mode line, as `tired--update-mode-line' left it.
Redisplay reads this string, so it costs no tree walk.  Do not
compute it from a `:eval' element.")

(defvar-local tired--mode-line-region nil
  "Region state that `tired--mode-line-cache' was built from.
`tired--mode-line-maybe-update' compares it against the current
region and rebuilds the cache when the two differ.")

(defvar-local tired--rows nil
  "Visible rows of the current redraw, as (ROW . DEPTH) conses.
`tired--redraw' walks the tree once and leaves the result here, so
the name column width and the printed rows read one list instead of
two.  The value is nil outside a redraw, so any other caller walks
the tree itself and never sees a stale row set.")

(defvar-local tired--subtree-starts []
  "Vector of buffer positions that start a subtree.
Element `i' holds the start of the line that prints the `i'th
subtree of the listing, in print order.  `tired--redraw-buffer'
fills the vector after each print from `tired--rows', so
`tired-subtree-bounds' costs one search of it.  A name edit empties
the vector, because a longer name moves every later line start.")

(defvar-local tired--watches nil
  "Hash table of watched directory names to file descriptors.
A listing that collapses chains watches thousands of directories, so
the table keeps one entry per path and a sync costs one lookup.")

(defvar-local tired--revert-timer nil
  "Pending `tired-auto-revert-delay' timer, or nil.")

(defvar-local tired--filter-timer nil
  "Pending `tired-filter-delay' timer, or nil.")

(defvar-local tired--collapse-cache nil
  "Hash table mapping a directory to its `tired--chain' result.
A refresh keeps the table and bumps `tired--collapse-generation', so
a chain result survives one refresh until a directory that it walked
reports another stamp.")

(defvar-local tired--collapse-generation 0
  "Counter that a refresh bumps when it re-reads the disk.
A chain result records the generation that computed it, so a redraw
inside one generation trusts the table and reads nothing, and the
first redraw after a refresh checks the stamps of the walked
directories.")

(defvar-local tired--listing-stamps nil
  "Alist of the paths that the last read covered to their stamp.
A path holds its `(MTIME . SIZE)' pair.  `tired-refresh' compares it,
so a listing that the disk did not change reprints nothing.")

(defvar-local tired--expanded nil
  "Hash set of absolute file names whose sections appear in the listing.")

(defvar-local tired--sections nil
  "Hash table mapping an absolute file name to its parsed sections.
The value is a cons of the file modification time and the section
list.  A changed time re-parses the file.")

(defvar-local tired--folded nil
  "Hash set of `(PATH . LINE)' keys for folded sections.")

(defvar-local tired--name-edit nil
  "Non-nil while the listing shows editable name cells.
`tired-name-edit-mode' sets it, and `tired-edit-names' turns that
mode on.  A reprint then erases what the user typed, so
`tired--redraw' draws nothing while the value holds.")

(defvar tired--elements-value-function nil
  "Function that returns the element count of a row, or nil.
`tired-elements' installs it, so the core keeps the Elements column,
its sort key and its cell while the library holds the counts.  A nil
value prints an empty cell and sorts every row as unknown.")

(defvar tired--elements-queue-function nil
  "Function that queues the rows of the current redraw for a count.
`tired--redraw-buffer' calls it after the print, and
`tired-elements' installs it.")

(defvar tired--elements-prune-function nil
  "Function that drops stale element counts.
`tired--reload-tables' calls it on refresh, and `tired-elements'
installs it.")

;;; Idle queue

(defcustom tired-queue-reprint-delay 0.2
  "Seconds between the last finished idle job and its repaint.
One timer repaints every buffer that a job marked dirty, so a long
walk costs few reprints."
  :type 'number
  :group 'tired)

(cl-defstruct (tired--job (:constructor tired--job-create))
  "One resumable unit of work on the idle queue.
KEY names the job inside its KIND, so one key costs one job while it
waits.  STEP advances the job and returns `:more' or `:done'.
FINISH runs once after STEP returns `:done'.  BUDGET holds the
seconds that one pass may spend on this job, or nil for no limit.
OWNERS holds the buffers that wait for a repaint.  DATA holds the
state of the job kind."
  kind
  key
  step
  finish
  budget
  owners
  data)

(defvar tired--queue-jobs nil
  "Jobs that wait for a step.
The head job runs first.")

(defvar tired--queue-index (make-hash-table :test #'equal)
  "Hash table that maps a job key to the job that holds it.")

(defvar tired--queue-timer nil
  "Idle timer that runs one more pass over `tired--queue-jobs'.")

(defvar tired--queue-dirty nil
  "Buffers that wait for a repaint after a finished job.")

(defvar tired--queue-reprint-timer nil
  "Timer that repaints the buffers in `tired--queue-dirty'.")

(defun tired--queue-index-key (job)
  "Return the key that `tired--queue-index' maps to JOB.
The kind joins the key, so a size walk and an element count of one
directory stay two jobs."
  (declare (pure t) (side-effect-free t))
  (let ((key (tired--job-key job)))
    (when key
      (cons (tired--job-kind job) key))))

(defun tired--queue-job (kind key)
  "Return the queued job of KIND that holds KEY, or nil."
  (when key
    (gethash (cons kind key) tired--queue-index)))

(defun tired--queue-drop (job)
  "Remove JOB from the queue without a finish."
  (setq tired--queue-jobs (delq job tired--queue-jobs))
  (let ((key (tired--queue-index-key job)))
    (when (and key (eq (gethash key tired--queue-index) job))
      (remhash key tired--queue-index))))

(defun tired--queue-drop-where (predicate)
  "Drop every queued job that PREDICATE accepts."
  (dolist (job (copy-sequence tired--queue-jobs))
    (when (funcall predicate job)
      (tired--queue-drop job))))

(defun tired--queue-enqueue (job)
  "Push JOB onto the queue unless a job already holds its key.
Return JOB when it joins the queue, and nil when it does not."
  (let ((key (tired--queue-index-key job)))
    (unless (and key (gethash key tired--queue-index))
      (when key
        (puthash key job tired--queue-index))
      (push job tired--queue-jobs)
      (tired--queue-schedule)
      job)))

(defun tired--queue-adopt (job buffer)
  "Make BUFFER wait for the repaint of JOB."
  (unless (memq buffer (tired--job-owners job))
    (push buffer (tired--job-owners job))))

(defun tired--queue-mark-dirty (buffers)
  "Mark BUFFERS for a repaint after a finished job."
  (dolist (buffer buffers)
    (when (and (buffer-live-p buffer)
               (not (memq buffer tired--queue-dirty)))
      (push buffer tired--queue-dirty))))

(defun tired--queue-forget-buffer (buffer)
  "Drop BUFFER as an owner and drop every job that loses all owners."
  (setq tired--queue-dirty (delq buffer tired--queue-dirty))
  (dolist (job (copy-sequence tired--queue-jobs))
    (when (memq buffer (tired--job-owners job))
      (setf (tired--job-owners job) (delq buffer (tired--job-owners job)))
      (when (null (tired--job-owners job))
        (tired--queue-drop job)))))

(defun tired--queue-forget-current ()
  "Drop every idle job that the current buffer owns.
`kill-buffer-hook' runs this, because a dead buffer never repaints."
  (tired--queue-forget-buffer (current-buffer)))

(defun tired--queue-finish (job)
  "Drop JOB from the queue and run its finish function."
  (tired--queue-drop job)
  (when (functionp (tired--job-finish job))
    (funcall (tired--job-finish job) job)))

(defun tired--queue-holds-p (job)
  "Return non-nil when JOB still holds its place in the queue.
A pass that runs keeps its jobs in a local list, so this asks the
index, and a job that `tired--queue-drop' removed during the pass
costs no step."
  (declare (side-effect-free t))
  (let ((key (tired--queue-index-key job)))
    (or (null key)
        (eq (gethash key tired--queue-index) job))))

(defun tired--queue-run ()
  "Advance the queue until a budget ends or a key waits.
Each step gives way to the next job, so one large job never holds
the others.  A pass that leaves work schedules another idle pass.
The pass takes the queue down while it runs, so a finished job drops
from a short list and a job that joins the queue lands on a clean
one; a rotation of the whole queue per step would cost one list copy
per step."
  (setq tired--queue-timer nil)
  (let* ((head (car tired--queue-jobs))
         (budget (and head (tired--job-budget head)))
         (deadline (and budget (+ (float-time) budget)))
         (pending tired--queue-jobs)
         (kept nil))
    (setq tired--queue-jobs nil)
    (while (and (or pending kept)
                (not (input-pending-p))
                (or (null deadline) (< (float-time) deadline)))
      (if (null pending)
          ;; Every job took one step, so the unfinished ones take the
          ;; next round inside this pass.
          (setq pending (nreverse kept)
                kept nil)
        (let ((job (pop pending)))
          (when (tired--queue-holds-p job)
            (if (eq (funcall (tired--job-step job) job) :done)
                (tired--queue-finish job)
              (push job kept))))))
    (setq tired--queue-jobs
          (nconc (nreverse kept) pending (nreverse tired--queue-jobs))))
  (when tired--queue-jobs
    (tired--queue-schedule))
  (when tired--queue-dirty
    (tired--queue-reprint-schedule)))

(defun tired--queue-schedule ()
  "Arrange one more pass at the next idle period.
An idle timer fires once for one transition into the idle state, so
each pass schedules its own successor."
  (unless (timerp tired--queue-timer)
    (setq tired--queue-timer
          (run-with-idle-timer 0 nil #'tired--queue-run))))

(defun tired--queue-reprint-schedule ()
  "Arrange one reprint for every buffer that waits for a job."
  (unless (timerp tired--queue-reprint-timer)
    (setq tired--queue-reprint-timer
          (run-at-time tired-queue-reprint-delay nil
                       #'tired--queue-reprint))))

(defun tired--queue-reprint ()
  "Repaint every dirty buffer that a window shows.
A buffer that no window shows keeps its state and prints it at its
next redraw."
  (setq tired--queue-reprint-timer nil)
  (let ((dirty tired--queue-dirty))
    (setq tired--queue-dirty nil)
    (dolist (buffer (delete-dups dirty))
      (when (and (buffer-live-p buffer)
                 (get-buffer-window buffer t)
                 (with-current-buffer buffer
                   (derived-mode-p 'tired-mode)))
        (with-current-buffer buffer
          (tired--redraw))))))

(defun tired--read-entries (directory)
  "Return a hash table of entries for DIRECTORY.
The table maps file names to `tired-entry' structs.  One
`file-remote-p' call answers the network state of every row of the
directory, so a redraw asks no second time per row."
  (let ((table (make-hash-table :test #'equal))
        (remote (if (file-remote-p directory) t 'local)))
    (dolist (pair (directory-files-and-attributes directory nil nil t))
      (let ((name (car pair)))
        (unless (member name '("." ".."))
          (puthash name (tired--make-entry directory name (cdr pair) remote)
                   table))))
    table))

(defun tired--make-entry (directory name &optional attributes remote)
  "Return a `tired-entry' for NAME inside DIRECTORY.
ATTRIBUTES defaults to the result of `file-attributes' for the file.
`tired--read-entries' passes attributes that it already fetched.
REMOTE carries the network state that the caller read for DIRECTORY:
the symbol `local' for a local directory, any other non-nil value for
a remote one, and nil to ask `file-remote-p' for this row."
  (let* ((path (expand-file-name name directory))
         (attributes (or attributes (file-attributes path)))
         (type (file-attribute-type attributes))
         (remote (cond ((eq remote 'local) nil)
                       (remote t)
                       (t (and (file-remote-p path) t)))))
    (tired--entry-create
     :name name
     :path path
     :type (pcase type
             ('t 'directory)
             ((pred stringp) 'symlink)
             ('nil 'file)
             (_ 'special))
     :dirp (eq t type)
     :size (file-attribute-size attributes)
     :mtime (float-time (file-attribute-modification-time attributes))
     :mode (file-attribute-modes attributes)
     :link (and (stringp type) type)
     :broken (and (stringp type) (tired--broken-link-p path))
     :remote remote)))

(defun tired--broken-link-p (path)
  "Return non-nil when the symbolic link at PATH does not resolve.
A circular link counts as broken.  The user option
`tired-check-symlinks' turns the check off."
  (and tired-check-symlinks
       (not (ignore-errors (file-exists-p (file-truename path))))))

(defun tired--in-narrow-p (entry)
  "Return non-nil when ENTRY is inside the narrow snapshot."
  (or (not tired--narrowed)
      (and (hash-table-p tired--narrowed-set)
           (gethash (tired-entry-path entry) tired--narrowed-set))))

(defun tired--hidden-name-p (name)
  "Return non-nil when a regexp in `tired-hidden-regexps' matches NAME."
  (declare (side-effect-free t))
  (let ((case-fold-search t))
    (seq-some (lambda (regexp) (string-match-p regexp name))
              tired-hidden-regexps)))

(defun tired--hidden-p (entry)
  "Return non-nil when the listing holds ENTRY back as hidden."
  (and (not tired--show-hidden)
       (tired--hidden-name-p (tired-entry-name entry))))

(defun tired--chain-name-hidden-p (name)
  "Return non-nil when NAME, one link of a collapsed chain, stays hidden.
The link carries its own name and no path, so a dotfile rule that
reads the last component matches here as it does on a real row."
  (or (and (not tired--show-hidden)
           (tired--hidden-name-p name))
      (and tired--hide-dotfiles
           (string-prefix-p "." name))))

(defun tired--name-visible-p (entry)
  "Return non-nil when ENTRY passes the hidden, dotfile and name filters."
  (let ((case-fold-search t))
    (and (not (tired--hidden-p entry))
         (or (not tired--hide-dotfiles)
             (not (string-prefix-p "."
                                   (file-name-nondirectory
                                    (tired-entry-name entry)))))
         (or (null tired--filter)
             (string-match-p (regexp-quote tired--filter)
                             (tired-entry-name entry))))))

(defun tired--entry-visible-p (entry)
  "Return non-nil when ENTRY passes the narrow, dotfile and name filters."
  (and (tired--in-narrow-p entry)
       (tired--name-visible-p entry)))

(defun tired--sort-extension (entry)
  "Return the extension of ENTRY, folded to lower case.
A name without an extension returns an empty string, so it sorts
before every real extension."
  (declare (side-effect-free t))
  (downcase (or (file-name-extension (tired-entry-name entry)) "")))

(defun tired--shown-size (entry)
  "Return the byte count that the size column shows for ENTRY, or nil.
A file shows its own size.  A directory shows the total of its
subtree when `tired-directory-size' holds and the memo table holds a
total.  A remote directory, a directory that
`tired-directory-size-exclude' names and a walk that the idle queue
has not finished show nothing, so the value stays nil."
  (cond
   ((not (tired-entry-dirp entry)) (or (tired-entry-size entry) 0))
   ((not tired-directory-size) nil)
   ((tired--size-skip-p (tired-entry-path entry) entry) nil)
   (t (tired--directory-total (tired-entry-path entry)))))

(defun tired--directory-matches-p (directory regexps)
  "Return non-nil when DIRECTORY matches one regexp of REGEXPS.
Match the absolute name both with and without a trailing slash, so a
rule that ends in a slash covers every directory below a mount point
and a rule that ends in a string-end anchor covers one directory
alone."
  (declare (pure t) (side-effect-free t))
  (when (and (stringp directory) regexps)
    (let* ((name (directory-file-name (expand-file-name directory)))
           (slashed (file-name-as-directory name)))
      (seq-some (lambda (regexp)
                  (or (string-match-p regexp name)
                      (string-match-p regexp slashed)))
                regexps))))

(defun tired--persistent-p (directory)
  "Return non-nil when DIRECTORY keeps its cache for the session.
`tired-persistent-directories' holds the rules."
  (declare (side-effect-free t))
  (tired--directory-matches-p directory tired-persistent-directories))

(defun tired--size-excluded-p (directory)
  "Return non-nil when DIRECTORY matches `tired-directory-size-exclude'.
The rules match the way `tired--directory-matches-p' matches them."
  (declare (side-effect-free t))
  (tired--directory-matches-p directory tired-directory-size-exclude))

(defun tired--entry-remote-p (entry)
  "Return non-nil when ENTRY sits on a network file system.
A row that `tired--read-entries' built carries the answer that its
directory read, so a redraw asks nothing.  A row that a caller built
by hand holds `unknown' and asks `file-remote-p' here."
  (declare (side-effect-free t))
  (let ((remote (tired-entry-remote entry)))
    (if (eq remote 'unknown)
        (and (file-remote-p (tired-entry-path entry)) t)
      remote)))

(defun tired--size-skip-p (directory &optional entry)
  "Return non-nil when DIRECTORY takes no recursive size walk.
A remote directory always skips, because a walk there costs one
network round trip per file.  `tired-directory-size-exclude' skips a
local directory that the user names, such as a mount point.
ENTRY, when given, holds the row of DIRECTORY and its network state,
so no second `file-remote-p' runs for a row that a read already
answered."
  (declare (side-effect-free t))
  (and (stringp directory)
       (or (if entry
               (tired--entry-remote-p entry)
             (and (file-remote-p directory) t))
           (tired--size-excluded-p directory))))

(defun tired--sort-value (entry)
  "Return the value that `tired--sort-key' compares for ENTRY.
The name value holds the folded extension, so a group of one
extension stays together.  Without `tired-sort-by-extension' every
name shares one empty extension, so the name alone decides.  The
elements value comes from `tired--elements-show', so the order
follows the number that the column prints, and a row without a count
stays nil."
  (pcase tired--sort-key
    ('name (if tired-sort-by-extension
               (tired--sort-extension entry)
             ""))
    ('size (or (tired--shown-size entry) (tired-entry-size entry) 0))
    ('modified (tired-entry-mtime entry))
    ('elements (tired--elements-show entry))
    ('mode (tired-entry-mode entry))
    (_ (error "Unknown sort key: %S" tired--sort-key))))

(cl-defstruct (tired-sort-row (:constructor tired--sort-row-create))
  "One row while a listing level sorts.
ENTRY holds the table entry, DISPLAY the collapse clone that the
listing shows instead of it, VALUE the value of `tired--sort-key'
and NAME the name that breaks a tie."
  entry
  display
  value
  name)

(defun tired--sort-row (directory entry)
  "Return the `tired-sort-row' for ENTRY inside DIRECTORY.
The name key reads ENTRY, so a collapsed chain keeps the group and
the order of its directory.  Every other key reads the row that the
listing shows, so the order follows the size, the time and the mode
that the row prints."
  (let* ((clone (tired--collapsed-display-entry directory entry))
         (subject (if (eq tired--sort-key 'name) entry (or clone entry))))
    (tired--sort-row-create
     :entry entry
     :display clone
     :value (tired--sort-value subject)
     :name (tired-entry-name subject))))

(defun tired--lessp (a b)
  "Return non-nil when sort row A lists before sort row B.
With `tired-group-directories' set, a directory comes first.
Within a group, rows follow `tired--sort-key' and `tired--sort-flip',
with the name as the tie-breaker.  A row whose value is nil has no
value yet, such as an element count that waits in the idle queue, so
it lists after every row that has one, in both directions."
  (declare (side-effect-free t))
  (let ((a-dir (and tired-group-directories
                    (tired-entry-dirp (tired-sort-row-entry a))))
        (b-dir (and tired-group-directories
                    (tired-entry-dirp (tired-sort-row-entry b)))))
    (cond
     ((and a-dir (not b-dir)) t)
     ((and b-dir (not a-dir)) nil)
     (t (let ((left (tired-sort-row-value a))
              (right (tired-sort-row-value b)))
          (cond
           ((and (null left) (null right))
            (string< (tired-sort-row-name a)
                     (tired-sort-row-name b)))
           ((null left) nil)
           ((null right) t)
           ((if (numberp left) (< left right) (string< left right))
            (not tired--sort-flip))
           ((if (numberp left) (< right left) (string< right left))
            tired--sort-flip)
           (t (string< (tired-sort-row-name a)
                       (tired-sort-row-name b)))))))))

(defun tired--table (directory)
  "Return the entry table for DIRECTORY, or nil."
  (declare (side-effect-free t))
  (let ((directory (directory-file-name (expand-file-name directory))))
    (and (hash-table-p tired--tables)
         (gethash directory tired--tables))))

(defun tired--inserted-p (directory)
  "Return non-nil when the listing shows the children of DIRECTORY."
  (declare (side-effect-free t))
  (and (hash-table-p tired--inserted)
       (gethash (directory-file-name (expand-file-name directory))
                tired--inserted)))

(defun tired--directory-entry-p (entry)
  "Return non-nil when ENTRY can hold children.
A symbolic link counts when it resolves to a directory.  The row
keeps its symlink name and face either way."
  (declare (side-effect-free t))
  (and (tired-entry-p entry)
       (or (tired-entry-dirp entry)
           (and (eq (tired-entry-type entry) 'symlink)
                (file-directory-p (tired-entry-path entry))))))

(defun tired--sorted-directory-rows (directory visible-only)
  "Return the `tired-sort-row' list of DIRECTORY in display order.
When VISIBLE-ONLY is non-nil, drop entries hidden by the filter and
the dotfile setting."
  (let ((table (tired--table directory))
        rows)
    (when table
      (maphash (lambda (_name entry)
                 (when (or (not visible-only)
                           (tired--entry-visible-p entry))
                   (push (tired--sort-row directory entry) rows)))
               table))
    (sort rows #'tired--lessp)))

(defun tired--sorted-directory-entries (directory visible-only)
  "Return the entries of DIRECTORY in display order.
When VISIBLE-ONLY is non-nil, drop entries hidden by the filter and
the dotfile setting.  A collapsed entry returns the table entry, so
a caller reads the file that the row stands for."
  (mapcar #'tired-sort-row-entry
          (tired--sorted-directory-rows directory visible-only)))

(defun tired--directory-names (directory)
  "Return the entry names of DIRECTORY, or nil when unreadable."
  (ignore-errors
    (seq-remove (lambda (name) (member name '("." "..")))
                (directory-files directory nil nil t))))

(cl-defstruct (tired--chain (:constructor tired--chain-create))
  "One cached single-child chain walk.
LEAF holds the entry that the chain ends at, or nil when the chain
does not collapse.  VISITED holds the directories that the walk
read, start first.  STAMPS holds one `(MTIME . SIZE)' stamp per
visited directory, in the same order.  GENERATION holds the
`tired--collapse-generation' that produced the result."
  leaf
  visited
  stamps
  generation)

(defun tired--directory-stamp (directory)
  "Return the `(MTIME . SIZE)' stamp of DIRECTORY, or nil.
A new child changes the modification time of a directory and the
size of its name list, so the pair detects a chain that broke."
  (declare (side-effect-free t))
  (let ((attributes (file-attributes directory)))
    (when attributes
      (cons (float-time (file-attribute-modification-time attributes))
            (file-attribute-size attributes)))))

(defun tired--shown-stamps ()
  "Return the stamp of every path that the listing reads.
The value is an alist of `(PATH . STAMP)', sorted by path, and it
covers the shown directory, every inserted directory, every level of
every collapsed chain and every expanded file."
  (declare (side-effect-free t))
  (let (stamps)
    (when tired--directory
      (push (cons tired--directory
                  (tired--directory-stamp tired--directory))
            stamps))
    ;; A collapsed chain hides the levels below its directory row, so a
    ;; new child deep in the chain changes no directory that the tables
    ;; hold.  Stamp every level that a chain walk read.
    (when (hash-table-p tired--collapse-cache)
      (maphash (lambda (_directory chain)
                 (when (tired--chain-leaf chain)
                   (dolist (visited (tired--chain-visited chain))
                     (push (cons visited
                                 (tired--directory-stamp visited))
                           stamps))))
               tired--collapse-cache))
    (when (hash-table-p tired--tables)
      (maphash (lambda (directory _table)
                 (push (cons directory
                             (tired--directory-stamp directory))
                       stamps))
               tired--tables))
    (when (hash-table-p tired--expanded)
      (maphash (lambda (path _ignore)
                 (push (cons path (tired--directory-stamp path)) stamps))
               tired--expanded))
    (sort (delete-dups stamps)
          (lambda (a b) (string< (car a) (car b))))))

(defun tired--listing-changed-p ()
  "Return non-nil when a path that the listing reads did change.
A buffer that never read the disk counts as changed."
  (not (equal (tired--shown-stamps) tired--listing-stamps)))

(defun tired--single-entry-leaf (directory)
  "Return the `tired--chain' of the single-entry walk from DIRECTORY.
The leaf stays nil when DIRECTORY holds zero or several entries,
because such a chain does not collapse.  Every later level shortens
the chain: the walk stops at the first branch, at a hidden link, at
an unreadable directory or at a cycle, and the entry that it reached
becomes the leaf.  A visited-truename set stops cycles.  One
attributes read per level records the stamp that a later refresh
checks."
  (let ((current (directory-file-name (expand-file-name directory)))
        (remote (if (file-remote-p directory) t 'local))
        (seen (make-hash-table :test #'equal))
        (visited nil)
        (stamps nil)
        (leaf nil)
        (searching t))
    (while searching
      (let ((key (file-truename current)))
        (if (gethash key seen)
            (setq searching nil)
          (puthash key t seen)
          (push current visited)
          (push (tired--directory-stamp current) stamps)
          (let ((names (tired--directory-names current)))
            (if (or (/= 1 (length names))
                    (tired--chain-name-hidden-p (car names)))
                (setq searching nil)
              (let ((entry (tired--make-entry current (car names) nil remote)))
                (setq leaf entry)
                (if (tired-entry-dirp entry)
                    (setq current (tired-entry-path entry))
                  (setq searching nil))))))))
    (tired--chain-create :leaf leaf
                         :visited (nreverse visited)
                         :stamps (nreverse stamps)
                         :generation tired--collapse-generation)))

(defun tired--chain-current-p (chain)
  "Return non-nil when CHAIN still describes the disk.
A result of the current generation counts, because a redraw inside
one refresh reads no directory.  An older result needs every walked
directory to keep its stamp."
  (declare (side-effect-free t))
  (or (= (tired--chain-generation chain) tired--collapse-generation)
      (let ((directories (tired--chain-visited chain))
            (stamps (tired--chain-stamps chain))
            (live t))
        (while (and live directories)
          (unless (equal (tired--directory-stamp (car directories))
                         (car stamps))
            (setq live nil))
          (setq directories (cdr directories)
                stamps (cdr stamps)))
        live)))

(defun tired--collapse-result (directory)
  "Return the cached `tired--chain' result for DIRECTORY.
Recompute a result that a changed directory invalidated, and keep the
one that still matches, so a refresh costs one attributes read per
walked level instead of a directory read."
  (let* ((key (directory-file-name (expand-file-name directory)))
         (cached (and (hash-table-p tired--collapse-cache)
                      (gethash key tired--collapse-cache))))
    (if (and cached (tired--chain-current-p cached))
        cached
      (let ((result (tired--single-entry-leaf key)))
        (when (hash-table-p tired--collapse-cache)
          (puthash key result tired--collapse-cache))
        result))))

(defun tired--collapsed-file (directory)
  "Return the cached chain leaf for DIRECTORY, or nil."
  (tired--chain-leaf (tired--collapse-result directory)))

(defun tired--collapsed-display-entry (directory entry)
  "Return a display clone for ENTRY when it collapses to one entry.
DIRECTORY is the listed parent and provides the relative name.  The
result is nil when ENTRY is not a directory or does not collapse.
The leaf of the chain can be a file or a directory.  A remote
directory never collapses, because the chain walk reads one
directory per level, and every read costs a network round trip."
  (when (and tired-collapse-single-child
             (tired-entry-dirp entry)
             (not (tired--entry-remote-p entry)))
    (let ((file (tired--collapsed-file (tired-entry-path entry))))
      (when file
        (let ((clone (copy-tired-entry file)))
          (setf (tired-entry-name clone)
                (file-relative-name (tired-entry-path file) directory)
                (tired-entry-collapsed clone) t)
          clone)))))

;;; File sections

(defun tired-file-handler (path)
  "Return the section handler that `tired-file-handlers' selects for PATH.
Return nil when no rule matches PATH."
  (let ((name (expand-file-name path)))
    (cdr (seq-find (lambda (rule) (string-match-p (car rule) name))
                   tired-file-handlers))))

(defun tired--call-handler (handler path)
  "Return the raw section plists that HANDLER extracts from PATH.
Run HANDLER in a temporary buffer that holds the file contents, so a
handler parses what the disk holds and never a visiting buffer.
HANDLER selects its own major mode.  Return nil when the file is
unreadable or when HANDLER signals an error.  Read the file with
VISIT set, so the buffer keeps the file name and no modified flag,
and the discarded buffer never prompts on kill."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents path t)
        (funcall handler path))
    (error
     (display-warning 'tired
                      (format "Section handler %s failed on %s: %s"
                              handler (abbreviate-file-name path)
                              (error-message-string err))
                      :warning)
     nil)))

(defun tired--section-plist (item path)
  "Return ITEM as a `tired-section' struct for PATH.
ITEM is a plist with `:label' and `:line', plus the optional keys
`:column', `:level', `:kind', `:action' and `:count'."
  (tired--section-create
   :label (or (plist-get item :label) "")
   :path path
   :line (or (plist-get item :line) 1)
   :column (plist-get item :column)
   :level (or (plist-get item :level) 0)
   :kind (or (plist-get item :kind) 'section)
   :action (plist-get item :action)
   :count (plist-get item :count)))

(defun tired-file-sections (path &optional force)
  "Return the sections of PATH as a list of `tired-section' structs.
Parse the file when FORCE is non-nil or when its modification time
changed.  Return nil when no handler matches, when the file is gone,
when the file exceeds `tired-section-file-size-limit' or when the
handler found nothing."
  (let* ((handler (tired-file-handler path))
         (attributes (and handler (file-attributes path)))
         (time (and attributes
                    (file-attribute-modification-time attributes)))
         (size (and attributes (file-attribute-size attributes)))
         (too-big (and size tired-section-file-size-limit
                       (> size tired-section-file-size-limit)))
         (cached (and (hash-table-p tired--sections)
                      (gethash path tired--sections)))
         (sections
          (cond
           ((or (null attributes) too-big) nil)
           ((and (not force) cached (equal (car cached) time)) (cdr cached))
           (t (mapcar (lambda (item) (tired--section-plist item path))
                      (tired--call-handler handler path))))))
    (when (and attributes
               (not too-big)
               (hash-table-p tired--sections))
      (puthash path (cons time sections) tired--sections))
    sections))

(defun tired--expanded-p (path)
  "Return non-nil when the sections of PATH appear in the listing."
  (declare (side-effect-free t))
  (and (hash-table-p tired--expanded)
       (gethash (expand-file-name path) tired--expanded)))

(defun tired--set-expanded (path value)
  "Record VALUE as the expansion state of PATH."
  (when (hash-table-p tired--expanded)
    (if value
        (puthash (expand-file-name path) t tired--expanded)
      (remhash (expand-file-name path) tired--expanded))))

(defun tired--section-key (section)
  "Return the identity of SECTION inside the listing.
The key holds the file name and the line, so two sections on the
same line fold together and no other row collides with them."
  (declare (pure t) (side-effect-free t))
  (cons (tired-section-path section) (tired-section-line section)))

(defun tired--section-folded-p (section)
  "Return non-nil when SECTION hides its child sections."
  (and (hash-table-p tired--folded)
       (gethash (tired--section-key section) tired--folded)))

(defun tired--set-folded (section value)
  "Record VALUE as the fold state of SECTION."
  (when (hash-table-p tired--folded)
    (if value
        (puthash (tired--section-key section) t tired--folded)
      (remhash (tired--section-key section) tired--folded))))

(defun tired--section-visible-p (section)
  "Return non-nil when SECTION passes the name filter."
  (declare (side-effect-free t))
  (or (null tired--filter)
      (string-match-p (regexp-quote tired--filter)
                      (tired-section-label section))))

(defun tired--section-face (section)
  "Return the face for SECTION from its kind."
  (declare (pure t) (side-effect-free t))
  (pcase (tired-section-kind section)
    ((or 'heading 'title 'table) 'tired-section-heading-face)
    (_ 'tired-section-face)))

(defun tired--face-only-string (string)
  "Return STRING with only its `face' property.
A source span may carry a `keymap', a `mouse-face', a `display' or an
`invisible' property, as an org link does.  A listing row shows its
whole label and owns its own mouse handling, so those properties stay
out."
  (declare (pure t) (side-effect-free t))
  (let ((copy (substring-no-properties string))
        (position 0)
        (end (length string)))
    (while (< position end)
      (let* ((face (get-text-property position 'face string))
             (next (or (next-single-property-change position 'face string end)
                       end)))
        (when face
          (put-text-property position next 'face face copy))
        (setq position next)))
    copy))

(defun tired--section-cell (section)
  "Return the name column string for SECTION, without indentation.
A handler may return a label that already carries the faces of its
major mode.  Such a part keeps its face, and every part without one
takes the face of the section kind."
  (tired--paint-missing-face (tired-section-label section)
                            (tired--section-face section)))

(defun tired--section-rows (entry depth)
  "Return (SECTION . DEPTH) conses for the sections of ENTRY.
DEPTH is the depth of the file row, so every section indents below
it.  The level of the first section is the base, and a deeper
section adds one indent per extra level.  A folded section hides its
children."
  (let* ((sections (tired-file-sections (tired-entry-path entry)))
         (base (and sections (tired-section-level (car sections))))
         (hidden nil)
         rows)
    (dolist (section sections)
      (let ((level (tired-section-level section)))
        (when (and hidden (<= level hidden))
          (setq hidden nil))
        (unless hidden
          (when (tired--section-folded-p section)
            (setq hidden level))
          (push (cons section (+ depth 1 (max 0 (- level (or base 0)))))
                rows))))
    (nreverse rows)))

(defun tired--row-path (row)
  "Return the absolute file name that ROW describes.
A section returns the file that holds it, so the path commands reach
the file from a section row."
  (declare (pure t) (side-effect-free t))
  (if (tired-section-p row)
      (tired-section-path row)
    (tired-entry-path row)))

(defun tired--row-key (row)
  "Return the identity of ROW inside the listing.
An entry keys on its path.  A section keys on its path and its line,
so two sections of one file stay distinct."
  (when row
    (cond
     ((tired-section-p row) (tired--section-key row))
     ((tired-entry-p row)
      (directory-file-name (expand-file-name (tired-entry-path row)))))))

(defun tired--row-name-cell (row)
  "Return the name cell for ROW, without indentation."
  (if (tired-section-p row)
      (tired--section-cell row)
    (tired--name-cell row)))

(defun tired--display-rows (&optional visible-only)
  "Return (ROW . DEPTH) conses for the whole listing.
ROW is a `tired-entry' or a `tired-section'.  Children of inserted
directories follow the row of their parent and indent by DEPTH.  The
sections of an expanded file follow the row of that file.  With
VISIBLE-ONLY, skip hidden, filtered and narrowed-out entries.  A
directory seen twice through symlinks appears once.  A directory
that leads to a single entry chain collapses into one row for the
last entry of the chain, and the row takes the sort place that its
printed size, time and mode earn.
Such a row still shows the sections of its file, and still shows the
children of its directory, when the user expands it."
  (let ((rows nil)
        (seen (make-hash-table :test #'equal)))
    (cl-labels
        ((walk (directory depth)
           (let ((key (file-truename directory)))
             (unless (gethash key seen)
               (puthash key t seen)
               (dolist (sort-row (tired--sorted-directory-rows directory nil))
                 (let* ((entry (tired-sort-row-entry sort-row))
                        (collapsed (tired-sort-row-display sort-row))
                        (display (or collapsed entry))
                        (hidden (tired--hidden-p display))
                        (sections (and (not hidden)
                                       (not (tired--directory-entry-p display))
                                       (tired--expanded-p
                                        (tired-entry-path display))
                                       (tired--section-rows display depth)))
                        (name-visible (and (not hidden)
                                           (tired--name-visible-p display)))
                        (shown (and (not hidden)
                                    (cond
                                     ((not visible-only) sections)
                                     ((not (tired--in-narrow-p display)) nil)
                                     (name-visible sections)
                                     (t (seq-filter
                                         (lambda (row)
                                           (tired--section-visible-p (car row)))
                                         sections))))))
                   (unless hidden
                     (when (or (not visible-only)
                               (and (tired--in-narrow-p display)
                                    (or name-visible shown)))
                       (push (cons display depth) rows))
                     (dolist (row shown)
                       (push row rows)))
                   (when (and (not hidden)
                              (tired--directory-entry-p display)
                              (tired--inserted-p
                               (tired-entry-path display)))
                     (walk (tired-entry-path display) (1+ depth)))))))))
      (walk tired--directory 0))
    (nreverse rows)))

(defun tired--rows-between (start end)
  "Return the rows of the printed lines from START to END.
A line without a row, such as the empty line that the printer leaves
below the last row, adds nothing."
  (save-excursion
    (goto-char start)
    (let (rows)
      (while (and (< (point) end) (not (eobp)))
        (let ((row (tabulated-list-get-id)))
          (when row (push row rows)))
        (forward-line 1))
      (nreverse rows))))

(defun tired--visible-rows ()
  "Return the visible (ROW . DEPTH) conses of the current listing.
Inside a redraw the value comes from `tired--rows', so the tree
walks once.  Outside a redraw the function walks the tree itself."
  (or tired--rows (tired--display-rows t)))

(defun tired--visible-entries ()
  "Return the entries that are currently shown, in display order.
Section rows are not entries, so they stay out of the result."
  (seq-filter #'tired-entry-p (mapcar #'car (tired--visible-rows))))

(defun tired--subtree-start-positions (rows)
  "Return the positions that start a subtree of the printed listing.
ROWS holds the (ROW . DEPTH) conses that the current print walked,
and the printed lines follow that order, so one pass pairs every
depth-zero row with the start of its line."
  (save-excursion
    (goto-char (point-min))
    (let (starts)
      (dolist (row rows)
        (when (zerop (cdr row))
          (push (point) starts))
        (forward-line 1))
      (vconcat (nreverse starts)))))

(defun tired--subtree-index (position)
  "Return the index of the subtree that holds POSITION, or nil.
`tired--subtree-starts' holds one start per subtree in print order,
so the answer is the last start at or below POSITION."
  (declare (side-effect-free t))
  (let ((starts tired--subtree-starts))
    (when (> (length starts) 0)
      (let ((low 0)
            (high (1- (length starts)))
            (found nil))
        (while (<= low high)
          (let ((middle (/ (+ low high) 2)))
            (if (<= (aref starts middle) position)
                (setq found middle
                      low (1+ middle))
              (setq high (1- middle)))))
        found))))

(defun tired-subtree-bounds ()
  "Return the bounds of the subtree that holds point, or nil.
A subtree covers one depth-zero row of the listing and every row
that it prints below itself, so a row deep in an inserted directory
answers the same bounds as its depth-zero entry.  Point below the
last row answers the subtree of that row.  A listing without a row
answers nil, and so does a listing in a name edit, because an edit
moves the line starts that this function reads."
  (when-let* ((index (tired--subtree-index (point))))
    (cons (aref tired--subtree-starts index)
          (if (< (1+ index) (length tired--subtree-starts))
              (aref tired--subtree-starts (1+ index))
            (point-max)))))

(defun tired--forward-subtree (backward)
  "Move point to the edge of a subtree, the way `forward-thing' asks.
A forward move reaches the start of the next depth-zero row, and a
BACKWARD move reaches the start of the subtree above, so
`forward-thing' steps one subtree at a time the way it steps one
line at a time for the `line' thing.  A subtree at the edge of the
listing leaves point alone."
  (when-let* ((index (tired--subtree-index (point))))
    (let ((next (if backward (1- index) (1+ index))))
      (cond
       ((and (>= next 0) (< next (length tired--subtree-starts)))
        (goto-char (aref tired--subtree-starts next)))
       (backward
        (goto-char (point-min)))))))

(defvar tired--ignored-source nil
  "Value of `completion-ignored-extensions' behind the cached regexp.")

(defvar tired--ignored-regexp-cache nil
  "Cached regexp that matches an ignored file name.")

(defun tired--ignored-regexp ()
  "Return the regexp that matches a name Dired shows as ignored.
The regexp covers `completion-ignored-extensions', an autosave name
and a lock file name.  The cache follows the variable."
  (unless (equal completion-ignored-extensions tired--ignored-source)
    (setq tired--ignored-source completion-ignored-extensions
          tired--ignored-regexp-cache
          (concat "\\(?:"
                  (if completion-ignored-extensions
                      (concat (regexp-opt completion-ignored-extensions) "\\|")
                    "")
                  "#\\|\\.#.+\\)\\'")))
  tired--ignored-regexp-cache)

(defun tired--ignored-name-p (name)
  "Return non-nil when NAME matches `completion-ignored-extensions'."
  (string-match-p (tired--ignored-regexp) name))

(defun tired--rule-subexp (rule)
  "Return the submatch index that RULE names, or nil.
Only an integer third element names a submatch.  Any other value
belongs to a face list."
  (declare (pure t) (side-effect-free t))
  (let ((third (and (proper-list-p rule) (nth 2 rule))))
    (and (integerp third) third)))

(defun tired--user-name-face (name)
  "Return the whole-name face for NAME from `tired-name-faces'.
The first rule that matches NAME wins.  A rule with an integer third
element paints a submatch only, so it stays out of this search."
  (seq-some (lambda (rule)
              (and (not (tired--rule-subexp rule))
                   (string-match-p (car rule) name)
                   (cdr rule)))
            tired-name-faces))

(defun tired--user-name-spans (name)
  "Return the (START END FACE) spans that `tired-name-faces' paints on NAME.
A rule with an integer third element contributes the text of that
submatch.  Rules run in list order, so a later span follows an
earlier one that covers the same text."
  (let (spans)
    (dolist (rule tired-name-faces)
      (let ((subexp (tired--rule-subexp rule)))
        (when (and subexp
                   (string-match (car rule) name))
          (let ((start (match-beginning subexp))
                (end (match-end subexp)))
            (when (and start end (< start end))
              (push (list start end (nth 1 rule)) spans))))))
    (nreverse spans)))

(defun tired--entry-name-spans (entry name)
  "Return the `tired-name-faces' spans for NAME of ENTRY.
A directory returns no span, because the directory face marks the
tree structure."
  (unless (tired-entry-dirp entry)
    (tired--user-name-spans name)))

(defun tired--paint-name-spans (name spans)
  "Paint SPANS over NAME and return the result.
Each span is (START END FACE).  A span combines its face with a face
the text already holds, so a span inherits an attribute of the base
face.  NAME itself stays unchanged."
  (declare (pure t) (side-effect-free t))
  (let ((string (copy-sequence name)))
    (dolist (span spans)
      (let* ((start (nth 0 span))
             (end (nth 1 span))
             (face (nth 2 span))
             (base (get-text-property start 'face string))
             (value (if base (list face base) face)))
        (put-text-property start end 'face value string)
        (put-text-property start end 'font-lock-face value string)))
    string))

(defun tired--directory-empty-p (directory &optional entry)
  "Return non-nil when the subtree of DIRECTORY holds no byte.
ENTRY, when given, holds the row of DIRECTORY and its network state.
Read the memo table alone, so a redraw never walks a subtree.  A
directory with no cached total counts as non-empty, and the idle
walk dims it one pass later.  A remote directory counts as
non-empty, because its walk costs one round trip per file.  A
directory that `tired-directory-size-exclude' names counts as
non-empty too, because no walk reads it."
  (and (stringp directory)
       (not (tired--size-skip-p directory entry))
       (let ((total (tired--directory-total directory)))
         (and total (zerop total)))))

(defun tired--directory-slash-face (face)
  "Return the face for the slash of a directory whose name takes FACE.
An empty directory dims as one run, so its slash keeps the ignored
face.  Every other name takes `tired-directory-suffix-face'."
  (declare (pure t) (side-effect-free t))
  (if (eq face 'tired-ignored-face)
      face
    'tired-directory-suffix-face))

(defun tired--name-face (entry &optional name)
  "Return the face for the name of ENTRY, or nil for a plain name.
NAME defaults to the name of ENTRY.  The value covers the whole name,
and a partial rule contributes no value here.  The fixed order runs
empty directory, directory, broken link, user rule, ignored suffix,
symbolic link, special file.  The order otherwise follows
`dired-font-lock-keywords'."
  (let ((name (or name (tired-entry-name entry))))
    (cond
     ((and (tired-entry-dirp entry)
           (tired--directory-empty-p (tired-entry-path entry) entry))
      'tired-ignored-face)
     ((tired-entry-dirp entry) 'tired-directory-face)
     ((and (eq (tired-entry-type entry) 'symlink)
           (tired-entry-broken entry))
      'tired-broken-symlink-face)
     ((tired--user-name-face name))
     ((tired--ignored-name-p name) 'tired-ignored-face)
     ((eq (tired-entry-type entry) 'symlink) 'tired-symlink-face)
     ((eq (tired-entry-type entry) 'special) 'tired-special-face)
     (t nil))))

(defun tired--face-properties (face)
  "Return the text properties that show FACE.
`face' works when `font-lock-mode' is off.  `font-lock-face' survives
`font-lock-unfontify-region', which removes `face'.  A name cell
carries both, as `package-menu--print-info-simple' does."
  (declare (pure t) (side-effect-free t))
  (list 'face face 'font-lock-face face))

(defun tired--paint-missing-face (string face)
  "Return STRING with FACE on every part that carries no face.
Drop every text property except `face' first, so a row never inherits
a `keymap', an `invisible' or a `mouse-face' from its source text.  A
part that already carries a `face' property keeps it, so a handler may
mix a plain prefix with propertized source text.  Each face also lands
in `font-lock-face', which survives `font-lock-unfontify-region'.  A
FACE of nil leaves the uncovered parts alone."
  (declare (pure t) (side-effect-free t))
  (let ((string (tired--face-only-string string))
        (position 0)
        (end (length string)))
    (while (< position end)
      (let* ((source (get-text-property position 'face string))
             (next (or (next-single-property-change position 'face
                                                    string end)
                       end)))
        (if source
            (put-text-property position next 'font-lock-face source string)
          (when face
            (add-text-properties position next
                                 (tired--face-properties face)
                                 string)))
        (setq position next)))
    string))

(defun tired--propertize-name (name face &optional spans)
  "Return NAME with FACE applied, or NAME alone when FACE is nil.
Paint SPANS over the result when SPANS holds entries."
  (declare (pure t) (side-effect-free t))
  (let ((string (if face
                    (apply #'propertize name (tired--face-properties face))
                  name)))
    (if spans
        (tired--paint-name-spans string spans)
      string)))

(defun tired--symlink-suffix (entry)
  "Return the arrow and the target text for the symbolic link ENTRY."
  (declare (pure t) (side-effect-free t))
  (concat " -> "
          (apply #'propertize
                 (or (tired-entry-link entry) "?")
                 (tired--face-properties
                  (if (tired-entry-broken entry)
                      'tired-broken-symlink-face
                    'tired-symlink-target-face)))))

(defun tired--collapsed-name-cell (entry)
  "Return the name cell for the collapsed ENTRY.
Paint every directory component with the directory face, because the
row stands for a chain of directories.  Paint the last component
with the face its own row takes, and close a directory leaf with a
slash.  A symbolic link keeps its target arrow."
  (let* ((name (tired-entry-name entry))
         (file (file-name-nondirectory name))
         (head (string-remove-suffix file name))
         (face (tired--name-face entry file)))
    (concat (tired--propertize-name head 'tired-directory-face)
            (tired--propertize-name file face
                                    (tired--entry-name-spans entry file))
            (when (tired-entry-dirp entry)
              (tired--propertize-name "/" (tired--directory-slash-face face)))
            (when (eq (tired-entry-type entry) 'symlink)
              (tired--symlink-suffix entry)))))

(defvar tired--name-cells nil
  "Hash table of name cells for one redraw, or nil.
`tired--redraw-buffer' binds it, so one row builds its cell once for
the width pass, for the print and for the mouse region, instead of
three times.")

(defconst tired--name-cells-missing (make-symbol "tired--name-cells-missing")
  "Value that marks a row with no cached name cell.")

(defun tired--name-cell (entry)
  "Return the name column string for ENTRY."
  (if (hash-table-p tired--name-cells)
      (let ((cached (gethash entry tired--name-cells
                             tired--name-cells-missing)))
        (if (eq cached tired--name-cells-missing)
            (puthash entry (tired--name-cell-1 entry) tired--name-cells)
          cached))
    (tired--name-cell-1 entry)))

(defun tired--name-cell-1 (entry)
  "Return the name column string for ENTRY, without the redraw cache."
  (let* ((name (tired-entry-name entry))
         (face (tired--name-face entry))
         (spans (tired--entry-name-spans entry name)))
    (cond
     ((tired-entry-collapsed entry) (tired--collapsed-name-cell entry))
     (t (pcase (tired-entry-type entry)
          ('directory
           (concat (tired--propertize-name name face)
                   (tired--propertize-name
                    "/" (tired--directory-slash-face face))))
          ('symlink
           (concat (tired--propertize-name name face spans)
                   (tired--symlink-suffix entry)))
          (_ (tired--propertize-name name face spans)))))))

(defun tired--mouse-help (row)
  "Return the mouse help text for ROW.
The keys alone never show the mouse, so the text names the two
commands.  The middle button reads the row, and the second click of
a double click toggles it."
  (declare (side-effect-free t))
  (cond
   ((tired-section-p row)
    "mouse-2: visit in another window, double-click: fold")
   ((tired--directory-entry-p row)
    (concat "mouse-2: visit in another window, "
            "double-click: show or hide the children"))
   ((tired-file-handler (tired-entry-path row))
    "mouse-2: visit in another window, double-click: expand or collapse")
   (t "mouse-2: visit in another window")))

(defun tired--paint-row-help ()
  "Add the help text and the mouse face to every printed row.
`tabulated-list-print' erases and reprints the buffer, so this pass
runs after each print.  The whole line carries the help text, so the
indent of a nested row and the space beside the columns explain the
mouse commands too.  The name alone carries `mouse-face', as Dired
paints the name of a file, so the pointer highlights the name and
leaves the rest of the row alone."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((row (tabulated-list-get-id)))
          (when row
            (add-text-properties
             (line-beginning-position) (line-end-position)
             (list 'help-echo (tired--mouse-help row)))
            (when-let* ((name (tired--name-region)))
              (add-text-properties (car name) (cdr name)
                                   (list 'mouse-face 'highlight)))))
        (forward-line 1)))))

(defvar tired--size-cache (make-hash-table :test #'equal)
  "Global memo table for the directory size walks.
Every Tired buffer shares the table.  A key holds the absolute name
of a directory, so a walk needs no `file-truename' call to build
one.  A value holds `(TOTAL . STAMP)', where STAMP is the
`float-time' at which the walk that produced TOTAL started.
`tired-size-cache-ttl' bounds the age of a total and
`tired--size-cache-prune' drops the totals that expire.")

(defvar tired--size-cache-permanent (make-hash-table :test #'equal)
  "Memo table for the totals of `tired-persistent-directories'.
A walk of a directory that matches one of those rules stores its
total here instead of in `tired--size-cache', under the same
`(TOTAL . STAMP)' value.  No age drops a value: it lasts until
`tired-clear-caches', a change of the rules or Emacs exits.")

(defvar tired--child-cache (make-hash-table :test #'equal)
  "Global table of directory child counts.
The directory size walk reads every directory of a subtree with
`directory-files-and-attributes', so it stores the number of names
that it saw here, under the key of `tired--size-cache'.  A count
therefore lasts as long as the total beside it, and no second
directory read answers the Elements column.  A count of a key that
`tired--size-cache-permanent' holds outlives a prune, because the
prune walks the size tables alone.")

(defvar tired--size-cache-rules nil
  "Value of `tired-persistent-directories' that the table holds.
`tired--size-cache-prune' compares it, so a change of the rules
empties `tired--size-cache-permanent' once.")

(defvar tired--size-always nil
  "When non-nil, queue a directory size walk with no window.
Batch Emacs shows no window, so the test suite binds this to t.")

(defvar-local tired--elements-deferred nil
  "Non-nil when a redraw left the element counts of its rows unqueued.
The core sets it while no window shows the listing, and the next
display queues the rows that the window holds.")

(defvar-local tired--size-deferred nil
  "Non-nil when a redraw left a directory size unqueued.
`tired--size-queue' sets it while no window shows the listing, and
a display, an idle timer or the next redraw reads it.")

(defvar-local tired--size-forced nil
  "Time of the refresh that wants every shown total recomputed.
`tired--reload-tables' sets it, and `tired--size-queue' reads it
once and then clears it, so one refresh forces one walk per shown
directory.  A nil value means that the cached totals serve the
redraw.")

(defvar-local tired--size-timer nil
  "Timer that redraws the listing to queue its directory size walks.")

(defconst tired--size-redraw-delay 0.3
  "Idle seconds before a redraw queues a deferred directory size.")

(cl-defstruct (tired--size-walk (:constructor tired--size-walk-create))
  "State of one resumable directory size walk.
STAMP holds the `float-time' at which the walk started, so every
directory that the walk reaches carries one cache age.  STACK holds
the frames of the walk, the deepest first.  A frame is a plist with
`:directory', `:scanned' and `:total'."
  stamp
  stack)

(defun tired--size-key (directory)
  "Return the `tired--size-cache' key for DIRECTORY.
Normalise the name without a symbolic link resolution: the walk
starts on one directory and never descends through a link, so the
absolute name stays unique.  `file-truename' would cost one file
round trip per path component."
  (declare (side-effect-free t))
  (directory-file-name (expand-file-name directory)))

(defun tired--size-cache-valid-p (value)
  "Return non-nil when VALUE holds a total young enough to reuse."
  (declare (side-effect-free t))
  (and (consp value)
       (<= (- (float-time) (cdr value)) tired-size-cache-ttl)))

(defun tired--size-cache-clear ()
  "Drop every cached directory size.
Empty `tired--size-cache-permanent' as well, so a directory under a
rule walks its subtree again."
  (clrhash tired--size-cache)
  (clrhash tired--size-cache-permanent)
  (clrhash tired--child-cache))

(defun tired--size-cache-prune ()
  "Drop every cached total that `tired-size-cache-ttl' expired.
Call it on refresh, so the table holds no more than the directories
that one cache window can reach.  A change of
`tired-persistent-directories' empties `tired--size-cache-permanent'
as well, so a rule that left the list stops after one refresh."
  (unless (equal tired--size-cache-rules tired-persistent-directories)
    (setq tired--size-cache-rules (copy-sequence tired-persistent-directories))
    (clrhash tired--size-cache-permanent))
  (let (stale)
    (maphash (lambda (key value)
               (unless (tired--size-cache-valid-p value)
                 (push key stale)))
             tired--size-cache)
    (dolist (key stale)
      (remhash key tired--size-cache)
      (unless (gethash key tired--size-cache-permanent)
        (remhash key tired--child-cache)))))

(defun tired--size-window-p ()
  "Return non-nil when a window shows the listing.
A test binds `tired--size-always', because batch Emacs shows no
buffer in a window."
  (or tired--size-always
      (and (get-buffer-window-list (current-buffer) nil t) t)))

(defun tired--child-count (directory)
  "Return the number of names that the size walk saw in DIRECTORY.
Return nil when no walk of DIRECTORY has landed yet, so the caller
reads the directory itself."
  (declare (side-effect-free t))
  (gethash (tired--size-key directory) tired--child-cache))

(defun tired--size-store (key total walk)
  "Store TOTAL for KEY under the start stamp of WALK.
A KEY that matches `tired-persistent-directories' lands in
`tired--size-cache-permanent', so no window drops it."
  (puthash key (cons total (or (tired--size-walk-stamp walk) (float-time)))
           (if (tired--persistent-p key)
               tired--size-cache-permanent
             tired--size-cache)))

(defun tired--size-walk-scan (walk)
  "Read the children of the head frame of WALK.
Count every regular file in the total of the frame and record the
subdirectories that the frame still visits.  Keep the order of the
directory.  Skip symbolic links, so a link cycle cannot loop.  An
unreadable directory counts as empty."
  (let* ((stack (tired--size-walk-stack walk))
         (frame (car stack))
         (directory (plist-get frame :directory))
         (total 0)
         (names 0)
         children)
    (dolist (pair (ignore-errors
                   (directory-files-and-attributes directory nil nil t)))
      (unless (member (car pair) '("." ".."))
        (setq names (1+ names))
        (let ((type (file-attribute-type (cdr pair))))
          (cond
           ((eq t type)
            ;; A child that `tired-directory-size-exclude' names adds
            ;; no byte to this total and takes no frame of its own.
            (let ((child (expand-file-name (car pair) directory)))
              (unless (tired--size-excluded-p child)
                (push child children))))
           ((stringp type) nil)
           (t (setq total (+ total (or (file-attribute-size (cdr pair)) 0))))))))
    (puthash (tired--size-key directory) names tired--child-cache)
    (setcar stack (plist-put (plist-put (plist-put frame :total total)
                                        :names (nreverse children))
                             :scanned t))))

(defun tired--size-walk-visit (walk)
  "Push the next child directory of the head frame of WALK."
  (let* ((stack (tired--size-walk-stack walk))
         (frame (car stack))
         (names (plist-get frame :names)))
    (setcar stack (plist-put frame :names (cdr names)))
    (setf (tired--size-walk-stack walk)
          (cons (list :directory (car names)
                      :scanned nil
                      :total 0
                      :names nil)
                stack))))

(defun tired--size-walk-close (walk)
  "Close the head frame of WALK and add its total to the parent.
Store the total of the frame first, so a nested directory keeps its
own number.  Return `:more' while a frame stays in WALK and `:done'
at its root."
  (let* ((stack (tired--size-walk-stack walk))
         (frame (car stack))
         (total (plist-get frame :total))
         (rest (cdr stack)))
    (tired--size-store (tired--size-key (plist-get frame :directory))
                       total walk)
    (setf (tired--size-walk-stack walk) rest)
    (if (null rest)
        :done
      (let ((parent (car rest)))
        (setcar rest (plist-put parent :total
                                (+ (plist-get parent :total) total)))
        :more))))

(defun tired--size-walk-step (job)
  "Advance the walk of JOB by one directory.
Return `:more' while a frame waits and `:done' after the root total
lands in the cache."
  (let* ((walk (tired--job-data job))
         (stack (tired--size-walk-stack walk)))
    (cond
     ((null stack) :done)
     ((not (plist-get (car stack) :scanned))
      (tired--size-walk-scan walk)
      :more)
     ((plist-get (car stack) :names)
      (tired--size-walk-visit walk)
      :more)
     (t (tired--size-walk-close walk)))))

(defun tired--size-walk-advance (job)
  "Advance JOB by one directory and stop a walk that signals.
Store a zero total for the root, so a tree that raises an error
costs one pass and no second walk inside the cache window."
  (condition-case err
      (tired--size-walk-step job)
    (error
     (display-warning
      'tired
      (format "Directory size walk failed on %s: %s"
              (abbreviate-file-name (tired--job-key job))
              (error-message-string err))
      :warning)
     (tired--size-store (tired--job-key job) 0 (tired--job-data job))
     :done)))

(defun tired--size-walk-finish (job)
  "Repaint the buffers that wait for the walk of JOB."
  (tired--queue-mark-dirty (tired--job-owners job)))

(defun tired--size-walk-job-p (job)
  "Return non-nil when JOB walks a directory size."
  (declare (pure t) (side-effect-free t))
  (eq (tired--job-kind job) 'size))

(defun tired--size-enqueue (key directory &optional force entry)
  "Queue an idle walk of DIRECTORY under the cache key KEY.
A kept total, a young total, a remote directory, an excluded
directory and a queued walk cost no walk.  A kept total is one that
`tired--size-cache-permanent' holds, so a refresh walks no directory
under `tired-persistent-directories'.
FORCE recomputes a young total, because a refresh asked for the
size that the disk holds now.  FORCE also drops a queued walk that
started before FORCE, because that walk can still store a scan that
predates the change.  A walk that started after FORCE stays, so one
refresh never restarts itself."
  (when (and (not (gethash key tired--size-cache-permanent))
             (not (tired--size-skip-p directory entry))
             (or force
                 (not (tired--size-cache-valid-p
                       (gethash key tired--size-cache))))
             (progn
               (when force
                 (when-let* ((job (tired--queue-job 'size key)))
                   (when (< (or (tired--size-walk-stamp
                                 (tired--job-data job))
                                0)
                            force)
                     (tired--queue-drop job))))
               (null (tired--queue-job 'size key))))
    (tired--queue-enqueue
     (tired--job-create
      :kind 'size
      :key key
      :step #'tired--size-walk-advance
      :finish #'tired--size-walk-finish
      :budget tired-directory-size-budget
      :owners (list (current-buffer))
      :data (tired--size-walk-create
             :stamp (float-time)
             :stack (list (list :directory (expand-file-name directory)
                                :scanned nil
                                :total 0
                                :names nil)))))))

(defun tired--size-ancestor-p (key directories)
  "Return non-nil when a directory above KEY waits for a walk.
DIRECTORIES holds the keys that the redraw collected.  Stop at the
shown directory, so no row above the listing counts as an ancestor."
  (declare (side-effect-free t))
  (let ((ceiling (tired--size-key tired--directory))
        (parent (directory-file-name (file-name-directory key)))
        found)
    (while (and parent
                (not found)
                (string-prefix-p (file-name-as-directory ceiling)
                                 (file-name-as-directory parent)))
      (setq found (gethash parent directories)
            parent (directory-file-name (file-name-directory parent))))
    found))

(defun tired--size-queue ()
  "Queue the visible directory rows for an idle size walk.
`tired--redraw-buffer' calls this after the print.  A listing that
no window shows queues nothing and sets `tired--size-deferred', so
the next display starts the walk.  Only the topmost row of a chain
queues, because a walk covers the subtree of its row."
  (if (not (tired--size-window-p))
      (setq tired--size-deferred t)
    (let ((directories (make-hash-table :test #'equal))
          (force tired--size-forced))
      (setq tired--size-forced nil)
      (dolist (cell (tired--visible-rows))
        (let ((row (car cell)))
          (when (and (tired-entry-p row)
                     (tired-entry-dirp row)
                     (not (tired--size-skip-p (tired-entry-path row) row)))
            (puthash (tired--size-key (tired-entry-path row)) row
                     directories))))
      (maphash (lambda (key row)
                 (unless (tired--size-ancestor-p key directories)
                   (tired--size-enqueue key key force row)))
               directories))))

(defun tired--directory-total (directory)
  "Return the byte total that the memo table holds for DIRECTORY, or nil.
The redraw reads the two memo tables alone, so no redraw walks a
tree, and a total that `tired--size-cache-permanent' keeps needs no
rule match.  A refresh drops the totals that
`tired-size-cache-ttl' expired, and `tired--size-queue' queues a new
walk for a directory without a young total.  A refresh also queues a
walk of every directory that it shows, so a live total never hides a
change that the refresh just read from the disk."
  (let ((key (tired--size-key directory)))
    (let ((hit (or (gethash key tired--size-cache-permanent)
                   (gethash key tired--size-cache))))
      (when (consp hit)
        (car hit)))))

(defvar-local tired--name-column-window-width nil
  "Width of the window that the last print sized the name column for.
A redraw records it, and `tired--width-changed-p' compares it, so a
resize costs one `window-width' call instead of a walk over every
row.")

(defvar-local tired--width-window nil
  "Window that decides the name column width, or nil before a redraw.
`tabulated-list-format' belongs to the buffer, so one width serves
every window and every frame that shows the listing.  A redraw pins
the window that renders the listing here, and a later redraw reads
the pin, so a timer or a frame event never restyles the columns from
a window of another size.")

(defun tired--width-window (&optional hint)
  "Return the window that decides the name column width.
Prefer the pin in `tired--width-window' while it still shows the
listing, then HINT while it shows the listing, then the selected
window while it shows it, then the first window that shows it.
The selected window alone is no answer: it can show another buffer
in another frame, with another width, and the buffer holds one
`tabulated-list-format' for every window."
  (let ((shown (get-buffer-window-list (current-buffer) nil t)))
    (cond
     ((memq tired--width-window shown) tired--width-window)
     ((memq hint shown) hint)
     ((memq (selected-window) shown) (selected-window))
     ((car shown))
     (t (selected-window)))))

(defun tired--pin-width-window (&optional hint)
  "Pin the window that decides the name column width, and return it.
HINT is the window that a caller offers, or nil.  A window that
does not show the listing stays unpinned, so a listing that no
window shows keeps a stale pin out of its way."
  (let ((window (tired--width-window hint)))
    (when (memq window (get-buffer-window-list (current-buffer) nil t))
      (setq tired--width-window window))
    window))

(defun tired--schedule-size-redraw (&optional delay)
  "Redraw the listing after DELAY seconds to queue a deferred size.
DELAY defaults to `tired--size-redraw-delay'.  A zero delay moves the
redraw out of a display hook, where a reprint must wait.  A listing
that no window shows queues nothing, and the next display starts the
walk."
  (when (and tired--size-deferred
             (tired--size-window-p)
             (not (timerp tired--size-timer)))
    (let ((buffer (current-buffer)))
      (setq tired--size-timer
            (run-at-time (or delay tired--size-redraw-delay)
                         nil #'tired--size-redraw buffer)))))

(defun tired--size-redraw (buffer)
  "Redraw BUFFER so a shown listing queues its directory size walks."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq tired--size-timer nil)
      (when (and (derived-mode-p 'tired-mode)
                 tired--size-deferred
                 (tired--size-window-p))
        (tired--redraw (tired--width-window))))))

(defun tired--elements-queue-shown ()
  "Queue the element counts that the windows of the listing show.
`post-command-hook' calls this, so a scroll queues the rows that it
revealed.  The core keeps no count itself, so it calls
`tired--elements-queue-function'."
  (when (and tired--elements-queue-function
             (tired--size-window-p))
    (funcall tired--elements-queue-function)))

(defun tired--window-buffer-changed (_window)
  "Redraw the listing after a window starts to show it.
A redraw that no window shows queues no directory size walk and no
element count, so the first redisplay of the buffer queues both.
Redisplay runs this hook, so the reprint goes through a timer."
  (when (or tired--size-deferred tired--elements-deferred)
    (tired--schedule-size-redraw 0)))

(defun tired--size-cell (entry)
  "Return the size column string for ENTRY.
A remote directory keeps the column empty, because a walk over the
network costs one round trip per file, and a directory that
`tired-directory-size-exclude' names keeps it empty too.
`tired--shown-size' decides the number, so the size sort and the cell
agree."
  (let ((size (tired--shown-size entry)))
    (if size (file-size-human-readable size) "")))

(defun tired--size-column (entry)
  "Return the size cell for ENTRY, painted with `tired-file-size'.
An empty cell keeps no face, because a face on no text shows
nothing."
  (let ((text (tired--size-cell entry)))
    (if (string-empty-p text)
        text
      (propertize text 'face 'tired-file-size
                  'font-lock-face 'tired-file-size))))

(defun tired--elements-show (row)
  "Return the element count that ROW shows, or nil.
A section row carries the count that its handler read, so its cell
needs no cache read.  Every other row reads the count of
`tired-elements' through `tired--elements-value-function'.  A row
without a value sorts and prints as unknown."
  (if (tired-section-p row)
      (tired-section-count row)
    (if tired--elements-value-function
        (funcall tired--elements-value-function row)
      nil)))

(defun tired--elements-cell (row)
  "Return the Elements cell for ROW.
A row without a count keeps the cell empty, so a pending count shows
nothing until the idle queue fills it."
  (let ((count (tired--elements-show row)))
    (if (integerp count) (number-to-string count) "")))

(defun tired--mode-cell (entry)
  "Return the Mode column string for ENTRY.
A mode whose group or world part holds a `w' paints that character
with `tired-perm-write-face', the way Dired paints it.  Like the
Dired rule, the cell needs a `-' or a `d' in its first place."
  (declare (pure t) (side-effect-free t))
  (let ((modes (tired-entry-mode entry)))
    (cond
     ((not (and modes (<= 10 (length modes))
                (memq (aref modes 0) '(?- ?d))))
      (or modes ""))
     (t
      (let ((cell (copy-sequence modes))
            (index 5))
        (while (<= index 8)
          (when (eq (aref cell index) ?w)
            (add-text-properties index (1+ index)
                                 (tired--face-properties
                                  'tired-perm-write-face)
                                 cell))
          (setq index (+ index 3)))
        cell)))))

(defun tired--row (row depth)
  "Return the tabulated list row for ROW at DEPTH.
ROW is a `tired-entry' or a `tired-section'.  A section leaves the
size, the date and the mode empty, and fills the Elements cell with
the count that its handler read, because one table format serves
every row.
Emacs 31 requires a vector of column descriptors here; a list makes
`tabulated-list-print-entry' signal a type error."
  (if (tired-section-p row)
      (vector (concat (make-string (* 2 depth) ?\s)
                      (tired--section-cell row))
              ""
              (tired--elements-cell row)
              ""
              "")
    (vector (concat (make-string (* 2 depth) ?\s)
                    (tired--name-cell row))
            (tired--size-column row)
            (tired--elements-cell row)
            (propertize (format-time-string tired-date-format
                                            (tired-entry-mtime row))
                        'face 'tired-date
                        'font-lock-face 'tired-date)
            (tired--mode-cell row))))

(defun tired--tabulated-entries ()
  "Return `tabulated-list-entries' for the current listing.
When `tired-directory-size' is non-nil, the global memo table
serves every row of every redraw, so a nested directory costs one
read per `tired-size-cache-ttl' window, not one read per redraw.
`tired-directory-size-budget' stops the walk, and a stopped walk
leaves the size cell of its row empty until the next pass."
  (mapcar (lambda (row)
            (list (car row) (tired--row (car row) (cdr row))))
          (tired--visible-rows)))

(defun tired--column-sort-keymap (key)
  "Return a key map that sorts the listing by KEY.
A click on the header of the column runs `tired--sort-by-column',
so the column that already sorts the listing flips the direction."
  (let ((map (make-sparse-keymap))
        (command (lambda () (interactive) (tired--sort-by-column key))))
    (define-key map [header-line mouse-1] command)
    ;; `follow-link' can turn a click into a drag event.  Bind the
    ;; second button too, so the header sorts either way.
    (define-key map [header-line mouse-2] command)
    map))

(defun tired--sort-indicator ()
  "Return the character that marks the current sort direction.
The character comes from `tabulated-list-gui-sort-indicator-asc'
and `tabulated-list-gui-sort-indicator-desc', so the user sets the
marker through the Emacs options.  `tabulated-list-mode' supplies a
buffer-local `glyphless-char-display' table, so a text terminal frame
shows `tabulated-list-tty-sort-indicator-asc' or
`tabulated-list-tty-sort-indicator-desc' in its place."
  (if tired--sort-flip
      tabulated-list-gui-sort-indicator-desc
    tabulated-list-gui-sort-indicator-asc))

(defun tired--column-label (label key)
  "Return LABEL with a direction indicator when KEY is the sort key.
The label carries a key map, so a click on the header sorts by that
column.  The indicator stays in the string, and a click on the
current sort column flips the direction."
  (propertize (if (eq key tired--sort-key)
                  (concat label (format " %c" (tired--sort-indicator)))
                label)
              'keymap (tired--column-sort-keymap key)
              'mouse-face 'header-line-highlight
              'help-echo "mouse-1: sort by this column"))

(defconst tired--fixed-column-width 48
  "Width of the columns that keep their size.
This sum covers the size, modification time, elements and mode
columns, the left padding and the space after the name column.")

(defun tired--name-column-width (&optional window)
  "Return the width of the name column for WINDOW.
Grow the column to the longest visible name.  Clamp it to at least
`tired-name-column-min-width' and to the window width minus the
other columns."
  (let ((longest (string-width (tired--column-label "Name" 'name)))
        (available (- (window-width (or window (selected-window)))
                      tired--fixed-column-width)))
    (when tired--directory
      (dolist (row (tired--visible-rows))
        (setq longest
              (max longest
                   (+ (* 2 (cdr row))
                      (string-width (tired--row-name-cell (car row))))))))
    (max tired-name-column-min-width
         (min longest available))))

(defun tired--format (&optional name-width)
  "Return `tabulated-list-format' for the current sort state.
NAME-WIDTH is the width of the name column, or nil to size the
column from the current listing."
  (vector
   (list (tired--column-label "Name" 'name)
         (or name-width (tired--name-column-width))
         nil)
   (list (tired--column-label "Size" 'size) 9 nil :right-align t)
   (list (tired--column-label "Elements" 'elements) 10 nil :right-align t)
   (list (tired--column-label "Modified" 'modified) 17 nil)
   (list (tired--column-label "Mode" 'mode) 10 nil)))

(defun tired--escape-mode-line (text)
  "Return TEXT with every percent sign doubled.
The mode line and the header line read `%' as the start of a
substitution, so a literal sign needs two.  A filter string and a
directory name can hold any character, and `%b' in a filter would
print the buffer name."
  (declare (pure t) (side-effect-free t))
  (replace-regexp-in-string "%" "%%" text t t))

(defun tired--header-title ()
  "Return the listing state shown in the header line.
The buffer name already names the directory, so the header line
holds the state alone and stays empty without one."
  (let ((parts '()))
    (when tired--narrowed
      (push "[narrowed]" parts))
    (when tired--filter
      (push (format "[filter: %s]" tired--filter) parts))
    (when tired--hide-dotfiles
      (push "[dotfiles hidden]" parts))
    (mapconcat #'identity (nreverse parts) "  ")))

(defun tired--count-hidden ()
  "Return the number of entries that `tired-hidden-regexps' matches.
Count the entries of every shown directory, whether or not the
filter, the narrow snapshot or the dotfile setting also hides one,
and whether or not the buffer shows them at the moment."
  (let ((count 0))
    (when (and tired-hidden-regexps (hash-table-p tired--tables))
      (maphash
       (lambda (_directory table)
         (maphash (lambda (_name entry)
                    (when (tired--hidden-name-p (tired-entry-name entry))
                      (setq count (1+ count))))
                  table))
       tired--tables))
    count))

(defun tired--mode-line ()
  "Return the `tired-mode' mode line string.
Return the empty string when the listing holds no optional state, so
an ordinary listing shows no bracket group at all."
  (let ((parts '()))
    (when tired--selection
      (push (format "%d selected, %s"
                    (length tired--selection)
                    (file-size-human-readable (tired--selection-size)))
            parts))
    (when (and (null tired--selection) (use-region-p))
      (let ((entries (tired--region-entries)))
        (push (format "%d in region, %s"
                      (length entries)
                      (file-size-human-readable (tired--entries-size entries)))
              parts)))
    (when tired--narrowed
      (push "narrowed" parts))
    (when (and (hash-table-p tired--inserted)
               (> (hash-table-count tired--inserted) 0))
      (push (format "%d inserted" (hash-table-count tired--inserted)) parts))
    (when (and (hash-table-p tired--expanded)
               (> (hash-table-count tired--expanded) 0))
      (push (format "%d expanded" (hash-table-count tired--expanded)) parts))
    (when (> tired--hidden-total 0)
      (push (format (if tired--show-hidden
                        "%d hidden shown"
                      "%d hidden")
                    tired--hidden-total)
            parts))
    (when tired--filter
      (push (format "filter: %s" tired--filter) parts))
    (unless tired-collapse-single-child
      (push "no collapse" parts))
    (unless tired-auto-revert
      (push "auto-revert off" parts))
    (if parts
        (concat " [" (string-join (nreverse parts) ", ") "]")
      "")))

(defun tired--update-mode-line ()
  "Rebuild the Tired part of the mode line and install it.
The redraw calls this, so redisplay reads one string instead of
calling `tired--mode-line' for every visible frame.  That function
walks the tree to sum the selection size, and a redisplay must not
pay for it.  A region change runs the function too, because the
region count changes with no redraw."
  (setq tired--mode-line-region (tired--region-signature))
  (let ((text (tired--mode-line)))
    (unless (equal text tired--mode-line-cache)
      (setq tired--mode-line-cache text)
      (setq mode-line-format
            (if (string-empty-p text)
                tired--mode-line-base
              (append tired--mode-line-base
                      (list (tired--escape-mode-line text)))))))
  (force-mode-line-update))

(defun tired--region-signature ()
  "Return a value that changes when the active region changes.
The mode line reports the number of rows in the region, and point
motion inside an active region changes that number with no redraw
and no mark hook, so the cache keys on this signature."
  (when (region-active-p)
    (list (region-beginning) (region-end))))

(defun tired--mode-line-maybe-update ()
  "Rebuild the mode line when the active region changed.
`tired-mode' runs this from `post-command-hook', so a moved point
inside an active region reaches the mode line without a redraw."
  (unless (equal (tired--region-signature) tired--mode-line-region)
    (tired--update-mode-line)))

(defun tired--row-at-point ()
  "Return the row at point, or nil when there is none.
The row is a `tired-entry' or a `tired-section'."
  (let ((id (tabulated-list-get-id)))
    (and (or (tired-entry-p id) (tired-section-p id)) id)))

(defun tired--row-at (position)
  "Return the row on the line at POSITION, or nil."
  (when position
    (save-excursion
      (goto-char position)
      (tired--row-at-point))))

(defun tired--name-text (row)
  "Return the displayed name of ROW without indentation and decoration.
The decoration covers the arrow that shows a symbolic link target
and the slash that closes a directory name."
  (let ((cell (tired--row-name-cell row)))
    (cond
     ((and (tired-entry-p row)
           (eq (tired-entry-type row) 'symlink))
      (string-remove-suffix (tired--symlink-suffix row) cell))
     ((and (tired-entry-p row) (tired-entry-dirp row))
      (string-remove-suffix "/" cell))
     (t cell))))

(defun tired--name-region ()
  "Return the buffer region that shows the name of the row on this line.
The name column starts at the line start, and its cell holds two
spaces per depth level, so the printed cell minus the name text
gives the indent.  The region stops before the slash that closes a
directory name and before the arrow that targets a symbolic link.
Return nil when the line holds no row."
  (let ((row (tired--row-at-point))
        (columns (tabulated-list-get-entry)))
    (when (and row columns)
      (let* ((cell (aref columns 0))
             (indent (- (length cell)
                        (length (tired--row-name-cell row))))
             (start (+ (line-beginning-position) indent))
             (end (min (+ start (length (tired--name-text row)))
                       (line-end-position))))
        (when (and (<= (line-beginning-position) start)
                   (<= start end))
          (cons start end))))))

(defun tired--name-bounds ()
  "Return the buffer region that shows the name of the row at point.
Return nil when the line holds no row, or when point leaves the
name for the size, date or mode column.  The region stops before
the arrow that shows a symbolic link target."
  (let ((region (tired--name-region)))
    (when (and region
               (<= (car region) (point))
               (<= (point) (cdr region)))
      region)))

(defun tired--filename-at-point ()
  "Return the absolute name of the row at point, or nil.
The provider reads the name column alone, so point on the size,
date or mode column yields no name here.  `thing-at-point' then
falls back to its own guess.  A section row names its file."
  (when (tired--name-bounds)
    (tired--row-path (tired--row-at-point))))

(defun tired--selected-p (entry)
  "Return non-nil when ENTRY is part of the transient selection."
  (and (tired-entry-p entry)
       (hash-table-p tired--selection-set)
       (gethash (tired-entry-path entry) tired--selection-set)))

(defun tired--selected-entries ()
  "Return the selected entries in display order."
  (delq nil
        (mapcar (lambda (row)
                  (let ((entry (car row)))
                    (and (tired--selected-p entry) entry)))
                (tired--display-rows nil))))

(defun tired--entry-size (entry)
  "Return the byte count that ENTRY adds to a total.
A directory adds its whole subtree, the way a selection should name
the bytes that it holds.  The sum reads no `tired-directory-size',
because that option governs the size column alone.  A directory on a
remote host adds nothing, because a walk over the network costs one
round trip per file, and a directory that
`tired-directory-size-exclude' names adds nothing, because no walk
reads it."
  (cond
   ((not (tired-entry-dirp entry)) (or (tired-entry-size entry) 0))
   ((tired--size-skip-p (tired-entry-path entry) entry) 0)
   (t (or (tired--directory-total (tired-entry-path entry)) 0))))

(defun tired--entries-size (entries)
  "Return the total size of ENTRIES in bytes.
A directory counts its whole subtree, and a remote directory counts
nothing."
  (let ((total 0))
    (dolist (entry entries total)
      (setq total (+ total (tired--entry-size entry))))))

(defun tired--selection-size ()
  "Return the total size of the selected entries in bytes."
  (tired--entries-size (tired--selected-entries)))

(defun tired--selection-targets ()
  "Return the entries a command acts on.
The transient selection comes first, then the active region, then
the row at point.  A section row stands for the file that holds it.
This function changes nothing, so a menu `:active' form can call it.
`tired--targets' reads the same rows for a command."
  (or (tired--selected-entries)
      (tired--region-entries)
      (let ((row (tired--row-at-point)))
        (cond
         ((tired-entry-p row) (list row))
         ((tired-section-p row)
          (let ((entry (tired--entry-for-path
                        (tired-section-path row))))
            (when entry (list entry))))))))

(defun tired--targets ()
  "Return the entries a command acts on, and commit an active region.
The region joins the transient selection first, so every command
reads one source and the region needs no branch of its own.  A
non-empty selection wins over the region, and a region that holds
no entry changes nothing."
  (tired--commit-region)
  (tired--selection-targets))

(defun tired--commit-region ()
  "Turn the active region into the transient selection.
Keep a non-empty selection, because it wins over the region.  Change
nothing when the region holds no entry."
  (when (and (use-region-p) (null tired--selection))
    (let ((entries (tired--region-entries)))
      (when entries
        (tired--set-selection (mapcar #'tired-entry-path entries))
        (tired--apply-selection-overlays)
        (tired--update-mode-line)))))

(defun tired--display-entry-table ()
  "Return a hash table that maps each listed entry path to its entry.
A collapsed row shows the leaf of a chain, so the table of its
parent directory holds no such name."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (row (tired--display-rows t) table)
      (let ((entry (car row)))
        (when (tired-entry-p entry)
          (puthash (tired-entry-path entry) entry table))))))

(defun tired--region-entries ()
  "Return the entries inside the active region, or nil.
Both ends join, so the row that point shows joins even when the
region ends at its line start, and a line motion grows the region
one row per step.  Read the ends from point and mark, because a
linewise evil range ends with the newline of the row at point, and
that newline does not name another row.  A section row stands for
the file that holds it, and one file joins once, so a region over
the headings of a file reaches that file alone."
  (when (use-region-p)
    (let* ((far (max (point) (or (mark t) (point))))
           (last (save-excursion (goto-char far) (line-beginning-position)))
           (table nil)
           (seen (make-hash-table :test #'equal))
           entries)
      (save-excursion
        (goto-char (region-beginning))
        (beginning-of-line)
        (while (and (not (eobp))
                    (<= (line-beginning-position) last))
          (let* ((row (tired--row-at-point))
                 (entry
                  (cond
                   ((tired-entry-p row) row)
                   ((tired-section-p row)
                    (setq table (or table (tired--display-entry-table)))
                    (let ((path (tired-section-path row)))
                      (or (gethash path table)
                          (tired--entry-for-path path)))))))
            (when (and entry
                       (not (gethash (tired-entry-path entry) seen)))
              (puthash (tired-entry-path entry) t seen)
              (push entry entries)))
          (forward-line 1)))
      (nreverse entries))))

(defun tired--entry-for-path (path)
  "Return the listed entry for PATH, or nil."
  (let* ((directory (file-name-directory path))
         (table (tired--table directory))
         (entry (and table (gethash (file-name-nondirectory path) table))))
    (and entry (equal (tired-entry-path entry) path) entry)))

(defun tired--set-selection (paths)
  "Set the transient selection to PATHS and rebuild its lookup table."
  (setq tired--selection (copy-sequence paths))
  (setq tired--selection-set (make-hash-table :test #'equal))
  (dolist (path paths)
    (puthash path t tired--selection-set)))

(defun tired--set-narrowed (paths)
  "Set the narrowed path snapshot to PATHS and rebuild its lookup table."
  (setq tired--narrowed (copy-sequence paths))
  (setq tired--narrowed-set (make-hash-table :test #'equal))
  (dolist (path paths)
    (puthash path t tired--narrowed-set)))

(defun tired--prune-selection (selection)
  "Return SELECTION without paths that are no longer listed."
  (seq-filter #'tired--entry-for-path selection))

(defun tired--apply-selection-overlays ()
  "Highlight every entry in the transient selection."
  (remove-overlays (point-min) (point-max) 'tired-selection t)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (tired--selected-p (tired--row-at-point))
        (let ((overlay (make-overlay (line-beginning-position)
                                     (min (point-max) (1+ (line-end-position))))))
          (overlay-put overlay 'face 'tired-selected-face)
          (overlay-put overlay 'tired-selection t)
          (overlay-put overlay 'evaporate t)))
      (forward-line 1))))

(defun tired--goto-path (path)
  "Move point to the line showing PATH.
Return non-nil when the listing contains PATH.  Leave point at the
first line when PATH is absent."
  (when path
    (let ((path (directory-file-name (expand-file-name path)))
          (found nil))
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (let ((row (tired--row-at-point)))
          (if (and (tired-entry-p row)
                   (equal (tired-entry-path row) path))
              (setq found t)
            (forward-line 1))))
      (unless found
        (goto-char (point-min)))
      found)))

(defun tired--goto-row (row)
  "Move point to the line that shows ROW.
Return non-nil when the listing still shows ROW.  A section matches
on its path and its line, so two sections of one file stay apart.
Leave point at the first line when the row is absent."
  (when row
    (let ((key (tired--row-key row))
          (found nil))
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (if (equal (tired--row-key (tired--row-at-point)) key)
            (setq found t)
          (forward-line 1)))
      (unless found
        (goto-char (point-min)))
      found)))

(defun tired--goto-entry (row)
  "Move point to the line showing ROW, when it is still listed."
  (when (or (tired-entry-p row) (tired-section-p row))
    (tired--goto-row row)))

(defun tired--restore-mark (row)
  "Put the mark back on the line of ROW, when the listing shows it.
Keep the region active, or inactive, as it was before the redraw."
  (when (and row
             (marker-position (mark-marker)))
    (save-excursion
      (when (tired--goto-row row)
        (set-marker (mark-marker) (point) (current-buffer))))))

(defun tired--chain-paths ()
  "Return the skipped directories of every cached collapse.
A new sibling in one of them breaks the chain, so each needs its own
watch.  A directory that does not collapse skips nothing and adds
nothing.  A directory that the listing shows keeps its own watch
when the user inserts it, so the duplicates cost nothing."
  (let (paths)
    (when (hash-table-p tired--collapse-cache)
      (maphash (lambda (_directory result)
                 (when (tired--chain-leaf result)
                   ;; Copy the visited list: `nconc' would splice the
                   ;; paths onto the list that the chain struct holds.
                   (setq paths (append (tired--chain-visited result) paths))))
               tired--collapse-cache))
    paths))

(defun tired--watch-paths ()
  "Return the paths that need a file notification watch.
The root directory is always watched.  Inserted directories join the
list, and so does every directory that a collapsed chain skips,
because a new sibling there breaks the collapse.  Every expanded
file joins as well, because a directory watch does not report an
edit to a file inside that directory."
  (append (list (directory-file-name (expand-file-name tired--directory)))
          (and (hash-table-p tired--inserted)
               (hash-table-keys tired--inserted))
          (and (hash-table-p tired--expanded)
               (hash-table-keys tired--expanded))
          (tired--chain-paths)))

(defun tired--stop-watching ()
  "Cancel the debounce timer and remove every file notification watch."
  (when (timerp tired--revert-timer)
    (cancel-timer tired--revert-timer)
    (setq tired--revert-timer nil))
  (when (timerp tired--size-timer)
    (cancel-timer tired--size-timer)
    (setq tired--size-timer nil))
  (when (hash-table-p tired--watches)
    (maphash (lambda (_directory descriptor)
               (ignore-errors (file-notify-rm-watch descriptor)))
             tired--watches))
  (setq tired--watches nil))

(defun tired--auto-revert-enabled-p ()
  "Return non-nil when the current buffer may watch its paths.
A remote directory needs `tired-auto-revert-remote' as well as
`tired-auto-revert', because every watch there costs a network
round trip and some TRAMP methods refuse one."
  (and tired-auto-revert
       (or tired-auto-revert-remote
           (not (file-remote-p (or tired--directory
                                   default-directory))))))

(defun tired--sync-watches ()
  "Add missing watches and remove watches for vanished paths.
A path that matches `tired-persistent-directories' takes no watch,
because no change arrives under it, so a new child reaches the
listing through `tired-refresh' alone.
One hash set of wanted paths and one hash table of live watches turn
a listing that collapses thousands of chains into a linear pass."
  (if (not (tired--auto-revert-enabled-p))
      (tired--stop-watching)
    (let* ((wanted (make-hash-table :test #'equal))
           (buffer (current-buffer))
           (watches tired--watches)
           stale)
      (dolist (directory (tired--watch-paths))
        (unless (tired--persistent-p directory)
          (puthash directory t wanted)))
      (when (hash-table-p watches)
        (maphash (lambda (directory _descriptor)
                   (unless (gethash directory wanted)
                     (push directory stale)))
                 watches)
        (dolist (directory stale)
          (ignore-errors
            (file-notify-rm-watch (gethash directory watches)))
          (remhash directory watches)))
      (maphash (lambda (directory _ignore)
                 (unless (and (hash-table-p watches)
                              (gethash directory watches))
                   (let* ((callback
                           (lambda (_event)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (tired--schedule-revert)))))
                          (descriptor
                           (ignore-errors
                             (file-notify-add-watch directory '(change)
                                                    callback))))
                     (when descriptor
                       (unless (hash-table-p watches)
                         (setq watches (make-hash-table :test #'equal)))
                       (puthash directory descriptor watches)))))
               wanted)
      ;; A listing without a watch keeps no table, so `tired--watches'
      ;; stays nil and a test reads ``no watch''.
      (setq tired--watches watches))))

(defun tired--schedule-revert ()
  "Schedule a refresh after `tired-auto-revert-delay' seconds."
  (unless (timerp tired--revert-timer)
    (setq tired--revert-timer
          (run-at-time tired-auto-revert-delay nil
                       #'tired--auto-revert-now (current-buffer)))))

(defun tired--auto-revert-now (buffer)
  "Refresh BUFFER after a file change.
Skip the refresh while a minibuffer is active, so an open completion
or filter prompt keeps its input."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq tired--revert-timer nil)
      (when (and (tired--auto-revert-enabled-p)
                 (not (active-minibuffer-window)))
        (tired-refresh)))))

(defun tired--file-changed (event)
  "Handle file notification EVENT by scheduling a refresh.
Ignore Emacs lock files and events without a file name.  One
directory notification can describe several entries, so the whole
listing refreshes once."
  (let ((file (nth 2 event)))
    (unless (and file (string-prefix-p ".#" (file-name-nondirectory file)))
      (tired--schedule-revert))))

(defun tired-toggle-auto-revert ()
  "Toggle automatic refresh of the current buffer."
  (interactive)
  (setq-local tired-auto-revert (not tired-auto-revert))
  (tired--sync-watches)
  (tired--update-mode-line)
  (message "Auto-revert %s" (if (tired--auto-revert-enabled-p) "on" "off")))

(defun tired--point-row (window)
  "Return the row at the point of WINDOW.
The window point wins when WINDOW is not the selected window, because
the buffer point of a window that lost the selection lags behind."
  (if (and (window-live-p window)
           (not (eq window (selected-window)))
           (eq (window-buffer window) (current-buffer)))
      (tired--row-at (window-point window))
    (tired--row-at-point)))

(defun tired--row-position (row)
  "Return the buffer position of the line that shows ROW.
Return nil when the listing no longer shows ROW."
  (save-excursion
    (when (tired--goto-row row)
      (point))))

(defun tired--window-views ()
  "Return one view per window that shows the listing.
A view is a list of the window, the row at its point and the row at
its display start.  Either row is nil when its line holds no row."
  (let (views)
    (dolist (window (get-buffer-window-list nil t))
      (push (list window
                  (tired--row-at (window-point window))
                  (tired--row-at (window-start window)))
            views))
    (nreverse views)))

(defun tired--restore-window-views (views)
  "Put every window in VIEWS back to the view it showed before a reprint.
`tabulated-list-print' erases the buffer, and the erase collapses both
the point marker and the display start marker of each window that
shows the listing.  Point would then sit at the bottom of a window
that starts at the first line.  Set the window point first, then the
window start, so point keeps its place inside the window.  A window
whose point vanished keeps its own point."
  (dolist (view views)
    (let ((window (car view))
          (point-row (nth 1 view))
          (start-row (nth 2 view)))
      (when (and (window-live-p window)
                 (eq (window-buffer window) (current-buffer)))
        (let ((point-position (and point-row (tired--row-position point-row)))
              (start-position (and start-row (tired--row-position start-row))))
          (when point-position
            (set-window-point window point-position)
            (when (and start-position (< start-position point-position))
              (set-window-start window start-position))))))))

(defun tired--redraw (&optional window)
  "Redraw the listing, unless an edit owns the buffer text.
WINDOW is the window that shows the buffer.  `tired-edit-names'
leaves `tired--name-edit' set while the name cells accept changes,
and a reprint then erases what the user typed, so the redraw draws
nothing."
  (unless tired--name-edit
    (tired--redraw-buffer window)))

(defun tired--redraw-buffer (&optional window)
  "Redraw the listing from the cached entries.
WINDOW is the window that shows the buffer, or nil for the pin in
`tired--width-window'.  Its width limits the name column.  The
redraw keeps the point and the scroll position of every window that
shows the listing, and it keeps the name column of point: a caller
that leaves point at the first character of a name finds it there
again, so no redraw moves the cursor into the indent of a row.
The redraw reads the directory size memo table alone, so it blocks
on no subtree.  `tired--size-queue' then queues the visible
directory rows and the idle queue fills the size cells."
  (setq tired--size-deferred nil)
  (let* ((window (tired--pin-width-window window))
         (_ (setq tired--name-column-window-width
                  (window-width window)))
         (point-entry (tired--point-row window))
         (point-line (line-number-at-pos))
         (at-name (tired--at-name-p))
         (mark-entry (tired--row-at (mark t)))
         (views (tired--window-views)))
    (setq tired--hidden-total (tired--count-hidden))
    (setq tired--rows (tired--display-rows t))
    (let ((tired--name-cells (make-hash-table :test #'eq)))
      (unwind-protect
        (progn
          (setq tabulated-list-format
                (tired--format (tired--name-column-width window)))
          (tabulated-list-init-header)
          (setq tired--header-base header-line-format)
          (setq header-line-format
                (let ((title (tired--header-title)))
                  (if (string-empty-p title)
                      tired--header-base
                    (list (propertize (tired--escape-mode-line title)
                                      'face 'bold)
                          "  "
                          tired--header-base))))
          (tabulated-list-print t)
          (setq tired--subtree-starts
                (tired--subtree-start-positions tired--rows))
          (tired--paint-row-help)
          (when tired--elements-queue-function
            (funcall tired--elements-queue-function))
          (tired--size-queue))
        (setq tired--rows nil)))
    (unless (tired--goto-entry point-entry)
      ;; The printed row is gone, and the print left point on the first
      ;; line.  Hold the line instead, so a removal of the last row
      ;; stops on the row that remains above it.
      (when point-entry
        (tired--goto-line point-line)))
    (tired--restore-window-views views)
    ;; The view restore sets the window point to the line start of its
    ;; row, and the selected window shares its point with the buffer.
    (when at-name
      (tired--beginning-of-name))
    (tired--restore-mark mark-entry)
    (tired--apply-selection-overlays)
    (tired--sync-watches)
    (tired--update-mode-line)
    (run-hooks 'tired-after-redraw-hook)))

(defun tired--width-changed-p (window)
  "Return non-nil when WINDOW shows a listing that needs another width.
Compare the width of the window that decides the column with the
width that the last print used, so the answer costs one call.  The
size hook fires once per changed window of a frame, and it also
fires when the echo area grows, which leaves the width alone.  A
window that does not show the listing decides nothing, so it never
needs a repaint."
  (/= (window-width (tired--width-window window))
      (or tired--name-column-window-width 0)))

(defun tired--window-size-changed (frame)
  "Redraw Tired listings in the windows of FRAME.
A resize changes the space available to the name column.  Only a
window that decides the width repaints: a frame that holds the
listing in a window of another size keeps the column that the
pinned window asked for."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'tired-mode)
                 tired--directory
                 (tired--width-changed-p window))
        (tired--redraw window)))))

(add-hook 'window-size-change-functions #'tired--window-size-changed)

(defun tired--forget-inserted (directory)
  "Remove DIRECTORY and its inserted descendants from the listing.
Drop the chain results below them as well, so a stale chain adds no
watch."
  (let* ((base (directory-file-name (expand-file-name directory)))
         (prefix (file-name-as-directory base))
         doomed)
    (maphash (lambda (other _ignore)
               (let ((other (directory-file-name other)))
                 (when (or (equal other base)
                           (string-prefix-p prefix other))
                   (push other doomed))))
             tired--inserted)
    (dolist (other doomed)
      (remhash other tired--inserted)
      (remhash other tired--tables))
    (tired--forget-chains base)))

(defun tired--forget-chains (directory)
  "Drop the chain results under DIRECTORY from the collapse cache."
  (when (hash-table-p tired--collapse-cache)
    (let ((prefix (file-name-as-directory
                   (directory-file-name (expand-file-name directory))))
          stale)
      (maphash (lambda (key _result)
                 (when (string-prefix-p prefix key)
                   (push key stale)))
               tired--collapse-cache)
      (dolist (key stale)
        (remhash key tired--collapse-cache)))))

(defun tired--reload-tables ()
  "Read the root directory and every inserted directory.
Drop inserted directories that no longer exist.  Drop expanded
files that vanished.  Drop the directory size walks that a refresh
or a directory change made stale, and keep `tired--size-cache', so a
refresh inside one `tired-size-cache-ttl' window reads no directory
twice."
  (setq tired--tables (make-hash-table :test #'equal))
  ;; The chain results stay, and the new generation makes the next
  ;; redraw check the stamp of every directory that they walked.  A
  ;; refresh of a static directory then costs one attributes read per
  ;; level instead of a directory read.
  (setq tired--collapse-generation (1+ tired--collapse-generation))
  (tired--queue-drop-where #'tired--size-walk-job-p)
  (tired--size-cache-prune)
  ;; The refresh reads the disk, so a young total can hide a file that
  ;; arrived after its walk.  Keep the total on screen and queue a new
  ;; walk, so no size cell empties and no ignored face outlives the
  ;; refresh that should clear it.
  (setq tired--size-forced (float-time))
  (when tired--elements-prune-function
    (funcall tired--elements-prune-function))
  (puthash (directory-file-name tired--directory)
           (tired--read-entries tired--directory)
           tired--tables)
  (let (gone)
    (maphash (lambda (directory _ignore)
               (if (file-directory-p directory)
                   (puthash directory (tired--read-entries directory)
                            tired--tables)
                 (push directory gone)))
             tired--inserted)
    (dolist (directory gone)
      (tired--forget-inserted directory)))
  (let (gone)
    (maphash (lambda (path _ignore)
               (unless (file-regular-p path)
                 (push path gone)))
             tired--expanded)
    (dolist (path gone)
      (remhash path tired--expanded)
      (when (hash-table-p tired--sections)
        (remhash path tired--sections)))))

(defun tired-refresh ()
  "Reload the listing from disk and redraw the buffer.
With `tired-refresh-keeps-an-unchanged-listing', a listing whose
directories and expanded files keep the stamp of the last read keeps
its printed rows, and the size walks alone run again."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (cond
   ((or (not tired-refresh-keeps-an-unchanged-listing)
        (tired--listing-changed-p))
    (tired--reload-tables)
    (tired--set-selection (tired--prune-selection tired--selection))
    (tired--set-narrowed (tired--prune-selection tired--narrowed))
    (tired--redraw)
    (setq tired--listing-stamps (tired--shown-stamps)))
   (t
    ;; No row changed, so keep the printed rows and let the idle
    ;; reprint show the totals that the walks store.  A changed
    ;; `tired-elements-functions' invalidates a count without a change
    ;; on the disk, and queueing the shown rows again notices that.
    (setq tired--size-forced (float-time))
    (when (and tired--elements-prune-function
               (funcall tired--elements-prune-function))
      ;; A cached count left the table, so queue the rows that show
      ;; one and let the idle reprint fill the cells.
      (when tired--elements-queue-function
        (funcall tired--elements-queue-function)))
    (tired--size-queue)
    (if (tired--width-changed-p (tired--width-window))
        (tired--redraw)
      (tired--update-mode-line)))))

(defun tired--revert (_ignore-auto _noconfirm)
  "Revert the buffer by refreshing the listing.
IGNORE-AUTO and NOCONFIRM are accepted for `revert-buffer-function'."
  (tired-refresh))

(defun tired-up-directory ()
  "Open the parent of the current directory."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (tired (file-name-directory (directory-file-name tired--directory))))

(defun tired--beginning-of-name ()
  "Move point to the first character of the name on the current line.
The name column starts at the line start, and its cell holds two
spaces per depth level, so skipping the spaces reaches the first
character of the name."
  (beginning-of-line)
  (skip-chars-forward " ")
  (point))

(defun tired--at-name-p ()
  "Return non-nil when point sits on the first character of a name."
  (save-excursion
    (eq (point) (tired--beginning-of-name))))

(defun tired--redraw-at-name ()
  "Redraw the listing and put point at the start of the name it shows.
A view command keeps the row at point, so the cursor stays on the
name that `tired-next-line' put it on, instead of moving to the
line start of a deeply indented row.  `tired--redraw-buffer' already
keeps a name column that point holds, so this call serves a caller
that moves point into the name itself."
  (tired--redraw)
  (tired--beginning-of-name))

(defun tired-next-line (&optional arg)
  "Move point ARG lines down and put it at the start of the name.
ARG defaults to one line.  The `^' interactive code keeps
`shift-select-mode' working, as it does in `dired-next-line'."
  (interactive "^p")
  (forward-line (or arg 1))
  (tired--beginning-of-name))

(defun tired-previous-line (&optional arg)
  "Move point ARG lines up and put it at the start of the name.
ARG defaults to one line.  The `^' interactive code keeps
`shift-select-mode' working, as it does in `dired-previous-line'."
  (interactive "^p")
  (forward-line (- (or arg 1)))
  (tired--beginning-of-name))

(defun tired--last-row-position ()
  "Return the position of the last row of the listing, or nil."
  (save-excursion
    (goto-char (point-max))
    (beginning-of-line)
    (while (and (not (bobp)) (null (tired--row-at-point)))
      (forward-line -1))
    (when (tired--row-at-point)
      (point))))

(defun tired--goto-line (line)
  "Move point to the start of line LINE, clamped to the last row.
`tabulated-list-print' moves point to the first line when the row it
showed is gone, so a redraw puts that line back.  A listing that grew
shorter stops on its last row, and an empty listing keeps point on
the first line."
  (goto-char (point-min))
  (forward-line (1- (max 1 line)))
  (when (eobp)
    (when-let* ((last (tired--last-row-position)))
      (goto-char last))))

(defun tired-goto-last-entry (&optional count)
  "Move point to the last row of the listing.
The buffer ends with an empty line, because the printer closes the
last row with a newline, so the plain motion to the last line lands
below every row.  With COUNT above one, move to line COUNT instead,
which keeps the numeric prefix of `evil-goto-line'."
  (interactive "P")
  (if (and (integerp count) (> count 1))
      (progn
        (goto-char (point-min))
        (forward-line (1- count)))
    (let ((position (tired--last-row-position)))
      (unless position
        (user-error "The listing holds no row"))
      (goto-char position))))

(defun tired--apply-to-rows (function)
  "Run FUNCTION on every target entry, then redraw once.
FUNCTION receives one `tired-entry'.  A failure on one entry does
not stop the rest.  When every entry fails, signal the first error,
so a one-row command keeps its message.  An active region becomes
the selection, so a view command acts on a run and keeps it for the
next command.  Point stays at the start of the name that it acted on."
  (let ((entries (tired--targets)))
    (unless entries
      (user-error "No entry at point"))
    (let ((done 0)
          (failures 0)
          (first-error nil))
      (dolist (entry entries)
        (condition-case err
            (progn (funcall function entry) (setq done (1+ done)))
          (error
           (setq failures (1+ failures))
           (unless first-error (setq first-error err)))))
      (deactivate-mark)
      (tired--redraw-at-name)
      (cond
       ((zerop done)
        (signal (car first-error) (cdr first-error)))
       ((> failures 0)
        (message "%d of %d rows skipped" failures (+ done failures))))
      done)))

(defun tired--insert-directory (entry)
  "Insert the children of the directory ENTRY into the listing.
Read the children and leave the redraw to the caller."
  (let ((directory (tired-entry-path entry)))
    (unless (file-directory-p directory)
      (user-error "Not a directory: %s" directory))
    (setq directory (directory-file-name (expand-file-name directory)))
    (puthash directory t tired--inserted)
    (puthash directory (tired--read-entries directory) tired--tables)))

(defun tired--expand-path (path)
  "Record PATH as expanded, so its sections show.
Signal a user error when no handler claims PATH, or when the handler
found no section."
  (unless (tired-file-handler path)
    (user-error "No section handler for %s"
                (file-name-nondirectory path)))
  (unless (tired-file-sections path)
    (user-error "No sections in %s" (file-name-nondirectory path)))
  (tired--set-expanded path t))

(defun tired--collapse-path (path)
  "Record PATH as collapsed, so its sections hide.
Signal a user error when PATH is not expanded."
  (unless (tired--expanded-p path)
    (user-error "%s is not expanded" (file-name-nondirectory path)))
  (tired--set-expanded path nil))

(defun tired-insert-subdir (&optional directory)
  "Insert the children of every target directory into the listing.
DIRECTORY names one directory and skips the target read.  Inserted
children follow their parent row and indent by one level.  Inserting
an already inserted directory changes nothing."
  (interactive)
  (if directory
      (progn
        (unless (file-directory-p directory)
          (user-error "Not a directory: %s" directory))
        (setq directory (directory-file-name (expand-file-name directory)))
        (puthash directory t tired--inserted)
        (puthash directory (tired--read-entries directory) tired--tables)
        (tired--redraw-at-name))
    (tired--apply-to-rows #'tired--insert-directory)))

(defun tired-remove-subdir ()
  "Remove the inserted children of every target directory."
  (interactive)
  (tired--apply-to-rows
   (lambda (entry)
     (unless (and (tired--directory-entry-p entry)
                  (tired--inserted-p (tired-entry-path entry)))
       (user-error "No inserted directory: %s" (tired-entry-path entry)))
     (tired--forget-inserted (tired-entry-path entry)))))

(defun tired-expand-file (&optional path)
  "Show the sections of every target file under its row.
PATH names one file and skips the target read.  Signal a user error
when no handler claims a file, or when the handler found no section."
  (interactive)
  (if path
      (progn
        (tired--expand-path path)
        (tired--redraw-at-name)
        (message "Expanded %s" (file-name-nondirectory path)))
    (tired--apply-to-rows
     (lambda (entry)
       (let ((path (tired-entry-path entry)))
         (tired--expand-path path)
         (message "Expanded %s" (file-name-nondirectory path)))))))

(defun tired-collapse-file (&optional path)
  "Hide the sections of every target file.
PATH names one file and skips the target read.  Signal a user error
when a file is not expanded."
  (interactive)
  (if path
      (progn
        (tired--collapse-path path)
        (tired--redraw-at-name))
    (tired--apply-to-rows
     (lambda (entry) (tired--collapse-path (tired-entry-path entry))))))

(defun tired--toggle-fold (section)
  "Toggle the fold state of SECTION."
  (if (tired--section-folded-p section)
      (tired--set-folded section nil)
    (tired--set-folded section t))
  (tired--redraw-at-name))

(defun tired--toggle-tree (entry)
  "Toggle the subtree of ENTRY, one row.
A directory row inserts or removes its children.  A file row with a
section handler expands or collapses its sections.  Leave the redraw
to the caller."
  (let ((path (tired-entry-path entry)))
    (cond
     ((tired--directory-entry-p entry)
      (let ((directory (directory-file-name (expand-file-name path))))
        (if (tired--inserted-p directory)
            (tired--forget-inserted directory)
          (tired--insert-directory entry))))
     ((tired-file-handler path)
      (if (tired--expanded-p path)
          (tired--collapse-path path)
        (tired--expand-path path)))
     (t (user-error "No subtree at point")))))

(defun tired-toggle-subdir ()
  "Insert, expand or fold the target rows.
A directory row inserts or removes its children.  A file row with a
section handler expands or collapses its sections.  A section row at
point folds or unfolds its own children, because a fold belongs to
one section alone."
  (interactive)
  (let ((row (tired--row-at-point)))
    (if (and (tired-section-p row)
             (null tired--selection)
             (not (use-region-p)))
        (tired--toggle-fold row)
      (tired--apply-to-rows #'tired--toggle-tree))))

(defun tired-bookmark-make-record ()
  "Return a bookmark record for the current Tired buffer."
  (list (abbreviate-file-name tired--directory)
        (cons 'handler #'tired-bookmark-jump)
        (cons 'directory tired--directory)))

(defun tired-bookmark-jump (bookmark)
  "Jump to the Tired buffer described by BOOKMARK."
  (tired (bookmark-prop-get bookmark 'directory)))

(defun tired--toggle-selection (paths)
  "Toggle the membership of every path in PATHS in the selection.
An unselected path joins the selection and a selected path leaves
it.  Update the overlays and the mode line afterwards."
  (let ((toggled (make-hash-table :test #'equal))
        selection)
    (dolist (path paths)
      (puthash path t toggled))
    (dolist (path tired--selection)
      (unless (gethash path toggled)
        (push path selection)))
    (maphash (lambda (path _ignore)
               (unless (and (hash-table-p tired--selection-set)
                            (gethash path tired--selection-set))
                 (push path selection)))
             toggled)
    (tired--set-selection selection))
  (tired--apply-selection-overlays)
  (tired--update-mode-line))

(defun tired-select-toggle ()
  "Toggle the entry at point in the selection.
Signal a user error on a section row, because a section stands for
its file and a file row already covers that file."
  (interactive)
  (let ((entry (tired--row-at-point)))
    (cond
     ((tired-section-p entry)
      (user-error "A section row is not selectable"))
     ((not (tired-entry-p entry))
      (user-error "No entry at point")))
    (tired--toggle-selection (list (tired-entry-path entry)))))

(defun tired-select-toggle-next ()
  "Toggle the selection at point, then move to the next line."
  (interactive)
  (tired-select-toggle)
  (forward-line 1))

(defun tired-select-all ()
  "Toggle the selection of every visible entry.
An unselected entry joins the selection and a selected entry leaves
it.  A selected entry that the listing hides stays selected."
  (interactive)
  (tired--toggle-selection
   (mapcar #'tired-entry-path (tired--visible-entries))))

(defun tired-select-extension ()
  "Add every visible file that shares the extension of point.
An extensionless name and a dotfile name share one empty key, so a
name that holds no dot still finds its own group.  A directory
stays out.  A section row stands for the file that holds it.  The
command adds to the selection, so a second extension joins the
first.  Point stays on the row that started the command."
  (interactive)
  (let* ((row (tired--row-at-point))
         (path (cond ((tired-entry-p row) (tired-entry-path row))
                     ((tired-section-p row) (tired-section-path row))
                     (t (user-error "No entry at point"))))
         (extension (or (file-name-extension path) ""))
         (paths (copy-sequence tired--selection))
         (seen (make-hash-table :test #'equal)))
    (dolist (selected paths)
      (puthash selected t seen))
    (dolist (entry (tired--visible-entries))
      (let ((candidate (tired-entry-path entry)))
        (when (and (not (tired--directory-entry-p entry))
                   (equal (or (file-name-extension candidate) "")
                          extension)
                   (not (gethash candidate seen)))
          (puthash candidate t seen)
          (push candidate paths))))
    (save-excursion
      (tired--set-selection paths)
      (tired--apply-selection-overlays)
      (tired--update-mode-line))))

(defun tired-select-none ()
  "Clear the transient selection and the active region.
Both sources feed one target list, so a clear drops both."
  (interactive)
  (tired--set-selection nil)
  (tired--apply-selection-overlays)
  (deactivate-mark)
  (tired--update-mode-line))

(defun tired-select-invert ()
  "Invert the selection over the visible entries.
Selected entries outside the visible listing drop out."
  (interactive)
  (tired--set-selection
   (mapcar #'tired-entry-path
           (seq-remove #'tired--selected-p (tired--visible-entries))))
  (tired--apply-selection-overlays)
  (tired--update-mode-line))

(defun tired--narrow-ancestors (paths)
  "Return PATHS plus the directories needed to reach them."
  (let ((root (directory-file-name (expand-file-name tired--directory)))
        (result (copy-sequence paths)))
    (dolist (path paths)
      (let ((directory (file-name-directory path)))
        (while (and directory
                    (> (length directory) (length root))
                    (string-prefix-p root directory))
          (push (directory-file-name directory) result)
          (setq directory
                (file-name-directory (directory-file-name directory))))))
    (delete-dups result)))

(defun tired-narrow-to-selection ()
  "Show only the selected entries and the directories that contain them.
An active region joins the selection first."
  (interactive)
  (tired--commit-region)
  (unless tired--selection
    (user-error "No selection"))
  (tired--set-narrowed (tired--narrow-ancestors tired--selection))
  (tired--redraw))

(defun tired-widen ()
  "Show the whole listing again."
  (interactive)
  (tired--set-narrowed nil)
  (tired--redraw))

(defun tired-toggle-narrow ()
  "Narrow the listing to the selection, or widen it."
  (interactive)
  (if tired--narrowed
      (tired-widen)
    (tired-narrow-to-selection)))

(defun tired--sort-state-parts (state)
  "Return the `(KEY . FLIP)' pair that sort STATE stands for."
  (declare (pure t) (side-effect-free t))
  (pcase state
    ('name-asc (cons 'name nil))
    ('name-desc (cons 'name t))
    ('size-asc (cons 'size nil))
    ('size-desc (cons 'size t))
    ('modified-asc (cons 'modified nil))
    ('modified-desc (cons 'modified t))
    ('elements-asc (cons 'elements nil))
    ('elements-desc (cons 'elements t))
    ('mode-asc (cons 'mode nil))
    ('mode-desc (cons 'mode t))
    (_ (error "Unknown sort state: %S" state))))

(defun tired--sort-state ()
  "Return the sort state of the listing, or nil.
The value stays nil when `tired-sort-states' leaves out the
current column or the current direction."
  (let ((parts (cons tired--sort-key (and tired--sort-flip t))))
    (seq-find (lambda (state)
                (equal (tired--sort-state-parts state) parts))
              tired-sort-states)))

(defun tired--sort-step (step)
  "Move STEP places along `tired-sort-states' and apply that state.
A negative STEP moves back, and the walk wraps around.  A current
state that the list leaves out gives way to the first state when
STEP is positive and to the last state when it is negative."
  (let ((states tired-sort-states))
    (unless states
      (user-error "No sort state to cycle"))
    (let* ((current (tired--sort-state))
           (start (cond (current (seq-position states current))
                        ((< step 0) 0)
                        (t -1)))
           (state (nth (mod (+ start step) (length states)) states))
           (parts (tired--sort-state-parts state)))
      (setq tired--sort-key (car parts)
            tired--sort-flip (cdr parts))
      (tired--redraw))))

(defun tired--sort-select (index)
  "Apply the sort state at INDEX in `tired-sort-states'.
INDEX counts from one, and a value outside the list signals a
user error."
  (let ((states tired-sort-states))
    (unless states
      (user-error "No sort state to cycle"))
    (unless (and (integerp index) (< 0 index) (<= index (length states)))
      (user-error "Sort state %s is outside `tired-sort-states'" index))
    (let ((parts (tired--sort-state-parts (nth (1- index) states))))
      (setq tired--sort-key (car parts)
            tired--sort-flip (cdr parts))
      (tired--redraw))))

(defun tired--sort-by-column (column &optional reverse)
  "Sort the listing by COLUMN.
COLUMN is one of `name', `size', `modified', `elements' or `mode'.
Selecting the current column again flips the direction.  With
REVERSE, start with the opposite direction."
  (if (eq column tired--sort-key)
      (setq tired--sort-flip (not tired--sort-flip))
    (setq tired--sort-key column
          tired--sort-flip (and reverse t)))
  (tired--redraw))

(defun tired-sort (&optional argument)
  "Cycle the listing through the sort states of `tired-sort-states'.
With no ARGUMENT, select the state that follows the current one,
so the command cycles forward.  A positive ARGUMENT selects that
position in the list, where one names the first state.  A negative
ARGUMENT moves back that many states.  The walk wraps around at
both ends of the list, a column that the list leaves out gives way
to the first state forward and to the last state back, and a
position outside the list signals a user error."
  (interactive "P")
  (let ((step (and argument (prefix-numeric-value argument))))
    (cond ((null step) (tired--sort-step 1))
          ((< step 0) (tired--sort-step step))
          (t (tired--sort-select step)))))

(defun tired--filter-cancel-timer ()
  "Cancel a pending filter redraw, if one waits."
  (when (timerp tired--filter-timer)
    (cancel-timer tired--filter-timer)
    (setq tired--filter-timer nil)))

(defun tired--filter-flush (filter)
  "Cancel a pending filter redraw and apply FILTER at once.
The exit and the quit path call this, because the user expects the
final text to reach the listing without the delay."
  (tired--filter-cancel-timer)
  (tired--apply-filter filter))

(defun tired--apply-filter (filter)
  "Set `tired--filter' to FILTER and redraw the listing.
An empty FILTER removes the current filter.  A pending delayed
redraw goes away, because this call supersedes it."
  (tired--filter-cancel-timer)
  (setq tired--filter (unless (or (null filter) (string-empty-p filter)) filter))
  (tired--redraw))

(defun tired--filter-changed (origin)
  "Apply the current minibuffer text as the filter of ORIGIN.
Delay the redraw by `tired-filter-delay', so a typed word costs one
redraw.  A zero delay applies the text at once.  Read the minibuffer
before the switch, because `minibuffer-contents' returns the text of
the current buffer when that buffer is not a minibuffer."
  (let ((text (minibuffer-contents)))
    (with-current-buffer origin
      (tired--filter-cancel-timer)
      (if (or (null tired-filter-delay) (<= tired-filter-delay 0))
          (tired--apply-filter text)
        (setq tired--filter-timer
              (run-with-idle-timer
               tired-filter-delay nil
               (lambda (buffer filter)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq tired--filter-timer nil)
                     (tired--apply-filter filter))))
               origin text))))))

(defun tired--filter-quit-on-command ()
  "Clear the name filter when the next command counts as a quit.
`tired-mode' runs this from `pre-command-hook'.  The hook reads
`this-command' and never the pressed key, so `keyboard-quit' from its
own key, from `M-x' and from a user binding reaches this function
alike, and `tired-filter-quit-commands' adds the evil quit command.
A listing without a filter pays one variable read per command and no
redraw.

The clear keeps its own guard: a signal inside a command hook
removes that function from the buffer, and the command that follows
still quits.  A `quit' arriving during the redraw would remove it the
same way, so the guard catches both."
  (when (and tired--filter (memq this-command tired-filter-quit-commands))
    (condition-case nil
        (tired--apply-filter nil)
      (quit nil)
      (error nil))))

(defun tired-filter ()
  "Narrow the listing while typing a filter.
A change updates the listing after `tired-filter-delay'.
\[exit-minibuffer] keeps the filter and applies the typed text at
once, \[keyboard-quit] restores the previous one.  An empty filter
removes it.  A later quit command clears the kept filter, because
`tired--filter-quit-on-command' reads `this-command' in
`pre-command-hook' and `tired-filter-quit-commands' names those
commands."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (let ((origin (current-buffer))
        (original tired--filter)
        (start (tired--row-at-point)))
    (condition-case nil
        (let ((result
               (minibuffer-with-setup-hook
                   (lambda ()
                     (add-hook 'after-change-functions
                               (lambda (&rest _)
                                 (tired--filter-changed origin))
                               nil t))
                 (read-string "Filter: " original))))
          (with-current-buffer origin
            (tired--filter-flush result)))
      (quit
       (with-current-buffer origin
         (tired--filter-flush original)
         (tired--goto-entry start))))))

(defun tired-clear-filter ()
  "Remove the name filter."
  (interactive)
  (tired--apply-filter nil))

(defun tired-toggle-dotfiles ()
  "Toggle the display of entries whose name starts with a dot."
  (interactive)
  (setq tired--hide-dotfiles (not tired--hide-dotfiles))
  ;; A dotfile link ends a chain, so the cached chains follow the toggle.
  (setq tired--collapse-cache (make-hash-table :test #'equal))
  (tired--redraw))

(defun tired-toggle-hidden ()
  "Toggle the display of entries that `tired-hidden-regexps' hides."
  (interactive)
  (setq tired--show-hidden (not tired--show-hidden))
  ;; A hidden link ends a chain, so the cached chains follow the toggle.
  (setq tired--collapse-cache (make-hash-table :test #'equal))
  (tired--redraw))

(defun tired-toggle-collapse ()
  "Toggle collapsing of single-entry directory chains in this buffer."
  (interactive)
  (setq-local tired-collapse-single-child
              (not tired-collapse-single-child))
  (setq tired--collapse-cache (make-hash-table :test #'equal))
  (tired--redraw)
  (message "Single-child collapse %s"
           (if tired-collapse-single-child "on" "off")))

(defun tired--copy-name-value (entry)
  "Return the name of ENTRY that `tired-copy-name' copies.
A full path takes the abbreviation of `abbreviate-file-name', so a
path under the home directory starts with a tilde."
  (if tired--copy-name-absolute
      (abbreviate-file-name (tired-entry-path entry))
    (tired-entry-name entry)))

(defun tired-copy-name ()
  "Copy the names of the targets to the kill ring.
One call copies the name of each target, and the next call copies
the full path with the home directory abbreviated.  A third call
copies the name again."
  (interactive)
  (let ((targets (tired--targets)))
    (unless targets
      (user-error "No entry at point"))
    (kill-new (mapconcat #'tired--copy-name-value targets "\n"))
    (deactivate-mark)
    (message "Copied %d %s%s"
             (length targets)
             (if tired--copy-name-absolute "path" "name")
             (if (= (length targets) 1) "" "s"))
    (setq tired--copy-name-absolute (not tired--copy-name-absolute))))

(defun tired--copy-targets (function description)
  "Copy FUNCTION of each target path to the kill ring.
DESCRIPTION names the copied form in the echo area."
  (let ((targets (tired--targets)))
    (unless targets
      (user-error "No entry at point"))
    (kill-new
     (mapconcat (lambda (entry)
                  (funcall function (tired-entry-path entry)))
                targets
                "\n"))
    (deactivate-mark)
    (message "Copied %d %s%s"
             (length targets)
             description
             (if (= (length targets) 1) "" "s"))))

(defun tired-copy-path ()
  "Copy the full paths of the targets to the kill ring."
  (interactive)
  (tired--copy-targets #'identity "path"))

(defun tired-copy-relative-path ()
  "Copy target paths relative to the shown directory."
  (interactive)
  (let ((directory tired--directory))
    (tired--copy-targets
     (lambda (path) (file-relative-name path directory))
     "relative path")))

(defun tired--project-root ()
  "Return the project root of the shown directory.
Signal a user error when no project contains it."
  (let ((project (project-current nil tired--directory)))
    (unless project
      (user-error "No project at %s" tired--directory))
    (project-root project)))

(defun tired-copy-project-path ()
  "Copy target paths relative to the project root."
  (interactive)
  (let ((root (tired--project-root)))
    (tired--copy-targets
     (lambda (path) (file-relative-name path root))
     "project path")))

(defun tired--visit-section (section &optional other-window)
  "Visit the file of SECTION at its line and column.
Show it in another window when OTHER-WINDOW is non-nil.  Return the
visited buffer."
  (let* ((path (tired-section-path section))
         (buffer (if other-window
                     (find-file-other-window path)
                   (find-file path))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line (max 0 (1- (tired-section-line section))))
      (when (tired-section-column section)
        (move-to-column (tired-section-column section)))
      (recenter))
    buffer))

(defun tired--open-section (section &optional other-window)
  "Visit the target of SECTION, in another window when requested.
A section without an action opens its file at the section line and
column.  An action is a function, or a cons of a function and extra
arguments.  The function receives SECTION and OTHER-WINDOW after the
extra arguments."
  (let ((action (tired-section-action section)))
    (cond
     ((null action)
      (tired--visit-section section other-window))
     ((consp action)
      (apply (car action) section
             (append (cdr action) (list other-window))))
     (t (funcall action section other-window)))))

(defun tired--open-entry (entry &optional other-window)
  "Visit ENTRY, in another window when OTHER-WINDOW is non-nil.
A section visits its own target.  Directories, including symlinks to
directories, open in a Tired buffer.  All other entry types open
with `find-file'."
  (if (tired-section-p entry)
      (tired--open-section entry other-window)
    (let ((path (tired-entry-path entry)))
      (if (file-directory-p path)
          (if other-window (tired-other-window path) (tired path))
        (if other-window
            (find-file-other-window path)
          (find-file path))))))

(defun tired-find-file (&optional other-window)
  "Visit the target entries.
Visit every target in another window when OTHER-WINDOW is non-nil.
Without a selection or an active region, the row at point is the
target, so a section row visits its own file position.  The
selection is cleared afterwards."
  (interactive "P")
  (let* ((row (tired--row-at-point))
         (section-p (and (tired-section-p row)
                         (null tired--selection)
                         (not (use-region-p))))
         (targets (unless section-p (tired--targets)))
         (origin (current-buffer)))
    (cond
     (section-p (tired--open-entry row other-window))
     (targets
      (dolist (entry targets)
        (tired--open-entry entry other-window)))
     (t (user-error "No entry at point")))
    (when (buffer-live-p origin)
      (with-current-buffer origin
        (tired-select-none)
        (deactivate-mark)))))

(defun tired-find-file-other-window ()
  "Visit the target entries in another window.
A directory opens through `switch-to-buffer-other-window', so the
user options `split-height-threshold' and `split-width-threshold'
decide the direction of a split, as they do for
`dired-find-file-other-window'."
  (interactive)
  (tired-find-file t))

(defun tired--click-row (event)
  "Return the row under the mouse click EVENT, or nil.
The click may land in a window that shows another listing, so read
the row from the buffer of that window.  A click below the last row
returns nil."
  (let* ((position (event-start event))
         (window (posn-window position))
         (point (posn-point position)))
    (when (and (window-live-p window)
               (integer-or-marker-p point))
      (with-current-buffer (window-buffer window)
        (when (and (>= point (point-min))
                   (<= point (point-max)))
          (tired--row-at point))))))

(defun tired-mouse-find-file-other-window (event)
  "Visit the entry under the mouse click EVENT in another window.
Read the row under the pointer, not the selection, so one click
opens one entry and the selection stays.  A section row visits its
own file position and a directory row opens a Tired buffer."
  (interactive "e")
  (let ((row (tired--click-row event)))
    (unless row
      (user-error "No entry under the mouse"))
    (mouse-set-point event)
    (tired--open-entry row t)))

(defun tired-mouse-toggle (event)
  "Toggle the row under the mouse double click EVENT.
A directory row inserts or removes its children, a file row with a
handler expands or collapses its sections, and a section row folds
or unfolds its children.  Move point to the row first, so the next
key command acts on it.  A double click makes no region, so drop the
one that the click started."
  (interactive "e")
  (unless (tired--click-row event)
    (user-error "No entry under the mouse"))
  (mouse-set-point event)
  (deactivate-mark)
  (tired-toggle-subdir))

(defun tired--click-selects-row (&rest _)
  "Return nil, so one click selects a row and follows no link.
`tabulated-list-mode' binds `follow-link' to `mouse-face', and that
binding turns a click on a marked row into a click on its other
binding.  The name cell of a row carries `mouse-face', so the pointer
highlights a name, and this predicate keeps that highlight from
turning a click into a link.  A Tired row needs one click to move
point, a second click to toggle the row and a drag to make a region,
so no click opens an entry.  The middle button opens a row instead."
  nil)

(defun tired-browse-url-of-file (&optional secondary)
  "Ask a WWW browser to display the target files.
Use `browse-url-secondary-browser-function' instead of
`browse-url-browser-function' when SECONDARY is non-nil.  Act on
the selection, then on the active region, then on the row at
point.  A section row browses the file that holds it.  A directory
target reaches the browser as a file URL, the way
`browse-url-of-dired-file' does.  Like that command, this one
leaves `browse-url-default-handlers' empty, so no Emacs handler
takes the file back from the browser."
  (interactive "P")
  (let ((targets (tired--targets)))
    (unless targets
      (user-error "No entry at point"))
    (let ((browse-url-browser-function
           (if secondary
               browse-url-secondary-browser-function
             browse-url-browser-function))
          (browse-url-default-handlers nil))
      (dolist (entry targets)
        (browse-url-of-file (tired-entry-path entry))))
    (deactivate-mark)))

(defun tired--context-command (position command)
  "Return a command that calls COMMAND at POSITION.
A context menu click does not move point, so the command moves
there first and then reads the row at point."
  (lambda ()
    (interactive)
    (when (integer-or-marker-p position)
      (goto-char (min position (point-max))))
    (call-interactively command)))

(defun tired-context-menu (menu click)
  "Populate MENU with the Tired commands for CLICK.
A click on a row adds the commands that act on that row, and the
listing commands follow.  A click below the last row adds nothing,
so the plain Emacs menu stays.  `tired-mode' puts this function
into `context-menu-functions' locally."
  (let ((row (tired--click-row click)))
    (when (and row (derived-mode-p 'tired-mode))
      (let* ((start (event-start click))
             (position (posn-point start))
             (entry (tired-entry-p row))
             (command (lambda (function)
                        (tired--context-command position function))))
        (define-key-after menu [tired-visit]
          (list 'menu-item "Visit" (funcall command #'tired-find-file)))
        (define-key-after menu [tired-visit-other-window]
          (list 'menu-item "Visit in Other Window"
                (funcall command #'tired-find-file-other-window)))
        (define-key-after menu [tired-separator] menu-bar-separator)
        (when (tired--directory-entry-p row)
          (define-key-after menu [tired-insert-subdir]
            (list 'menu-item "Insert Children"
                  (funcall command #'tired-insert-subdir)))
          (define-key-after menu [tired-toggle-subdir]
            (list 'menu-item "Toggle Subtree"
                  (funcall command #'tired-toggle-subdir))))
        (when (and entry (tired-file-handler (tired-entry-path row)))
          (define-key-after menu [tired-expand-file]
            (list 'menu-item "Expand Sections"
                  (funcall command #'tired-toggle-subdir))))
        (when entry
          (define-key-after menu [tired-rename]
            (list 'menu-item "Rename" (funcall command #'tired-rename)))
          (define-key-after menu [tired-copy-name]
            (list 'menu-item "Copy Name"
                  (funcall command #'tired-copy-name))))
        (define-key-after menu [tired-copy-here]
          (list 'menu-item "Copy Here" (funcall command #'tired-copy)))
        (define-key-after menu [tired-move]
          (list 'menu-item "Move" (funcall command #'tired-move)))
        (define-key-after menu [tired-delete]
          (list 'menu-item "Delete" (funcall command #'tired-delete)))
        (define-key-after menu [tired-separator-2] menu-bar-separator)
        (define-key-after menu [tired-refresh]
          '(menu-item "Refresh" tired-refresh))))
    menu))

(declare-function tired-export-csv "tired-export" ())
(declare-function tired-export-json "tired-export" ())
(declare-function tired-export-text "tired-export" ())

(defvar-keymap tired-mode-map
  :doc "Local keymap for `tired-mode' buffers."
  :parent tabulated-list-mode-map
  ;; The mouse reads the row under the pointer, so a click still moves
  ;; point and a drag still makes a region.
  "<mouse-2>" #'tired-mouse-find-file-other-window
  "<double-mouse-1>" #'tired-mouse-toggle
  "<follow-link>" #'tired--click-selects-row
  "RET" #'tired-find-file
  "o" #'tired-find-file-other-window
  "^" #'tired-up-directory
  "n" #'tired-next-line
  "p" #'tired-previous-line
  "g" #'tired-refresh
  "i" #'tired-insert-subdir
  "M-i" #'tired-remove-subdir
  "TAB" #'tired-toggle-subdir
  "j" #'tired-find-file
  "J" #'tired-find-file-other-window
  "s" #'tired-sort
  ">" #'tired-sort
  "SPC" #'tired-select-toggle-next
  "M-SPC" #'tired-select-toggle
  "S-SPC" #'tired-select-toggle
  "t" #'tired-select-all
  "%" #'tired-select-extension
  "u" #'tired-select-none
  "~" #'tired-toggle-hidden
  "N" #'tired-toggle-narrow
  "A" #'tired-toggle-auto-revert
  "C" #'tired-toggle-collapse
  "f" #'tired-filter
  "F" #'tired-clear-filter
  "." #'tired-toggle-dotfiles
  "y" #'tired-copy-name
  "w" #'tired-copy-path
  "W" #'tired-copy-relative-path
  "P" #'tired-copy-project-path
  "c" #'tired-copy
  "m" #'tired-move
  "R" #'tired-rename
  "D" #'tired-delete
  "!" #'tired-do-shell-command
  "+" #'tired-mkdir
  "M-t" #'tired-touch
  "q" #'quit-window
  "<remap> <dired-jump>" #'tired-jump
  "<remap> <end-of-buffer>" #'tired-goto-last-entry
  "<remap> <csv-mode>" #'tired-export-csv
  "<remap> <text-mode>" #'tired-export-text
  "<remap> <js-json-mode>" #'tired-export-json)

(easy-menu-define tired-mode-menu tired-mode-map
  "Menu for `tired-mode'.
The menu names the commands that a new user cannot guess from the
key map.  Each entry tests the listing when the menu opens, so a
command that needs an entry stays insensitive on an empty row."
  '("Tired"
    ["Visit" tired-find-file
     :active (tired--row-at-point)
     :help "Visit the entry at point, or every selected file"]
    ["Visit in other window" tired-find-file-other-window
     :active (tired--row-at-point)]
    ["Up" tired-up-directory]
    "--"
    ["Insert subdirectory" tired-insert-subdir
     :active (tired--directory-entry-p (tired--row-at-point))
     :help "Show the children of the directory at point"]
    ["Remove subdirectory" tired-remove-subdir
     :active (tired--directory-entry-p (tired--row-at-point))]
    ["Toggle subtree" tired-toggle-subdir
     :active (tired--directory-entry-p (tired--row-at-point))]
    ["Expand file" tired-expand-file
     :active (tired--row-at-point)
     :help "Show the sections that a handler extracts"]
    ["Collapse file" tired-collapse-file]
    ("Filter"
     ["Set filter" tired-filter
      :help "Narrow the listing while typing"]
     ["Clear filter" tired-clear-filter
      :active tired--filter]
     ["Show dotfiles" tired-toggle-dotfiles
      :style toggle :selected (not tired--hide-dotfiles)]
     ["Show hidden" tired-toggle-hidden
      :style toggle :selected tired--show-hidden])
    ("Select"
     ["Toggle" tired-select-toggle
      :active (tired--row-at-point)]
     ["Toggle and move down" tired-select-toggle-next
      :active (tired--row-at-point)]
     ["All" tired-select-all]
     ["By extension" tired-select-extension
      :active (tired--row-at-point)
      :help "Add every visible file with the extension of point"]
     ["None" tired-select-none
      :active tired--selection]
     ["Invert" tired-select-invert]
     ["Narrow to selection" tired-toggle-narrow]
     "--"
     ["Copy name" tired-copy-name
      :active (tired--row-at-point)]
     ["Copy path" tired-copy-path
      :active (tired--selection-targets)]
     ["Copy relative path" tired-copy-relative-path
      :active (tired--selection-targets)]
     ["Copy project path" tired-copy-project-path
      :active (tired--selection-targets)])
    ("Sort"
     ["Name" (tired--sort-by-column 'name)
      :style radio :selected (eq tired--sort-key 'name)]
     ["Size" (tired--sort-by-column 'size)
      :style radio :selected (eq tired--sort-key 'size)]
     ["Modified" (tired--sort-by-column 'modified)
      :style radio :selected (eq tired--sort-key 'modified)]
     ["Mode" (tired--sort-by-column 'mode)
      :style radio :selected (eq tired--sort-key 'mode)]
     "--"
     ["Cycle sort state" tired-sort
      :help "Move to the next state of `tired-sort-states'"])
    "--"
    ["Copy here" tired-copy
     :active (tired--selection-targets)]
    ["Move" tired-move
     :active (tired--selection-targets)]
    ["Rename" tired-rename
     :active (tired-entry-p (tired--row-at-point))
     :help "Rename the entry at point, without a confirmation"]
    ["Delete" tired-delete
     :active (tired--selection-targets)
     :help "Move the targets into the session trash"]
    ["Shell command" tired-do-shell-command
     :active (tired--selection-targets)]
    "--"
    ("Export"
     ["CSV" tired-export-csv
      :help "Write the targets or the whole view as CSV"]
     ["Text" tired-export-text
      :help "Write the view with a full path on every line"]
     ["JSON" tired-export-json
      :help "Write the targets or the whole view in the rclone lsjson shape"])
    "--"
    ["Refresh" tired-refresh]
    ["Automatic refresh" tired-toggle-auto-revert
     :style toggle :selected tired-auto-revert]
    ["Single-child collapse" tired-toggle-collapse
     :style toggle :selected tired-collapse-single-child]))

(define-derived-mode tired-mode tabulated-list-mode "Tired"
  "Major mode for editing a directory as a tabulated list.
The directory contents come from `directory-files' and
`file-attributes', never from parsing `ls -l' output.

\\{tired-mode-map}"
  :group 'tired
  (setq-local tired--sort-key 'name)
  (setq-local tired--sort-flip nil)
  (setq-local tired--filter nil)
  (tired--set-selection nil)
  (tired--set-narrowed nil)
  (setq-local tired--hide-dotfiles tired-hide-dotfiles)
  (setq-local tired--tables (make-hash-table :test #'equal))
  (setq-local tired--inserted (make-hash-table :test #'equal))
  (setq-local tired--watches nil)
  (setq-local tired--revert-timer nil)
  (setq-local tired--size-timer nil)
  (setq-local tired--size-deferred nil)
  (setq-local tired--collapse-cache (make-hash-table :test #'equal))
  (setq-local tired--expanded (make-hash-table :test #'equal))
  (setq-local tired--sections (make-hash-table :test #'equal))
  (setq-local tired--folded (make-hash-table :test #'equal))
  (setq-local tired--listing-stamps nil)
  (add-hook 'kill-buffer-hook #'tired--stop-watching nil t)
  (add-hook 'kill-buffer-hook #'tired--queue-forget-current nil t)
  (setq-local tabulated-list-format (tired--format))
  (setq-local tabulated-list-entries #'tired--tabulated-entries)
  ;; Emacs draws the sort arrow in the padding, and every Tired column
  ;; stays unsortable, so a blank padding column would carry nothing.
  (setq-local tabulated-list-padding 0)
  (setq-local tabulated-list-sort-key nil)
  (setq-local revert-buffer-function #'tired--revert)
  (setq-local bookmark-make-record-function #'tired-bookmark-make-record)
  ;; A row name is a file name at point, so `thing-at-point', `ffap'
  ;; and `embark' read the name column alone.
  (setq-local thing-at-point-provider-alist
              (cons '(filename . tired--filename-at-point)
                    thing-at-point-provider-alist))
  (setq-local bounds-of-thing-at-point-provider-alist
              (append '((filename . tired--name-bounds)
                        (tired-subtree . tired-subtree-bounds))
                      bounds-of-thing-at-point-provider-alist))
  ;; A depth-zero row with the rows that it prints forms one subtree,
  ;; so a reader of `thingatpt' steps one subtree at a time.
  (setq-local forward-thing-provider-alist
              (cons '(tired-subtree . tired--forward-subtree)
                    forward-thing-provider-alist))
  (setq-local tired--mode-line-base (default-value 'mode-line-format))
  (setq-local tired--mode-line-cache "")
  (setq-local mode-line-format tired--mode-line-base)
  (add-hook 'post-command-hook #'tired--mode-line-maybe-update nil t)
  ;; A quit command clears the filter before it runs, whatever key
  ;; reached it.  The hook belongs to the major mode, so a change of
  ;; major mode drops it together with the mode.
  (add-hook 'pre-command-hook #'tired--filter-quit-on-command nil t)
  ;; A redraw that no window shows leaves the directory sizes
  ;; unwalked, so the first display of the buffer walks them.
  (add-hook 'window-buffer-change-functions
            #'tired--window-buffer-changed nil t)
  ;; A scroll reveals rows that the last redraw never queued for an
  ;; element count, and `tired-elements' answers the seam.
  (add-hook 'post-command-hook #'tired--elements-queue-shown nil t)
  ;; `context-menu-functions' lives in mouse.el.  A session without a
  ;; menu has no context menu mode, so skip the hook there.
  (when (boundp 'context-menu-functions)
    (add-hook 'context-menu-functions #'tired-context-menu nil t)))

(provide 'tired-core)

;;; tired-core.el ends here
