;;; tired-tests.el --- ERT tests for Tired  -*- lexical-binding: t -*-

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

;; ERT tests for tired.  Every test builds its own directory tree
;; under a temporary directory, so the tests do not depend on the
;; state of the working tree.

;;; Code:

(require 'ert)
(require 'seq)
(require 'tired)

(declare-function treesit-ready-p "treesit" (language &optional quiet))
;; `tired-evil-mode' binds keys through the evil library, which stays
;; optional.  The tests below skip themselves when evil is absent.
(declare-function evil-local-mode "evil" (&optional arg))
(declare-function evil-normal-state "evil" nil)
(declare-function evil-visual-line "evil" (&optional count))
(declare-function tired-evil-mode "tired-evil" (&optional arg))
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
          (default-directory root))
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

(ert-deftest tired-mode-is-derived-from-tabulated-list-mode ()
  "The major mode must inherit from `tabulated-list-mode'."
  (tired-tests--with-fixture
    (tired root)
    (should (derived-mode-p 'tired-mode 'tabulated-list-mode))
    (should (equal (tired--buffer-name root) (buffer-name)))))

(ert-deftest tired-noselect-returns-buffer-without-display ()
  "`tired-noselect' returns a buffer and keeps the window layout."
  (tired-tests--with-fixture
    (let ((buffer (tired-noselect root)))
      (should (buffer-live-p buffer))
      (should (equal (tired--buffer-name root) (buffer-name buffer)))
      (should (eq 'tired-mode (buffer-local-value 'major-mode buffer)))
      (should (equal root (buffer-local-value 'default-directory buffer)))
      (should-not (get-buffer-window buffer)))))

(ert-deftest tired-noselect-reuses-its-buffer ()
  "Two calls for one directory return the same buffer."
  (tired-tests--with-fixture
    (should (eq (tired-noselect root) (tired-noselect root)))))

(ert-deftest tired-find-file-mode-toggles-find-directory-functions ()
  "`tired-find-file-mode' adds and removes the finder."
  (should-not tired-find-file-mode)
  (unwind-protect
      (progn
        (should-not (memq #'tired-noselect find-directory-functions))
        (tired-find-file-mode 1)
        (should (memq #'tired-noselect find-directory-functions))
        (tired-find-file-mode -1)
        (should-not (memq #'tired-noselect find-directory-functions)))
    (tired-find-file-mode -1)))

(ert-deftest find-file-opens-a-directory-in-tired-mode ()
  "With the mode on, `find-file' visits a directory with Tired."
  (tired-tests--with-fixture
    (unwind-protect
        (progn
          (tired-find-file-mode 1)
          (should (memq #'tired-noselect find-directory-functions))
          (with-current-buffer (find-file-noselect root)
            (should (derived-mode-p 'tired-mode))
            (should (equal root default-directory))))
      (tired-find-file-mode -1))))

(ert-deftest tired-listing-puts-directories-first ()
  "Directories sort before files, and files sort by name."
  (tired-tests--with-fixture
    (tired root)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "beta.txt" "link")))))

(ert-deftest tired-entries-carry-file-attributes ()
  "Each entry records its type, size and mode."
  (tired-tests--with-fixture
    (tired root)
    (let ((sub (tired-tests--entry "sub"))
          (alpha (tired-tests--entry "alpha.txt"))
          (link (tired-tests--entry "link")))
      (should (eq 'directory (tired-entry-type sub)))
      (should (tired-entry-dirp sub))
      (should (eq 'file (tired-entry-type alpha)))
      (should (= 3 (tired-entry-size alpha)))
      (should (string-prefix-p "-" (tired-entry-mode alpha)))
      (should (eq 'symlink (tired-entry-type link)))
      (should (equal "alpha.txt" (tired-entry-link link)))
      (should-not (tired-entry-dirp link)))))

(ert-deftest tired-toggle-dotfiles-hides-hidden-entries ()
  "Toggling dotfiles removes and restores hidden entries."
  (tired-tests--with-fixture
    (tired root)
    (tired-toggle-dotfiles)
    (should (equal (tired-tests--names)
                   '("sub" "alpha.txt" "beta.txt" "link")))
    (tired-toggle-dotfiles)
    (should (member ".hidden" (tired-tests--names)))))

(ert-deftest tired-sort-by-size-toggles-direction ()
  "Sorting by size orders files by size and flips on repetition."
  (tired-tests--with-fixture
    (tired root)
    (tired-sort 'size)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "link" "beta.txt")))
    (tired-sort 'size)
    (should (equal (tired-tests--names)
                   '("sub" "beta.txt" "link" "alpha.txt" ".hidden")))))

(ert-deftest tired-sort-by-name-keeps-directories-first ()
  "The name sort keeps directories first in both directions."
  (tired-tests--with-fixture
    (tired root)
    (tired-sort 'name)
    (should (equal (car (tired-tests--names)) "sub"))
    (tired-sort 'name)
    (should (equal (car (tired-tests--names)) "sub"))))

(ert-deftest tired-name-column-grows-to-longest-name ()
  "The name column width follows the longest visible entry."
  (tired-tests--with-fixture
    (let ((name (make-string 30 ?n)))
      (with-temp-file (expand-file-name name) (insert "x")))
    (tired root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100)))
      (tired-refresh))
    (should (= 30 (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-name-column-keeps-minimum-width ()
  "Short names do not shrink the name column below the minimum."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100)))
      (tired-refresh))
    (should (= tired-name-column-min-width
               (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-name-column-clamps-to-window ()
  "A long name does not push the other columns off screen."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 80 ?x)) (insert "x"))
    (tired root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 80)))
      (tired-refresh))
    (should (= (- 80 tired--fixed-column-width)
               (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-window-size-change-resizes-name-column ()
  "A window size change updates the name column width."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 60 ?w)) (insert "x"))
    (tired root)
    (let ((width 120))
      (cl-letf (((symbol-function 'window-width) (lambda (&rest _) width)))
        (tired-refresh)
        (should (= 60 (nth 1 (aref tabulated-list-format 0))))
        (setq width 80)
        (tired--window-size-changed (selected-frame))
        (should (= (- 80 tired--fixed-column-width)
                   (nth 1 (aref tabulated-list-format 0))))))))

(ert-deftest tired-filter-matches-case-insensitively ()
  "A filter keeps only matching names."
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "BETA")
    (should (equal (tired-tests--names) '("beta.txt")))
    (tired-clear-filter)
    (should (= 5 (length (tired-tests--names))))))

(ert-deftest tired-filter-command-commits-with-ret ()
  "RET in the live filter keeps the typed value."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "BETA")))
      (tired-filter))
    (should (equal tired--filter "BETA"))
    (should (equal (tired-tests--names) '("beta.txt")))))

(ert-deftest tired-filter-command-restores-on-quit ()
  "C-g in the live filter restores the previous filter."
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "beta")
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (signal 'quit nil))))
      (tired-filter))
    (should (equal tired--filter "beta"))
    (should (equal (tired-tests--names) '("beta.txt")))))

(ert-deftest tired-selection-drives-targets ()
  "Selecting an entry makes it the target of file commands."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (should (equal (mapcar #'tired-entry-name (tired--selection-targets))
                   '("beta.txt")))
    (should (= 1 (length (seq-filter (lambda (overlay)
                                       (overlay-get overlay 'tired-selection))
                                     (overlays-in (point-min) (point-max))))))
    (tired-select-none)
    (should-not tired--selection)
    (should-not (seq-filter (lambda (overlay)
                              (overlay-get overlay 'tired-selection))
                            (overlays-in (point-min) (point-max))))))

(ert-deftest tired-select-all-selects-visible-entries ()
  "Selecting all covers exactly the visible entries."
  (tired-tests--with-fixture
    (tired root)
    (tired-select-all)
    (should (= 5 (length tired--selection)))
    (should (equal (sort (mapcar #'tired-entry-name (tired--selection-targets))
                         #'string<)
                   '(".hidden" "alpha.txt" "beta.txt" "link" "sub")))))

(ert-deftest tired-copy-path-joins-targets ()
  "Copying paths puts one path per line on the kill ring."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-copy-path)
    (should (equal (current-kill 0)
                   (concat (expand-file-name "alpha.txt" root)
                           "\n"
                           (expand-file-name "beta.txt" root))))))

(ert-deftest tired-copy-relative-path-uses-buffer-directory ()
  "Relative copies drop the shown directory prefix."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-copy-relative-path)
    (should (equal (current-kill 0) "alpha.txt\nbeta.txt"))))

(ert-deftest tired-copy-relative-path-handles-inserted-entries ()
  "Relative copies work inside inserted sections."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (tired-copy-relative-path)
    (should (equal (current-kill 0) "sub/inner.txt"))))

(ert-deftest tired-copy-project-path-uses-project-root ()
  "Project copies are relative to the project root."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (cl-letf (((symbol-function 'tired--project-root)
               (lambda () root)))
      (tired-copy-project-path))
    (should (equal (current-kill 0) "alpha.txt"))))

(ert-deftest tired-copy-project-path-without-project-errors ()
  "Project copies signal an error outside a project."
  (tired-tests--with-fixture
    (tired root)
    (require 'project)
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) nil)))
      (should-error (tired-copy-project-path) :type 'user-error))))

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

(ert-deftest tired-copy-file-into-a-directory ()
  "Copy puts a copy of the target file into the destination."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (tired-copy destination)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "abc"))
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" root))
                       "abc"))
        (should-not tired--selection)))))

(ert-deftest tired-copy-directory-recursively ()
  "Copy of a directory keeps its subtree."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "sub")
        (tired-copy destination)
        (should (equal (tired-tests--contents
                        (expand-file-name "sub/inner.txt" destination))
                       "inner"))
        (should (equal (tired-tests--contents
                        (expand-file-name "sub/deep/leaf.txt" destination))
                       "leaf"))))))

(ert-deftest tired-copy-mixed-selection ()
  "Copy handles a selection that mixes files and directories."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (tired-select-toggle)
        (tired-tests--goto "sub")
        (tired-select-toggle)
        (tired-copy destination)
        (should (file-regular-p (expand-file-name "alpha.txt" destination)))
        (should (file-directory-p (expand-file-name "sub" destination)))
        (should-not tired--selection)))))

(ert-deftest tired-copy-overwrite-moves-old-file-to-trash ()
  "Copy puts a replaced destination into the trash and undo restores it."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (with-temp-file (expand-file-name "alpha.txt" destination)
          (insert "old"))
        (tired-tests--goto "alpha.txt")
        (tired-copy destination)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "abc"))
        (should (= 1 (length (tired-tests--trash-entries))))
        (tired-undo)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "old"))
        (should (= 1 (length (tired-tests--trash-entries))))
        (should (equal (tired-tests--contents
                        (expand-file-name
                         (car (tired-tests--trash-entries))
                         tired-trash-directory))
                       "abc"))))))

(ert-deftest tired-move-single-target-renames ()
  "Move with one target reads the destination as the new full path."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "renamed.txt" root)))
        (tired-tests--goto "alpha.txt")
        (tired-move destination)
        (should (file-regular-p destination))
        (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
        (tired-undo)
        (should (file-regular-p (expand-file-name "alpha.txt" root)))
        (should-not (file-exists-p destination))))))

(ert-deftest tired-move-many-targets-into-a-directory ()
  "Move with several targets reads the destination as a directory."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (tired-select-toggle)
        (tired-tests--goto "beta.txt")
        (tired-select-toggle)
        (tired-move destination)
        (should (file-regular-p (expand-file-name "alpha.txt" destination)))
        (should (file-regular-p (expand-file-name "beta.txt" destination)))
        (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
        (tired-undo)
        (should (file-regular-p (expand-file-name "alpha.txt" root)))
        (should (file-regular-p (expand-file-name "beta.txt" root)))
        (should-not (file-exists-p (expand-file-name "alpha.txt" destination)))))))

(ert-deftest tired-move-overwrite-moves-old-file-to-trash ()
  "Move puts a replaced destination into the trash and undo restores it."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (with-temp-file (expand-file-name "alpha.txt" destination)
          (insert "old"))
        (tired-tests--goto "alpha.txt")
        (tired-move (expand-file-name "alpha.txt" destination))
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "abc"))
        (tired-undo)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "old"))
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" root))
                       "abc"))))))

