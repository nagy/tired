;;; tired-tests-file-ops.el --- ERT tests for the Tired file commands  -*- lexical-binding: t -*-

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

;; Tests for the file commands, the session trash, the undo stack
;; and the shell command.

;;; Code:

(require 'ert)

(require 'cl-lib)

(require 'seq)

(require 'tired-tests-fixtures)

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

(ert-deftest tired-move-of-a-collapsed-leaf-keeps-the-chain-row ()
  "Move of a collapsed leaf keeps the chain row on the same line.
The destination keeps its own row, so point follows that row even
though the moved leaf sits inside the destination directory now."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (make-directory (expand-file-name "foo/a/b/c" root) t)
      (make-directory (expand-file-name "dest" root) t)
      (tired-tests--write "dest/keep.txt" "k")
      (tired root)
      (tired-tests--goto "foo/a/b/c")
      (tired-move (expand-file-name "dest" root))
      (should (file-directory-p (expand-file-name "dest/c" root)))
      (should (equal (tired-entry-name (tired--row-at-point)) "foo/a/b")))))

(ert-deftest tired-rename-file ()
  "Rename changes the name at point and undo returns the old name."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-rename "renamed.txt")
      (should (file-regular-p (expand-file-name "renamed.txt" root)))
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should (equal (tired-entry-name (tired--row-at-point)) "renamed.txt"))
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should-not (file-exists-p (expand-file-name "renamed.txt" root))))))

(ert-deftest tired-rename-keeps-the-selection ()
  "Rename reads the row at point and leaves the selection alone."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-select-toggle)
      (tired-tests--goto "beta.txt")
      (tired-rename "gamma.txt")
      (should (file-regular-p (expand-file-name "gamma.txt" root)))
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should (= 1 (length tired--selection))))))

(ert-deftest tired-rename-replaces-an-existing-path ()
  "Rename puts the replaced path into the trash and undo restores both."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-rename "beta.txt")
      (should (equal (tired-tests--contents
                      (expand-file-name "beta.txt" root))
                     "abc"))
      (should (= 1 (length (tired-tests--trash-entries))))
      (tired-undo)
      (should (equal (tired-tests--contents
                      (expand-file-name "alpha.txt" root))
                     "abc"))
      (should (equal (tired-tests--contents
                      (expand-file-name "beta.txt" root))
                     (make-string 40 ?x))))))

(ert-deftest tired-rename-rejects-a-directory-part ()
  "Rename takes a base name and never a path."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (should-error (tired-rename "sub/inner.txt") :type 'user-error)
      (should-error (tired-rename "") :type 'user-error)
      (should-error (tired-rename "..") :type 'user-error)
      (should (file-regular-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-rename-rejects-a-section ()
  "A section row names no file of its own."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (with-temp-file (expand-file-name "note.org" root)
        (insert "* One\n"))
      (tired root)
      (tired-tests--goto "note.org")
      (tired-expand-file)
      (tired-tests--goto-section "One")
      (should-error (tired-rename "other.org") :type 'user-error))))

(ert-deftest tired-edit-names-renames-a-row ()
  "A committed name edit renames the file and undo puts the old name back."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (should tired--name-edit)
      (should-not buffer-read-only)
      (tired-tests--edit-name "alpha.txt" "renamed.txt")
      (tired-commit-edits)
      (should (file-regular-p (expand-file-name "renamed.txt" root)))
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should-not tired--name-edit)
      (should buffer-read-only)
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should-not (file-exists-p (expand-file-name "renamed.txt" root))))))

(ert-deftest tired-edit-names-marks-one-undo-action ()
  "A commit of several names lands on the undo stack once."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "one.txt")
      (tired-tests--edit-name "beta.txt" "two.txt")
      (tired-commit-edits)
      (should (equal (mapcar #'car tired--undo-actions)
                     '("rename of 2 entries")))
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should (file-regular-p (expand-file-name "beta.txt" root)))
      (should-not (file-exists-p (expand-file-name "one.txt" root)))
      (should-not (file-exists-p (expand-file-name "two.txt" root))))))

(ert-deftest tired-edit-names-keeps-the-other-columns ()
  "Only a name cell accepts a change."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-edit-names)
      (tired-tests--goto "inner.txt")
      (goto-char (line-beginning-position))
      (should-error (insert "x") :type 'text-read-only)
      (goto-char (line-end-position))
      (should-error (insert "x") :type 'text-read-only)
      (tired-abort-edits)
      (should (equal (tired-entry-name (tired--row-at-point)) "inner.txt")))))

(ert-deftest tired-edit-names-rejects-a-duplicate-name ()
  "Two rows cannot take the same new name."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "same.txt")
      (tired-tests--edit-name "beta.txt" "same.txt")
      (should-error (tired-commit-edits) :type 'user-error)
      (should tired--name-edit)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should (file-regular-p (expand-file-name "beta.txt" root)))
      (should-not (file-exists-p (expand-file-name "same.txt" root))))))

(ert-deftest tired-edit-names-rejects-a-directory-part ()
  "A name edit leaves the directory of a row alone."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "sub/alpha.txt")
      (should-error (tired-commit-edits) :type 'user-error)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should-not (file-exists-p (expand-file-name "sub/alpha.txt" root))))))

(ert-deftest tired-edit-names-rejects-a-taken-over-name ()
  "A commit refuses a name that another renamed row leaves behind."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "beta.txt")
      (tired-tests--edit-name "beta.txt" "gamma.txt")
      (should-error (tired-commit-edits) :type 'user-error)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should (file-regular-p (expand-file-name "beta.txt" root)))
      (should (equal (tired-tests--contents
                      (expand-file-name "beta.txt" root))
                     (make-string 40 ?x))))))

