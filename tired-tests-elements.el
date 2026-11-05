;;; tired-tests-elements.el --- ERT tests for the Elements column  -*- lexical-binding: t -*-

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

;; Tests for the Elements column: the column itself, the dissectors,
;; the cache, the queue, the sort and the clear command.  The suite
;; flushes the queue by hand, because batch Emacs runs no idle timer.

;;; Code:

(require 'ert)

(require 'cl-lib)

(require 'seq)

(require 'tired-tests-fixtures)

(defun tired-tests--elements-cell (name)
  "Return the Elements cell of the entry called NAME."
  (aref (tired--row (tired-tests--entry name) 0) 2))

;;; The column

(ert-deftest tired-elements-column-sits-between-size-and-modified ()
  "The Elements column follows Size and leads Modified."
  (tired-tests--with-fixture
    (tired root)
    (should (string-prefix-p "Size" (car (aref tabulated-list-format 1))))
    (should (string-prefix-p "Elements" (car (aref tabulated-list-format 2))))
    (should (string-prefix-p "Modified" (car (aref tabulated-list-format 3))))
    (should (string-prefix-p "Mode" (car (aref tabulated-list-format 4))))
    (should (= 10 (nth 1 (aref tabulated-list-format 2))))
    (should (nth 3 (aref tabulated-list-format 2)))
    (should (string-match-p "Elements" (tired-tests--header-string)))))

(ert-deftest tired-elements-column-click-sorts-the-listing ()
  "A click on the Elements header sorts by the column."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--click-header "Elements")
    (should (eq tired--sort-key 'elements))
    (should (eq (tired--sort-state) 'elements-asc))))

(ert-deftest tired-elements-section-row-prints-the-count-of-its-handler ()
  "A section row prints the count that its handler read.
A section without a count keeps the cell empty, because a section is
not a file."
  (tired-tests--with-fixture
    (should (equal ""
                   (tired--elements-cell
                    (tired--section-create :label "x" :path "/x" :line 1))))
    (should (equal "7"
                   (tired--elements-cell
                    (tired--section-create :label "x" :path "/x" :line 1
                                           :count 7))))))

;;; Directories

(ert-deftest tired-elements-directory-counts-immediate-children ()
  "A directory counts its immediate children and never a subtree."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "sub"))))
    (should (= 5 (tired-elements-directory root)))
    (should (equal "3" (tired-tests--elements-cell "sub")))))

(ert-deftest tired-elements-directory-counts-a-dotfile ()
  "Every name on disk counts, dotfiles included."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--flush-elements)
    (let ((tired--hide-dotfiles t))
      (tired-refresh)
      (should (= 5 (tired-elements-directory root))))))

(ert-deftest tired-elements-directory-count-ignores-the-filter ()
  "A filter changes the rows, not the count of a directory."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--flush-elements)
    (let ((before (tired--elements-value (tired-tests--entry "sub"))))
      (tired--apply-filter "inner")
      (should (= before (tired--elements-value (tired-tests--entry "sub")))))))

(ert-deftest tired-elements-directory-returns-nil-for-a-file ()
  "A file row reaches the file dissectors, not the directory count."
  (tired-tests--with-fixture
    (should-not (tired-elements-directory (expand-file-name "alpha.txt" root)))))

;;; JSON

(ert-deftest tired-elements-json-counts-an-array-and-an-object ()
  "A top-level array counts its items and an object counts its keys."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired-tests--write "b.json" "{\"a\":1,\"b\":2}")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.json"))))
    (should (= 2 (tired--elements-value (tired-tests--entry "b.json"))))
    (should (equal "3" (tired-tests--elements-cell "a.json")))))

(ert-deftest tired-elements-json-keeps-an-empty-array-at-zero ()
  "An empty container counts zero, and zero is a count."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[]")
    (tired-tests--write "b.json" "{}")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 0 (tired--elements-value (tired-tests--entry "a.json"))))
    (should (= 0 (tired--elements-value (tired-tests--entry "b.json"))))
    (should (equal "0" (tired-tests--elements-cell "a.json")))))

(ert-deftest tired-elements-json-ignores-another-root ()
  "A scalar or a truncated file keeps an empty cell."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "42")
    (tired-tests--write "b.json" "[1,2")
    (tired-tests--write "c.json" "")
    (tired root)
    (tired-tests--flush-elements)
    (should-not (tired--elements-value (tired-tests--entry "a.json")))
    (should-not (tired--elements-value (tired-tests--entry "b.json")))
    (should-not (tired--elements-value (tired-tests--entry "c.json")))))

