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

(require 'tired-core)
(require 'tired-sections)
(require 'tired-file-ops)

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
