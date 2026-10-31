;;; tired-evil.el --- Evil bindings for Tired  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; URL: https://github.com/nagy/tired
;; Version: 0.1.0
;; Keywords: files convenience
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

;; This file is optional.  It gives a Tired buffer evil bindings that
;; keep the motions: j, k, gg, C-d, C-u, n and N keep their meaning,
;; and every Tired command gets a direct key.  The two line motions
;; land on the name of the row, like the `n' and `p' keys of
;; `tired-mode-map'.  The search
;; key, /, runs `tired-filter' instead of `evil-ex-search-forward'.
;; G reaches the last row through `tired-goto-last-entry', because the
;; plain motion stops on the empty line below the listing.
;;
;;   (require 'tired-evil)
;;   (tired-evil-mode 1)
;;
;; A command acts on the transient selection, and an active region
;; joins it first, so a visual range feeds delete, copy, move and the
;; view commands without an extra step.
;;
;; Evil keeps its state maps in `emulation-mode-map-alists', and Emacs
;; checks that list before the major mode map, so `evil-ret' on RET
;; would hide `tired-find-file'.  `evil-define-minor-mode-key' installs
;; these maps ahead of the state maps and restores every Tired key.
;; Emacs activates such a map only while the mode symbol holds a value,
;; so turning `tired-evil-local-mode' on or off needs no
;; `evil-normalize-keymaps' call.
;;
;; The normal table shadows `w', `W' and `P' so the copy commands keep
;; their keys, and it puts the selection on `m' and the move command on
;; `R'.  Shadowing `m' costs the evil mark command, and shadowing `R'
;; keeps the evil replace state out of a read-only listing.  The visual
;; table uses the same `m' and `R', and it stays short because visual
;; state needs its text objects.
;;
;; The middle button opens the row under the pointer, because a
;; read-only listing has nothing to paste.  Evil binds `down-mouse-1' to
;; `evil-mouse-drag-region', which keeps the drag that makes a region,
;; and that command turns a double click into a text selection, so a
;; double click does not toggle a row here.  TAB and `e' toggle it.

;;; Code:

(require 'evil)
(require 'tired)

(defvar tired-evil-keys
  '(;; Opening a row.
    ("RET" . tired-find-file)
    ("o" . tired-find-file-other-window)
    ("<mouse-2>" . tired-mouse-find-file-other-window)
    ("f" . tired-find-file)
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
    ("<remap> <evil-replace>" . tired-rename)
    ("<remap> <evil-ex-search-forward>" . tired-filter)
    ("<remap> <evil-search-forward>" . tired-filter)
    ("<remap> <evil-goto-line>" . tired-goto-last-entry)
    ;; A line motion stops on the name, as the `n' and `p' keys of
    ;; `tired-mode-map' do.
    ("<remap> <evil-next-line>" . tired-next-line)
    ("<remap> <evil-previous-line>" . tired-previous-line)
    ("s" . tired-sort)
    ("F" . tired-clear-filter)
    ("." . tired-toggle-dotfiles)
    ("~" . tired-toggle-hidden)
    ("N" . tired-toggle-narrow)
    ("A" . tired-toggle-auto-revert)
    ;; Selection.
    ("m" . tired-select-toggle-next)
    ("M-SPC" . tired-select-toggle)
    ("t" . tired-select-all)
    ("%" . tired-select-extension)
    ("u" . tired-select-none)
    ;; Files.
    ("D" . tired-delete)
    ("!" . tired-do-shell-command)
    ("c" . tired-copy)
    ("R" . tired-move)
    ("+" . tired-mkdir)
    ("M-t" . tired-touch)
    ("y" . tired-copy-name)
    ("w" . tired-copy-path)
    ("W" . tired-copy-relative-path)
    ("P" . tired-copy-project-path))
  "Keys that `tired-evil-mode' binds in normal state.
Each entry is a key description and the command it runs.  The
listing commits the region into the selection first, so a visual
range reaches every file command and every view command.")

(defvar tired-evil-visual-keys
  '(("D" . tired-delete)
    ("!" . tired-do-shell-command)
    ("c" . tired-copy)
    ("R" . tired-move)
    ("y" . tired-copy-name)
    ("w" . tired-copy-path)
    ("m" . tired-select-toggle))
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
  "Turn on `tired-evil-local-mode' in a Tired buffer."
  (when (derived-mode-p 'tired-mode)
    (tired-evil-local-mode 1)))

;;;###autoload
(define-minor-mode tired-evil-mode
  "Global minor mode that gives `tired-mode' buffers evil bindings.
The bindings leave the evil motions alone and put every Tired
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
