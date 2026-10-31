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
          (should (eq (key-binding (key-parse "f")) #'tired-find-file))
          (should (eq (key-binding (key-parse "gr")) #'tired-refresh))
          ;; The search key narrows the listing instead of searching it.
          (should (eq (key-binding (key-parse "/")) #'tired-filter))
          ;; `evil-replace' has nothing to do in a read-only listing,
          ;; so the remap turns its key into a reload.
          (should (eq (key-binding (key-parse "r"))
                      #'revert-buffer-quick))
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
          ;; Motion stays evil, so a Tired buffer is still navigable.
          (should (eq (key-binding (key-parse "j")) #'evil-next-line))
          (should (eq (key-binding (key-parse "gg"))
                      #'evil-goto-first-line))
          ;; G skips the empty line below the listing.
          (should (eq (key-binding (key-parse "G"))
                      #'tired-goto-last-entry)))
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

(provide 'tired-tests-evil)

;;; tired-tests-evil.el ends here
