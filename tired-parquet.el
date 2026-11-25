;;; tired-parquet.el --- Read the footer of a Parquet file  -*- lexical-binding: t; -*-

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

;; A Parquet file ends with its metadata: an eight byte tail that holds
;; the length of a Thrift-encoded footer and the magic `PAR1', then the
;; footer itself.  The footer carries the schema tree, the row count and
;; the row groups, and it touches no data page, so this library reads the
;; tail and the footer alone.  A listing shows the schema of a 41
;; megabyte file in about a millisecond and never reads a page.
;;
;; The footer speaks the Thrift compact protocol, which describes itself:
;; a field carries its id as a delta from the field before it and its
;; type in the same byte, and an integer carries a width that its value
;; decides.  `bindat' describes a layout that the bytes before it fix, so
;; it cannot read a varint, a stateful field header or a width that the
;; data decides.  The reader here walks the bytes by hand:
;; `tired--thrift-byte' steps one byte, `tired--thrift-skip' steps one
;; value of any type, and a struct reader names the fields that it wants
;; and skips the rest.
;;
;; Design notes for a change in this file:
;;
;; - Every integer of the compact protocol is a varint, and a signed one
;;   is a zigzag varint for `i32' and `i64' alike.  A varint ends on a
;;   byte whose high bit is clear, so no fixed width describes it.
;; - The bool types 1 and 2 sit in the field header and take no value
;;   byte, so a field reader advances the reader for its value alone.
;; - The schema is a preorder list of `SchemaElement', and `num_children'
;;   alone gives the tree, so `tired--parquet-layout' rebuilds the depth
;;   from a stack of the children that remain.  No parent field is read.
;; - `tired--parquet-metadata' stops at field 4 of `FileMetaData'.  Field
;;   6 holds the name of the writer, but it lies behind the row groups,
;;   and walking those costs 700 ms on a file of 2000 row groups where
;;   the stop costs one.  Take the count of row groups from the header of
;;   the list at field 4 and leave its elements alone.
;; - A footer arrives in one string, so the reader needs no resumable
;;   state: `tired-elements' reads the footer in chunks and parses it
;;   again from the start, and `tired--thrift-eof' means "read more".
;; - `tired--parquet-range' reads a byte range, and
;;   `tired--elements-read-range' does the same for the chunk walks of
;;   this package.  The two stay apart because a library that reads the
;;   Parquet format has no business naming the reader of a CSV scan.
;; - The tail magic `PARE' marks an encrypted footer whose metadata this
;;   reader cannot parse, so `tired--parquet-footer-range' refuses it.

;;; Code:

