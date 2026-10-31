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

;; The file commands that change the file system: copy, move, delete,
;; mkdir and touch.  Each command pushes one undo action, and the
;; session trash keeps every removed byte.  The shell command lives
;; here too, because it is the one command that runs a shell.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tired-core)

(defvar tired--trash-counter 0
  "Counter that makes names inside the session trash unique.")

(defvar tired-trash-directory
  (expand-file-name (format "tired-trash-%d-%d/" (user-uid) (emacs-pid))
                    temporary-file-directory)
  "Directory that holds paths removed during this session.
`tired-delete' moves its targets here.  A copy or a move that
replaces a path puts the old path here first.  `tired-undo' moves
the path back.  The directory lives under the variable
`temporary-file-directory', so the system clears it when the
machine reboots.  Emacs copies the path and then deletes it when
the trash sits on another file system.")

(defvar tired-undo-push-functions nil
  "Abnormal hook that takes every undoable Tired action.
Each function receives DESCRIPTION and FUNCTION.  DESCRIPTION is a
string that names the action.  FUNCTION reverts the action and
takes no argument.  While the hook is empty, Tired keeps the
action on `tired--undo-actions' for `tired-undo'.")

(defvar tired--undo-actions nil
  "Stack of undo actions as (DESCRIPTION . FUNCTION) conses.
The most recent action comes first.")

(defun tired--path-exists-p (path)
  "Return non-nil when PATH exists, including a dangling symbolic link."
  (or (file-exists-p path) (file-symlink-p path)))

(defun tired--trash-name (path)
  "Return an unused name for PATH inside `tired-trash-directory'."
  (let* ((name (file-name-nondirectory (directory-file-name path)))
         (base (expand-file-name name tired-trash-directory))
         (stamp (format-time-string "%Y%m%dT%H%M%S"))
         candidate)
    (while (progn
             (setq tired--trash-counter (1+ tired--trash-counter))
             (setq candidate (format "%s.%s-%d" base stamp tired--trash-counter))
             (tired--path-exists-p candidate)))
    candidate))

(defun tired--trash-move (path)
  "Move PATH into `tired-trash-directory' and return the new path."
  (make-directory tired-trash-directory t)
  (let ((target (tired--trash-name path)))
    (rename-file path target)
    target))

(defun tired--restore-path (trash-path original)
  "Move TRASH-PATH back to ORIGINAL.
Do nothing when TRASH-PATH is gone, or when ORIGINAL exists again.
Return non-nil when the move happened."
  (when (and (tired--path-exists-p trash-path)
             (not (tired--path-exists-p original)))
    (make-directory (file-name-directory original) t)
    (rename-file trash-path original)
    t))

(defun tired--refresh-buffers ()
  "Refresh every live Tired buffer."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'tired-mode) tired--directory)
        (ignore-errors (tired-refresh))))))

(defun tired--push-undo (description function)
  "Hand FUNCTION to the undo stack as the undo of DESCRIPTION.
When `tired-undo-push-functions' is non-nil, those functions take
the action.  Otherwise the action joins `tired--undo-actions'."
  (if tired-undo-push-functions
      (run-hook-with-args 'tired-undo-push-functions description function)
    (push (cons description function) tired--undo-actions))
  description)

(defun tired-undo ()
  "Undo the last file operation of this session.
`tired-undo-push-functions' owns the action when the hook is
non-nil, so the command signals a user error then."
  (interactive)
  (let ((action (pop tired--undo-actions)))
    (unless action
      (user-error "Nothing for Tired to undo"))
    (funcall (cdr action))
    (message "Undid %s" (car action))))

(defun tired--report-operation (description done failures)
  "Announce DONE successes and FAILURES for DESCRIPTION."
  (if (null failures)
      (message "%s %d %s" description done (if (= done 1) "entry" "entries"))
    (display-warning
     'tired
     (concat (format "%s: %d done, %d failed."
                     description done (length failures))
             (mapconcat (lambda (failure)
                          (format "\n  %s: %s" (car failure) (cdr failure)))
                        failures ""))
     :warning)
    (message "%s: %d done, %d failed.  See *Warnings*"
             description done (length failures))))

(defun tired--path-under-p (path parent)
  "Return non-nil when PATH is PARENT or lies below it."
  (let ((path (directory-file-name (expand-file-name path)))
        (parent (directory-file-name (expand-file-name parent))))
    (or (equal path parent)
        (string-prefix-p (file-name-as-directory parent) path))))

(defun tired--next-surviving-row (row)
  "Return the first row below ROW that a removal of ROW keeps.
Rows of the same path and rows below it count as doomed, because a
command that removes a directory removes its children and a command
that removes a file removes its sections.  Return nil when no row
stays below ROW."
  (let ((from (and row (tired--row-position row))))
    (when from
      (let ((path (tired--row-path row))
            result)
        (save-excursion
          (goto-char from)
          (forward-line 1)
          (while (and (not result) (not (eobp)))
            (let ((here (tired--row-at-point)))
              (when (and here
                         (not (tired--path-under-p
                               (tired--row-path here) path)))
                (setq result here)))
            (forward-line 1)))
        result))))

(defun tired--apply-to-targets (description function)
  "Call FUNCTION with each target path and then clear the selection.
DESCRIPTION names the action.  Deepest paths run first, so a
selection that holds a directory and its children reaches the
children first.  A failure does not stop the remaining targets.
A command that removed the row at point leaves point on the next
row that survives, not on the first line.  Report the failures and
refresh the listing."
  (let ((targets (tired--selection-targets)))
    (unless targets
      (user-error "No entry at point"))
    (setq targets
          (sort (copy-sequence targets)
                (lambda (a b)
                  (> (length (tired-entry-path a))
                     (length (tired-entry-path b))))))
    (let* ((done 0)
           (failures nil)
           (point-row (tired--row-at-point))
           (successor (tired--next-surviving-row point-row)))
      (dolist (entry targets)
        (let ((path (tired-entry-path entry)))
          (condition-case err
              (progn (funcall function path)
                     (setq done (1+ done)))
            (error (push (cons path (error-message-string err)) failures)))))
      (tired-select-none)
      (tired-refresh)
      (unless (tired--row-position point-row)
        (tired--goto-row successor))
      (deactivate-mark)
      (tired--report-operation description done (nreverse failures)))))

(defun tired--undo-copy (created trashed)
  "Remove CREATED paths and put TRASHED paths back."
  (dolist (path created)
    (when (tired--path-exists-p path)
      (ignore-errors (tired--trash-move path))))
  (dolist (pair trashed)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (tired--refresh-buffers))

(defun tired--undo-move (moved trashed)
  "Move every MOVED pair back and put TRASHED paths back."
  (dolist (pair moved)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (dolist (pair trashed)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (tired--refresh-buffers))

(defun tired--undo-delete (trashed)
  "Put every TRASHED pair back, parents first."
  (dolist (pair trashed)
    (ignore-errors (tired--restore-path (car pair) (cdr pair))))
  (tired--refresh-buffers))

(defun tired--replace-with-trash (path)
  "Move PATH into the session trash and return the new name.
Return nil when PATH is absent."
  (when (tired--path-exists-p path)
    (tired--trash-move path)))

(defun tired--other-tired-directory ()
  "Return the directory of a Tired buffer in another window.
Scan the windows of this frame from the one after the selected
window, as `dired-dwim-target-next' does.  Return nil when no
other window shows a Tired buffer, or when that buffer shows the
directory of this buffer, because a move into the same directory
would change nothing."
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
An existing destination goes to `tired-trash-directory' first, so
`tired-undo' puts it back.  The copy never calls a shell."
  (interactive (list (read-directory-name "Copy targets to: " tired--directory)))
  (let ((destination (file-name-as-directory (expand-file-name directory)))
        (created nil)
        (trashed nil))
    (tired--apply-to-targets
     "Copied"
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
       (format "copy into %s" (abbreviate-file-name destination))
       (lambda () (tired--undo-copy created trashed))))))

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
  (let* ((targets (tired--selection-targets))
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
     "Moved"
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
       (format "move to %s" (abbreviate-file-name directory))
       (lambda () (tired--undo-move moved trashed))))))

