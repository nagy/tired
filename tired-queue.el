;;; tired-queue.el --- The idle job queue of Tired  -*- lexical-binding: t -*-

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

;; The idle job queue that runs the directory size walks and the element
;; counts.  A job holds a kind, a key, a step function, a finish
;; function, a budget, the buffers that wait for its repaint, and a data
;; slot for its kind.  One pass runs one step of every job, so no kind
;; holds the queue, and a pass that leaves work schedules its own
;; successor.
;;
;; The queue holds no directory and no count, so `tired-core' and
;; `tired-elements' queue their own kinds here.  The only call back into
;; the listing is the reprint, `tired--redraw'.
;;
;; Design notes for a change in this file:
;;
;; - `tired--queue-enqueue' holds the idle jobs of the process, one per
;;   kind and key.  A pass takes the queue down, runs one step of every
;;   job, and starts another round over the unfinished jobs until every
;;   job spends its own `tired--job-budget' or pending input stops it.
;;   A job never spends the budget of another kind, so a nil budget
;;   bounds that job alone, and the pass adds the seconds that each step
;;   took.  A pass that leaves work schedules its own successor through
;;   `tired--queue-delay', and through `tired--queue-busy-delay' while a
;;   key waits.  Never chain an idle timer: a ripe idle timer stops the
;;   read loop before the wait that reads subprocess output, so a walk
;;   would starve every process of its output and sentinel.  See
;;   `docs/adr/0032'.
;; - A job belongs to the buffer that queued it, and a second listing
;;   that wants the same key joins the running job instead of queueing a
;;   second one.  A job that loses its last owner leaves the queue, so a
;;   killed buffer costs no step.
;; - The reprint rides one timer, and it repaints a dirty buffer alone
;;   when a window shows it and that buffer runs `tired-mode'.  A buffer
;;   that no window shows keeps its state and paints at its next redraw.

;;; Code:

