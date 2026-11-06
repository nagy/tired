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
;; structs: Org, Emacs Lisp, Rust, Go, Markdown, Cargo and SQLite.  The
;; framework that calls a handler stays in `tired-core', so a new
;; handler costs one rule in `tired-file-handlers'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tired-core)

;; This user option lives in `treesit', which loads at run time.  A plain
;; `defvar' marks the variable special, so a binding stays dynamic and
;; byte compilation stays quiet.
(defvar treesit-auto-install-grammar)

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
(declare-function treesit-node-child-count "treesit" (node &optional named))
(declare-function treesit-node-children "treesit" (node &optional named))
(declare-function treesit-node-end "treesit" (node))
(declare-function treesit-node-field-name "treesit" (node))
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

(defun tired--org-heading-span (headline)
  "Return the (BEG . END) buffer span of the title of HEADLINE.
Skip the stars, then search the title text on the heading line, so a
TODO keyword, a priority cookie and a tag list stay out of the span.
Return nil when the title does not appear verbatim."
  (save-excursion
    (goto-char (org-element-property :begin headline))
    (when (re-search-forward "^\\*+[ \t]+" (line-end-position) t)
      (let ((title (org-element-property :title headline)))
        (when (and (stringp title)
                   (not (string-empty-p title))
                   (search-forward title (line-end-position) t))
          (cons (match-beginning 0) (match-end 0)))))))

