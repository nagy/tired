;;; tired-elements.el --- Element counts for Tired rows  -*- lexical-binding: t -*-

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

;; The Elements column counts the items that a listing row holds.
;; A redraw prints the count that `tired--elements-cache' holds and
;; queues the rest, so a redraw reads no file.  One global idle queue
;; runs one dissector per path in small steps, and
;; `tired-elements-functions' holds the dissectors, so a user extends
;; the column with `add-hook'.

;;; Code:

(require 'cl-lib)

(require 'tired-core)

(defcustom tired-elements-functions
  '(tired-elements-directory)
  "Abnormal hook that counts the elements of one path.
Each function receives the absolute file name and returns nil when
it has no opinion, an integer for a count that it knows now, or a
`tired--elements-job' for a count that it reads in steps.  The first
non-nil result wins, so a cheap test belongs before an expensive
read."
  :type 'hook
  :group 'tired)

(defcustom tired-elements-budget 0.02
  "Seconds that one idle pass spends on element counts.
A nil value lets one pass run until the queue empties.
`input-pending-p' still stops a pass when a key waits."
  :type '(choice (number :tag "Seconds") (const :tag "No budget" nil))
  :group 'tired)

(defcustom tired-elements-chunk-size 65536
  "Bytes that one step reads from a file.
Only a dissector that reads a file in steps uses the value."
  :type '(integer 1 *)
  :group 'tired)

(defcustom tired-elements-cache-ttl 60
  "Seconds that a cached element count survives without a read.
A redraw that shows a row refreshes its entry, so a shown file keeps
its count.  `tired-refresh' drops every entry that no buffer read
inside this window.  A nil value keeps every entry for the session."
  :type '(choice (number :tag "Seconds") (const :tag "Never" nil))
  :group 'tired)

(defcustom tired-elements-reprint-delay 0.2
  "Seconds between a finished element count and the reprint.
One reprint serves every count that finished inside the window, so a
directory of many files costs one print."
  :type 'number
  :group 'tired)

(cl-defstruct (tired--elements-job (:constructor tired--elements-job-create))
  "One incremental read for the element count of one path.
PATH is absolute.  STAMP holds the modification time and the size
that the row reported when the job was queued, so a finished count
lands in the cache for the file that the read saw.  HOOKS holds the
hook value that the dissector ran with.  STEP is a function of this
job that returns `:more' or `:done'.  STATE holds whatever the
dissector keeps between steps.  COUNT holds the finished number, or
nil for no count.  OWNERS lists the buffers that show the path.
OFFSET and SIZE drive a chunked read."
  path
  stamp
  hooks
  step
  state
  count
  owners
  offset
  size)

(defvar tired--elements-cache (make-hash-table :test #'equal)
  "Global table of element counts.
The key is the absolute file name.  The value holds the
modification time and the size that the count describes, the hook
value that produced it, the `float-time' of the last read, and the
count itself.  Every Tired buffer shares the table, so one file
costs one read.")

(defconst tired--elements-missing (make-symbol "tired--elements-missing")
  "Value that marks a path with no entry in `tired--elements-cache'.")

(defvar tired--elements-jobs nil
  "Jobs that wait for a step.  The head runs first.")

(defvar tired--elements-queued (make-hash-table :test #'equal)
  "Hash table that maps a path to the job that counts it.")

(defvar tired--elements-timer nil
  "Idle timer that runs one more pass over `tired--elements-jobs'.")

(defvar tired--elements-dirty nil
  "Buffers that wait for a reprint after a finished count.")

(defvar tired--elements-reprint-timer nil
  "Timer that repaints the buffers in `tired--elements-dirty'.")

(defvar tired--elements-always nil
  "When non-nil, queue element counts with no window.
Batch Emacs shows no window, so the test suite binds this to t.")

(defun tired--elements-key (path)
  "Return the `tired--elements-cache' key for PATH.
Join the absolute name as plain text, so a name of `~' stays a name
and needs no home directory lookup."
  (directory-file-name (expand-file-name path)))

(defun tired--elements-stamp (entry)
  "Return the `(MTIME SIZE)' stamp of ENTRY, or nil.
A remote path returns nil, because every read there costs one
network round trip.  A symbolic link reads the attributes of its
target, so the count of a link describes the file that the link
shows."
  (let ((path (tired-entry-path entry)))
    (if (file-remote-p path)
        nil
      (if (eq (tired-entry-type entry) 'symlink)
          (let ((attributes (file-attributes path)))
            (when attributes
              (list (float-time (file-attribute-modification-time attributes))
                    (file-attribute-size attributes))))
        (list (tired-entry-mtime entry)
              (tired-entry-size entry))))))

(defun tired--elements-entry (key stamp)
  "Return the cache entry for KEY under STAMP, or nil.
A matching entry takes the current `float-time', because a redraw
that shows the row counts as a read.  An entry that describes another
modification time, another size or another hook value does not match."
  (let ((hit (gethash key tired--elements-cache tired--elements-missing)))
    (when (and (not (eq hit tired--elements-missing))
               (equal (nth 0 hit) stamp)
               (equal (nth 1 hit) tired-elements-functions))
      (setcar (nthcdr 2 hit) (float-time))
      hit)))

(defun tired--elements-value (row)
  "Return the element count that ROW shows, or nil.
A count that no cache entry holds is nil, and the idle queue fills it
after the print."
  (when (tired-entry-p row)
    (when-let* ((stamp (tired--elements-stamp row))
                (hit (tired--elements-entry
                      (tired--elements-key (tired-entry-path row))
                      stamp)))
      (nth 3 hit))))

(defun tired--elements-enqueue (row)
  "Queue ROW for a count unless a fresh count or a job holds it.
A second buffer that shows the same path joins the running job, so
one read serves every listing."
  (let ((path (tired--elements-key (tired-entry-path row)))
        (stamp (tired--elements-stamp row)))
    (when stamp
      (let ((job (gethash path tired--elements-queued)))
        (cond
         ((tired--elements-entry path stamp) nil)
         (job
          (unless (memq (current-buffer) (tired--elements-job-owners job))
            (push (current-buffer) (tired--elements-job-owners job))))
         (t
          (let ((job (tired--elements-job-create
                      :path path
                      :stamp stamp
                      :size (nth 1 stamp)
                      :step #'tired--elements-dispatch
                      :owners (list (current-buffer)))))
            (puthash path job tired--elements-queued)
            (push job tired--elements-jobs)
            (tired--elements-schedule))))))))

(defun tired--elements-queue ()
  "Queue every visible row of the listing for an element count.
`tired--redraw-buffer' calls this after the print.  Walk the rows
backwards, so the job of the top row sits at the head of the queue
and runs first.  A row whose count is fresh needs nothing, and a
section row has no count."
  (when (or tired--elements-always (tired--size-window-p))
    (dolist (cell (reverse (tired--visible-rows)))
      (let ((row (car cell)))
        (when (tired-entry-p row)
          (tired--elements-enqueue row))))))

(defun tired--elements-step (job)
  "Advance JOB by one step, inside the buffer that queued it.
A dissector may read the entry table of the listing, so the buffer
of the first owner stays current.  Return `:more' or `:done'."
  (let ((buffer (car (tired--elements-job-owners job))))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (funcall (tired--elements-job-step job) job))
      (funcall (tired--elements-job-step job) job))))

(defun tired--elements-dispatch (job)
  "Run `tired-elements-functions' for the path of JOB.
An integer finishes the job.  A job hands its step and its state
over, and the same pass steps it.  No dissector finishes the job
with no count."
  (setf (tired--elements-job-hooks job)
        (copy-sequence tired-elements-functions))
  (let ((result (run-hook-with-args-until-success
                 'tired-elements-functions
                 (tired--elements-job-path job))))
    (cond
     ((integerp result)
      (setf (tired--elements-job-count job) result)
      :done)
     ((and (tired--elements-job-p result)
           (functionp (tired--elements-job-step result))
           (not (eq (tired--elements-job-step result)
                    #'tired--elements-dispatch)))
      (setf (tired--elements-job-step job)
            (tired--elements-job-step result)
            (tired--elements-job-state job)
            (tired--elements-job-state result))
      (tired--elements-step job))
     (t (setf (tired--elements-job-count job) nil)
        :done))))

(defun tired--elements-finish (job)
  "Store the count of JOB and mark its buffers for a reprint.
Store a nil count as well, so a file that no dissector understands
costs no second read."
  (let ((path (tired--elements-job-path job)))
    (remhash path tired--elements-queued)
    (setq tired--elements-jobs (delq job tired--elements-jobs))
    (puthash path
             (list (tired--elements-job-stamp job)
                   (tired--elements-job-hooks job)
                   (float-time)
                   (tired--elements-job-count job))
             tired--elements-cache)
    (dolist (buffer (tired--elements-job-owners job))
      (when (and (buffer-live-p buffer)
                 (not (memq buffer tired--elements-dirty)))
        (push buffer tired--elements-dirty)))))

(defun tired--elements-run ()
  "Advance the queue until the budget ends or a key waits.
Each step gives way to the next job, so one large file never holds
the counts of the other rows.  A pass that leaves work schedules
another idle pass."
  (setq tired--elements-timer nil)
  (let ((deadline (and tired-elements-budget
                       (+ (float-time) tired-elements-budget))))
    (while (and tired--elements-jobs
                (not (input-pending-p))
                (or (null deadline) (< (float-time) deadline)))
      (let ((job (car tired--elements-jobs)))
        (if (eq (tired--elements-step job) :done)
            (tired--elements-finish job)
          (setq tired--elements-jobs
                (nconc (cdr tired--elements-jobs) (list job)))))))
  (when tired--elements-jobs
    (tired--elements-schedule))
  (when tired--elements-dirty
    (tired--elements-reprint-schedule)))

(defun tired--elements-schedule ()
  "Arrange one more pass at the next idle period.
An idle timer fires once for one transition into the idle state, so
each pass schedules its own successor."
  (unless (timerp tired--elements-timer)
    (setq tired--elements-timer
          (run-with-idle-timer 0 nil #'tired--elements-run))))

(defun tired--elements-reprint-schedule ()
  "Arrange one reprint for every buffer that waits for a count."
  (unless (timerp tired--elements-reprint-timer)
    (setq tired--elements-reprint-timer
          (run-at-time tired-elements-reprint-delay nil
                       #'tired--elements-reprint))))

(defun tired--elements-reprint ()
  "Repaint every dirty buffer that a window shows.
A buffer that no window shows keeps its counts and prints them at
its next redraw."
  (setq tired--elements-reprint-timer nil)
  (let ((dirty tired--elements-dirty))
    (setq tired--elements-dirty nil)
    (dolist (buffer (delete-dups dirty))
      (when (and (buffer-live-p buffer)
                 (get-buffer-window buffer t)
                 (with-current-buffer buffer
                   (derived-mode-p 'tired-mode)))
        (with-current-buffer buffer
          (tired--redraw))))))

(defun tired--elements-prune ()
  "Drop the cached counts that no buffer read for the cache window.
Call it on refresh, so the table holds no path that the user left."
  (when tired-elements-cache-ttl
    (let (stale)
      (maphash (lambda (key entry)
                 (when (> (- (float-time) (nth 2 entry))
                          tired-elements-cache-ttl)
                   (push key stale)))
               tired--elements-cache)
      (dolist (key stale)
        (remhash key tired--elements-cache)))))

(defun tired-elements-clear-cache ()
  "Drop every cached element count and count the shown rows again.
The command has no key and no menu entry, so `M-x' alone reaches it.
It serves a file that changed without a move of its modification
time or its size."
  (interactive)
  (clrhash tired--elements-cache)
  (setq tired--elements-jobs nil
        tired--elements-queued (make-hash-table :test #'equal))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'tired-mode)
        (tired--redraw)))))

(defun tired-elements-directory (path)
  "Return the number of immediate children of the directory at PATH.
Count every name that `directory-files' returns, dotfiles included,
and never a subtree.  A shown directory already holds its names in
its entry table, so it costs no read.  Return nil for a file."
  (when (file-directory-p path)
    (let ((table (and (derived-mode-p 'tired-mode)
                      (tired--table path))))
      (if table
          (hash-table-count table)
        (length (tired--directory-names path))))))

(setq tired--elements-value-function #'tired--elements-value
      tired--elements-queue-function #'tired--elements-queue
      tired--elements-prune-function #'tired--elements-prune)

(provide 'tired-elements)

;;; tired-elements.el ends here