(ert-deftest tired-edit-names-rejects-a-vanished-row ()
  "A commit refuses a row whose path left the disk."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "renamed.txt")
      (delete-file (expand-file-name "alpha.txt" root))
      (should-error (tired-commit-edits) :type 'user-error)
      (should tired--name-edit)
      (should-not (file-exists-p (expand-file-name "renamed.txt" root))))))

(ert-deftest tired-edit-names-trashes-an-existing-destination ()
  "A new name that exists on disk goes to the trash first."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "beta.txt")
      (tired-commit-edits)
      (should (equal (tired-tests--contents
                      (expand-file-name "beta.txt" root))
                     "abc"))
      (should (= 1 (length (tired-tests--trash-entries))))
      (tired-undo)
      (should (equal (tired-tests--contents
                      (expand-file-name "alpha.txt" root))
                     "abc"))
      (should (equal (tired-tests--contents
                      (expand-file-name "beta.txt" root))
                     (make-string 40 ?x))))))

(ert-deftest tired-edit-names-abort-drops-the-changes ()
  "Abort reprints the names and leaves the edit mode."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "junk.txt")
      (tired-abort-edits)
      (should-not tired--name-edit)
      (should buffer-read-only)
      (should-not (get-text-property (point-min) 'read-only))
      (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt"))
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should-not (file-exists-p (expand-file-name "junk.txt" root))))))

(ert-deftest tired-edit-names-leaves-a-section-read-only ()
  "A section row carries no name of its own."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired-tests--write "note.org" "* One\n")
      (tired root)
      (tired-tests--goto "note.org")
      (tired-expand-file)
      (tired-edit-names)
      (tired-tests--goto-section "One")
      (should-not (tired--rename-region))
      (should-error (insert "x") :type 'text-read-only)
      (tired-abort-edits))))

(ert-deftest tired-edit-names-holds-a-typed-name-across-a-redraw ()
  "A refresh waits while the name edit mode owns the buffer text."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "later.txt")
      (tired-refresh)
      (should tired--name-edit)
      (should (equal (mapcar #'cdr (tired--name-edit-changes))
                     '("later.txt")))
      (tired-commit-edits)
      (should (file-regular-p (expand-file-name "later.txt" root))))))

(ert-deftest tired-edit-names-renames-a-collapsed-leaf ()
  "The editable part of a chain row is the leaf name alone."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (make-directory (expand-file-name "foo/a/b/c" root) t)
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "foo/a/b/c" "d")
      (tired-commit-edits)
      (should (file-directory-p (expand-file-name "foo/a/b/d" root)))
      (should-not (file-directory-p (expand-file-name "foo/a/b/c" root)))
      (should (equal (tired-entry-name (tired--row-at-point)) "foo/a/b/d")))))

