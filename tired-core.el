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
(declare-function tired-undo "tired-file-ops" nil)
(declare-function recentf-add-file "recentf" (filename))

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

(defcustom tired-date-format "%Y-%m-%d %H:%M"
  "Format string for the modification time column.
See `format-time-string' for the available conversions."
  :type 'string)

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

(defcustom tired-display-buffer-action 'display-buffer-same-window
  "Display action that `tired' uses for the listing.
The value takes the form that `display-buffer' accepts: one action
function or a list of a function and an alist.  The default replaces
the current buffer, like `dired'.  Set it to a pop-up action to give
the listing its own window, and add a `display-buffer-alist' entry
for a rule that depends on the buffer name."
  :type '(choice (function-item display-buffer-same-window)
                 (function-item display-buffer-pop-up-window)
                 (function-item display-buffer-reuse-window)
                 (function :tag "Action function")
                 (repeat :tag "Action list" (sexp :tag "Action"))))

(defcustom tired-other-window-action
  '(display-buffer-use-some-window (inhibit-same-window . t))
  "Display action that `tired-other-window' uses for the listing.
The default reuses another window of the frame and never the
selected one.  The value takes the form that `display-buffer'
accepts."
  :type '(choice (function-item display-buffer-pop-up-window)
                 (function-item display-buffer-reuse-window)
                 (function :tag "Action function")
                 (repeat :tag "Action list" (sexp :tag "Action"))))

(defcustom tired-filter-delay 0.15
  "Seconds to wait before a typed filter redraws the listing.
A redraw walks the tree and prints every row, so a fast typist would
pay one redraw per keystroke.  The delay coalesces a burst of
keystrokes into one redraw, and the exit and quit keys apply the
pending text at once.  Set the value to 0 to redraw on every
keystroke."
  :type 'number
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
directory read per directory on the first walk, so the option stays
nil by default.  `tired-size-cache-ttl' then serves every later
refresh from a global memo table.  A remote directory never shows a
total, because the walk would cost one network round trip per file."
  :type 'boolean)

(defcustom tired-size-cache-ttl 60
  "Seconds a computed directory size stays valid.
A total sums a whole subtree, so an edit deep in the tree can change
a size that a listing already shows.  A cached total serves every
refresh inside this window, and a stale total stays on screen until
the window ends.  Set the value to 0 to sum the subtree on every
refresh.  A garbage collection hook cannot replace this window:
Emacs collects garbage several times during one walk of a large
tree, so such a hook would empty the table faster than it fills."
  :type 'natnum)

(defcustom tired-dwim-target t
  "When non-nil, `tired-move' reads a destination from another window.
The command scans the windows of the frame, the way
`dired-dwim-target-next' does.  When another window shows a Tired
buffer for another directory, the command moves the targets into
that directory at once and asks no question.  When no such window
exists, the command prompts in the minibuffer."
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
    ("\\.\\(?:md\\|markdown\\)\\'" . tired-file-sections-markdown)
    ("/Cargo\\.toml\\'" . tired-file-sections-cargo)
    ("\\.\\(?:db\\|sqlite\\|sqlite3\\)\\'" . tired-file-sections-sqlite))
  "Alist of regexp to a function that extracts sections from a file.
The regexp matches the absolute file name, and the first match wins.
The function receives the file name and runs in a temporary buffer
that holds the file contents.  It selects its own major mode, then
returns a list of plists with the keys `:label', `:line', `:level'
and `:kind', plus the optional keys `:column' and `:action'.  An
empty list means the file has no sections."
  :type '(alist :key-type regexp :value-type function))

(defcustom tired-org-narrow-on-open t
  "When non-nil, narrow an org buffer to the subtree that was opened.
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
  "Face for names that match `completion-ignored-extensions'.")

(defface tired-selected-face
  '((t :inherit highlight :extend t))
  "Face for entries in the transient selection.")

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
  '((t :inherit marginalia-size))
  "Face for the size column.
The column takes the Marginalia size face, so a theme colors a size
the way it colors a size in the Minibuffer completion list.")

(cl-defstruct (tired-entry (:constructor tired--entry-create))
  "One entry of a directory listing.
NAME is the file name without its directory.  PATH is the absolute
file name.  TYPE is one of `directory', `file', `symlink' or
`special'.  DIRP is non-nil for real directories only.  SIZE is the
size in bytes.  MTIME is a float time value.  MODE is the permission
string as returned by `file-attribute-modes'.  LINK is the link
target for symbolic links.  BROKEN is non-nil when a symbolic link
does not resolve.  COLLAPSED is non-nil on a display clone of a
single-entry chain, whose NAME holds the relative path."
  name
  path
  type
  dirp
  size
  mtime
  mode
  link
  broken
  collapsed)

(cl-defstruct (tired-section (:constructor tired--section-create))
  "One row that a file handler extracted from a file.
LABEL is the display string without indentation.  PATH is the
absolute file name that holds the section.  LINE is 1-based.  COLUMN
is 0-based, or nil.  LEVEL is the nesting level that the handler
declared.  KIND is a symbol such as `heading' or `function'.  ACTION
is nil for a plain visit, or a function, or a cons of a function and
its arguments."
  label
  path
  line
  column
  level
  kind
  action)

(defvar-local tired--directory nil
  "Absolute name of the directory shown in the current buffer.")

(defvar-local tired--tables nil
  "Hash table mapping absolute directory names to entry tables.")

(defvar-local tired--inserted nil
  "Hash table of directories whose children appear in the listing.")

(defvar-local tired--sort-key 'name
  "Column used to sort the listing.
One of `name', `size', `modified' or `mode'.")

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

(defvar-local tired--watches nil
  "Alist of watched directory names to file notification descriptors.")

(defvar-local tired--revert-timer nil
  "Pending `tired-auto-revert-delay' timer, or nil.")

(defvar-local tired--filter-timer nil
  "Pending `tired-filter-delay' timer, or nil.")

(defvar-local tired--collapse-cache nil
  "Hash table mapping a directory to its single-entry chain result.
The value is a cons of the leaf entry and the directories that the
chain walk visited, start first.  The leaf stays nil when the chain
does not collapse.  Refresh clears the cache.")

(defvar-local tired--expanded nil
  "Hash set of absolute file names whose sections appear in the listing.")

(defvar-local tired--sections nil
  "Hash table mapping an absolute file name to its parsed sections.
The value is a cons of the file modification time and the section
list.  A changed time re-parses the file.")

(defvar-local tired--folded nil
  "Hash set of `(PATH . LINE)' keys for folded sections.")

(defun tired--read-entries (directory)
  "Return a hash table of entries for DIRECTORY.
The table maps file names to `tired-entry' structs."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (pair (directory-files-and-attributes directory nil nil t))
      (let ((name (car pair)))
        (unless (member name '("." ".."))
          (puthash name (tired--make-entry directory name (cdr pair))
                   table))))
    table))

(defun tired--make-entry (directory name &optional attributes)
  "Return a `tired-entry' for NAME inside DIRECTORY.
ATTRIBUTES defaults to the result of `file-attributes' for the file.
`tired--read-entries' passes attributes that it already fetched."
  (let* ((path (expand-file-name name directory))
         (attributes (or attributes (file-attributes path)))
         (type (file-attribute-type attributes)))
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
     :broken (and (stringp type) (tired--broken-link-p path)))))

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

(defun tired--key-before-p (key a b)
  "Return non-nil when A sorts before B by KEY, ignoring direction."
  (pcase key
    ('name (string< (tired-entry-name a) (tired-entry-name b)))
    ('size (< (tired-entry-size a) (tired-entry-size b)))
    ('modified (< (tired-entry-mtime a) (tired-entry-mtime b)))
    ('mode (string< (tired-entry-mode a) (tired-entry-mode b)))
    (_ nil)))

(defun tired--lessp (a b)
  "Return non-nil when A must be listed before B.
Directories always come first.  Within a group, entries follow
`tired--sort-key' and `tired--sort-flip', with the name as the
tie-breaker."
  (cond
   ((and (tired-entry-dirp a) (not (tired-entry-dirp b))) t)
   ((and (tired-entry-dirp b) (not (tired-entry-dirp a))) nil)
   (t (let ((forward (tired--key-before-p tired--sort-key a b))
            (backward (tired--key-before-p tired--sort-key b a)))
        (cond (forward (not tired--sort-flip))
              (backward tired--sort-flip)
              (t (string< (tired-entry-name a) (tired-entry-name b))))))))

(defun tired--table (directory)
  "Return the entry table for DIRECTORY, or nil."
  (let ((directory (directory-file-name (expand-file-name directory))))
    (and (hash-table-p tired--tables)
         (gethash directory tired--tables))))

(defun tired--inserted-p (directory)
  "Return non-nil when DIRECTORY is inserted in the listing."
  (and (hash-table-p tired--inserted)
       (gethash (directory-file-name (expand-file-name directory))
                tired--inserted)))

(defun tired--directory-entry-p (entry)
  "Return non-nil when ENTRY can hold children.
A symbolic link counts when it resolves to a directory.  The row
keeps its symlink name and face either way."
  (and (tired-entry-p entry)
       (or (tired-entry-dirp entry)
           (and (eq (tired-entry-type entry) 'symlink)
                (file-directory-p (tired-entry-path entry))))))

(defun tired--sorted-directory-entries (directory visible-only)
  "Return the entries of DIRECTORY in display order.
When VISIBLE-ONLY is non-nil, drop entries hidden by the filter and
the dotfile setting."
  (let ((table (tired--table directory))
        entries)
    (when table
      (maphash (lambda (_name entry)
                 (when (or (not visible-only)
                           (tired--entry-visible-p entry))
                   (push entry entries)))
               table))
    (sort entries #'tired--lessp)))

(defun tired--directory-names (directory)
  "Return the entry names of DIRECTORY, or nil when unreadable."
  (ignore-errors
    (seq-remove (lambda (name) (member name '("." "..")))
                (directory-files directory nil nil t))))

(defun tired--single-entry-leaf (directory)
  "Return the leaf of the single-entry chain that starts at DIRECTORY.
The value is a cons of the leaf entry and the directories that the
walk visited, start first.  The leaf stays nil when DIRECTORY holds
zero or several entries, because such a chain does not collapse.
Every later level shortens the chain: the walk stops at the first
branch, at a hidden link, at an unreadable directory or at a cycle,
and the entry it reached becomes the leaf.  A visited-truename set
stops cycles."
  (let ((current (directory-file-name (expand-file-name directory)))
        (seen (make-hash-table :test #'equal))
        (visited nil)
        (leaf nil)
        (searching t))
    (while searching
      (let ((key (file-truename current)))
        (if (gethash key seen)
            (setq searching nil)
          (puthash key t seen)
          (push current visited)
          (let ((names (tired--directory-names current)))
            (if (or (/= 1 (length names))
                    (tired--chain-name-hidden-p (car names)))
                (setq searching nil)
              (let ((entry (tired--make-entry current (car names))))
                (setq leaf entry)
                (if (tired-entry-dirp entry)
                    (setq current (tired-entry-path entry))
                  (setq searching nil))))))))
    (cons leaf (nreverse visited))))

(defun tired--collapse-result (directory)
  "Return the cached chain result for DIRECTORY.
The value is a cons of the leaf entry, or nil, and the visited
directories."
  (let* ((key (directory-file-name (expand-file-name directory)))
         (cached (and (hash-table-p tired--collapse-cache)
                      (gethash key tired--collapse-cache 'missing))))
    (if (not (eq cached 'missing))
        cached
      (let ((result (tired--single-entry-leaf key)))
        (when (hash-table-p tired--collapse-cache)
          (puthash key result tired--collapse-cache))
        result))))

(defun tired--collapsed-file (directory)
  "Return the cached chain leaf for DIRECTORY, or nil."
  (car (tired--collapse-result directory)))

(defun tired--collapsed-display-entry (directory entry)
  "Return a display clone for ENTRY when it collapses to one entry.
DIRECTORY is the listed parent and provides the relative name.  The
result is nil when ENTRY is not a directory or does not collapse.
The leaf of the chain can be a file or a directory.  A remote
directory never collapses, because the chain walk reads one
directory per level, and every read costs a network round trip."
  (when (and tired-collapse-single-child
             (tired-entry-dirp entry)
             (not (file-remote-p (tired-entry-path entry))))
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
`:column', `:level', `:kind' and `:action'."
  (tired--section-create
   :label (or (plist-get item :label) "")
   :path path
   :line (or (plist-get item :line) 1)
   :column (plist-get item :column)
   :level (or (plist-get item :level) 0)
   :kind (or (plist-get item :kind) 'section)
   :action (plist-get item :action)))

(defun tired-file-sections (path &optional force)
  "Return the sections of PATH as a list of `tired-section' structs.
Parse the file when FORCE is non-nil or when its modification time
changed.  Return nil when no handler matches, when the file is gone
or when the handler found nothing."
  (let* ((handler (tired-file-handler path))
         (attributes (and handler (file-attributes path)))
         (time (and attributes
                    (file-attribute-modification-time attributes)))
         (cached (and (hash-table-p tired--sections)
                      (gethash path tired--sections)))
         (sections
          (cond
           ((null attributes) nil)
           ((and (not force) cached (equal (car cached) time)) (cdr cached))
           (t (mapcar (lambda (item) (tired--section-plist item path))
                      (tired--call-handler handler path))))))
    (when (and attributes (hash-table-p tired--sections))
      (puthash path (cons time sections) tired--sections))
    sections))

(defun tired--expanded-p (path)
  "Return non-nil when the sections of PATH appear in the listing."
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
  (or (null tired--filter)
      (string-match-p (regexp-quote tired--filter)
                      (tired-section-label section))))

(defun tired--section-face (section)
  "Return the face for SECTION from its kind."
  (pcase (tired-section-kind section)
    ((or 'heading 'title 'table) 'tired-section-heading-face)
    (_ 'tired-section-face)))

(defun tired--mirror-font-lock-face (string)
  "Return STRING with each `face' property copied into `font-lock-face'.
`font-lock-face' survives `font-lock-unfontify-region', which removes
`face'."
  (let ((string (copy-sequence string))
        (position 0)
        (end (length string)))
    (while (< position end)
      (let* ((face (get-text-property position 'face string))
             (next (or (next-single-property-change position 'face string end)
                       end)))
        (when face
          (add-text-properties position next
                               (list 'font-lock-face face)
                               string))
        (setq position next)))
    string))

(defun tired--section-cell (section)
  "Return the name column string for SECTION, without indentation.
A handler may return a label that already carries the faces of its
major mode.  Such a label keeps them and takes no fallback face."
  (let ((label (tired-section-label section)))
    (if (text-property-not-all 0 (length label) 'face nil label)
        (tired--mirror-font-lock-face label)
      (tired--propertize-name label (tired--section-face section)))))

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
last entry of the chain, keeping the directory's sort position.
Such a row still shows the sections of its file, and still shows the
children of its directory, when the user expands it."
  (let ((rows nil)
        (seen (make-hash-table :test #'equal)))
    (cl-labels
        ((walk (directory depth)
           (let ((key (file-truename directory)))
             (unless (gethash key seen)
               (puthash key t seen)
               (dolist (entry (tired--sorted-directory-entries directory nil))
                 (let* ((collapsed
                         (tired--collapsed-display-entry directory entry))
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

(defun tired--visible-rows ()
  "Return the visible (ROW . DEPTH) conses of the current listing.
Inside a redraw the value comes from `tired--rows', so the tree
walks once.  Outside a redraw the function walks the tree itself."
  (or tired--rows (tired--display-rows t)))

(defun tired--visible-entries ()
  "Return the entries that are currently shown, in display order.
Section rows are not entries, so they stay out of the result."
  (seq-filter #'tired-entry-p (mapcar #'car (tired--visible-rows))))

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

(defun tired--name-face (entry &optional name)
  "Return the face for the name of ENTRY, or nil for a plain name.
NAME defaults to the name of ENTRY.  The value covers the whole name,
and a partial rule contributes no value here.  The fixed order runs
directory, broken link, user rule, ignored suffix, symbolic link,
special file.  The order otherwise follows
`dired-font-lock-keywords'."
  (let ((name (or name (tired-entry-name entry))))
    (cond
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
  (list 'face face 'font-lock-face face))

(defun tired--propertize-name (name face &optional spans)
  "Return NAME with FACE applied, or NAME alone when FACE is nil.
Paint SPANS over the result when SPANS holds entries."
  (let ((string (if face
                    (apply #'propertize name (tired--face-properties face))
                  name)))
    (if spans
        (tired--paint-name-spans string spans)
      string)))

(defun tired--symlink-suffix (entry)
  "Return the arrow and the target text for the symbolic link ENTRY."
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
         (head (string-remove-suffix file name)))
    (concat (tired--propertize-name head 'tired-directory-face)
            (tired--propertize-name file (tired--name-face entry file)
                                    (tired--entry-name-spans entry file))
            (when (tired-entry-dirp entry)
              (tired--propertize-name "/" 'tired-directory-suffix-face))
            (when (eq (tired-entry-type entry) 'symlink)
              (tired--symlink-suffix entry)))))

(defun tired--name-cell (entry)
  "Return the name column string for ENTRY."
  (let* ((name (tired-entry-name entry))
         (face (tired--name-face entry))
         (spans (tired--entry-name-spans entry name)))
    (cond
     ((tired-entry-collapsed entry) (tired--collapsed-name-cell entry))
     (t (pcase (tired-entry-type entry)
          ('directory
           (concat (tired--propertize-name name face)
                   (tired--propertize-name
                    "/" 'tired-directory-suffix-face)))
          ('symlink
           (concat (tired--propertize-name name face spans)
                   (tired--symlink-suffix entry)))
          (_ (tired--propertize-name name face spans)))))))

(defun tired--mouse-help (row)
  "Return the mouse help text for ROW.
The keys alone never show the mouse, so the text names the two
commands.  The middle button reads the row, and the second click of
a double click toggles it."
  (cond
   ((tired-section-p row)
    "mouse-2: visit in another window, double-click: fold")
   ((tired--directory-entry-p row)
    (concat "mouse-2: visit in another window, "
            "double-click: show or hide the children"))
   ((tired-file-handler (tired-entry-path row))
    "mouse-2: visit in another window, double-click: expand or collapse")
   (t "mouse-2: visit in another window")))

(defun tired--paint-row-mouse ()
  "Add the mouse face and the help text to every printed row.
`tabulated-list-print' erases and reprints the buffer, so this pass
runs after each print.  The whole line reacts, so the indent of a
nested row and the space beside the columns light up too."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((row (tabulated-list-get-id)))
          (when row
            (add-text-properties
             (line-beginning-position) (line-end-position)
             (list 'mouse-face 'highlight
                   'help-echo (tired--mouse-help row)))))
        (forward-line 1)))))

(defvar tired--size-cache (make-hash-table :test #'equal)
  "Global memo table for `tired--subtree-size'.
Every Tired buffer shares the table.  A key holds the absolute name
of a directory, so a walk needs no `file-truename' call to build
one.  A value holds `(TOTAL . STAMP)', where STAMP is the
`float-time' at which the walk that produced TOTAL started.
`tired-size-cache-ttl' bounds the age of a total and
`tired--size-cache-prune' drops the totals that expire.")

(defvar tired--size-stamp nil
  "Stamp that the running size walk stores in `tired--size-cache'.
A walk binds one timestamp, so every directory that the walk
reaches carries the same age.")

(defun tired--size-key (directory)
  "Return the `tired--size-cache' key for DIRECTORY.
Normalise the name without a symbolic link resolution: the walk
starts on one directory and never descends through a link, so the
absolute name stays unique.  `file-truename' would cost one file
round trip per path component."
  (directory-file-name (expand-file-name directory)))

(defun tired--size-cache-valid-p (value)
  "Return non-nil when VALUE holds a total young enough to reuse."
  (and (consp value)
       (<= (- (float-time) (cdr value)) tired-size-cache-ttl)))

(defun tired--size-cache-clear ()
  "Drop every cached directory size."
  (clrhash tired--size-cache))

(defun tired--size-cache-prune ()
  "Drop every cached total that `tired-size-cache-ttl' expired.
Call it on refresh, so the table holds no more than the directories
that one cache window can reach."
  (let (stale)
    (maphash (lambda (key value)
               (unless (tired--size-cache-valid-p value)
                 (push key stale)))
             tired--size-cache)
    (dolist (key stale)
      (remhash key tired--size-cache))))

(defun tired--subtree-size (directory)
  "Return the number of bytes in every regular file under DIRECTORY.
Skip symbolic links, so a link cycle cannot loop.  Store each
visited directory in `tired--size-cache', so one calculation reads a
nested directory once and a later walk inside the cache window
reads nothing.  An unreadable directory counts as zero."
  (let* ((key (tired--size-key directory))
         (hit (gethash key tired--size-cache)))
    (if (tired--size-cache-valid-p hit)
        (car hit)
      (let ((total 0))
        (dolist (pair (ignore-errors
                       (directory-files-and-attributes directory nil nil t)))
          (let* ((name (car pair))
                 (attributes (cdr pair))
                 (type (file-attribute-type attributes)))
            (unless (member name '("." ".."))
              (cond
               ((eq t type)
                (setq total (+ total (tired--subtree-size
                                      (expand-file-name name directory)))))
               ((stringp type) nil)
               (t (setq total (+ total
                                 (or (file-attribute-size attributes) 0))))))))
        (puthash key (cons total (or tired--size-stamp (float-time)))
                 tired--size-cache)
        total))))

(defun tired--directory-total (directory)
  "Return the number of bytes in every regular file under DIRECTORY.
Serve the value from `tired--size-cache' when it stays young enough
and sum the subtree otherwise.  One walk stamps every directory it
reaches with the same start time."
  (let ((tired--size-stamp (float-time)))
    (tired--subtree-size directory)))

(defun tired--size-cell (entry)
  "Return the size column string for ENTRY.
A remote directory keeps the column empty, because a walk over the
network costs one round trip per file."
  (cond
   ((not (tired-entry-dirp entry))
    (file-size-human-readable (tired-entry-size entry)))
   ((not tired-directory-size) "")
   ((file-remote-p (tired-entry-path entry)) "")
   (t
    (file-size-human-readable
     (tired--directory-total (tired-entry-path entry))))))

(defun tired--size-column (entry)
  "Return the size cell for ENTRY, painted with `tired-file-size'.
An empty cell keeps no face, because a face on no text shows
nothing."
  (let ((text (tired--size-cell entry)))
    (if (string-empty-p text)
        text
      (propertize text 'face 'tired-file-size
                  'font-lock-face 'tired-file-size))))

(defun tired--row (row depth)
  "Return the tabulated list row for ROW at DEPTH.
ROW is a `tired-entry' or a `tired-section'.  A section fills the
name column only, because one table format serves every row.
Emacs 31 requires a vector of column descriptors here; a list makes
`tabulated-list-print-entry' signal a type error."
  (if (tired-section-p row)
      (vector (concat (make-string (* 2 depth) ?\s)
                      (tired--section-cell row))
              ""
              ""
              "")
    (vector (concat (make-string (* 2 depth) ?\s)
                    (tired--name-cell row))
            (tired--size-column row)
            (propertize (format-time-string tired-date-format
                                            (tired-entry-mtime row))
                        'face 'tired-date
                        'font-lock-face 'tired-date)
            (tired-entry-mode row))))

(defun tired--tabulated-entries ()
  "Return `tabulated-list-entries' for the current listing.
When `tired-directory-size' is non-nil, the global memo table
serves every row of every redraw, so a nested directory costs one
read per `tired-size-cache-ttl' window, not one read per redraw."
  (mapcar (lambda (row)
            (list (car row) (tired--row (car row) (cdr row))))
          (tired--visible-rows)))

(defun tired--column-sort-keymap (key)
  "Return a key map that sorts the listing by KEY.
A click on the header of the column runs `tired-sort', so the
column that already sorts the listing flips the direction."
  (let ((map (make-sparse-keymap))
        (command (lambda () (interactive) (tired-sort key))))
    (define-key map [header-line mouse-1] command)
    ;; `follow-link' can turn a click into a drag event.  Bind the
    ;; second button too, so the header sorts either way.
    (define-key map [header-line mouse-2] command)
    map))

(defun tired--column-label (label key)
  "Return LABEL with a direction indicator when KEY is the sort key.
The label carries a key map, so a click on the header sorts by that
column.  The indicator stays in the string, and a click on the
current sort column flips the direction."
  (propertize (if (eq key tired--sort-key)
                  (concat label (if tired--sort-flip " v" " ^"))
                label)
              'keymap (tired--column-sort-keymap key)
              'mouse-face 'header-line-highlight
              'help-echo "mouse-1: sort by this column"))

(defconst tired--fixed-column-width 38
  "Width of the columns that keep their size.
This sum covers the size, modification time and mode columns, the
left padding and the space after the name column.")

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
   (list (tired--column-label "Modified" 'modified) 17 nil)
   (list (tired--column-label "Mode" 'mode) 10 nil)))

(defun tired--escape-mode-line (text)
  "Return TEXT with every percent sign doubled.
The mode line and the header line read `%' as the start of a
substitution, so a literal sign needs two.  A filter string and a
directory name can hold any character, and `%b' in a filter would
print the buffer name."
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
      (push (format "%d in region" (length (tired--region-entries))) parts))
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

(defun tired--selection-size ()
  "Return the total size of the selected non-directory entries in bytes."
  (let ((total 0))
    (dolist (entry (tired--selected-entries) total)
      (unless (tired-entry-dirp entry)
        (setq total (+ total (or (tired-entry-size entry) 0)))))))

(defun tired--selection-targets ()
  "Return the entries a command acts on.
The transient selection comes first, then the active region, then
the row at point.  A section row stands for the file that holds it."
  (or (tired--selected-entries)
      (tired--region-entries)
      (let ((row (tired--row-at-point)))
        (cond
         ((tired-entry-p row) (list row))
         ((tired-section-p row)
          (let ((entry (tired--entry-for-path
                        (tired-section-path row))))
            (when entry (list entry))))))))

(defun tired--region-entries ()
  "Return the entries inside the active region, or nil.
The row on which the region ends does not join, because the region
ends at the beginning of that line.  A section row does not join,
because a region targets files."
  (when (use-region-p)
    (let ((end (region-end))
          entries)
      (save-excursion
        (goto-char (region-beginning))
        (beginning-of-line)
        (while (and (not (eobp))
                    (< (line-beginning-position) end))
          (let ((row (tired--row-at-point)))
            (when (tired-entry-p row) (push row entries)))
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
                 (when (car result)
                   (setq paths (append (cdr result) paths))))
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
  (dolist (watch tired--watches)
    (ignore-errors (file-notify-rm-watch (cdr watch))))
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
  "Add missing watches and remove watches for vanished paths."
  (if (not (tired--auto-revert-enabled-p))
      (tired--stop-watching)
    (let ((wanted (tired--watch-paths)))
      (dolist (directory wanted)
        (unless (assoc directory tired--watches)
          (let* ((buffer (current-buffer))
                 (callback (lambda (_event)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (tired--schedule-revert)))))
                 (descriptor (ignore-errors
                               (file-notify-add-watch directory
                                                      '(change)
                                                      callback))))
            (when descriptor
              (push (cons directory descriptor) tired--watches)))))
      (setq tired--watches
            (seq-filter
             (lambda (watch)
               (if (member (car watch) wanted)
                   t
                 (ignore-errors (file-notify-rm-watch (cdr watch)))
                 nil))
             tired--watches)))))

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
  "Redraw the listing from the cached entries.
WINDOW is the window that shows the buffer, or nil for the selected
window.  Its width limits the name column.  The redraw keeps the
point and the scroll position of every window that shows the listing."
  (let* ((window (or window (selected-window)))
         (point-entry (tired--point-row window))
         (mark-entry (tired--row-at (mark t)))
         (views (tired--window-views)))
    (setq tired--hidden-total (tired--count-hidden))
    (setq tired--rows (tired--display-rows t))
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
          (tired--paint-row-mouse))
      (setq tired--rows nil))
    (tired--goto-entry point-entry)
    (tired--restore-window-views views)
    (tired--restore-mark mark-entry)
    (tired--apply-selection-overlays)
    (tired--sync-watches)
    (tired--update-mode-line)))

(defun tired--width-changed-p (window)
  "Return non-nil when WINDOW needs a different name column width.
The size hook fires once per changed window of a frame, and it also
fires when the echo area grows.  A redraw that finds the same width
has nothing to do, and its reprint would only cost the point and the
scroll position of the window."
  (/= (tired--name-column-width window)
      (nth 1 (aref tabulated-list-format 0))))

(defun tired--window-size-changed (frame)
  "Redraw Tired listings in the windows of FRAME.
A resize changes the space available to the name column."
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
files that vanished.  Keep `tired--size-cache', so a refresh inside
one `tired-size-cache-ttl' window reads no directory twice."
  (setq tired--tables (make-hash-table :test #'equal))
  (setq tired--collapse-cache (make-hash-table :test #'equal))
  (tired--size-cache-prune)
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
  "Reload the listing from disk and redraw the buffer."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (tired--reload-tables)
  (tired--set-selection (tired--prune-selection tired--selection))
  (tired--set-narrowed (tired--prune-selection tired--narrowed))
  (tired--redraw))

(defun tired--revert (_ignore-auto _noconfirm)
  "Revert the buffer by refreshing the listing.
IGNORE-AUTO and NOCONFIRM are accepted for `revert-buffer-function'."
  (tired-refresh))

(defun tired--buffer-name (directory)
  "Return the Tired buffer name for DIRECTORY."
  (format "Tired: %s" (abbreviate-file-name directory)))

;;;###autoload
(defun tired-noselect (directory)
  "Return a Tired buffer for DIRECTORY, without selecting it.
The buffer name depends on DIRECTORY, so a second call reuses the
same buffer.  The buffer gets DIRECTORY as `default-directory'."
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (unless (file-directory-p directory)
      (user-error "Not a directory: %s" directory))
    (let ((buffer (get-buffer-create (tired--buffer-name directory))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'tired-mode)
          (tired-mode))
        (unless (equal tired--directory directory)
          (setq tired--inserted (make-hash-table :test #'equal))
          (setq tired--expanded (make-hash-table :test #'equal))
          (setq tired--sections (make-hash-table :test #'equal))
          (setq tired--folded (make-hash-table :test #'equal))
          (tired--set-selection nil))
        (setq tired--directory directory)
        (setq default-directory directory)
        (tired-refresh)
        ;; `recentf-mode' records files that a buffer visits, and a
        ;; Tired buffer visits a directory.
        (when (bound-and-true-p recentf-mode)
          (recentf-add-file directory)))
      buffer)))

;;;###autoload
(define-minor-mode tired-find-file-mode
  "Let `find-file' visit a directory in a Tired buffer.
Turning the mode on puts `tired-noselect' into
`find-directory-functions'.  Turning it off takes that function out
again, so `find-file' falls back to Dired.  The mode starts off, so
no command changes without the user's consent."
  :global t
  :group 'tired
  (if tired-find-file-mode
      (add-to-list 'find-directory-functions #'tired-noselect)
    (setq find-directory-functions
          (delq #'tired-noselect find-directory-functions))))

(defun tired--show-buffer (buffer action)
  "Show BUFFER through ACTION, select its window and return BUFFER.
Select the window that `display-buffer' chose, so a caller such as
`tired-jump' can move point in the listing.  The command returns the
buffer, as `dired' does, also when ACTION picks no window."
  (let ((window (display-buffer buffer action)))
    (when (window-live-p window)
      (select-window window))
    buffer))

;;;###autoload
(defun tired (directory)
  "Show DIRECTORY in a Tired buffer.
Interactively, offer `default-directory' as the default.  This
command is the short way to open a listing, in the manner of
`dired'.  The listing goes through `tired-display-buffer-action'."
  (interactive
   (list (read-directory-name "Directory: " nil default-directory t)))
  (tired--show-buffer (tired-noselect directory)
                       tired-display-buffer-action))

;;;###autoload
(defun tired-other-window (directory)
  "Show DIRECTORY in a Tired buffer in another window.
The listing goes through `tired-other-window-action'."
  (interactive
   (list (read-directory-name "Directory: " nil default-directory t)))
  (tired--show-buffer (tired-noselect directory)
                       tired-other-window-action))

(defun tired-up-directory ()
  "Open the parent of the current directory."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (tired (file-name-directory (directory-file-name tired--directory))))

(defun tired--last-row-position ()
  "Return the position of the last row of the listing, or nil."
  (save-excursion
    (goto-char (point-max))
    (beginning-of-line)
    (while (and (not (bobp)) (null (tired--row-at-point)))
      (forward-line -1))
    (when (tired--row-at-point)
      (point))))

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

(defun tired-insert-subdir (&optional directory)
  "Insert the children of DIRECTORY into the listing.
DIRECTORY defaults to the directory at point.  Inserted children
follow their parent row and indent by one level.  Inserting an
already inserted directory changes nothing."
  (interactive)
  (let* ((entry (tired--row-at-point))
         (directory (or directory
                        (and (tired-entry-p entry)
                             (tired-entry-path entry))
                        (user-error "No directory at point"))))
    (unless (file-directory-p directory)
      (user-error "Not a directory: %s" directory))
    (setq directory (directory-file-name (expand-file-name directory)))
    (puthash directory t tired--inserted)
    (puthash directory (tired--read-entries directory) tired--tables)
    (tired--redraw)))

(defun tired-remove-subdir ()
  "Remove the inserted children of the directory at point."
  (interactive)
  (let ((entry (tired--row-at-point)))
    (unless (and (tired-entry-p entry)
                 (tired--inserted-p (tired-entry-path entry)))
      (user-error "No inserted directory at point"))
    (tired--forget-inserted (tired-entry-path entry))
    (tired--redraw)))

(defun tired-expand-file (&optional path)
  "Show the sections of the file at point under its row.
PATH defaults to the file at point.  Signal a user error when no
handler claims the file, or when the handler found no section."
  (interactive)
  (let* ((row (tired--row-at-point))
         (path (or path
                   (and (tired-entry-p row) (tired-entry-path row))
                   (user-error "No entry at point"))))
    (unless (tired-file-handler path)
      (user-error "No section handler for %s"
                  (file-name-nondirectory path)))
    (unless (tired-file-sections path)
      (user-error "No sections in %s" (file-name-nondirectory path)))
    (tired--set-expanded path t)
    (tired--redraw)
    (message "Expanded %s" (file-name-nondirectory path))))

(defun tired-collapse-file (&optional path)
  "Hide the sections of the file at point.
PATH defaults to the file at point.  Signal a user error when the
file is not expanded."
  (interactive)
  (let* ((row (tired--row-at-point))
         (path (or path
                   (and (tired-entry-p row) (tired-entry-path row))
                   (and (tired-section-p row) (tired-section-path row))
                   (user-error "No entry at point"))))
    (unless (tired--expanded-p path)
      (user-error "%s is not expanded" (file-name-nondirectory path)))
    (tired--set-expanded path nil)
    (tired--redraw)))

(defun tired--toggle-expand (path)
  "Expand the file PATH, or collapse it when it is expanded."
  (if (tired--expanded-p path)
      (tired-collapse-file path)
    (tired-expand-file path)))

(defun tired--toggle-fold (section)
  "Fold SECTION, or unfold it when it is folded."
  (if (tired--section-folded-p section)
      (tired--set-folded section nil)
    (tired--set-folded section t))
  (tired--redraw))

(defun tired-toggle-subdir ()
  "Insert, expand or fold the subtree at point.
A directory row inserts or removes its children.  A file row with a
section handler expands or collapses its sections.  A section row
folds or unfolds its own children."
  (interactive)
  (let ((row (tired--row-at-point)))
    (cond
     ((tired-section-p row) (tired--toggle-fold row))
     ((not (tired-entry-p row)) (user-error "No entry at point"))
     ((file-directory-p (tired-entry-path row))
      (if (tired--inserted-p (tired-entry-path row))
          (tired-remove-subdir)
        (tired-insert-subdir)))
     ((tired-file-handler (tired-entry-path row))
      (tired--toggle-expand (tired-entry-path row)))
     (t (user-error "No subtree at point")))))

;;;###autoload
(defun tired-jump (&optional other-window)
  "Visit the directory of the current buffer in a Tired buffer.
In a Tired buffer, visit the parent directory and put point on the
directory that was shown.  Without a visited file, use
`default-directory'.  When OTHER-WINDOW is non-nil, show the buffer in
another window."
  (interactive "P")
  (let* ((here (expand-file-name
                (cond ((derived-mode-p 'tired-mode) tired--directory)
                      ((buffer-file-name) (buffer-file-name))
                      (t default-directory))))
         (directory-p (file-directory-p here))
         (directory (if (and directory-p (derived-mode-p 'tired-mode))
                        (file-name-directory (directory-file-name here))
                      (if directory-p
                          here
                        (file-name-directory here))))
         (anchor (cond ((derived-mode-p 'tired-mode)
                        (directory-file-name here))
                       (directory-p nil)
                       (t (directory-file-name here)))))
    (if other-window (tired-other-window directory) (tired directory))
    (tired--goto-path anchor)))

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

(defun tired-select-none ()
  "Clear the transient selection."
  (interactive)
  (tired--set-selection nil)
  (tired--apply-selection-overlays)
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
  "Show only the selected entries and the directories that contain them."
  (interactive)
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

(defun tired-sort (column &optional reverse)
  "Sort the listing by COLUMN.
COLUMN is one of `name', `size', `modified' or `mode'.  Selecting
the current column again flips the direction.  With REVERSE, start
with the opposite direction."
  (interactive
   (list (intern (completing-read "Sort by: "
                                  '("name" "size" "modified" "mode")
                                  nil t nil nil
                                  (symbol-name tired--sort-key)))
         current-prefix-arg))
  (if (eq column tired--sort-key)
      (setq tired--sort-flip (not tired--sort-flip))
    (setq tired--sort-key column
          tired--sort-flip (and reverse t)))
  (tired--redraw))

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

(defun tired-filter ()
  "Narrow the listing while typing a filter.
A change updates the listing after `tired-filter-delay'.
\[exit-minibuffer] keeps the filter and applies the typed text at
once, \[keyboard-quit] restores the previous one.  An empty filter
removes it."
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

(defun tired-copy-name ()
  "Copy the names of the targets to the kill ring."
  (interactive)
  (let ((targets (tired--selection-targets)))
    (unless targets
      (user-error "No entry at point"))
    (kill-new (mapconcat #'tired-entry-name targets "\n"))
    (deactivate-mark)
    (message "Copied %d name%s"
             (length targets)
             (if (= (length targets) 1) "" "s"))))

(defun tired--copy-targets (function description)
  "Copy FUNCTION of each target path to the kill ring.
DESCRIPTION names the copied form in the echo area."
  (let ((targets (tired--selection-targets)))
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
         (targets (unless section-p (tired--selection-targets)))
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
  "Visit the target entries in another window."
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
binding.  A Tired row needs one click to move point, a second click
to toggle the row and a drag to make a region, so no click opens an
entry.  The middle button opens a row instead."
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
  (let ((targets (tired--selection-targets)))
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
  "g" #'tired-refresh
  "i" #'tired-insert-subdir
  "M-i" #'tired-remove-subdir
  "TAB" #'tired-toggle-subdir
  "e" #'tired-expand-file
  "E" #'tired-collapse-file
  "j" #'tired-find-file
  "J" #'tired-find-file-other-window
  "s" #'tired-sort
  "SPC" #'tired-select-toggle-next
  "M-SPC" #'tired-select-toggle
  "S-SPC" #'tired-select-toggle
  "t" #'tired-select-all
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
  "U" #'tired-undo
  "q" #'quit-window
  "<remap> <dired-jump>" #'tired-jump
  "<remap> <end-of-buffer>" #'tired-goto-last-entry)

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
     ["Name" (tired-sort 'name)
      :style radio :selected (eq tired--sort-key 'name)]
     ["Size" (tired-sort 'size)
      :style radio :selected (eq tired--sort-key 'size)]
     ["Modified" (tired-sort 'modified)
      :style radio :selected (eq tired--sort-key 'modified)]
     ["Mode" (tired-sort 'mode)
      :style radio :selected (eq tired--sort-key 'mode)])
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
    ["Undo" tired-undo
     :active (bound-and-true-p tired--undo-actions)]
    ["Shell command" tired-do-shell-command
     :active (tired--selection-targets)]
    "--"
    ["Refresh" tired-refresh]
    ["Automatic refresh" tired-toggle-auto-revert
     :style toggle :selected tired-auto-revert]
    ["Single-child collapse" tired-toggle-collapse
     :style toggle :selected tired-collapse-single-child]))

;;;###autoload
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
  (setq-local tired--collapse-cache (make-hash-table :test #'equal))
  (setq-local tired--expanded (make-hash-table :test #'equal))
  (setq-local tired--sections (make-hash-table :test #'equal))
  (setq-local tired--folded (make-hash-table :test #'equal))
  (add-hook 'kill-buffer-hook #'tired--stop-watching nil t)
  (setq-local tabulated-list-format (tired--format))
  (setq-local tabulated-list-entries #'tired--tabulated-entries)
  ;; Emacs draws the sort arrow in the padding, and every Tired column
  ;; stays unsortable, so a blank padding column would carry nothing.
  (setq-local tabulated-list-padding 0)
  (setq-local tabulated-list-sort-key nil)
  (setq-local revert-buffer-function #'tired--revert)
  (setq-local bookmark-make-record-function #'tired-bookmark-make-record)
  (setq-local tired--mode-line-base (default-value 'mode-line-format))
  (setq-local tired--mode-line-cache "")
  (setq-local mode-line-format tired--mode-line-base)
  (add-hook 'post-command-hook #'tired--mode-line-maybe-update nil t)
  ;; `context-menu-functions' lives in mouse.el.  A session without a
  ;; menu has no context menu mode, so skip the hook there.
  (when (boundp 'context-menu-functions)
    (add-hook 'context-menu-functions #'tired-context-menu nil t)))

(provide 'tired-core)

;;; tired-core.el ends here
