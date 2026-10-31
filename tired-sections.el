;;; tired-sections.el --- Section handlers for Tired  -*- lexical-binding: t -*-

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

;; The section handlers that turn one file into `tired-section'
;; structs: Org, Emacs Lisp, Rust, Markdown, Cargo and SQLite.  The
;; framework that calls a handler stays in `tired-core', so a new
;; handler costs one rule in `tired-file-handlers'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tired-core)

(declare-function org-element-map "org-element"
                  (data types fun &optional info first-match no-recursion
                        with-affiliated no-footnotes))
(declare-function org-element-parse-buffer "org-element"
                  (&optional granularity visible-only))
(declare-function org-element-property "org-element" (property element))
(declare-function org-narrow-to-subtree "org" (&optional arg))
(declare-function treesit-available-p "treesit" nil)
(declare-function treesit-buffer-root-node "treesit" (&optional language))
(declare-function treesit-node-child-by-field-name "treesit"
                  (node field-name))
(declare-function treesit-node-child "treesit" (node n &optional named))
(declare-function treesit-node-children "treesit" (node &optional named))
(declare-function treesit-node-start "treesit" (node))
(declare-function treesit-node-parent "treesit" (node))
(declare-function treesit-node-text "treesit" (node &optional no-propertize))
(declare-function treesit-node-type "treesit" (node))
(declare-function treesit-ready-p "treesit" (language &optional quiet))
(declare-function sqlite-available-p "sqlite.c" nil)
(declare-function sqlite-close "sqlite.c" (db))
(declare-function sqlite-open "sqlite.c" (file &optional readonly disable-uri))
(declare-function sqlite-select "sqlite.c"
                  (db query &optional values return-type))

(defun tired--org-open-heading (section &optional other-window)
  "Visit the org heading of SECTION and narrow to its subtree.
Show the buffer in another window when OTHER-WINDOW is non-nil.
Narrow only when `tired-org-narrow-on-open' is non-nil, the visited
buffer uses Org mode and point sits on a heading.  A narrow that
fails leaves the buffer wide."
  (let ((buffer (tired--visit-section section other-window)))
    (when (and tired-org-narrow-on-open
               (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (derived-mode-p 'org-mode)
          (require 'org)
          (ignore-errors (org-narrow-to-subtree)))))))

(defun tired-file-sections-org (_path)
  "Return the headings of the current org buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Parse with `org-element', so a heading inside a source block or an
example block stays out of the listing.  The line of a heading is
the line of its stars.  Every section carries
`tired--org-open-heading' as its action."
  (require 'org)
  (require 'org-element)
  (delay-mode-hooks (org-mode))
  (org-element-map (org-element-parse-buffer 'headline) 'headline
    (lambda (headline)
      (list :label (or (org-element-property :raw-value headline) "")
            :line (line-number-at-pos (org-element-property :begin headline))
            :level (org-element-property :level headline)
            :kind 'heading
            :action #'tired--org-open-heading))))

(defconst tired--elisp-read-error (make-symbol "tired--read-error")
  "Sentinel that marks a form which `read' rejected.")

(defun tired--elisp-label (form)
  "Return a short label for the top-level FORM, or nil.
The label holds the head symbol plus its first argument when that
argument is a symbol or a quoted symbol."
  (when (consp form)
    (let ((head (car form))
          (argument (cadr form)))
      (cond
       ((not (symbolp head)) nil)
       ((null argument) (symbol-name head))
       ((symbolp argument) (format "%s %s" head argument))
       ((and (consp argument)
             (eq (car argument) 'quote)
             (symbolp (cadr argument)))
        (format "%s %s" head (cadr argument)))
       (t (symbol-name head))))))

(defun tired--elisp-label-spans (form start)
  "Return the source spans of the head and the argument of FORM at START.
The value is a list of one or two (BEG . END) conses for the head
symbol and, when the form names one, its symbol argument.  The value
is nil when FORM does not start with an open paren."
  (when (and (consp form)
             (symbolp (car form))
             (eq (char-after start) ?\())
    (save-excursion
      (goto-char start)
      (forward-char 1)
      (forward-comment (point-max))
      (let ((head-start (point))
            spans)
        (forward-sexp 1)
        (push (cons head-start (point)) spans)
        (forward-comment (point-max))
        (while (memq (char-after) '(?\' ?`))
          (forward-char 1))
        (let ((argument (cadr form)))
          (when (or (and argument (symbolp argument))
                    (and (consp argument)
                         (eq (car argument) 'quote)
                         (symbolp (cadr argument))))
            (let ((argument-start (point)))
              (forward-sexp 1)
              (push (cons argument-start (point)) spans))))
        (nreverse spans)))))

(defun tired--elisp-fontified-label (form start)
  "Return the label of FORM at START with the faces of its source text.
Return nil when FORM carries no label.  Copy the head symbol and the
symbol argument out of the fontified current buffer, so each part keeps
the face that `emacs-lisp-mode' gives it.  Return the plain label when
the source spans do not reproduce it."
  (when-let* ((label (tired--elisp-label form)))
    (let* ((spans (tired--elisp-label-spans form start))
           (pieces (mapcar (lambda (span)
                             (buffer-substring (car span) (cdr span)))
                           spans)))
      (if (and pieces
               (equal (mapconcat #'substring-no-properties pieces " ") label))
          (mapconcat #'identity pieces " ")
        label))))

(defun tired-file-sections-elisp (_path)
  "Return the top-level forms of the current Emacs Lisp buffer.
The buffer already holds the file, so the handler ignores PATH.
Only top-level forms become sections, so a form inside `progn'
stays out.  A form that `read' rejects ends the scan.  Each label
carries the faces that `emacs-lisp-mode' fontification gives its
source text."
  (delay-mode-hooks (emacs-lisp-mode))
  (font-lock-ensure)
  (let (sections)
    (goto-char (point-min))
    (while (progn (forward-comment (point-max)) (not (eobp)))
      (let ((start (point))
            (form (condition-case nil
                      (read (current-buffer))
                    (error tired--elisp-read-error))))
        (if (eq form tired--elisp-read-error)
            (goto-char (point-max))
          (when-let* ((label (tired--elisp-fontified-label form start)))
            (push (list :label label
                        :line (line-number-at-pos start)
                        :level 0
                        :kind (if (string-prefix-p "def"
                                                   (symbol-name (car form)))
                                  'definition
                                'form))
                  sections)))))
    (nreverse sections)))

(defconst tired--rust-section-spec
  '(:language rust
    :mode rust-ts-mode
    :kinds (("function_item" . function)
            ("function_signature_item" . function)
            ("struct_item" . struct)
            ("enum_item" . enum)
            ("union_item" . union)
            ("trait_item" . trait)
            ("impl_item" . impl)
            ("mod_item" . module)
            ("type_item" . type)
            ("const_item" . constant)
            ("static_item" . constant)
            ("macro_definition" . macro))
    :containers ("impl_item" "mod_item" "trait_item")
    :fields ("name" "type"))
  "Tree-sitter section spec for a Rust file.")

(defconst tired--markdown-section-spec
  '(:language markdown
    :mode markdown-ts-mode
    :require markdown-ts-mode
    :kinds (("atx_heading" . heading)
            ("setext_heading" . heading))
    :label tired--markdown-section-label
    :level tired--markdown-section-level)
  "Tree-sitter section spec for a Markdown file.")

(defun tired--treesit-field-text (node fields)
  "Return the text of the first field of NODE that FIELDS names.
Return nil when NODE carries none of the fields."
  (seq-some (lambda (field)
              (when-let* ((child (treesit-node-child-by-field-name
                                  node field)))
                (treesit-node-text child t)))
            fields))

(defun tired--treesit-kind (node spec)
  "Return the section kind that SPEC declares for NODE, or nil."
  (alist-get (treesit-node-type node) (plist-get spec :kinds)
             nil nil #'equal))

(defun tired--treesit-label (node kind spec)
  "Return the label for NODE of KIND under SPEC.
SPEC may name a `:label' function.  Without one, use the first
`:fields' entry that NODE carries and fall back to KIND alone."
  (if-let* ((function (plist-get spec :label)))
      (funcall function node kind)
    (format "%s %s" kind
            (or (tired--treesit-field-text
                 node (or (plist-get spec :fields) '("name")))
                "?"))))

(defun tired--treesit-level (node spec depth)
  "Return the level for NODE under SPEC, or DEPTH.
SPEC may name a `:level' function, so a grammar that spells the level
in a marker node does not rely on the tree depth."
  (if-let* ((function (plist-get spec :level)))
      (funcall function node)
    depth))

(defun tired--treesit-shown-p (node spec)
  "Return non-nil when SPEC shows NODE as a section.
SPEC may name a `:filter' function, which receives NODE and decides
whether NODE appears.  Without one every node of a known kind
appears."
  (let ((filter (plist-get spec :filter)))
    (or (null filter) (funcall filter node))))

(defun tired--treesit-walk (node spec depth)
  "Return the section plists of NODE and its children under SPEC.
DEPTH is the current nesting depth.  A node type listed in
`:containers' raises the depth of its children by one.  A node that
`:filter' rejects yields no section, and its children still walk."
  (let* ((kind (tired--treesit-kind node spec))
         (here (when (and kind (tired--treesit-shown-p node spec))
                 (list (list :label (tired--treesit-label node kind spec)
                             :line (line-number-at-pos
                                    (treesit-node-start node))
                             :level (tired--treesit-level node spec depth)
                             :kind kind))))
         (next-depth (if (member (treesit-node-type node)
                                 (plist-get spec :containers))
                         (1+ depth)
                       depth)))
    (append here
            (mapcan (lambda (child)
                      (tired--treesit-walk child spec next-depth))
                    (treesit-node-children node t)))))

(defun tired--treesit-sections (spec)
  "Return the section plists of the current buffer according to SPEC.
SPEC is a plist with `:language', an optional `:mode', an optional
`:require', `:kinds', optional `:containers', optional `:fields',
optional `:filter', optional `:label' and optional `:level'.  Return
nil when the grammar is missing, so the caller keeps a plain file
row."
  (require 'treesit)
  (let ((language (plist-get spec :language)))
    (when (and (treesit-available-p) (treesit-ready-p language t))
      (when-let* ((library (plist-get spec :require)))
        (require library))
      (when-let* ((mode (plist-get spec :mode)))
        (delay-mode-hooks (funcall mode)))
      (when-let* ((root (treesit-buffer-root-node language)))
        (tired--treesit-walk root spec 0)))))

(defun tired--markdown-section-level (node)
  "Return the heading level of the Markdown NODE.
An ATX heading counts its hash markers.  A setext heading takes
level 1 from an `=' underline and level 2 from any other underline."
  (if (equal (treesit-node-type node) "atx_heading")
      (length (treesit-node-text (treesit-node-child node 0) t))
    (if (seq-some (lambda (child)
                    (equal (treesit-node-type child) "setext_h1_underline"))
                  (treesit-node-children node))
        1
      2)))

(defun tired--markdown-section-label (node _kind)
  "Return the text of the Markdown heading NODE without its marker.
KIND stays unused."
  (let ((content (or (treesit-node-child-by-field-name
                      node "heading_content")
                     node)))
    (string-trim (treesit-node-text content t))))

(defun tired-file-sections-rust (_path)
  "Return the items of the current Rust buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Read functions, structs, enums, traits, impl blocks, modules,
constants and macros through tree-sitter.  Return nil when the
Rust grammar is missing."
  (tired--treesit-sections tired--rust-section-spec))

(defun tired-file-sections-markdown (_path)
  "Return the headings of the current Markdown buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Read ATX and setext headings through tree-sitter, so a heading
inside a fenced code block stays out of the listing.  Return nil
when the Markdown grammar is missing."
  (tired--treesit-sections tired--markdown-section-spec))

(defconst tired--cargo-tables '("features" "dependencies"
                                "dev-dependencies" "build-dependencies")
  "Table names that the Cargo manifest handler lists.
A table with any other name stays out, so `[patch.crates-io]' and
`[target.'cfg(...)'.dependencies]' show no section.")

(defconst tired--cargo-section-spec
  '(:language toml
    :mode toml-ts-mode
    :require toml-ts-mode
    :kinds (("table" . table)
            ("table_array_element" . table)
            ("pair" . dependency))
    :containers ("table" "table_array_element")
    :filter tired--cargo-node-shown-p
    :label tired--cargo-section-label)
  "Tree-sitter section spec for a Cargo manifest.")

(defun tired--toml-unquote (text)
  "Return TEXT without the quotes of a TOML string."
  (if (and (> (length text) 1)
           (memq (aref text 0) '(?\" ?'))
           (eq (aref text 0) (aref text (1- (length text)))))
      (substring text 1 -1)
    text))

(defun tired--toml-key (node)
  "Return the key text of the TOML pair or table NODE.
Strip the quotes of a quoted key, so a quoted crate name reads like
a bare one."
  (when-let* ((child (seq-find (lambda (child)
                                 (member (treesit-node-type child)
                                         '("bare_key" "quoted_key"
                                           "dotted_key")))
                               (treesit-node-children node t))))
    (if (equal (treesit-node-type child) "quoted_key")
        (tired--toml-unquote (treesit-node-text child t))
      (treesit-node-text child t))))

(defun tired--toml-pair-value (node)
  "Return the value node of the TOML pair NODE, or nil."
  (seq-find (lambda (child)
              (not (member (treesit-node-type child)
                           '("bare_key" "quoted_key" "dotted_key"
                             "comment"))))
            (treesit-node-children node t)))

(defun tired--toml-field-text (table name)
  "Return the value text of the pair NAME in the TOML inline table TABLE."
  (when-let* ((pair (seq-find (lambda (child)
                                (and (equal (treesit-node-type child) "pair")
                                     (equal (tired--toml-key child) name)))
                              (treesit-node-children table t))))
    (when-let* ((value (tired--toml-pair-value pair)))
      (treesit-node-text value t))))

(defun tired--cargo-node-shown-p (node)
  "Return non-nil when NODE belongs in a Cargo manifest listing.
Keep the four tables that `tired--cargo-tables' names and the pairs
inside them, so a pair of another table stays out."
  (pcase (treesit-node-type node)
    ((or "table" "table_array_element")
     (member (tired--toml-key node) tired--cargo-tables))
    ("pair"
     (member (tired--toml-key (treesit-node-parent node)) tired--cargo-tables))))

(defun tired--cargo-version (value)
  "Return the version text of the TOML pair VALUE.
VALUE holds either a version string or an inline table with a
`version' key.  Return nil when VALUE names no version."
  (pcase (and value (treesit-node-type value))
    ("string" (tired--toml-unquote (treesit-node-text value t)))
    ("inline_table"
     (when-let* ((text (tired--toml-field-text value "version")))
       (tired--toml-unquote text)))))

(defun tired--cargo-badges (value)
  "Return the badge strings of the TOML pair VALUE.
An inline table with `optional = true' earns `[optional]', and one
with `default-features = false' earns `[no-default]'."
  (when (and value (equal (treesit-node-type value) "inline_table"))
    (delq nil
          (list (when (equal (tired--toml-field-text value "optional") "true")
                  "[optional]")
                (when (equal (tired--toml-field-text value "default-features")
                             "false")
                  "[no-default]")))))

(defvar tired--cargo-columns nil
  "Column widths of the Cargo manifest in the current buffer.
The value is a cons `(KEY . VERSION)'.  `tired-file-sections-cargo'
binds the variable to nil for one parse, and `tired--cargo-measure'
fills it on first use, so every listed table of a file shares both
columns.")

;; One key column and one version column span the whole file, so a
;; feature arrow, a dependency version and a dependency badge each
;; start at the same place, the way elastic tabstops align a block.
;; The labels stay plain strings, so the filter, the copy commands and
;; the tests read them like any other label.
(defun tired--cargo-measure ()
  "Return the column widths of the four listed tables in this buffer.
Measure the file once, then reuse the value.  The car is the widest
key length, and the cdr is the widest version length."
  (or tired--cargo-columns
      (setq tired--cargo-columns
            (let ((root (treesit-buffer-root-node 'toml))
                  (key-width 0)
                  (version-width 0))
              (dolist (table (and root (treesit-node-children root t)))
                (when (member (tired--toml-key table) tired--cargo-tables)
                  (dolist (pair (treesit-node-children table t))
                    (when (equal (treesit-node-type pair) "pair")
                      (setq key-width
                            (max key-width
                                 (length (or (tired--toml-key pair) ""))))
                      (when-let* ((version (tired--cargo-version
                                            (tired--toml-pair-value pair))))
                        (setq version-width
                              (max version-width (length version))))))))
              (cons key-width version-width)))))

(defun tired--cargo-pad (text width)
  "Return TEXT padded with spaces to WIDTH characters."
  (concat text (make-string (max 0 (- width (length text))) ?\s)))

(defun tired--cargo-padded-key (key)
  "Return KEY padded to the key column of the Cargo manifest.
The column covers every listed table of the file, so a feature
arrow and a dependency version start in one place."
  (tired--cargo-pad key (car (tired--cargo-measure))))

(defun tired--cargo-padded-version (version)
  "Return VERSION padded to the version column of the manifest.
The column covers every listed table of the file, so the badges of
a dependency start in one place."
  (tired--cargo-pad version (cdr (tired--cargo-measure))))

(defun tired--cargo-table-label (node)
  "Return the label of the Cargo table NODE.
The label names the table and counts its entries."
  (format "%s (%d)" (tired--toml-key node)
          (seq-count (lambda (child)
                       (equal (treesit-node-type child) "pair"))
                     (treesit-node-children node t))))

(defun tired--cargo-feature-label (node key)
  "Return the label of the feature NODE under the key KEY.
List the members of the feature, so the row answers what the
feature turns on.  Pad KEY to the key column, so every arrow of
the manifest sits in one place."
  (let* ((value (tired--toml-pair-value node))
         (members (when (and value (equal (treesit-node-type value) "array"))
                    (mapcar (lambda (child)
                              (tired--toml-unquote
                               (treesit-node-text child t)))
                            (seq-filter (lambda (child)
                                          (equal (treesit-node-type child)
                                                 "string"))
                                        (treesit-node-children value))))))
    (if members
        (format "%s \u2192 %s" (tired--cargo-padded-key key)
                (string-join members ", "))
      key)))

(defun tired--cargo-dependency-label (node key)
  "Return the label of the dependency NODE under the key KEY.
The label holds the crate name, its version and its badges.  Pad
the version to the version column, so the badges line up."
  (let* ((value (tired--toml-pair-value node))
         (version (tired--cargo-version value))
         (badges (tired--cargo-badges value)))
    (string-trim (concat (tired--cargo-padded-key key) " "
                         (and version (tired--cargo-padded-version version))
                         (when badges (concat " " (string-join badges " ")))))))

(defun tired--cargo-section-label (node _kind)
  "Return the label of the Cargo manifest NODE.
KIND stays unused, because the parent table decides the label
shape: a pair of `[features]' lists members, and a pair of any
other listed table holds a dependency."
  (if (equal (treesit-node-type node) "pair")
      (let ((key (tired--toml-key node))
            (parent (tired--toml-key (treesit-node-parent node))))
        (if (equal parent "features")
            (tired--cargo-feature-label node key)
          (tired--cargo-dependency-label node key)))
    (tired--cargo-table-label node)))

(defun tired-file-sections-cargo (_path)
  "Return the tables of the current Cargo manifest buffer as sections.
The buffer already holds the file, so the handler ignores PATH.
Read the `features', `dependencies', `dev-dependencies' and
`build-dependencies' tables through tree-sitter, with their entries
one level below.  Bind one key column and one version column for
the whole file, so the feature arrows and the dependency versions
line up.  Return nil when the TOML grammar is missing."
  (let ((tired--cargo-columns nil))
    (tired--treesit-sections tired--cargo-section-spec)))

(defun tired--sqlite-column-label (row)
  "Return the label for the `PRAGMA table_info' ROW of one column.
ROW holds the column id, name, declared type, NOT NULL flag, default
value and primary key flag."
  (let ((name (nth 1 row))
        (type (nth 2 row))
        (notnull (nth 3 row))
        (primary (nth 5 row)))
    (concat (if (and type (not (string-empty-p type)))
                (format "%s %s" name type)
              name)
            (if (and notnull (not (zerop notnull))) " NOT NULL" "")
            (if (and primary (not (zerop primary))) " PRIMARY KEY" ""))))

(defun tired--sqlite-open-table (section table &optional _other-window)
  "Show TABLE of the database that SECTION belongs to.
Open the database in `sqlite-mode' and move point to the row of
TABLE.  OTHER-WINDOW stays unused, because `sqlite-mode-open-file'
chooses the window itself."
  (require 'sqlite-mode)
  (sqlite-mode-open-file (tired-section-path section))
  (goto-char (point-min))
  (when (re-search-forward (concat "^" (regexp-quote table) "\\_>") nil t)
    (beginning-of-line)))

(defun tired-file-sections-sqlite (path)
  "Return the tables and columns of the SQLite database at PATH.
The handler uses the built-in `sqlite' support, so it needs no
external tool.  Each table is a section and its columns follow one
level deeper.  A database has no lines, so a section carries a
synthetic ordinal and its action opens the table in `sqlite-mode'.
Return nil when Emacs lacks SQLite support or when PATH holds no
readable database."
  (when (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (condition-case nil
        (let ((db (sqlite-open path t))
              (line 0)
              sections)
          (unwind-protect
              (dolist (row (sqlite-select
                            db
                            (concat "SELECT name FROM sqlite_master "
                                    "WHERE type IN ('table', 'view') "
                                    "AND name NOT LIKE 'sqlite_%' "
                                    "ORDER BY name")))
                (let ((table (car row)))
                  (push (list :label table
                              :line (setq line (1+ line))
                              :level 0
                              :kind 'table
                              :action (cons #'tired--sqlite-open-table
                                            (list table)))
                        sections)
                  (dolist (column (sqlite-select
                                   db (format "PRAGMA table_info(%S)" table)))
                    (push (list :label (tired--sqlite-column-label column)
                                :line (setq line (1+ line))
                                :level 1
                                :kind 'column
                                :action (cons #'tired--sqlite-open-table
                                              (list table)))
                          sections))))
            (sqlite-close db))
          (nreverse sections))
      (error nil))))

(provide 'tired-sections)

;;; tired-sections.el ends here