(ert-deftest tired-delete-moves-target-to-trash ()
  "Delete removes the target from the listing and keeps it in the trash."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should (= 1 (length (tired-tests--trash-entries))))
      (should-not (member "alpha.txt" (tired-tests--names)))
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-delete-handles-nested-selection ()
  "Delete removes a directory and its selected child, and undo restores both."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "sub")
      (tired-select-toggle)
      (tired-insert-subdir)
      (tired-tests--goto "inner.txt")
      (tired-select-toggle)
      (tired-delete)
      (should-not (file-exists-p (expand-file-name "sub" root)))
      (should (= 2 (length (tired-tests--trash-entries))))
      (tired-undo)
      (should (equal (tired-tests--contents
                      (expand-file-name "sub/inner.txt" root))
                     "inner"))
      (should (equal (tired-tests--contents
                      (expand-file-name "sub/deep/leaf.txt" root))
                     "leaf")))))

(ert-deftest tired-delete-clears-selection-and-refreshes ()
  "Delete clears the selection and drops the rows of the removed entries."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-select-toggle)
      (tired-tests--goto "beta.txt")
      (tired-select-toggle)
      (tired-delete)
      (should-not tired--selection)
      (should-not (member "alpha.txt" (tired-tests--names)))
      (should-not (member "beta.txt" (tired-tests--names))))))

(ert-deftest tired-delete-reports-partial-failure ()
  "A vanished target does not stop the remaining targets."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-select-toggle)
      (tired-tests--goto "beta.txt")
      (tired-select-toggle)
      (delete-file (expand-file-name "beta.txt" root))
      (let ((reported nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _)
                     (setq reported message))))
          (tired-delete))
        (should (string-match-p "beta\\.txt" reported))
        (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
        (tired-undo)
        (should (file-regular-p (expand-file-name "alpha.txt" root)))))))

