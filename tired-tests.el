;;; tired-tests.el --- ERT tests for tired  -*- lexical-binding: t -*-

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

;; Keep unrelated tests free of real file notification watches and
;; pending timers.  The auto-revert tests bind this to t themselves.
(setq tired-auto-revert nil)

(defmacro tired-tests--with-fixture (&rest body)
  "Run BODY inside a fresh directory that holds test entries.
The variable `root' is bound to the temporary directory.  The
fixture contains a subdirectory, regular files, a hidden file and
a symlink, and removes every tired buffer it opened."
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
      (let ((entry (tired--entry-at-point)))
        (if (and entry (equal (tired-entry-name entry) name))
            (setq found t)
          (forward-line 1))))
    (unless found
      (error "Entry not listed: %s" name))))

(defun tired-tests--entry (name)
  "Return the listed entry called NAME."
  (seq-find (lambda (entry)
              (equal (tired-entry-name entry) name))
            (tired--sorted-directory-entries tired--directory nil)))

(ert-deftest tired-mode-is-derived-from-tabulated-list-mode ()
  "The major mode must inherit from `tabulated-list-mode'."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (should (derived-mode-p 'tired-mode 'tabulated-list-mode))
    (should (equal (tired--buffer-name root) (buffer-name)))))

(ert-deftest tired-listing-puts-directories-first ()
  "Directories sort before files, and files sort by name."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "beta.txt" "link")))))

(ert-deftest tired-entries-carry-file-attributes ()
  "Each entry records its type, size and mode."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
    (tired-find-directory root)
    (tired-toggle-dotfiles)
    (should (equal (tired-tests--names)
                   '("sub" "alpha.txt" "beta.txt" "link")))
    (tired-toggle-dotfiles)
    (should (member ".hidden" (tired-tests--names)))))

(ert-deftest tired-sort-by-size-toggles-direction ()
  "Sorting by size orders files by size and flips on repetition."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-sort 'size)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "link" "beta.txt")))
    (tired-sort 'size)
    (should (equal (tired-tests--names)
                   '("sub" "beta.txt" "link" "alpha.txt" ".hidden")))))

(ert-deftest tired-sort-by-name-keeps-directories-first ()
  "The name sort keeps directories first in both directions."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-sort 'name)
    (should (equal (car (tired-tests--names)) "sub"))
    (tired-sort 'name)
    (should (equal (car (tired-tests--names)) "sub"))))

(ert-deftest tired-name-column-grows-to-longest-name ()
  "The name column width follows the longest visible entry."
  (tired-tests--with-fixture
    (let ((name (make-string 30 ?n)))
      (with-temp-file (expand-file-name name) (insert "x")))
    (tired-find-directory root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100)))
      (tired-refresh))
    (should (= 30 (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-name-column-keeps-minimum-width ()
  "Short names do not shrink the name column below the minimum."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100)))
      (tired-refresh))
    (should (= tired-name-column-min-width
               (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-name-column-clamps-to-window ()
  "A long name does not push the other columns off screen."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 80 ?x)) (insert "x"))
    (tired-find-directory root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 80)))
      (tired-refresh))
    (should (= (- 80 tired--fixed-column-width)
               (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-window-size-change-resizes-name-column ()
  "A window size change updates the name column width."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 60 ?w)) (insert "x"))
    (tired-find-directory root)
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
    (tired-find-directory root)
    (tired--apply-filter "BETA")
    (should (equal (tired-tests--names) '("beta.txt")))
    (tired-clear-filter)
    (should (= 5 (length (tired-tests--names))))))

