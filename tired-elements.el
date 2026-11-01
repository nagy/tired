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
(require 'seq)
(require 'subr-x)

(require 'tired-core)

(defcustom tired-elements-functions
  '(tired-elements-directory
    tired-elements-json
    tired-elements-markdown
    tired-elements-csv
    tired-elements-parquet
    tired-elements-sections)
  "Abnormal hook that counts the elements of one path.
Each function receives the absolute file name and returns nil when
it has no opinion, an integer for a count that it knows now, or a
`tired--elements-job' for a count that it reads in steps.  The first
non-nil result wins, so a cheap test belongs before an expensive
read.  `tired-elements-directory' counts the immediate children of a
directory, `tired-elements-json' counts a top-level JSON container,
`tired-elements-markdown' counts the top-level Markdown headings,
`tired-elements-csv' counts the uncommented rows of a CSV file,
`tired-elements-parquet' reads the row count of a Parquet footer, and
`tired-elements-sections' counts the sections at depth zero of any
other file that a handler claims."
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

(defcustom tired-elements-sync-limit 1000000
  "Largest file, in bytes, that the section fallback parses.
The Parquet dissector holds its footer under the same bound.
`tired-file-sections' parses a whole file in one call, so a larger
file keeps an empty cell instead of blocking the idle pass, and a
footer beyond the bound keeps no count."
  :type '(integer 0 *)
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
                      :offset 0
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
of the first owner stays current.  A dissector that signals finishes
the job with no count, so one bad file never stops the queue.
Return `:more' or `:done'."
  (let ((buffer (car (tired--elements-job-owners job))))
    (condition-case err
        (if (buffer-live-p buffer)
            (with-current-buffer buffer
              (funcall (tired--elements-job-step job) job))
          (funcall (tired--elements-job-step job) job))
      (error
       (display-warning
        'tired
        (format "Element dissector failed on %s: %s"
                (abbreviate-file-name (tired--elements-job-path job))
                (error-message-string err))
        :warning)
       (setf (tired--elements-job-count job) nil)
       :done))))

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

;;; Readers

(defun tired--elements-read-range (path start end)
  "Return the bytes of PATH from START to END as a unibyte string.
`insert-file-contents-literally' seeks on a local file, so a range
read costs the bytes that the caller asks for and never the whole
file.  A dissector that reads a tail or a header uses this helper,
and `tired--elements-read' wraps it for a forward walk."
  (when (< start end)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path nil start end)
      (buffer-string))))

(defun tired--elements-read (job)
  "Return the next chunk of JOB as a unibyte string, or nil.
Read with `insert-file-contents-literally', so a dissector sees the
bytes of the file and no decoded text.  A range read seeks on a local
file, so one step costs one read, whatever the size of the file."
  (let* ((offset (or (tired--elements-job-offset job) 0))
         (end (min (or (tired--elements-job-size job) 0)
                   (+ offset tired-elements-chunk-size))))
    (when (< offset end)
      (setf (tired--elements-job-offset job) end)
      (tired--elements-read-range (tired--elements-job-path job)
                                  offset end))))

;;; JSON

(defconst tired--json-whitespace '(?\s ?\t ?\n ?\r)
  "Characters that JSON reads as whitespace.")

(cl-defstruct (tired--json-state (:constructor tired--json-state-create))
  "Scanner state for the top-level items of a JSON file.
MODE holds `array', `object' or nil before the root.  DEPTH counts
the open containers.  COUNT holds the items that the scan found.
IN-STRING and ESCAPE track a string, and KEY-OPEN marks the key
string of an object.  EXPECT holds whether a new value or key may
start.  DONE holds when the root closed, and INVALID holds when the
first byte is no container."
  mode
  depth
  count
  in-string
  escape
  expect
  key-open
  done
  invalid)

