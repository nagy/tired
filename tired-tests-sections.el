;;; tired-tests-sections.el --- ERT tests for the Tired sections  -*- lexical-binding: t -*-

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

;; Tests for the section framework and the section handlers.

;;; Code:

(require 'ert)

(require 'cl-lib)

(require 'seq)

(require 'tired-tests-fixtures)

(declare-function treesit-ready-p "treesit" (language &optional quiet))

(ert-deftest tired-hidden-regexps-hide-the-sections-of-a-file ()
  "A hidden file takes its sections out of the listing too."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (let ((tired-hidden-regexps '("notes\\.org\\'")))
      (tired-refresh)
      (should-not (member "notes.org" (tired-tests--names)))
      (should (null (tired-tests--sections))))))

(ert-deftest tired-collapse-row-expands-file-sections ()
  "A collapsed single file still expands its own sections."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (tired-tests--write "chain/a/b/notes.org" "* Intro\n** Detail\n")
    (tired root)
    (should (member "chain/a/b/notes.org" (tired-tests--names)))
    (tired-tests--goto "chain/a/b/notes.org")
    (tired-toggle-subdir)
    (should (tired--expanded-p
             (expand-file-name "chain/a/b/notes.org" root)))
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2))))
    (tired-tests--goto "chain/a/b/notes.org")
    (tired-collapse-file)
    (should-not (tired-tests--sections))))