(require 'cl-lib)

(define-error 'tired--thrift-eof "Thrift reader reached the end of its data")
(define-error 'tired--thrift-invalid "Invalid Thrift data")

(defconst tired--thrift-depth-limit 64
  "Nesting depth that `tired--thrift-skip' accepts.
A crafted file must not exhaust the stack.")

(defconst tired-parquet-footer-limit (* 4 1024 1024)
  "Largest footer, in bytes, that `tired-parquet-schema' reads.
A Parquet footer holds the schema and the row group metadata, so a
file of a few thousand columns keeps a footer well below a megabyte.
A larger footer returns nil, which bounds the memory that one
listing row costs.")

(defconst tired--parquet-physical-types
  ["BOOLEAN" "INT32" "INT64" "INT96" "FLOAT" "DOUBLE" "BYTE_ARRAY"
   "FIXED_LEN_BYTE_ARRAY"]
  "Names of the `Type' enum of the Parquet format, by value.")

(defconst tired--parquet-repetition-types
  ["REQUIRED" "OPTIONAL" "REPEATED"]
  "Names of the `FieldRepetitionType' enum of the Parquet format.")

(defconst tired--parquet-converted-types
  ["UTF8" "MAP" "MAP_KEY_VALUE" "LIST" "ENUM" "DECIMAL" "DATE"
   "TIME_MILLIS" "TIME_MICROS" "TIMESTAMP_MILLIS" "TIMESTAMP_MICROS"
   "UINT_8" "UINT_16" "UINT_32" "UINT_64" "INT_8" "INT_16" "INT_32"
   "INT_64" "JSON" "BSON" "INTERVAL"]
  "Names of the `ConvertedType' enum of the Parquet format.
A new file states its intent in a `LogicalType' union instead, and an
old one sets this field.")

(defconst tired--parquet-logical-types
  '((1 . STRING) (2 . MAP) (3 . LIST) (4 . ENUM) (5 . DECIMAL) (6 . DATE)
    (7 . TIME) (8 . TIMESTAMP) (10 . INTEGER) (11 . UNKNOWN) (12 . JSON)
    (13 . BSON) (14 . UUID) (15 . FLOAT16))
  "Names of the members of the `LogicalType' union of the format.
Field 9 stays out of the union: the format reserves it for an
INTERVAL type that it never defined, so `INTEGER' sits at 10 and
every later member one field above its ordinal.")

(cl-defstruct (tired--thrift (:constructor tired--thrift-create))
  "Reader over a unibyte STRING for the Thrift compact protocol.
POSITION points at the next byte."
  string
  (position 0))

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

(defun tired--thrift-binary (reader)
  "Return the binary value at READER as a unibyte string."
  (let* ((length (tired--thrift-varint reader))
         (position (tired--thrift-position reader))
         (string (tired--thrift-string reader)))
    (when (> (+ position length) (length string))
      (signal 'tired--thrift-eof nil))
    (setf (tired--thrift-position reader) (+ position length))
    (substring string position (+ position length))))

(defun tired--thrift-text (reader)
  "Return the binary value at READER decoded as UTF-8."
  (decode-coding-string (tired--thrift-binary reader) 'utf-8))

(defun tired--thrift-skip (reader type depth)
  "Advance READER over one value of compact TYPE.
DEPTH counts the open containers, and a deep nesting signals an
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

(defun tired--thrift-field (reader previous)
  "Return `(FIELD . TYPE)' of the next struct field of READER.
PREVIOUS is the field id before it, which a short header names as a
delta.  A nil FIELD ends the struct.  Signal `tired--thrift-eof'
when the data ends first."
  (let* ((header (tired--thrift-byte reader))
         (type (logand header #x0f))
         (delta (ash header -4)))
    (cons (unless (zerop type)
            (if (zerop delta)
                (tired--thrift-zigzag reader)
              (+ previous delta)))
          type)))

(defun tired--thrift-enum (table value)
  "Return the name of VALUE in TABLE, or VALUE when TABLE lacks it."
  (declare (pure t) (side-effect-free t))
  (if (and (integerp value) (>= value 0) (< value (length table)))
      (aref table value)
    value))

(defun tired--parquet-le32 (string)
  "Return the little-endian 32-bit integer in the first four bytes of STRING."
  (declare (pure t) (side-effect-free t))
  (+ (aref string 0)
     (ash (aref string 1) 8)
     (ash (aref string 2) 16)
     (ash (aref string 3) 24)))

(defun tired--parquet-range (path start end)
  "Return the bytes of PATH from START to END as a unibyte string.
`insert-file-contents-literally' seeks on a local file, so a range
read costs the bytes that the caller asks for and never the whole
file."
  (declare (side-effect-free t))
  (when (< start end)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path nil start end)
      (buffer-string))))

(defun tired--parquet-footer-range (path)
  "Return the `(START . END)' byte range of the footer of PATH.
Read the eight byte tail alone, and return nil when it carries no
`PAR1' magic, when it names a footer that reaches past the data, or
when the file is too small to hold a Parquet tail."
  (declare (side-effect-free t))
  (let* ((size (file-attribute-size (file-attributes path)))
         (tail (and size (>= size 12)
                    (tired--parquet-range path (- size 8) size)))
         (length (and tail
                      (= (aref tail 4) ?P) (= (aref tail 5) ?A)
                      (= (aref tail 6) ?R) (= (aref tail 7) ?1)
                      (tired--parquet-le32 tail))))
    (when (and length
               (> length 0)
               (<= length (- size 12)))
      (cons (- size 8 length) (- size 8)))))

(defun tired--parquet-count (string)
  "Return the row count of the Thrift `FileMetaData' in STRING, or nil.
Stop at field 3, so the schema and the row groups stay unread.
Signal `tired--thrift-eof' when STRING ends before the count."
  (let ((reader (tired--thrift-create :string string))
        (previous 0)
        (result nil)
        (done nil))
    (while (not done)
      (let* ((field (tired--thrift-field reader previous))
             (id (car field))
             (type (cdr field)))
        (if (null id)
            (setq done t)
          (if (= id 3)
              (setq done t
                    result (and (= type 6) (tired--thrift-zigzag reader)))
            (tired--thrift-skip reader type 1))
          (setq previous id))))
    result))

(defun tired--parquet-logical (reader)
  "Return the `LogicalType' union at READER as a symbol.
Read the tag of the union alone and skip its payload, so a name
such as `STRING' or `TIMESTAMP' remains."
  (let ((previous 0)
        (done nil)
        tag)
    (while (not done)
      (let ((field (tired--thrift-field reader previous)))
        (if (null (car field))
            (setq done t)
          (setq previous (car field)
                tag (car field))
          (tired--thrift-skip reader (cdr field) 1))))
    (cdr (assq tag tired--parquet-logical-types))))

(defun tired--parquet-schema-element (reader)
  "Return the `SchemaElement' struct at READER as a plist.
The keys are `:name', `:physical', `:type-length', `:repetition',
`:children', `:converted', `:scale', `:precision', `:field-id' and
`:logical'.  Signal `tired--thrift-eof' when the data ends first."
  (let ((previous 0)
        (done nil)
        name physical type-length repetition children converted scale
        precision field-id logical)
    (while (not done)
      (let* ((field (tired--thrift-field reader previous))
             (id (car field))
             (type (cdr field)))
        (if (null id)
            (setq done t)
          (setq previous id)
          (pcase id
            (1 (setq physical (tired--thrift-zigzag reader)))
            (2 (setq type-length (tired--thrift-zigzag reader)))
            (3 (setq repetition (tired--thrift-zigzag reader)))
            (4 (setq name (tired--thrift-text reader)))
            (5 (setq children (tired--thrift-zigzag reader)))
            (6 (setq converted (tired--thrift-zigzag reader)))
            (7 (setq scale (tired--thrift-zigzag reader)))
            (8 (setq precision (tired--thrift-zigzag reader)))
            (9 (setq field-id (tired--thrift-zigzag reader)))
            (10 (setq logical (tired--parquet-logical reader)))
            (_ (tired--thrift-skip reader type 1))))))
    (list :name name
          :physical (tired--thrift-enum tired--parquet-physical-types
                                        physical)
          :type-length type-length
          :repetition (tired--thrift-enum tired--parquet-repetition-types
                                          repetition)
          :children (or children 0)
          :converted (tired--thrift-enum tired--parquet-converted-types
                                         converted)
          :scale scale
          :precision precision
          :field-id field-id
          :logical logical)))

(defun tired--parquet-schema-list (reader)
  "Return the `list<SchemaElement>' at READER."
  (let* ((header (tired--thrift-byte reader))
         (size (ash header -4))
         (type (logand header #x0f)))
    (when (= size 15)
      (setq size (tired--thrift-varint reader)))
    (unless (= type 12)
      (signal 'tired--thrift-invalid nil))
    (let (elements)
      (dotimes (_ size)
        (push (tired--parquet-schema-element reader) elements))
      (nreverse elements))))

(defun tired--parquet-layout (elements)
  "Return ELEMENTS with a `:depth' that the schema tree decides.
ELEMENTS arrive in preorder, so a stack of the children that remain
gives each one its depth: the root sits at zero and a top-level
field at one."
  (let ((remaining nil)
        (first t)
        result)
    (dolist (element elements)
      (let ((children (plist-get element :children)))
        (unless first
          (while (and remaining (zerop (car remaining)))
            (pop remaining))
          ;; A crafted schema that outlives its tree leaves no level to
          ;; count down, so the row keeps the depth that remains.
          (when remaining
            (setcar remaining (1- (car remaining)))))
        (setq first nil)
        (push (plist-put (copy-sequence element) :depth (length remaining))
              result)
        (when (> children 0)
          (push children remaining))))
    (nreverse result)))

(defun tired--parquet-metadata (string)
  "Return the `FileMetaData' of the Thrift footer in STRING as a plist.
The keys are `:version', `:rows', `:row-groups' and `:schema', a list
of field plists from `tired--parquet-schema-element' that carries
`:depth'.  Signal `tired--thrift-eof' when STRING ends before the
metadata does and `tired--thrift-invalid' for a foreign encoding."
  (let ((reader (tired--thrift-create :string string))
        (previous 0)
        (done nil)
        version rows row-groups schema)
    (while (not done)
      (let* ((field (tired--thrift-field reader previous))
             (id (car field))
             (type (cdr field)))
        (cond
         ((null id) (setq done t))
         (t
          (setq previous id)
          (pcase id
            (1 (setq version (tired--thrift-zigzag reader)))
            (2 (setq schema (tired--parquet-schema-list reader)))
            (3 (setq rows (tired--thrift-zigzag reader)))
            ;; The row groups carry no fact that a listing shows, and
            ;; walking them costs the whole footer, so the header of the
            ;; list gives their count and the rest stays unread.
            (4 (let* ((header (tired--thrift-byte reader))
                      (size (ash header -4)))
                 (setq row-groups (if (= size 15)
                                      (tired--thrift-varint reader)
                                    size))
                 (setq done t)))
            (_ (tired--thrift-skip reader type 1)))))))
    (list :version version
          :rows rows
          :row-groups row-groups
          :schema (and schema (tired--parquet-layout schema)))))

(defun tired-parquet-schema (path)
  "Return the footer metadata of the Parquet file at PATH, or nil.
The value is the plist of `tired--parquet-metadata'.  Read the eight
byte tail and the footer alone, so no data page enters memory.
Return nil when PATH carries no Parquet tail, when its footer does
not parse, when its footer passes `tired-parquet-footer-limit' or
when PATH is gone."
  (declare (side-effect-free t))
  (when-let* ((range (tired--parquet-footer-range path))
              (start (car range))
              (end (cdr range)))
    (when-let* ((small (<= (- end start) tired-parquet-footer-limit))
                (footer (and small
                             (tired--parquet-range path start end))))
      (condition-case nil
          (tired--parquet-metadata footer)
        (tired--thrift-eof nil)
        (tired--thrift-invalid nil)))))

(provide 'tired-parquet)
;;; tired-parquet.el ends here
