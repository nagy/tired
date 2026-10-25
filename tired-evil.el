;;; tired-evil.el --- Evil bindings for tired  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; URL: https://github.com/nagy/tired
;; Version: 0.1.0
;; Keywords: files
;; Package-Requires: ((emacs "31.1") (evil "1.14"))

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

;; This file is optional.  It gives a tired buffer evil bindings that
;; keep the motions: j, k, gg, G, C-d, C-u, /, n and N keep their
;; meaning, and every tired command gets a direct key.
;;
;;   (require 'tired-evil)
;;   (tired-evil-mode 1)
;;
;; A command acts on the transient selection first, then on the Emacs
;; region, then on the row at point, so a visual range feeds delete,
;; copy and move without an extra step.

;;; Code:

(require 'evil)
(require 'tired)

(defvar tired-evil-keys
  '(;; Opening a row.
    ("RET" . tired-open)
    ("o" . tired-open-other-window)
    ("-" . tired-up-directory)
    ("^" . tired-up-directory)
    ("TAB" . tired-toggle-subdir)
    ("gf" . tired-find-file)
    ("gF" . tired-find-file-other-window)
    ("q" . quit-window)
    ;; Tree and sections.
    ("i" . tired-insert-subdir)
    ("M-i" . tired-remove-subdir)
    ("e" . tired-expand-file)
    ("E" . tired-collapse-file)
    ("C" . tired-toggle-collapse)
    ;; View.
    ("gr" . tired-refresh)
    ("s" . tired-sort)
    ("f" . tired-filter)
    ("F" . tired-clear-filter)
    ("." . tired-toggle-dotfiles)
    ("N" . tired-toggle-narrow)
    ("A" . tired-toggle-auto-revert)
    ;; Selection.
    ("SPC" . tired-select-toggle-next)
    ("M-SPC" . tired-select-toggle)
    ("t" . tired-select-all)
    ("u" . tired-select-none)
    ("~" . tired-select-invert)
    ;; Files.
    ("D" . tired-delete)
    ("c" . tired-copy)
    ("m" . tired-move)
    ("+" . tired-mkdir)
    ("M-t" . tired-touch)
    ("U" . tired-undo)
    ("y" . tired-copy-name)
    ("w" . tired-copy-path))
  "Keys that `tired-evil-mode' binds in normal state.
Each entry is a key description and the command it runs.  The
listing reads the selection, the region and then the row at point,
so a visual range reaches every file command.")

(defvar tired-evil-visual-keys
  '(("D" . tired-delete)
    ("c" . tired-copy)
    ("m" . tired-move)
    ("U" . tired-undo)
    ("y" . tired-copy-name)
    ("w" . tired-copy-path)
    ("SPC" . tired-select-toggle))
  "Keys that `tired-evil-mode' binds in visual state.
A narrow set, because visual state needs its text objects.  Every
command here reads the active region.")

(defun tired-evil--bind (state keys)
  "Bind KEYS as `tired-evil-local-mode' keys in STATE."
  (apply #'evil-define-minor-mode-key state 'tired-evil-local-mode
         (mapcan (lambda (binding)
                   (list (key-parse (car binding)) (cdr binding)))
                 keys)))

(define-minor-mode tired-evil-local-mode
  "Minor mode that installs the evil bindings of `tired-evil-mode'.
Enable `tired-evil-mode' instead of this mode."
  :group 'tired
  :lighter nil)

(tired-evil--bind 'normal tired-evil-keys)
(tired-evil--bind 'visual tired-evil-visual-keys)

(defun tired-evil--enable-buffer ()
  "Turn on `tired-evil-local-mode' in a tired buffer."
  (when (derived-mode-p 'tired-mode)
    (tired-evil-local-mode 1)))

;;;###autoload
(define-minor-mode tired-evil-mode
  "Global minor mode that gives `tired-mode' buffers evil bindings.
The bindings leave the evil motions alone and put every tired
command on a direct key.  Turn it off to give the buffer back to
`tired-mode-map'."
  :global t
  :group 'tired
  :lighter nil
  (if tired-evil-mode
      (progn
        (add-hook 'tired-mode-hook #'tired-evil--enable-buffer)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (tired-evil--enable-buffer))))
    (remove-hook 'tired-mode-hook #'tired-evil--enable-buffer)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (bound-and-true-p tired-evil-local-mode)
          (tired-evil-local-mode -1))))))

(provide 'tired-evil)

;;; tired-evil.el ends here