(ert-deftest tired-file-handler-picks-the-first-matching-rule ()
  "The registry matches the absolute name and the first rule wins."
  (tired-tests--with-fixture
    (let ((tired-file-handlers
           (list (cons (concat (regexp-quote root) "alpha") #'ignore)
                 (cons "\\.txt\\'" #'identity))))
      (should (eq (tired-file-handler (expand-file-name "alpha.txt" root))
                  #'ignore))
      (should (eq (tired-file-handler (expand-file-name "beta.txt" root))
                  #'identity))
      (should-not (tired-file-handler (expand-file-name "sub" root))))))

(ert-deftest tired-expand-org-file-shows-nested-headings ()
  "TAB on an org file row shows its headings with levels as depth."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org"
                        "#+title: Notes\n\n* Intro\nBody.\n\n** Detail\nMore.\n\n* Plans\n- item\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2) ("Plans" . 1))))
    (should (tired--expanded-p (expand-file-name "notes.org" root)))
    (should (string-match-p "1 expanded" (tired--mode-line)))))

(ert-deftest tired-sections-of-an-elisp-file ()
  "An Emacs Lisp file lists its top-level forms in document order."
  (tired-tests--with-fixture
    (tired-tests--write "code.el"
                        ";;; code\n(defvar code-x 1)\n\n(defun code-foo (a) a)\n(provide 'code)\n")
    (tired root)
    (tired-tests--goto "code.el")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("defvar code-x" . 1)
                     ("defun code-foo" . 1)
                     ("provide code" . 1))))))

(ert-deftest tired-elisp-section-labels-take-mode-faces ()
  "An Emacs Lisp section label carries the faces of its source text."
  (tired-tests--with-fixture
    (tired-tests--write "code.el"
                        "(defvar code-x 1)\n(defun code-foo (a) a)\n")
    (let* ((path (expand-file-name "code.el" root))
           (sections (tired-file-sections path))
           (variable (car sections))
           (function (cadr sections)))
      (should (equal (tired-section-label variable) "defvar code-x"))
      (should (eq (get-text-property 0 'face (tired-section-label variable))
                  'font-lock-keyword-face))
      (should (eq (get-text-property 7 'face (tired-section-label variable))
                  'font-lock-variable-name-face))
      (should (eq (get-text-property 6 'face (tired-section-label function))
                  'font-lock-function-name-face))
      (let ((cell (tired--section-cell variable)))
        (should (eq (get-text-property 0 'font-lock-face cell)
                    'font-lock-keyword-face))
        (should (eq (get-text-property 0 'face cell)
                    'font-lock-keyword-face))))))

(ert-deftest tired-org-section-labels-take-mode-faces ()
  "An org heading label carries the faces of its source text."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org"
                        "* Intro\n* Body **with markup** here\n** TODO Detail :tag:\n")
    (let* ((path (expand-file-name "notes.org" root))
           (sections (tired-file-sections path))
           (first (car sections))
           (second (cadr sections))
           (third (caddr sections)))
      (should (equal (tired-section-label first) "Intro"))
      (should (eq (get-text-property 0 'face (tired-section-label first))
                  'org-level-1))
      (should (equal (tired-section-label second)
                     "Body **with markup** here"))
      (should (text-property-not-all 0 6 'face nil
                                     (tired-section-label second)))
      ;; The TODO keyword stays out of the label, and the level 2 face
      ;; follows the title.
      (should (equal (tired-section-label third) "Detail"))
      (should (eq (get-text-property 0 'face (tired-section-label third))
                  'org-level-2)))))

(ert-deftest tired-section-cell-keeps-only-the-source-faces ()
  "A section cell drops properties that belong to the source text."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* A [[file:x][link]] here\n")
    (let* ((path (expand-file-name "notes.org" root))
           (section (car (tired-file-sections path)))
           (label (tired-section-label section))
           (cell (tired--section-cell section)))
      ;; Org gives a link a key map, a mouse face and an invisible
      ;; property.  The listing row must show every character.
      (should (text-property-not-all 0 (length label) 'keymap nil label))
      (should-not (text-property-not-all 0 (length cell) 'keymap nil cell))
      (should-not (text-property-not-all 0 (length cell) 'mouse-face nil cell))
      (should-not (text-property-not-all 0 (length cell) 'invisible nil cell))
      (should (eq (get-text-property 0 'face cell) 'org-level-1))
      (should (eq (get-text-property 0 'font-lock-face cell) 'org-level-1)))))

(ert-deftest tired-rust-section-labels-take-mode-faces ()
  "A Rust item label keeps its source face over a plain kind prefix."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'rust t)))
  (tired-tests--with-fixture
    (tired-tests--write "lib.rs" "struct Config { n: u8 }\n\nfn main() {}\n")
    (let* ((path (expand-file-name "lib.rs" root))
           (sections (tired-file-sections path))
           (structure (car sections))
           (function (cadr sections))
           (cell (tired--section-cell structure)))
      (should (equal (tired-section-label structure) "struct Config"))
      (should (eq (get-text-property 7 'face (tired-section-label structure))
                  'font-lock-type-face))
      (should (eq (get-text-property 9 'face (tired-section-label function))
                  'font-lock-function-name-face))
      ;; The kind prefix carries no source face, so it takes the
      ;; section face, and the name keeps its own.
      (should (eq (get-text-property 0 'face cell) 'tired-section-face))
      (should (eq (get-text-property 0 'font-lock-face cell)
                  'tired-section-face))
      (should (eq (get-text-property 7 'face cell) 'font-lock-type-face))
      (should (eq (get-text-property 7 'font-lock-face cell)
                  'font-lock-type-face)))))

(ert-deftest tired-markdown-section-labels-take-mode-faces ()
  "A Markdown heading label keeps the face of its level."
  (skip-unless (and (require 'treesit nil t)
                    (treesit-ready-p 'markdown t)
                    (treesit-ready-p 'markdown-inline t)))
  (tired-tests--with-fixture
    (tired-tests--write "notes.md" "# Intro\n\n## Detail\n")
    (let* ((path (expand-file-name "notes.md" root))
           (sections (tired-file-sections path))
           (first (get-text-property 0 'face
                                     (tired-section-label (car sections))))
           (second (get-text-property 0 'face
                                      (tired-section-label (cadr sections)))))
      (should (equal (tired-section-label (car sections)) "Intro"))
      (should first)
      (should second)
      (should-not (equal first second)))))

(ert-deftest tired-cargo-section-labels-take-mode-faces ()
  "A Cargo row keeps the face of its key and of its version."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'toml t)))
  (tired-tests--with-fixture
    (tired-tests--write "Cargo.toml"
                        "[dependencies]\nanyhow = \"1.0\"\n")
    (let* ((path (expand-file-name "Cargo.toml" root))
           (sections (tired-file-sections path))
           (table (tired-section-label (car sections)))
           (dependency (tired-section-label (cadr sections)))
           (version (string-match "1\\.0" dependency)))
      (should (equal dependency "anyhow 1.0"))
      (should (eq (get-text-property 0 'face table) 'font-lock-type-face))
      (should (eq (get-text-property 0 'face dependency)
                  'font-lock-property-use-face))
      (should (eq (get-text-property version 'face dependency)
                  'font-lock-string-face))
      ;; The padding and the badges carry no source face, so they take
      ;; the section face.
      (should (eq (get-text-property 6 'face
                                     (tired--section-cell (cadr sections)))
                  'tired-section-face)))))

(ert-deftest tired-call-handler-does-not-ask-to-kill-its-buffer ()
  "Parsing a file must not prompt about the discarded temp buffer."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n** Detail\n")
    (let ((path (expand-file-name "notes.org" root))
          asked)
      (cl-letf* ((noninteractive nil)
                 ((symbol-function 'yes-or-no-p)
                  (lambda (&rest _) (setq asked t) t))
                 ((symbol-function 'y-or-n-p)
                  (lambda (&rest _) (setq asked t) t)))
        (tired-file-sections path))
      (should-not asked)
      (should (equal (mapcar #'tired-section-label
                             (tired-file-sections path))
                     '("Intro" "Detail"))))))

(ert-deftest tired-sections-of-a-rust-file ()
  "A Rust file lists items and nests the methods of an impl block."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'rust t)))
  (tired-tests--with-fixture
    (tired-tests--write "lib.rs"
                        "struct Config { n: u8 }\n\nimpl Config {\n    fn new() -> Self { Config { n: 0 } }\n}\n\nfn main() {}\n")
    (tired root)
    (tired-tests--goto "lib.rs")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("struct Config" . 1)
                     ("impl Config" . 1)
                     ("function new" . 2)
                     ("function main" . 1))))))

(ert-deftest tired-sections-of-a-go-file ()
  "A Go file lists declarations and indents a method under its type."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'go t)))
  (tired-tests--with-fixture
    (tired-tests--write "main.go"
                        (concat "package main\n\n"
                                "const Limit = 10\n\n"
                                "var name = \"demo\"\n\n"
                                "type Config struct {\n\tName string\n}\n\n"
                                "func (c *Config) Label() string { return c.Name }\n\n"
                                "func main() {\n\tvar local = 1\n\t_ = local\n}\n"))
    (tired root)
    (tired-tests--goto "main.go")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("const Limit" . 1)
                     ("var name" . 1)
                     ("type Config" . 1)
                     ("method (Config) Label" . 2)
                     ("function main" . 1))))))

(ert-deftest tired-go-method-declared-before-its-type-stays-flat ()
  "A method that precedes its type takes no indent from it."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'go t)))
  (tired-tests--with-fixture
    (tired-tests--write "main.go"
                        (concat "package main\n\n"
                                "func (c *Config) Label() string { return c.Name }\n\n"
                                "type Config struct {}\n"))
    (tired root)
    (tired-tests--goto "main.go")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("method (Config) Label" . 1)
                     ("type Config" . 1))))))

(ert-deftest tired-go-section-labels-take-mode-faces ()
  "A Go label keeps the face of its source name."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'go t)))
  (tired-tests--with-fixture
    (tired-tests--write "main.go" "package main\n\nfunc main() {}\n")
    (let* ((path (expand-file-name "main.go" root))
           (label (tired-section-label
                   (car (tired-file-sections path)))))
      (should (equal label "function main"))
      (should (eq (get-text-property 9 'face label)
                  'font-lock-function-name-face)))))

(ert-deftest tired-rust-constant-and-static-rows-name-their-kind ()
  "A Rust const row and a static row read apart."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'rust t)))
  (tired-tests--with-fixture
    (tired-tests--write "lib.rs"
                        "const LIMIT: u8 = 3;\n\nstatic NAME: &str = \"x\";\n")
    (let* ((path (expand-file-name "lib.rs" root))
           (sections (tired-file-sections path)))
      (should (equal (mapcar (lambda (section)
                               (substring-no-properties
                                (tired-section-label section)))
                             sections)
                     '("const LIMIT" "static NAME"))))))

(ert-deftest tired-sections-of-a-markdown-file ()
  "A Markdown file lists ATX and setext headings and skips code fences."
  (skip-unless (and (require 'treesit nil t)
                    (treesit-ready-p 'markdown t)
                    (treesit-ready-p 'markdown-inline t)))
  (tired-tests--with-fixture
    (tired-tests--write "notes.md"
                        "# Intro\n\n## Detail\n\n```sh\n# not a heading\n```\n\nClosing\n=======\n")
    (tired root)
    (tired-tests--goto "notes.md")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2) ("Closing" . 1))))))

(ert-deftest tired-sections-of-a-cargo-manifest ()
  "A Cargo manifest lists the four tables and their entries one level in."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'toml t)))
  (tired-tests--with-fixture
    (tired-tests--write "Cargo.toml"
                        (concat "[package]\nname = \"demo\"\n\n"
                                "[features]\ndefault = [\"cache\", \"svg\"]\n"
                                "cache = [\"dep:jixel\"]\n\n"
                                "[dependencies]\nanyhow = \"1.0\"\n"
                                "image = { version = \"0.25.10\", default-features = false }\n"
                                "xdg = { version = \"3.0.0\", optional = true }\n\n"
                                "[dev-dependencies]\ntempfile = \"3.27.0\"\n\n"
                                "[build-dependencies]\ncc = \"1.0\"\n\n"
                                "[patch.crates-io]\ncc = \"1.1\"\n\n"
                                "[target.'cfg(unix)'.dependencies]\nfoo = \"2.0\"\n"))
    (tired root)
    (tired-tests--goto "Cargo.toml")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("features (2)" . 1)
                     ("default  \u2192 cache, svg" . 2)
                     ("cache    \u2192 dep:jixel" . 2)
                     ("dependencies (3)" . 1)
                     ("anyhow   1.0" . 2)
                     ("image    0.25.10 [no-default]" . 2)
                     ("xdg      3.0.0   [optional]" . 2)
                     ("dev-dependencies (1)" . 1)
                     ("tempfile 3.27.0" . 2)
                     ("build-dependencies (1)" . 1)
                     ("cc       1.0" . 2))))
    (should (eq (tired-section-kind
                 (car (tired-file-sections
                       (expand-file-name "Cargo.toml" root))))
                'table))))

(ert-deftest tired-cargo-key-column-covers-every-table ()
  "Cargo rows share one key column across the four tables."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'toml t)))
  (tired-tests--with-fixture
    (tired-tests--write
     "Cargo.toml"
     (concat "[features]\nshort = [\"a\"]\n\n"
             "[dependencies]\na-much-longer-name = \"1.0\"\n"))
    (tired root)
    (tired-tests--goto "Cargo.toml")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("features (1)" . 1)
                     ("short              \u2192 a" . 2)
                     ("dependencies (1)" . 1)
                     ("a-much-longer-name 1.0" . 2))))))

(ert-deftest tired-cargo-version-column-aligns-badges ()
  "Cargo dependency badges start in one version column."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'toml t)))
  (tired-tests--with-fixture
    (tired-tests--write
     "Cargo.toml"
     (concat "[dependencies]\n"
             "a = { version = \"1.0\", optional = true }\n"
             "a-longer = { version = \"0.25.10\", optional = true, "
             "default-features = false }\n"))
    (tired root)
    (tired-tests--goto "Cargo.toml")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("dependencies (2)" . 1)
                     ("a        1.0     [optional]" . 2)
                     ("a-longer 0.25.10 [optional] [no-default]" . 2))))))

(ert-deftest tired-cargo-table-folds-its-entries ()
  "Folding a Cargo table section hides the entries below it."
  (skip-unless (and (require 'treesit nil t) (treesit-ready-p 'toml t)))
  (tired-tests--with-fixture
    (tired-tests--write "Cargo.toml"
                        "[dependencies]\nanyhow = \"1.0\"\nserde = \"1.0\"\n")
    (tired root)
    (tired-tests--goto "Cargo.toml")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("dependencies (2)" . 1)
                     ("anyhow 1.0" . 2)
                     ("serde  1.0" . 2))))
    (tired-tests--goto-section "dependencies (2)")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("dependencies (2)" . 1))))))

(ert-deftest tired-sections-of-a-sqlite-database ()
  "A SQLite file lists its tables and columns with a table action."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (tired-tests--with-fixture
    (let ((path (expand-file-name "data.sqlite" root)))
      (let ((db (sqlite-open path nil)))
        (sqlite-execute db "CREATE TABLE logs (msg TEXT)")
        (sqlite-execute db "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        (sqlite-close db))
      (tired root)
      (tired-tests--goto "data.sqlite")
      (tired-toggle-subdir)
      (should (equal (tired-tests--sections)
                     '(("logs" . 1)
                       ("msg TEXT" . 2)
                       ("users" . 1)
                       ("id INTEGER PRIMARY KEY" . 2)
                       ("name TEXT NOT NULL" . 2))))
      (let ((table (car (tired-file-sections path))))
        (should (eq (tired-section-kind table) 'table))
        (should (consp (tired-section-action table)))))))

(ert-deftest tired-sqlite-table-action-opens-sqlite-mode ()
  "RET on a table section opens the database at that table."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (tired-tests--with-fixture
    (let ((path (expand-file-name "data.sqlite" root)))
      (let ((db (sqlite-open path nil)))
        (sqlite-execute db "CREATE TABLE users (id INTEGER)")
        (sqlite-close db))
      (tired root)
      (tired-tests--goto "data.sqlite")
      (tired-toggle-subdir)
      (tired-tests--goto-section "users")
      (tired-find-file)
      (let ((buffer (get-buffer "*SQLite data.sqlite*")))
        (should buffer)
        (with-current-buffer buffer
          (should (derived-mode-p 'sqlite-mode))
          (should (looking-at "users")))
        (kill-buffer buffer)))))

(ert-deftest tired-sqlite-handler-rejects-a-non-database ()
  "A .db file that holds no database yields no sections."
  (tired-tests--with-fixture
    (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
    (tired-tests--write "junk.db" "not a database")
    (should-not (tired-file-sections (expand-file-name "junk.db" root)))))

(ert-deftest tired-find-file-section-visits-its-line ()
  "RET on a section row visits the file at the section line."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Detail")
    (tired-find-file)
    (should (equal (buffer-file-name)
                   (expand-file-name "notes.org" root)))
    ;; An org heading narrows the buffer, so widen before the line check.
    (widen)
    (should (= 3 (line-number-at-pos)))))

(ert-deftest tired-find-file-org-heading-narrows-to-its-subtree ()
  "RET on an org heading narrows the visited buffer to that subtree."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org"
                        "* Intro\nintro body\n** Detail\ndetail body\n* Plans\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Detail")
    (tired-find-file)
    (should (buffer-narrowed-p))
    (let ((text (buffer-substring-no-properties
                 (point-min) (point-max))))
      (should (string-match-p "Detail" text))
      (should (string-match-p "detail body" text))
      (should-not (string-match-p "Intro" text)))))

(ert-deftest tired-find-file-org-heading-stays-wide-when-option-off ()
  "An org heading opens wide when `tired-org-narrow-on-open' is nil."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\nintro body\n* Plans\n")
    (let ((tired-org-narrow-on-open nil))
      (tired root)
      (tired-tests--goto "notes.org")
      (tired-toggle-subdir)
      (tired-tests--goto-section "Plans")
      (tired-find-file)
      (should-not (buffer-narrowed-p))
      (should (string-match-p
               "Intro" (buffer-substring-no-properties
                        (point-min) (point-max)))))))

(ert-deftest tired-find-file-non-org-section-stays-wide ()
  "A section of a non-org file opens without narrowing."
  (tired-tests--with-fixture
    (tired-tests--write "code.el" "(defun alpha ())\n(defun beta ())\n")
    (tired root)
    (tired-tests--goto "code.el")
    (tired-toggle-subdir)
    (tired-tests--goto-section "defun beta")
    (tired-find-file)
    (should-not (buffer-narrowed-p))))

(ert-deftest tired-section-rows-are-not-selectable ()
  "A selection command refuses a section row."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (should-error (tired-select-toggle) :type 'user-error)
    (should-not tired--selection)))

(ert-deftest tired-path-commands-use-the-file-of-a-section ()
  "A section stands for its file, so the path commands reach that file."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (let ((row (tired--row-at-point))
          (path (expand-file-name "notes.org" root)))
      (should (tired-section-p row))
      (should (equal (tired--row-path row) path))
      (should (equal (tired-entry-name (car (tired--selection-targets)))
                     "notes.org")))))

(ert-deftest tired-fold-hides-the-child-sections ()
  "TAB on a section row hides its children and TAB again shows them."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n\n* Plans\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Plans" . 1))))
    (tired-toggle-subdir)
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2) ("Plans" . 1))))))

(ert-deftest tired-collapse-file-hides-the-sections ()
  "E collapses the sections that TAB expanded."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (should (tired-tests--sections))
    (tired-tests--goto "notes.org")
    (tired-collapse-file)
    (should-not (tired-tests--sections))))

(ert-deftest tired-expand-file-rejects-a-file-without-handler ()
  "A file that no rule claims reports the missing handler."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-expand-file) :type 'user-error)
    (should-not (tired--expanded-p (expand-file-name "alpha.txt" root)))))

(ert-deftest tired-section-cache-follows-modification-time ()
  "The handler runs once per modification time, not once per redraw."
  (tired-tests--with-fixture
    (tired-tests--write "alpha.txt" "abc")
    (let ((calls 0)
          (path (expand-file-name "alpha.txt" root)))
      (let ((tired-file-handlers
             (list (cons "\\.txt\\'"
                         (lambda (_path)
                           (cl-incf calls)
                           '((:label "alpha" :line 1)))))))
        (tired root)
        (tired-file-sections path)
        (tired-file-sections path)
        (should (= 1 calls))
        (set-file-times path (time-add (current-time) 60))
        (tired-file-sections path)
        (should (= 2 calls))
        (should (equal (tired-section-label (car (tired-file-sections path)))
                       "alpha"))))))

(ert-deftest tired-broken-handler-keeps-the-listing ()
  "A handler that signals an error yields no sections and no crash."
  (tired-tests--with-fixture
    (tired-tests--write "alpha.txt" "abc")
    (let ((tired-file-handlers
           (list (cons "\\.txt\\'" (lambda (_path) (error "boom"))))))
      (tired root)
      (tired-tests--goto "alpha.txt")
      (should-error (tired-expand-file) :type 'user-error)
      (should (member "alpha.txt" (tired-tests--names))))))

(ert-deftest tired-refresh-drops-a-vanished-expanded-file ()
  "Refresh forgets an expanded file that a command removed."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (let ((path (expand-file-name "notes.org" root)))
      (delete-file path)
      (tired-refresh)
      (should-not (tired--expanded-p path))
      (should-not (tired-tests--sections)))))

(ert-deftest tired-watch-paths-cover-expanded-files ()
  "An expanded file gets its own notification watch."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired-tests--write "notes.org" "* Intro\n")
      (tired root)
      (tired-tests--goto "notes.org")
      (tired-toggle-subdir)
      (should (member (expand-file-name "notes.org" root)
                      (tired--watch-paths))))))

(ert-deftest tired-redraw-keeps-point-on-a-section-row ()
  "A redraw returns point to the same section, not to the file row."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Detail")
    (tired-sort 'size)
    (should (equal (tired-section-label (tired--row-at-point)) "Detail"))))

(ert-deftest tired-filter-keeps-the-sections-of-a-visible-file ()
  "A filter on the file name keeps that file and all of its sections."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n\n** Detail\n")
    (tired-tests--write "other.org" "* Other\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto "other.org")
    (tired-toggle-subdir)
    (tired--apply-filter "notes")
    (should (equal (tired-tests--sections)
                   '(("Intro" . 1) ("Detail" . 2))))
    (should (equal (tired-tests--names) '("notes.org")))))

(provide 'tired-tests-sections)

;;; tired-tests-sections.el ends here