(ert-deftest tired-mkdir-creates-a-directory ()
  "mkdir creates the directory and undo removes it again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((path (expand-file-name "fresh/nested" root)))
        (tired-mkdir path)
        (should (file-directory-p path))
        (should (member "fresh" (tired-tests--names)))
        (tired-undo)
        (should-not (file-exists-p (expand-file-name "fresh" root)))))))

(ert-deftest tired-mkdir-rejects-an-existing-path ()
  "mkdir refuses a path that already exists."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (should-error (tired-mkdir (expand-file-name "alpha.txt" root))
                    :type 'user-error))))

(ert-deftest tired-touch-creates-an-empty-file ()
  "touch creates a file and undo removes it again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((path (expand-file-name "fresh.txt" root)))
        (tired-touch path)
        (should (file-regular-p path))
        (should (equal (tired-tests--contents path) ""))
        (should (member "fresh.txt" (tired-tests--names)))
        (tired-undo)
        (should-not (file-exists-p path))))))

(ert-deftest tired-touch-restores-modification-time-on-undo ()
  "touch undoes the timestamp change of an existing file."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let* ((path (expand-file-name "alpha.txt" root))
             (past (encode-time 0 0 12 1 1 2020)))
        (set-file-times path past)
        (tired-touch path)
        (should (time-less-p past (file-attribute-modification-time
                                   (file-attributes path))))
        (tired-undo)
        (should (time-equal-p
                 (file-attribute-modification-time (file-attributes path))
                 past))))))

(ert-deftest tired-delete-hands-undo-to-the-hook ()
  "A non-nil `tired-undo-push-functions' takes the action."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((captured nil))
        (let ((tired-undo-push-functions
               (list (lambda (description function)
                       (push (cons description function) captured)))))
          (tired-tests--goto "alpha.txt")
          (tired-delete))
        (should-not tired--undo-actions)
        (should (string-match-p "delete" (caar captured)))
        (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
        (funcall (cdar captured))
        (should (file-regular-p (expand-file-name "alpha.txt" root)))))))

(ert-deftest tired-undo-without-actions-errors ()
  "Undo signals a user error when the stack is empty."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (should-error (tired-undo) :type 'user-error))))

(ert-deftest tired-delete-keeps-no-shell-dependency ()
  "Delete moves the target into the trash without a shell command."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "beta.txt")
      (cl-letf (((symbol-function 'shell-command) #'ignore)
                ((symbol-function 'call-process) #'ignore))
        (tired-delete))
      (should-not (file-exists-p (expand-file-name "beta.txt" root)))
      (should (string-prefix-p "beta.txt" (car (tired-tests--trash-entries)))))))


(ert-deftest tired-open-file-visits-the-file ()
  "Opening a file entry visits that file."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-open)
    (should (equal (buffer-file-name) (expand-file-name "alpha.txt" root)))
    (kill-buffer (current-buffer))))

(ert-deftest tired-open-directory-replaces-the-listing ()
  "Opening a directory entry shows it in a Tired buffer."
  (tired-tests--with-fixture
    (tired root)
    (let ((origin (current-buffer)))
      (tired-tests--goto "sub")
      (tired-open)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory
                     (file-name-as-directory (expand-file-name "sub" root))))
      (tired-up-directory)
      (should (eq (current-buffer) origin)))))

(ert-deftest tired-refresh-prunes-deleted-selection ()
  "Refresh drops selected entries that no longer exist."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (delete-file (expand-file-name "beta.txt" root))
    (tired-refresh)
    (should-not tired--selection)
    (should-not (member "beta.txt" (tired-tests--names)))))

