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
;;   s       sort the listing
;;   SPC     toggle selection, then move to the next line
;;   M-SPC   toggle selection of the entry at point
;;   t       select every visible entry
;;   u       clear the selection
;;   f       filter entries by name substring
;;   F       remove the filter
;;   .       toggle hidden entries
;;   y       copy the name of the targets
;;   w       copy the full path of the targets
;;   q       bury the buffer
;;
;; The selection is transient.  It lives only in the buffer, it is
;; pruned when entries disappear, and commands that act on it clear
;; it afterwards.

;;; Code:

(require 'cl-lib)
(require 'hl-line)
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

(defvar-local tired--entries nil
  "Hash table mapping entry names to `tired-entry' structs.")

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

(defvar-local tired--header-base nil
  "Header line string built by `tabulated-list-init-header'.")

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
  "Return non-nil when ENTRY passes the dotfile and name filters."
  (let ((case-fold-search t))
    (and (or (not tired--hide-dotfiles)
             (not (string-prefix-p "." (tired-entry-name entry))))
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

(defun tired--sorted-entries (visible-only)
  "Return all entries in display order.
When VISIBLE-ONLY is non-nil, drop entries hidden by the filter and
the dotfile setting."
  (let (entries)
    (when (hash-table-p tired--entries)
      (maphash (lambda (_name entry)
                 (when (or (not visible-only)
                           (tired--entry-visible-p entry))
                   (push entry entries)))
               tired--entries))
    (sort entries #'tired--lessp)))

(defun tired--visible-entries ()
  "Return the entries that are currently shown, in display order."
  (tired--sorted-entries t))

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

(defun tired--row (entry)
  "Return the tabulated list row for ENTRY.
Emacs 31 requires a vector of column descriptors here; a list makes
`tabulated-list-print-entry' signal a type error."
  (vector (tired--name-cell entry)
          (if (tired-entry-dirp entry)
              ""
            (file-size-human-readable (tired-entry-size entry)))
          (format-time-string tired-date-format (tired-entry-mtime entry))
          (tired-entry-mode entry)))

(defun tired--tabulated-entries ()
  "Return `tabulated-list-entries' for the current listing."
  (mapcar (lambda (entry)
            (list entry (tired--row entry)))
          (tired--visible-entries)))

(defun tired--column-label (label key)
  "Return LABEL with a direction indicator when KEY is the sort key."
  (if (eq key tired--sort-key)
      (concat label (if tired--sort-flip " v" " ^"))
    label))

(defun tired--format ()
  "Return `tabulated-list-format' for the current sort state."
  (vector
   (list (tired--column-label "Name" 'name) 40 nil)
   (list (tired--column-label "Size" 'size) 9 nil :right-align t)
   (list (tired--column-label "Modified" 'modified) 17 nil)
   (list (tired--column-label "Mode" 'mode) 10 nil)))

(defun tired--header-title ()
  "Return the directory title shown in the header line."
  (concat (abbreviate-file-name tired--directory)
          (when tired--filter
            (format "  [filter: %s]" tired--filter))
          (when tired--hide-dotfiles
            "  [dotfiles hidden]")))

(defun tired--mode-line ()
  "Return the `tired-mode' mode line string."
  (concat " ["
          (number-to-string (length tired--selection))
          " selected"
          (when tired--filter
            (format ", filter: %s" tired--filter))
          "]"))

(defun tired--entry-at-point ()
  "Return the entry at point, or nil when there is none."
  (let ((id (tabulated-list-get-id)))
    (and (tired-entry-p id) id)))

(defun tired--selected-p (entry)
  "Return non-nil when ENTRY is part of the transient selection."
  (and (tired-entry-p entry)
       (member (tired-entry-path entry) tired--selection)))

(defun tired--selection-targets ()
  "Return the sorted selected entries, or the entry at point."
  (let ((selected (seq-filter #'tired--selected-p (tired--sorted-entries nil))))
    (or selected
        (let ((entry (tired--entry-at-point)))
          (when entry (list entry))))))

(defun tired--prune-selection (selection)
  "Return SELECTION without paths that are no longer listed."
  (let (result)
    (dolist (path selection)
      (let ((entry (and (hash-table-p tired--entries)
                        (gethash (file-name-nondirectory path) tired--entries))))
        (when (and entry (equal (tired-entry-path entry) path))
          (push path result))))
    (nreverse result)))

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

(defun tired--goto-entry (entry)
  "Move point to the line showing ENTRY, when it is still listed."
  (when (tired-entry-p entry)
    (let ((path (tired-entry-path entry))
          (found nil))
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (let ((current (tired--entry-at-point)))
          (if (and current (equal (tired-entry-path current) path))
              (setq found t)
            (forward-line 1))))
      (unless found
        (goto-char (point-min))))))

(defun tired-refresh ()
  "Reload the listing from disk and redraw the buffer."
  (interactive)
  (unless tired--directory
    (user-error "Not in a tired buffer"))
  (let ((point-entry (tired--entry-at-point)))
    (setq tired--entries (tired--read-entries tired--directory))
    (setq tired--selection (tired--prune-selection tired--selection))
    (setq tabulated-list-format (tired--format))
    (tabulated-list-init-header)
    (setq tired--header-base header-line-format)
    (setq header-line-format
          (list (propertize (tired--header-title) 'face 'bold)
                "  "
                tired--header-base))
    (tabulated-list-print t)
    (tired--goto-entry point-entry)
    (tired--apply-selection-overlays)
    (force-mode-line-update)))

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
  (tired-refresh))

(defun tired-set-filter (filter)
  "Show only entries whose name contains FILTER.
An empty FILTER removes the current filter."
  (interactive (list (read-string "Filter (substring): " tired--filter)))
  (setq tired--filter (unless (string-empty-p filter) filter))
  (tired-refresh))

(defun tired-clear-filter ()
  "Remove the name filter."
  (interactive)
  (setq tired--filter nil)
  (tired-refresh))

(defun tired-toggle-dotfiles ()
  "Toggle the display of entries whose name starts with a dot."
  (interactive)
  (setq tired--hide-dotfiles (not tired--hide-dotfiles))
  (tired-refresh))

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

(defun tired-copy-path ()
  "Copy the full paths of the targets to the kill ring."
  (interactive)
  (let ((targets (tired--selection-targets)))
    (unless targets
      (user-error "No entry at point"))
    (kill-new (mapconcat #'tired-entry-path targets "\n"))
    (message "Copied %d path%s"
             (length targets)
             (if (= (length targets) 1) "" "s"))))

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
  "s" #'tired-sort
  "SPC" #'tired-select-toggle-next
  "M-SPC" #'tired-select-toggle
  "S-SPC" #'tired-select-toggle
  "t" #'tired-select-all
  "u" #'tired-select-none
  "f" #'tired-set-filter
  "F" #'tired-clear-filter
  "." #'tired-toggle-dotfiles
  "y" #'tired-copy-name
  "w" #'tired-copy-path
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
  (setq-local tired--hide-dotfiles tired-hide-dotfiles)
  (setq-local tabulated-list-format (tired--format))
  (setq-local tabulated-list-entries #'tired--tabulated-entries)
  (setq-local tabulated-list-padding 1)
  (setq-local tabulated-list-sort-key nil)
  (setq-local revert-buffer-function #'tired--revert)
  (setq-local mode-line-format
              (append (default-value 'mode-line-format)
                      '((:eval (tired--mode-line)))))
  (when tired-highlight-line
    (hl-line-mode 1)))

(provide 'tired)

;;; tired.el ends here
