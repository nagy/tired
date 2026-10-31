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
      (should (equal (tired-entry-name (tired--row-at-point)) "link"))
      (tired-delete)
      (should (tired-entry-p (tired--row-at-point)))
      (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt")))))

(ert-deftest tired-delete-of-the-only-entry-empties-the-listing ()
  "Delete of the only row leaves an empty listing and no error."
  (let* ((root (file-name-as-directory (make-temp-file "tired-tests-" t)))
         (default-directory root)
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
    (should (equal (tired-entry-name (tired--row-at-point)) "link"))
    (delete-file (expand-file-name "link" root))
    (tired-refresh)
    (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt"))))

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
      (should (equal (tired-entry-name (tired--row-at-point)) "zeta.txt")))))

(ert-deftest tired-delete-of-the-last-expanded-file-keeps-the-row-above ()
  "Delete of the last expanded file stops on the row that remains."
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired-tests--write "notes.org" "* Intro\n* Body\n")
      (tired root)
      (tired-tests--goto "notes.org")
      (tired-toggle-subdir)
      (tired-tests--goto-section "Intro")
      (tired-delete)
      (should (equal (tired-entry-name (tired--row-at-point)) "link")))))

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

(provide 'tired-tests-file-ops)

;;; tired-tests-file-ops.el ends here
