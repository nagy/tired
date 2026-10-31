;;; tired-tests-fixtures.el --- Shared ERT fixtures and helpers for Tired  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

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

;; Shared fixtures, helpers and setup for the Tired ERT suites.
;; Every test builds its own directory tree under a temporary
;; directory, so no test depends on the state of the working tree.
;;
;; The suite splits like the library: `tired-tests-core' tests the
;; listing, `tired-tests-sections' the file section handlers,
;; `tired-tests-file-ops' the file and shell commands, and
;; `tired-tests-evil' the evil bindings.  `tired-tests' loads them
;; all.

;;; Code:

(require 'ert)
(require 'seq)
(require 'tired)

(declare-function treesit-ready-p "treesit" (language &optional quiet))

;; Keep unrelated tests free of real file notification watches and
;; pending timers.  The auto-revert tests bind this to t themselves.
(setq tired-auto-revert nil)

;; The Nix check passes the directory that holds the tree-sitter
;; grammars.  A developer machine without the Rust grammar skips the
;; Rust test instead of failing.
(let ((directory (getenv "TREESIT_EXTRA_LOAD_PATH")))
  (when (and directory (locate-library "treesit"))
    (require 'treesit)
    (setq treesit-extra-load-path
          (cons directory treesit-extra-load-path))))

(defmacro tired-tests--with-fixture (&rest body)
  "Run BODY inside a fresh directory that holds test entries.
The variable `root' is bound to the temporary directory.  The
fixture contains a subdirectory, regular files, a hidden file and
a symlink, and removes every Tired buffer it opened."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "tired-tests-" t)))
          (default-directory root)
          ;; The size table is global.  Bind a private one, so a test
          ;; never sees a total that another test computed.
          (tired--size-cache (make-hash-table :test #'equal)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "alpha.txt") (insert "abc"))
           (with-temp-file (expand-file-name "beta.txt")
             (insert (make-string 40 ?x)))
           (with-temp-file (expand-file-name ".hidden") (insert "h"))
           (make-directory (expand-file-name "sub/deep") t)
           (with-temp-file (expand-file-name "sub/inner.txt")
             (insert "inner"))
           (with-temp-file (expand-file-name "sub/deep/leaf.txt")
             (insert "leaf"))
           (make-symbolic-link "alpha.txt" (expand-file-name "link"))
           ;; A directory symlink that points back at the root.  The
           ;; listing guard must not recurse through it.
           (make-symbolic-link root (expand-file-name "sub/loop"))
           ,@body)
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (and (derived-mode-p 'tired-mode)
                      tired--directory
                      (string-prefix-p root tired--directory))
             (kill-buffer buffer))))
       (delete-directory root t))))
(defun tired-tests--names ()
  "Return the names of the visible entries in display order."
  (mapcar #'tired-entry-name (tired--visible-entries)))
(defun tired-tests--goto (name)
  "Move point to the line whose entry is NAME."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (let ((entry (tired--row-at-point)))
        (if (and (tired-entry-p entry)
                 (equal (tired-entry-name entry) name))
            (setq found t)
          (forward-line 1))))
    (unless found
      (error "Entry not listed: %s" name))))
(defun tired-tests--goto-section (label)
  "Move point to the section row whose label is LABEL."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (let ((row (tired--row-at-point)))
        (if (and (tired-section-p row)
                 (equal (tired-section-label row) label))
            (setq found t)
          (forward-line 1))))
    (unless found
      (error "Section not listed: %s" label))))
(defun tired-tests--sections ()
  "Return (LABEL . DEPTH) conses for the section rows in the listing."
  (delq nil
        (mapcar (lambda (row)
                  (let ((entry (car row)))
                    (when (tired-section-p entry)
                      (cons (tired-section-label entry) (cdr row)))))
                (tired--display-rows t))))
(defmacro tired-tests--write (name content)
  "Write CONTENT to NAME inside `root'."
  (declare (indent 1) (debug t))
  `(with-temp-file (expand-file-name ,name root)
     (insert ,content)))
(defun tired-tests--entry (name)
  "Return the listed entry called NAME."
  (seq-find (lambda (entry)
              (equal (tired-entry-name entry) name))
            (tired--sorted-directory-entries tired--directory nil)))
(defmacro tired-tests--with-trash (&rest body)
  "Run BODY with a private trash directory and an empty undo stack."
  (declare (indent 0) (debug t))
  `(let ((tired-trash-directory
          (file-name-as-directory (make-temp-file "tired-tests-trash-" t)))
         (tired-undo-push-functions nil)
         (tired--undo-actions nil)
         (tired--trash-counter 0))
     (unwind-protect
         (progn ,@body)
       (delete-directory tired-trash-directory t))))
(defun tired-tests--trash-entries ()
  "Return the names inside `tired-trash-directory'."
  (directory-files tired-trash-directory nil "\\`[^.]"))
(defun tired-tests--contents (path)
  "Return the text inside PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))
(defmacro tired-tests--with-other-window (directory &rest body)
  "Show DIRECTORY in another window and run BODY.
The selected window keeps the current buffer.  The window is
deleted afterwards."
  (declare (indent 1) (debug t))
  (let ((window (make-symbol "window"))
        (other (make-symbol "other")))
    `(let* ((,window (selected-window))
            (,other (split-window)))
       (unwind-protect
           (progn
             (set-window-buffer ,other (tired-noselect ,directory))
             (select-window ,window)
             ,@body)
         (delete-window ,other)))))
(defun tired-tests--shell-run (command)
  "Run `tired-do-shell-command' with COMMAND and report what it did.
Return a cons of the shell command lines, in call order, and the
number of `tired-refresh' calls."
  (let ((lines nil)
        (refreshes 0))
    (cl-letf (((symbol-function 'shell-command)
               (lambda (line &optional _buffer _error) (push line lines)))
              ((symbol-function 'tired-refresh)
               (lambda (&rest _) (setq refreshes (1+ refreshes)))))
      (tired-do-shell-command command))
    (cons (nreverse lines) refreshes)))
(defun tired-tests--shell-mark-fills (command text)
  "Return COMMAND with each substitution mark replaced by TEXT."
  (tired--shell-fill-marks command text))
(defun tired-tests--cell-face (entry)
  "Return the face of the name column of ENTRY."
  (get-text-property 0 'face (tired--name-cell entry)))
(defun tired-tests--mark-row-range (first last)
  "Activate a region that covers the rows FIRST through LAST.
The region ends at the beginning of the row after LAST, so LAST
joins the range."
  (transient-mark-mode 1)
  (tired-tests--goto first)
  (beginning-of-line)
  (push-mark (point) t t)
  (tired-tests--goto last)
  (forward-line 1)
  (beginning-of-line))
(defun tired-tests--target-names ()
  "Return the names of the current targets."
  (mapcar #'tired-entry-name (tired--selection-targets)))
(provide 'tired-tests)

(provide 'tired-tests-fixtures)

;;; tired-tests-fixtures.el ends here
