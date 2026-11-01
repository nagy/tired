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
          ;; never sees a total that another test computed.  Batch
          ;; Emacs shows no window, so a walk needs the override and
          ;; no budget.
          (tired--size-cache (make-hash-table :test #'equal))
          (tired--size-always t)
          (tired-directory-size-budget nil)
          ;; The element cache and the idle queue are global too.
          ;; Stub the two schedulers, because batch Emacs runs no idle
          ;; timer and a test flushes the queue itself.
          (tired--elements-cache (make-hash-table :test #'equal))
          (tired--elements-queued (make-hash-table :test #'equal))
          (tired--elements-jobs nil)
          (tired--elements-dirty nil)
          (tired--elements-always t)
          (tired-elements-budget nil))
     (cl-letf (((symbol-function 'tired--elements-schedule) #'ignore)
               ((symbol-function 'tired--elements-reprint-schedule)
                #'ignore))
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
             (when (and (string-prefix-p "*Tired Export " (buffer-name))
                        (string-prefix-p root (or default-directory "")))
               (kill-buffer buffer))
             (when (and (derived-mode-p 'tired-mode)
                        tired--directory
                        (string-prefix-p root tired--directory))
               (kill-buffer buffer))))
         (delete-directory root t)))))

(defvar tired-tests--window-shown nil
  "When non-nil, the size gate reads the listing as shown.
Batch Emacs opens a window for `tired', so a test that needs a
hidden listing stubs the gate through
`tired-tests--with-deferred-sizes'.")

(defmacro tired-tests--with-deferred-sizes (&rest body)
  "Run BODY with the size walk gated as a hidden listing gates it.
The walk then waits for a window, as it does in a buffer that no
window shows.  Bind `tired-tests--window-shown' to t for the part of
BODY that acts as the display does."
  (declare (indent 0) (debug t))
  `(let ((tired-tests--window-shown nil)
         (tired--size-always nil)
         (tired-directory-size-budget 0.2))
     (cl-letf (((symbol-function 'tired--size-window-p)
                (lambda () tired-tests--window-shown)))
       ,@body)))

(defun tired-tests--click (type position)
  "Return a mouse click event of TYPE at buffer POSITION.
The event names the selected window, so batch Emacs reads it like a
click on the listing that the window shows."
  (list type (list (selected-window) position)))

(defun tired-tests--names ()
  "Return the names of the visible entries in display order."
  (mapcar #'tired-entry-name (tired--visible-entries)))

(defun tired-tests--header-string ()
  "Return the header line of the current listing as one string.
The printer builds the header from several strings, and the column
labels carry `tabulated-list-column-name', so scan for that
property."
  (or (seq-find (lambda (string)
                  (and (stringp string)
                       (> (length string) 0)
                       (text-property-not-all
                        0 (length string) 'tabulated-list-column-name
                        nil string)))
                (flatten-list header-line-format))
      ""))

(defun tired-tests--click-header (label)
  "Run the header click command of the column named LABEL."
  (let* ((string (tired-tests--header-string))
         (position (string-match (regexp-quote label) string))
         (map (and position (get-text-property position 'keymap string))))
    (unless (keymapp map)
      (error "No header key map on %s" label))
    (call-interactively (lookup-key map [header-line mouse-1]))))

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

(defun tired-tests--edit-name (name new)
  "Replace the editable name NAME with NEW in the current listing.
The listing must hold the name edit mode, so the change reaches the
name cell alone."
  (tired-tests--goto name)
  (let ((region (tired--rename-region)))
    (unless region
      (error "No editable name on %s" name))
    (delete-region (car region) (cdr region))
    (goto-char (car region))
    (insert new)))

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
The region ends at the beginning of the line of LAST, and the row at
point joins the range."
  (transient-mark-mode 1)
  (tired-tests--goto first)
  (beginning-of-line)
  (push-mark (point) t t)
  (tired-tests--goto last)
  (beginning-of-line))

(defun tired-tests--target-names ()
  "Return the names of the current targets."
  (mapcar #'tired-entry-name (tired--selection-targets)))

(defun tired-tests--tar-put (header start text)
  "Copy TEXT into the tar HEADER at START and return HEADER."
  (let ((index 0))
    (while (< index (length text))
      (aset header (+ start index) (aref text index))
      (setq index (1+ index))))
  header)

(defun tired-tests--tar-header (name size type &optional link prefix)
  "Return one 512-byte tar header.
NAME is the member name, SIZE the byte count, and TYPE the type flag.
LINK fills the link field, and PREFIX fills the ustar prefix field."
  (let ((header (make-string 512 ?\0)))
    (tired-tests--tar-put header 0 name)
    (tired-tests--tar-put header 100 "0000644\0")
    (tired-tests--tar-put header 108 "0000000\0")
    (tired-tests--tar-put header 116 "0000000\0")
    (tired-tests--tar-put header 124 (format "%011o\0" size))
    (tired-tests--tar-put header 136 "00000000000\0")
    (tired-tests--tar-put header 148 "        ")
    (aset header 156 type)
    (when link (tired-tests--tar-put header 157 link))
    (tired-tests--tar-put header 257 "ustar\0")
    (tired-tests--tar-put header 263 "00")
    (tired-tests--tar-put header 265 "tester")
    (tired-tests--tar-put header 297 "tester")
    (when prefix (tired-tests--tar-put header 345 prefix))
    header))

(defun tired-tests--tar-member (name content &optional type link)
  "Return the header and the data blocks of one tar member.
NAME is the member name, CONTENT the text, TYPE the type flag and
LINK the link target."
  (let ((type (or type ?0))
        (content (or content ""))
        (padded (* 512 (/ (+ (length content) 511) 512))))
    (concat (tired-tests--tar-header name (length content) type link)
            content
            (make-string (- padded (length content)) ?\0))))

(defun tired-tests--tar-bytes (&rest members)
  "Return the bytes of a tar archive that holds MEMBERS.
Each member is a list of NAME, CONTENT and the optional TYPE and LINK."
  (concat (mapconcat (lambda (member)
                       (apply #'tired-tests--tar-member member))
                     members "")
          (make-string 1024 ?\0)))

(defun tired-tests--tar-write-to (archive &rest members)
  "Write a tar archive at ARCHIVE from MEMBERS.
A `.gz' or `.zst' suffix compresses the archive with the matching
program, so a test needs that program."
  (let ((plain (concat archive ".plain.tar")))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (apply #'tired-tests--tar-bytes members))
      (write-region (point-min) (point-max) plain))
    (if (string-suffix-p ".tar" archive)
        (rename-file plain archive)
      (let ((program (if (string-suffix-p ".gz" archive) "gzip" "zstd")))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (call-process program nil t nil "-c" plain)
          ;; Write the compressed bytes as they are, so the jka-compr
          ;; handler does not compress the archive a second time.
          (let ((file-name-handler-alist nil)
                (coding-system-for-write 'no-conversion))
            (write-region (point-min) (point-max) archive)))
        (delete-file plain)))))

(defmacro tired-tests--tar-write (name &rest members)
  "Write a tar archive called NAME inside `root' from MEMBERS.
Each member is a list of NAME, CONTENT and the optional TYPE and LINK."
  (declare (indent 1) (debug t))
  `(tired-tests--tar-write-to (expand-file-name ,name root) ,@members))

(defun tired-tests--pax-record (key value)
  "Return one pax extended header record for KEY and VALUE.
The record starts with its own decimal length."
  (let* ((body (concat " " key "=" value "\n"))
         (length (+ (length body) 1)))
    (while (/= length (+ (length body) (length (number-to-string length))))
      (setq length (+ (length body) (length (number-to-string length)))))
    (concat (number-to-string length) body)))

(provide 'tired-tests)

(provide 'tired-tests-fixtures)

;;; tired-tests-fixtures.el ends here
