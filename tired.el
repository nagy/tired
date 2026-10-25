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
;; it afterwards.

;;; Code:

(require 'bookmark)
(require 'cl-lib)
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

(defface tired-directory-face
  '((t :inherit font-lock-function-name-face))
  "Face for directory names.")

(defface tired-symlink-face
  '((t :inherit font-lock-variable-name-face))
  "Face for symbolic link names and their targets.")

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
target for symbolic links."
  name
  path
  type
  dirp
  size
  mtime
  mode
  link)

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

(defvar-local tired--narrowed nil
  "List of paths shown exclusively, or nil when the listing is wide.")

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
    (dolist (name (directory-files directory nil nil t))
      (unless (member name '("." ".."))
        (puthash name (tired--make-entry directory name) table)))
    table))

(defun tired--make-entry (directory name)
  "Return a `tired-entry' for NAME inside DIRECTORY."
  (let* ((path (expand-file-name name directory))
         (attributes (file-attributes path)))
    (tired--entry-create
     :name name
     :path path
     :type (pcase (file-attribute-type attributes)
             ('t 'directory)
             ((pred stringp) 'symlink)
             ('nil 'file)
             (_ 'special))
     :dirp (eq t (file-attribute-type attributes))
     :size (file-attribute-size attributes)
     :mtime (float-time (file-attribute-modification-time attributes))
     :mode (file-attribute-modes attributes)
     :link (let ((type (file-attribute-type attributes)))
             (and (stringp type) type)))))

(defun tired--entry-visible-p (entry)
  "Return non-nil when ENTRY passes the narrow, dotfile and name filters."
  (let ((case-fold-search t))
    (and (or (not tired--narrowed)
             (member (tired-entry-path entry) tired--narrowed))
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

(defun tired--name-cell (entry)
  "Return the name column string for ENTRY."
  (pcase (tired-entry-type entry)
    ('directory
     (concat (propertize (tired-entry-name entry) 'face 'tired-directory-face)
             "/"))
    ('symlink
     (concat (propertize (tired-entry-name entry) 'face 'tired-symlink-face)
             " -> "
             (propertize (or (tired-entry-link entry) "?")
                         'face 'tired-symlink-face)))
    (_ (tired-entry-name entry))))

(defun tired--row (entry depth)
  "Return the tabulated list row for ENTRY at DEPTH.
Emacs 31 requires a vector of column descriptors here; a list makes
`tabulated-list-print-entry' signal a type error."
  (vector (concat (make-string (* 2 depth) ?\s)
                  (tired--name-cell entry))
          (if (tired-entry-dirp entry)
              ""
            (file-size-human-readable (tired-entry-size entry)))
          (format-time-string tired-date-format (tired-entry-mtime entry))
          (tired-entry-mode entry)))

(defun tired--tabulated-entries ()
  "Return `tabulated-list-entries' for the current listing."
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

(defun tired--selected-p (entry)
  "Return non-nil when ENTRY is part of the transient selection."
  (and (tired-entry-p entry)
       (member (tired-entry-path entry) tired--selection)))

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
  "Return the selected entries in display order, or the entry at point."
  (let ((selected (tired--selected-entries)))
    (or selected
        (let ((entry (tired--entry-at-point)))
          (when entry (list entry))))))

(defun tired--entry-for-path (path)
  "Return the listed entry for PATH, or nil."
  (let* ((directory (file-name-directory path))
         (table (tired--table directory))
         (entry (and table (gethash (file-name-nondirectory path) table))))
    (and entry (equal (tired-entry-path entry) path) entry)))

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
  (let ((point-entry (tired--entry-at-point)))
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
  (setq tired--selection (tired--prune-selection tired--selection))
  (setq tired--narrowed (tired--prune-selection tired--narrowed))
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
        (setq tired--selection nil))
      (setq tired--directory directory)
      (tired-refresh))
    (if other-window
        (pop-to-buffer buffer '(display-buffer-pop-up-window))
      (pop-to-buffer buffer))
    buffer))

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
      (if (member path tired--selection)
          (setq tired--selection (delete path tired--selection))
        (push path tired--selection))))
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
  (setq tired--selection
        (mapcar #'tired-entry-path (tired--visible-entries)))
  (tired--apply-selection-overlays)
  (force-mode-line-update))

(defun tired-select-none ()
  "Clear the transient selection."
  (interactive)
  (setq tired--selection nil)
  (tired--apply-selection-overlays)
  (force-mode-line-update))

(defun tired-select-invert ()
  "Invert the selection over the visible entries.
Selected entries outside the visible listing drop out."
  (interactive)
  (setq tired--selection
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
  (setq tired--narrowed (tired--narrow-ancestors tired--selection))
  (tired--redraw))

(defun tired-widen ()
  "Show the whole listing again."
  (interactive)
  (setq tired--narrowed nil)
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
        (tired-select-none)))))

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
  (setq-local tired--selection nil)
  (setq-local tired--narrowed nil)
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