(defun tired-delete ()
  "Move the targets into `tired-trash-directory'.
The command asks no question and never calls a shell.  A later
`tired-undo' moves the paths back."
  (interactive)
  (let ((trashed nil))
    (tired--apply-to-targets
     "Deleted"
     (lambda (path)
       (push (cons (tired--trash-move path) path) trashed)))
    (when trashed
      (tired--push-undo
       (format "delete of %d %s" (length trashed)
               (if (= (length trashed) 1) "entry" "entries"))
       (lambda () (tired--undo-delete trashed))))))

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
         (missing nil))
    (when (tired--path-exists-p path)
      (user-error "%s already exists" path))
    (while (and parent (not (file-directory-p parent)))
      (push (directory-file-name parent) missing)
      (setq parent (file-name-directory (directory-file-name parent))))
    (make-directory path t)
    (tired--push-undo
     (format "mkdir %s" (abbreviate-file-name path))
     (lambda ()
       (when (file-directory-p path)
         (tired--trash-move path))
       (dolist (dir (reverse missing))
         (when (and (file-directory-p dir)
                    (null (directory-files dir nil "\\`[^.]")))
           (delete-directory dir)))))
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
                     (file-attribute-modification-time (file-attributes path)))))
    (when (file-directory-p path)
      (user-error "%s is a directory" path))
    (write-region "" nil path nil 'silent)
    (tired--push-undo
     (format "touch %s" (abbreviate-file-name path))
     (lambda ()
       (cond ((not exists)
              (when (tired--path-exists-p path)
                (tired--trash-move path)))
             (mtime
              (set-file-times path mtime)))))
    (tired-refresh)
    (message "%s %s" (if exists "Touched" "Created")
             (abbreviate-file-name path))))

(defvar tired-shell-command-history nil
  "History list for `tired-do-shell-command'.")

(defcustom tired-confirm-shell-command t
  "Whether `tired-do-shell-command' asks about a mark that stays.
A `*' or `?' that whitespace does not isolate reaches the shell
untouched, and the user sometimes means a substitution.  The
command asks one yes-or-no question in that case.  Set this option
to nil to skip the question."
  :type 'boolean
  :group 'tired)

(defun tired--shell-regexp ()
  "Return the regexp that matches one substitution mark.
Group 1 holds the leading whitespace or the start of the string,
group 2 holds the mark and group 3 holds the trailing whitespace
or the end of the string.  A `?' inside backquote signs matches
with group 2 alone, so a shell can read it untouched."
  (concat "\\(?1:\\`\\|[ \t]\\)\\(?2:[*?]\\)\\(?3:[ \t]\\|\\'\\)"
          "\\|\\(?1:\\)\\(?2:`\\?`\\)\\(?3:\\)"))

(defun tired--shell-marks (string)
  "Return the substitution marks of STRING as a list of strings.
A mark is `*', `?' or a `?' that backquote signs wrap, where
whitespace isolates it, at the start or the end of STRING.  The
scan continues after each mark, so one space between two marks
hides neither."
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
  (let ((targets (tired--selection-targets)))
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
      (tired-select-none)
      (deactivate-mark)
      (unless background
        (tired-refresh)))))

(provide 'tired-file-ops)

;;; tired-file-ops.el ends here
