;;; tired-export.el --- Export commands for Tired  -*- lexical-binding: t -*-

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

;; Three commands write the current view to a read-only buffer:
;; `tired-export-csv' writes the four disk columns,
;; `tired-export-text' writes the view with a relative path on every
;; line, and `tired-export-json' writes the array that `rclone lsjson'
;; prints.  Each command reads the transient selection first, then the
;; active region, then every visible entry.  Section rows stay out,
;; because a section is not a file.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'tired-core)

(declare-function mailcap-extension-to-mime "mailcap" (extension))

(defconst tired-export-mime-fallback "application/octet-stream"
  "MIME type for a file that mailcap does not know.")

(defconst tired-export-directory-mime "inode/directory"
  "MIME type that the rclone local backend gives a directory.")

(defun tired--export-relative-path (entry)
  "Return the path of ENTRY relative to the shown directory."
  (file-relative-name (tired-entry-path entry) tired--directory))

(defun tired--export-byte-count (entry)
  "Return the size field of ENTRY in bytes.
A directory reports 0, because a recursive total costs one walk per
directory.  A symbolic link reports its own byte count."
  (if (tired-entry-dirp entry) 0 (or (tired-entry-size entry) 0)))

(defun tired--export-rfc3339 (time &optional nanoseconds)
  "Return TIME as an RFC 3339 stamp.
A non-nil NANOSECONDS adds the nanosecond fraction and a UTC
suffix, the way `rclone lsjson' prints a modification time.  A nil
TIME reports the epoch."
  (if nanoseconds
      (format-time-string "%Y-%m-%dT%H:%M:%S.%NZ" (or time 0) t)
    (format-time-string "%Y-%m-%dT%H:%M:%S%:z" (or time 0))))

(defun tired--export-text (entries)
  "Return ENTRIES as aligned text with a relative path on every line.
The path is relative to the shown directory.  The other three disk
columns follow the path in the order of the listing.  The path
column grows to the longest path, so no path wraps and a later grep
finds the whole path on one line."
  (let* ((rows (mapcar (lambda (entry)
                         (list (tired--export-relative-path entry)
                               (tired--size-cell entry)
                               (format-time-string
                                tired-date-format
                                (or (tired-entry-mtime entry) 0))
                               (or (tired-entry-mode entry) "")))
                       entries))
         (width (max tired-name-column-min-width
                     (apply #'max 0
                            (mapcar (lambda (row) (string-width (car row)))
                                    rows)))))
    (mapconcat (lambda (row)
                 (string-trim-right
                  (concat (string-pad (nth 0 row) width)
                          " "
                          (string-pad (nth 1 row) 9 ?\s t)
                          " "
                          (string-pad (nth 2 row) 16)
                          " "
                          (nth 3 row))))
               rows
               "\n")))

(defun tired--export-csv-field (value)
  "Return VALUE as one CSV field.
Quote the field when it holds a comma, a double quote or a line
break, and double every inner quote, as RFC 4180 asks."
  (if (string-match-p "[,\"\n\r]" value)
      (concat "\"" (string-replace "\"" "\"\"" value) "\"")
    value))

(defun tired--export-csv (entries)
  "Return ENTRIES as CSV text with a header row.
The header names the four disk columns of the listing.  The Elements
count stays out, because it is a derived number.  A path is relative
to the shown directory, and a directory reports size 0."
  (mapconcat
   #'identity
   (cons "Name,Size,Modified,Mode"
         (mapcar (lambda (entry)
                   (mapconcat
                    #'tired--export-csv-field
                    (list (tired--export-relative-path entry)
                          (number-to-string (tired--export-byte-count entry))
                          (tired--export-rfc3339
                           (tired-entry-mtime entry))
                          (or (tired-entry-mode entry) ""))
                    ","))
                 entries))
   "\n"))

(defun tired--export-mime-type (entry path)
  "Return the MIME type of ENTRY, whose relative path is PATH.
A directory reports `inode/directory', as the rclone local backend
does.  A file reports the type that mailcap knows, or
`tired-export-mime-fallback'."
  (if (tired--directory-entry-p entry)
      tired-export-directory-mime
    (let ((extension (file-name-extension path)))
      (or (and extension
               (require 'mailcap nil t)
               (mailcap-extension-to-mime extension))
          tired-export-mime-fallback))))

(defun tired--export-json-object (entry)
  "Return the `rclone lsjson' object for ENTRY.
The keys follow the rclone order: Path, Name, Size, MimeType,
ModTime and IsDir.  A directory reports size -1, as rclone does.
Path is relative to the shown directory, and ModTime is an RFC 3339
stamp in UTC."
  (let* ((path (tired--export-relative-path entry))
         (directory (tired--directory-entry-p entry))
         (mtime (tired-entry-mtime entry)))
    (list (cons "Path" path)
          (cons "Name" (file-name-nondirectory path))
          (cons "Size" (if directory -1 (or (tired-entry-size entry) 0)))
          (cons "MimeType" (tired--export-mime-type entry path))
          (cons "ModTime" (tired--export-rfc3339 mtime t))
          (cons "IsDir" (if directory t :json-false)))))