(ert-deftest tired-refresh-keeps-sort-and-point ()
  "Refresh keeps the sort order and the entry at point."
  (tired-tests--with-fixture
    (tired root)
    (tired-sort 'size 'reverse)
    (tired-tests--goto "link")
    (tired-refresh)
    (should (equal (tired-entry-name (tired--row-at-point)) "link"))
    (should (eq 'size tired--sort-key))
    (should tired--sort-flip)))

(ert-deftest tired-name-cell-shows-symlink-target ()
  "The name column of a symlink shows its target."
  (tired-tests--with-fixture
    (tired root)
    (let ((cell (tired--name-cell (tired-tests--entry "link"))))
      (should (string-match-p " -> alpha\\.txt\\'" cell)))
    (should (string-suffix-p "/"
                             (tired--name-cell (tired-tests--entry "sub"))))))

(defun tired-tests--cell-face (entry)
  "Return the face of the name column of ENTRY."
  (get-text-property 0 'face (tired--name-cell entry)))

(ert-deftest tired-command-opens-a-listing ()
  "The `tired' command opens the listing of the directory it gets."
  (tired-tests--with-fixture
    (should (commandp 'tired))
    (let ((buffer (tired (directory-file-name root))))
      (should (eq buffer (current-buffer)))
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-faces-inherit-dired-faces ()
  "Each name face takes its look from the matching Dired face."
  (dolist (pair '((tired-directory-face . dired-directory)
                  (tired-symlink-face . dired-symlink)
                  (tired-symlink-target-face . dired-symlink-filename)
                  (tired-broken-symlink-face . dired-broken-symlink)
                  (tired-special-face . dired-special)
                  (tired-ignored-face . dired-ignored)))
    (should (memq (cdr pair)
                  (ensure-list (face-attribute (car pair) :inherit))))))

(ert-deftest tired-name-cell-fontifies-names-like-dired ()
  "Directory, symlink and special names get the Dired face mapping."
  (tired-tests--with-fixture
    (tired root)
    (should (eq 'tired-directory-face
                (tired-tests--cell-face (tired-tests--entry "sub"))))
    (should (eq 'tired-symlink-face
                (tired-tests--cell-face (tired-tests--entry "link"))))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))
    (should (eq 'tired-special-face
                (tired--name-face
                 (tired--entry-create :name "fifo" :type 'special))))))

(ert-deftest tired-size-cell-stays-empty-by-default ()
  "A directory shows no size unless `tired-directory-size' is on."
  (tired-tests--with-fixture
    (tired root)
    (should-not (default-value 'tired-directory-size))
    (should (equal "" (tired--size-cell (tired-tests--entry "sub"))))
    (should (equal (file-size-human-readable 3)
                   (tired--size-cell (tired-tests--entry "alpha.txt"))))))

(ert-deftest tired-size-cell-sums-a-directory-recursively ()
  "With `tired-directory-size' on, a directory sums its files."
  (tired-tests--with-fixture
    (let ((tired-directory-size t))
      (tired root)
      (should (equal (file-size-human-readable 9)
                     (tired--size-cell (tired-tests--entry "sub"))))
      (should (equal 9 (tired--directory-total
                        (expand-file-name "sub" root))))
      (should (equal 53 (tired--directory-total root))))))

(ert-deftest tired--subtree-size-memoizes-each-directory ()
  "One calculation reads each nested directory once, and links stay unfollowed."
  (tired-tests--with-fixture
    (let ((tired--size-cache (make-hash-table :test #'equal))
          (calls 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (cl-letf (((symbol-function 'directory-files-and-attributes)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (apply original args))))
        (should (equal 53 (tired--subtree-size root)))
        (should (equal 53 (tired--subtree-size root))))
      ;; The root, its child and its grandchild, once each.  The link
      ;; back to the root stays unfollowed.
      (should (= 3 calls)))))

(ert-deftest tired-name-cell-fontifies-broken-symlink ()
  "A link that does not resolve gets the broken symlink face."
  (tired-tests--with-fixture
    (make-symbolic-link "missing.txt" (expand-file-name "dead"))
    (tired root)
    (let ((entry (tired-tests--entry "dead"))
          (cell nil))
      (should (tired-entry-broken entry))
      (should-not (tired-entry-broken (tired-tests--entry "link")))
      (setq cell (tired--name-cell entry))
      (should (eq 'tired-broken-symlink-face (get-text-property 0 'face cell)))
      (should (eq 'tired-broken-symlink-face
                  (get-text-property (length "dead -> ") 'face cell))))))

(ert-deftest tired-name-cell-fontifies-ignored-suffix ()
  "A name that matches `completion-ignored-extensions' gets the ignored face."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name "alpha.elc") (insert "x"))
    (tired root)
    (should (eq 'tired-ignored-face
                (tired-tests--cell-face (tired-tests--entry "alpha.elc"))))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))
    (should (equal (tired--ignored-regexp) (tired--ignored-regexp)))))

(ert-deftest tired-name-faces-colorizes-a-matching-name ()
  "A `tired-name-faces' rule sets the name face, and a directory keeps its own."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\.txt\\'" . bold)
                              ("." . italic))))
      (tired root)
      (should (eq 'bold (tired-tests--cell-face
                         (tired-tests--entry "alpha.txt"))))
      (should (eq 'tired-directory-face
                  (tired-tests--cell-face (tired-tests--entry "sub"))))
      ;; The first matching rule wins.
      (should (eq 'bold (tired--name-face (tired-tests--entry "beta.txt")))))))

(ert-deftest tired-name-faces-accepts-a-face-list ()
  "A rule value may add attributes to a color with an anonymous face."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\.txt\\'" bold (:underline t)))))
      (tired root)
      (should (equal '(bold (:underline t))
                     (tired-tests--cell-face
                      (tired-tests--entry "alpha.txt"))))
      (should (equal '(bold (:underline t))
                     (get-text-property
                      0 'font-lock-face
                      (tired--name-cell (tired-tests--entry "alpha.txt"))))))))

(ert-deftest tired-name-face-defaults-to-nil ()
  "With no rule and no Dired face, a plain file keeps no face."
  (tired-tests--with-fixture
    (tired root)
    (should-not (default-value 'tired-name-faces))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))))

(ert-deftest tired-name-cell-sets-both-face-properties ()
  "A name cell carries `face' and `font-lock-face', so refontification keeps it."
  (tired-tests--with-fixture
    (tired root)
    (let ((cell (tired--name-cell (tired-tests--entry "sub"))))
      (should (eq 'tired-directory-face (get-text-property 0 'face cell)))
      (should (eq 'tired-directory-face
                  (get-text-property 0 'font-lock-face cell))))))

(ert-deftest tired-name-face-survives-font-lock ()
  "Font-lock refontification does not strip the directory face."
  (tired-tests--with-fixture
    (tired root)
    (setq-local font-lock-defaults
                '((("alpha\\.txt\\>" (0 'bold)))))
    (let ((noninteractive nil))
      (font-lock-mode 1))
    (unwind-protect
        (progn
          (font-lock-ensure)
          (goto-char (point-min))
          (search-forward "sub")
          (should (eq 'tired-directory-face
                      (get-text-property (match-beginning 0) 'font-lock-face)))
          (goto-char (point-min))
          (search-forward "alpha.txt")
          (should (eq 'bold (get-text-property (match-beginning 0) 'face))))
      (let ((noninteractive nil))
        (font-lock-mode -1)))))

(ert-deftest tired-jump-from-file-buffer ()
  "Jumping from a file buffer opens its directory and marks the file."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-open)
    (let ((file-buffer (current-buffer)))
      (unwind-protect
          (progn
            (tired-jump)
            (should (derived-mode-p 'tired-mode))
            (should (equal tired--directory root))
            (should (equal (tired-entry-name (tired--row-at-point))
                           "alpha.txt")))
        (kill-buffer file-buffer)))))

(ert-deftest tired-jump-from-tired-buffer-goes-up ()
  "Jumping from a Tired buffer opens the parent and marks the directory."
  (tired-tests--with-fixture
    (tired root)
    (let ((origin (current-buffer)))
      (tired-tests--goto "sub")
      (tired-open)
      (tired-jump)
      (should (eq (current-buffer) origin))
      (should (equal (tired-entry-name (tired--row-at-point)) "sub")))))

(ert-deftest tired-jump-uses-default-directory ()
  "Jumping from a buffer without a file uses `default-directory'."
  (tired-tests--with-fixture
    (with-temp-buffer
      (setq default-directory root)
      (tired-jump)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-bookmark-round-trip ()
  "A Tired bookmark records the directory and restores the buffer."
  (tired-tests--with-fixture
    (tired root)
    (let ((record (tired-bookmark-make-record)))
      (should (equal (car record) (abbreviate-file-name root)))
      (should (eq (cdr (assq 'handler record)) #'tired-bookmark-jump))
      (kill-buffer (current-buffer))
      (tired-bookmark-jump record)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-insert-subdir-adds-indented-children ()
  "Inserting a directory shows its children below it, indented by depth."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    ;; `deep` holds one file, so it collapses into one row.
    (should (equal (tired-tests--names)
                   '("sub" "deep/leaf.txt" "inner.txt" "loop"
                     ".hidden" "alpha.txt" "beta.txt" "link")))
    (should (equal (mapcar #'cdr (tired--display-rows t))
                   '(0 1 1 1 0 0 0 0)))
    (should (string-prefix-p
             "  inner.txt"
             (aref (tired--row
                    (tired--entry-for-path
                     (expand-file-name "sub/inner.txt" root))
                    1)
                   0)))))

(ert-deftest tired-insert-subdir-nests ()
  "Inserting a child section keeps the tree order."
  (tired-tests--with-fixture
    (let ((tired-collapse-single-child nil))
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-tests--goto "deep")
      (tired-insert-subdir)
      (should (equal (tired-tests--names)
                     '("sub" "deep" "leaf.txt" "inner.txt" "loop"
                       ".hidden" "alpha.txt" "beta.txt" "link")))
      (should (equal (mapcar #'cdr (tired--display-rows t))
                     '(0 1 2 1 1 0 0 0 0))))))

(ert-deftest tired-toggle-subdir-removes-children ()
  "TAB inserts and removes one section."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-toggle-subdir)
    (should (member "inner.txt" (tired-tests--names)))
    (tired-toggle-subdir)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "beta.txt" "link")))))

(ert-deftest tired-remove-subdir-drops-descendants ()
  "Removing a section drops nested inserted sections as well."
  (tired-tests--with-fixture
    (let ((tired-collapse-single-child nil))
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-tests--goto "deep")
      (tired-insert-subdir)
      (tired-tests--goto "sub")
      (tired-remove-subdir)
      (should (= 0 (hash-table-count tired--inserted)))
      (should (equal (tired-tests--names)
                     '("sub" ".hidden" "alpha.txt" "beta.txt" "link"))))))

(ert-deftest tired-insert-subdir-rejects-files ()
  "Inserting a file signals a user error."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-insert-subdir) :type 'user-error)))

(ert-deftest tired-refresh-keeps-inserted-sections ()
  "Refresh reloads inserted directories and keeps the sections."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (with-temp-file (expand-file-name "sub/new.txt") (insert "new"))
    (tired-refresh)
    (should (member "new.txt" (tired-tests--names)))
    (should (tired--inserted-p (expand-file-name "sub" root)))))

(ert-deftest tired-insert-subdir-guards-symlink-cycles ()
  "A symlink back to an ancestor does not recurse."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "loop")
    (tired-insert-subdir)
    (should (= 8 (length (tired-tests--names))))))

(ert-deftest tired-selection-targets-cover-inserted-entries ()
  "Selection and targets work inside inserted sections."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (should (equal (mapcar #'tired-entry-name (tired--selection-targets))
                   '("inner.txt")))
    (tired-select-all)
    (should (= 8 (length (tired--selection-targets))))))

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

(ert-deftest tired-region-drives-targets ()
  "The active region sets the targets when the selection is empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (should (equal (tired-tests--target-names) '("alpha.txt" "beta.txt")))
    (should-not tired--selection)))

(ert-deftest tired-region-excludes-the-row-at-its-end ()
  "A region that ends at a line start leaves that row out."
  (tired-tests--with-fixture
    (tired root)
    (transient-mark-mode 1)
    (tired-tests--goto "alpha.txt")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-tests--goto "link")
    (beginning-of-line)
    (should (equal (tired-tests--target-names) '("alpha.txt" "beta.txt")))))

(ert-deftest tired-region-loses-to-the-selection ()
  "An explicit selection wins over the active region."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "link")
    (tired-select-toggle)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (should (equal (tired-tests--target-names) '("link")))))

(ert-deftest tired-region-copy-path-copies-every-row ()
  "Copy acts on the region and then deactivates it."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (tired-copy-path)
    (should (equal (current-kill 0)
                   (concat (expand-file-name "alpha.txt" root)
                           "\n"
                           (expand-file-name "beta.txt" root))))
    (should-not (use-region-p))))

(ert-deftest tired-region-delete-acts-on-every-row ()
  "Delete removes every row of the region."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--mark-row-range "alpha.txt" "beta.txt")
      (tired-delete)
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should-not (file-exists-p (expand-file-name "beta.txt" root)))
      (should-not (use-region-p)))))

(ert-deftest tired-redraw-restores-the-mark-by-path ()
  "Refresh and sort keep the mark on the same entry."
  (tired-tests--with-fixture
    (tired root)
    (transient-mark-mode 1)
    (tired-tests--goto "beta.txt")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-refresh)
    (should (equal (tired-entry-name (tired--row-at (mark t)))
                   "beta.txt"))
    (tired-sort 'size)
    (should (equal (tired-entry-name (tired--row-at (mark t)))
                   "beta.txt"))))

(ert-deftest tired-mode-line-counts-the-region ()
  "The mode line reports the region when the selection is empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (should (string-match-p "2 in region" (tired--mode-line)))
    (tired-select-toggle)
    (should-not (string-match-p "in region" (tired--mode-line)))))

(ert-deftest tired-select-invert-flips-visible-entries ()
  "Inverting selects every visible entry that was not selected."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-select-invert)
    (should (equal (sort (mapcar #'tired-entry-name
                                 (tired--selection-targets))
                         #'string<)
                   '(".hidden" "beta.txt" "link" "sub")))))

(ert-deftest tired-selection-size-sums-non-directories ()
  "The selection size adds file sizes and skips directories."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-tests--goto "sub")
    (tired-select-toggle)
    (should (= 43 (tired--selection-size)))
    (should (string-match-p "3 selected" (tired--mode-line)))))

(ert-deftest tired-narrow-shows-selection-and-widens ()
  "Narrowing hides unselected entries and widening restores them."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (should (equal (tired-tests--names) '("alpha.txt" "beta.txt")))
    (should (string-match-p "narrowed" (tired--header-title)))
    (tired-widen)
    (should (= 5 (length (tired-tests--names))))))

(ert-deftest tired-narrow-keeps-ancestor-directories ()
  "A narrowed entry inside a section keeps its parent row visible."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (should (equal (tired-tests--names) '("sub" "inner.txt")))))

(ert-deftest tired-narrow-prunes-deleted-paths ()
  "Refresh drops narrowed paths that vanished and widens when empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (delete-file (expand-file-name "beta.txt" root))
    (tired-refresh)
    (should-not tired--narrowed)
    (should (= 4 (length (tired-tests--names))))))

(ert-deftest tired-watch-directories-follow-inserted-sections ()
  "The watch list holds the root and every inserted directory."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired root)
      (should (equal (tired--watch-paths)
                     (list (directory-file-name root))))
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (should (equal (sort (tired--watch-paths) #'string<)
                     (sort (list (directory-file-name root)
                                 (expand-file-name "sub" root))
                           #'string<))))))

(ert-deftest tired-sync-watches-adds-and-removes ()
  "Inserted sections gain a watch and removed sections lose it."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (added nil) (removed nil) (counter 0))
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (directory _aspects _callback)
                   (push directory added)
                   (list 'fake (cl-incf counter))))
                ((symbol-function 'file-notify-rm-watch)
                 (lambda (descriptor) (push descriptor removed))))
        (tired root)
        (tired-tests--goto "sub")
        (tired-insert-subdir)
        (should (member (expand-file-name "sub" root) added))
        (tired-refresh)
        (should (= 2 (length added)))
        (tired-remove-subdir)
        (should (= 1 (length removed)))))))

(ert-deftest tired-kill-buffer-removes-watches ()
  "Killing a Tired buffer removes its file notification watches."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (removed nil) (counter 0))
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (&rest _) (list 'fake (cl-incf counter))))
                ((symbol-function 'file-notify-rm-watch)
                 (lambda (descriptor) (push descriptor removed))))
        (let ((buffer (tired root)))
          (should (= 1 (length tired--watches)))
          (kill-buffer buffer)
          (should (= 1 (length removed))))))))

(ert-deftest tired-file-change-coalesces-into-one-timer ()
  "A second event keeps the pending timer instead of adding another."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired root)
      (tired--file-changed nil)
      (let ((timer tired--revert-timer))
        (should (timerp timer))
        (tired--file-changed nil)
        (should (eq timer tired--revert-timer))
        (cancel-timer timer)
        (setq tired--revert-timer nil)))))

(ert-deftest tired-auto-revert-refreshes-once-and-skips-minibuffer ()
  "The timer callback refreshes, except while a minibuffer is active."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (calls 0))
      (tired root)
      (let ((buffer (current-buffer)))
        (cl-letf (((symbol-function 'tired-refresh)
                   (lambda () (cl-incf calls))))
          (tired--auto-revert-now buffer)
          (should (= 1 calls))
          (setq calls 0)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () t)))
            (tired--auto-revert-now buffer))
          (should (= 0 calls)))))))

(ert-deftest tired-file-change-ignores-lockfiles ()
  "Emacs lock file events do not schedule a refresh."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired root)
      (tired--file-changed '(descriptor created "/tmp/.#alpha.txt"))
      (should-not tired--revert-timer))))

(ert-deftest tired-collapse-single-entry-chain ()
  "A chain of single-entry directories becomes one file row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt")
      (insert "abc"))
    (tired root)
    (should (equal (car (tired-tests--names)) "chain/a/b/file.txt"))
    (should-not (member "chain" (tired-tests--names)))
    (let* ((row (seq-find
                 (lambda (row)
                   (equal (tired-entry-name (car row))
                          "chain/a/b/file.txt"))
                 (tired--display-rows t)))
           (entry (car row)))
      (should (= 3 (tired-entry-size entry)))
      (should-not (tired-entry-dirp entry))
      (should (equal (tired-entry-path entry)
                     (expand-file-name "chain/a/b/file.txt" root))))
    (tired-tests--goto "chain/a/b/file.txt")
    (tired-open)
    (should (equal (buffer-file-name)
                   (expand-file-name "chain/a/b/file.txt" root)))
    (kill-buffer (current-buffer))))

(ert-deftest tired-collapse-requires-exactly-one-entry ()
  "A branch or an empty directory does not collapse."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "branch/x" root) t)
    (with-temp-file (expand-file-name "branch/x/one.txt") (insert "1"))
    (with-temp-file (expand-file-name "branch/x/two.txt") (insert "2"))
    (make-directory (expand-file-name "empty" root))
    (tired root)
    (should (member "branch" (tired-tests--names)))
    (should (member "empty" (tired-tests--names)))
    (should-not (member "branch/x/one.txt" (tired-tests--names)))))

(ert-deftest tired-collapse-hidden-final-file ()
  "A collapsed chain whose file is hidden follows the dotfile toggle."  (tired-tests--with-fixture
    (make-directory (expand-file-name "secret/a" root) t)
    (with-temp-file (expand-file-name "secret/a/.hiddenfile") (insert "h"))
    (tired root)
    (should (member "secret/a/.hiddenfile" (tired-tests--names)))
    (tired-toggle-dotfiles)
    (should-not (member "secret/a/.hiddenfile" (tired-tests--names)))))

(ert-deftest tired-collapse-paints-the-path-and-the-file-apart ()
  "A collapsed row paints its directory part and its file part apart."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a" root) t)
    (with-temp-file (expand-file-name "chain/a/file.elc") (insert "abc"))
    (tired root)
    (let* ((row (seq-find
                 (lambda (row)
                   (equal (tired-entry-name (car row))
                          "chain/a/file.elc"))
                 (tired--display-rows t)))
           (cell (tired--name-cell (car row)))
           (file-start (length "chain/a/")))
      (should (equal (substring-no-properties cell) "chain/a/file.elc"))
      (should (eq (get-text-property 0 'face cell) 'tired-directory-face))
      (should (eq (get-text-property (1- file-start) 'face cell)
                  'tired-directory-face))
      (should (eq (get-text-property file-start 'face cell)
                  'tired-ignored-face))
      (should (eq (get-text-property file-start 'font-lock-face cell)
                  'tired-ignored-face)))))

(ert-deftest tired-toggle-collapse-shows-real-rows ()
  "C switches between the collapsed row and the directory row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt") (insert "abc"))
    (tired root)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))
    (tired-toggle-collapse)
    (should (member "chain" (tired-tests--names)))
    (should-not (member "chain/a/b/file.txt" (tired-tests--names)))
    (should (string-match-p "no collapse" (tired--mode-line)))
    (tired-toggle-collapse)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))))

(ert-deftest tired-collapse-cache-clears-on-refresh ()
  "Refresh notices when a former chain gains a second entry."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt") (insert "abc"))
    (tired root)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))
    (with-temp-file (expand-file-name "chain/a/b/other.txt") (insert "x"))
    (tired-refresh)
    (should (member "chain" (tired-tests--names)))
    (should-not (member "chain/a/b/file.txt" (tired-tests--names)))))

(ert-deftest tired-file-handler-picks-the-first-matching-rule ()
  "The registry matches the absolute name and the first rule wins."
  (tired-tests--with-fixture
    (let ((tired-file-handlers
           (list (cons (concat (regexp-quote root) "alpha") #'ignore)
                 (cons "\\.txt\\'" #'identity))))
      (should (eq (tired-file-handler (expand-file-name "alpha.txt" root))
                  #'ignore))
      (should (eq (tired-file-handler (expand-file-name "beta.txt" root))
                  #'identity))
      (should-not (tired-file-handler (expand-file-name "sub" root))))))

(ert-deftest tired-expand-org-file-shows-nested-headings ()
  "TAB on an org file row shows its headings with levels as depth."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org"
                        "#+title: Notes\n\n* Intro\nBody.\n\n** Detail\nMore.\n\n* Plans\n- item\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2) ("Plans" . 1))))
    (should (tired--expanded-p (expand-file-name "notes.org" root)))
    (should (string-match-p "1 expanded" (tired--mode-line)))))

(ert-deftest tired-sections-of-an-elisp-file ()
  "An Emacs Lisp file lists its top-level forms in document order."
  (tired-tests--with-fixture
    (tired-tests--write "code.el"
                        ";;; code\n(defvar code-x 1)\n\n(defun code-foo (a) a)\n(provide 'code)\n")
    (tired root)
    (tired-tests--goto "code.el")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("defvar code-x" . 1)
                     ("defun code-foo" . 1)
                     ("provide code" . 1))))))

(ert-deftest tired-elisp-section-labels-take-mode-faces ()
  "An Emacs Lisp section label carries the faces of its source text."
  (tired-tests--with-fixture
    (tired-tests--write "code.el"
                        "(defvar code-x 1)\n(defun code-foo (a) a)\n")
    (let* ((path (expand-file-name "code.el" root))
           (sections (tired-file-sections path))
           (variable (car sections))
           (function (cadr sections)))
      (should (equal (tired-section-label variable) "defvar code-x"))
      (should (eq (get-text-property 0 'face (tired-section-label variable))
                  'font-lock-keyword-face))
      (should (eq (get-text-property 7 'face (tired-section-label variable))
                  'font-lock-variable-name-face))
      (should (eq (get-text-property 6 'face (tired-section-label function))
                  'font-lock-function-name-face))
      (let ((cell (tired--section-cell variable)))
        (should (eq (get-text-property 0 'font-lock-face cell)
                    'font-lock-keyword-face))
        (should (eq (get-text-property 0 'face cell)
                    'font-lock-keyword-face))))))

(ert-deftest tired-call-handler-does-not-ask-to-kill-its-buffer ()
  "Parsing a file must not prompt about the discarded temp buffer."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n** Detail\n")
    (let ((path (expand-file-name "notes.org" root))
          asked)
      (cl-letf* ((noninteractive nil)
                 ((symbol-function 'yes-or-no-p)
                  (lambda (&rest _) (setq asked t) t))
                 ((symbol-function 'y-or-n-p)
                  (lambda (&rest _) (setq asked t) t)))
        (tired-file-sections path))
      (should-not asked)
      (should (equal (mapcar #'tired-section-label
                             (tired-file-sections path))
                     '("Intro" "Detail"))))))

(ert-deftest tired-sections-of-a-rust-file ()
  "A Rust file lists items and nests the methods of an impl block."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'rust t)))
  (tired-tests--with-fixture
    (tired-tests--write "lib.rs"
                        "struct Config { n: u8 }\n\nimpl Config {\n    fn new() -> Self { Config { n: 0 } }\n}\n\nfn main() {}\n")
    (tired root)
    (tired-tests--goto "lib.rs")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("struct Config" . 1)
                     ("impl Config" . 1)
                     ("function new" . 2)
                     ("function main" . 1))))))

(ert-deftest tired-sections-of-a-markdown-file ()
  "A Markdown file lists ATX and setext headings and skips code fences."
  (skip-unless (and (require 'treesit nil t)
                    (treesit-ready-p 'markdown t)
                    (treesit-ready-p 'markdown-inline t)))
  (tired-tests--with-fixture
    (tired-tests--write "notes.md"
                        "# Intro\n\n## Detail\n\n```sh\n# not a heading\n```\n\nClosing\n=======\n")
    (tired root)
    (tired-tests--goto "notes.md")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2) ("Closing" . 1))))))

(ert-deftest tired-sections-of-a-sqlite-database ()
  "A SQLite file lists its tables and columns with a table action."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (tired-tests--with-fixture
    (let ((path (expand-file-name "data.sqlite" root)))
      (let ((db (sqlite-open path nil)))
        (sqlite-execute db "CREATE TABLE logs (msg TEXT)")
        (sqlite-execute db "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        (sqlite-close db))
      (tired root)
      (tired-tests--goto "data.sqlite")
      (tired-toggle-subdir)
      (should (equal (tired-tests--sections)
                     '(("logs" . 1)
                       ("msg TEXT" . 2)
                       ("users" . 1)
                       ("id INTEGER PRIMARY KEY" . 2)
                       ("name TEXT NOT NULL" . 2))))
      (let ((table (car (tired-file-sections path))))
        (should (eq (tired-section-kind table) 'table))
        (should (consp (tired-section-action table)))))))

(ert-deftest tired-sqlite-table-action-opens-sqlite-mode ()
  "RET on a table section opens the database at that table."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (tired-tests--with-fixture
    (let ((path (expand-file-name "data.sqlite" root)))
      (let ((db (sqlite-open path nil)))
        (sqlite-execute db "CREATE TABLE users (id INTEGER)")
        (sqlite-close db))
      (tired root)
      (tired-tests--goto "data.sqlite")
      (tired-toggle-subdir)
      (tired-tests--goto-section "users")
      (tired-open)
      (let ((buffer (get-buffer "*SQLite data.sqlite*")))
        (should buffer)
        (with-current-buffer buffer
          (should (derived-mode-p 'sqlite-mode))
          (should (looking-at "users")))
        (kill-buffer buffer)))))

(ert-deftest tired-sqlite-handler-rejects-a-non-database ()
  "A .db file that holds no database yields no sections."
  (tired-tests--with-fixture
    (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
    (tired-tests--write "junk.db" "not a database")
    (should-not (tired-file-sections (expand-file-name "junk.db" root)))))

(ert-deftest tired-find-file-completes-over-the-subtree ()
  "The finder offers files and directories below the shown directory."
  (tired-tests--with-fixture
    (tired root)
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered collection)
                   "sub/deep/leaf.txt")))
        (tired-find-file))
      (should (member "sub/deep/leaf.txt" offered))
      (should (member "sub/" offered))
      (should (equal buffer-file-name
                     (expand-file-name "sub/deep/leaf.txt" root))))))

(ert-deftest tired-find-file-hides-dotfiles-when-set ()
  "A hidden path stays out of the finder list."
  (tired-tests--with-fixture
    (tired-tests--write "sub/.secret" "s")
    (tired root)
    (let ((tired--hide-dotfiles t)
          offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered collection)
                   "alpha.txt")))
        (tired-find-file))
      (should-not (seq-some (lambda (name) (string-match-p "/\\." name))
                            offered))
      (should (equal buffer-file-name
                     (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-find-file-other-window-visits-the-choice ()
  "The other-window finder visits the chosen file."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "sub/inner.txt")))
      (tired-find-file-other-window))
    (should (equal buffer-file-name
                   (expand-file-name "sub/inner.txt" root)))))

(ert-deftest tired-find-file-opens-a-chosen-directory ()
  "A directory candidate opens as a Tired buffer."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "sub/")))
      (tired-find-file))
    (should (derived-mode-p 'tired-mode))
    (should (equal tired--directory
                   (file-name-as-directory (expand-file-name "sub" root))))))

(ert-deftest tired-open-section-visits-its-line ()
  "RET on a section row visits the file at the section line."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Detail")
    (tired-open)
    (should (equal (buffer-file-name)
                   (expand-file-name "notes.org" root)))
    ;; An org heading narrows the buffer, so widen before the line check.
    (widen)
    (should (= 3 (line-number-at-pos)))))

(ert-deftest tired-open-org-heading-narrows-to-its-subtree ()
  "RET on an org heading narrows the visited buffer to that subtree."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org"
                        "* Intro\nintro body\n** Detail\ndetail body\n* Plans\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Detail")
    (tired-open)
    (should (buffer-narrowed-p))
    (let ((text (buffer-substring-no-properties
                 (point-min) (point-max))))
      (should (string-match-p "Detail" text))
      (should (string-match-p "detail body" text))
      (should-not (string-match-p "Intro" text)))))

(ert-deftest tired-open-org-heading-stays-wide-when-option-off ()
  "An org heading opens wide when `tired-org-narrow-on-open' is nil."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\nintro body\n* Plans\n")
    (let ((tired-org-narrow-on-open nil))
      (tired root)
      (tired-tests--goto "notes.org")
      (tired-toggle-subdir)
      (tired-tests--goto-section "Plans")
      (tired-open)
      (should-not (buffer-narrowed-p))
      (should (string-match-p
               "Intro" (buffer-substring-no-properties
                        (point-min) (point-max)))))))

(ert-deftest tired-open-non-org-section-stays-wide ()
  "A section of a non-org file opens without narrowing."
  (tired-tests--with-fixture
    (tired-tests--write "code.el" "(defun alpha ())\n(defun beta ())\n")
    (tired root)
    (tired-tests--goto "code.el")
    (tired-toggle-subdir)
    (tired-tests--goto-section "defun beta")
    (tired-open)
    (should-not (buffer-narrowed-p))))

(ert-deftest tired-section-rows-are-not-selectable ()
  "A selection command refuses a section row."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (should-error (tired-select-toggle) :type 'user-error)
    (should-not tired--selection)))

(ert-deftest tired-path-commands-use-the-file-of-a-section ()
  "A section stands for its file, so the path commands reach that file."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (let ((row (tired--row-at-point))
          (path (expand-file-name "notes.org" root)))
      (should (tired-section-p row))
      (should (equal (tired--row-path row) path))
      (should (equal (tired-entry-name (car (tired--selection-targets)))
                     "notes.org")))))

(ert-deftest tired-fold-hides-the-child-sections ()
  "TAB on a section row hides its children and TAB again shows them."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n\n* Plans\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Plans" . 1))))
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2) ("Plans" . 1))))))

(ert-deftest tired-collapse-file-hides-the-sections ()
  "E collapses the sections that TAB expanded."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (should (tired-tests--sections))
    (tired-tests--goto "notes.org")
    (tired-collapse-file)
    (should-not (tired-tests--sections))))

(ert-deftest tired-expand-file-rejects-a-file-without-handler ()
  "A file that no rule claims reports the missing handler."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-expand-file) :type 'user-error)
    (should-not (tired--expanded-p (expand-file-name "alpha.txt" root)))))

(ert-deftest tired-section-cache-follows-modification-time ()
  "The handler runs once per modification time, not once per redraw."
  (tired-tests--with-fixture
    (tired-tests--write "alpha.txt" "abc")
    (let ((calls 0)
          (path (expand-file-name "alpha.txt" root)))
      (let ((tired-file-handlers
             (list (cons "\\.txt\\'"
                         (lambda (_path)
                           (cl-incf calls)
                           '((:label "alpha" :line 1)))))))
        (tired root)
        (tired-file-sections path)
        (tired-file-sections path)
        (should (= 1 calls))
        (set-file-times path (time-add (current-time) 60))
        (tired-file-sections path)
        (should (= 2 calls))
        (should (equal (tired-section-label (car (tired-file-sections path)))
                       "alpha"))))))

(ert-deftest tired-broken-handler-keeps-the-listing ()
  "A handler that signals an error yields no sections and no crash."
  (tired-tests--with-fixture
    (tired-tests--write "alpha.txt" "abc")
    (let ((tired-file-handlers
           (list (cons "\\.txt\\'" (lambda (_path) (error "boom"))))))
      (tired root)
      (tired-tests--goto "alpha.txt")
      (should-error (tired-expand-file) :type 'user-error)
      (should (member "alpha.txt" (tired-tests--names))))))

(ert-deftest tired-refresh-drops-a-vanished-expanded-file ()
  "Refresh forgets an expanded file that a command removed."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (let ((path (expand-file-name "notes.org" root)))
      (delete-file path)
      (tired-refresh)
      (should-not (tired--expanded-p path))
      (should-not (tired-tests--sections)))))

(ert-deftest tired-watch-paths-cover-expanded-files ()
  "An expanded file gets its own notification watch."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired-tests--write "notes.org" "* Intro\n")
      (tired root)
      (tired-tests--goto "notes.org")
      (tired-toggle-subdir)
      (should (member (expand-file-name "notes.org" root)
                      (tired--watch-paths))))))

(ert-deftest tired-redraw-keeps-point-on-a-section-row ()
  "A redraw returns point to the same section, not to the file row."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Detail")
    (tired-sort 'size)
    (should (equal (tired-section-label (tired--row-at-point)) "Detail"))))

(ert-deftest tired-filter-keeps-the-sections-of-a-visible-file ()
  "A filter on the file name keeps that file and all of its sections."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n")
    (tired-tests--write "other.org" "* Other\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto "other.org")
    (tired-toggle-subdir)
    (tired--apply-filter "notes")
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2))))
    (should (equal (tired-tests--names) '("notes.org")))))

(ert-deftest tired-toggle-subdir-rejects-a-file-without-subtree ()
  "TAB on a plain file reports that no subtree exists."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-toggle-subdir) :type 'user-error)))

(ert-deftest tired-evil-mode-binds-the-tired-commands ()
  "The global evil mode gives a Tired buffer dired-style keys."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired root)
    (evil-local-mode 1)
    (unwind-protect
        (progn
          (tired-evil-mode 1)
          (should (bound-and-true-p tired-evil-local-mode))
          (should (eq (key-binding (key-parse "D")) #'tired-delete))
          (should (eq (key-binding (key-parse "TAB"))
                      #'tired-toggle-subdir))
          (should (eq (key-binding (key-parse "gr")) #'tired-refresh))
          (should (eq (key-binding (key-parse "SPC"))
                      #'tired-select-toggle-next))
          ;; The copy commands keep their `tired-mode-map' keys.
          (should (eq (key-binding (key-parse "W"))
                      #'tired-copy-relative-path))
          (should (eq (key-binding (key-parse "P"))
                      #'tired-copy-project-path))
          ;; Motion stays evil, so a Tired buffer is still navigable.
          (should (eq (key-binding (key-parse "j")) #'evil-next-line))
          (should (eq (key-binding (key-parse "gg"))
                      #'evil-goto-first-line)))
      (tired-evil-mode -1)
      (evil-local-mode -1))
    (should-not (bound-and-true-p tired-evil-local-mode))))

(ert-deftest tired-evil-visual-state-binds-the-file-commands ()
  "A visual range reaches delete, and the text objects stay."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired root)
    (evil-local-mode 1)
    (unwind-protect
        (progn
          (tired-evil-mode 1)
          (evil-visual-line)
          (should (eq evil-state 'visual))
          (should (eq (key-binding (key-parse "D")) #'tired-delete))
          (should (eq (key-binding (key-parse "c")) #'tired-copy))
          ;; Visual state keeps its inner text objects.
          (should (keymapp (key-binding (key-parse "i")))))
      (evil-normal-state)
      (tired-evil-mode -1)
      (evil-local-mode -1))))

(ert-deftest tired-evil-mode-covers-a-buffer-made-later ()
  "A Tired buffer that appears after the mode is on takes the keys."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired root)
    (evil-local-mode 1)
    (unwind-protect
        (progn
          (tired-evil-mode 1)
          (tired (expand-file-name "sub" root))
          (should (bound-and-true-p tired-evil-local-mode))
          (should (eq (key-binding (key-parse "D")) #'tired-delete)))
      (tired-evil-mode -1)
      (evil-local-mode -1))))

(ert-deftest tired-evil-bindings-arrive-with-the-evil-library ()
  "Loading Tired and then evil gives RET back to the Tired command."
  (skip-unless (require 'evil nil t))
  (tired-tests--with-fixture
    (tired root)
    (evil-local-mode 1)
    (unwind-protect
        (progn
          (tired-evil-mode -1)
          (tired--enable-evil-bindings)
          (should (bound-and-true-p tired-evil-local-mode))
          (should (eq (key-binding (key-parse "RET")) #'tired-open)))
      (tired-evil-mode -1)
      (evil-local-mode -1))))

(provide 'tired-tests)

;;; tired-tests.el ends here