(require 'cl-lib)

;; The reprint repaints a listing, and this library sits below the
;; listing, so the call takes a declaration and no load-time dependency.
(declare-function tired--redraw "tired-core" (&optional window))

(defcustom tired-queue-reprint-delay 0.2
  "Seconds between the last finished idle job and its repaint.
One timer repaints every buffer that a job marked dirty, so a long
walk costs few reprints."
  :type 'number
  :group 'tired)

(cl-defstruct (tired--job (:constructor tired--job-create))
  "One resumable unit of work on the idle queue.
KEY names the job inside its KIND, so one key costs one job while it
waits.  STEP advances the job and returns `:more' or `:done'.
FINISH runs once after STEP returns `:done'.  BUDGET holds the
seconds that one pass may spend on this job, or nil for no limit.
OWNERS holds the buffers that wait for a repaint.  DATA holds the
state of the job kind."
  kind
  key
  step
  finish
  budget
  owners
  data)

(defvar tired--queue-jobs nil
  "Jobs that wait for a step.
The head job runs first.")

(defvar tired--queue-index (make-hash-table :test #'equal)
  "Hash table that maps a job key to the job that holds it.")

(defvar tired--queue-timer nil
  "Idle timer that runs one more pass over `tired--queue-jobs'.")

(defvar tired--queue-dirty nil
  "Buffers that wait for a repaint after a finished job.")

(defvar tired--queue-reprint-timer nil
  "Timer that repaints the buffers in `tired--queue-dirty'.")

(defun tired--queue-index-key (job)
  "Return the key that `tired--queue-index' maps to JOB.
The kind joins the key, so a size walk and an element count of one
directory stay two jobs."
  (declare (pure t) (side-effect-free t))
  (let ((key (tired--job-key job)))
    (when key
      (cons (tired--job-kind job) key))))

(defun tired--queue-job (kind key)
  "Return the queued job of KIND that holds KEY, or nil."
  (declare (side-effect-free t))
  (when key
    (gethash (cons kind key) tired--queue-index)))

(defun tired--queue-drop (job)
  "Remove JOB from the queue without a finish."
  (setq tired--queue-jobs (delq job tired--queue-jobs))
  (let ((key (tired--queue-index-key job)))
    (when (and key (eq (gethash key tired--queue-index) job))
      (remhash key tired--queue-index))))

(defun tired--queue-drop-where (predicate)
  "Drop every queued job that PREDICATE accepts."
  (dolist (job (copy-sequence tired--queue-jobs))
    (when (funcall predicate job)
      (tired--queue-drop job))))

(defun tired--queue-enqueue (job)
  "Push JOB onto the queue unless a job already holds its key.
Return JOB when it joins the queue, and nil when it does not."
  (let ((key (tired--queue-index-key job)))
    (unless (and key (gethash key tired--queue-index))
      (when key
        (puthash key job tired--queue-index))
      (push job tired--queue-jobs)
      (tired--queue-schedule)
      job)))

(defun tired--queue-adopt (job buffer)
  "Make BUFFER wait for the repaint of JOB."
  (unless (memq buffer (tired--job-owners job))
    (push buffer (tired--job-owners job))))

(defun tired--queue-mark-dirty (buffers)
  "Mark BUFFERS for a repaint after a finished job."
  (dolist (buffer buffers)
    (when (and (buffer-live-p buffer)
               (not (memq buffer tired--queue-dirty)))
      (push buffer tired--queue-dirty))))

(defun tired--queue-forget-buffer (buffer)
  "Drop BUFFER as an owner and drop every job that loses all owners."
  (setq tired--queue-dirty (delq buffer tired--queue-dirty))
  (dolist (job (copy-sequence tired--queue-jobs))
    (when (memq buffer (tired--job-owners job))
      (setf (tired--job-owners job) (delq buffer (tired--job-owners job)))
      (when (null (tired--job-owners job))
        (tired--queue-drop job)))))

(defun tired--queue-forget-current ()
  "Drop every idle job that the current buffer owns.
`kill-buffer-hook' runs this, because a dead buffer never repaints."
  (tired--queue-forget-buffer (current-buffer)))

(defun tired--queue-finish (job)
  "Drop JOB from the queue and run its finish function."
  (tired--queue-drop job)
  (when (functionp (tired--job-finish job))
    (funcall (tired--job-finish job) job)))

(defun tired--queue-holds-p (job)
  "Return non-nil when JOB still holds its place in the queue.
A pass that runs keeps its jobs in a local list, so this asks the
index, and a job that `tired--queue-drop' removed during the pass
costs no step."
  (declare (side-effect-free t))
  (let ((key (tired--queue-index-key job)))
    (or (null key)
        (eq (gethash key tired--queue-index) job))))

(defconst tired--queue-delay 0.02
  "Seconds between two idle queue passes.
A normal timer chain reads subprocess output between two passes.
An always-ripe idle timer chain does not: Emacs skips the wait that
reads that output, so no process shows output and no sentinel runs
until every queued job finishes.  Measured on Emacs 31.1, a child
that writes after one second reaches its filter at once with this
chain and after five seconds with an idle chain.")

(defconst tired--queue-busy-delay 0.1
  "Seconds between two passes while a key waits.
A pass that a keystroke stops costs no step, and the pass that
follows costs another 0.02 seconds of waiting, so a burst of typing
would arm forty timers per second.  The longer gap keeps a user who
types cheap.")

(defun tired--queue-run ()
  "Advance the queue until every job spends its budget or a key waits.
Each step gives way to the next job, so one large job never holds
the others.  A pass that leaves work arms its successor.
A job stops at its own `tired--job-budget', so a mixed pass honors the
option of every kind, and a nil budget bounds that job alone.  The
pass adds the seconds that a step took, so a job that a previous pass
left unfinished starts with a fresh budget.
The pass takes the queue down while it runs, so a finished job drops
from a short list and a job that joins the queue lands on a clean
one; a rotation of the whole queue per step would cost one list copy
per step."
  (setq tired--queue-timer nil)
  (let ((pending tired--queue-jobs)
        (kept nil)
        (spent (make-hash-table :test #'eq))
        (progress t))
    (setq tired--queue-jobs nil)
    (catch 'done
      (while (or pending kept)
        (when (input-pending-p)
          (throw 'done nil))
        (if (null pending)
            ;; Every job took its turn, so the unfinished ones take the
            ;; next round inside this pass, and a round that spends no
            ;; step leaves the queue for the next pass.
            (if progress
                (setq pending (nreverse kept)
                      kept nil
                      progress nil)
              (throw 'done nil))
          (let* ((job (pop pending))
                 (budget (tired--job-budget job))
                 (used (gethash job spent 0)))
            (when (tired--queue-holds-p job)
              (if (and budget (>= used budget))
                  (push job kept)
                (let ((start (float-time)))
                  (setq progress t)
                  (if (eq (funcall (tired--job-step job) job) :done)
                      (tired--queue-finish job)
                    (puthash job (+ used (- (float-time) start)) spent)
                    (push job kept)))))))))
    (setq tired--queue-jobs
          (nconc (nreverse kept) pending (nreverse tired--queue-jobs))))
  (when tired--queue-jobs
    (tired--queue-schedule
     (and (input-pending-p) tired--queue-busy-delay)))
  (when tired--queue-dirty
    (tired--queue-reprint-schedule)))

(defun tired--queue-schedule (&optional delay)
  "Arrange one more pass after DELAY seconds.
DELAY defaults to `tired--queue-delay'.  The timer is a normal timer,
because a ripe idle timer starves every subprocess of its output."
  (unless (timerp tired--queue-timer)
    (setq tired--queue-timer
          (run-at-time (or delay tired--queue-delay) nil
                       #'tired--queue-wake))))

(defun tired--queue-wake ()
  "Run one idle queue pass unless input waits.
A normal timer fires while Emacs reads a command too, so the gate
sends the pass back to `tired--queue-schedule' when a key waits."
  (setq tired--queue-timer nil)
  (cond
   ((null tired--queue-jobs) nil)
   ((input-pending-p) (tired--queue-schedule tired--queue-busy-delay))
   (t (tired--queue-run))))

(defun tired--queue-reprint-schedule ()
  "Arrange one reprint for every buffer that waits for a job."
  (unless (timerp tired--queue-reprint-timer)
    (setq tired--queue-reprint-timer
          (run-at-time tired-queue-reprint-delay nil
                       #'tired--queue-reprint))))

(defun tired--queue-reprint ()
  "Repaint every dirty buffer that a window shows.
A buffer that no window shows keeps its state and prints it at its
next redraw."
  (setq tired--queue-reprint-timer nil)
  (let ((dirty tired--queue-dirty))
    (setq tired--queue-dirty nil)
    (dolist (buffer (delete-dups dirty))
      (when (and (buffer-live-p buffer)
                 (get-buffer-window buffer t)
                 (with-current-buffer buffer
                   (derived-mode-p 'tired-mode)))
        (with-current-buffer buffer
          (tired--redraw))))))

(provide 'tired-queue)

;;; tired-queue.el ends here
