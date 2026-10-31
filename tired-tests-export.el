;;; tired-tests-export.el --- ERT tests for the Tired export commands  -*- lexical-binding: t -*-

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

;; Tests for the CSV, text and JSON exports: the buffer state, the
;; target source, the path form and the rclone shape.

;;; Code:

(require 'ert)

(require 'json)

(require 'seq)

(require 'tired-tests-fixtures)

(ert-deftest tired-export-csv-writes-a-header-and-rows ()
  "The CSV export carries a header and one row per visible entry."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root))
          count)
      (with-current-buffer tired
        (setq count (length (tired--visible-entries))))
      (let ((buffer (with-current-buffer tired (tired-export-csv))))
        (with-current-buffer buffer
          (should buffer-read-only)
          (should-not (buffer-modified-p))
          (should (equal default-directory root))
          (let ((lines (split-string (buffer-string) "\n" t)))
            (should (equal (car lines) "Name,Size,Modified,Mode"))
            (should (= (length lines) (1+ count)))
            (should (seq-some (lambda (line)
                                (string-prefix-p "alpha.txt,3," line))
                              lines))
            (should (seq-some (lambda (line)
                                (string-prefix-p "sub,0," line))
                              lines))))))))

(ert-deftest tired-export-csv-quotes-a-field ()
  "A CSV field takes quotes around a comma and a doubled inner quote."
  (should (equal (tired--export-csv-field "plain") "plain"))
  (should (equal (tired--export-csv-field "a,b") "\"a,b\""))
  (should (equal (tired--export-csv-field "a\"b") "\"a\"\"b\"")))

(ert-deftest tired-export-text-prints-full-paths ()
  "The text export replaces indentation with the full path."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root))
          count)
      (with-current-buffer tired
        (tired-tests--goto "sub")
        (tired-insert-subdir)
        (setq count (length (tired--visible-entries))))
      (let ((buffer (with-current-buffer tired (tired-export-text))))
        (with-current-buffer buffer
          (let ((lines (split-string (buffer-string) "\n" t)))
            (should (= (length lines) count))
            (should (seq-every-p (lambda (line) (string-prefix-p root line))
                                 lines))
            (should (seq-some
                     (lambda (line)
                       (string-prefix-p (expand-file-name "sub/inner.txt" root)
                                        line))
                     lines))))))))

(ert-deftest tired-export-json-matches-the-rclone-shape ()
  "The JSON export holds the six rclone lsjson keys per object."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root))
          objects)
      (let ((buffer (with-current-buffer tired (tired-export-json))))
        (with-current-buffer buffer
          (goto-char (point-min))
          (setq objects (json-parse-buffer :object-type 'alist
                                           :array-type 'list
                                           :false-object :json-false))))
      (let ((alpha (seq-find
                    (lambda (object)
                      (equal (alist-get 'Path object) "alpha.txt"))
                    objects))
            (sub (seq-find
                  (lambda (object)
                    (equal (alist-get 'Path object) "sub"))
                  objects)))
        (should alpha)
        (should (= (length alpha) 6))
        (should (equal (alist-get 'Name alpha) "alpha.txt"))
        (should (= (alist-get 'Size alpha) 3))
        (should (eq (alist-get 'IsDir alpha) :json-false))
        (should (stringp (alist-get 'MimeType alpha)))
        (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T"
                                (alist-get 'ModTime alpha)))
        (should sub)
        (should (= (length sub) 6))
        (should (eq (alist-get 'IsDir sub) t))
        (should (= (alist-get 'Size sub) -1))
        (should (equal (alist-get 'MimeType sub)
                       "inode/directory"))))))

(ert-deftest tired-export-follows-the-selection ()
  "A selection limits the export to the selected entries."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root)))
      (with-current-buffer tired
        (tired-tests--goto "alpha.txt")
        (tired-select-toggle)
        (tired-tests--goto "beta.txt")
        (tired-select-toggle))
      (let ((buffer (with-current-buffer tired (tired-export-csv))))
        (with-current-buffer buffer
          (let ((lines (split-string (buffer-string) "\n" t)))
            (should (= (length lines) 3))
            (should (equal (mapcar (lambda (line)
                                     (car (split-string line ",")))
                                   (cdr lines))
                           '("alpha.txt" "beta.txt")))))))))

(ert-deftest tired-export-follows-the-region ()
  "An active region limits the export without a selection."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (let ((buffer (tired-export-csv)))
      (with-current-buffer buffer
        (let ((lines (split-string (buffer-string) "\n" t)))
          (should (= (length lines) 3))
          (should (equal (mapcar (lambda (line)
                                   (car (split-string line ",")))
                                 (cdr lines))
                         '("alpha.txt" "beta.txt"))))))))

(ert-deftest tired-export-skips-section-rows ()
  "A section row never reaches an export."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* One\n** Two\n")
    (let ((tired (tired-noselect root))
          count)
      (with-current-buffer tired
        (tired-tests--goto "notes.org")
        (tired-expand-file)
        (setq count (length (tired--visible-entries)))
        (should (tired-tests--sections)))
      (let ((buffer (with-current-buffer tired (tired-export-csv))))
        (with-current-buffer buffer
          (let ((lines (split-string (buffer-string) "\n" t)))
            (should (= (length lines) (1+ count)))
            (should-not (seq-some (lambda (line)
                                    (string-match-p "One" line))
                                  lines))))))))

(ert-deftest tired-export-whole-view-reuses-a-buffer-per-format ()
  "A second whole-view export replaces the contents of one buffer."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root))
          first
          second)
      (setq first (with-current-buffer tired (tired-export-csv)))
      (setq second (with-current-buffer tired (tired-export-csv)))
      (should (eq first second))
      (should (string-prefix-p "*Tired Export csv: " (buffer-name first))))))

(ert-deftest tired-export-selection-gets-a-fresh-buffer ()
  "A partial export never reuses a whole-view buffer."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root))
          whole
          partial)
      (setq whole (with-current-buffer tired (tired-export-csv)))
      (with-current-buffer tired
        (tired-tests--goto "alpha.txt")
        (tired-select-toggle))
      (setq partial (with-current-buffer tired (tired-export-csv)))
      (should-not (eq whole partial))
      (should (string-match-p "(1 selected)" (buffer-name partial))))))

(ert-deftest tired-export-commands-remap-their-major-modes ()
  "A key that runs a major mode reaches the matching export."
  (tired-tests--with-fixture
    (tired root)
    (should (eq (command-remapping 'csv-mode) #'tired-export-csv))
    (should (eq (command-remapping 'text-mode) #'tired-export-text))
    (should (eq (command-remapping 'js-json-mode) #'tired-export-json))))

(ert-deftest tired-export-relative-path-reaches-an-inserted-entry ()
  "The CSV path of an inserted entry keeps its subdirectory."
  (tired-tests--with-fixture
    (let ((tired (tired-noselect root)))
      (with-current-buffer tired
        (tired-tests--goto "sub")
        (tired-insert-subdir)
        (tired-tests--goto "inner.txt")
        (tired-select-toggle))
      (let ((buffer (with-current-buffer tired (tired-export-csv))))
        (with-current-buffer buffer
          (let ((lines (split-string (buffer-string) "\n" t)))
            (should (equal (mapcar (lambda (line)
                                     (car (split-string line ",")))
                                   (cdr lines))
                           '("sub/inner.txt")))))))))

(provide 'tired-tests-export)

;;; tired-tests-export.el ends here
