;;; tired.el --- Tabulated list directory editor  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; URL: https://github.com/nagy/tired
;; Version: 0.1.0
;; Keywords: files
;; Package-Requires: ((emacs "31.1"))

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

;; Tired is a directory editor built on `tabulated-list-mode'.  It
;; reads directory contents with Emacs primitives and never parses
;; the output of `ls -l'.
;;
;; Entry points:
;;
;;   M-x tired
;;   M-x tired-other-window
;;
;; `M-x tired-find-file-mode' makes `find-file' visit a directory in a
;; Tired buffer.  The mode starts off, so the user opts in.
;;
;; Key bindings in `tired-mode':
;;
;;   RET     visit the entry at point, or every selected file
;;   o       same, in another window
;;   ^       go to the parent directory
;;   g       refresh the listing
;;   l       refresh the listing, including inserted sections
;;   i       insert the children of the directory at point
;;   TAB     insert, expand or fold the subtree at point
;;   e       expand the sections of the file at point
;;   E       collapse the sections of the file at point
;;   j       find a path anywhere below the shown directory
;;   J       the same, in another window
;;   M-i     remove the inserted children of the directory at point
;;   s       sort the listing
;;   SPC     toggle selection, then move to the next line
;;   M-SPC   toggle selection of the entry at point
;;   t       select every visible entry
;;   u       clear the selection
;;   ~       invert the selection over the visible entries
;;   N       narrow to the selection, or widen again
;;   A       toggle automatic refresh on directory changes
;;   C       toggle single-child directory collapse
;;   f       narrow the listing while typing a filter
;;   F       remove the filter
;;   .       toggle hidden entries
;;   y       copy the name of the targets
;;   w       copy the full path of the targets
;;   W       copy paths relative to the shown directory
;;   P       copy paths relative to the project root
;;   c       copy the targets into a directory
;;   m       move the targets
;;   D       delete the targets, without a confirmation
;;   +       create a directory
;;   M-t     create an empty file
;;   U       undo the last file operation
;;   q       bury the buffer
;;
;; Related commands:
;;
;;   M-x tired-jump  visit the directory of the current buffer
;;
;; The mode sets `bookmark-make-record-function', so `bookmark-set'
;; records a Tired buffer and `bookmark-jump' restores it.
;;
;; The selection is transient.  It lives only in the buffer, it is
;; pruned when entries disappear, and commands that act on it clear
;; it afterwards.  An active region is a second target source: mark a
;; row, move with S-<down> or the mouse, and every row in between
;; becomes a target.  A non-empty selection wins over the region.
;;
;; A file row opens into sections when a handler claims the file.
;; `tired-file-handlers' maps a regexp on the absolute file name to a
;; function.  The function reads the file in a temporary buffer and
;; returns a list of plists with `:label', `:line', `:level' and
;; `:kind'.  Org files yield headings, Emacs Lisp files yield top-level
;; forms, Rust and Markdown files yield items through tree-sitter,
;; Cargo manifests yield the four dependency and feature tables, and
;; SQLite databases yield tables and columns through the built-in
;; `sqlite' support.  TAB expands a file row, and TAB on a section row
;; folds that section.
;;
;; File operations act at once, without a confirmation question.
;; Delete moves each path into `tired-trash-directory', and a copy or
;; a move that replaces a path puts the old path there first.  Each
;; command hands an undo function to `tired-undo-push-functions', so a
;; global undo system can own the action.  While that hook is empty,
;; `tired-undo' pops the action from `tired--undo-actions'.

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

(defgroup tired nil
  "Tabulated list directory editor."
  :group 'files
  :prefix "tired-")