(defun tired--org-section-label (headline)
  "Return the title of HEADLINE with the faces of its source text.
The faces come from `org-mode' fontification, so a heading keeps the
color of its level.  Return the plain raw value when the span holds
no face."
  (let* ((span (tired--org-heading-span headline))
         (text (and span (buffer-substring (car span) (cdr span)))))
    (if (and text (text-property-not-all 0 (length text) 'face nil text))
        text
      (or (org-element-property :raw-value headline) ""))))

(defun tired-file-sections-org (_path)
  "Return the headings of the current org buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Parse with `org-element', so a heading inside a source block or an
example block stays out of the listing.  The line of a heading is
the line of its stars.  A label carries the faces that `org-mode'
fontification gives the title.  Every section carries
`tired--org-open-heading' as its action."
  (require 'org)
  (require 'org-element)
  (delay-mode-hooks (org-mode))
  (font-lock-ensure)
  (org-element-map (org-element-parse-buffer 'headline) 'headline
    (lambda (headline)
      (list :label (tired--org-section-label headline)
            :line (line-number-at-pos (org-element-property :begin headline))
            :level (org-element-property :level headline)
            :kind 'heading
            :action #'tired--org-open-heading))))

(defconst tired--elisp-read-error (make-symbol "tired--read-error")
  "Sentinel that marks a form which `read' rejected.")

(defconst tired--elisp-hidden-heads '(declare-function)
  "Head symbols that the Emacs Lisp handler leaves out of a listing.
A form with one of these heads speaks to the byte compiler alone, so
it earns no row.  The form still holds its lines in the file, so the
rows above and below it keep their own lines.")

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
stays out.  A form whose head `tired--elisp-hidden-heads' names stays
out too, because it speaks to the byte compiler alone.  A form that
`read' rejects ends the scan.  Each label carries the faces that
`emacs-lisp-mode' fontification gives its source text."
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
          (let ((label (unless (memq (car-safe form)
                                     tired--elisp-hidden-heads)
                         (tired--elisp-fontified-label form start))))
            (when label
              (push (list :label label
                          :line (line-number-at-pos start)
                          :level 0
                          :kind (if (string-prefix-p "def"
                                                     (symbol-name (car form)))
                                    'definition
                                  'form))
                    sections))))))
    (nreverse sections)))

(defun tired--treesit-keyword-string (kind)
  "Return KIND as a string that carries `font-lock-keyword-face'.
A row whose source text holds no prefix of its own uses this string,
so its kind word still reads like a keyword of the major mode."
  (propertize (symbol-name kind) 'face 'font-lock-keyword-face))

(defun tired--treesit-collapse-space (string)
  "Return STRING with each run of whitespace replaced by one space.
Trim both ends.  The parts that stay keep their text properties, so a
keyword keeps the face that the major mode gave it, and one item
prefix never breaks a row onto a second line."
  (let ((position 0)
        (end (length string))
        (parts nil))
    (while (< position end)
      (let ((space (string-match "[ \t\n\r\f]+" string position)))
        (if (and space (< space end))
            (progn
              (when (< position space)
                (push (substring string position space) parts))
              (push " " parts)
              (setq position (match-end 0)))
          (push (substring string position end) parts)
          (setq position end))))
    (string-trim (apply #'concat (nreverse parts)))))

(defun tired--treesit-keyword-text (start end)
  "Return the source text from START to END as a keyword prefix.
Collapse the whitespace, so one row holds one line.  A part that
carries no source face takes `font-lock-keyword-face', so a mode that
fontifies nothing still shows a keyword.  Return nil when the range
holds no text."
  (let ((text (tired--treesit-collapse-space (buffer-substring start end))))
    (when (> (length text) 0)
      (let ((position 0)
            (size (length text)))
        (while (< position size)
          (let ((next (or (next-single-property-change position 'face
                                                       text size)
                          size)))
            (unless (get-text-property position 'face text)
              (add-text-properties position next
                                   '(face font-lock-keyword-face)
                                   text))
            (setq position next))))
      text)))

(defun tired--treesit-prefixed-label (prefix name)
  "Return PREFIX and NAME as one label, separated by a space.
Return NAME alone without a PREFIX, so a name that starts a row takes
no leading space."
  (if (and prefix (> (length prefix) 0))
      (concat prefix " " name)
    name))

(defun tired--rust-prefix-start (node)
  "Return the position where the prefix text of NODE starts.
Skip a visibility modifier, so a row never shows `pub' and a
multi-line `pub(in path)' costs no line break."
  (if-let* ((visibility
             (seq-find (lambda (child)
                         (equal (treesit-node-type child)
                                "visibility_modifier"))
                       (treesit-node-children node))))
      (treesit-node-end visibility)
    (treesit-node-start node)))

(defun tired--rust-section-label (node kind)
  "Return the label for the Rust item NODE of KIND.
Take the item prefix from the source text, so a struct reads `struct'
and a function reads `fn', `async fn' or `unsafe fn', and each prefix
keeps the face that `rust-ts-mode' gave its keyword.  A visibility
modifier stays out, so a struct never reads differently for `pub'.
An impl block names its type and its trait, the way its source line
does."
  (if (equal (treesit-node-type node) "impl_item")
      (if-let* ((body (treesit-node-child-by-field-name node "body")))
          (or (tired--treesit-keyword-text (tired--rust-prefix-start node)
                                           (treesit-node-start body))
              (tired--treesit-keyword-string kind))
        (tired--treesit-keyword-string kind))
    (if-let* ((name (treesit-node-child-by-field-name node "name")))
        (tired--treesit-prefixed-label
         (tired--treesit-keyword-text (tired--rust-prefix-start node)
                                      (treesit-node-start name))
         (treesit-node-text name))
      (tired--treesit-keyword-string kind))))

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
            ("const_item" . const)
            ("static_item" . static)
            ("macro_definition" . macro))
    :containers ("impl_item" "mod_item" "trait_item")
    :label tired--rust-section-label)
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
Return nil when NODE carries none of the fields.  The text keeps the
faces that the buffer fontification gave it."
  (seq-some (lambda (field)
              (when-let* ((child (treesit-node-child-by-field-name
                                  node field)))
                (treesit-node-text child)))
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
  (let ((language (plist-get spec :language))
        ;; A fenced Markdown code block names another language, and a
        ;; missing grammar there must not raise an install question
        ;; while the listing parses a file.
        (treesit-auto-install-grammar nil))
    (when (and (treesit-available-p) (treesit-ready-p language t))
      (when-let* ((library (plist-get spec :require)))
        (require library))
      (when-let* ((mode (plist-get spec :mode)))
        (delay-mode-hooks (funcall mode)))
      ;; Fontify the whole buffer once, so every label below can copy
      ;; the faces of its source text.
      (font-lock-ensure)
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
KIND stays unused.  The text keeps the faces that
`markdown-ts-mode' gives it."
  (let ((content (or (treesit-node-child-by-field-name
                      node "heading_content")
                     node)))
    (string-trim (treesit-node-text content))))

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

(defvar tired--go-type-starts nil
  "Hash table of every Go type name of the current buffer.
The value is the start of the `type_spec' node, so a method indents
under a type that the file declares above it.
`tired-file-sections-go' binds the variable to nil for one parse, and
`tired--go-type-start' fills it on first use.")

(defun tired--go-collect-type-starts ()
  "Return a hash table from each Go type name of the buffer to its start.
The value of a name is the start of its `type_spec' node, so every
name of one `type' block has its own position."
  (let ((root (treesit-buffer-root-node 'go))
        (table (make-hash-table :test #'equal)))
    (dolist (declaration (and root (treesit-node-children root t)))
      (when (equal (treesit-node-type declaration) "type_declaration")
        (dolist (spec (treesit-node-children declaration t))
          (when (equal (treesit-node-type spec) "type_spec")
            (when-let* ((name (treesit-node-child-by-field-name spec "name")))
              (puthash (treesit-node-text name t)
                       (treesit-node-start spec)
                       table))))))
    table))

(defun tired--go-type-start (name)
  "Return the position of the Go type NAME in this buffer, or nil.
Fill `tired--go-type-starts' on first use, so one parse walks the
type declarations once."
  (unless tired--go-type-starts
    (setq tired--go-type-starts (tired--go-collect-type-starts)))
  (gethash name tired--go-type-starts))

(defun tired--go-receiver-name (node)
  "Return the receiver type name of the Go method declaration NODE.
Drop a pointer star and a type argument list, so a method of `*Set[T]'
names the type `Set'.  Return nil when NODE names no receiver type."
  (when-let* ((receiver (treesit-node-child-by-field-name node "receiver"))
              (parameter (seq-find (lambda (child)
                                     (equal (treesit-node-type child)
                                            "parameter_declaration"))
                                   (treesit-node-children receiver t)))
              (type (treesit-node-child-by-field-name parameter "type")))
    (let ((text (treesit-node-text type t)))
      (setq text (replace-regexp-in-string "\\`\\*+" "" text))
      (replace-regexp-in-string "\\[.*\\'" "" text))))

(defun tired--go-name-texts (node)
  "Return the declared names of the Go constant or variable spec NODE.
Each name keeps the faces that the buffer fontification gave it."
  (let (names)
    (dotimes (index (treesit-node-child-count node t))
      (let ((child (treesit-node-child node index t)))
        (when (and (equal (treesit-node-type child) "identifier")
                   (equal (treesit-node-field-name child) "name"))
          (push (treesit-node-text child) names))))
    (nreverse names)))

(defun tired--go-section-label (node kind)
  "Return the label for the Go NODE of KIND.
A declaration that starts with its keyword takes the keyword from the
source text, so a function reads `func' and a method reads
`func (c *Config)', and each keyword keeps the face that `go-ts-mode'
gave it.  A type, constant or variable spec sits inside its
declaration, so its kind word carries `font-lock-keyword-face' alone.
A constant and a variable name every name that one spec declares."
  (let ((name (pcase (treesit-node-type node)
                ((or "const_spec" "var_spec")
                 (or (string-join (tired--go-name-texts node) ", ") "?"))
                (_ (or (tired--treesit-field-text node '("name")) "?")))))
    (if (member (treesit-node-type node)
                '("function_declaration" "method_declaration"))
        (tired--treesit-prefixed-label
         (when-let* ((child (treesit-node-child-by-field-name node "name")))
           (tired--treesit-keyword-text (treesit-node-start node)
                                        (treesit-node-start child)))
         name)
      (tired--treesit-prefixed-label (tired--treesit-keyword-string kind)
                                     name))))

(defun tired--go-node-shown-p (node)
  "Return non-nil when NODE belongs in a Go listing.
Keep a declaration at the top level of the file, and drop the one
inside a function body or a nested block."
  (let* ((parent (treesit-node-parent node))
         (container (and parent (treesit-node-parent parent))))
    (or (null parent)
        (equal (treesit-node-type parent) "source_file")
        (and container
             (equal (treesit-node-type container) "source_file")))))

(defun tired--go-node-level (node)
  "Return the level of the Go NODE.
A method indents one level under the type that the file declares
above it.  Every other declaration sits at level zero."
  (if (and (equal (treesit-node-type node) "method_declaration")
           (when-let* ((name (tired--go-receiver-name node))
                       (start (tired--go-type-start name)))
             (< start (treesit-node-start node))))
      1
    0))

(defconst tired--go-section-spec
  '(:language go
    :mode go-ts-mode
    :require go-ts-mode
    :kinds (("function_declaration" . function)
            ("method_declaration" . method)
            ("type_spec" . type)
            ("const_spec" . const)
            ("var_spec" . var))
    :filter tired--go-node-shown-p
    :label tired--go-section-label
    :level tired--go-node-level)
  "Tree-sitter section spec for a Go file.")

(defun tired-file-sections-go (_path)
  "Return the declarations of the current Go buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Read functions, methods, types, constants and variables through
tree-sitter.  A method indents under the type that the file declares
above it, and a declaration inside a function body stays out.  Return
nil when the Go grammar is missing."
  (let ((tired--go-type-starts nil))
    (tired--treesit-sections tired--go-section-spec)))

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
  (declare (pure t) (side-effect-free t))
  (if (and (> (length text) 1)
           (memq (aref text 0) '(?\" ?'))
           (eq (aref text 0) (aref text (1- (length text)))))
      (substring text 1 -1)
    text))

(defun tired--toml-key-node (node)
  "Return the key node of the TOML pair or table NODE, or nil."
  (seq-find (lambda (child)
              (member (treesit-node-type child)
                      '("bare_key" "quoted_key" "dotted_key")))
            (treesit-node-children node t)))

(defun tired--toml-key (node)
  "Return the key text of the TOML pair or table NODE.
Strip the quotes of a quoted key, so a quoted crate name reads like
a bare one."
  (when-let* ((child (tired--toml-key-node node)))
    (if (equal (treesit-node-type child) "quoted_key")
        (tired--toml-unquote (treesit-node-text child t))
      (treesit-node-text child t))))

(defun tired--toml-key-label (node)
  "Return the key text of the TOML pair or table NODE with its faces.
Strip the quotes of a quoted key, so a quoted crate name reads like a
bare one.  The text keeps the faces that the buffer fontification
gave it."
  (when-let* ((child (tired--toml-key-node node)))
    (if (equal (treesit-node-type child) "quoted_key")
        (tired--toml-unquote (treesit-node-text child))
      (treesit-node-text child))))

(defun tired--toml-pair-value (node)
  "Return the value node of the TOML pair NODE, or nil."
  (seq-find (lambda (child)
              (not (member (treesit-node-type child)
                           '("bare_key" "quoted_key" "dotted_key"
                             "comment"))))
            (treesit-node-children node t)))

(defun tired--toml-field-node (table name)
  "Return the value node of the pair NAME in the TOML inline table TABLE."
  (when-let* ((pair (seq-find (lambda (child)
                                (and (equal (treesit-node-type child) "pair")
                                     (equal (tired--toml-key child) name)))
                              (treesit-node-children table t))))
    (tired--toml-pair-value pair)))

(defun tired--toml-field-text (table name)
  "Return the plain value text of the pair NAME in the TOML inline table TABLE."
  (when-let* ((value (tired--toml-field-node table name)))
    (treesit-node-text value t)))

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
`version' key.  Return nil when VALUE names no version.  The text
keeps the faces that the buffer fontification gave it."
  (pcase (and value (treesit-node-type value))
    ("string" (tired--toml-unquote (treesit-node-text value)))
    ("inline_table"
     (when-let* ((node (tired--toml-field-node value "version")))
       (tired--toml-unquote (treesit-node-text node))))))

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
  (declare (pure t) (side-effect-free t))
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
The label names the table and counts its entries.  The name keeps the
faces that the buffer fontification gave it."
  (concat (or (tired--toml-key-label node) "")
          (format " (%d)"
                  (seq-count (lambda (child)
                               (equal (treesit-node-type child) "pair"))
                             (treesit-node-children node t)))))

(defun tired--cargo-member-texts (value)
  "Return the member texts of the TOML array VALUE with their faces.
VALUE holds the value node of a feature pair."
  (when (and value (equal (treesit-node-type value) "array"))
    (mapcar (lambda (child)
              (tired--toml-unquote (treesit-node-text child)))
            (seq-filter (lambda (child)
                          (equal (treesit-node-type child) "string"))
                        (treesit-node-children value)))))

(defun tired--cargo-feature-label (node key)
  "Return the label of the feature NODE under the plain key KEY.
List the members of the feature, so the row answers what the
feature turns on.  Pad the feature name to the key column, so every
arrow of the manifest sits in one place.  The feature name and each
member keep the faces of their source text."
  (let* ((members (tired--cargo-member-texts
                   (tired--toml-pair-value node)))
         (name (tired--cargo-padded-key
                (or (tired--toml-key-label node) key))))
    (if members
        (concat name " \u2192 " (string-join members ", "))
      key)))

(defun tired--cargo-dependency-label (node key)
  "Return the label of the dependency NODE under the plain key KEY.
The label holds the crate name, its version and its badges.  Pad
the version to the version column, so the badges line up.  The crate
name and the version keep the faces of their source text."
  (let* ((value (tired--toml-pair-value node))
         (name (tired--cargo-padded-key
                (or (tired--toml-key-label node) key)))
         (version (tired--cargo-version value))
         (badges (tired--cargo-badges value)))
    (string-trim (concat name " "
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

(defface tired-sqlite-column-face
  '((t :inherit font-lock-variable-name-face))
  "Face for the name of a SQLite column.
The face inherits `font-lock-variable-name-face', so a theme colors
the name the way it colors a variable in a source file."
  :group 'tired)

(defface tired-sqlite-type-face
  '((t :inherit font-lock-type-face))
  "Face for the declared type of a SQLite column.
The face inherits `font-lock-type-face', so a theme colors the type
the way it colors a type in a source file."
  :group 'tired)

(defface tired-sqlite-constraint-face
  '((t :inherit font-lock-keyword-face))
  "Face for a constraint keyword of a SQLite column.
The face paints `NOT NULL' and `PRIMARY KEY', and it inherits
`font-lock-keyword-face'."
  :group 'tired)

(defun tired--sqlite-painted (text face)
  "Return TEXT painted with FACE, or an empty string for nil TEXT.
The separators of a label stay plain, so only the token takes the
color.  The section cell mirrors FACE into `font-lock-face'."
  (declare (pure t) (side-effect-free t))
  (if (or (null text) (string-empty-p text))
      ""
    (propertize text 'face face)))

(defun tired--sqlite-column-label (row)
  "Return the label for the `PRAGMA table_info' ROW of one column.
ROW holds the column id, name, declared type, NOT NULL flag, default
value and primary key flag.  Paint the name, the type and each
constraint keyword with its own face, so a column row reads like a
declaration."
  (declare (pure t) (side-effect-free t))
  (let ((tokens nil)
        (name (nth 1 row))
        (type (nth 2 row))
        (notnull (nth 3 row))
        (primary (nth 5 row)))
    (push (tired--sqlite-painted name 'tired-sqlite-column-face) tokens)
    (when (and type (not (string-empty-p type)))
      (push (tired--sqlite-painted type 'tired-sqlite-type-face) tokens))
    (when (and notnull (not (zerop notnull)))
      (push (tired--sqlite-painted "NOT NULL" 'tired-sqlite-constraint-face)
            tokens))
    (when (and primary (not (zerop primary)))
      (push (tired--sqlite-painted "PRIMARY KEY"
                                   'tired-sqlite-constraint-face)
            tokens))
    (string-join (nreverse tokens) " ")))

(defun tired--sqlite-table-count (db table)
  "Return the number of rows that TABLE of DB holds.
A view answers the same query, because SQLite counts its rows on a
read.  Return nil when the query fails."
  (condition-case nil
      (car (car (sqlite-select db (format "SELECT count(*) FROM %S" table))))
    (error nil)))

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
A table section also carries the number of rows that the table
holds, so the Elements column answers for it.  Return nil when
Emacs lacks SQLite support or when PATH holds no readable
database."
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
                              :count (tired--sqlite-table-count db table)
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

(defconst tired--tar-block 512
  "Size of one tar header block and of one tar data block.")

(defun tired--tar-field (header start end)
  "Return the text between START and END of the tar HEADER.
Stop at the first NUL byte, as the format intends."
  (declare (pure t) (side-effect-free t))
  (let* ((text (substring header start end))
         (nul (cl-position 0 text)))
    (substring text 0 (or nul (length text)))))

(defun tired--tar-number (text)
  "Return the number that the tar header field TEXT holds.
Read an octal field, and a GNU base-256 field that sets the high bit
of its first byte.  Return 0 for an empty field."
  (declare (pure t) (side-effect-free t))
  ;; `string-trim' reads through `string-match', so the caller keeps
  ;; its own match data.
  (let ((text (save-match-data (string-trim text "[\0 ]" "[\0 ]"))))
    (cond
     ((string-empty-p text) 0)
     ((>= (aref text 0) 128)
      (let ((value (logand (aref text 0) 127))
            (index 1))
        (while (< index (length text))
          (setq value (+ (* value 256) (aref text index)))
          (setq index (1+ index)))
        value))
     (t (string-to-number text 8)))))

(defun tired--tar-pax-records (text)
  "Return the extended header records of TEXT as an alist.
Each record holds a decimal length, a space, the KEY=VALUE text and a
newline."
  (declare (pure t) (side-effect-free t))
  (let ((index 0)
        (end (length text))
        records)
    (while (< index end)
      (let* ((space (cl-position ?\s text :start index))
             (length (and space
                          (string-to-number (substring text index space))))
             (stop (and length (> length 0) (+ index length))))
        (if (or (null stop) (> stop end))
            (setq index end)
          (let* ((record (substring text (1+ space) (1- stop)))
                 (equal (cl-position ?= record)))
            (when equal
              (push (cons (substring record 0 equal)
                          (substring record (1+ equal)))
                    records)))
          (setq index stop))))
    (nreverse records)))

(defun tired--tar-header-name (header)
  "Return the member name that the tar HEADER holds.
Join the ustar prefix field and the name field when the prefix holds
text."
  (declare (pure t) (side-effect-free t))
  (let ((name (tired--tar-field header 0 100))
        (prefix (tired--tar-field header 345 500)))
    (if (string-empty-p prefix) name (concat prefix "/" name))))

(defun tired--tar-plain-text (text)
  "Return TEXT without the NUL bytes that pad a tar record."
  (declare (pure t) (side-effect-free t))
  (replace-regexp-in-string "\0+" "" text))

(defun tired--tar-member-name (name)
  "Return the archive member NAME as a plain relative path, or nil.
Drop a leading dot and a trailing slash, and reject the archive root
and a name that leaves the archive."
  (declare (pure t) (side-effect-free t))
  (let ((name (replace-regexp-in-string
               "\\`\\./" "" (tired--tar-plain-text name))))
    (setq name (replace-regexp-in-string "/+\\'" "" name))
    (when (and (not (string-empty-p name))
               (not (equal name "."))
               (not (string-prefix-p "/" name))
               (not (string-match-p
                     "\\(?:\\`\\|/\\)\\.\\.\\(?:/\\|\\'\\)" name)))
      (if (multibyte-string-p name)
          name
        (decode-coding-string name 'utf-8)))))

(defun tired--tar-level (name)
  "Return the depth of the archive member NAME."
  (declare (pure t) (side-effect-free t))
  (let ((depth 0)
        (index 0))
    (while (setq index (cl-position ?/ name :start index))
      (setq depth (1+ depth))
      (setq index (1+ index)))
    depth))

(defun tired--tar-end-block-p (position)
  "Return non-nil when the block at POSITION holds no member.
An archive ends with a block of NUL bytes."
  (not (string-match-p "[^\0]"
                       (buffer-substring-no-properties
                        position (+ position tired--tar-block)))))

(defun tired--tar-entries ()
  "Return the members of the tar archive in the current buffer.
Each value is a plist with `:name', `:size', `:type', `:offset' and
`:link'.  Read the 512-byte headers, and follow the GNU long-name and
the pax extended headers that change a name, a size or a link.  The
buffer must hold the raw bytes of the archive."
  (let ((position (point-min))
        (end (point-max))
        long-name
        long-link
        pax
        entries)
    (while (and (<= (+ position tired--tar-block) end)
                (not (tired--tar-end-block-p position)))
      (let* ((header (buffer-substring-no-properties
                      position (+ position tired--tar-block)))
             (type (aref header 156))
             (size (tired--tar-number (substring header 124 136)))
             (offset (+ position tired--tar-block))
             (data-end (min end (+ offset size))))
        (pcase type
          (?L (setq long-name (buffer-substring-no-properties offset data-end)))
          (?K (setq long-link (buffer-substring-no-properties offset data-end)))
          ((or ?x ?g)
           (setq pax (append (tired--tar-pax-records
                              (buffer-substring-no-properties offset data-end))
                             pax)))
          (_
           (let* ((raw (or long-name
                           (alist-get "path" pax nil nil #'equal)
                           (tired--tar-header-name header)))
                  (name (tired--tar-member-name raw))
                  (link (tired--tar-field header 157 257))
                  (link (or long-link
                            (alist-get "linkpath" pax nil nil #'equal)
                            link))
                  (link (tired--tar-plain-text link)))
             (setq size (if-let* ((text (alist-get "size" pax nil nil #'equal)))
                          (string-to-number text)
                        size))
             (when name
               (push (list :name name
                           :size size
                           :type type
                           :offset offset
                           :link link)
                     entries))
             (setq long-name nil)
             (setq long-link nil)
             (setq pax nil))))
        (setq position (+ offset
                          (* tired--tar-block
                             (/ (+ size (1- tired--tar-block))
                                tired--tar-block))))))
    (nreverse entries)))

(defun tired--tar-member-label (entry)
  "Return the row label for the archive member ENTRY.
A directory keeps a trailing slash, and a link names its target."
  (let ((name (plist-get entry :name))
        (type (plist-get entry :type))
        (link (plist-get entry :link)))
    (concat (file-name-nondirectory name)
            (if (eq type ?5) "/" "")
            (if (and link (not (string-empty-p link)) (memq type '(?1 ?2)))
                (concat " -> " link)
              ""))))

(defun tired--tar-sections ()
  "Return the section plists of the tar archive in the current buffer.
A member row carries a synthetic ordinal as its line, because an
archive has no lines.  Its action extracts the member."
  (let ((line 0))
    (mapcar (lambda (entry)
              (let ((name (plist-get entry :name))
                    (type (plist-get entry :type)))
                (list :label (tired--tar-member-label entry)
                      :line (setq line (1+ line))
                      :level (tired--tar-level name)
                      :kind (if (eq type ?5) 'directory 'file)
                      :action (cons #'tired--tar-open-member (list name)))))
            (tired--tar-entries))))

(defun tired--tar-archive-buffer (path)
  "Return a new buffer that holds the raw bytes of the archive at PATH.
`insert-file-contents' decompresses a compressed archive, because
`jka-compr' handles the compressed suffix."
  (with-current-buffer (generate-new-buffer " *tired-tar*" t)
    (let ((coding-system-for-read 'no-conversion))
      (insert-file-contents path))
    (set-buffer-multibyte nil)
    (current-buffer)))

(defun tired--tar-extract (path member)
  "Write the archive member MEMBER of PATH to a new temporary file.
Return the file name.  Signal a user error when the archive holds no
such member, or when the member is a directory or a link."
  (let ((buffer (tired--tar-archive-buffer path)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((entry (seq-find (lambda (item)
                                   (equal (plist-get item :name) member))
                                 (tired--tar-entries))))
            (cond
             ((null entry)
              (user-error "No member %s in %s" member path))
             ((eq (plist-get entry :type) ?5)
              (user-error "Member %s is a directory" member))
             ((memq (plist-get entry :type) '(?1 ?2))
              (user-error "Member %s is a link" member))
             (t
              (let* ((offset (plist-get entry :offset))
                     (file (expand-file-name
                            (file-name-nondirectory member)
                            (make-temp-file "tired-tar-" t))))
                (let ((coding-system-for-write 'no-conversion))
                  (write-region offset (+ offset (plist-get entry :size))
                                file nil 'silent))
                file)))))
      (kill-buffer buffer))))

(defun tired--tar-open-member (section member &optional other-window)
  "Visit MEMBER of the archive that SECTION belongs to.
Extract the member to a temporary file first.  OTHER-WINDOW shows the
file in another window."
  (let ((file (tired--tar-extract (tired-section-path section) member)))
    (if other-window
        (find-file-other-window file)
      (find-file file))))

(defun tired-file-sections-tar (_path)
  "Return the members of the current tar buffer as section plists.
The buffer already holds the file, so the handler ignores PATH.
Emacs decompresses a `.tar.gz' or a `.tar.zst' archive before this
call, so one parser serves every suffix.  The handler reads the raw
bytes, because a tar header holds NUL bytes.  Return nil when the
buffer holds no tar member."
  (set-buffer-multibyte nil)
  (tired--tar-sections))

(provide 'tired-sections)

;;; tired-sections.el ends here