(defun tired--export-json (entries)
  "Return ENTRIES as the JSON array that `rclone lsjson' prints.
Keep one object per line, so a later grep finds a whole object on
one line.  The result carries no trailing newline, because the
export buffer adds one."
  (if (null entries)
      "[]"
    (concat "[\n"
            (mapconcat (lambda (entry)
                         (json-encode (tired--export-json-object entry)))
                       entries ",\n")
            "\n]")))

(defun tired--export-mode (format)
  "Return the major mode symbol that FORMAT wants.
CSV and JSON take their own modes when the libraries are present,
so the buffer reads as data.  A missing library falls back to
`text-mode'."
  (pcase format
    ('csv (if (require 'csv-mode nil t) 'csv-mode 'text-mode))
    ('json (if (require 'js nil t) 'js-json-mode 'text-mode))
    (_ 'text-mode)))

(defun tired--export-buffer (format count selected)
  "Return the buffer for a FORMAT export of COUNT entries.
A SELECTED export names the entry count and always gets a fresh
buffer, because a different selection holds different entries.  A
whole-view export reuses one buffer per format and directory, so a
second call replaces the old text instead of piling up buffers."
  (let ((name (format "*Tired Export %s: %s"
                      (symbol-name format)
                      (directory-file-name
                       (abbreviate-file-name tired--directory)))))
    (if selected
        (generate-new-buffer (format "%s (%d selected)*" name count))
      (get-buffer-create (format "%s*" name)))))

(defun tired--export-fill (buffer text format directory)
  "Replace the contents of BUFFER with TEXT for FORMAT.
DIRECTORY becomes the default directory.  The buffer takes the mode
that FORMAT names.  It stays unmodified, so a later save needs an
explicit file name."
  (with-current-buffer buffer
    (setq default-directory directory)
    (funcall (tired--export-mode format))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      (unless (bolp)
        (insert "\n")))
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)))

(defun tired--export (format)
  "Export the current view in FORMAT to a read-only buffer.
FORMAT is `csv', `text' or `json'.  The transient selection comes
first, then the active region, then every visible entry.  Return
the export buffer."
  (let* ((partial (or (tired--selected-entries)
                      (tired--region-entries)))
         (entries (or partial (tired--visible-entries)))
         (text (pcase format
                 ('csv (tired--export-csv entries))
                 ('text (tired--export-text entries))
                 ('json (tired--export-json entries))
                 (_ (error "Unknown export format: %S" format))))
         (buffer (tired--export-buffer format (length entries) partial)))
    (tired--export-fill buffer text format tired--directory)
    (pop-to-buffer buffer)
    (goto-char (point-min))
    (message "Exported %d %s to %s"
             (length entries)
             (if (= (length entries) 1) "entry" "entries")
             (buffer-name buffer))
    buffer))

(defun tired-export-csv ()
  "Export the targets or the whole view as CSV.
Write a read-only buffer with one row per entry and the four disk
columns.  The Elements count stays out, because it is derived.  A
path is relative to the shown directory."
  (interactive)
  (tired--export 'csv))

(defun tired-export-text ()
  "Export the targets or the whole view as aligned plain text.
The text mirrors the four disk columns of the listing, but every
line starts with the path of its entry relative to the shown
directory instead of an indented name."
  (interactive)
  (tired--export 'text))

(defun tired-export-json ()
  "Export the targets or the whole view in the `rclone lsjson' shape.
Write a read-only buffer that holds one JSON object per line.  A
path is relative to the shown directory."
  (interactive)
  (tired--export 'json))

(provide 'tired-export)

;;; tired-export.el ends here
