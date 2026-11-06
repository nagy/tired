;;; tired-file-ops.el --- File commands for Tired  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; URL: https://github.com/nagy/tired

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

;; The file commands that change the file system: copy, move, rename,
;; delete, mkdir and touch, plus the in-place name edit, undo and redo.
;; Each command pushes one undo action, and the session trash keeps
;; every removed byte.  The shell command lives here too, because it is
;; the one command that runs a shell.
;;
;; Design notes for a change in this file:
;;
;; - `tired--apply-to-targets' runs one function over the paths deepest
;;   first, then clears the selection, refreshes, repairs point and
;;   reports one line.  A row that leaves the listing under point keeps
;;   its line, and otherwise point takes the row below the nearest row
;;   that stays above it.
;; - A command prints exactly one line through `message` and no
;;   `display-warning' beside it.  `tired--report-operation' builds it
;;   for copy, move, delete and commit.
;; - Removal goes through `tired--trash-move', never through
;;   `delete-file', so undo restores the path.  The trash usually sits
;;   on another file system, so a move is a copy and a delete, and a
;;   reboot loses it.  Never empty the trash inside an undo function.
;; - An action holds two steps that share one lexical state, and every
;;   path parks under one trash name for the whole session through
;;   `tired--parking-slot', so one undo and redo cycle leaves no dead
;;   entry.  `tired-redo' signals a user error while
;;   `tired-undo-push-functions' holds.
;; - `tired-rename' reads the row at point alone and renames the buffer
;;   that visits the path through `tired--rename-visiting-buffers'.  The
;;   helper calls `set-visited-file-name', never `rename-buffer', so
;;   `uniquify' shapes a taken name.  No other command reaches it.
;; - `tired-copy' and `tired-move' read their destination from another
;;   Tired window through `tired--other-tired-directory' when
;;   `tired-dwim-target' holds.
;; - `tired-edit-names' marks every character outside a name with a
;;   `read-only' text property and keeps the two ends in
;;   `tired--name-edit-regions' as markers, because the printed column is
;;   stale after an edit.  A `read-only' property alone keeps no name
;;   from growing: mark the character before a name `rear-nonsticky', and
;;   mark the first character of a read-only line `front-sticky'.
;; - Do not guard the edit with `before-change-functions': a signal there
;;   clears that buffer-local hook, so the first refused key would leave
;;   every later key unguarded.
;; - `special-mode-map' remaps `self-insert-command' to `undefined', and
;;   `tired-mode-map' inherits that remap, so the edit mode needs its own
;;   `<remap> <self-insert-command>' and one explicit binding per
;;   printable character.
;; - `tired-commit-edits' checks every name before it touches the disk:
;;   blank, a directory part, a control character, a repeated name, a
;;   name that the same commit moves away, a destination that names a
;;   directory, and a row that left the disk.  It keeps display order, so
;;   a renamed parent runs before a renamed child.  A rename that fails
;;   keeps its row editable and turns the rows that succeeded read only.
;; - Build every new path with `tired--name-target', never with
;;   `expand-file-name', which reads a name of `~' as the home
;;   directory.
;; - `tired--same-name-entry-p' drops the trash step when the source and
;;   the destination differ in case alone, because the file system
;;   resolves them to one entry, and `tired-undo' cannot move such a path
;;   back.  `tired--rename-region' narrows a collapsed chain row to its
;;   leaf, so a rename moves the leaf alone.
;; - Changing a text property sets the modified flag, and
;;   `tired--paint-row-help' adds properties after every print, so a
;;   listing buffer counts as modified.  Do not read that flag as a sign
;;   of an unsaved name edit.
;; - `tired-delete' waits through a flag set when `tired-delete-delay'
;;   holds a positive number.  `tired--flagged-deletion' stays disjoint
;;   from the selection, because the countdown owns the path.  The
;;   countdown runs in the buffer that scheduled it, so
;;   `tired--delete-flagged' takes the buffer as its argument and checks
;;   `buffer-live-p'.  A flag set to nil or zero leaves the pending flags
;;   alone, because the option governs the next `tired-delete'.
;;   `tired--prune-flags' drops a flag by `file-exists-p' and
;;   `file-symlink-p', never by the listing, or a hidden row would
;;   silently cancel a deletion.  A countdown that ends while a
;;   minibuffer prompt is active retries after
;;   `tired--delete-retry-delay'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tired-core)

(defvar tired--trash-counter 0
  "Counter that makes names inside the session trash unique.")

(defcustom tired-trash-directory nil
  "Directory that holds paths removed during this session.
A nil value means the session default: a directory under the
variable `temporary-file-directory' whose name holds the user id and
the Emacs process id, so two Emacs sessions never share one trash.  Set
the value to keep the removed paths elsewhere, for example under
`~/.local/state/tired/trash/'.

`tired-delete' moves its targets here.  A copy or a move that
replaces a path puts the old path here first.  `tired-undo' moves
the path back.  The system clears a temporary directory when the
machine reboots, so a path removed before a reboot does not come
back.  Emacs copies the path and then deletes it when the trash sits
on another file system."
  :type '(choice (const :tag "Per-session temporary directory" nil)
                 directory)
  :group 'tired)