(ert-deftest tired-elements-json-counts-a-nested-container ()
  "A string, an escape and a nested container stay one top-level item."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[\"a\\\"b\",2,[3,4],{\"k\":5}]")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 4 (tired--elements-value (tired-tests--entry "a.json"))))))

(ert-deftest tired-elements-json-skips-a-file-above-the-limit ()
  "A file above `tired-elements-sync-limit' keeps an empty cell."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (let ((tired-elements-sync-limit 4))
      (tired root)
      (tired-tests--flush-elements))
    (should-not (tired--elements-value (tired-tests--entry "a.json")))))

;;; Markdown

(ert-deftest tired-elements-markdown-counts-the-top-level ()
  "Markdown counts the headings that the tree prints at depth zero."
  (tired-tests--with-fixture
    (tired-tests--write "a.md" "## A\n# B\n## C\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.md"))))))

(ert-deftest tired-elements-markdown-keeps-a-fenced-block-out ()
  "A heading inside a fence never counts."
  (tired-tests--with-fixture
    (tired-tests--write "a.md" "# A\n\n```\n# hidden\n```\n\n# B\n")
    (tired-tests--write "b.md" "~~~\n# hidden\n~~~\n# real\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 2 (tired--elements-value (tired-tests--entry "a.md"))))
    (should (= 1 (tired--elements-value (tired-tests--entry "b.md"))))))

(ert-deftest tired-elements-markdown-counts-a-setext-heading ()
  "A setext underline counts under a paragraph line alone."
  (tired-tests--with-fixture
    (tired-tests--write "a.md" "Title\n=====\n\nSub\n---\n")
    (tired-tests--write "b.md" "---\n# A\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 1 (tired--elements-value (tired-tests--entry "a.md"))))
    (should (= 1 (tired--elements-value (tired-tests--entry "b.md"))))))

(ert-deftest tired-elements-markdown-survives-a-chunk-boundary ()
  "A heading split across two chunks still counts."
  (tired-tests--with-fixture
    (tired-tests--write "a.md" "text\n# A\ntext\n# B\n")
    (let ((tired-elements-chunk-size 5))
      (tired root)
      (tired-tests--flush-elements))
    (should (= 2 (tired--elements-value (tired-tests--entry "a.md"))))))

(ert-deftest tired-elements-markdown-returns-nil-for-a-plain-file ()
  "A file without a heading has no count."
  (tired-tests--with-fixture
    (tired-tests--write "a.md" "text only\n")
    (tired root)
    (tired-tests--flush-elements)
    (should-not (tired--elements-value (tired-tests--entry "a.md")))))

;;; CSV

(ert-deftest tired-elements-csv-counts-uncommented-rows ()
  "A CSV file counts its rows and leaves a `#' row out.
The header row counts, and a blank line stays out."
  (tired-tests--with-fixture
    (tired-tests--write "a.csv" "name,qty\n# c\napple,2\n\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 2 (tired--elements-value (tired-tests--entry "a.csv"))))
    (should (equal "2" (tired-tests--elements-cell "a.csv")))))

(ert-deftest tired-elements-csv-keeps-a-quoted-newline-in-one-row ()
  "A quoted field holds a comma and a newline, so it never splits."
  (tired-tests--with-fixture
    (tired-tests--write "a.csv" "id,note\n1,\"a\n# not a comment\"\n")
    (tired-tests--write "b.csv" "\"a,b\",c\n")
    (tired-tests--write "c.csv" "\"a\"\"b\",c\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 2 (tired--elements-value (tired-tests--entry "a.csv"))))
    (should (= 1 (tired--elements-value (tired-tests--entry "b.csv"))))
    (should (= 1 (tired--elements-value (tired-tests--entry "c.csv"))))))

(ert-deftest tired-elements-csv-takes-crlf-and-a-last-row ()
  "A carriage return ends no row on its own, and the last row counts."
  (tired-tests--with-fixture
    (tired-tests--write "a.csv" "a,b\r\n1,2\r\n3,4\r\n")
    (tired-tests--write "b.csv" "a,b\n1,2")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.csv"))))
    (should (= 2 (tired--elements-value (tired-tests--entry "b.csv"))))))

(ert-deftest tired-elements-csv-counts-an-empty-file-as-zero ()
  "An empty CSV file holds zero rows, and zero is a count."
  (tired-tests--with-fixture
    (tired-tests--write "a.csv" "")
    (tired-tests--write "b.csv" "# only a comment\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 0 (tired--elements-value (tired-tests--entry "a.csv"))))
    (should (= 0 (tired--elements-value (tired-tests--entry "b.csv"))))
    (should (equal "0" (tired-tests--elements-cell "a.csv")))))

(ert-deftest tired-elements-csv-survives-a-chunk-boundary ()
  "A quoted field and a comment cross a chunk boundary."
  (tired-tests--with-fixture
    (tired-tests--write "a.csv" "name,qty\n# c\n1,\"a\nb\"\n")
    (let ((tired-elements-chunk-size 3))
      (tired root)
      (tired-tests--flush-elements))
    (should (= 2 (tired--elements-value (tired-tests--entry "a.csv"))))))

;;; Parquet

(defun tired-tests--leb128 (value)
  "Return VALUE as a list of unsigned LEB128 bytes."
  (let (bytes)
    (while (> value 127)
      (push (logior 128 (logand value 127)) bytes)
      (setq value (ash value -7)))
    (nreverse (push value bytes))))

(defun tired-tests--parquet-footer (rows)
  "Return a minimal Thrift `FileMetaData' footer with ROWS."
  (apply #'unibyte-string
         (append
          (list #x15) (tired-tests--leb128 2)     ; field 1, version 1
          (list #x19 #x1C)                        ; field 2, schema of 1
          (list #x18 #x01 ?x #x00)                ; SchemaElement {name "x"}
          (list #x16) (tired-tests--leb128 (* 2 rows))
          (list #x00))))

(defun tired-tests--parquet-content (footer &optional tail-magic)
  "Return a Parquet file body with FOOTER and TAIL-MAGIC."
  (let ((length (length footer)))
    (concat "PAR1" footer
            (unibyte-string (logand length #xff)
                            (logand (ash length -8) #xff) 0 0)
            (or tail-magic "PAR1"))))

(defmacro tired-tests--write-bytes (name content)
  "Write CONTENT, a unibyte string, to NAME inside `root'."
  (declare (indent 1) (debug t))
  `(let ((coding-system-for-write 'no-conversion))
     (with-temp-file (expand-file-name ,name root)
       (set-buffer-multibyte nil)
       (insert ,content))))

(ert-deftest tired-elements-parquet-counts-the-rows ()
  "A Parquet file counts the rows of its footer."
  (tired-tests--with-fixture
    (tired-tests--write-bytes "a.parquet"
      (tired-tests--parquet-content (tired-tests--parquet-footer 42)))
    (tired root)
    (tired-tests--flush-elements)
    (should (= 42 (tired--elements-value (tired-tests--entry "a.parquet"))))
    (should (equal "42" (tired-tests--elements-cell "a.parquet")))))

(ert-deftest tired-elements-parquet-keeps-a-foreign-file-out ()
  "A bad tail magic, a short file and an impossible length count nothing."
  (tired-tests--with-fixture
    (tired-tests--write-bytes "a.parquet"
      (tired-tests--parquet-content (tired-tests--parquet-footer 7) "PARE"))
    (tired-tests--write-bytes "b.parquet" "PAR1")
    (tired-tests--write-bytes "c.parquet"
      (concat "PAR1" "x" (unibyte-string 200 0 0 0) "PAR1"))
    (tired root)
    (tired-tests--flush-elements)
    (should-not (tired--elements-value (tired-tests--entry "a.parquet")))
    (should-not (tired--elements-value (tired-tests--entry "b.parquet")))
    (should-not (tired--elements-value (tired-tests--entry "c.parquet")))))

(ert-deftest tired-elements-parquet-survives-a-chunk-boundary ()
  "A footer larger than one chunk parses over several steps."
  (tired-tests--with-fixture
    (tired-tests--write-bytes "a.parquet"
      (tired-tests--parquet-content (tired-tests--parquet-footer 1234)))
    (let ((tired-elements-chunk-size 4))
      (tired root)
      (tired-tests--flush-elements))
    (should (= 1234 (tired--elements-value (tired-tests--entry "a.parquet"))))))

(ert-deftest tired-elements-parquet-skips-every-schema-field ()
  "The skipper walks a schema of every Thrift type."
  (let ((footer (apply #'unibyte-string
                       (append
                        (list #x15 #x02)                  ; version 1
                        (list #x19 #x1C)                  ; schema of 1
                        (list #x18 #x01 ?x)               ; name "x"
                        (list #x15 #x06)                  ; i32 3
                        (list #x16) (tired-tests--leb128 600) ; i64 300
                        (list #x17 0 0 0 0 0 0 0 0)       ; double
                        (list #x19 #x25 #x02 #x04)        ; list<i32> 2
                        (list #x1B #x01 #x58 #x0E #x01 ?y) ; map<i32,binary>
                        (list #x1C #x00)                  ; nested struct
                        (list #x11)                       ; bool true
                        (list #x00)                       ; end SchemaElement
                        (list #x16) (tired-tests--leb128 200000) ; rows 100000
                        (list #x00)))))
    (should (= 100000 (tired--parquet-count footer))))
  (should (eq 'eof (condition-case nil
                       (tired--parquet-count (unibyte-string #x15))
                     (tired--thrift-eof 'eof))))
  (should (eq 'invalid (condition-case nil
                           (tired--parquet-count (unibyte-string #x1F))
                         (tired--thrift-invalid 'invalid)))))

(ert-deftest tired-elements-parquet-returns-nil-without-a-row-count ()
  "A footer that ends before field 3 has no count."
  (should-not (tired--parquet-count (unibyte-string #x15 #x02 #x00))))

;;; The section fallback

(ert-deftest tired-elements-sections-count-the-top-level ()
  "Every other name counts the sections at depth zero."
  (tired-tests--with-fixture
    (tired-tests--write "a.org" "* A\n** B\n* C\n")
    (tired-tests--write "b.el" "(defun a () 1)\n\n(defvar b 2)\n")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 2 (tired--elements-value (tired-tests--entry "a.org"))))
    (should (= 2 (tired--elements-value (tired-tests--entry "b.el"))))))

(ert-deftest tired-elements-sections-stay-out-of-a-large-file ()
  "A file above the sync limit keeps an empty cell."
  (tired-tests--with-fixture
    (tired-tests--write "a.org" "* A\n* B\n")
    (let ((tired-elements-sync-limit 0))
      (tired root)
      (tired-tests--flush-elements))
    (should-not (tired--elements-value (tired-tests--entry "a.org")))))

(ert-deftest tired-elements-sections-return-nil-without-a-handler ()
  "A file that no handler claims has no count."
  (tired-tests--with-fixture
    (should-not (tired-elements-sections (expand-file-name "alpha.txt" root)))))

;;; The cache

(ert-deftest tired-elements-cache-serves-a-second-redraw ()
  "A fresh count queues no job on the next redraw."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (tired-tests--flush-elements)
    (tired-refresh)
    (should-not (tired-tests--queued-jobs 'elements))))

(ert-deftest tired-elements-cache-follows-the-file ()
  "A changed file reaches the column as a new count."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.json"))))
    (tired-tests--write "a.json" "[1,2]")
    (tired-refresh)
    (should (= 1 (length (tired-tests--queued-jobs 'elements))))
    (tired-tests--flush-elements)
    (should (= 2 (tired--elements-value (tired-tests--entry "a.json"))))))

(ert-deftest tired-elements-cache-follows-the-hook-value ()
  "An edited hook drops the counts that it produced."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.json"))))
    (let ((tired-elements-functions
           (cons (lambda (path)
                   (when (string-suffix-p ".json" path) 9))
                 tired-elements-functions)))
      (tired-refresh)
      (tired-tests--flush-elements)
      (should (= 9 (tired--elements-value (tired-tests--entry "a.json")))))))

(ert-deftest tired-elements-clear-cache-drops-every-count ()
  "The command empties the cache and queues the shown rows again."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.json"))))
    (tired-elements-clear-cache)
    (should-not (tired--elements-value (tired-tests--entry "a.json")))
    (should tired--queue-jobs)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "a.json"))))))

(ert-deftest tired-elements-cache-keeps-a-persistent-count ()
  "A count under a rule lands in the permanent table and stays."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (let ((tired-persistent-directories
           (list (concat "\\`" (regexp-quote root)))))
      (tired root)
      (tired-tests--flush-elements)
      (let ((key (tired--elements-key (expand-file-name "a.json" root))))
        (should (gethash key tired--elements-cache-permanent))
        (should-not (gethash key tired--elements-cache))
        ;; Age the entry beyond the window, so the window alone would
        ;; drop it.
        (setcar (nthcdr 2 (gethash key tired--elements-cache-permanent))
                (- (float-time) 3600))
        (tired--elements-prune)
        (should (gethash key tired--elements-cache-permanent))
        (should (= 3 (tired--elements-value
                      (tired-tests--entry "a.json"))))))))

(ert-deftest tired-elements-clear-cache-has-no-listing-binding ()
  "No key and no menu entry runs `tired-elements-clear-cache'."
  (tired-tests--with-fixture
    (tired root)
    (should-not (where-is-internal #'tired-elements-clear-cache
                                  tired-mode-map))
    (should (commandp #'tired-elements-clear-cache))))

(ert-deftest tired-elements-remote-path-keeps-the-cell-empty ()
  "A remote row costs no network round trip."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'file-remote-p)
               (lambda (_name &rest _) "/ssh:host:")))
      (should-not (tired--elements-stamp (tired-tests--entry "sub")))
      (should-not (tired--elements-value (tired-tests--entry "sub")))
      (should-not (tired--elements-value (tired-tests--entry "alpha.txt"))))))

;;; The queue

(ert-deftest tired-elements-budget-stops-a-pass ()
  "A spent budget leaves the job in the queue."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (let ((tired-elements-budget 0)
          (tired-directory-size-budget 0))
      (tired root)
      (should tired--queue-jobs)
      (tired--queue-run)
      (should tired--queue-jobs)
      (dolist (job tired--queue-jobs)
        (setf (tired--job-budget job) nil))
      (tired--queue-run)
      (should-not tired--queue-jobs))))

(ert-deftest tired-elements-queue-gives-way-after-a-step ()
  "Two jobs that need more than one step interleave."
  (tired-tests--with-fixture
    (let* ((calls nil)
           (step (lambda (job)
                   (push (tired--elements-job-path job) calls)
                   (if (eq (tired--elements-job-state job) 'second)
                       (progn
                         (setf (tired--elements-job-count job) 0)
                         :done)
                     (setf (tired--elements-job-state job) 'second)
                     :more)))
           (jobs (mapcar (lambda (path)
                           (tired--job-create
                            :key path
                            :step #'tired--elements-advance
                            :finish #'tired--elements-finish
                            :owners (list (current-buffer))
                            :data (tired--elements-job-create
                                   :path path :step step)))
                         '("/one" "/two"))))
      (mapc #'tired--queue-enqueue (reverse jobs))
      (tired--queue-run)
      (should (equal (nreverse calls) '("/one" "/two" "/one" "/two")))
      (should-not tired--queue-jobs))))

(ert-deftest tired-elements-queue-covers-the-window-alone ()
  "A redraw queues the rows of the window, not the whole listing."
  (tired-tests--with-fixture
    (dotimes (i 20) (tired-tests--write (format "f%02d.txt" i) "x"))
    (let ((buffer (tired root))
          (tired-elements-lookahead 0))
      (with-current-buffer buffer
        (setq tired--queue-jobs nil)
        (clrhash tired--queue-index)
        (goto-char (point-min))
        (forward-line 3)
        (let ((end (point)))
          (cl-letf (((symbol-function 'window-end) (lambda (&rest _) end))
                    ((symbol-function 'window-start)
                     (lambda (&rest _) (point-min))))
            (tired--elements-queue)))
        (should (= 3 (length (tired-tests--queued-jobs 'elements))))
        (should (< 3 (length (tired--visible-rows))))))))

(ert-deftest tired-elements-directory-uses-the-size-walk-count ()
  "The size walk answers the child count, so no directory read follows."
  (tired-tests--with-fixture
    (let ((tired-directory-size t))
      (tired root)
      (tired-tests--flush-sizes))
    (should (= 3 (tired--child-count (expand-file-name "sub" root))))
    (let ((reads 0)
          (original (symbol-function 'directory-files)))
      (cl-letf (((symbol-function 'directory-files)
                 (lambda (&rest args)
                   (setq reads (1+ reads))
                   (apply original args))))
        (should (= 3 (tired-elements-directory
                      (expand-file-name "sub" root)))))
      (should (= 0 reads)))))

(ert-deftest tired-elements-scroll-queues-a-revealed-row ()
  "A scroll queues the counts of the rows that it reveals."
  (tired-tests--with-fixture
    (dotimes (i 5) (tired-tests--write (format "f%d.txt" i) "x"))
    (let ((buffer (tired root)))
      (with-current-buffer buffer
        (tired-tests--flush-elements)
        (should-not (tired-tests--queued-jobs 'elements))
        (clrhash tired--elements-cache)
        (tired--elements-queue-shown)
        (should (tired-tests--queued-jobs 'elements))))))

(ert-deftest tired-elements-queue-holds-one-job-per-path ()
  "A second queue pass adds no second job for the same path."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (let ((count (length (tired-tests--queued-jobs 'elements))))
      (tired-refresh)
      (should (= count (length (tired-tests--queued-jobs 'elements)))))
    (tired-tests--flush-elements)
    (tired-refresh)
    (should-not (tired-tests--queued-jobs 'elements))))

(ert-deftest tired-elements-dissector-error-finishes-the-job ()
  "A dissector that signals leaves no count and stops no queue."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (let ((tired-elements-functions
           (list (lambda (_path) (error "boom"))
                 #'tired-elements-json)))
      (tired root)
      (tired-tests--flush-elements))
    (should-not (tired--elements-value (tired-tests--entry "a.json")))
    (should-not tired--queue-jobs)))

(ert-deftest tired-elements-reprint-repaints-a-shown-buffer ()
  "One finished count repaints its buffer once."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (let ((count 0))
      (cl-letf (((symbol-function 'tired--redraw)
                 (lambda (&rest _) (setq count (1+ count)))))
        (tired--queue-run)
        (should (= 0 count))
        (tired--queue-reprint)
        (should (= 1 count))
        (tired--queue-reprint)
        (should (= 1 count))))))

(ert-deftest tired-elements-directory-counts-an-inserted-directory ()
  "A shown directory counts from its entry table and reads nothing.
The insert reads the children of the directory into the table, so the
count of that directory needs no second `directory-files' call."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--flush-elements)
    (should (= 3 (tired--elements-value (tired-tests--entry "sub"))))
    (cl-letf (((symbol-function 'tired--directory-names)
               (lambda (&rest _) (error "Unexpected directory read"))))
      (should (= 3 (tired-elements-directory
                    (expand-file-name "sub" root)))))))

(ert-deftest tired-elements-schedule-keeps-one-idle-timer ()
  "A pass that already waits takes no second timer."
  (let ((timers 0)
        (tired--queue-timer nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (&rest _)
                 (setq timers (1+ timers))
                 (run-at-time 60 nil #'ignore))))
      (unwind-protect
          (progn
            (tired--queue-schedule)
            (tired--queue-schedule)
            (should (= 1 timers)))
        (when (timerp tired--queue-timer)
          (cancel-timer tired--queue-timer))))))

(ert-deftest tired-elements-run-schedules-the-next-idle-pass ()
  "A pass that leaves a job arranges its successor."
  (let ((scheduled 0)
        (tired--queue-jobs
         (list (tired--job-create
                :key "/one"
                :step (lambda (_job) :more)
                :budget 0)))
        (tired--queue-index (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'tired--queue-schedule)
               (lambda () (setq scheduled (1+ scheduled)))))
      (tired--queue-run)
      (should (= 1 scheduled))
      (should tired--queue-jobs))))

;;; The sort

(ert-deftest tired-elements-sort-puts-an-unknown-count-last ()
  "A row without a count lists after a row with one, both ways."
  (tired-tests--with-fixture
    (tired-tests--write "a.json" "[1,2,3]")
    (tired root)
    (tired-tests--flush-elements)
    (tired--sort-by-column 'elements)
    (let ((names (tired-tests--names)))
      (should (< (seq-position names "a.json")
                 (seq-position names "alpha.txt"))))
    (tired--sort-by-column 'elements 'reverse)
    (let ((names (tired-tests--names)))
      (should (< (seq-position names "a.json")
                 (seq-position names "alpha.txt"))))))

(provide 'tired-tests-elements)

;;; tired-tests-elements.el ends here
