;;; tired-parquet-test.el --- Tests for tired-parquet  -*- lexical-binding: t -*-

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

;; The footer of a Parquet file is Thrift, so a fixture is a list of
;; bytes that the helper builds.  Write a fixture, read it back and
;; compare the plist against what the writer put in it.

;;; Code:

(require 'ert)
(require 'tired-parquet)

(require 'tired-test-helper)

(ert-deftest tired-parquet-schema-reads-the-footer ()
  "A footer gives its version, its row count and its schema."
  (tired-test--with-fixture
    (tired-test--parquet-write
     "a.parquet"
     (list (tired-test--parquet-element "root" :children 2)
           (tired-test--parquet-element "id" :type 2 :repetition 0)
           (tired-test--parquet-element "name" :type 6 :repetition 1
                                        :converted 0 :logical 1))
     :rows 99 :row-groups 3 :version 2)
    (let* ((metadata (tired-parquet-schema
                      (expand-file-name "a.parquet" root)))
           (schema (plist-get metadata :schema)))
      (should (= 2 (plist-get metadata :version)))
      (should (= 99 (plist-get metadata :rows)))
      (should (= 3 (plist-get metadata :row-groups)))
      (should (equal '("root" "id" "name")
                     (mapcar (lambda (field) (plist-get field :name)) schema)))
      (should (equal '(0 1 1)
                     (mapcar (lambda (field) (plist-get field :depth)) schema)))
      (should (equal "INT64" (plist-get (nth 1 schema) :physical)))
      (should (equal "REQUIRED" (plist-get (nth 1 schema) :repetition)))
      (should (equal "OPTIONAL" (plist-get (nth 2 schema) :repetition)))
      (should (equal "UTF8" (plist-get (nth 2 schema) :converted)))
      (should (eq 'STRING (plist-get (nth 2 schema) :logical))))))

(ert-deftest tired-parquet-schema-hangs-a-child-under-its-parent ()
  "A struct field keeps every field below it one level deeper."
  (tired-test--with-fixture
    (tired-test--parquet-write
     "a.parquet"
     (list (tired-test--parquet-element "root" :children 2)
           (tired-test--parquet-element "id" :type 2)
           (tired-test--parquet-element "nested" :children 1)
           (tired-test--parquet-element "x" :type 1)))
    (should (equal '(0 1 1 2)
                   (mapcar (lambda (field) (plist-get field :depth))
                           (plist-get (tired-parquet-schema
                                       (expand-file-name "a.parquet" root))
                                      :schema))))))

(ert-deftest tired-parquet-schema-keeps-a-broken-tree-in-hand ()
  "A schema that outlives its root keeps no negative depth."
  (tired-test--with-fixture
    (tired-test--parquet-write
     "a.parquet"
     (list (tired-test--parquet-element "root" :children 1)
           (tired-test--parquet-element "a" :type 2)
           (tired-test--parquet-element "b" :type 2)))
    (should (equal '(0 1 0)
                   (mapcar (lambda (field) (plist-get field :depth))
                           (plist-get (tired-parquet-schema
                                       (expand-file-name "a.parquet" root))
                                      :schema))))))

(ert-deftest tired-parquet-schema-leaves-the-row-groups-alone ()
  "The count of row groups comes from the list header alone.
A footer that stops at that header parses, so the reader never walks
the row groups behind it."
  (tired-test--with-fixture
    (tired-test--write-bytes
      "a.parquet"
      (tired-test--parquet-content
       (apply #'unibyte-string
              (append
               (tired-test--thrift-int 0 1 1)
               (tired-test--thrift-header 1 2 9)
               (tired-test--thrift-list-header 1 12)
               (tired-test--parquet-element "x")
               (tired-test--thrift-int 2 3 7)
               (tired-test--thrift-header 3 4 9)
               (tired-test--thrift-list-header 500 12)))))
    (let ((metadata (tired-parquet-schema
                     (expand-file-name "a.parquet" root))))
      (should (= 7 (plist-get metadata :rows)))
      (should (= 500 (plist-get metadata :row-groups))))))

(ert-deftest tired-parquet-schema-refuses-a-foreign-file ()
  "A bad tail, a short file and an impossible length give no schema."
  (tired-test--with-fixture
    (tired-test--write-bytes "a.parquet"
      (tired-test--parquet-content (tired-test--parquet-footer 1) "PARE"))
    (tired-test--write-bytes "b.parquet" "PAR1")
    (tired-test--write-bytes "c.parquet"
      (concat "PAR1" "x" (unibyte-string 200 0 0 0) "PAR1"))
    (dolist (name '("a.parquet" "b.parquet" "c.parquet"))
      (should-not (tired-parquet-schema (expand-file-name name root))))))

(ert-deftest tired-parquet-schema-survives-a-truncated-footer ()
  "A footer that the tail promises but the file lacks gives no schema."
  (tired-test--with-fixture
    (let ((footer (tired-test--parquet-footer 5)))
      (tired-test--write-bytes "a.parquet"
        (concat "PAR1" (substring footer 0 8)
                (unibyte-string (length footer) 0 0 0) "PAR1")))
    (should-not (tired-parquet-schema (expand-file-name "a.parquet" root)))))

(ert-deftest tired-parquet-schema-refuses-a-footer-past-the-limit ()
  "A footer above the limit costs no read."
  (tired-test--with-fixture
    (tired-test--parquet-write "a.parquet"
                               (list (tired-test--parquet-element "x")))
    (let ((tired-parquet-footer-limit 0))
      (should-not (tired-parquet-schema
                   (expand-file-name "a.parquet" root))))))

(ert-deftest tired-parquet-logical-type-skips-the-reserved-field ()
  "The logical type takes its name from a union that skips field 9."
  (tired-test--with-fixture
    (tired-test--parquet-write
     "a.parquet"
     (list (tired-test--parquet-element "root" :children 2)
           (tired-test--parquet-element "i" :type 1 :logical 10)
           (tired-test--parquet-element "u" :type 6 :logical 14)))
    (let ((schema (plist-get (tired-parquet-schema
                              (expand-file-name "a.parquet" root))
                             :schema)))
      (should (eq 'INTEGER (plist-get (nth 1 schema) :logical)))
      (should (eq 'UUID (plist-get (nth 2 schema) :logical))))))

(ert-deftest tired-parquet-schema-reads-no-file ()
  "A path that carries no file gives no schema."
  (tired-test--with-fixture
    (should-not (tired-parquet-schema
                 (expand-file-name "nope.parquet" root)))
    (should-not (tired-parquet-schema (expand-file-name "alpha.txt" root)))))

(provide 'tired-parquet-test)

;;; tired-parquet-test.el ends here
