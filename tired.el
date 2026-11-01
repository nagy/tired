;;; tired.el --- Tabulated list directory editor  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; URL: https://github.com/nagy/tired
;; Version: 0.1.0
;; Keywords: files convenience
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
;;   i       insert the children of the directory at point
;;   TAB     insert, expand or fold the subtree at point
;;   e       expand the sections of the file at point
;;   E       collapse the sections of the file at point
;;   j       visit the entry at point, like RET
;;   J       the same, in another window
;;   M-i     remove the inserted children of the directory at point
;;   s       sort the listing
;;   SPC     toggle selection, then move to the next line
;;   M-SPC   toggle selection of the entry at point
;;   t       toggle the selection of every visible entry
;;   u       clear the selection
;;   ~       show or hide the entries that a regexp hides
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
;;   !       run a shell command on the targets
;;   +       create a directory
;;   M-t     create an empty file
;;   U       undo the last file operation
;;   q       bury the buffer
;;
;; Related commands:
;;
;;   M-x tired-jump  visit the directory of the current buffer
;;
;; Export commands:
;;
;;   M-x tired-export-csv   the four listing columns as CSV
;;   M-x tired-export-text  the view with a relative path on every line
;;   M-x tired-export-json  the array that `rclone lsjson' prints
;;
;; An export reads the selection, then the active region, then the
;; whole visible view, and writes a read-only buffer.  Section rows
;; stay out, because a section is not a file.
;;
;; The mode sets `bookmark-make-record-function', so `bookmark-set'
;; records a Tired buffer and `bookmark-jump' restores it.
;;
;; The selection is transient.  It lives only in the buffer, it is
;; pruned when entries disappear, and a command that acts on files
;; clears it afterwards.  An active region joins it: mark a row, move
;; with S-<down> or the mouse, and every row in between becomes a
;; selection before the command acts, so one source feeds copy,
;; delete, move, the shell command and the view commands.  A
;; non-empty selection wins over the region, and `u' clears both.
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

(require 'tired-core)
(require 'tired-sections)
(require 'tired-file-ops)
(require 'tired-export)

(declare-function recentf-add-file "recentf" (filename))

;;; Entry points

;; The autoload cookies live here, not in the libraries they call, so a
;; `package.el' install loads every library before the first command
;; runs.  A cookie in `tired-core' would generate an autoload that
;; loads that file alone, and then `tired-file-handlers' would name a
;; void section handler and the file commands would signal.

;;;###autoload
(autoload 'tired-undo "tired-file-ops"
  "Reverse the last Tired file operation." t)

(defun tired--buffer-name (directory)
  "Return the Tired buffer name for DIRECTORY."
  (format "Tired: %s" (abbreviate-file-name directory)))

;;;###autoload
(defun tired-noselect (directory)
  "Return a Tired buffer for DIRECTORY, without selecting it.
The buffer name depends on DIRECTORY, so a second call reuses the
same buffer.  The buffer gets DIRECTORY as `default-directory' and
as `list-buffers-directory', so `list-buffers' names the directory
in its file column."
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
        ;; A Tired buffer visits no file, so `list-buffers' reads this
        ;; variable for its file column.
        (setq list-buffers-directory directory)
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
Select the window that `display-buffer' chose, so `tired-jump' can
move point in the listing after the call.  The command returns the
buffer, as `dired' does, also when ACTION picks no window.  A value
that is not a cons cell becomes a one-element function list, for
`display-buffer' reads such a value as a request for another
window."
  (let ((window (display-buffer buffer
                                (if (consp action)
                                    action
                                  (list action)))))
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
Select the Tired window, the way `dired-other-window' does.  When
the command must split the current window, the user options
`split-height-threshold' and `split-width-threshold' decide whether
the split runs horizontally or vertically."
  (interactive
   (list (read-directory-name "Directory: " nil default-directory t)))
  (switch-to-buffer-other-window (tired-noselect directory)))

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

;;; Evil integration

;; The definitions below follow `provide', so `(require 'tired)' inside
;; `tired-evil' returns at once instead of loading this file again.

(declare-function tired-evil-mode "tired-evil" (&optional arg))

(defun tired--enable-evil-bindings (&rest _)
  "Turn on `tired-evil-mode' when the evil library is present.
The arguments are ignored, so the function fits
`after-load-functions'.  Evil keeps its state maps in
`emulation-mode-map-alists', and Emacs checks those maps before
`tired-mode-map'.  Evil therefore hides `tired-find-file' on RET and
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