(defcustom tired-undo-push-functions nil
  "Abnormal hook that takes every undoable Tired action.
Each function receives DESCRIPTION and FUNCTION.  DESCRIPTION is a
string that names the action.  FUNCTION reverts the action and
takes no argument.  While the hook is empty, Tired keeps the
action on `tired--undo-actions' for `tired-undo'."
  :type 'hook
  :group 'tired)

(defcustom tired-rename-visiting-buffer t
  "When non-nil, `tired-rename' renames the buffer that visits a path.
The buffer of a renamed file takes the new name through
`set-visited-file-name', as `dired-rename-file' does, and the
buffer of a file below a renamed directory takes the new directory
prefix, as `dired-rename-subdir' does.  A name that another buffer
holds becomes unique with a suffix such as `<2>', and `uniquify'
shapes that name when the library holds.  A nil value leaves every
buffer name as it stands."
  :type 'boolean
  :group 'tired)

(defvar tired--undo-actions nil
  "Stack of actions as (DESCRIPTION UNDO-FUNCTION REDO-FUNCTION) lists.
The most recent action comes first, and both functions take no
argument and return the number of paths that moved.  The two
functions share one lexical state, so a cycle of undo and redo
reuses one trash name per path.")

(defvar tired--redo-actions nil
  "Stack of actions that `tired-undo' reversed.
`tired-redo' redoes the most recent one first.  Every new file
command empties the stack, so a redo never overwrites later work.")

(defun tired--trash-root ()
  "Return the directory that holds this session's removed paths.
Serve `tired-trash-directory' when the user set it, and the
per-process temporary directory otherwise."
  (declare (side-effect-free t))
  (or tired-trash-directory
      (expand-file-name (format "tired-trash-%d-%d/" (user-uid) (emacs-pid))
                        temporary-file-directory)))

(defun tired--path-exists-p (path)
  "Return non-nil when PATH exists, including a dangling symbolic link."
  (declare (side-effect-free t))
  (or (file-exists-p path) (file-symlink-p path)))

(defun tired--trash-name (path)
  "Return an unused name for PATH inside the trash directory."
  (let* ((name (file-name-nondirectory (directory-file-name path)))
         (base (expand-file-name name (tired--trash-root)))
         (stamp (format-time-string "%Y%m%dT%H%M%S"))
         candidate)
    (while (progn
             (setq tired--trash-counter (1+ tired--trash-counter))
             (setq candidate (format "%s.%s-%d" base stamp tired--trash-counter))
             (tired--path-exists-p candidate)))
    candidate))

(defun tired--trash-move (path)
  "Move PATH into the trash directory and return the new path."
  (make-directory (tired--trash-root) t)
  (let ((target (tired--trash-name path)))
    (rename-file path target)
    target))

(defun tired--restore-path (trash-path original)
  "Move TRASH-PATH back to ORIGINAL.
Do nothing when TRASH-PATH is gone, or when ORIGINAL exists again.
Return non-nil when the move happened."
  (tired--move-path trash-path original))

(defun tired--move-path (from to)
  "Move FROM to TO and return non-nil when the move happened.
Change nothing when FROM is absent, or when TO exists, so a cycle
of undo and redo never overwrites a path that a user made in the
meantime."
  (when (and (tired--path-exists-p from)
             (not (tired--path-exists-p to)))
    (make-directory (file-name-directory to) t)
    (rename-file from to)
    t))

(defun tired--parking-slot (target slots)
  "Return SLOTS with a trash slot for TARGET.
SLOTS holds (PATH . TRASH-NAME) conses.  Add a free trash name for
TARGET when SLOTS holds none for it, so one name serves every
cycle of one action and the trash holds one entry per path."
  (if (assoc target slots)
      slots
    (cons (cons target (tired--trash-name target)) slots)))

(defun tired--refresh-buffers (&optional skip)
  "Refresh every live Tired buffer, except SKIP.
A listing keeps its printed rows while the disk changed no stamp,
so a refresh of a buffer without a changed path costs one stamp
pass.  SKIP names the buffer that the caller refreshed itself, as
`tired--apply-to-targets' does."
  (dolist (buffer (buffer-list))
    (unless (eq buffer skip)
      (with-current-buffer buffer
        (when (and (derived-mode-p 'tired-mode) tired--directory)
          (ignore-errors (tired-refresh)))))))

(defun tired--push-undo (description undo redo)
  "Hand UNDO and REDO to the undo stack as the two sides of DESCRIPTION.
When `tired-undo-push-functions' is non-nil, those functions take
the action and Tired keeps no redo path.  Otherwise the action
joins `tired--undo-actions', and `tired--redo-actions' empties,
because a new action invalidates every undone one."
  (setq tired--redo-actions nil)
  (if tired-undo-push-functions
      (run-hook-with-args 'tired-undo-push-functions description undo)
    (push (list description undo redo) tired--undo-actions))
  description)

(defun tired--action-line (verb description count)
  "Return one line that names VERB of DESCRIPTION and COUNT.
VERB holds a past tense such as Undid, and COUNT holds the
number of paths that moved, or nil when the verb reports none."
  (format "%s %s%s"
          verb description
          (if (integerp count)
              (format " (%d %s)" count
                      (if (= count 1) "entry" "entries"))
            "")))

(defun tired-undo ()
  "Undo the last file operation of this session.
Print one line that names the action and the number of paths that
moved back.  `tired-redo' reverses that undo.  When
`tired-undo-push-functions' is non-nil, the hook owns the action,
so the command signals a user error then."
  (interactive)
  (let ((action (pop tired--undo-actions)))
    (unless action
      (user-error "Nothing for Tired to undo"))
    (push action tired--redo-actions)
    (message "%s" (tired--action-line "Undid" (car action)
                                       (funcall (nth 1 action))))))

(defun tired-redo ()
  "Redo the last file operation that `tired-undo' reversed.
Print one line that names the action and the number of paths that
moved forward.  A new file command empties the redo stack, so the
command signals a user error when no undone action waits.  The
command changes paths, so it signals the same error while
`tired-undo-push-functions' owns the actions: the hook keeps no
redo function."
  (interactive)
  (when tired-undo-push-functions
    (user-error "`tired-undo-push-functions' owns the actions"))
  (let ((action (pop tired--redo-actions)))
    (unless action
      (user-error "Nothing for Tired to redo"))
    (push action tired--undo-actions)
    (message "%s" (tired--action-line "Redid" (car action)
                                       (funcall (nth 2 action))))))

(defun tired--report-operation (verb place done failures)
  "Print one line that names DONE successes of VERB at PLACE.
PLACE holds the destination name, or nil when the verb needs none.
FAILURES holds `(PATH . MESSAGE)' conses, and the line names the
first failed path."
  (message "%s %d %s%s%s"
           verb done (if (= done 1) "entry" "entries")
           (if place (format " to %s" place) "")
           (if (null failures)
               ""
             (format ", %d failed: %s"
                     (length failures)
                     (abbreviate-file-name (car (car failures)))))))

(defun tired--path-under-p (path parent)
  "Return non-nil when PATH is PARENT or lies below it."
  (declare (side-effect-free t))
  (let ((path (directory-file-name (expand-file-name path)))
        (parent (directory-file-name (expand-file-name parent))))
    (or (equal path parent)
        (string-prefix-p (file-name-as-directory parent) path))))

(defun tired--rename-file-buffer (path target)
  "Point the buffer that visits PATH at TARGET.
Do nothing while no buffer visits PATH.  Pass ALONG-WITH-FILE, so
`set-visited-file-name' keeps the modification time that the buffer
read, as `dired-rename-file' does."
  (let ((buffer (get-file-buffer path)))
    (when buffer
      (with-current-buffer buffer
        (set-visited-file-name target nil t)))))

(defun tired--rename-subtree-buffers (path target)
  "Rewrite the directory PATH to TARGET in every buffer below PATH.
Keep the modified flag of each buffer, as `dired-rename-subdir'
does, and skip a buffer that visits the renamed directory itself,
because a directory name is no visited file, and an indirect
buffer, because `set-visited-file-name' refuses one."
  (let ((from (file-name-as-directory (expand-file-name path)))
        (to (file-name-as-directory (expand-file-name target))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and buffer-file-name
                   (not (buffer-base-buffer))
                   (tired--path-under-p buffer-file-name from))
          (let ((name (expand-file-name buffer-file-name)))
            (unless (equal (directory-file-name name)
                           (directory-file-name from))
              (let ((modified (buffer-modified-p)))
                (set-visited-file-name
                 (expand-file-name (substring name (length from)) to))
                (set-buffer-modified-p modified)))))))))

(defun tired--rename-visiting-buffers (path target)
  "Rename every buffer that visits PATH to TARGET.
PATH names a file or a directory.  Run the function after the move
of the disk, so TARGET exists and decides the branch.  A buffer
that visits a path below a renamed directory takes the new prefix
through `tired--rename-subtree-buffers', and every other buffer
takes the new name through `tired--rename-file-buffer'."
  (if (file-directory-p target)
      (tired--rename-subtree-buffers path target)
    (tired--rename-file-buffer path target)))

(defun tired--surviving-row-above (row doomed)
  "Return the nearest row above ROW that the command keeps.
DOOMED holds the target paths of the command, so a row whose path
lies under one of them leaves the listing too.  A row also leaves
the listing when its path is gone from the disk, because the
refresh then drops it.  Return nil when no row above ROW stays."
  (let ((from (and row (tired--row-position row))))
    (when from
      (save-excursion
        (goto-char from)
        (let (result)
          (while (and (not result) (zerop (forward-line -1)))
            (let ((here (tired--row-at-point)))
              (when (and here
                         (tired--path-exists-p (tired--row-path here))
                         (not (cl-some (lambda (path)
                                         (tired--path-under-p
                                          (tired--row-path here) path))
                                       doomed)))
                (setq result here))))
          result)))))

(defun tired--goto-row-below (row)
  "Move point to the row below ROW, clamped to the last row.
With no ROW, move point to the first line.  A ROW that the listing
no longer shows leaves point where the refresh put it."
  (let ((position (and row (tired--row-position row))))
    (cond
     (position
      (goto-char position)
      (forward-line 1)
      (when (eobp)
        (goto-char (or (tired--last-row-position) (point-min)))))
     ((null row)
      (goto-char (point-min))))))

(defun tired--apply-to-targets (verb place function &optional paths keep-selection)
  "Call FUNCTION with each target path and then clear the selection.
VERB names the action and PLACE names its destination.  PATHS names
the paths to act on, and a nil value reads the targets of the
command.  KEEP-SELECTION non-nil leaves the transient selection as it
stands, because a deletion timer owns its rows and the user never
selected them.  The command prints one line that names the count, the
destination and the first failed path.  Deepest paths run first, so a
selection that holds a directory and its children reaches the
children first.  A failure does not stop the remaining targets.
A command that removed the row at point moves point to the row
below the nearest row that stays above it, so a removed block
above point does not push point down.  A row that leaves the
listing under point keeps its line through the refresh, so a
collapsed chain row that still shows a path under a removed leaf
keeps focus.  A shorter listing clamps point to its last row,
never to the first line.  Refresh the listing after the line, and
refresh the other Tired buffers too, because the destination may
belong to another window.  A name edit holds the buffer text, so
the command signals a user error there, because its redraw would
draw nothing."
  (when tired--name-edit
    (user-error "Commit or abort the name edit first"))
  (let ((paths (or paths (mapcar #'tired-entry-path (tired--targets)))))
    (unless paths
      (user-error "No entry at point"))
    (setq paths
          (sort (copy-sequence paths)
                (lambda (a b) (> (length a) (length b)))))
    (let* ((done 0)
           (failures nil)
           (point-row (tired--row-at-point))
           (anchor (tired--surviving-row-above point-row paths)))
      (dolist (path paths)
        (condition-case err
            (progn (funcall function path)
                   (setq done (1+ done)))
          (error (push (cons path (error-message-string err)) failures))))
      (unless keep-selection
        (tired--clear-selection))
      (tired-refresh)
      ;; A command reaches the listing of another window, because a
      ;; copy or a move writes into a directory that the dwim target
      ;; or the minibuffer question named.  That window holds no watch
      ;; on a path that it does not list yet, so it takes the same
      ;; stamp check here.
      (tired--refresh-buffers (current-buffer))
      (unless (tired--row-position point-row)
        (tired--goto-row-below anchor))
      (deactivate-mark)
      (tired--report-operation verb place done (nreverse failures)))))

(defun tired--undo-restore (pairs)
  "Put every PAIRS entry back and return the number restored.
Each pair holds the trashed path and the original path."
  (let ((restored 0))
    (dolist (pair pairs)
      (when (ignore-errors (tired--restore-path (car pair) (cdr pair)))
        (setq restored (1+ restored))))
    restored))

(defun tired--undo-copy (created slots trashed)
  "Remove CREATED paths and put TRASHED paths back.
Return (COUNT . SLOTS), where COUNT is the number of paths that
moved and SLOTS holds the trash name of every CREATED path, so a
later `tired--redo-copy' finds the copy again."
  (let ((restored 0))
    (dolist (path created)
      (setq slots (tired--parking-slot path slots))
      (when (tired--move-path path (cdr (assoc path slots)))
        (setq restored (1+ restored))))
    (setq restored (+ restored (tired--undo-restore trashed)))
    (tired--refresh-buffers)
    (cons restored slots)))

(defun tired--redo-copy (slots trashed)
  "Park the TRASHED paths again and put every SLOTS copy back.
SLOTS holds (PATH . TRASH-NAME) conses.  Return the number of
paths that moved."
  (let ((restored 0))
    (dolist (pair trashed)
      (when (tired--move-path (cdr pair) (car pair))
        (setq restored (1+ restored))))
    (dolist (slot slots)
      (when (tired--move-path (cdr slot) (car slot))
        (setq restored (1+ restored))))
    (tired--refresh-buffers)
    restored))

(defun tired--undo-move (moved trashed)
  "Move every MOVED pair back, put TRASHED paths back and return the count."
  (let ((restored (tired--undo-restore moved)))
    (setq restored (+ restored (tired--undo-restore trashed)))
    (tired--refresh-buffers)
    restored))

(defun tired--redo-move (moved trashed)
  "Move every MOVED pair forward and park TRASHED again.
Each pair holds the destination and the source of one move, so the
trashed pairs run first and free the destination of the entries.
Return the number of paths that moved."
  (let ((restored 0))
    (dolist (pair trashed)
      (when (tired--move-path (cdr pair) (car pair))
        (setq restored (1+ restored))))
    (dolist (pair moved)
      (when (tired--move-path (cdr pair) (car pair))
        (setq restored (1+ restored))))
    (tired--refresh-buffers)
    restored))

(defun tired--undo-delete (trashed)
  "Put every TRASHED pair back, parents first, and return the count."
  (let ((restored (tired--undo-restore trashed)))
    (tired--refresh-buffers)
    restored))

(defun tired--redo-delete (trashed)
  "Move the original path of every TRASHED pair into the trash again.
Return the number of paths that moved."
  (let ((trashed-count 0))
    (dolist (pair trashed)
      (when (tired--move-path (cdr pair) (car pair))
        (setq trashed-count (1+ trashed-count))))
    (tired--refresh-buffers)
    trashed-count))

(defun tired--replace-with-trash (path)
  "Move PATH into the session trash and return the new name.
Return nil when PATH is absent."
  (when (tired--path-exists-p path)
    (tired--trash-move path)))

(defun tired--name-target (path name)
  "Return the path that the base name NAME gives to PATH.
The result joins PATH's directory and NAME as plain text, so no
name reaches `expand-file-name'.  A name such as \"~\" then stays a
file name in that directory, and never names the home directory."
  (declare (pure t) (side-effect-free t))
  (concat (file-name-as-directory
           (file-name-directory (directory-file-name path)))
          name))

(defun tired--same-name-entry-p (path target)
  "Return non-nil when PATH and TARGET differ in case alone.
A case-insensitive file system resolves such a TARGET to PATH
itself, so the rename needs no trash step.  A case-sensitive file
system keeps two files, and the caller trashes TARGET first."
  (let ((path (directory-file-name path)))
    (and (string-equal-ignore-case path target)
         (file-equal-p path target))))

(defun tired--other-tired-directory ()
  "Return the directory of a Tired buffer in another window.
Scan the windows of this frame from the one after the selected
window, as `dired-dwim-target-next' does.  Return nil when no
other window shows a Tired buffer, or when that buffer shows the
directory of this buffer, because a copy or a move into the same
directory would change nothing."
  (let ((here tired--directory))
    (catch 'found
      (dolist (window (window-list-1 (next-window nil 'nomini) 'nomini))
        (unless (eq window (selected-window))
          (with-current-buffer (window-buffer window)
            (when (and (derived-mode-p 'tired-mode)
                       tired--directory
                       (not (equal tired--directory here)))
              (throw 'found tired--directory))))))))

(defun tired-copy (directory)
  "Copy the targets into DIRECTORY.
Interactively, when `tired-dwim-target' holds and another window of
the frame shows a Tired buffer for another directory, the command
copies the targets into that directory at once and asks no
question.  An existing destination goes to `tired-trash-directory'
first, so `tired-undo' puts it back.  The copy never calls a shell."
  (interactive
   (let ((targets (tired--selection-targets))
         (dwim (and tired-dwim-target (tired--other-tired-directory))))
     (unless targets
       (user-error "No entry at point"))
     (if dwim
         (list dwim)
       (list (read-directory-name "Copy targets to: " tired--directory)))))
  (let ((destination (file-name-as-directory (expand-file-name directory)))
        (created nil)
        (trashed nil)
        (slots nil))
    (tired--apply-to-targets
     "Copied" (abbreviate-file-name (directory-file-name destination))
     (lambda (path)
       (let* ((name (file-name-nondirectory (directory-file-name path)))
              (target (expand-file-name name destination))
              (previous (tired--replace-with-trash target)))
         (when previous
           (push (cons previous target) trashed))
         (condition-case err
             (if (file-directory-p path)
                 (copy-directory path target)
               (copy-file path target))
           (error
            (when previous
              (setq trashed (delete (assoc previous trashed) trashed))
              (ignore-errors (tired--restore-path previous target)))
            (signal (car err) (cdr err))))
         (push target created))))
    (when created
      (tired--push-undo
       (format "copy into %s"
               (abbreviate-file-name (directory-file-name destination)))
       (lambda ()
         (let ((result (tired--undo-copy created slots trashed)))
           (setq slots (cdr result))
           (car result)))
       (lambda () (tired--redo-copy slots trashed))))))

(defun tired-move (destination)
  "Move the targets to DESTINATION.
With one target, DESTINATION is the new full path, unless it names
an existing directory.  With several targets, DESTINATION is a
directory.  Interactively, when `tired-dwim-target' holds and
another window of the frame shows a Tired buffer for another
directory, the command moves the targets into that directory at
once and asks no question.  An existing destination goes to
`tired-trash-directory' first, so `tired-undo' puts it back.  The
move never calls a shell."
  (interactive
   (let ((targets (tired--selection-targets))
         (dwim (and tired-dwim-target (tired--other-tired-directory))))
     (unless targets
       (user-error "No entry at point"))
     (cond
      (dwim (list dwim))
      ((null (cdr targets))
       (list (read-file-name
              "Move to: " tired--directory nil nil
              (file-name-nondirectory
               (directory-file-name (tired-entry-path (car targets)))))))
      (t (list (read-directory-name "Move targets to: " tired--directory))))))
  (let* ((targets (tired--targets))
         (single (null (cdr targets)))
         (destination (expand-file-name destination))
         (full-path (and single
                         (not (file-directory-p destination))
                         (not (directory-name-p destination))
                         destination))
         (directory (file-name-as-directory
                     (or (and full-path (file-name-directory full-path))
                         destination)))
         (moved nil)
         (trashed nil))
    (tired--apply-to-targets
     "Moved" (abbreviate-file-name (directory-file-name directory))
     (lambda (path)
       (let* ((target (or full-path
                          (expand-file-name
                           (file-name-nondirectory (directory-file-name path))
                           directory)))
              (previous (unless (equal (directory-file-name path)
                                       (directory-file-name target))
                          (tired--replace-with-trash target))))
         (when previous
           (push (cons previous target) trashed))
         (condition-case err
             (unless (equal (directory-file-name path)
                            (directory-file-name target))
               (rename-file path target))
           (error
            (when previous
              (setq trashed (delete (assoc previous trashed) trashed))
              (ignore-errors (tired--restore-path previous target)))
            (signal (car err) (cdr err))))
         (push (cons target path) moved))))
    (when moved
      (tired--push-undo
       (format "move to %s"
               (abbreviate-file-name (directory-file-name directory)))
       (lambda () (tired--undo-move moved trashed))
       (lambda () (tired--redo-move moved trashed))))))

(defun tired-rename (name)
  "Rename the entry at point to NAME.
NAME holds the new base name and no directory part.  Interactively,
the minibuffer shows the current name first.  An existing
destination goes to `tired-trash-directory' first, so `tired-undo'
puts it back.  A destination that names a directory signals a user
error, so no subtree leaves the listing by accident.  The command
reads the row at point alone and ignores the selection and the
region.  A later `tired-undo' returns the old name.  Point follows
the renamed row.  A buffer that visits the path takes the new name
too when `tired-rename-visiting-buffer' holds.  The command never
calls a shell, and it signals a user error while a name edit holds
the buffer text."
  (interactive
   (if tired--name-edit
       (user-error "Commit or abort the name edit first")
     (let ((row (tired--row-at-point)))
       (unless row
         (user-error "No entry at point"))
       (when (tired-section-p row)
         (user-error "Cannot rename a section"))
       (let ((old (file-name-nondirectory
                   (directory-file-name (tired-entry-path row)))))
         (list (read-string (format "Rename %s to: " old) old))))))
  (let ((row (tired--row-at-point)))
    (when tired--name-edit
      (user-error "Commit or abort the name edit first"))
    (unless row
      (user-error "No entry at point"))
    (unless (tired-entry-p row)
      (user-error "Cannot rename a section"))
    (let* ((path (tired-entry-path row))
           (old (file-name-nondirectory (directory-file-name path)))
           (target (tired--name-target path name)))
      (when (or (string-empty-p (string-trim name))
                (member name '("." "..")))
        (user-error "Invalid name %s" name))
      (when (file-name-directory name)
        (user-error "A name holds no directory part: %s" name))
      (if (equal (directory-file-name target) (directory-file-name path))
          (message "Name unchanged")
        (when (file-directory-p target)
          (user-error "%s names a directory" name))
        (let ((previous (unless (tired--same-name-entry-p path target)
                          (tired--replace-with-trash target)))
              (moved nil)
              (trashed nil))
          (rename-file path target)
          (when tired-rename-visiting-buffer
            (tired--rename-visiting-buffers path target))
          (setq moved (list (cons target path)))
          (when previous
            (setq trashed (list (cons previous target))))
          (tired--push-undo
           (format "rename %s to %s" old name)
           (lambda () (tired--undo-move moved trashed))
           (lambda () (tired--redo-move moved trashed)))
          (tired-refresh)
          (tired--goto-path target)
          (message "Renamed %s to %s" old name))))))

;;; Name edits

(defvar tired-name-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (char (number-sequence ?\s ?~))
      (define-key map (char-to-string char) #'tired--name-self-insert))
    (define-key map [remap self-insert-command] #'tired--name-self-insert)
    (define-key map "\C-c\C-c" #'tired-commit-edits)
    (define-key map "\C-c\C-k" #'tired-abort-edits)
    ;; A newline would split a row, and TAB would toggle a subtree.
    (dolist (key '("TAB" "RET" "C-j" "C-o"))
      (define-key map (kbd key) #'undefined))
    map)
  "Key map for `tired-name-edit-mode'.
Every printable character inserts itself, because the listing key
map binds most letters to a command.  The remap of
`self-insert-command' replaces the one of `special-mode-map'.")

(defun tired--name-self-insert (&optional arg)
  "Insert ARG copies of the typed character at point.
`special-mode-map' remaps `self-insert-command' to `undefined', and
the listing inherits that remap, so the name edit mode needs a
command of its own for a typed character."
  (interactive "*p")
  (self-insert-command (or arg 1)))

(defvar-local tired--name-edit-regions nil
  "Alist of entry, start marker and end marker for the name edit.
The start marker stays before text inserted at the name start, and
the end marker follows text appended to the name, so both markers
track the user's changes.  `tired-commit-edits' reads the text
between the markers.")

(defvar-local tired--name-edit-sticky nil
  "List of (START . END) regions that the name edit made sticky.
`tired--mark-name-edits' records every region whose
`rear-nonsticky' or `front-sticky' property it changes, and
`tired--stop-name-edit' reads the list, so a sticky property that
another feature set elsewhere in the buffer stays.")

(defun tired--rename-region ()
  "Return the buffer region that a name edit changes on this line.
A collapsed chain row shows a relative name, so the region covers
the leaf component alone and the directory part stays out.  Return
nil when the line holds no entry row."
  (let ((row (tired--row-at-point))
        (region (tired--name-region)))
    (when (and region (tired-entry-p row) (< (car region) (cdr region)))
      (cons (save-excursion
              (goto-char (cdr region))
              (if (search-backward "/" (car region) t)
                  (1+ (point))
                (car region)))
            (cdr region)))))

(defun tired--mark-name-edits (regions)
  "Make each region in REGIONS the only writable text of the buffer.
REGIONS holds (START . END) conses, one per editable name leaf.
The rest of the listing takes a `read-only' text property, so a
change reaches no other column.  The character before a name is
`rear-nonsticky' for that property, because a user who deletes a
whole name retypes it at the same place.  The first character of a
read-only line start is `front-sticky' instead, so an insertion
never lands in the indentation or in front of a section label.
Every changed sticky property joins `tired--name-edit-sticky'."
  (let ((inhibit-read-only t))
    (add-text-properties (point-min) (point-max) '(read-only t))
    (dolist (region regions)
      (remove-text-properties (car region) (cdr region) '(read-only t))
      (when (> (car region) (point-min))
        (add-text-properties (1- (car region)) (car region)
                             '(rear-nonsticky (read-only)))
        (push (cons (1- (car region)) (car region))
              tired--name-edit-sticky)))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (get-text-property (point) 'read-only)
          (add-text-properties (point) (1+ (point))
                               '(front-sticky (read-only)))
          (push (cons (point) (1+ (point))) tired--name-edit-sticky))
        (forward-line 1)))))

(defun tired--start-name-edit ()
  "Record every name cell and make the listing accept name changes.
The markers around a name follow the user's edits, so a name that
the user deleted accepts a new one at the same place."
  (setq buffer-read-only nil)
  (setq tired--name-edit-regions nil)
  (setq tired--name-edit-sticky nil)
  ;; A longer name moves every later line start, so the subtree
  ;; positions of the last print no longer name a line.
  (setq tired--subtree-starts [])
  (let (regions)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((row (tired--row-at-point))
              (region (tired--rename-region)))
          (when region
            (push region regions)
            (push (list row
                        (copy-marker (car region) nil)
                        (copy-marker (cdr region) t))
                  tired--name-edit-regions)))
        (forward-line 1)))
    (setq tired--name-edit-regions (nreverse tired--name-edit-regions))
    (setq tired--name-edit t)
    (tired--mark-name-edits (nreverse regions))))

(defun tired--stop-name-edit ()
  "Drop the name markers and make the listing read only again.
The edit owns the `read-only' property of the whole buffer, so that
property goes everywhere.  The sticky properties belong to the
name edit alone, so only the regions in `tired--name-edit-sticky'
lose them, and a sticky property that another feature set stays."
  (let ((inhibit-read-only t))
    (remove-text-properties (point-min) (point-max) '(read-only nil))
    (dolist (region tired--name-edit-sticky)
      (remove-text-properties
       (max (point-min) (car region))
       (min (point-max) (cdr region))
       '(front-sticky nil rear-nonsticky nil))))
  (setq tired--name-edit-regions nil)
  (setq tired--name-edit-sticky nil)
  (setq tired--name-edit nil)
  (setq buffer-read-only t))

(define-minor-mode tired-name-edit-mode
  "Minor mode that makes the name cells of a listing editable.
`tired-edit-names' turns the mode on.  Only the name of an entry
row accepts a change.  `tired-commit-edits' renames the rows that
hold a new name, and `tired-abort-edits' drops every change.  The
mode reads the printed rows, so a redraw waits until the mode goes
off.

\\{tired-name-edit-mode-map}"
  :lighter " Edit"
  :keymap tired-name-edit-mode-map
  :group 'tired
  (cond
   ((not tired-name-edit-mode)
    (when tired--name-edit
      (tired--stop-name-edit)))
   ((not (derived-mode-p 'tired-mode))
    (setq tired-name-edit-mode nil)
    (user-error "Not a Tired listing"))
   (t (tired--start-name-edit))))

(defun tired-edit-names ()
  "Edit the names of the listed entries in place.
Only the name of each row accepts a change.  `tired-commit-edits'
renames the rows that hold a new name, and `tired-abort-edits'
drops every change.  A commit refuses a blank name, a name that
carries a directory part, a name that repeats another name, a name
that belongs to a row which the same commit renames, a destination
that names a directory, and a row whose path left the disk.  An
existing destination goes to `tired-trash-directory' first, and one
undo action holds the whole commit, so `tired-undo' returns every
old name.  A rename that fails keeps its row editable and turns
the other rows read only, so a second commit retries it.

The command reads no selection and allocates no key.  A collapsed
chain row shows a relative name, and its editable part is the leaf
alone."
  (interactive)
  (unless tired--directory
    (user-error "Not in a Tired buffer"))
  (when tired--name-edit
    (user-error "Names are editable already"))
  (unless (tired--visible-entries)
    (user-error "No entry to edit"))
  (tired--clear-flags)
  (tired-name-edit-mode 1)
  (message "Edit names, C-c C-c renames, C-c C-k drops the changes"))

(defun tired-abort-edits ()
  "Drop every edited name and leave the name edit mode."
  (interactive)
  (unless tired--name-edit
    (user-error "Names are not editable"))
  (tired-name-edit-mode -1)
  ;; The name edit emptied the subtree positions, and a listing that
  ;; the disk did not change keeps its printed rows, so force the
  ;; reprint that fills them again.  The reprint also drops the names
  ;; that the user typed.
  (setq tired--listing-stamps nil)
  (tired-refresh)
  (message "Names unchanged"))

(defun tired--name-edit-changes ()
  "Return (ENTRY . NAME) conses for every row whose name changed.
A row whose name the user deleted counts as changed to an empty
name, so the commit refuses it."
  (let (changes)
    (dolist (record tired--name-edit-regions)
      (let* ((entry (nth 0 record))
             (name (buffer-substring-no-properties
                    (marker-position (nth 1 record))
                    (marker-position (nth 2 record))))
             (old (file-name-nondirectory
                   (directory-file-name (tired-entry-path entry)))))
        (unless (equal old name)
          (push (cons entry name) changes))))
    (nreverse changes)))

(defun tired--check-name-edits (changes)
  "Signal a user error when CHANGES cannot reach the disk.
A change is an (ENTRY . NAME) cons.  Refuse a blank name, a name
that holds a directory part or a control character, a name that
the commit already took, a name that belongs to a row which the
same commit renames, a destination that names a directory, and a
row whose path left the disk."
  (let ((sources (make-hash-table :test #'equal))
        (targets (make-hash-table :test #'equal)))
    (dolist (change changes)
      (puthash (directory-file-name
                (expand-file-name (tired-entry-path (car change))))
               change sources))
    (dolist (change changes)
      (let* ((entry (car change))
             (name (cdr change))
             (path (tired-entry-path entry))
             (target (tired--name-target path name)))
        (when (string-empty-p (string-trim name))
          (user-error "A name is empty"))
        (when (member name '("." ".."))
          (user-error "Invalid name %s" name))
        (when (file-name-directory name)
          (user-error "A name holds no directory part: %s" name))
        (when (cl-some (lambda (char) (or (< char 32) (= char 127))) name)
          (user-error "A name holds no control character: %s" name))
        (unless (tired--path-exists-p path)
          (user-error "%s left the disk" (abbreviate-file-name path)))
        (when (file-directory-p target)
          (user-error "%s names a directory" name))
        (when (gethash target targets)
          (user-error "Two entries take the name %s" name))
        (let ((other (gethash target sources)))
          (when (and other (not (eq other change)))
            (user-error "The name %s belongs to a renamed entry" name)))
        (puthash target change targets)))))

(defun tired-commit-edits ()
  "Rename every entry whose name changed.
The commit leaves the name edit mode, unless a rename fails.
The commit refuses a blank name, a name that carries a directory
part, a name that repeats another name, a name that belongs to a
row that the same commit renames, a destination that names a
directory, and a row whose path left the disk.  Such a refusal
keeps the edits, so the user fixes the name or runs
`tired-abort-edits'.  An existing destination goes to
`tired-trash-directory' first.  A failure does not stop the
remaining names: the rows that took their new name become read
only, and the rows that failed stay editable, so a second commit
retries them or an abort drops them.  The commit reports the paths
that failed.  One undo action holds the whole commit, so
`tired-undo' returns every old name."
  (interactive)
  (unless tired--name-edit
    (user-error "Names are not editable"))
  (let ((changes (tired--name-edit-changes)))
    (tired--check-name-edits changes)
    (if (null changes)
        (progn
          (tired-name-edit-mode -1)
          ;; The name edit emptied the subtree positions, so force the
          ;; reprint that fills them again.
          (setq tired--listing-stamps nil)
          (tired-refresh)
          (message "No name changed"))
      (let ((done 0)
            (renames nil)
            (trashed nil)
            (settled nil)
            (failures nil))
        (dolist (change changes)
          (let* ((entry (car change))
                 (name (cdr change))
                 (path (tired-entry-path entry))
                 (target (tired--name-target path name))
                 (previous nil)
                 (renamed nil))
            (condition-case err
                (progn
                  (setq previous (unless (tired--same-name-entry-p path target)
                                   (tired--replace-with-trash target)))
                  (when previous
                    (push (cons previous target) trashed))
                  (rename-file path target)
                  (setq renamed t)
                  (push (cons target path) renames)
                  (push entry settled)
                  (setq done (1+ done)))
              (error
               (unless renamed
                 (when previous
                   (setq trashed (delete (assoc previous trashed) trashed))
                   (ignore-errors (tired--restore-path previous target))))
               (push (cons path (error-message-string err)) failures)))))
        (when renames
          (tired--push-undo
           (format "rename of %d %s" (length renames)
                   (if (= (length renames) 1) "entry" "entries"))
           (lambda () (tired--undo-move renames trashed))
           (lambda () (tired--redo-move renames trashed))))
        (setq failures (nreverse failures))
        (if failures
            ;; The rows that failed keep their typed name, so the edit
            ;; mode stays and the other rows turn read only.
            (progn
              (setq tired--name-edit-regions
                    (cl-remove-if (lambda (record)
                                    (memq (nth 0 record) settled))
                                  tired--name-edit-regions))
              (tired--mark-name-edits
               (mapcar (lambda (record)
                         (cons (marker-position (nth 1 record))
                               (marker-position (nth 2 record))))
                       tired--name-edit-regions))
              (tired-refresh))
          (tired-name-edit-mode -1)
          (tired-refresh))
        (tired--report-operation "Renamed" nil done failures)))))

(defun tired--record-delete (trashed)
  "Push one undo action for TRASHED, a list of (TRASH . PATH) conses."
  (when trashed
    (tired--push-undo
     (format "delete of %d %s" (length trashed)
             (if (= (length trashed) 1) "entry" "entries"))
     (lambda () (tired--undo-delete trashed))
     (lambda () (tired--redo-delete trashed)))))

(defun tired-delete-flagged (paths)
  "Delete PATHS, the rows that a delayed `tired-delete' flagged.
Keep the transient selection, because a flagged row never joined it,
and let the usual refresh drop the rows that left the disk.  One undo
action covers the removal and one line reports it."
  (let ((trashed nil))
    (tired--apply-to-targets
     "Deleted" "trash"
     (lambda (path)
       (push (cons (tired--trash-move path) path) trashed))
     (copy-sequence paths)
     t)
    (tired--record-delete trashed)))

(defun tired-delete ()
  "Delete the targets, or flag them for a delayed deletion.
With `tired-delete-delay' set to a positive number, the command moves
the targets into the deletion flag set, paints their rows with
`tired-flagged-deletion' and starts a countdown of that many seconds,
so a misplaced command costs no bytes.  A selection change starts the
countdown again, `tired-select-none' drops every flag, and
`tired-select-toggle' on a flagged row drops that flag alone.  When
the countdown ends, the command removes exactly the flagged paths,
and the rest of the selection stays.  A nil or zero delay deletes at
once, as before.  The command asks no question and never calls a
shell.  A later `tired-undo' moves the paths back."
  (interactive)
  (if (and (numberp tired-delete-delay) (> tired-delete-delay 0))
      (tired--flag-deletion (mapcar #'tired-entry-path (tired--targets)))
    (let ((trashed nil))
      (tired--apply-to-targets
       "Deleted" "trash"
       (lambda (path)
         (push (cons (tired--trash-move path) path) trashed)))
      (tired--record-delete trashed))))

(defun tired--creation-directory ()
  "Return the directory that creation commands start from.
The entry at point decides: a directory row starts inside that
directory, every other row starts at the shown directory."
  (let ((entry (tired--row-at-point)))
    (if (and (tired-entry-p entry)
             (file-directory-p (tired-entry-path entry)))
        (file-name-as-directory (tired-entry-path entry))
      tired--directory)))

(defun tired-mkdir (directory)
  "Create DIRECTORY and its parents.
The command asks no confirmation.  A later `tired-undo' removes the
new directory and the parents that it created."
  (interactive
   (list (read-file-name "Create directory: " (tired--creation-directory)
                         nil nil)))
  (let* ((path (directory-file-name (expand-file-name directory)))
         (parent (file-name-directory path))
         (missing nil)
         (slots nil))
    (when (tired--path-exists-p path)
      (user-error "%s already exists" path))
    (while (and parent (not (file-directory-p parent)))
      (push (directory-file-name parent) missing)
      (setq parent (file-name-directory (directory-file-name parent))))
    (make-directory path t)
    (tired--push-undo
     (format "mkdir %s" (abbreviate-file-name path))
     (lambda ()
       (let ((removed 0))
         (setq slots (tired--parking-slot path slots))
         (when (tired--move-path path (cdr (assoc path slots)))
           (setq removed 1))
         (dolist (dir (reverse missing))
           (when (and (file-directory-p dir)
                      (null (directory-files dir nil "\\`[^.]")))
             (delete-directory dir)
             (setq removed (1+ removed))))
         removed))
     (lambda ()
       (let ((made 0))
         (dolist (dir (reverse missing))
           (unless (file-directory-p dir)
             (make-directory dir t)
             (setq made (1+ made))))
         (when (and slots (tired--move-path (cdr (assoc path slots)) path))
           (setq made (1+ made)))
         (tired--refresh-buffers)
         made)))
    (tired-refresh)
    (message "Created %s" (abbreviate-file-name path))))

(defun tired-touch (file)
  "Create FILE, or update its modification time when it exists.
The command asks no confirmation.  A later `tired-undo' removes a
created file, or puts the earlier modification time back."
  (interactive
   (list (read-file-name "Create empty file: " (tired--creation-directory)
                         nil nil)))
  (let* ((path (expand-file-name file))
         (exists (tired--path-exists-p path))
         (mtime (and exists
                     (file-regular-p path)
                     (file-attribute-modification-time (file-attributes path))))
         (slots nil))
    (when (file-directory-p path)
      (user-error "%s is a directory" path))
    (write-region "" nil path nil 'silent)
    (tired--push-undo
     (format "touch %s" (abbreviate-file-name path))
     (lambda ()
       (cond ((not exists)
              (setq slots (tired--parking-slot path slots))
              (if (tired--move-path path (cdr (assoc path slots))) 1 0))
             (mtime
              (if (ignore-errors (set-file-times path mtime) t) 1 0))))
     (lambda ()
       (cond ((not exists)
              (if (and slots (tired--move-path (cdr (assoc path slots)) path))
                  1
                0))
             (mtime
              (if (ignore-errors (set-file-times path nil) t) 1 0)))))
    (tired-refresh)
    (message "%s %s" (if exists "Touched" "Created")
             (abbreviate-file-name path))))

(defvar tired-shell-command-history nil
  "History list for `tired-do-shell-command'.")

(defcustom tired-confirm-shell-command t
  "When non-nil, `tired-do-shell-command' asks about a mark that stays.
A `*' or `?' that whitespace does not isolate reaches the shell
untouched, and the user sometimes means a substitution.  The
command asks one yes-or-no question in that case.  Set this option
to nil to skip the question."
  :type 'boolean
  :group 'tired)

;; A mark needs whitespace or a string end beside it.  Do not match a
;; bare `[*?]' class: a glob pattern such as `*.txt' must reach the
;; shell unchanged.
(defun tired--shell-regexp ()
  "Return the regexp that matches one substitution mark.
Group 1 holds the leading whitespace or the start of the string,
group 2 holds the mark and group 3 holds the trailing whitespace
or the end of the string.  A `?' inside backquote signs matches
with group 2 alone, so a shell can read it untouched."
  (declare (pure t) (side-effect-free t))
  (concat "\\(?1:\\`\\|[ \t]\\)\\(?2:[*?]\\)\\(?3:[ \t]\\|\\'\\)"
          "\\|\\(?1:\\)\\(?2:`\\?`\\)\\(?3:\\)"))

(defun tired--shell-marks (string)
  "Return the substitution marks of STRING as a list of strings.
A mark is `*', `?' or a `?' that backquote signs wrap, where
whitespace isolates it, at the start or the end of STRING.  The
scan resumes at the end of the mark, so the trailing whitespace of
one match serves as the leading whitespace of the next, and one
space between two marks hides neither.  A resume at the end of the
whole match would consume that space once and leave the second mark
in place."
  (let ((regexp (tired--shell-regexp))
        (start 0)
        (marks nil))
    (while (string-match regexp string start)
      (push (match-string 2 string) marks)
      (setq start (match-end 2)))
    (nreverse marks)))

(defun tired--shell-mark-count (string mark)
  "Return the number of MARK characters in STRING."
  (let ((regexp (regexp-quote mark))
        (start 0)
        (count 0))
    (while (string-match regexp string start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun tired--shell-mark-match-p (string mark)
  "Return non-nil when STRING holds MARK where whitespace isolates it.
Isolated means whitespace on both sides, or the start or the end of
STRING.  A `?' wrapped in backquote signs counts too.  MARK of nil
matches either mark."
  (seq-some (lambda (text)
              (or (null mark) (string-search mark text)))
            (tired--shell-marks string)))

(defun tired--shell-fill-marks (command text)
  "Return COMMAND with every substitution mark replaced by TEXT.
TEXT goes in as it stands, so a caller quotes a file name first.
The scan continues after each mark, so two marks that one space
separates both fill, and a mark inside TEXT stays."
  (let ((regexp (tired--shell-regexp))
        (start 0)
        (parts nil))
    (while (string-match regexp command start)
      (push (substring command start (match-beginning 2)) parts)
      (push text parts)
      (setq start (match-end 2)))
    (push (substring command start) parts)
    (apply #'concat (nreverse parts))))

(defun tired--shell-keeps-mark-p (command mark)
  "Return non-nil when COMMAND passes MARK to the shell.
A mark that whitespace isolates becomes a substitution, so it never
reaches the shell.  Every other mark does, and so does a bare `?'
outside backquote signs."
  (let ((isolated 0))
    (dolist (text (tired--shell-marks command))
      (when (string-search mark text)
        (setq isolated (1+ isolated))))
    (< isolated (tired--shell-mark-count command mark))))

(defun tired--shell-file-name (path)
  "Return PATH as a name to hand to a shell command.
The name is relative to the shown directory, so an entry of an
inserted subdirectory reads as `sub/file'.  A name that starts with
a dash takes a leading `./', so the command does not read it as a
switch."
  (declare (side-effect-free t))
  (let ((name (file-relative-name path tired--directory)))
    (if (string-prefix-p "-" name) (concat "./" name) name)))

(defun tired--shell-parts (command)
  "Split COMMAND into its body and the flags of its last characters.
Return a list of the body, a background flag and a sequential
flag.  A trailing `&' asks for a background run.  A trailing `;'
or `;&' also asks for a background run, and it makes the runs wait
for each other."
  (let ((body command)
        (background nil)
        (sequential nil))
    (when (string-match "[ \t]*&[ \t]*\\'" body)
      (setq body (substring body 0 (match-beginning 0))
            background t))
    (when (string-match "[ \t]*;[ \t]*\\'" body)
      (setq body (substring body 0 (match-beginning 0))
            sequential t))
    (list body (or background sequential) sequential)))

(defun tired--shell-on-each (command files)
  "Return one shell command body per path in FILES.
A `?' mark in COMMAND takes the file name.  A COMMAND without a
mark takes the name at its end, after a space."
  (let ((substitutes (tired--shell-mark-match-p command "?"))
        (names (mapcar (lambda (path)
                         (shell-quote-argument (tired--shell-file-name path)))
                       files)))
    (mapcar (lambda (name)
              (if substitutes
                  (tired--shell-fill-marks command name)
                (concat command " " name)))
            names)))

(defun tired--shell-once (command files)
  "Return one shell command body for the whole list of FILES.
A substitution mark in COMMAND takes the shell-quoted list, and a
COMMAND without a mark takes the list at its end."
  (let ((names (mapconcat (lambda (path)
                            (shell-quote-argument (tired--shell-file-name path)))
                          files " ")))
    (if (tired--shell-mark-match-p command nil)
        (tired--shell-fill-marks command names)
      (concat command " " names))))

(defun tired--shell-command-line (command files background sequential)
  "Return the shell command line that runs COMMAND over FILES.
A `*' mark puts the whole file list into one run.  A `?' mark runs
COMMAND once per file, and so does a COMMAND without a mark.
BACKGROUND makes the whole line run in the background.
SEQUENTIAL makes the runs wait for each other."
  (if (tired--shell-mark-match-p command "*")
      (concat (tired--shell-once command files)
              (if background " &" ""))
    (let ((bodies (tired--shell-on-each command files)))
      (cond
       ((not background) (mapconcat #'identity bodies "; "))
       (sequential (concat "( " (mapconcat #'identity bodies "; ") " ) &"))
       (t (concat (mapconcat #'identity bodies " & ") " & wait"))))))

(defun tired--shell-target-label (targets)
  "Return a description of TARGETS for a shell command prompt."
  (declare (pure t) (side-effect-free t))
  (if (null (cdr targets))
      (file-name-nondirectory
       (directory-file-name (tired-entry-path (car targets))))
    (format "%d entries" (length targets))))

(defun tired-do-shell-command (command)
  "Run shell COMMAND on the target entries.
Tired reads the targets from the selection, then the region, then
the row at point, and it lists them relative to the shown
directory.

A `*' that whitespace isolates in COMMAND stands for the whole file
list in one run.  A `?' that whitespace isolates stands for one
file, so Tired runs COMMAND once per file.  With neither mark,
Tired adds one file name to COMMAND and runs it once per file.  A
mark that whitespace does not isolate reaches the shell as it
stands, and Tired asks one question first unless
`tired-confirm-shell-command' is nil.  A `?' inside backquote signs
counts as a substitution too.

A trailing `&' runs the command in the background, with one job per
file.  A trailing `;' or `;&' runs the files one after another, in
one background job.  A background run leaves the listing alone,
and a synchronous run refreshes it, because COMMAND can create or
remove paths.

The shell owns the result, so `tired-undo' cannot reverse this
command.  The command clears the selection and the region, like
every other command that acts on targets."
  (interactive
   (let ((targets (tired--selection-targets)))
     (unless targets
       (user-error "No entry at point"))
     (list (read-shell-command
            (format "! on %s: " (tired--shell-target-label targets))
            nil 'tired-shell-command-history))))
  (let ((targets (tired--targets)))
    (unless targets
      (user-error "No entry at point"))
    (cl-destructuring-bind (body background sequential)
        (tired--shell-parts command)
      (when (string-blank-p body)
        (user-error "Empty shell command"))
      (when (and (tired--shell-mark-match-p body "*")
                 (tired--shell-mark-match-p body "?"))
        (user-error "Do not combine `*' and `?' marks"))
      (when (and tired-confirm-shell-command
                 (or (tired--shell-keeps-mark-p body "*")
                     (tired--shell-keeps-mark-p body "?"))
                 (not (y-or-n-p
                       "A `*' or `?' stays for the shell.  Run the command? ")))
        (user-error "Command canceled"))
      (let ((default-directory (file-name-as-directory tired--directory)))
        (shell-command
         (tired--shell-command-line body (mapcar #'tired-entry-path targets)
                                    background sequential)))
      (tired--clear-selection)
      (deactivate-mark)
      (unless background
        (tired-refresh)))))

(provide 'tired-file-ops)

;;; tired-file-ops.el ends here