(defcustom tired-hide-dotfiles nil
  "When non-nil, do not list entries whose name starts with a dot."
  :type 'boolean)

(defcustom tired-date-format "%Y-%m-%d %H:%M"
  "Format string for the modification time column.
See `format-time-string' for the available conversions."
  :type 'string)

(defcustom tired-auto-revert t
  "When non-nil, refresh the listing when a watched directory changes."
  :type 'boolean)

(defcustom tired-auto-revert-delay 0.5
  "Seconds to wait after a file notification before refreshing.
A delay coalesces bursts of events, such as a build writing many
files, into one refresh."
  :type 'number)

(defcustom tired-collapse-single-child t
  "When non-nil, collapse a directory that leads to exactly one file.
The collapsed row shows the path relative to the listed directory,
uses the file attributes, and keeps the directory's position in the
listing.  The row acts as the file for open, selection and copy."
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

(defvar-local tired--watches nil
  "Alist of watched directory names to file notification descriptors.")

(defvar-local tired--revert-timer nil
  "Pending `tired-auto-revert-delay' timer, or nil.")

(defvar-local tired--collapse-cache nil
  "Hash table mapping a directory to its single-entry chain result.
The value is the final file entry, or nil when the chain does not
collapse.  Refresh clears the cache.")

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

(defun tired--name-visible-p (entry)
  "Return non-nil when ENTRY passes the dotfile and name filters."
  (let ((case-fold-search t))
    (and (or (not tired--hide-dotfiles)
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

(defun tired--single-entry-file (directory)
  "Return the file entry at the end of a single-entry chain under DIRECTORY.
Return nil when a level holds zero or several entries.  The chain
stops at the first branch.  A visited-truename set stops cycles."
  (let ((current (directory-file-name (expand-file-name directory)))
        (seen (make-hash-table :test #'equal))
        (result nil)
        (searching t))
    (while searching
      (let ((key (file-truename current)))
        (if (gethash key seen)
            (setq searching nil)
          (puthash key t seen)
          (let ((names (tired--directory-names current)))
            (if (/= 1 (length names))
                (setq searching nil)
              (let ((entry (tired--make-entry current (car names))))
                (if (tired-entry-dirp entry)
                    (setq current (tired-entry-path entry))
                  (setq result entry
                        searching nil))))))))
    result))

(defun tired--collapsed-file (directory)
  "Return the cached chain result for DIRECTORY, or nil."
  (let* ((key (directory-file-name (expand-file-name directory)))
         (cached (and (hash-table-p tired--collapse-cache)
                      (gethash key tired--collapse-cache 'missing))))
    (if (not (eq cached 'missing))
        cached
      (let ((file (tired--single-entry-file key)))
        (when (hash-table-p tired--collapse-cache)
          (puthash key file tired--collapse-cache))
        file))))

(defun tired--collapsed-display-entry (directory entry)
  "Return a display clone for ENTRY when it collapses to one file.
DIRECTORY is the listed parent and provides the relative name.  The
result is nil when ENTRY is not a directory or does not collapse."
  (when (and tired-collapse-single-child
             (tired-entry-dirp entry))
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
directory seen twice through symlinks appears once.  A directory that
leads to exactly one file collapses into one row for that file,
keeping the directory's sort position."
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
                        (sections (and (not collapsed)
                                       (not (tired--directory-entry-p entry))
                                       (tired--expanded-p
                                        (tired-entry-path entry))
                                       (tired--section-rows display depth)))
                        (name-visible (tired--name-visible-p display))
                        (shown (cond
                                ((not visible-only) sections)
                                ((not (tired--in-narrow-p display)) nil)
                                (name-visible sections)
                                (t (seq-filter
                                    (lambda (row)
                                      (tired--section-visible-p (car row)))
                                    sections)))))
                   (when (or (not visible-only)
                             (and (tired--in-narrow-p display)
                                  (or name-visible shown)))
                     (push (cons display depth) rows))
                   (dolist (row shown)
                     (push row rows))
                   (when (and (not collapsed)
                              (tired--directory-entry-p entry)
                              (tired--inserted-p
                               (tired-entry-path entry)))
                     (walk (tired-entry-path entry) (1+ depth)))))))))
      (walk tired--directory 0))
    (nreverse rows)))

(defun tired--visible-entries ()
  "Return the entries that are currently shown, in display order.
Section rows are not entries, so they stay out of the result."
  (seq-filter #'tired-entry-p (mapcar #'car (tired--display-rows t))))

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
with the face the file takes on its own row.  A symbolic link keeps
its target arrow."
  (let* ((name (tired-entry-name entry))
         (file (file-name-nondirectory name))
         (head (string-remove-suffix file name)))
    (concat (tired--propertize-name head 'tired-directory-face)
            (tired--propertize-name file (tired--name-face entry file)
                                    (tired--entry-name-spans entry file))
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
          (tired--display-rows t)))

(defun tired--column-label (label key)
  "Return LABEL with a direction indicator when KEY is the sort key."
  (if (eq key tired--sort-key)
      (concat label (if tired--sort-flip " v" " ^"))
    label))

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
      (dolist (row (tired--display-rows t))
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

(defun tired--header-title ()
  "Return the directory title shown in the header line."
  (concat (abbreviate-file-name tired--directory)
          (when tired--narrowed
            "  [narrowed]")
          (when tired--filter
            (format "  [filter: %s]" tired--filter))
          (when tired--hide-dotfiles
            "  [dotfiles hidden]")))

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
    (when tired--filter
      (push (format "filter: %s" tired--filter) parts))
    (unless tired-collapse-single-child
      (push "no collapse" parts))
    (unless tired-auto-revert
      (push "auto-revert off" parts))
    (if parts
        (concat " [" (string-join (nreverse parts) ", ") "]")
      "")))

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

(defun tired--watch-paths ()
  "Return the paths that need a file notification watch.
The root directory is always watched.  Inserted directories join the
list.  Collapsed directories stay unwatched, so their changes arrive
with the next explicit refresh.  Every expanded file joins as well,
because a directory watch does not report an edit to a file inside
that directory."
  (append (list (directory-file-name (expand-file-name tired--directory)))
          (and (hash-table-p tired--inserted)
               (hash-table-keys tired--inserted))
          (and (hash-table-p tired--expanded)
               (hash-table-keys tired--expanded))))

(defun tired--stop-watching ()
  "Cancel the debounce timer and remove every file notification watch."
  (when (timerp tired--revert-timer)
    (cancel-timer tired--revert-timer)
    (setq tired--revert-timer nil))
  (dolist (watch tired--watches)
    (ignore-errors (file-notify-rm-watch (cdr watch))))
  (setq tired--watches nil))

(defun tired--sync-watches ()
  "Add missing watches and remove watches for vanished paths."
  (if (not tired-auto-revert)
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
      (when (and tired-auto-revert
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
  (force-mode-line-update)
  (message "Auto-revert %s" (if tired-auto-revert "on" "off")))

(defun tired--point-row (window)
  "Return the row at the point of WINDOW.
The window point wins when WINDOW is not the selected window, because
the buffer point of a window that lost the selection lags behind."
  (if (and (window-live-p window)
           (not (eq window (selected-window)))
           (eq (window-buffer window) (current-buffer)))
      (tired--row-at (window-point window))
    (tired--row-at-point)))

(defun tired--window-rows ()
  "Return one (WINDOW . ROW) pair per window that shows the listing.
ROW is the row at that window's point, or nil when the window sits on
a line without a row."
  (let (pairs)
    (dolist (window (get-buffer-window-list nil t))
      (push (cons window (tired--row-at (window-point window))) pairs))
    (nreverse pairs)))

(defun tired--restore-window-rows (pairs)
  "Move each window in PAIRS back to the row it showed before a reprint.
`tabulated-list-print' erases the buffer, and that erase collapses the
point marker of every window that shows the listing, so a window that
lost the selection would return to the first line.  A window whose row
vanished keeps its own point."
  (dolist (pair pairs)
    (let ((window (car pair))
          (row (cdr pair)))
      (when (and (window-live-p window)
                 (eq (window-buffer window) (current-buffer))
                 row)
        (save-excursion
          (when (tired--goto-row row)
            (set-window-point window (point))))))))

(defun tired--redraw (&optional window)
  "Redraw the listing from the cached entries.
WINDOW is the window that shows the buffer, or nil for the selected
window.  Its width limits the name column.  The redraw keeps the
point of every window that shows the listing."
  (let* ((window (or window (selected-window)))
         (point-entry (tired--point-row window))
         (mark-entry (tired--row-at (mark t)))
         (window-rows (tired--window-rows)))
    (setq tabulated-list-format
          (tired--format (tired--name-column-width window)))
    (tabulated-list-init-header)
    (setq tired--header-base header-line-format)
    (setq header-line-format
          (list (propertize (tired--header-title) 'face 'bold)
                "  "
                tired--header-base))
    (tabulated-list-print t)
    (tired--goto-entry point-entry)
    (tired--restore-window-rows window-rows)
    (tired--restore-mark mark-entry)
    (tired--apply-selection-overlays)
    (tired--sync-watches)
    (force-mode-line-update)))

(defun tired--window-size-changed (frame)
  "Redraw Tired listings in the windows of FRAME.
A resize changes the space available to the name column."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'tired-mode)
                 tired--directory)
        (tired--redraw window)))))

(add-hook 'window-size-change-functions #'tired--window-size-changed)

(defun tired--forget-inserted (directory)
  "Remove DIRECTORY and its inserted descendants from the listing."
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
      (remhash other tired--tables))))

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
        (tired-refresh))
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

;;;###autoload
(defun tired (directory)
  "Show DIRECTORY in a Tired buffer.
Interactively, offer `default-directory' as the default.  This
command is the short way to open a listing, in the manner of
`dired'."
  (interactive
   (list (read-directory-name "Directory: " nil default-directory t)))
  (pop-to-buffer-same-window (tired-noselect directory)))

;;;###autoload
(defun tired-other-window (directory)
  "Show DIRECTORY in a Tired buffer in another window."
  (interactive
   (list (read-directory-name "Directory: " nil default-directory t)))
  (switch-to-buffer-other-window (tired-noselect directory)))

(defun tired-up-directory ()
  "Open the parent of the current directory."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (tired (file-name-directory (directory-file-name tired--directory))))

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

(defun tired--find-candidates (directory)
  "Return the completion candidates below DIRECTORY.
A candidate holds the name relative to DIRECTORY.  A directory
candidate ends with a slash.  Hidden paths stay out when
`tired--hide-dotfiles' holds.  Symbolic links to directories stay
unfollowed."
  (let* ((base (file-name-as-directory (expand-file-name directory)))
         (hidden-p (lambda (path)
                     (and tired--hide-dotfiles
                          (string-match-p
                           "\\(?:\\`\\|/\\)\\.[^/]"
                           (file-relative-name path base))))))
    (mapcar (lambda (path)
              (let ((name (file-relative-name path base)))
                (if (file-directory-p path)
                    (concat name "/")
                  name)))
            (seq-remove hidden-p
                        (directory-files-recursively
                         base "" t
                         (lambda (subdir)
                           (not (funcall hidden-p subdir))))))))

(defun tired-find-file (&optional other-window)
  "Visit a path below the shown directory, chosen by name.
Completion offers every file and directory in the subtree, so a
partial name with slashes narrows the choice.  Hidden paths stay out
when `tired-hide-dotfiles' holds.  A chosen directory opens as a
Tired buffer.  With OTHER-WINDOW, use another window."
  (interactive "P")
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (let ((candidates (tired--find-candidates tired--directory)))
    (unless candidates
      (user-error "No file below %s"
                  (abbreviate-file-name tired--directory)))
    (let ((path (expand-file-name
                 (completing-read "Find file: " candidates nil t)
                 tired--directory)))
      (cond
       ((file-directory-p path)
        (if other-window (tired-other-window path) (tired path)))
       (other-window (find-file-other-window path))
       (t (find-file path))))))

(defun tired-find-file-other-window ()
  "Visit a path below the shown directory in another window.
Completion works like `tired-find-file'."
  (interactive)
  (tired-find-file t))

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

(defun tired-select-toggle ()
  "Add the entry at point to the selection, or remove it.
Signal a user error on a section row, because a section stands for
its file and a file row already covers that file."
  (interactive)
  (let ((entry (tired--row-at-point)))
    (cond
     ((tired-section-p entry)
      (user-error "A section row is not selectable"))
     ((not (tired-entry-p entry))
      (user-error "No entry at point")))
    (let ((path (tired-entry-path entry)))
      (if (tired--selected-p entry)
          (tired--set-selection (delete path tired--selection))
        (tired--set-selection (cons path tired--selection)))))
  (tired--apply-selection-overlays)
  (force-mode-line-update))

(defun tired-select-toggle-next ()
  "Toggle the selection at point, then move to the next line."
  (interactive)
  (tired-select-toggle)
  (forward-line 1))

(defun tired-select-all ()
  "Select every visible entry."
  (interactive)
  (tired--set-selection
   (mapcar #'tired-entry-path (tired--visible-entries)))
  (tired--apply-selection-overlays)
  (force-mode-line-update))

(defun tired-select-none ()
  "Clear the transient selection."
  (interactive)
  (tired--set-selection nil)
  (tired--apply-selection-overlays)
  (force-mode-line-update))

(defun tired-select-invert ()
  "Invert the selection over the visible entries.
Selected entries outside the visible listing drop out."
  (interactive)
  (tired--set-selection
   (mapcar #'tired-entry-path
           (seq-remove #'tired--selected-p (tired--visible-entries))))
  (tired--apply-selection-overlays)
  (force-mode-line-update))

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

(defun tired--apply-filter (filter)
  "Set `tired--filter' to FILTER and redraw the listing.
An empty FILTER removes the current filter."
  (setq tired--filter (unless (or (null filter) (string-empty-p filter)) filter))
  (tired--redraw))

(defun tired--filter-changed (origin)
  "Apply the current minibuffer text as the filter of ORIGIN.
Read the minibuffer before the switch, because
`minibuffer-contents' returns the text of the current buffer when
that buffer is not a minibuffer."
  (let ((text (minibuffer-contents)))
    (with-current-buffer origin
      (tired--apply-filter text))))

(defun tired-filter ()
  "Narrow the listing while typing a filter.
Every change updates the listing immediately.  \[exit-minibuffer]
keeps the filter, \[keyboard-quit] restores the previous one.  An
empty filter removes it."
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
            (tired--apply-filter result)))
      (quit
       (with-current-buffer origin
         (tired--apply-filter original)
         (tired--goto-entry start))))))

(defun tired-clear-filter ()
  "Remove the name filter."
  (interactive)
  (tired--apply-filter nil))

(defun tired-toggle-dotfiles ()
  "Toggle the display of entries whose name starts with a dot."
  (interactive)
  (setq tired--hide-dotfiles (not tired--hide-dotfiles))
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

(defvar tired--trash-counter 0
  "Counter that makes names inside the session trash unique.")

(defvar tired-trash-directory
  (expand-file-name (format "tired-trash-%d-%d/" (user-uid) (emacs-pid))
                    temporary-file-directory)
  "Directory that holds paths removed during this session.
`tired-delete' moves its targets here.  A copy or a move that
replaces a path puts the old path here first.  `tired-undo' moves
the path back.  The directory lives under the variable
`temporary-file-directory', so the system clears it when the
machine reboots.  Emacs copies the path and then deletes it when
the trash sits on another file system.")

(defvar tired-undo-push-functions nil
  "Abnormal hook that takes every undoable Tired action.
Each function receives DESCRIPTION and FUNCTION.  DESCRIPTION is a
string that names the action.  FUNCTION reverts the action and
takes no argument.  While the hook is empty, Tired keeps the
action on `tired--undo-actions' for `tired-undo'.")

(defvar tired--undo-actions nil
  "Stack of undo actions as (DESCRIPTION . FUNCTION) conses.
The most recent action comes first.")

(defun tired--path-exists-p (path)
  "Return non-nil when PATH exists, including a dangling symbolic link."
  (or (file-exists-p path) (file-symlink-p path)))

(defun tired--trash-name (path)
  "Return an unused name for PATH inside `tired-trash-directory'."
  (let* ((name (file-name-nondirectory (directory-file-name path)))
         (base (expand-file-name name tired-trash-directory))
         (stamp (format-time-string "%Y%m%dT%H%M%S"))
         candidate)
    (while (progn
             (setq tired--trash-counter (1+ tired--trash-counter))
             (setq candidate (format "%s.%s-%d" base stamp tired--trash-counter))
             (tired--path-exists-p candidate)))
    candidate))

(defun tired--trash-move (path)
  "Move PATH into `tired-trash-directory' and return the new path."
  (make-directory tired-trash-directory t)
  (let ((target (tired--trash-name path)))
    (rename-file path target)
    target))

(defun tired--restore-path (trash-path original)
  "Move TRASH-PATH back to ORIGINAL.
Do nothing when TRASH-PATH is gone, or when ORIGINAL exists again.
Return non-nil when the move happened."
  (when (and (tired--path-exists-p trash-path)
             (not (tired--path-exists-p original)))
    (make-directory (file-name-directory original) t)
    (rename-file trash-path original)
    t))

(defun tired--refresh-buffers ()
  "Refresh every live Tired buffer."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'tired-mode) tired--directory)
        (ignore-errors (tired-refresh))))))

(defun tired--push-undo (description function)
  "Hand FUNCTION to the undo stack as the undo of DESCRIPTION.
When `tired-undo-push-functions' is non-nil, those functions take
the action.  Otherwise the action joins `tired--undo-actions'."
  (if tired-undo-push-functions
      (run-hook-with-args 'tired-undo-push-functions description function)
    (push (cons description function) tired--undo-actions))
  description)

(defun tired-undo ()
  "Undo the last file operation of this session.
`tired-undo-push-functions' owns the action when the hook is
non-nil, so the command signals a user error then."
  (interactive)
  (let ((action (pop tired--undo-actions)))
    (unless action
      (user-error "Nothing for Tired to undo"))
    (funcall (cdr action))
    (message "Undid %s" (car action))))

(defun tired--report-operation (description done failures)
  "Announce DONE successes and FAILURES for DESCRIPTION."
  (if (null failures)
      (message "%s %d %s" description done (if (= done 1) "entry" "entries"))
    (display-warning
     'tired
     (concat (format "%s: %d done, %d failed."
                     description done (length failures))
             (mapconcat (lambda (failure)
                          (format "\n  %s: %s" (car failure) (cdr failure)))
                        failures ""))
     :warning)
    (message "%s: %d done, %d failed.  See *Warnings*"
             description done (length failures))))

(defun tired--apply-to-targets (description function)
  "Call FUNCTION with each target path and then clear the selection.
DESCRIPTION names the action.  Deepest paths run first, so a
selection that holds a directory and its children reaches the
children first.  A failure does not stop the remaining targets.
Report the failures and refresh the listing."
  (let ((targets (tired--selection-targets)))
    (unless targets
      (user-error "No entry at point"))
    (setq targets
          (sort (copy-sequence targets)
                (lambda (a b)
                  (> (length (tired-entry-path a))
                     (length (tired-entry-path b))))))
    (let ((done 0)
          (failures nil))
      (dolist (entry targets)
        (let ((path (tired-entry-path entry)))
          (condition-case err
              (progn (funcall function path)
                     (setq done (1+ done)))
            (error (push (cons path (error-message-string err)) failures)))))
      (tired-select-none)
      (tired-refresh)
      (deactivate-mark)
      (tired--report-operation description done (nreverse failures)))))

(defun tired--undo-copy (created trashed)
  "Remove CREATED paths and put TRASHED paths back."
  (dolist (path created)
    (when (tired--path-exists-p path)
      (ignore-errors (tired--trash-move path))))
  (dolist (pair trashed)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (tired--refresh-buffers))

(defun tired--undo-move (moved trashed)
  "Move every MOVED pair back and put TRASHED paths back."
  (dolist (pair moved)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (dolist (pair trashed)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (tired--refresh-buffers))

(defun tired--undo-delete (trashed)
  "Put every TRASHED pair back, parents first."
  (dolist (pair trashed)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (tired--refresh-buffers))

(defun tired--replace-with-trash (path)
  "Move PATH into the session trash and return the new name.
Return nil when PATH is absent."
  (when (tired--path-exists-p path)
    (tired--trash-move path)))

(defun tired-copy (directory)
  "Copy the targets into DIRECTORY.
An existing destination goes to `tired-trash-directory' first, so
`tired-undo' puts it back.  The copy never calls a shell."
  (interactive (list (read-directory-name "Copy targets to: " tired--directory)))
  (let ((destination (file-name-as-directory (expand-file-name directory)))
        (created nil)
        (trashed nil))
    (tired--apply-to-targets
     "Copied"
     (lambda (path)
       (let* ((name (file-name-nondirectory (directory-file-name path)))
              (target (expand-file-name name destination))
              (previous (tired--replace-with-trash target)))
         (when previous
           (push (cons previous target) trashed))
         (condition-case err
             (if (file-directory-p path)
                 (copy-directory path target)
               (copy-file path target))
           (error
            (when previous
              (setq trashed (delete (assoc previous trashed) trashed))
              (ignore-errors (tired--restore-path previous target)))
            (signal (car err) (cdr err))))
         (push target created))))
    (when created
      (tired--push-undo
       (format "copy into %s" (abbreviate-file-name destination))
       (lambda () (tired--undo-copy created trashed))))))

(defun tired-move (destination)
  "Move the targets to DESTINATION.
With one target, DESTINATION is the new full path, unless it names
an existing directory.  With several targets, DESTINATION is a
directory.  An existing destination goes to
`tired-trash-directory' first, so `tired-undo' puts it back.  The
move never calls a shell."
  (interactive
   (let ((targets (tired--selection-targets)))
     (unless targets
       (user-error "No entry at point"))
     (if (null (cdr targets))
         (list (read-file-name
                "Move to: " tired--directory nil nil
                (file-name-nondirectory
                 (directory-file-name (tired-entry-path (car targets))))))
       (list (read-directory-name "Move targets to: " tired--directory)))))
  (let* ((targets (tired--selection-targets))
         (single (null (cdr targets)))
         (destination (expand-file-name destination))
         (full-path (and single
                         (not (file-directory-p destination))
                         (not (directory-name-p destination))
                         destination))
         (directory (file-name-as-directory
                     (or (and full-path (file-name-directory full-path))
                         destination)))
         (moved nil)
         (trashed nil))
    (tired--apply-to-targets
     "Moved"
     (lambda (path)
       (let* ((target (or full-path
                          (expand-file-name
                           (file-name-nondirectory (directory-file-name path))
                           directory)))
              (previous (unless (equal (directory-file-name path)
                                       (directory-file-name target))
                          (tired--replace-with-trash target))))
         (when previous
           (push (cons previous target) trashed))
         (condition-case err
             (unless (equal (directory-file-name path)
                            (directory-file-name target))
               (rename-file path target))
           (error
            (when previous
              (setq trashed (delete (assoc previous trashed) trashed))
              (ignore-errors (tired--restore-path previous target)))
            (signal (car err) (cdr err))))
         (push (cons target path) moved))))
    (when moved
      (tired--push-undo
       (format "move to %s" (abbreviate-file-name directory))
       (lambda () (tired--undo-move moved trashed))))))

(defun tired-delete ()
  "Move the targets into `tired-trash-directory'.
The command asks no question and never calls a shell.  A later
`tired-undo' moves the paths back."
  (interactive)
  (let ((trashed nil))
    (tired--apply-to-targets
     "Deleted"
     (lambda (path)
       (push (cons (tired--trash-move path) path) trashed)))
    (when trashed
      (tired--push-undo
       (format "delete of %d %s" (length trashed)
               (if (= (length trashed) 1) "entry" "entries"))
       (lambda () (tired--undo-delete trashed))))))

(defun tired--creation-directory ()
  "Return the directory that creation commands start from.
The entry at point decides: a directory row starts inside that
directory, every other row starts at the shown directory."
  (let ((entry (tired--row-at-point)))
    (if (and (tired-entry-p entry)
             (file-directory-p (tired-entry-path entry)))
        (file-name-as-directory (tired-entry-path entry))
      tired--directory)))

(defun tired-mkdir (directory)
  "Create DIRECTORY and its parents.
The command asks no confirmation.  A later `tired-undo' removes the
new directory and the parents that it created."
  (interactive
   (list (read-file-name "Create directory: " (tired--creation-directory)
                         nil nil)))
  (let* ((path (directory-file-name (expand-file-name directory)))
         (parent (file-name-directory path))
         (missing nil))
    (when (tired--path-exists-p path)
      (user-error "%s already exists" path))
    (while (and parent (not (file-directory-p parent)))
      (push (directory-file-name parent) missing)
      (setq parent (file-name-directory (directory-file-name parent))))
    (make-directory path t)
    (tired--push-undo
     (format "mkdir %s" (abbreviate-file-name path))
     (lambda ()
       (when (file-directory-p path)
         (tired--trash-move path))
       (dolist (dir (reverse missing))
         (when (and (file-directory-p dir)
                    (null (directory-files dir nil "\\`[^.]")))
           (delete-directory dir)))))
    (tired-refresh)
    (message "Created %s" (abbreviate-file-name path))))

(defun tired-touch (file)
  "Create FILE, or update its modification time when it exists.
The command asks no confirmation.  A later `tired-undo' removes a
created file, or puts the earlier modification time back."
  (interactive
   (list (read-file-name "Create empty file: " (tired--creation-directory)
                         nil nil)))
  (let* ((path (expand-file-name file))
         (exists (tired--path-exists-p path))
         (mtime (and exists
                     (file-regular-p path)
                     (file-attribute-modification-time (file-attributes path)))))
    (when (file-directory-p path)
      (user-error "%s is a directory" path))
    (write-region "" nil path nil 'silent)
    (tired--push-undo
     (format "touch %s" (abbreviate-file-name path))
     (lambda ()
       (cond ((not exists)
              (when (tired--path-exists-p path)
                (tired--trash-move path)))
             (mtime
              (set-file-times path mtime)))))
    (tired-refresh)
    (message "%s %s" (if exists "Touched" "Created")
             (abbreviate-file-name path))))

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

(defun tired-open (&optional other-window)
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

(defun tired-open-other-window ()
  "Visit the target entries in another window."
  (interactive)
  (tired-open t))

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
    (deactivate-mark)
    (message "Browsing %d file%s"
             (length targets)
             (if (= (length targets) 1) "" "s"))))

(defvar-keymap tired-mode-map
  :doc "Local keymap for `tired-mode' buffers."
  :parent tabulated-list-mode-map
  "RET" #'tired-open
  "o" #'tired-open-other-window
  "^" #'tired-up-directory
  "g" #'tired-refresh
  "l" #'tired-refresh
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
  "~" #'tired-select-invert
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
  "D" #'tired-delete
  "+" #'tired-mkdir
  "M-t" #'tired-touch
  "U" #'tired-undo
  "q" #'quit-window
  "<remap> <dired-jump>" #'tired-jump)

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
  (setq-local tabulated-list-padding 0)
  (setq-local tabulated-list-sort-key nil)
  (setq-local revert-buffer-function #'tired--revert)
  (setq-local bookmark-make-record-function #'tired-bookmark-make-record)
  (setq-local mode-line-format
              (append (default-value 'mode-line-format)
                      '((:eval (tired--mode-line))))))

;;; Section handlers

(declare-function org-element-map "org-element"
                  (data types fun &optional info first-match no-recursion
                        with-affiliated no-footnotes))
(declare-function org-element-parse-buffer "org-element"
                  (&optional granularity visible-only))
(declare-function org-element-property "org-element" (property element))
(declare-function org-narrow-to-subtree "org" (&optional arg))
(declare-function treesit-available-p "treesit" nil)
(declare-function treesit-buffer-root-node "treesit" (&optional language))
(declare-function treesit-node-child-by-field-name "treesit"
                  (node field-name))
(declare-function treesit-node-child "treesit" (node n &optional named))
(declare-function treesit-node-children "treesit" (node &optional named))
(declare-function treesit-node-start "treesit" (node))
(declare-function treesit-node-parent "treesit" (node))
(declare-function treesit-node-text "treesit" (node &optional no-propertize))
(declare-function treesit-node-type "treesit" (node))
(declare-function treesit-ready-p "treesit" (language &optional quiet))
(declare-function sqlite-available-p "sqlite.c" nil)
(declare-function sqlite-close "sqlite.c" (db))
(declare-function sqlite-open "sqlite.c" (file &optional readonly disable-uri))
(declare-function sqlite-select "sqlite.c"
                  (db query &optional values return-type))

(defun tired--org-open-heading (section &optional other-window)
  "Visit the org heading of SECTION and narrow to its subtree.
Show the buffer in another window when OTHER-WINDOW is non-nil.
Narrow only when `tired-org-narrow-on-open' is non-nil, the visited
buffer uses Org mode and point sits on a heading.  A narrow that
fails leaves the buffer wide."
  (let ((buffer (tired--visit-section section other-window)))
    (when (and tired-org-narrow-on-open
               (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (derived-mode-p 'org-mode)
          (require 'org)
          (ignore-errors (org-narrow-to-subtree)))))))

(defun tired-file-sections-org (_path)
  "Return the headings of the current org buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Parse with `org-element', so a heading inside a source block or an
example block stays out of the listing.  The line of a heading is
the line of its stars.  Every section carries
`tired--org-open-heading' as its action."
  (require 'org)
  (require 'org-element)
  (delay-mode-hooks (org-mode))
  (org-element-map (org-element-parse-buffer 'headline) 'headline
    (lambda (headline)
      (list :label (or (org-element-property :raw-value headline) "")
            :line (line-number-at-pos (org-element-property :begin headline))
            :level (org-element-property :level headline)
            :kind 'heading
            :action #'tired--org-open-heading))))

(defconst tired--elisp-read-error (make-symbol "tired--read-error")
  "Sentinel that marks a form which `read' rejected.")

(defun tired--elisp-label (form)
  "Return a short label for the top-level FORM, or nil.
The label holds the head symbol plus its first argument when that
argument is a symbol or a quoted symbol."
  (when (consp form)
    (let ((head (car form))
          (argument (cadr form)))
      (cond
       ((not (symbolp head)) nil)
       ((null argument) (symbol-name head))
       ((symbolp argument) (format "%s %s" head argument))
       ((and (consp argument)
             (eq (car argument) 'quote)
             (symbolp (cadr argument)))
        (format "%s %s" head (cadr argument)))
       (t (symbol-name head))))))

(defun tired--elisp-label-spans (form start)
  "Return the source spans of the head and the argument of FORM at START.
The value is a list of one or two (BEG . END) conses for the head
symbol and, when the form names one, its symbol argument.  The value
is nil when FORM does not start with an open paren."
  (when (and (consp form)
             (symbolp (car form))
             (eq (char-after start) ?\())
    (save-excursion
      (goto-char start)
      (forward-char 1)
      (forward-comment (point-max))
      (let ((head-start (point))
            spans)
        (forward-sexp 1)
        (push (cons head-start (point)) spans)
        (forward-comment (point-max))
        (while (memq (char-after) '(?\' ?`))
          (forward-char 1))
        (let ((argument (cadr form)))
          (when (or (and argument (symbolp argument))
                    (and (consp argument)
                         (eq (car argument) 'quote)
                         (symbolp (cadr argument))))
            (let ((argument-start (point)))
              (forward-sexp 1)
              (push (cons argument-start (point)) spans))))
        (nreverse spans)))))

(defun tired--elisp-fontified-label (form start)
  "Return the label of FORM at START with the faces of its source text.
Return nil when FORM carries no label.  Copy the head symbol and the
symbol argument out of the fontified current buffer, so each part keeps
the face that `emacs-lisp-mode' gives it.  Return the plain label when
the source spans do not reproduce it."
  (when-let* ((label (tired--elisp-label form)))
    (let* ((spans (tired--elisp-label-spans form start))
           (pieces (mapcar (lambda (span)
                             (buffer-substring (car span) (cdr span)))
                           spans)))
      (if (and pieces
               (equal (mapconcat #'substring-no-properties pieces " ") label))
          (mapconcat #'identity pieces " ")
        label))))

(defun tired-file-sections-elisp (_path)
  "Return the top-level forms of the current Emacs Lisp buffer.
The buffer already holds the file, so the handler ignores PATH.
Only top-level forms become sections, so a form inside `progn'
stays out.  A form that `read' rejects ends the scan.  Each label
carries the faces that `emacs-lisp-mode' fontification gives its
source text."
  (delay-mode-hooks (emacs-lisp-mode))
  (font-lock-ensure)
  (let (sections)
    (goto-char (point-min))
    (while (progn (forward-comment (point-max)) (not (eobp)))
      (let ((start (point))
            (form (condition-case nil
                      (read (current-buffer))
                    (error tired--elisp-read-error))))
        (if (eq form tired--elisp-read-error)
            (goto-char (point-max))
          (when-let* ((label (tired--elisp-fontified-label form start)))
            (push (list :label label
                        :line (line-number-at-pos start)
                        :level 0
                        :kind (if (string-prefix-p "def"
                                                   (symbol-name (car form)))
                                  'definition
                                'form))
                  sections)))))
    (nreverse sections)))

(defconst tired--rust-section-spec
  '(:language rust
    :mode rust-ts-mode
    :kinds (("function_item" . function)
            ("function_signature_item" . function)
            ("struct_item" . struct)
            ("enum_item" . enum)
            ("union_item" . union)
            ("trait_item" . trait)
            ("impl_item" . impl)
            ("mod_item" . module)
            ("type_item" . type)
            ("const_item" . constant)
            ("static_item" . constant)
            ("macro_definition" . macro))
    :containers ("impl_item" "mod_item" "trait_item")
    :fields ("name" "type"))
  "Tree-sitter section spec for a Rust file.")

(defconst tired--markdown-section-spec
  '(:language markdown
    :mode markdown-ts-mode
    :require markdown-ts-mode
    :kinds (("atx_heading" . heading)
            ("setext_heading" . heading))
    :label tired--markdown-section-label
    :level tired--markdown-section-level)
  "Tree-sitter section spec for a Markdown file.")

(defun tired--treesit-field-text (node fields)
  "Return the text of the first field of NODE that FIELDS names.
Return nil when NODE carries none of the fields."
  (seq-some (lambda (field)
              (when-let* ((child (treesit-node-child-by-field-name
                                  node field)))
                (treesit-node-text child t)))
            fields))

(defun tired--treesit-kind (node spec)
  "Return the section kind that SPEC declares for NODE, or nil."
  (alist-get (treesit-node-type node) (plist-get spec :kinds)
             nil nil #'equal))

(defun tired--treesit-label (node kind spec)
  "Return the label for NODE of KIND under SPEC.
SPEC may name a `:label' function.  Without one, use the first
`:fields' entry that NODE carries and fall back to KIND alone."
  (if-let* ((function (plist-get spec :label)))
      (funcall function node kind)
    (format "%s %s" kind
            (or (tired--treesit-field-text
                 node (or (plist-get spec :fields) '("name")))
                "?"))))

(defun tired--treesit-level (node spec depth)
  "Return the level for NODE under SPEC, or DEPTH.
SPEC may name a `:level' function, so a grammar that spells the level
in a marker node does not rely on the tree depth."
  (if-let* ((function (plist-get spec :level)))
      (funcall function node)
    depth))

(defun tired--treesit-shown-p (node spec)
  "Return non-nil when SPEC shows NODE as a section.
SPEC may name a `:filter' function, which receives NODE and decides
whether NODE appears.  Without one every node of a known kind
appears."
  (let ((filter (plist-get spec :filter)))
    (or (null filter) (funcall filter node))))

(defun tired--treesit-walk (node spec depth)
  "Return the section plists of NODE and its children under SPEC.
DEPTH is the current nesting depth.  A node type listed in
`:containers' raises the depth of its children by one.  A node that
`:filter' rejects yields no section, and its children still walk."
  (let* ((kind (tired--treesit-kind node spec))
         (here (when (and kind (tired--treesit-shown-p node spec))
                 (list (list :label (tired--treesit-label node kind spec)
                             :line (line-number-at-pos
                                    (treesit-node-start node))
                             :level (tired--treesit-level node spec depth)
                             :kind kind))))
         (next-depth (if (member (treesit-node-type node)
                                 (plist-get spec :containers))
                         (1+ depth)
                       depth)))
    (append here
            (mapcan (lambda (child)
                      (tired--treesit-walk child spec next-depth))
                    (treesit-node-children node t)))))

(defun tired--treesit-sections (spec)
  "Return the section plists of the current buffer according to SPEC.
SPEC is a plist with `:language', an optional `:mode', an optional
`:require', `:kinds', optional `:containers', optional `:fields',
optional `:filter', optional `:label' and optional `:level'.  Return
nil when the grammar is missing, so the caller keeps a plain file
row."
  (require 'treesit)
  (let ((language (plist-get spec :language)))
    (when (and (treesit-available-p) (treesit-ready-p language t))
      (when-let* ((library (plist-get spec :require)))
        (require library))
      (when-let* ((mode (plist-get spec :mode)))
        (delay-mode-hooks (funcall mode)))
      (when-let* ((root (treesit-buffer-root-node language)))
        (tired--treesit-walk root spec 0)))))

(defun tired--markdown-section-level (node)
  "Return the heading level of the Markdown NODE.
An ATX heading counts its hash markers.  A setext heading takes
level 1 from an `=' underline and level 2 from any other underline."
  (if (equal (treesit-node-type node) "atx_heading")
      (length (treesit-node-text (treesit-node-child node 0) t))
    (if (seq-some (lambda (child)
                    (equal (treesit-node-type child) "setext_h1_underline"))
                  (treesit-node-children node))
        1
      2)))

(defun tired--markdown-section-label (node _kind)
  "Return the text of the Markdown heading NODE without its marker.
KIND stays unused."
  (let ((content (or (treesit-node-child-by-field-name
                      node "heading_content")
                     node)))
    (string-trim (treesit-node-text content t))))

(defun tired-file-sections-rust (_path)
  "Return the items of the current Rust buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Read functions, structs, enums, traits, impl blocks, modules,
constants and macros through tree-sitter.  Return nil when the
Rust grammar is missing."
  (tired--treesit-sections tired--rust-section-spec))

(defun tired-file-sections-markdown (_path)
  "Return the headings of the current Markdown buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Read ATX and setext headings through tree-sitter, so a heading
inside a fenced code block stays out of the listing.  Return nil
when the Markdown grammar is missing."
  (tired--treesit-sections tired--markdown-section-spec))

(defconst tired--cargo-tables '("features" "dependencies"
                                "dev-dependencies" "build-dependencies")
  "Table names that the Cargo manifest handler lists.
A table with any other name stays out, so `[patch.crates-io]' and
`[target.'cfg(...)'.dependencies]' show no section.")

(defconst tired--cargo-section-spec
  '(:language toml
    :mode toml-ts-mode
    :require toml-ts-mode
    :kinds (("table" . table)
            ("table_array_element" . table)
            ("pair" . dependency))
    :containers ("table" "table_array_element")
    :filter tired--cargo-node-shown-p
    :label tired--cargo-section-label)
  "Tree-sitter section spec for a Cargo manifest.")

(defun tired--toml-unquote (text)
  "Return TEXT without the quotes of a TOML string."
  (if (and (> (length text) 1)
           (memq (aref text 0) '(?\" ?'))
           (eq (aref text 0) (aref text (1- (length text)))))
      (substring text 1 -1)
    text))

(defun tired--toml-key (node)
  "Return the key text of the TOML pair or table NODE.
Strip the quotes of a quoted key, so a quoted crate name reads like
a bare one."
  (when-let* ((child (seq-find (lambda (child)
                                 (member (treesit-node-type child)
                                         '("bare_key" "quoted_key"
                                           "dotted_key")))
                               (treesit-node-children node t))))
    (if (equal (treesit-node-type child) "quoted_key")
        (tired--toml-unquote (treesit-node-text child t))
      (treesit-node-text child t))))

(defun tired--toml-pair-value (node)
  "Return the value node of the TOML pair NODE, or nil."
  (seq-find (lambda (child)
              (not (member (treesit-node-type child)
                           '("bare_key" "quoted_key" "dotted_key"
                             "comment"))))
            (treesit-node-children node t)))

(defun tired--toml-field-text (table name)
  "Return the value text of the pair NAME in the TOML inline table TABLE."
  (when-let* ((pair (seq-find (lambda (child)
                                (and (equal (treesit-node-type child) "pair")
                                     (equal (tired--toml-key child) name)))
                              (treesit-node-children table t))))
    (when-let* ((value (tired--toml-pair-value pair)))
      (treesit-node-text value t))))

(defun tired--cargo-node-shown-p (node)
  "Return non-nil when NODE belongs in a Cargo manifest listing.
Keep the four tables that `tired--cargo-tables' names and the pairs
inside them, so a pair of another table stays out."
  (pcase (treesit-node-type node)
    ((or "table" "table_array_element")
     (member (tired--toml-key node) tired--cargo-tables))
    ("pair"
     (member (tired--toml-key (treesit-node-parent node)) tired--cargo-tables))))

(defun tired--cargo-version (value)
  "Return the version text of the TOML pair VALUE.
VALUE holds either a version string or an inline table with a
`version' key.  Return nil when VALUE names no version."
  (pcase (and value (treesit-node-type value))
    ("string" (tired--toml-unquote (treesit-node-text value t)))
    ("inline_table"
     (when-let* ((text (tired--toml-field-text value "version")))
       (tired--toml-unquote text)))))

(defun tired--cargo-badges (value)
  "Return the badge strings of the TOML pair VALUE.
An inline table with `optional = true' earns `[optional]', and one
with `default-features = false' earns `[no-default]'."
  (when (and value (equal (treesit-node-type value) "inline_table"))
    (delq nil
          (list (when (equal (tired--toml-field-text value "optional") "true")
                  "[optional]")
                (when (equal (tired--toml-field-text value "default-features")
                             "false")
                  "[no-default]")))))

(defun tired--cargo-padded-key (node key)
  "Return KEY padded to the widest sibling key of the TOML pair NODE.
The manifest reads as a table of columns, so the versions line up."
  (let* ((siblings (seq-filter (lambda (child)
                                 (equal (treesit-node-type child) "pair"))
                               (treesit-node-children
                                (treesit-node-parent node) t)))
         (width (seq-max (mapcar (lambda (child)
                                   (length (or (tired--toml-key child) "")))
                                 siblings))))
    (concat key (make-string (max 0 (- width (length key))) ?\s))))

(defun tired--cargo-table-label (node)
  "Return the label of the Cargo table NODE.
The label names the table and counts its entries."
  (format "%s (%d)" (tired--toml-key node)
          (seq-count (lambda (child)
                       (equal (treesit-node-type child) "pair"))
                     (treesit-node-children node t))))

(defun tired--cargo-feature-label (node key)
  "Return the label of the feature NODE under the key KEY.
List the members of the feature, so the row answers what the
feature turns on."
  (let* ((value (tired--toml-pair-value node))
         (members (when (and value (equal (treesit-node-type value) "array"))
                    (mapcar (lambda (child)
                              (tired--toml-unquote
                               (treesit-node-text child t)))
                            (seq-filter (lambda (child)
                                          (equal (treesit-node-type child)
                                                 "string"))
                                        (treesit-node-children value))))))
    (if members
        (format "%s \u2192 %s" key (string-join members ", "))
      key)))

(defun tired--cargo-dependency-label (node key)
  "Return the label of the dependency NODE under the key KEY.
The label holds the crate name, its version and its badges."
  (let* ((value (tired--toml-pair-value node))
         (version (tired--cargo-version value))
         (badges (tired--cargo-badges value)))
    (string-trim (concat (tired--cargo-padded-key node key) " " version
                         (when badges (concat " " (string-join badges " ")))))))

(defun tired--cargo-section-label (node _kind)
  "Return the label of the Cargo manifest NODE.
KIND stays unused, because the parent table decides the label
shape: a pair of `[features]' lists members, and a pair of any
other listed table holds a dependency."
  (if (equal (treesit-node-type node) "pair")
      (let ((key (tired--toml-key node))
            (parent (tired--toml-key (treesit-node-parent node))))
        (if (equal parent "features")
            (tired--cargo-feature-label node key)
          (tired--cargo-dependency-label node key)))
    (tired--cargo-table-label node)))

(defun tired-file-sections-cargo (_path)
  "Return the tables of the current Cargo manifest buffer as sections.
The buffer already holds the file, so the handler ignores PATH.
Read the `features', `dependencies', `dev-dependencies' and
`build-dependencies' tables through tree-sitter, with their entries
one level below.  Return nil when the TOML grammar is missing."
  (tired--treesit-sections tired--cargo-section-spec))

(defun tired--sqlite-column-label (row)
  "Return the label for the `PRAGMA table_info' ROW of one column.
ROW holds the column id, name, declared type, NOT NULL flag, default
value and primary key flag."
  (let ((name (nth 1 row))
        (type (nth 2 row))
        (notnull (nth 3 row))
        (primary (nth 5 row)))
    (concat (if (and type (not (string-empty-p type)))
                (format "%s %s" name type)
              name)
            (if (and notnull (not (zerop notnull))) " NOT NULL" "")
            (if (and primary (not (zerop primary))) " PRIMARY KEY" ""))))

(defun tired--sqlite-open-table (section table &optional _other-window)
  "Show TABLE of the database that SECTION belongs to.
Open the database in `sqlite-mode' and move point to the row of
TABLE.  OTHER-WINDOW stays unused, because `sqlite-mode-open-file'
chooses the window itself."
  (require 'sqlite-mode)
  (sqlite-mode-open-file (tired-section-path section))
  (goto-char (point-min))
  (when (re-search-forward (concat "^" (regexp-quote table) "\\_>") nil t)
    (beginning-of-line)))

(defun tired-file-sections-sqlite (path)
  "Return the tables and columns of the SQLite database at PATH.
The handler uses the built-in `sqlite' support, so it needs no
external tool.  Each table is a section and its columns follow one
level deeper.  A database has no lines, so a section carries a
synthetic ordinal and its action opens the table in `sqlite-mode'.
Return nil when Emacs lacks SQLite support or when PATH holds no
readable database."
  (when (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (condition-case nil
        (let ((db (sqlite-open path t))
              (line 0)
              sections)
          (unwind-protect
              (dolist (row (sqlite-select
                            db
                            (concat "SELECT name FROM sqlite_master "
                                    "WHERE type IN ('table', 'view') "
                                    "AND name NOT LIKE 'sqlite_%' "
                                    "ORDER BY name")))
                (let ((table (car row)))
                  (push (list :label table
                              :line (setq line (1+ line))
                              :level 0
                              :kind 'table
                              :action (cons #'tired--sqlite-open-table
                                            (list table)))
                        sections)
                  (dolist (column (sqlite-select
                                   db (format "PRAGMA table_info(%S)" table)))
                    (push (list :label (tired--sqlite-column-label column)
                                :line (setq line (1+ line))
                                :level 1
                                :kind 'column
                                :action (cons #'tired--sqlite-open-table
                                              (list table)))
                          sections))))
            (sqlite-close db))
          (nreverse sections))
      (error nil))))

;;; Evil integration

;; The definitions below follow `provide', so `(require 'tired)' inside
;; `tired-evil' returns at once instead of loading this file again.

(declare-function tired-evil-mode "tired-evil" (&optional arg))

(defun tired--enable-evil-bindings (&rest _)
  "Turn on `tired-evil-mode' when the evil library is present.
The arguments are ignored, so the function fits
`after-load-functions'.  Evil keeps its state maps in
`emulation-mode-map-alists', and Emacs checks those maps before
`tired-mode-map'.  Evil therefore hides `tired-open' on RET and
every other Tired key.  `tired-evil' binds the same commands
through the evil map machinery, which puts them back."
  (when (and (featurep 'evil)
             (require 'tired-evil nil t))
    (remove-hook 'after-load-functions #'tired--enable-evil-bindings)
    (tired-evil-mode 1)))

;; The hook below runs at the end of this very load too, so a user
;; with evil already loaded takes the bindings at once, and a user who
;; loads Tired first waits for the evil library to arrive.
(add-hook 'after-load-functions #'tired--enable-evil-bindings)

(provide 'tired)

;;; tired.el ends here