(ert-deftest tired-edit-names-commit-without-a-change ()
  "A commit that finds no new name leaves the mode and touches nothing."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-commit-edits)
      (should-not tired--name-edit)
      (should buffer-read-only)
      (should-not tired--undo-actions)
      (should (file-regular-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-edit-names-refuses-outside-the-edit-mode ()
  "The commit and the abort need the edit mode."
  (tired-tests--with-fixture
    (tired root)
    (should-error (tired-commit-edits) :type 'user-error)
    (should-error (tired-abort-edits) :type 'user-error)
    (tired-edit-names)
    (should-error (tired-edit-names) :type 'user-error)
    (tired-abort-edits)))

(ert-deftest tired-edit-names-reaches-the-user-through-m-x-alone ()
  "No key and no menu entry runs the name edit.
The command changes paths, so a stray key must not reach it."
  (tired-tests--with-fixture
    (tired root)
    (should-not (where-is-internal #'tired-edit-names tired-mode-map))
    (should (commandp #'tired-edit-names))
    (should (eq (lookup-key tired-name-edit-mode-map (kbd "C-c C-c"))
                #'tired-commit-edits))
    (should (eq (lookup-key tired-name-edit-mode-map (kbd "C-c C-k"))
                #'tired-abort-edits))))

(ert-deftest tired-edit-names-keeps-a-tilde-a-plain-name ()
  "A name of ~ stays a file name in the shown directory.
`expand-file-name' would read it as the home directory, so the
commit joins the directory and the name as plain text."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "~")
      (tired-commit-edits)
      (should (equal (tired-tests--contents (concat root "~"))
                     "abc"))
      (should-not (file-exists-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-rename-keeps-a-tilde-a-plain-name ()
  "The single rename reads the same target, so ~ stays local."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-rename "~")
      (should (equal (tired-tests--contents (concat root "~"))
                     "abc")))))

(ert-deftest tired-edit-names-rejects-a-directory-target ()
  "A commit refuses a name that an existing directory holds.
The trash would take the whole subtree, so the commit signals."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "sub")
      (should-error (tired-commit-edits) :type 'user-error)
      (should tired--name-edit)
      (should (file-directory-p (expand-file-name "sub" root)))
      (should (file-regular-p (expand-file-name "sub/inner.txt" root)))
      (should (file-regular-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-rename-rejects-a-directory-target ()
  "The single rename keeps the subtree of a directory too."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (should-error (tired-rename "sub") :type 'user-error)
      (should (file-directory-p (expand-file-name "sub" root)))
      (should (file-regular-p (expand-file-name "sub/inner.txt" root)))
      (should (file-regular-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-edit-names-rejects-a-blank-name ()
  "A name of spaces alone counts as an empty name."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (should-error (tired-rename "   ") :type 'user-error)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "   ")
      (should-error (tired-commit-edits) :type 'user-error)
      (should tired--name-edit)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (tired-abort-edits))))

(ert-deftest tired-edit-names-renames-a-plain-directory ()
  "An ordinary directory row edits its own name, not a chain leaf."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "sub" "other")
      (tired-commit-edits)
      (should (file-directory-p (expand-file-name "other" root)))
      (should (file-regular-p (expand-file-name "other/inner.txt" root)))
      (should-not (file-exists-p (expand-file-name "sub" root))))))

(ert-deftest tired-edit-names-keeps-a-failed-name-editable ()
  "A rename that fails keeps its row, and the other rows turn read only.
A name longer than the file system allows makes `rename-file'
signal after the check passed."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (let ((long (concat (make-string 300 ?y) ".txt")))
        (tired-tests--edit-name "alpha.txt" "one.txt")
        (tired-tests--edit-name "beta.txt" long)
        (let ((lines (tired-tests--with-messages (tired-commit-edits))))
          (should (= (length lines) 1))
          (should (string-match-p "1 failed" (car lines))))
        (should tired--name-edit)
        (should (file-regular-p (expand-file-name "one.txt" root)))
        (should (file-regular-p (expand-file-name "beta.txt" root)))
        (should (equal (mapcar #'cdr (tired--name-edit-changes))
                       (list long)))
        (goto-char (point-min))
        (should (search-forward "one.txt" nil t))
        (should (get-text-property (match-beginning 0) 'read-only))
        (goto-char (point-min))
        (should (search-forward (substring long 0 4) nil t))
        (should-not (get-text-property (match-beginning 0) 'read-only))
        (tired-abort-edits)
        (should (file-regular-p (expand-file-name "one.txt" root)))))))

(ert-deftest tired-file-commands-refuse-while-names-are-editable ()
  "A file command signals while the names accept changes.
Its redraw would draw nothing, so the listing would disagree with
the disk."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-edit-names)
      (should-error (tired--apply-to-targets "Ignored" nil #'ignore)
                    :type 'user-error)
      (should-error (tired-delete) :type 'user-error)
      (should-error (tired-rename "other.txt") :type 'user-error)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (tired-abort-edits)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (should-not (file-exists-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-copy-prompts-without-another-window ()
  "Copy asks in the minibuffer when no other window shows a Tired buffer."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (let (asked)
        (cl-letf (((symbol-function 'read-directory-name)
                   (lambda (&rest _)
                     (setq asked t)
                     (expand-file-name "out" root))))
          (make-directory (expand-file-name "out" root))
          (call-interactively #'tired-copy))
        (should asked)
        (should (file-regular-p (expand-file-name "out/alpha.txt" root)))))))

(ert-deftest tired-copy-uses-another-window-directory-at-once ()
  "Copy with another Tired window asks no question and copies at once.
The copy joins the undo stack, so `tired-undo' removes it again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((other (file-name-as-directory
                    (make-temp-file "tired-tests-other-" t))))
        (unwind-protect
            (progn
              (tired root)
              (tired-tests--goto "alpha.txt")
              (tired-tests--with-other-window other
                (cl-letf (((symbol-function 'read-directory-name)
                           (lambda (&rest _)
                             (ert-fail "tired-copy asked a question"))))
                  (call-interactively #'tired-copy))
                (should (equal "abc"
                               (tired-tests--contents
                                (expand-file-name "alpha.txt" other))))
                (should (equal "abc"
                               (tired-tests--contents
                                (expand-file-name "alpha.txt" root))))
                (tired-undo)
                (should-not (file-exists-p
                             (expand-file-name "alpha.txt" other)))
                (should (equal "abc"
                               (tired-tests--contents
                                (expand-file-name "alpha.txt" root))))))
          (delete-directory other t))))))

(ert-deftest tired-copy-prompts-when-dwim-is-off ()
  "The dwim option nil keeps the question in the minibuffer for copy."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((other (file-name-as-directory
                    (make-temp-file "tired-tests-other-" t)))
            (tired-dwim-target nil))
        (unwind-protect
            (progn
              (tired root)
              (make-directory (expand-file-name "out" root))
              (tired-tests--goto "alpha.txt")
              (tired-tests--with-other-window other
                (let (asked)
                  (cl-letf (((symbol-function 'read-directory-name)
                             (lambda (&rest _)
                               (setq asked t)
                               (expand-file-name "out" root))))
                    (call-interactively #'tired-copy))
                  (should asked)
                  (should (file-regular-p
                           (expand-file-name "out/alpha.txt" root)))
                  (should-not (file-exists-p
                               (expand-file-name "alpha.txt" other))))))
          (delete-directory other t))))))

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

(ert-deftest tired-other-tired-directory-finds-another-window ()
  "The dwim helper returns the directory of a Tired buffer in another window."
  (tired-tests--with-fixture
    (let ((other (file-name-as-directory
                  (make-temp-file "tired-tests-other-" t))))
      (unwind-protect
          (progn
            (tired root)
            (tired-tests--with-other-window other
              (should (equal (tired--other-tired-directory) other))))
        (delete-directory other t)))))

(ert-deftest tired-other-tired-directory-skips-the-shown-directory ()
  "The dwim helper ignores a window that shows the same directory."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--with-other-window root
      (should-not (tired--other-tired-directory)))))

(ert-deftest tired-move-uses-another-window-directory-at-once ()
  "Move with another Tired window asks no question and moves at once."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((other (file-name-as-directory
                    (make-temp-file "tired-tests-other-" t))))
        (unwind-protect
            (progn
              (tired root)
              (tired-tests--goto "alpha.txt")
              (tired-tests--with-other-window other
                (cl-letf (((symbol-function 'read-file-name)
                           (lambda (&rest _)
                             (ert-fail "tired-move asked a question"))))
                  (call-interactively #'tired-move))
                (should (equal "abc"
                               (tired-tests--contents
                                (expand-file-name "alpha.txt" other))))
                (should-not (file-exists-p
                             (expand-file-name "alpha.txt" root)))
                (tired-undo)
                (should (equal "abc"
                               (tired-tests--contents
                                (expand-file-name "alpha.txt" root))))
                (should-not (file-exists-p
                             (expand-file-name "alpha.txt" other)))))
          (delete-directory other t))))))

(ert-deftest tired-move-prompts-without-another-window ()
  "Move asks in the minibuffer when no other window shows a Tired buffer."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (let (asked)
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _)
                     (setq asked t)
                     (expand-file-name "renamed.txt" root))))
          (call-interactively #'tired-move))
        (should asked)
        (should (file-regular-p (expand-file-name "renamed.txt" root)))))))

(ert-deftest tired-move-prompts-when-dwim-is-off ()
  "The dwim option nil keeps the question in the minibuffer."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((other (file-name-as-directory
                    (make-temp-file "tired-tests-other-" t)))
            (tired-dwim-target nil))
        (unwind-protect
            (progn
              (tired root)
              (tired-tests--goto "alpha.txt")
              (tired-tests--with-other-window other
                (let (asked)
                  (cl-letf (((symbol-function 'read-file-name)
                             (lambda (&rest _)
                               (setq asked t)
                               (expand-file-name "renamed.txt" root))))
                    (call-interactively #'tired-move))
                  (should asked)
                  (should (file-regular-p
                           (expand-file-name "renamed.txt" root)))
                  (should-not (file-exists-p
                               (expand-file-name "alpha.txt" other))))))
          (delete-directory other t))))))

(ert-deftest tired-trash-directory-defaults-to-a-session-directory ()
  "A nil option names a per-process directory under the temp dir.
Two Emacs sessions must not share one trash, so the default name
carries the process id.  A set option wins."
  (let ((tired-trash-directory nil))
    (should (equal (tired--trash-root)
                   (expand-file-name
                    (format "tired-trash-%d-%d/" (user-uid) (emacs-pid))
                    temporary-file-directory))))
  (let ((tired-trash-directory "/tmp/my-trash/"))
    (should (equal (tired--trash-root) "/tmp/my-trash/"))))

(ert-deftest tired-trash-directory-is-a-user-option ()
  "A user can set the trash location through Custom."
  (should (custom-variable-p 'tired-trash-directory))
  (should (eq (car (get 'tired-trash-directory 'custom-type)) 'choice)))

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

(ert-deftest tired-delete-leaves-point-on-the-next-entry ()
  "Delete moves point to the entry below the removed one."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt")))))

(ert-deftest tired-delete-of-the-last-entry-keeps-the-row-above ()
  "Delete of the last row leaves point on the last row that stays."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-goto-last-entry)
      (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt"))
      (tired-delete)
      (should (tired-entry-p (tired--row-at-point)))
      (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt")))))

(ert-deftest tired-delete-of-the-only-entry-empties-the-listing ()
  "Delete of the only row leaves an empty listing and no error."
  (let* ((root (file-name-as-directory (make-temp-file "tired-tests-" t)))
         (default-directory root)
         (tired-delete-delay nil)
         (tired--size-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "only.txt") (insert "x"))
          (tired-tests--with-trash
            (tired root)
            (tired-goto-last-entry)
            (tired-delete)
            (should-not (tired--row-at-point))
            (should-not (tired--visible-entries))))
      (delete-directory root t))))

(ert-deftest tired-refresh-after-a-vanished-last-row-keeps-the-line ()
  "A refresh whose last row left the disk holds the last row."
  (tired-tests--with-fixture
    (tired root)
    (tired-goto-last-entry)
    (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt"))
    (delete-file (expand-file-name "beta.txt" root))
    (tired-refresh)
    (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt"))))

(ert-deftest tired-delete-of-a-directory-leaves-point-on-the-next-entry ()
  "Delete of a directory with rows below it moves point past its subtree."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-delete)
      (should (equal (tired-entry-name (tired--row-at-point)) ".hidden")))))

(ert-deftest tired-delete-of-an-expanded-file-leaves-point-on-the-next-entry ()
  "Delete of an expanded file moves point past the sections of that file."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired-tests--write "notes.org" "* Intro\n* Body\n")
      (tired-tests--write "zeta.txt" "z")
      (tired root)
      (tired-tests--goto "notes.org")
      (tired-toggle-subdir)
      (tired-tests--goto-section "Intro")
      (tired-delete)
      (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt")))))

(ert-deftest tired-delete-of-a-collapsed-leaf-keeps-the-chain-row ()
  "Delete of a collapsed leaf keeps the chain row on the same line.
A single-entry chain shows one row for `foo/a/b/c'.  The delete of
the empty directory `c' leaves `foo/a/b' on that line, so point
must stay there instead of moving down to the row below."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (make-directory (expand-file-name "foo/a/b/c" root) t)
      (tired root)
      (tired-tests--goto "foo/a/b/c")
      (tired-delete)
      (should (equal (tired-entry-name (tired--row-at-point)) "foo/a/b")))))

(ert-deftest tired-delete-of-a-nested-collapsed-leaf-keeps-the-chain-row ()
  "A nested collapsed row keeps its line when its leaf leaves.
The row above it stays, so point follows that row and not the row
far below."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (make-directory (expand-file-name "sub/one/two/three" root) t)
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-tests--goto "one/two/three")
      (tired-delete)
      (should (equal (tired-entry-name (tired--row-at-point))
                     "one/two")))))

(ert-deftest tired-delete-of-the-last-expanded-file-keeps-the-row-above ()
  "Delete of the last expanded file stops on the row that remains.
The plain name order puts the Org file below every other file, so
the test binds `tired-sort-by-extension' to nil."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired-tests--write "notes.org" "* Intro\n* Body\n")
      (let ((tired-sort-by-extension nil))
        (tired root)
        (tired-tests--goto "notes.org")
        (tired-toggle-subdir)
        (tired-tests--goto-section "Intro")
        (tired-delete)
        (should (equal (tired-entry-name (tired--row-at-point)) "link"))))))

(ert-deftest tired-delete-past-point-reaches-the-next-surviving-entry ()
  "Delete of a run that covers point moves point below the whole run.
The row below point leaves the listing too, so the plain next row
is gone.  Point must land on the first row that stays below the
run, not on the first line."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto ".hidden")
      (tired-select-toggle)
      (tired-tests--goto "alpha.txt")
      (tired-select-toggle)
      (tired-tests--goto "beta.txt")
      (tired-select-toggle)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (should (equal (tired-tests--names) '("sub" "link")))
      (should (equal (tired-entry-name (tired--row-at-point)) "link")))))

(ert-deftest tired-delete-of-the-tail-keeps-the-last-remaining-entry ()
  "Delete of every row below point stops on the last row that remains."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "beta.txt")
      (tired-select-toggle)
      (tired-tests--goto "link")
      (tired-select-toggle)
      (tired-tests--goto "beta.txt")
      (tired-delete)
      (should (equal (tired-tests--names) '("sub" ".hidden" "alpha.txt")))
      (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt")))))

(ert-deftest tired-delete-reports-partial-failure ()
  "A vanished target does not stop the remaining targets.
The command prints one line that names the failed path."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-select-toggle)
      (tired-tests--goto "beta.txt")
      (tired-select-toggle)
      (delete-file (expand-file-name "beta.txt" root))
      (let ((lines (tired-tests--with-messages (tired-delete))))
        (should (= (length lines) 1))
        (should (string-match-p "beta\\.txt" (car lines)))
        (should (string-match-p "1 failed" (car lines))))
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-copy-prints-one-summary-line ()
  "A copy prints one line with the count and the destination."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (should (equal (tired-tests--with-messages (tired-copy destination))
                       (list (format "Copied 1 entry to %s"
                                     (abbreviate-file-name destination)))))))))

(ert-deftest tired-undo-prints-the-restored-count ()
  "Undo prints one line with the number of paths that moved back."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (tired-select-toggle)
        (tired-tests--goto "beta.txt")
        (tired-select-toggle)
        (tired-copy destination)
        (should (equal (tired-tests--with-messages (tired-undo))
                       (list (format "Undid copy into %s (2 entries)"
                                     (abbreviate-file-name destination)))))))))

(ert-deftest tired-mkdir-creates-a-directory ()
  "mkdir creates the directory and undo removes it again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((path (expand-file-name "fresh/nested" root)))
        (tired-mkdir path)
        (should (file-directory-p path))
        (should (member "fresh/nested" (tired-tests--names)))
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

(ert-deftest tired-undo-push-functions-is-a-user-option ()
  "A user can set the undo hook through Custom.
The hook is the one place a global undo package takes over, so it
must be a defcustom and not a plain defvar."
  (should (custom-variable-p 'tired-undo-push-functions))
  (should (eq (get 'tired-undo-push-functions 'custom-type) 'hook)))

(ert-deftest tired-undo-without-actions-errors ()
  "Undo signals a user error when the stack is empty."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (should-error (tired-undo) :type 'user-error))))

(ert-deftest tired-redo-without-an-undone-action-errors ()
  "Redo signals a user error when no undone action waits."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (should-error (tired-redo) :type 'user-error))))

(ert-deftest tired-redo-errors-while-the-hook-owns-the-actions ()
  "A user with an undo hook takes no redo path."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((tired-undo-push-functions (list #'ignore)))
        (tired-tests--goto "alpha.txt")
        (tired-delete)
        (should-not tired--undo-actions)
        (should-error (tired-redo) :type 'user-error)))))

(ert-deftest tired-redo-deletes-the-entry-again ()
  "Redo moves a restored entry back into the trash.
One action keeps one trash name, so a cycle grows no entry and
loses no byte."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (should (= 1 (length (tired-tests--trash-entries))))
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should-not (tired-tests--trash-entries))
      (tired-redo)
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should (= 1 (length (tired-tests--trash-entries))))
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (should-not (tired-tests--trash-entries)))))

(ert-deftest tired-redo-moves-the-entry-again ()
  "Redo moves a restored entry to its destination again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "renamed.txt" root)))
        (tired-tests--goto "alpha.txt")
        (tired-move destination)
        (tired-undo)
        (should (file-regular-p (expand-file-name "alpha.txt" root)))
        (tired-redo)
        (should (file-regular-p destination))
        (should-not (file-exists-p (expand-file-name "alpha.txt" root)))))))

(ert-deftest tired-redo-copies-the-entry-again ()
  "Redo restores the copy from the trash, bytes and all."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (tired-copy destination)
        (tired-undo)
        (should-not (file-exists-p
                     (expand-file-name "alpha.txt" destination)))
        (tired-redo)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "abc"))
        (should-not (tired-tests--trash-entries))))))

(ert-deftest tired-redo-copy-parks-the-replaced-file-again ()
  "Redo of an overwriting copy takes the old file back out again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (with-temp-file (expand-file-name "alpha.txt" destination)
          (insert "old"))
        (tired-tests--goto "alpha.txt")
        (tired-copy destination)
        (tired-undo)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "old"))
        (tired-redo)
        (should (equal (tired-tests--contents
                        (expand-file-name "alpha.txt" destination))
                       "abc"))
        (should (= 1 (length (tired-tests--trash-entries))))
        (should (equal (tired-tests--contents
                        (expand-file-name
                         (car (tired-tests--trash-entries))
                         tired-trash-directory))
                       "old"))))))

(ert-deftest tired-redo-renames-the-entry-again ()
  "Redo returns the new name after an undo."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-rename "renamed.txt")
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (tired-redo)
      (should (file-regular-p (expand-file-name "renamed.txt" root)))
      (should-not (file-exists-p (expand-file-name "alpha.txt" root))))))

(ert-deftest tired-redo-commits-the-name-edits-again ()
  "Redo of a commit renames every row of the commit."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-edit-names)
      (tired-tests--edit-name "alpha.txt" "one.txt")
      (tired-tests--edit-name "beta.txt" "two.txt")
      (tired-commit-edits)
      (tired-undo)
      (should (file-regular-p (expand-file-name "alpha.txt" root)))
      (tired-redo)
      (should (file-regular-p (expand-file-name "one.txt" root)))
      (should (file-regular-p (expand-file-name "two.txt" root)))
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should-not (file-exists-p (expand-file-name "beta.txt" root))))))

(ert-deftest tired-redo-restores-a-created-directory-with-its-content ()
  "Redo of a mkdir brings the directory back from the trash."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-mkdir (expand-file-name "new/deep" root))
      (with-temp-file (expand-file-name "new/deep/keep.txt" root)
        (insert "kept"))
      (tired-undo)
      (should-not (file-exists-p (expand-file-name "new" root)))
      (tired-redo)
      (should (file-directory-p (expand-file-name "new/deep" root)))
      (should (equal (tired-tests--contents
                      (expand-file-name "new/deep/keep.txt" root))
                     "kept")))))

(ert-deftest tired-redo-creates-the-empty-file-again ()
  "Redo of an undo of a touch creates the file again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((path (expand-file-name "new.txt" root)))
        (tired-touch path)
        (tired-undo)
        (should-not (file-exists-p path))
        (tired-redo)
        (should (file-regular-p path))
        (should (= 0 (file-attribute-size (file-attributes path))))))))

(ert-deftest tired-redo-touches-an-existing-file-again ()
  "Redo of an undone touch moves the modification time forward."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let* ((path (expand-file-name "alpha.txt" root))
             (past (time-subtract (current-time) (days-to-time 3))))
        (set-file-times path past)
        (tired-touch path)
        (tired-undo)
        (should (time-equal-p
                 (file-attribute-modification-time (file-attributes path))
                 past))
        (tired-redo)
        (should (time-less-p
                 past
                 (file-attribute-modification-time
                  (file-attributes path))))))))

(ert-deftest tired-redo-stack-clears-on-a-new-file-command ()
  "A new action invalidates every undone one."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (tired-undo)
      (should tired--redo-actions)
      (tired-tests--goto "beta.txt")
      (tired-delete)
      (should-not tired--redo-actions)
      (should-error (tired-redo) :type 'user-error))))

(ert-deftest tired-redo-prints-the-count ()
  "Redo prints one line with the number of paths that moved."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (let ((destination (expand-file-name "out" root)))
        (make-directory destination)
        (tired-tests--goto "alpha.txt")
        (tired-select-toggle)
        (tired-tests--goto "beta.txt")
        (tired-select-toggle)
        (tired-copy destination)
        (tired-undo)
        (should (equal (tired-tests--with-messages (tired-redo))
                       (list (format "Redid copy into %s (2 entries)"
                                     (abbreviate-file-name
                                      destination)))))))))

(ert-deftest tired-redo-reaches-the-user-through-m-x-alone ()
  "No key and no menu entry runs `tired-redo'.
The command changes paths, so a stray key must not reach it.  `M-x'
finds it through the autoload in `tired.el'."
  (tired-tests--with-fixture
    (tired root)
    (should-not (where-is-internal #'tired-redo tired-mode-map))
    (should (commandp #'tired-redo))))

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

(ert-deftest tired-do-shell-command-appends-the-file-name ()
  "A command without a mark runs once per target, with its name."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (let ((result (tired-tests--shell-run "wc")))
      (should (equal (car result) '("wc alpha.txt")))
      (should (= 1 (cdr result))))))

(ert-deftest tired-do-shell-command-runs-a-star-mark-once ()
  "A `*' mark takes the whole selected file list and runs one command."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (let ((result (tired-tests--shell-run "du -sh *")))
      (should (equal (car result) '("du -sh alpha.txt beta.txt")))
      (should (= 1 (cdr result)))
      (should-not tired--selection))))

(ert-deftest tired-do-shell-command-runs-a-question-mark-per-file ()
  "A `?' mark takes one file name, so the command runs once per target."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (should (equal (car (tired-tests--shell-run "gzip ?"))
                   '("gzip alpha.txt; gzip beta.txt")))))

(ert-deftest tired-do-shell-command-backgrounds-with-a-trailing-ampersand ()
  "A trailing `&' gives one background job per file and no refresh."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (let ((result (tired-tests--shell-run "gzip ? &")))
      (should (equal (car result)
                     '("gzip alpha.txt & gzip beta.txt & wait")))
      (should (= 0 (cdr result))))))

(ert-deftest tired-do-shell-command-backgrounds-the-file-list-once ()
  "A `*' mark with a trailing `&' makes one background job."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (should (equal (car (tired-tests--shell-run "du -sh * &"))
                   '("du -sh alpha.txt beta.txt &")))))

(ert-deftest tired-do-shell-command-sequences-a-trailing-semicolon ()
  "A trailing `;' runs the files one after another in one background job."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (let ((result (tired-tests--shell-run "gzip ?;")))
      (should (equal (car result)
                     '("( gzip alpha.txt; gzip beta.txt ) &")))
      (should (= 0 (cdr result))))))

(ert-deftest tired-do-shell-command-refreshes-after-a-sync-run ()
  "A synchronous command refreshes the listing once."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should (= 1 (cdr (tired-tests--shell-run "touch"))))))

(ert-deftest tired-do-shell-command-asks-about-a-bare-mark ()
  "A `*' inside a word stays for the shell, so tired asks first."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (let ((asked nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) nil)))
        (should-error (tired-do-shell-command "ls *.txt") :type 'user-error))
      (should asked))
    (let ((tired-confirm-shell-command nil))
      (should (equal (car (tired-tests--shell-run "ls *.txt"))
                     '("ls *.txt alpha.txt"))))))

(ert-deftest tired-do-shell-command-rejects-two-mark-kinds ()
  "Both substitution marks in one command signal a user error."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-do-shell-command "echo * ?") :type 'user-error)))

(ert-deftest tired-do-shell-command-protects-a-leading-dash ()
  "A name that starts with a dash takes a leading `./'."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name "-dash.txt" root) (insert "dash"))
    (tired root)
    (tired-tests--goto "-dash.txt")
    (should (equal (car (tired-tests--shell-run "rm"))
                   '("rm ./-dash.txt")))))

(ert-deftest tired-do-shell-command-names-an-inserted-subdirectory ()
  "A target below the shown directory takes a relative name."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (should (equal (car (tired-tests--shell-run "wc"))
                   '("wc sub/inner.txt")))))

(ert-deftest tired-shell-marks-fill-every-isolated-mark ()
  "Two marks that one space separates both take the file name."
  (should (equal (tired-tests--shell-mark-fills "mv * *" "F") "mv F F"))
  (should (equal (tired-tests--shell-mark-fills "cp `?` x" "F") "cp F x"))
  ;; A mark inside the replacement text never fills again.
  (should (equal (tired-tests--shell-mark-fills "ls *" "*") "ls *"))
  (should-not (tired--shell-keeps-mark-p "ls *" "*"))
  (should (tired--shell-keeps-mark-p "ls *.txt" "*"))
  (should (tired--shell-keeps-mark-p "ls ?.txt" "?")))

(ert-deftest tired-mode-binds-the-shell-command ()
  "`!' runs the shell command, the way `dired-do-shell-command' does."
  (tired-tests--with-fixture
    (tired root)
    (should (eq (key-binding (key-parse "!")) #'tired-do-shell-command))))

(ert-deftest tired-undo-reaches-the-user-through-m-x-alone ()
  "No key and no menu entry runs `tired-undo'.
The command changes paths, so a stray key must not reach it.  `M-x'
finds it through the autoload in `tired.el'."
  (tired-tests--with-fixture
    (tired root)
    (should-not (where-is-internal #'tired-undo tired-mode-map))
    (should (commandp #'tired-undo))))

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

(ert-deftest tired-delete-with-a-nil-delay-deletes-at-once ()
  "A nil delay keeps the old behaviour: one command, no flag."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (should-not tired-delete-delay)
      (tired-tests--goto "alpha.txt")
      (tired-delete)
      (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
      (should-not tired--flagged-deletion))))

(ert-deftest tired-delete-with-a-zero-delay-deletes-at-once ()
  "A zero delay deletes at once, so a flag can never wait."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 0))
        (tired root)
        (tired-tests--goto "alpha.txt")
        (tired-delete)
        (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
        (should-not tired--flagged-deletion)))))

(ert-deftest tired-delete-delay-keeps-the-files-until-the-countdown-ends ()
  "A delayed delete flags the row, keeps the file and stores no undo yet."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-delete)
          (should (tired--flagged-deletion-p
                   (expand-file-name "alpha.txt" root)))
          (should (file-regular-p (expand-file-name "alpha.txt" root)))
          (should-not (tired-tests--trash-entries))
          (should-not tired--undo-actions)
          (should (= 1 (length (tired-tests--delete-countdowns
                                scheduled)))))))))

(ert-deftest tired-delete-delay-adds-a-second-batch ()
  "A second delete joins the flag set and starts the countdown again."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-delete)
          (tired-tests--goto "beta.txt")
          (tired-delete)
          (should (= 2 (length tired--flagged-deletion)))
          (should (file-regular-p (expand-file-name "alpha.txt" root)))
          (should (file-regular-p (expand-file-name "beta.txt" root)))
          (should (= 2 (length (tired-tests--delete-countdowns
                                scheduled)))))))))

(ert-deftest tired-delete-flagged-removes-exactly-the-flagged-paths ()
  "The countdown removes the flagged rows and no other selected row."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-select-toggle)
          (tired-tests--goto "beta.txt")
          (tired-select-toggle)
          (tired-delete)
          (tired-tests--goto "sub")
          (tired-select-toggle)
          (should (equal (tired-tests--target-names) '("sub")))
          (tired--delete-flagged (current-buffer))
          (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
          (should-not (file-exists-p (expand-file-name "beta.txt" root)))
          (should (file-directory-p (expand-file-name "sub" root)))
          (should (equal (tired-tests--target-names) '("sub")))
          (should-not tired--flagged-deletion)
          (should-not tired--delete-timer)
          (should (= 2 (length (tired-tests--trash-entries)))))))))

(ert-deftest tired-delete-flagged-pushes-one-undo-action ()
  "One undo action covers the whole countdown, and it restores each path."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-select-toggle)
          (tired-tests--goto "beta.txt")
          (tired-select-toggle)
          (tired-delete)
          (tired--delete-flagged (current-buffer))
          (should (= 1 (length tired--undo-actions)))
          (tired-undo)
          (should (equal (tired-tests--contents
                          (expand-file-name "alpha.txt" root))
                         "abc"))
          (should (equal (tired-tests--contents
                          (expand-file-name "beta.txt" root))
                         (make-string 40 ?x))))))))

(ert-deftest tired-delete-flagged-waits-for-a-minibuffer ()
  "A countdown that ends inside a prompt waits and retries later."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-delete)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () (selected-window))))
            (tired--delete-flagged (current-buffer)))
          (should (file-regular-p (expand-file-name "alpha.txt" root)))
          (should (tired--flagged-deletion-p
                   (expand-file-name "alpha.txt" root)))
          (should (= 2 (length (tired-tests--delete-countdowns
                                scheduled))))
          (tired--delete-flagged (current-buffer))
          (should-not (file-exists-p (expand-file-name "alpha.txt" root)))
          (should-not tired--flagged-deletion))))))

(ert-deftest tired-edit-names-cancels-a-delayed-delete ()
  "An in-place name edit drops the flags and stops the countdown."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-delete)
          (tired-edit-names)
          (should-not tired--flagged-deletion)
          (should-not tired--delete-timer)
          (should (memq timer cancelled))
          (should (file-regular-p (expand-file-name "alpha.txt" root)))
          (tired-abort-edits))))))

(ert-deftest tired-killing-a-buffer-cancels-a-delayed-delete ()
  "Killing the listing stops the countdown, so no dead buffer deletes."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3))
        (tired-tests--with-delete-timers
          (tired root)
          (tired-tests--goto "alpha.txt")
          (tired-delete)
          (kill-buffer (current-buffer))
          (should (memq timer cancelled))
          (should (file-regular-p (expand-file-name "alpha.txt" root))))))))

(ert-deftest tired-copy-ignores-a-flagged-row ()
  "A copy acts on the selection alone and leaves the flag set waiting."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (let ((tired-delete-delay 3)
            (destination (expand-file-name "out" root)))
        (tired-tests--with-delete-timers
          (tired root)
          (make-directory destination)
          (tired-tests--goto "alpha.txt")
          (tired-select-toggle)
          (tired-tests--goto "beta.txt")
          (tired-select-toggle)
          (tired-delete)
          (tired-tests--goto "sub")
          (tired-select-toggle)
          (should (equal (tired-tests--target-names) '("sub")))
          (tired-copy destination)
          (should (file-directory-p (expand-file-name "sub" destination)))
          (should-not (file-exists-p (expand-file-name "alpha.txt"
                                                       destination)))
          (should (file-regular-p (expand-file-name "alpha.txt" root)))
          (should (tired--flagged-deletion-p
                   (expand-file-name "alpha.txt" root))))))))

(provide 'tired-tests-file-ops)

;;; tired-tests-file-ops.el ends here
