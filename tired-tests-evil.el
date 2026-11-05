;;; tired-tests-evil.el --- ERT tests for the Tired evil bindings  -*- lexical-binding: t -*-

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

;; Tests for the evil bindings.  Every test skips itself when the
;; evil library is absent.

;;; Code:

(require 'ert)

(require 'tired-tests-fixtures)

(declare-function evil-local-mode "evil" (&optional arg))

(declare-function evil-normal-state "evil" nil)

(declare-function evil-visual-line "evil" (&optional count))

(declare-function tired-evil-mode "tired-evil" (&optional arg))

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
          ;; The shell command keeps its dired key, so `evil-shell-command'
          ;; does not filter the listing through a shell.
          (should (eq (key-binding (key-parse "!"))
                      #'tired-do-shell-command))
          (should (eq (key-binding (key-parse "TAB"))
                      #'tired-toggle-subdir))
          ;; TAB toggles a file, so the two section commands keep no
          ;; evil key and the word motions stay.
          (should-not (eq (key-binding (key-parse "e"))
                          #'tired-expand-file))
          (should-not (eq (key-binding (key-parse "E"))
                          #'tired-collapse-file))
          ;; The middle button opens the row, because a read-only
          ;; listing has nothing to paste.
          (should (eq (key-binding (key-parse "<mouse-2>"))
                      #'tired-mouse-find-file-other-window))
          (should (eq (key-binding (key-parse "f")) #'tired-find-file))
          (should (eq (key-binding (key-parse "gr")) #'tired-refresh))
          ;; The search key narrows the listing instead of searching it.
          (should (eq (key-binding (key-parse "/")) #'tired-filter))
          ;; `evil-replace' names a character and a listing names a
          ;; file, so the remap turns its key into a rename.
          (should (eq (key-binding (key-parse "r"))
                      #'tired-rename))
          (should (eq (key-binding (key-parse "m"))
                      #'tired-select-toggle-next))
          ;; The toggle key replaces the selection invert on the evil map.
          (should (eq (key-binding (key-parse "~"))
                      #'tired-toggle-hidden))
          ;; The move command takes shift-R, so the evil replace state
          ;; stays out of a read-only listing.
          (should (eq (key-binding (key-parse "R")) #'tired-move))
          ;; The copy commands keep their `tired-mode-map' keys.
          (should (eq (key-binding (key-parse "W"))
                      #'tired-copy-relative-path))
          (should (eq (key-binding (key-parse "P"))
                      #'tired-copy-project-path))
          ;; Motion stays evil, so a Tired buffer is still navigable,
          ;; and the two line motions stop on the name.
          (should (eq (key-binding (key-parse "j")) #'tired-next-line))
          (should (eq (key-binding (key-parse "k"))
                      #'tired-previous-line))
          (should (eq (key-binding (key-parse "gg"))
                      #'evil-goto-first-line))
          ;; G skips the empty line below the listing.
          (should (eq (key-binding (key-parse "G"))
                      #'tired-goto-last-entry))
          ;; The down arrow character cycles the sort states, and the
          ;; arrow keys keep their evil line motion.
          (should (eq (key-binding (key-parse "↓"))
                      #'tired-sort))
          (should-not (eq (key-binding (key-parse "↑"))
                          #'tired-sort))
          (should-not (eq (key-binding (key-parse "<down>"))
                          #'tired-sort))
          (should-not (eq (key-binding (key-parse ">"))
                          #'tired-sort)))
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
          (should (eq (key-binding (key-parse "!"))
                      #'tired-do-shell-command))
          (should (eq (key-binding (key-parse "c")) #'tired-copy))
          (should (eq (key-binding (key-parse "R")) #'tired-move))
          (should (eq (key-binding (key-parse "m"))
                      #'tired-select-toggle))
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
          (should (eq (key-binding (key-parse "RET")) #'tired-find-file)))
      (tired-evil-mode -1)
      (evil-local-mode -1))))

(ert-deftest tired-evil-line-motion-lands-on-the-name ()
  "The evil line motions stop on the name of the row."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired root)
    (evil-local-mode 1)
    (unwind-protect
        (progn
          (tired-evil-mode 1)
          (tired-insert-subdir)
          (tired-tests--goto "sub")
          (call-interactively (key-binding (key-parse "j")))
          (should (equal (tired-entry-name (tired--row-at-point))
                         "deep/leaf.txt"))
          (should (= 2 (current-column)))
          (call-interactively (key-binding (key-parse "k")))
          (should (equal (tired-entry-name (tired--row-at-point)) "sub"))
          (should (= 0 (current-column))))
      (evil-normal-state)
      (tired-evil-mode -1)
      (evil-local-mode -1))))

(ert-deftest tired-evil-name-edit-enters-the-insert-state ()
  "A name edit types in the insert state and leaves it again.
The normal state map binds every row key ahead of the edit key map,
so only the insert state carries a typed character to a name."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (evil-local-mode 1)
      (unwind-protect
          (progn
            (tired-evil-mode 1)
            (should (eq (bound-and-true-p evil-state) 'normal))
            (tired-edit-names)
            (should (eq evil-state 'insert))
            (tired-tests--goto "alpha.txt")
            (let ((region (tired--rename-region)))
              (delete-region (car region) (cdr region))
              (goto-char (car region))
              (execute-kbd-macro "evil.txt"))
            (execute-kbd-macro (kbd "C-c C-c"))
            (should (eq evil-state 'normal))
            (should-not tired--name-edit)
            (should (file-regular-p (expand-file-name "evil.txt" root))))
        (evil-normal-state)
        (tired-evil-mode -1)
        (evil-local-mode -1)))))

(ert-deftest tired-evil-name-edit-survives-a-late-enable ()
  "Evil started during an edit enters the insert state at once, and a
buffer that leaves the local mode keeps no stale hook."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired-tests--with-trash
      (tired root)
      (evil-local-mode 1)
      (unwind-protect
          (progn
            (tired-edit-names)
            (should-not (bound-and-true-p tired-evil-local-mode))
            (tired-evil-mode 1)
            (should (bound-and-true-p tired-evil-local-mode))
            (should (eq (bound-and-true-p evil-state) 'insert))
            (tired-evil-local-mode -1)
            (should-not (bound-and-true-p tired-evil-local-mode))
            (should-not (memq #'tired-evil--name-edit
                              tired-name-edit-mode-hook)))
        (when tired--name-edit
          (tired-abort-edits))
        (tired-evil-mode -1)
        (evil-normal-state)
        (evil-local-mode -1)))))

(ert-deftest tired-evil-visual-range-covers-the-row-at-point ()
  "A visual range grows one row per line motion and keeps point's row.
The line motions carry the `:keep-visual' property, so evil leaves the
range unexpanded around them and `V j j' covers three rows."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (tired-tests--with-fixture
    (tired root)
    (evil-local-mode 1)
    (unwind-protect
        (progn
          (tired-evil-mode 1)
          (tired-tests--goto ".hidden")
          (execute-kbd-macro (kbd "Vjj"))
          (should (eq evil-state 'visual))
          (should (equal (tired-tests--target-names)
                         '(".hidden" "link" "alpha.txt")))
          (execute-kbd-macro (kbd "k"))
          (should (equal (tired-tests--target-names)
                         '(".hidden" "link")))
          (execute-kbd-macro (kbd "<escape>"))
          (should (eq evil-state 'normal))
          (tired-tests--goto ".hidden")
          (execute-kbd-macro (kbd "vjj"))
          (should (equal (tired-tests--target-names)
                         '(".hidden" "link" "alpha.txt"))))
      (evil-normal-state)
      (tired-evil-mode -1)
      (evil-local-mode -1))))

(ert-deftest tired-evil-quit-command-clears-the-filter ()
  "The evil quit command joins the filter quit list.
`tired--filter-quit-on-command' reads `this-command', so no key
binding reaches the clear, and the same list serves the Emacs quit
commands."
  (skip-unless (require 'evil nil t))
  (require 'tired-evil)
  (should (memq 'evil-force-normal-state tired-filter-quit-commands))
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "beta")
    (let ((this-command 'evil-force-normal-state))
      (tired--filter-quit-on-command))
    (should-not tired--filter)
    (should (= 5 (length (tired-tests--names))))))

(provide 'tired-tests-evil)

;;; tired-tests-evil.el ends here
