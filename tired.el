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

;; tired is a directory editor built on `tabulated-list-mode'.  It
;; reads directory contents with Emacs primitives and never parses
;; the output of `ls -l'.
;;
;; Entry point:
;;
;;   M-x tired
;;   M-x tired-find-directory
;;
;; Key bindings in `tired-mode':
;;
;;   RET     visit the entry at point, or every selected file
;;   o       same, in another window
;;   ^       go to the parent directory
;;   g       refresh the listing
;;   l       refresh the listing, including inserted sections
;;   i       insert the children of the directory at point
;;   TAB     toggle insertion of the directory at point
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
;; records a tired buffer and `bookmark-jump' restores it.
;;
;; The selection is transient.  It lives only in the buffer, it is
;; pruned when entries disappear, and commands that act on it clear
;; it afterwards.  An active region is a second target source: mark a
;; row, move with S-<down> or the mouse, and every row in between
;; becomes a target.  A non-empty selection wins over the region.
;;
;; File operations act at once, without a confirmation question.
;; Delete moves each path into `tired-trash-directory', and a copy or
;; a move that replaces a path puts the old path there first.  Each
;; command hands an undo function to `tired-undo-push-functions', so a
;; global undo system can own the action.  While that hook is empty,
;; `tired-undo' pops the action from `tired--undo-actions'.

;;; Code:

(require 'bookmark)
(require 'cl-lib)
(require 'dired)
(require 'filenotify)
(require 'hl-line)
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

(defcustom tired-highlight-line t
  "When non-nil, highlight the line at point with `hl-line-mode'."
  :type 'boolean)

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
directory read per directory on every refresh, so the option stays
nil by default."
  :type 'boolean)

(defcustom tired-name-faces nil
  "Alist of (REGEXP . FACE) that colorizes entry names.
The first rule whose REGEXP matches the entry name wins.  A rule
reaches files, symbolic links and special files.  A directory keeps
its own face.  The default is nil, so only the Dired faces colorize
a name."
  :type '(alist :key-type regexp :value-type face))

(defface tired-directory-face
  '((t :inherit dired-directory))
  "Face for directory names.")

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

(cl-defstruct (tired-entry (:constructor tired--entry-create))
  "One entry of a directory listing.
NAME is the file name without its directory.  PATH is the absolute
file name.  TYPE is one of `directory', `file', `symlink' or
`special'.  DIRP is non-nil for real directories only.  SIZE is the
size in bytes.  MTIME is a float time value.  MODE is the permission
string as returned by `file-attribute-modes'.  LINK is the link
target for symbolic links.  BROKEN is non-nil when a symbolic link
does not resolve."
  name
  path
  type
  dirp
  size
  mtime
  mode
  link
  broken)

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

(defun tired--entry-visible-p (entry)
  "Return non-nil when ENTRY passes the narrow, dotfile and name filters."
  (let ((case-fold-search t))
    (and (or (not tired--narrowed)
             (and (hash-table-p tired--narrowed-set)
                  (gethash (tired-entry-path entry) tired--narrowed-set)))
         (or (not tired--hide-dotfiles)
             (not (string-prefix-p "."
                                   (file-name-nondirectory
                                    (tired-entry-name entry)))))
         (or (null tired--filter)
             (string-match-p (regexp-quote tired--filter)
                             (tired-entry-name entry))))))

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
                (file-relative-name (tired-entry-path file) directory))
          clone)))))

(defun tired--display-rows (&optional visible-only)
  "Return (ENTRY . DEPTH) conses for the whole listing.
Children of inserted directories follow the row of their parent and
indent by DEPTH.  With VISIBLE-ONLY, skip hidden, filtered and
narrowed-out entries.  A directory seen twice through symlinks
appears once.  A directory that leads to exactly one file collapses
into one row for that file, keeping the directory's sort position."
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
                        (display (or collapsed entry)))
                   (when (or (not visible-only)
                             (tired--entry-visible-p display))
                     (push (cons display depth) rows))
                   (when (and (not collapsed)
                              (tired-entry-dirp entry)
                              (tired--inserted-p
                               (tired-entry-path entry)))
                     (walk (tired-entry-path entry) (1+ depth)))))))))
      (walk tired--directory 0))
    (nreverse rows)))