(ert-deftest tired-filter-command-commits-with-ret ()
  "RET in the live filter keeps the typed value."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "BETA")))
      (tired-filter))
    (should (equal tired--filter "BETA"))
    (should (equal (tired-tests--names) '("beta.txt")))))

(ert-deftest tired-filter-command-restores-on-quit ()
  "C-g in the live filter restores the previous filter."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired--apply-filter "beta")
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (signal 'quit nil))))
      (tired-filter))
    (should (equal tired--filter "beta"))
    (should (equal (tired-tests--names) '("beta.txt")))))

(ert-deftest tired-selection-drives-targets ()
  "Selecting an entry makes it the target of file commands."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
    (tired-find-directory root)
    (tired-select-all)
    (should (= 5 (length tired--selection)))
    (should (equal (sort (mapcar #'tired-entry-name (tired--selection-targets))
                         #'string<)
                   '(".hidden" "alpha.txt" "beta.txt" "link" "sub")))))

(ert-deftest tired-copy-path-joins-targets ()
  "Copying paths puts one path per line on the kill ring."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
    (tired-find-directory root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-copy-relative-path)
    (should (equal (current-kill 0) "alpha.txt\nbeta.txt"))))

(ert-deftest tired-copy-relative-path-handles-inserted-entries ()
  "Relative copies work inside inserted sections."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (tired-copy-relative-path)
    (should (equal (current-kill 0) "sub/inner.txt"))))

(ert-deftest tired-copy-project-path-uses-project-root ()
  "Project copies are relative to the project root."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "alpha.txt")
    (cl-letf (((symbol-function 'tired--project-root)
               (lambda () root)))
      (tired-copy-project-path))
    (should (equal (current-kill 0) "alpha.txt"))))

(ert-deftest tired-copy-project-path-without-project-errors ()
  "Project copies signal an error outside a project."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (require 'project)
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) nil)))
      (should-error (tired-copy-project-path) :type 'user-error))))

(ert-deftest tired-open-file-visits-the-file ()
  "Opening a file entry visits that file."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "alpha.txt")
    (tired-open)
    (should (equal (buffer-file-name) (expand-file-name "alpha.txt" root)))
    (kill-buffer (current-buffer))))

(ert-deftest tired-open-directory-replaces-the-listing ()
  "Opening a directory entry shows it in a tired buffer."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
    (tired-find-directory root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (delete-file (expand-file-name "beta.txt" root))
    (tired-refresh)
    (should-not tired--selection)
    (should-not (member "beta.txt" (tired-tests--names)))))

(ert-deftest tired-refresh-keeps-sort-and-point ()
  "Refresh keeps the sort order and the entry at point."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-sort 'size 'reverse)
    (tired-tests--goto "link")
    (tired-refresh)
    (should (equal (tired-entry-name (tired--entry-at-point)) "link"))
    (should (eq 'size tired--sort-key))
    (should tired--sort-flip)))

(ert-deftest tired-name-cell-shows-symlink-target ()
  "The name column of a symlink shows its target."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (let ((cell (tired--name-cell (tired-tests--entry "link"))))
      (should (string-match-p " -> alpha\\.txt\\'" cell)))
    (should (string-suffix-p "/"
                             (tired--name-cell (tired-tests--entry "sub"))))))

(defun tired-tests--cell-face (entry)
  "Return the face of the name column of ENTRY."
  (get-text-property 0 'face (tired--name-cell entry)))

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
    (tired-find-directory root)
    (should (eq 'tired-directory-face
                (tired-tests--cell-face (tired-tests--entry "sub"))))
    (should (eq 'tired-symlink-face
                (tired-tests--cell-face (tired-tests--entry "link"))))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))
    (should (eq 'tired-special-face
                (tired--name-face
                 (tired--entry-create :name "fifo" :type 'special))))))

(ert-deftest tired-name-cell-fontifies-broken-symlink ()
  "A link that does not resolve gets the broken symlink face."
  (tired-tests--with-fixture
    (make-symbolic-link "missing.txt" (expand-file-name "dead"))
    (tired-find-directory root)
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
    (tired-find-directory root)
    (should (eq 'tired-ignored-face
                (tired-tests--cell-face (tired-tests--entry "alpha.elc"))))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))
    (should (equal (tired--ignored-regexp) (tired--ignored-regexp)))))

(ert-deftest tired-jump-from-file-buffer ()
  "Jumping from a file buffer opens its directory and marks the file."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "alpha.txt")
    (tired-open)
    (let ((file-buffer (current-buffer)))
      (unwind-protect
          (progn
            (tired-jump)
            (should (derived-mode-p 'tired-mode))
            (should (equal tired--directory root))
            (should (equal (tired-entry-name (tired--entry-at-point))
                           "alpha.txt")))
        (kill-buffer file-buffer)))))

(ert-deftest tired-jump-from-tired-buffer-goes-up ()
  "Jumping from a tired buffer opens the parent and marks the directory."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (let ((origin (current-buffer)))
      (tired-tests--goto "sub")
      (tired-open)
      (tired-jump)
      (should (eq (current-buffer) origin))
      (should (equal (tired-entry-name (tired--entry-at-point)) "sub")))))

(ert-deftest tired-jump-uses-default-directory ()
  "Jumping from a buffer without a file uses `default-directory'."
  (tired-tests--with-fixture
    (with-temp-buffer
      (setq default-directory root)
      (tired-jump)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-bookmark-round-trip ()
  "A tired bookmark records the directory and restores the buffer."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
    (tired-find-directory root)
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
      (tired-find-directory root)
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
    (tired-find-directory root)
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
      (tired-find-directory root)
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
    (tired-find-directory root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-insert-subdir) :type 'user-error)))

(ert-deftest tired-refresh-keeps-inserted-sections ()
  "Refresh reloads inserted directories and keeps the sections."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (with-temp-file (expand-file-name "sub/new.txt") (insert "new"))
    (tired-refresh)
    (should (member "new.txt" (tired-tests--names)))
    (should (tired--inserted-p (expand-file-name "sub" root)))))

(ert-deftest tired-insert-subdir-guards-symlink-cycles ()
  "A symlink back to an ancestor does not recurse."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "loop")
    (tired-insert-subdir)
    (should (= 8 (length (tired-tests--names))))))

(ert-deftest tired-selection-targets-cover-inserted-entries ()
  "Selection and targets work inside inserted sections."
  (tired-tests--with-fixture
    (tired-find-directory root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (should (equal (mapcar #'tired-entry-name (tired--selection-targets))
                   '("inner.txt")))
    (tired-select-all)
    (should (= 8 (length (tired--selection-targets))))))

(ert-deftest tired-select-invert-flips-visible-entries ()
  "Inverting selects every visible entry that was not selected."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
    (tired-find-directory root)
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
    (tired-find-directory root)
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
    (tired-find-directory root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (should (equal (tired-tests--names) '("sub" "inner.txt")))))

(ert-deftest tired-narrow-prunes-deleted-paths ()
  "Refresh drops narrowed paths that vanished and widens when empty."
  (tired-tests--with-fixture
    (tired-find-directory root)
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
      (tired-find-directory root)
      (should (equal (tired--watch-directories)
                     (list (directory-file-name root))))
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (should (equal (sort (tired--watch-directories) #'string<)
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
        (tired-find-directory root)
        (tired-tests--goto "sub")
        (tired-insert-subdir)
        (should (member (expand-file-name "sub" root) added))
        (tired-refresh)
        (should (= 2 (length added)))
        (tired-remove-subdir)
        (should (= 1 (length removed)))))))

(ert-deftest tired-kill-buffer-removes-watches ()
  "Killing a tired buffer removes its file notification watches."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (removed nil) (counter 0))
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (&rest _) (list 'fake (cl-incf counter))))
                ((symbol-function 'file-notify-rm-watch)
                 (lambda (descriptor) (push descriptor removed))))
        (let ((buffer (tired-find-directory root)))
          (should (= 1 (length tired--watches)))
          (kill-buffer buffer)
          (should (= 1 (length removed))))))))

(ert-deftest tired-file-change-coalesces-into-one-timer ()
  "A second event keeps the pending timer instead of adding another."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired-find-directory root)
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
      (tired-find-directory root)
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
      (tired-find-directory root)
      (tired--file-changed '(descriptor created "/tmp/.#alpha.txt"))
      (should-not tired--revert-timer))))

(ert-deftest tired-collapse-single-entry-chain ()
  "A chain of single-entry directories becomes one file row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt")
      (insert "abc"))
    (tired-find-directory root)
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
    (tired-find-directory root)
    (should (member "branch" (tired-tests--names)))
    (should (member "empty" (tired-tests--names)))
    (should-not (member "branch/x/one.txt" (tired-tests--names)))))

(ert-deftest tired-collapse-hidden-final-file ()
  "A collapsed chain whose file is hidden follows the dotfile toggle."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "secret/a" root) t)
    (with-temp-file (expand-file-name "secret/a/.hiddenfile") (insert "h"))
    (tired-find-directory root)
    (should (member "secret/a/.hiddenfile" (tired-tests--names)))
    (tired-toggle-dotfiles)
    (should-not (member "secret/a/.hiddenfile" (tired-tests--names)))))

(ert-deftest tired-toggle-collapse-shows-real-rows ()
  "C switches between the collapsed row and the directory row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt") (insert "abc"))
    (tired-find-directory root)
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
    (tired-find-directory root)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))
    (with-temp-file (expand-file-name "chain/a/b/other.txt") (insert "x"))
    (tired-refresh)
    (should (member "chain" (tired-tests--names)))
    (should-not (member "chain/a/b/file.txt" (tired-tests--names)))))

(provide 'tired-tests)

;;; tired-tests.el ends here