(defun tired--json-scan (state string)
  "Advance STATE over STRING and return STATE.
Count the items of a top-level array and the keys of a top-level
object.  A string, an escape and a chunk boundary carry over, so one
chunk of a split string never changes the count."
  (let ((index 0)
        (length (length string)))
    (while (and (< index length)
                (not (tired--json-state-done state))
                (not (tired--json-state-invalid state)))
      (let ((char (aref string index)))
        (cond
         ((null (tired--json-state-mode state))
          (unless (memq char tired--json-whitespace)
            (pcase char
              (?\[
               (setf (tired--json-state-mode state) 'array
                     (tired--json-state-depth state) 1
                     (tired--json-state-count state) 0
                     (tired--json-state-expect state) t))
              (?\{
               (setf (tired--json-state-mode state) 'object
                     (tired--json-state-depth state) 1
                     (tired--json-state-count state) 0
                     (tired--json-state-expect state) t))
              (_
               (setf (tired--json-state-invalid state) t
                     (tired--json-state-done state) t)))))
         ((tired--json-state-in-string state)
          (cond
           ((tired--json-state-escape state)
            (setf (tired--json-state-escape state) nil))
           ((eq char ?\\)
            (setf (tired--json-state-escape state) t))
           ((eq char ?\")
            (setf (tired--json-state-in-string state) nil)
            (when (and (eq (tired--json-state-mode state) 'object)
                       (= (tired--json-state-depth state) 1)
                       (tired--json-state-key-open state))
              (setf (tired--json-state-key-open state) nil
                    (tired--json-state-expect state) nil
                    (tired--json-state-count state)
                    (1+ (tired--json-state-count state)))))))
         ((memq char tired--json-whitespace) nil)
         (t
          (when (and (eq (tired--json-state-mode state) 'array)
                     (= (tired--json-state-depth state) 1)
                     (tired--json-state-expect state)
                     (not (eq char ?\])))
            (setf (tired--json-state-expect state) nil
                  (tired--json-state-count state)
                  (1+ (tired--json-state-count state))))
          (cond
           ((eq char ?\")
            (setf (tired--json-state-in-string state) t)
            (when (and (eq (tired--json-state-mode state) 'object)
                       (= (tired--json-state-depth state) 1)
                       (tired--json-state-expect state))
              (setf (tired--json-state-key-open state) t)))
           ((memq char '(?\[ ?\{))
            (setf (tired--json-state-depth state)
                  (1+ (tired--json-state-depth state))
                  (tired--json-state-expect state) nil))
           ((memq char '(?\] ?\}))
            (setf (tired--json-state-depth state)
                  (1- (tired--json-state-depth state)))
            (when (= (tired--json-state-depth state) 0)
              (setf (tired--json-state-done state) t)))
           ((eq char ?\,)
            (when (= (tired--json-state-depth state) 1)
              (setf (tired--json-state-expect state) t)))))))
      (setq index (1+ index))))
  state)

(defun tired--json-step (job)
  "Advance JOB over the next chunk of its JSON file.
Return `:done' when the root container closed or the file ended."
  (let ((state (tired--elements-job-state job)))
    (if (or (tired--json-state-done state)
            (>= (or (tired--elements-job-offset job) 0)
                (or (tired--elements-job-size job) 0)))
        (progn
          (setf (tired--elements-job-count job)
                (and (tired--json-state-done state)
                     (not (tired--json-state-invalid state))
                     (tired--json-state-count state)))
          :done)
      (when-let* ((chunk (tired--elements-read job)))
        (tired--json-scan state chunk))
      :more)))

(defun tired-elements-json (path)
  "Return a count or a job for the JSON file at PATH.
A top-level array counts its items, and a top-level object counts
its keys.  Return nil for another name, so the next dissector
decides."
  (when (let ((case-fold-search t))
          (string-match-p "\\.json\\'" path))
    (tired--elements-job-create
     :step #'tired--json-step
     :state (tired--json-state-create))))

;;; Markdown

(cl-defstruct (tired--markdown-state (:constructor tired--markdown-state-create))
  "Scanner state for the top-level headings of a Markdown file.
COUNTS holds one bucket per heading level, index 1 to 6.  FIRST is
the level of the first heading, or nil.  LEFTOVER holds the partial
line that the last chunk ended with.  FENCE holds the open code
fence as a cons of its character and its length, or nil.
PREVIOUS holds whether the last line was a paragraph line, which a
setext underline needs."
  counts
  first
  leftover
  fence
  previous)

(defun tired--markdown-fence-open (line)
  "Return the code fence that LINE opens as a cons, or nil.
The car is the fence character and the cdr holds its length."
  (when (string-match "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
    (let ((runs (match-string 1 line)))
      (cons (aref runs 0) (length runs)))))

(defun tired--markdown-fence-closes-p (line fence)
  "Return non-nil when LINE closes the code FENCE.
The fence needs the same character and at least the same length."
  (when (string-match "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\'" line)
    (let ((runs (match-string 1 line)))
      (and (eq (aref runs 0) (car fence))
           (>= (length runs) (cdr fence))))))

(defun tired--markdown-atx-level (line)
  "Return the level of the ATX heading in LINE, or nil."
  (when (string-match "\\` \\{0,3\\}\\(#\\{1,6\\}\\)\\(?:[ \t]\\|\\'\\)" line)
    (length (match-string 1 line))))

(defun tired--markdown-setext-level (line)
  "Return the level of the setext underline in LINE, or nil."
  (when (string-match "\\` \\{0,3\\}\\(=\\{1,\\}\\|-\\{1,\\}\\)[ \t]*\\'" line)
    (if (eq (aref (match-string 1 line) 0) ?=) 1 2)))

(defun tired--markdown-record (state level)
  "Add one heading at LEVEL to STATE and return STATE."
  (unless (tired--markdown-state-first state)
    (setf (tired--markdown-state-first state) level))
  (let ((counts (tired--markdown-state-counts state)))
    (aset counts level (1+ (aref counts level))))
  state)

(defun tired--markdown-line (state line)
  "Record the heading of LINE in STATE and return STATE.
A line inside a fence never counts, and a fence line never counts.
A setext underline counts only under a paragraph line, so a thematic
break after a blank line stays out."
  (let ((fence (tired--markdown-state-fence state)))
    (cond
     (fence
      (when (tired--markdown-fence-closes-p line fence)
        (setf (tired--markdown-state-fence state) nil))
      (setf (tired--markdown-state-previous state) nil))
     ((tired--markdown-fence-open line)
      (setf (tired--markdown-state-fence state)
            (tired--markdown-fence-open line)
            (tired--markdown-state-previous state) nil))
     ((tired--markdown-atx-level line)
      (tired--markdown-record state (tired--markdown-atx-level line))
      (setf (tired--markdown-state-previous state) nil))
     ((and (tired--markdown-state-previous state)
           (tired--markdown-setext-level line))
      (tired--markdown-record state (tired--markdown-setext-level line))
      (setf (tired--markdown-state-previous state) nil))
     ((string-empty-p (string-trim line))
      (setf (tired--markdown-state-previous state) nil))
     ((string-match-p "\\` \\{0,3\\}\\(?:[-*+] \\|[0-9]+[.)] \\|>\\||\\|#\\)"
                       line)
      (setf (tired--markdown-state-previous state) nil))
     (t
      (setf (tired--markdown-state-previous state) t))))
  state)

(defun tired--markdown-scan (state string)
  "Advance STATE over STRING and return STATE.
Keep the last partial line for the next chunk, so a heading that a
chunk boundary cuts in two still counts."
  (let ((text (concat (tired--markdown-state-leftover state) string))
        (start 0))
    (while (string-match "\n" text start)
      ;; `tired--markdown-line' runs its own matches, so the end of
      ;; this line needs its own binding.
      (let ((end (match-end 0))
            (line (substring text start (match-beginning 0))))
        (tired--markdown-line state line)
        (setq start end)))
    (setf (tired--markdown-state-leftover state) (substring text start)))
  state)

(defun tired--markdown-count (state)
  "Return the number of headings that STATE puts at depth zero.
The first heading sets the base, as it does in the section tree, so
a file whose first heading is `##' counts its `##' headings.  A later
shallower heading also prints at depth zero, so it joins the count."
  (when-let* ((first (tired--markdown-state-first state)))
    (let ((total 0)
          (level 1))
      (while (<= level first)
        (setq total (+ total
                       (aref (tired--markdown-state-counts state) level)))
        (setq level (1+ level)))
      total)))

(defun tired--markdown-step (job)
  "Advance JOB over the next chunk of its Markdown file.
Return `:done' when the file ended, after the last partial line."
  (let ((state (tired--elements-job-state job)))
    (if (>= (or (tired--elements-job-offset job) 0)
            (or (tired--elements-job-size job) 0))
        (progn
          (let ((leftover (or (tired--markdown-state-leftover state) "")))
            (unless (string-empty-p leftover)
              (tired--markdown-line state leftover)
              (setf (tired--markdown-state-leftover state) "")))
          (setf (tired--elements-job-count job)
                (tired--markdown-count state))
          :done)
      (when-let* ((chunk (tired--elements-read job)))
        (tired--markdown-scan state chunk))
      :more)))

(defun tired-elements-markdown (path)
  "Return a count or a job for the Markdown file at PATH.
Count the headings that the section tree prints at depth zero, ATX
and setext alike, and keep a fenced code block out.  Return nil for
another name, so the next dissector decides."
  (when (let ((case-fold-search t))
          (string-match-p "\\.\\(?:md\\|markdown\\)\\'" path))
    (tired--elements-job-create
     :step #'tired--markdown-step
     :state (tired--markdown-state-create :counts (make-vector 7 0)))))

;;; CSV

(cl-defstruct (tired--csv-state (:constructor tired--csv-state-create))
  "Scanner state for the rows of a CSV file.
COUNT holds the rows that the scan counted.  START holds whether the
next byte starts a record.  CONTENT holds whether the current record
holds a byte.  COMMENT holds whether the current record starts with
`#'.  IN-STRING and PENDING track a quoted field, where a doubled
quote stands for one quote.  FIELD holds whether the next byte may
open a quoted field."
  (count 0)
  start
  content
  comment
  in-string
  pending
  field)

(defun tired--csv-byte (state char)
  "Advance STATE over one byte CHAR.
Return `:consumed', or `:again' when a closing quote asks the caller
to feed CHAR a second time, now outside the field."
  (cond
   ((tired--csv-state-comment state)
    (when (eq char ?\n)
      (setf (tired--csv-state-comment state) nil
            (tired--csv-state-start state) t
            (tired--csv-state-content state) nil
            (tired--csv-state-in-string state) nil
            (tired--csv-state-pending state) nil
            (tired--csv-state-field state) t))
    :consumed)
   ((tired--csv-state-in-string state)
    (cond
     ((tired--csv-state-pending state)
      (if (eq char ?\")
          (progn (setf (tired--csv-state-pending state) nil) :consumed)
        (setf (tired--csv-state-in-string state) nil
              (tired--csv-state-pending state) nil)
        :again))
     ((eq char ?\")
      (setf (tired--csv-state-pending state) t)
      :consumed)
     (t :consumed)))
   ((eq char ?\n)
    (when (tired--csv-state-content state)
      (setf (tired--csv-state-count state)
            (1+ (tired--csv-state-count state))))
    (setf (tired--csv-state-start state) t
          (tired--csv-state-content state) nil
          (tired--csv-state-field state) t)
    :consumed)
   ((eq char ?\r) :consumed)
   ((tired--csv-state-start state)
    (setf (tired--csv-state-start state) nil)
    (if (eq char ?#)
        (setf (tired--csv-state-comment state) t)
      (setf (tired--csv-state-content state) t
            (tired--csv-state-field state) nil)
      (when (eq char ?\")
        (setf (tired--csv-state-in-string state) t)))
    :consumed)
   ((eq char ?\,)
    (setf (tired--csv-state-field state) t
          (tired--csv-state-content state) t)
    :consumed)
   ((eq char ?\")
    (setf (tired--csv-state-content state) t)
    (when (tired--csv-state-field state)
      (setf (tired--csv-state-in-string state) t
            (tired--csv-state-field state) nil))
    :consumed)
   (t
    (setf (tired--csv-state-content state) t
          (tired--csv-state-field state) nil)
    :consumed)))

(defun tired--csv-scan (state string)
  "Advance STATE over STRING and return STATE.
A quote that closes a field asks for its byte a second time, so the
loop keeps its index and drops it only on `:consumed'."
  (let ((index 0)
        (length (length string)))
    (while (< index length)
      (when (eq (tired--csv-byte state (aref string index)) :consumed)
        (setq index (1+ index))))
    state))

(defun tired--csv-step (job)
  "Advance JOB over the next chunk of its CSV file.
Count a last row that the file ends without a newline.  Return
`:done' when the file ended."
  (let ((state (tired--elements-job-state job)))
    (if (>= (or (tired--elements-job-offset job) 0)
            (or (tired--elements-job-size job) 0))
        (progn
          (when (and (tired--csv-state-content state)
                     (not (tired--csv-state-comment state)))
            (setf (tired--csv-state-count state)
                  (1+ (tired--csv-state-count state))))
          (setf (tired--elements-job-count job)
                (tired--csv-state-count state))
          :done)
      (when-let* ((chunk (tired--elements-read job)))
        (tired--csv-scan state chunk))
      :more)))

(defun tired-elements-csv (path)
  "Return a count or a job for the CSV file at PATH.
Count every record that does not start with `#', the header line
included, and skip a blank line.  A quoted field may hold a comma or
a newline, so a `#' inside one never starts a comment.  Return nil
for another name, so the next dissector decides."
  (when (let ((case-fold-search t))
          (string-match-p "\\.csv\\'" path))
    (tired--elements-job-create
     :step #'tired--csv-step
     :state (tired--csv-state-create :start t :field t))))

;;; Thrift

(define-error 'tired--thrift-eof "Thrift reader reached the end of its data")
(define-error 'tired--thrift-invalid "Invalid Thrift data")

(cl-defstruct (tired--thrift (:constructor tired--thrift-create))
  "Reader over a unibyte STRING for the Thrift compact protocol.
POSITION points at the next byte."
  string
  (position 0))

(defconst tired--thrift-depth-limit 64
  "Nesting depth that `tired--thrift-skip' accepts.
A crafted file must not exhaust the stack.")

(defun tired--thrift-byte (reader)
  "Return the next byte of READER and advance it.
Signal `tired--thrift-eof' when no byte remains."
  (let ((position (tired--thrift-position reader)))
    (when (>= position (length (tired--thrift-string reader)))
      (signal 'tired--thrift-eof nil))
    (setf (tired--thrift-position reader) (1+ position))
    (aref (tired--thrift-string reader) position)))

(defun tired--thrift-varint (reader)
  "Return the unsigned LEB128 integer at READER."
  (let ((result 0)
        (shift 0)
        (done nil))
    (while (not done)
      (let ((byte (tired--thrift-byte reader)))
        (setq result (logior result (ash (logand byte #x7f) shift)))
        (if (zerop (logand byte #x80))
            (setq done t)
          (setq shift (+ shift 7))
          (when (> shift 63)
            (signal 'tired--thrift-invalid nil)))))
    result))

(defun tired--thrift-zigzag (reader)
  "Return the zigzag-encoded integer at READER."
  (let ((value (tired--thrift-varint reader)))
    (logxor (ash value -1) (- (logand value 1)))))

(defun tired--thrift-skip-bytes (reader count)
  "Advance READER over COUNT bytes.
Signal `tired--thrift-eof' when fewer bytes remain and
`tired--thrift-invalid' for a negative COUNT."
  (when (< count 0)
    (signal 'tired--thrift-invalid nil))
  (let ((end (+ (tired--thrift-position reader) count)))
    (when (> end (length (tired--thrift-string reader)))
      (signal 'tired--thrift-eof nil))
    (setf (tired--thrift-position reader) end)))

(defun tired--thrift-skip (reader type depth)
  "Advance READER over one value of compact TYPE.
DEPTH counts the open containers, and a deep nesting signal an
invalid struct."
  (when (> depth tired--thrift-depth-limit)
    (signal 'tired--thrift-invalid nil))
  (pcase type
    ((or 1 2) nil)
    (3 (tired--thrift-skip-bytes reader 1))
    ((or 4 5 6) (tired--thrift-varint reader))
    (7 (tired--thrift-skip-bytes reader 8))
    (8 (tired--thrift-skip-bytes reader (tired--thrift-varint reader)))
    ((or 9 10)
     (let* ((header (tired--thrift-byte reader))
            (size (ash header -4))
            (element (logand header #x0f)))
       (when (= size 15)
         (setq size (tired--thrift-varint reader)))
       (dotimes (_ size)
         (if (memq element '(1 2))
             (tired--thrift-skip-bytes reader 1)
           (tired--thrift-skip reader element (1+ depth))))))
    (11
     (let ((size (tired--thrift-varint reader)))
       (when (> size 0)
         (let* ((types (tired--thrift-byte reader))
                (key (ash types -4))
                (value (logand types #x0f)))
           (dotimes (_ size)
             (tired--thrift-skip reader key (1+ depth))
             (tired--thrift-skip reader value (1+ depth)))))))
    (12 (tired--thrift-skip-struct reader (1+ depth)))
    (_ (signal 'tired--thrift-invalid nil))))

(defun tired--thrift-skip-struct (reader depth)
  "Advance READER over one struct at DEPTH."
  (let ((previous 0)
        (done nil))
    (while (not done)
      (let* ((header (tired--thrift-byte reader))
             (type (logand header #x0f)))
        (if (zerop type)
            (setq done t)
          (let* ((delta (ash header -4))
                 (field (if (zerop delta)
                            (tired--thrift-zigzag reader)
                          (+ previous delta))))
            (setq previous field)
            (tired--thrift-skip reader type depth)))))))

;;; Parquet

(cl-defstruct (tired--parquet-state (:constructor tired--parquet-state-create))
  "Scanner state for the footer of a Parquet file.
PHASE holds `tail' before the last eight bytes read and `footer'
afterwards.  START and LENGTH locate the Thrift footer, and BUFFER
holds the footer bytes that the scan reads so far."
  phase
  start
  (length 0)
  (buffer ""))

(defun tired--parquet-le32 (string)
  "Return the little-endian 32-bit integer in the first four bytes of STRING."
  (+ (aref string 0)
     (ash (aref string 1) 8)
     (ash (aref string 2) 16)
     (ash (aref string 3) 24)))

(defun tired--parquet-count (string)
  "Return the row count of the Thrift FileMetaData in STRING, or nil.
Stop at field 3, so the row groups stay unread.  Signal
`tired--thrift-eof' when STRING ends before the count."
  (let ((reader (tired--thrift-create :string string))
        (previous 0)
        (result nil)
        (done nil))
    (while (not done)
      (let* ((header (tired--thrift-byte reader))
             (type (logand header #x0f)))
        (if (zerop type)
            (setq done t)
          (let* ((delta (ash header -4))
                 (field (if (zerop delta)
                            (tired--thrift-zigzag reader)
                          (+ previous delta))))
            (if (= field 3)
                (setq done t
                      result (and (= type 6) (tired--thrift-zigzag reader)))
              (tired--thrift-skip reader type 1))
            (setq previous field)))))
    result))

(defun tired--parquet-tail (job state)
  "Read the fixed tail of the file of JOB and locate its footer in STATE.
Return `:more' when the footer wait, or `:done'."
  (let* ((size (or (tired--elements-job-size job) 0))
         (tail (and (>= size 12)
                    (tired--elements-read-range
                     (tired--elements-job-path job) (- size 8) size)))
         (length (and tail
                      (= (aref tail 4) ?P) (= (aref tail 5) ?A)
                      (= (aref tail 6) ?R) (= (aref tail 7) ?1)
                      (tired--parquet-le32 tail))))
    (if (or (null length)
            (< length 0)
            (> length (- size 12)))
        (progn
          (setf (tired--elements-job-count job) nil)
          :done)
      (setf (tired--parquet-state-phase state) 'footer
            (tired--parquet-state-start state) (- size 8 length)
            (tired--parquet-state-length state) length
            (tired--parquet-state-buffer state) "")
      :more)))

(defun tired--parquet-footer (job state)
  "Read one piece of the footer of the file of JOB and parse STATE.
Hold the growing footer in the state and parse it again, so a schema
larger than one chunk needs no resumable Thrift reader.  A footer
that `tired-elements-sync-limit' stops keeps no count."
  (let* ((path (tired--elements-job-path job))
         (start (tired--parquet-state-start state))
         (length (tired--parquet-state-length state))
         (buffer (tired--parquet-state-buffer state))
         (have (length buffer)))
    (if (> have tired-elements-sync-limit)
        (progn
          (setf (tired--elements-job-count job) nil)
          :done)
      (let* ((take (min (- length have)
                        (max tired-elements-chunk-size (* 2 have))))
             (buffer (concat buffer
                             (tired--elements-read-range
                              path (+ start have) (+ start have take)))))
        (setf (tired--parquet-state-buffer state) buffer)
        (let ((result (condition-case nil
                          (tired--parquet-count buffer)
                        (tired--thrift-eof 'eof)
                        (tired--thrift-invalid 'invalid))))
          (cond
           ((integerp result)
            (setf (tired--elements-job-count job) result)
            :done)
           ((or (eq result 'invalid)
                (>= (length buffer) length))
            (setf (tired--elements-job-count job) nil)
            :done)
           (t :more)))))))

(defun tired--parquet-step (job)
  "Advance JOB over the footer of its Parquet file.
Return `:done' when the row count arrives or the file holds none."
  (let ((state (tired--elements-job-state job)))
    (if (eq (tired--parquet-state-phase state) 'tail)
        (tired--parquet-tail job state)
      (tired--parquet-footer job state))))

(defun tired-elements-parquet (path)
  "Return a count or a job for the Parquet file at PATH.
The footer at the end of the file holds the row count, so the
dissector reads the tail and the start of the footer and never a
data page.  A codec such as ZSTD touches the pages alone, so it
never reaches the count.  Return nil for another name."
  (when (let ((case-fold-search t))
          (string-match-p "\\.parquet\\'" path))
    (tired--elements-job-create
     :step #'tired--parquet-step
     :state (tired--parquet-state-create :phase 'tail))))

;;; Sections

(defun tired-elements-sections (path)
  "Return the number of top-level sections of PATH, or nil.
Count the sections that print at depth zero, so the first section
sets the base and a later shallower section joins the top level.
Parse a file in one step, so a file above
`tired-elements-sync-limit' returns nil and keeps an empty cell.
Return nil when no handler claims PATH."
  (let* ((attributes (file-attributes path))
         (size (and attributes (file-attribute-size attributes))))
    (when (and (integerp size)
               (<= size tired-elements-sync-limit)
               (tired-file-handler path))
      (let ((sections (tired-file-sections path)))
        (when sections
          (let ((base (tired-section-level (car sections))))
            (seq-count (lambda (section)
                         (<= (tired-section-level section) base))
                       sections)))))))

;;; Directories

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