(defun tired--visible-entries ()
  "Return the entries that are currently shown, in display order."
  (mapcar #'car (tired--display-rows t)))

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

(defun tired--user-name-face (name)
  "Return the face from the first `tired-name-faces' rule that matches NAME."
  (seq-some (lambda (rule)
              (and (string-match-p (car rule) name) (cdr rule)))
            tired-name-faces))

(defun tired--name-face (entry)
  "Return the face for the name of ENTRY, or nil for a plain name.
The fixed order runs directory, broken link, user rule, ignored
suffix, symbolic link, special file.  The order otherwise follows
`dired-font-lock-keywords'."
  (let ((name (tired-entry-name entry)))
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

(defun tired--propertize-name (name face)
  "Return NAME with FACE applied, or NAME alone when FACE is nil."
  (if face
      (apply #'propertize name (tired--face-properties face))
    name))

(defun tired--name-cell (entry)
  "Return the name column string for ENTRY."
  (let ((name (tired-entry-name entry))
        (face (tired--name-face entry)))
    (pcase (tired-entry-type entry)
      ('directory
       (concat (tired--propertize-name name face) "/"))
      ('symlink
       (concat (tired--propertize-name name face)
               " -> "
               (apply #'propertize
                      (or (tired-entry-link entry) "?")
                      (tired--face-properties
                       (if (tired-entry-broken entry)
                           'tired-broken-symlink-face
                         'tired-symlink-target-face)))))
      (_ (tired--propertize-name name face)))))

(defvar tired--size-cache nil
  "Hash table that maps a truename to the size of a directory subtree.
`tired--directory-total' binds the table for one calculation.")

(defun tired--subtree-size (directory)
  "Return the number of bytes in every regular file under DIRECTORY.
Skip symbolic links, so a link cycle cannot loop.  Store each
visited directory in `tired--size-cache', so one calculation reads a
nested directory once.  An unreadable directory counts as zero."
  (let* ((key (file-truename directory))
         (hit (gethash key tired--size-cache 'tired--miss)))
    (if (not (eq hit 'tired--miss))
        hit
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
        (puthash key total tired--size-cache)
        total))))

(defun tired--directory-total (directory)
  "Return the number of bytes in every regular file under DIRECTORY.
Reuse the cache that `tired--tabulated-entries' binds for one redraw,
or make a cache for this call.  The cache never outlives the redraw,
so a changed file leaves no stale size behind."
  (let ((tired--size-cache (or tired--size-cache
                               (make-hash-table :test #'equal))))
    (tired--subtree-size directory)))

(defun tired--size-cell (entry)
  "Return the size column string for ENTRY."
  (cond
   ((not (tired-entry-dirp entry))
    (file-size-human-readable (tired-entry-size entry)))
   (tired-directory-size
    (file-size-human-readable
     (tired--directory-total (tired-entry-path entry))))
   (t "")))

(defun tired--row (entry depth)
  "Return the tabulated list row for ENTRY at DEPTH.
Emacs 31 requires a vector of column descriptors here; a list makes
`tabulated-list-print-entry' signal a type error."
  (vector (concat (make-string (* 2 depth) ?\s)
                  (tired--name-cell entry))
          (tired--size-cell entry)
          (format-time-string tired-date-format (tired-entry-mtime entry))
          (tired-entry-mode entry)))

(defun tired--tabulated-entries ()
  "Return `tabulated-list-entries' for the current listing.
When `tired-directory-size' is non-nil, one memo table serves every
row of the redraw, so a nested directory costs one read, not one
read per ancestor."
  (let ((tired--size-cache (and tired-directory-size
                                (make-hash-table :test #'equal))))
    (mapcar (lambda (row)
              (list (car row) (tired--row (car row) (cdr row))))
            (tired--display-rows t))))

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
                      (string-width (tired--name-cell (car row))))))))
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
  "Return the `tired-mode' mode line string."
  (concat " ["
          (if tired--selection
              (format "%d selected, %s"
                      (length tired--selection)
                      (file-size-human-readable (tired--selection-size)))
            "0 selected")
          (when (and (null tired--selection) (use-region-p))
            (format ", %d in region" (length (tired--region-entries))))
          (when tired--narrowed
            ", narrowed")
          (when (and (hash-table-p tired--inserted)
                     (> (hash-table-count tired--inserted) 0))
            (format ", %d inserted" (hash-table-count tired--inserted)))
          (when tired--filter
            (format ", filter: %s" tired--filter))
          (unless tired-collapse-single-child
            ", no collapse")
          (unless tired-auto-revert
            ", auto-revert off")
          "]"))

(defun tired--entry-at-point ()
  "Return the entry at point, or nil when there is none."
  (let ((id (tabulated-list-get-id)))
    (and (tired-entry-p id) id)))

(defun tired--entry-at (position)
  "Return the entry on the line at POSITION, or nil."
  (when position
    (save-excursion
      (goto-char position)
      (tired--entry-at-point))))

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
the entry at point."
  (or (tired--selected-entries)
      (tired--region-entries)
      (let ((entry (tired--entry-at-point)))
        (when entry (list entry)))))

(defun tired--region-entries ()
  "Return the entries inside the active region, or nil.
The row on which the region ends does not join, because the region
ends at the beginning of that line."
  (when (use-region-p)
    (let ((end (region-end))
          entries)
      (save-excursion
        (goto-char (region-beginning))
        (beginning-of-line)
        (while (and (not (eobp))
                    (< (line-beginning-position) end))
          (let ((entry (tired--entry-at-point)))
            (when entry (push entry entries)))
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
      (when (tired--selected-p (tired--entry-at-point))
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
        (let ((entry (tired--entry-at-point)))
          (if (and entry (equal (tired-entry-path entry) path))
              (setq found t)
            (forward-line 1))))
      (unless found
        (goto-char (point-min)))
      found)))

(defun tired--goto-entry (entry)
  "Move point to the line showing ENTRY, when it is still listed."
  (when (tired-entry-p entry)
    (tired--goto-path (tired-entry-path entry))))

(defun tired--restore-mark (entry)
  "Put the mark back on the row of ENTRY, when the listing shows it.
Keep the region active, or inactive, as it was before the redraw."
  (when (and entry
             (marker-position (mark-marker)))
    (save-excursion
      (when (tired--goto-path (tired-entry-path entry))
        (set-marker (mark-marker) (point) (current-buffer))))))

(defun tired--watch-directories ()
  "Return the directories that need a file notification watch.
The root directory is always watched.  Inserted directories join the
list.  Collapsed directories stay unwatched, so their changes arrive
with the next explicit refresh."
  (cons (directory-file-name (expand-file-name tired--directory))
        (when (hash-table-p tired--inserted)
          (hash-table-keys tired--inserted))))

(defun tired--stop-watching ()
  "Cancel the debounce timer and remove every file notification watch."
  (when (timerp tired--revert-timer)
    (cancel-timer tired--revert-timer)
    (setq tired--revert-timer nil))
  (dolist (watch tired--watches)
    (ignore-errors (file-notify-rm-watch (cdr watch))))
  (setq tired--watches nil))

(defun tired--sync-watches ()
  "Add missing watches and remove watches for collapsed directories."
  (if (not tired-auto-revert)
      (tired--stop-watching)
    (let ((wanted (tired--watch-directories)))
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

(defun tired--redraw (&optional window)
  "Redraw the listing from the cached entries.
WINDOW is the window that shows the buffer, or nil for the selected
window.  Its width limits the name column."
  (let* ((point-entry (tired--entry-at-point))
         (mark-entry (tired--entry-at (mark t))))
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
    (tired--restore-mark mark-entry)
    (tired--apply-selection-overlays)
    (tired--sync-watches)
    (force-mode-line-update)))

(defun tired--window-size-changed (frame)
  "Redraw tired listings in the windows of FRAME.
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
Drop inserted directories that no longer exist."
  (setq tired--tables (make-hash-table :test #'equal))
  (setq tired--collapse-cache (make-hash-table :test #'equal))
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
      (tired--forget-inserted directory))))

(defun tired-refresh ()
  "Reload the listing from disk and redraw the buffer."
  (interactive)
  (unless tired--directory
    (user-error "Not in a tired buffer"))
  (tired--reload-tables)
  (tired--set-selection (tired--prune-selection tired--selection))
  (tired--set-narrowed (tired--prune-selection tired--narrowed))
  (tired--redraw))

(defun tired--revert (_ignore-auto _noconfirm)
  "Revert the buffer by refreshing the listing.
IGNORE-AUTO and NOCONFIRM are accepted for `revert-buffer-function'."
  (tired-refresh))

(defun tired--buffer-name (directory)
  "Return the tired buffer name for DIRECTORY."
  (format "tired: %s" (abbreviate-file-name directory)))

;;;###autoload
(defun tired-find-directory (directory &optional other-window)
  "Open DIRECTORY in a tired buffer.
When OTHER-WINDOW is non-nil, show the buffer in another window."
  (interactive (list (read-directory-name "Directory: " nil nil t)))
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (buffer (get-buffer-create (tired--buffer-name directory))))
    (unless (file-directory-p directory)
      (user-error "Not a directory: %s" directory))
    (with-current-buffer buffer
      (unless (derived-mode-p 'tired-mode)
        (tired-mode))
      (unless (equal tired--directory directory)
        (setq tired--inserted (make-hash-table :test #'equal))
        (tired--set-selection nil))
      (setq tired--directory directory)
      (tired-refresh))
    (if other-window
        (pop-to-buffer buffer '(display-buffer-pop-up-window))
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun tired (directory)
  "Show DIRECTORY in a tired buffer.
Interactively, offer `default-directory' as the default.  This
command is the short way to open a listing, in the manner of
`dired'."
  (interactive
   (list (read-directory-name "Directory: " nil default-directory t)))
  (tired-find-directory directory))

(defun tired-up-directory ()
  "Open the parent of the current directory."
  (interactive)
  (unless tired--directory
    (user-error "Not in a tired buffer"))
  (tired-find-directory
   (file-name-directory (directory-file-name tired--directory))))

(defun tired-insert-subdir (&optional directory)
  "Insert the children of DIRECTORY into the listing.
DIRECTORY defaults to the directory at point.  Inserted children
follow their parent row and indent by one level.  Inserting an
already inserted directory changes nothing."
  (interactive)
  (let* ((entry (tired--entry-at-point))
         (directory (or directory
                        (and entry (tired-entry-path entry))
                        (user-error "No entry at point"))))
    (unless (file-directory-p directory)
      (user-error "Not a directory: %s" directory))
    (setq directory (directory-file-name (expand-file-name directory)))
    (puthash directory t tired--inserted)
    (puthash directory (tired--read-entries directory) tired--tables)
    (tired--redraw)))

(defun tired-remove-subdir ()
  "Remove the inserted children of the directory at point."
  (interactive)
  (let ((entry (tired--entry-at-point)))
    (unless (and entry (tired--inserted-p (tired-entry-path entry)))
      (user-error "No inserted directory at point"))
    (tired--forget-inserted (tired-entry-path entry))
    (tired--redraw)))

(defun tired-toggle-subdir ()
  "Insert or remove the children of the directory at point."
  (interactive)
  (let ((entry (tired--entry-at-point)))
    (unless entry
      (user-error "No entry at point"))
    (if (tired--inserted-p (tired-entry-path entry))
        (tired-remove-subdir)
      (tired-insert-subdir))))

;;;###autoload
(defun tired-jump (&optional other-window)
  "Visit the directory of the current buffer in a tired buffer.
In a tired buffer, visit the parent directory and put point on the
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
    (tired-find-directory directory other-window)
    (tired--goto-path anchor)))

(defun tired-bookmark-make-record ()
  "Return a bookmark record for the current tired buffer."
  (list (abbreviate-file-name tired--directory)
        (cons 'handler #'tired-bookmark-jump)
        (cons 'directory tired--directory)))

(defun tired-bookmark-jump (bookmark)
  "Jump to the tired buffer described by BOOKMARK."
  (tired-find-directory (bookmark-prop-get bookmark 'directory)))

(defun tired-select-toggle ()
  "Add the entry at point to the selection, or remove it."
  (interactive)
  (let ((entry (tired--entry-at-point)))
    (unless entry
      (user-error "No entry at point"))
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

(defun tired-filter ()
  "Narrow the listing while typing a filter.
Every change updates the listing immediately.  \[exit-minibuffer]
keeps the filter, \[keyboard-quit] restores the previous one.  An
empty filter removes it."
  (interactive)
  (unless tired--directory
    (user-error "Not in a tired buffer"))
  (let ((origin (current-buffer))
        (original tired--filter))
    (condition-case nil
        (let ((result
               (minibuffer-with-setup-hook
                   (lambda ()
                     (add-hook 'after-change-functions
                               (lambda (&rest _)
                                 (with-current-buffer origin
                                   (tired--apply-filter
                                    (minibuffer-contents))))
                               nil t))
                 (read-string "Filter: " original))))
          (with-current-buffer origin
            (tired--apply-filter result)))
      (quit
       (with-current-buffer origin
         (tired--apply-filter original))))))

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
  "Abnormal hook that takes every undoable tired action.
Each function receives DESCRIPTION and FUNCTION.  DESCRIPTION is a
string that names the action.  FUNCTION reverts the action and
takes no argument.  While the hook is empty, tired keeps the
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
  "Refresh every live tired buffer."
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
      (user-error "Nothing for tired to undo"))
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
  (let ((entry (tired--entry-at-point)))
    (if (and entry (file-directory-p (tired-entry-path entry)))
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

(defun tired--open-entry (entry &optional other-window)
  "Visit ENTRY, in another window when OTHER-WINDOW is non-nil.
Directories, including symlinks to directories, open in a tired
buffer.  All other entry types open with `find-file'."
  (let ((path (tired-entry-path entry)))
    (if (file-directory-p path)
        (tired-find-directory path other-window)
      (if other-window
          (find-file-other-window path)
        (find-file path)))))

(defun tired-open (&optional other-window)
  "Visit the target entries.
Without a selection, visit the entry at point.  Visit every target
in another window when OTHER-WINDOW is non-nil.  The selection is
cleared afterwards."
  (interactive "P")
  (let ((targets (tired--selection-targets))
        (origin (current-buffer)))
    (unless targets
      (user-error "No entry at point"))
    (dolist (entry targets)
      (tired--open-entry entry other-window))
    (when (buffer-live-p origin)
      (with-current-buffer origin
        (tired-select-none)
        (deactivate-mark)))))

(defun tired-open-other-window ()
  "Visit the target entries in another window."
  (interactive)
  (tired-open t))

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
  "q" #'quit-window)

;;;###autoload
(define-derived-mode tired-mode tabulated-list-mode "tired"
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
  (add-hook 'kill-buffer-hook #'tired--stop-watching nil t)
  (setq-local tabulated-list-format (tired--format))
  (setq-local tabulated-list-entries #'tired--tabulated-entries)
  (setq-local tabulated-list-padding 1)
  (setq-local tabulated-list-sort-key nil)
  (setq-local revert-buffer-function #'tired--revert)
  (setq-local bookmark-make-record-function #'tired-bookmark-make-record)
  (setq-local mode-line-format
              (append (default-value 'mode-line-format)
                      '((:eval (tired--mode-line)))))
  (when tired-highlight-line
    (hl-line-mode 1)))

(provide 'tired)

;;; tired.el ends here
