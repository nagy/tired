;;; tired-tests-core.el --- ERT tests for the Tired listing  -*- lexical-binding: t -*-

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

;; Tests for the listing, the selection, the faces, the sizes, the
;; redraw, the motion commands and the entry points.

;;; Code:

(require 'ert)

(require 'cl-lib)

(require 'seq)

(require 'tired-tests-fixtures)

;; The suite byte-compiles, so a `let' binding of a recentf variable
;; needs a declaration.  Without one the compiler makes the binding
;; lexical, and `recentf-add-file' writes the global value instead.
(defvar recentf-list)

(defvar recentf-mode)

(ert-deftest tired-mode-is-derived-from-tabulated-list-mode ()
  "The major mode must inherit from `tabulated-list-mode'."
  (tired-tests--with-fixture
    (tired root)
    (should (derived-mode-p 'tired-mode 'tabulated-list-mode))
    (should (equal (tired--buffer-name root) (buffer-name)))))

(ert-deftest tired-noselect-returns-buffer-without-display ()
  "`tired-noselect' returns a buffer and keeps the window layout."
  (tired-tests--with-fixture
    (let ((buffer (tired-noselect root)))
      (should (buffer-live-p buffer))
      (should (equal (tired--buffer-name root) (buffer-name buffer)))
      (should (eq 'tired-mode (buffer-local-value 'major-mode buffer)))
      (should (equal root (buffer-local-value 'default-directory buffer)))
      (should (equal root
                     (buffer-local-value 'list-buffers-directory buffer)))
      (should-not (get-buffer-window buffer)))))

(ert-deftest tired-noselect-reuses-its-buffer ()
  "Two calls for one directory return the same buffer."
  (tired-tests--with-fixture
    (should (eq (tired-noselect root) (tired-noselect root)))))

(ert-deftest tired-passes-the-display-action-to-display-buffer ()
  "`tired' hands its action to `display-buffer'."
  (tired-tests--with-fixture
    (let ((seen nil)
          (tired-display-buffer-action '(display-buffer-same-window)))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer action)
                   (push (list buffer action) seen)
                   (selected-window))))
        (tired root))
      (setq seen (nreverse seen))
      (should (equal (nth 1 (nth 0 seen)) '(display-buffer-same-window))))))

(ert-deftest tired-other-window-splits-as-dired-does ()
  "`tired-other-window' obeys the split thresholds.
`switch-to-buffer-other-window' reads `pop-up-windows', the
`split-height-threshold' and the `split-width-threshold', so the
listing opens beside the current buffer and not on a new frame."
  (tired-tests--with-fixture
    (let (shown)
      (cl-letf (((symbol-function 'switch-to-buffer-other-window)
                 (lambda (buffer) (push buffer shown) buffer)))
        (tired-other-window root))
      (should (equal shown (list (tired-noselect root)))))))

(ert-deftest tired-wrap-a-bare-action-function-in-a-list ()
  "A bare function symbol reaches `display-buffer' as a list.
`display-buffer' reads a value that is not a cons cell as a request
for another window, so a bare symbol would drop the action and add
`inhibit-same-window'."
  (tired-tests--with-fixture
    (let ((seen nil)
          (tired-display-buffer-action 'display-buffer-same-window))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (_buffer action)
                   (push action seen)
                   (selected-window))))
        (tired root))
      (should (equal (car seen) '(display-buffer-same-window))))))

(ert-deftest tired-display-buffer-action-starts-as-a-list ()
  "The display option holds a cons cell."
  (should (consp (default-value 'tired-display-buffer-action))))

(ert-deftest tired-default-action-reaches-display-buffer-as-a-list ()
  "The default action must reach `display-buffer' as a cons cell."
  (tired-tests--with-fixture
    (let (seen)
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (_buffer action)
                   (setq seen action)
                   (selected-window))))
        (tired root))
      (should (consp seen)))))

(ert-deftest tired-display-buffer-action-is-a-user-option ()
  "The display option carries a docstring and starts set."
  (should (custom-variable-p 'tired-display-buffer-action))
  (should (default-value 'tired-display-buffer-action))
  (should (stringp (documentation-property 'tired-display-buffer-action
                                           'variable-documentation))))

(ert-deftest tired-find-file-mode-toggles-find-directory-functions ()
  "`tired-find-file-mode' adds and removes the finder."
  (should-not tired-find-file-mode)
  (unwind-protect
      (progn
        (should-not (memq #'tired-noselect find-directory-functions))
        (tired-find-file-mode 1)
        (should (memq #'tired-noselect find-directory-functions))
        (tired-find-file-mode -1)
        (should-not (memq #'tired-noselect find-directory-functions)))
    (tired-find-file-mode -1)))

(ert-deftest find-file-opens-a-directory-in-tired-mode ()
  "With the mode on, `find-file' visits a directory with Tired."
  (tired-tests--with-fixture
    (unwind-protect
        (progn
          (tired-find-file-mode 1)
          (should (memq #'tired-noselect find-directory-functions))
          (with-current-buffer (find-file-noselect root)
            (should (derived-mode-p 'tired-mode))
            (should (equal root default-directory))))
      (tired-find-file-mode -1))))

(ert-deftest tired-autoload-cookies-stay-in-a-loading-entry-point ()
  "`tired.el' and `tired-evil.el' carry every `;;;###autoload' cookie.
A cookie in `tired-core' generates an autoload that loads that file
alone.  A `package.el' user then runs `tired' from the core, and the
default `tired-file-handlers' names a void section handler.
`tired-evil' may keep its cookie, because the file requires `tired'."
  (let* ((entry (locate-library "tired"))
         (directory (file-name-directory entry))
         (files (directory-files directory t "\\`tired.*\\.el\\'"))
         (allowed '("tired.el" "tired-evil.el")))
    (should (member (expand-file-name "tired.el" directory) files))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (if (member (file-name-nondirectory file) allowed)
            (when (equal (file-name-nondirectory file) "tired.el")
              (should (re-search-forward "^;;;###autoload" nil t)))
          (should-not (re-search-forward "^;;;###autoload" nil t)))))))

(ert-deftest tired-listing-puts-directories-first ()
  "Directories sort before files, and files group by extension."
  (tired-tests--with-fixture
    (tired root)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "link" "alpha.txt" "beta.txt")))))

(ert-deftest tired-entries-carry-file-attributes ()
  "Each entry records its type, size and mode."
  (tired-tests--with-fixture
    (tired root)
    (let ((sub (tired-tests--entry "sub"))
          (alpha (tired-tests--entry "alpha.txt"))
          (link (tired-tests--entry "link")))
      (should (eq 'directory (tired-entry-type sub)))
      (should (tired-entry-dirp sub))
      (should (eq 'file (tired-entry-type alpha)))
      (should (= 3 (tired-entry-size alpha)))
      (should (string-prefix-p "-" (tired-entry-mode alpha)))
      (should (eq 'symlink (tired-entry-type link)))
      (should (equal "alpha.txt" (tired-entry-link link)))
      (should-not (tired-entry-dirp link)))))

(ert-deftest tired-toggle-dotfiles-hides-hidden-entries ()
  "Toggling dotfiles removes and restores hidden entries."
  (tired-tests--with-fixture
    (tired root)
    (tired-toggle-dotfiles)
    (should (equal (tired-tests--names)
                   '("sub" "link" "alpha.txt" "beta.txt")))
    (tired-toggle-dotfiles)
    (should (member ".hidden" (tired-tests--names)))))

(ert-deftest tired-hidden-regexps-remove-entries ()
  "A regexp in `tired-hidden-regexps' removes matching entries."
  (tired-tests--with-fixture
    (let ((tired-hidden-regexps '("\\.txt\\'")))
      (tired root)
      (should (equal (tired-tests--names)
                     '("sub" ".hidden" "link"))))))

(ert-deftest tired-hidden-regexps-hide-an-inserted-subtree ()
  "A hidden directory hides the children that the user inserted."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-toggle-subdir)
    (should (member "inner.txt" (tired-tests--names)))
    (let ((tired-hidden-regexps '("\\`sub\\'")))
      (tired-refresh)
      (should-not (member "sub" (tired-tests--names)))
      (should-not (member "inner.txt" (tired-tests--names))))))

(ert-deftest tired-toggle-hidden-shows-and-hides-entries ()
  "The toggle inverts the display of entries that a regexp hides."
  (tired-tests--with-fixture
    (let ((tired-hidden-regexps '("\\.txt\\'")))
      (tired root)
      (should (eq (key-binding (key-parse "~")) #'tired-toggle-hidden))
      (should-not (member "alpha.txt" (tired-tests--names)))
      (should (string-match-p "2 hidden" (tired--mode-line)))
      (tired-toggle-hidden)
      (should (member "alpha.txt" (tired-tests--names)))
      (should (string-match-p "2 hidden shown" (tired--mode-line)))
      (tired-toggle-hidden)
      (should-not (member "alpha.txt" (tired-tests--names)))
      (should (string-match-p "2 hidden" (tired--mode-line))))))

(ert-deftest tired-sort-by-column-toggles-direction ()
  "Sorting by size orders files by size and flips on repetition."
  (tired-tests--with-fixture
    (tired root)
    (tired--sort-by-column 'size)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "link" "beta.txt")))
    (tired--sort-by-column 'size)
    (should (equal (tired-tests--names)
                   '("sub" "beta.txt" "link" "alpha.txt" ".hidden")))))

(ert-deftest tired-sort-walks-the-sort-states ()
  "`tired-sort' walks `tired-sort-states' and wraps around."
  (tired-tests--with-fixture
    (tired root)
    (should (eq (tired--sort-state) 'name-asc))
    (tired-sort)
    (should (eq (tired--sort-state) 'name-desc))
    (should (equal (tired-tests--names)
                   '("sub" "alpha.txt" "beta.txt" ".hidden" "link")))
    (tired-sort)
    (should (eq (tired--sort-state) 'size-asc))
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "link" "beta.txt")))
    (tired-sort -1)
    (should (eq (tired--sort-state) 'name-desc))
    (tired-sort -1)
    (should (eq (tired--sort-state) 'name-asc))
    (tired-sort -1)
    (should (eq (tired--sort-state) 'modified-desc))))

(ert-deftest tired-sort-selects-a-state-by-position ()
  "A positive prefix selects a position in `tired-sort-states'."
  (tired-tests--with-fixture
    (tired root)
    (tired-sort 3)
    (should (eq (tired--sort-state) 'size-asc))
    (tired-sort 4)
    (should (eq (tired--sort-state) 'size-desc))
    (tired-sort 5)
    (should (eq (tired--sort-state) 'elements-asc))
    (tired-sort 7)
    (should (eq (tired--sort-state) 'modified-asc))
    (tired-sort 1)
    (should (eq (tired--sort-state) 'name-asc))
    (should-error (tired-sort 0))
    (should-error (tired-sort 99))))

(ert-deftest tired-sort-crosses-a-state-outside-the-list ()
  "A column that the state list leaves out gives way to the list."
  (tired-tests--with-fixture
    (tired root)
    (tired--sort-by-column 'mode)
    (should-not (tired--sort-state))
    (tired-sort)
    (should (eq (tired--sort-state) 'name-asc))
    (tired--sort-by-column 'mode)
    (tired-sort -1)
    (should (eq (tired--sort-state) 'modified-desc))))

(ert-deftest tired-sort-key-cycles-the-states ()
  "The mode map puts the sort cycling on `>' alone."
  (should (eq (lookup-key tired-mode-map ">") #'tired-sort))
  ;; `<' falls back to the motion of `special-mode-map'.
  (should (eq (lookup-key tired-mode-map "<")
              (lookup-key special-mode-map "<"))))

(ert-deftest tired-sort-by-name-keeps-directories-first ()
  "The name sort keeps directories first in both directions."
  (tired-tests--with-fixture
    (tired root)
    (tired--sort-by-column 'name)
    (should (equal (car (tired-tests--names)) "sub"))
    (tired--sort-by-column 'name)
    (should (equal (car (tired-tests--names)) "sub"))))

(ert-deftest tired-name-sort-groups-files-by-extension ()
  "`tired-sort-by-extension' groups files by extension, then by name.
A name without an extension leads the file group, a dotfile counts
as extensionless, and an upper-case extension joins its lower-case
twin.  The option nil keeps the plain name order."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* a\n")
    (tired-tests--write "alpha.TXT" "x")
    (tired root)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "link" "notes.org" "alpha.TXT"
                     "alpha.txt" "beta.txt")))
    (let ((tired-sort-by-extension nil))
      (tired-refresh)
      (should (equal (tired-tests--names)
                     '("sub" ".hidden" "alpha.TXT" "alpha.txt"
                       "beta.txt" "link" "notes.org"))))))

(ert-deftest tired-name-sort-keeps-a-collapsed-chain-in-its-group ()
  "The name key reads the directory, so a leaf extension moves no row.
The chain row stays in the directory group and keeps the name place
of its directory, because the leaf name must not regroup it."
  (tired-tests--with-fixture
    (let ((chain (expand-file-name "chain/a" root)))
      (make-directory chain t)
      (with-temp-file (expand-file-name "leaf.zzz" chain)
        (insert "x")))
    (tired root)
    (should (equal (seq-take (tired-tests--names) 2)
                   '("chain/a/leaf.zzz" "sub")))))

(ert-deftest tired-sort-by-modified-follows-a-collapsed-leaf ()
  "A collapsed row sorts by the time that its row prints.
The top directory takes the opposite time, so the leaf decides."
  (tired-tests--with-fixture
    (let ((base 1600000000))
      (dolist (spec '(("chain-old" 9000 100) ("chain-new" 0 700)))
        (let* ((top (expand-file-name (car spec) root))
               (leaf (expand-file-name "a/b/leaf.txt" top)))
          (make-directory (file-name-directory leaf) t)
          (with-temp-file leaf (insert "x"))
          (set-file-times leaf
                          (seconds-to-time (+ base (nth 2 spec))))
          (set-file-times top
                          (seconds-to-time (+ base (nth 1 spec)))))))
    (tired root)
    (tired--sort-by-column 'modified)
    (should (equal (seq-filter (lambda (name)
                                 (string-prefix-p "chain" name))
                               (tired-tests--names))
                   '("chain-old/a/b/leaf.txt" "chain-new/a/b/leaf.txt")))))

(ert-deftest tired-sort-by-size-follows-the-printed-directory-total ()
  "A directory sorts by the total that its size cell shows.
Both temporary directories hold one entry, so a sort on the raw
inode size ties and falls back to the name, which puts `big' first."
  (tired-tests--with-fixture
    (let ((small (expand-file-name "small" root))
          (big (expand-file-name "big" root)))
      (make-directory small t)
      (make-directory big t)
      (with-temp-file (expand-file-name "s.bin" small)
        (insert (make-string 10 ?s)))
      (with-temp-file (expand-file-name "b.bin" big)
        (insert (make-string 5000 ?b))))
    (let ((tired-directory-size t)
          (tired-collapse-single-child nil))
      (tired root)
      (tired-tests--flush-sizes)
      (tired--sort-by-column 'size)
      (let ((names (tired-tests--names)))
        (should (equal (tired--size-cell (tired-tests--entry "small"))
                       "10"))
        (should (< (seq-position names "small")
                   (seq-position names "big")))))))

(ert-deftest tired-group-directories-nil-interleaves-directories ()
  "With `tired-group-directories' nil, one order holds every row.
The option nil lets a file sit between two directories, the way
`dired' sorts by time."
  (tired-tests--with-fixture
    (let ((base 1600000000))
      (dolist (spec '(("alpha.txt" 30) (".hidden" 10)
                      ("sub" 20) ("beta.txt" 40)))
        (set-file-times (expand-file-name (car spec) root)
                        (seconds-to-time (+ base (cadr spec))))))
    (tired root)
    (tired--sort-by-column 'modified)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "beta.txt" "link")))
    (let ((tired-group-directories nil))
      (tired-refresh)
      (should (equal (tired-tests--names)
                     '(".hidden" "sub" "alpha.txt" "beta.txt"
                       "link"))))))

(ert-deftest tired-header-click-sorts-by-a-column ()
  "A click on a header label sorts the listing by its column."
  (tired-tests--with-fixture
    (tired root)
    (should (eq tired--sort-key 'name))
    (tired-tests--click-header "Size")
    (should (eq tired--sort-key 'size))
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "alpha.txt" "link" "beta.txt")))
    (tired-tests--click-header "Size")
    (should tired--sort-flip)
    (should (equal (tired-tests--names)
                   '("sub" "beta.txt" "link" "alpha.txt" ".hidden")))))

(ert-deftest tired-header-click-keeps-the-sort-indicator ()
  "The label of the sort column carries the arrow and a key map."
  (tired-tests--with-fixture
    (tired root)
    (let ((asc (format "Name %c" tabulated-list-gui-sort-indicator-asc))
          (desc (format "Name %c" tabulated-list-gui-sort-indicator-desc))
          (header nil))
      (setq header (tired-tests--header-string))
      (should (string-match-p (regexp-quote asc) header))
      (tired-tests--click-header "Modified")
      (setq header (tired-tests--header-string))
      (should (string-match-p
               (regexp-quote (format "Modified %c"
                                     tabulated-list-gui-sort-indicator-asc))
               header))
      (should-not (string-match-p (regexp-quote desc) header))
      (should-not (string-match-p (regexp-quote asc) header))
      (tired--sort-by-column 'name)
      (tired--sort-by-column 'name)
      (should (string-match-p
               (regexp-quote (format "Name %c"
                                     tabulated-list-gui-sort-indicator-desc))
               (tired-tests--header-string))))))

(ert-deftest tired-header-indicator-follows-the-emacs-options ()
  "A user setting of the tabulated-list indicators reaches the header.
The two options are the ones that `tabulated-list-mode' itself reads
for its own header line."
  (tired-tests--with-fixture
    (let ((tabulated-list-gui-sort-indicator-asc ?A)
          (tabulated-list-gui-sort-indicator-desc ?D))
      (tired root)
      (should (string-match-p "Name A" (tired-tests--header-string)))
      (tired--sort-by-column 'size 'reverse)
      (should (string-match-p "Size D" (tired-tests--header-string))))))

(ert-deftest tired-name-column-grows-to-longest-name ()
  "The name column width follows the longest visible entry."
  (tired-tests--with-fixture
    (let ((name (make-string 30 ?n)))
      (with-temp-file (expand-file-name name) (insert "x")))
    (tired root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100)))
      (tired-refresh))
    (should (= 30 (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-name-column-keeps-minimum-width ()
  "Short names do not shrink the name column below the minimum."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100)))
      (tired-refresh))
    (should (= tired-name-column-min-width
               (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-name-column-clamps-to-window ()
  "A long name does not push the other columns off screen."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 80 ?x)) (insert "x"))
    (tired root)
    (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 80)))
      (tired-refresh))
    (should (= (- 80 tired--fixed-column-width)
               (nth 1 (aref tabulated-list-format 0))))))

(ert-deftest tired-window-size-change-resizes-name-column ()
  "A window size change updates the name column width."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 60 ?w)) (insert "x"))
    (tired root)
    (let ((width 120))
      (cl-letf (((symbol-function 'window-width) (lambda (&rest _) width)))
        (tired-refresh)
        (should (= 60 (nth 1 (aref tabulated-list-format 0))))
        (setq width 80)
        (tired--window-size-changed (selected-frame))
        (should (= (- 80 tired--fixed-column-width)
                   (nth 1 (aref tabulated-list-format 0))))))))

(ert-deftest tired-window-size-change-skips-an-unchanged-width ()
  "A size hook call with the same width redraws nothing.
The hook also runs when the echo area grows, and that growth leaves
the width of the listing untouched."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (cl-letf (((symbol-function 'tired--redraw)
               (lambda (&rest _) (error "Unexpected redraw"))))
      (tired--window-size-changed (selected-frame)))
    (should (equal "beta.txt" (tired-entry-name (tired--row-at-point))))))

(ert-deftest tired-name-column-keeps-the-window-that-shows-the-listing ()
  "A redraw sizes the column from the window that renders the listing.
The selected window can show another buffer in another frame, and its
width would restyle the columns of a buffer that it never draws."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 60 ?w)) (insert "x"))
    (tired root)
    (let ((listing (selected-window))
          (other (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer other
                               (get-buffer-create " *tired-tests-other*"))
            (select-window other)
            (cl-letf (((symbol-function 'window-width)
                       (lambda (&optional window _pixelwise)
                         (if (eq (or window (selected-window)) listing)
                             120
                           60))))
              (with-current-buffer (window-buffer listing)
                (tired-refresh)
                (should (= 60 (nth 1 (aref tabulated-list-format 0)))))))
        (select-window listing)
        (delete-window other)
        (when (get-buffer " *tired-tests-other*")
          (kill-buffer " *tired-tests-other*"))))))

(ert-deftest tired-window-size-change-ignores-a-window-without-the-listing ()
  "A size event from a window that does not decide the width repaints
nothing.  Another window of another size keeps the column that the
pinned window asked for."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name (make-string 60 ?w)) (insert "x"))
    (tired root)
    (let ((listing (selected-window))
          (other (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer other
                               (get-buffer-create " *tired-tests-other*"))
            (cl-letf (((symbol-function 'window-width)
                       (lambda (&optional window _pixelwise)
                         (if (eq (or window (selected-window)) listing)
                             120
                           60))))
              (with-current-buffer (window-buffer listing)
                (tired-refresh)
                (should (= 60 (nth 1 (aref tabulated-list-format 0))))
                (should-not (tired--width-changed-p other)))))
        (delete-window other)
        (when (get-buffer " *tired-tests-other*")
          (kill-buffer " *tired-tests-other*"))))))

(ert-deftest tired-size-redraw-reuses-the-pinned-window ()
  "The idle size pass keeps the window that rendered the listing.
The pass once read `get-buffer-window' with ALL-FRAMES set, so it took
an arbitrary window from any frame, and the column then followed the
width of that window."
  (tired-tests--with-fixture
    (tired root)
    (let ((listing (selected-window))
          (other (split-window))
          (seen 'none))
      (unwind-protect
          (progn
            (set-window-buffer other
                               (get-buffer-create " *tired-tests-other*"))
            (select-window other)
            (with-current-buffer (window-buffer listing)
              (setq tired--size-deferred t)
              (cl-letf (((symbol-function 'tired--redraw)
                         (lambda (&optional window) (setq seen window)))
                        ;; An arbitrary pick names the window that the
                        ;; old pass would have sized the column from.
                        ((symbol-function 'get-buffer-window)
                         (lambda (&rest _) other)))
                (tired--size-redraw (current-buffer))
                (should (eq seen listing)))))
        (select-window listing)
        (delete-window other)
        (when (get-buffer " *tired-tests-other*")
          (kill-buffer " *tired-tests-other*"))))))

(ert-deftest tired-filter-matches-case-insensitively ()
  "A filter keeps only matching names."
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "BETA")
    (should (equal (tired-tests--names) '("beta.txt")))
    (tired-clear-filter)
    (should (= 5 (length (tired-tests--names))))))

(ert-deftest tired-filter-command-commits-with-ret ()
  "RET in the live filter keeps the typed value."
  (tired-tests--with-fixture
    (tired root)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "BETA")))
      (tired-filter))
    (should (equal tired--filter "BETA"))
    (should (equal (tired-tests--names) '("beta.txt")))))

(ert-deftest tired-filter-command-restores-on-quit ()
  "C-g in the live filter restores the previous filter."
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "beta")
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (signal 'quit nil))))
      (tired-filter))
    (should (equal tired--filter "beta"))
    (should (equal (tired-tests--names) '("beta.txt")))))

(ert-deftest tired-filter-command-restores-point-on-quit ()
  "C-g puts point back on the row it started from."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (let ((start (point)))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _)
                   (tired--apply-filter "sub")
                   (signal 'quit nil))))
        (tired-filter))
      (should-not tired--filter)
      (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt"))
      (should (= start (point))))))

(ert-deftest tired-filter-command-applies-minibuffer-text ()
  "A keystroke applies the minibuffer text, not the buffer body."
  (tired-tests--with-fixture
    (tired root)
    (let ((origin (current-buffer))
          (tired-filter-delay 0))
      (cl-letf (((symbol-function 'minibuffer-contents)
                 (lambda () "BETA")))
        (tired--filter-changed origin))
      (should (equal tired--filter "BETA"))
      (should (equal (tired-tests--names) '("beta.txt"))))))

(ert-deftest tired-filter-command-waits-for-the-delay ()
  "A keystroke schedules one redraw instead of applying it.
A second keystroke replaces the pending redraw, so a typed word
costs one redraw and not one per character."
  (tired-tests--with-fixture
    (tired root)
    (let ((tired-filter-delay 30))
      (cl-letf (((symbol-function 'minibuffer-contents)
                 (lambda () "bet")))
        (tired--filter-changed (current-buffer)))
      (let ((first tired--filter-timer))
        (should (timerp first))
        (should-not tired--filter)
        (cl-letf (((symbol-function 'minibuffer-contents)
                   (lambda () "beta")))
          (tired--filter-changed (current-buffer)))
        (should (timerp tired--filter-timer))
        (should-not (eq first tired--filter-timer)))
      (tired--filter-flush "beta")
      (should-not tired--filter-timer)
      (should (equal tired--filter "beta")))))

(ert-deftest tired-selection-drives-targets ()
  "Selecting an entry makes it the target of file commands."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (should (equal (mapcar #'tired-entry-name (tired--selection-targets))
                   '("beta.txt")))
    (should (= 1 (length (seq-filter (lambda (overlay)
                                       (overlay-get overlay 'tired-selection))
                                     (overlays-in (point-min) (point-max))))))
    (tired-select-none)
    (should-not tired--selection)
    (should-not (seq-filter (lambda (overlay)
                              (overlay-get overlay 'tired-selection))
                            (overlays-in (point-min) (point-max))))))

(ert-deftest tired-select-all-selects-visible-entries ()
  "Selecting all covers exactly the visible entries."
  (tired-tests--with-fixture
    (tired root)
    (tired-select-all)
    (should (= 5 (length tired--selection)))
    (should (equal (sort (mapcar #'tired-entry-name (tired--selection-targets))
                         #'string<)
                   '(".hidden" "alpha.txt" "beta.txt" "link" "sub")))))

(ert-deftest tired-select-all-toggles-the-selection-off ()
  "A second select-all clears a selection that covers every visible entry."
  (tired-tests--with-fixture
    (tired root)
    (tired-select-all)
    (tired-select-all)
    (should-not tired--selection)
    (should-not (seq-filter (lambda (overlay)
                              (overlay-get overlay 'tired-selection))
                            (overlays-in (point-min) (point-max))))))

(ert-deftest tired-select-all-toggles-a-partial-selection ()
  "Selecting all inverts the visible part of a partial selection."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-select-all)
    (should (= 4 (length tired--selection)))
    (should-not (member (expand-file-name "alpha.txt" root)
                        tired--selection))))

(ert-deftest tired-select-all-keeps-a-selection-that-the-filter-hides ()
  "A hidden selected entry survives a toggle of the visible entries."
  (tired-tests--with-fixture
    (tired root)
    (tired-select-all)
    (tired-tests--goto "alpha.txt")
    (setq tired--filter "alpha")
    (tired-refresh)
    (tired-select-all)
    (should (= 4 (length tired--selection)))
    (should-not (member (expand-file-name "alpha.txt" root)
                        tired--selection))))

(ert-deftest tired-select-extension-selects-sibling-files ()
  "The command selects every visible file with the extension of point."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (call-interactively #'tired-select-extension)
    (should (equal (sort (mapcar #'tired-entry-name (tired--selection-targets))
                         #'string<)
                   '("alpha.txt" "beta.txt")))
    (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt"))))

(ert-deftest tired-select-extension-adds-to-the-selection ()
  "A second extension joins the first, and a directory stays out."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name "gamma.org" root) (insert "g"))
    (make-directory (expand-file-name "notes.org" root))
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-extension)
    (tired-tests--goto "gamma.org")
    (tired-select-extension)
    (should (equal (sort (mapcar #'tired-entry-name (tired--selection-targets))
                         #'string<)
                   '("alpha.txt" "beta.txt" "gamma.org")))
    (should (equal (tired-entry-name (tired--row-at-point)) "gamma.org"))))

(ert-deftest tired-select-extension-signals-on-an-empty-row ()
  "A listing line that holds no row signals an error."
  (tired-tests--with-fixture
    (tired root)
    (goto-char (point-max))
    (beginning-of-line)
    (should-error (tired-select-extension) :type 'user-error)))

(ert-deftest tired-copy-name-alternates-between-name-and-path ()
  "One call copies the names, the next copies the full paths.
The home directory of a path takes its abbreviation."
  (tired-tests--with-fixture
    (let ((directory-abbrev-alist
           (list (cons (concat "\\`" (regexp-quote root)) "~/"))))
      (tired root)
      (tired-tests--goto "alpha.txt")
      (tired-copy-name)
      (should (equal (current-kill 0) "alpha.txt"))
      (tired-copy-name)
      (should (equal (current-kill 0) "~/alpha.txt"))
      (tired-copy-name)
      (should (equal (current-kill 0) "alpha.txt")))))

(ert-deftest tired-copy-name-keeps-targets-on-one-line-each ()
  "A selection copies every target in the current form."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-copy-name)
    (should (equal (current-kill 0) "alpha.txt\nbeta.txt"))
    (tired-copy-name)
    (should (equal (current-kill 0)
                   (concat (abbreviate-file-name
                            (expand-file-name "alpha.txt" root))
                           "\n"
                           (abbreviate-file-name
                            (expand-file-name "beta.txt" root)))))))

(ert-deftest tired-copy-path-joins-targets ()
  "Copying paths puts one path per line on the kill ring."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-copy-path)
    (should (equal (current-kill 0)
                   (concat (expand-file-name "alpha.txt" root)
                           "\n"
                           (expand-file-name "beta.txt" root))))))

(ert-deftest tired-copy-relative-path-uses-buffer-directory ()
  "Relative copies drop the shown directory prefix."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-copy-relative-path)
    (should (equal (current-kill 0) "alpha.txt\nbeta.txt"))))

(ert-deftest tired-copy-relative-path-handles-inserted-entries ()
  "Relative copies work inside inserted sections."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (tired-copy-relative-path)
    (should (equal (current-kill 0) "sub/inner.txt"))))

(ert-deftest tired-copy-project-path-uses-project-root ()
  "Project copies are relative to the project root."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (cl-letf (((symbol-function 'tired--project-root)
               (lambda () root)))
      (tired-copy-project-path))
    (should (equal (current-kill 0) "alpha.txt"))))

(ert-deftest tired-copy-project-path-without-project-errors ()
  "Project copies signal an error outside a project."
  (tired-tests--with-fixture
    (tired root)
    (require 'project)
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) nil)))
      (should-error (tired-copy-project-path) :type 'user-error))))

(ert-deftest tired-browse-url-of-file-browses-the-targets ()
  "Browsing sends every target path to the browser."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (let (visited)
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (url &rest _) (push url visited))))
        (tired-browse-url-of-file))
      (should (equal (nreverse visited)
                     (list (expand-file-name "alpha.txt" root)
                           (expand-file-name "beta.txt" root)))))))

(ert-deftest tired-browse-url-of-file-uses-the-secondary-browser ()
  "A prefix argument selects the secondary browser."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (let (browser handlers)
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (&rest _)
                   (setq browser browse-url-browser-function)
                   (setq handlers browse-url-default-handlers))))
        (tired-browse-url-of-file t))
      (should (eq browser browse-url-secondary-browser-function))
      (should-not handlers))))

(ert-deftest tired-browse-url-of-file-browses-the-section-file ()
  "A section row browses the file that holds it."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* Intro\n")
    (tired root)
    (tired-tests--goto "notes.org")
    (tired-toggle-subdir)
    (tired-tests--goto-section "Intro")
    (let (visited)
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (url &rest _) (push url visited))))
        (tired-browse-url-of-file))
      (should (equal visited (list (expand-file-name "notes.org" root)))))))

(ert-deftest tired-find-file-visits-the-file ()
  "Opening a file entry visits that file."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-find-file)
    (should (equal (buffer-file-name) (expand-file-name "alpha.txt" root)))
    (kill-buffer (current-buffer))))

(ert-deftest tired-find-file-directory-replaces-the-listing ()
  "Opening a directory entry shows it in a Tired buffer."
  (tired-tests--with-fixture
    (tired root)
    (let ((origin (current-buffer)))
      (tired-tests--goto "sub")
      (tired-find-file)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory
                     (file-name-as-directory (expand-file-name "sub" root))))
      (tired-up-directory)
      (should (eq (current-buffer) origin)))))

(ert-deftest tired-row-carries-the-help-text ()
  "A printed row explains the mouse commands, and its name highlights."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (should (string-match-p "double-click"
                            (get-text-property (point) 'help-echo)))
    ;; The size column and the space after the mode column explain too.
    (let ((last (1- (line-end-position))))
      (should (string-match-p "mouse-2"
                              (get-text-property last 'help-echo))))
    ;; The indent belongs to the row, so a child row explains from the
    ;; left edge too.
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (should (string-match-p "mouse-2"
                            (get-text-property (line-beginning-position)
                                               'help-echo)))
    ;; The pointer highlights the name alone, so a hover shows the file
    ;; name that the row stands for.
    (let ((name (tired--name-region)))
      (should name)
      (should (eq (get-text-property (car name) 'mouse-face) 'highlight))
      (should (eq (get-text-property (1- (cdr name)) 'mouse-face) 'highlight)))
    ;; The indent, the slash and the rest of the line stay plain.
    (should-not (get-text-property (line-beginning-position) 'mouse-face))
    (should-not (get-text-property (1+ (cdr (tired--name-region)))
                                  'mouse-face))
    (should-not (text-property-not-all (1+ (cdr (tired--name-region)))
                                       (line-end-position)
                                       'mouse-face nil))))

(ert-deftest tired-mouse-click-does-not-follow-a-link ()
  "One click moves point, so a marked row is no link."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (should-not (mouse-on-link-p (list (selected-window) (point))))))

(ert-deftest tired-mouse-find-file-other-window-opens-the-clicked-row ()
  "The middle button opens the row under the pointer, not the selection."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (let* ((position (save-excursion
                       (tired-tests--goto "alpha.txt")
                       (point)))
           (event (tired-tests--click 'mouse-2 position))
           (opened nil))
      (cl-letf (((symbol-function 'tired--open-entry)
                 (lambda (row other-window)
                   (push (list (tired-entry-name row) other-window) opened))))
        (tired-mouse-find-file-other-window event))
      (should (equal opened '(("alpha.txt" t))))
      (should (equal (tired-entry-name (tired--row-at-point)) "alpha.txt"))
      (should (tired--selected-p (tired-tests--entry "beta.txt"))))))

(ert-deftest tired-mouse-toggle-toggles-the-clicked-row ()
  "A double click inserts the children of a directory and removes them."
  (tired-tests--with-fixture
    (tired root)
    (let ((event (tired-tests--click
                  'double-mouse-1
                  (save-excursion (tired-tests--goto "sub") (point)))))
      (tired-mouse-toggle event)
      (should (member "inner.txt" (tired-tests--names)))
      (should (equal (tired-entry-name (tired--row-at-point)) "sub"))
      (tired-mouse-toggle event)
      (should-not (member "inner.txt" (tired-tests--names))))))

(ert-deftest tired-mouse-commands-refuse-a-click-outside-a-row ()
  "A click below the last row signals an error instead of acting."
  (tired-tests--with-fixture
    (tired root)
    (let ((event (tired-tests--click 'mouse-2 (point-max))))
      (should-error (tired-mouse-find-file-other-window event)
                    :type 'user-error)
      (should-error (tired-mouse-toggle event) :type 'user-error))))

(ert-deftest tired-context-menu-lists-the-row-commands ()
  "A right click on a row offers the commands that act on it."
  (skip-unless (require 'mouse nil t))
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (let* ((event (tired-tests--click 'mouse-3 (point)))
           (menu (tired-context-menu (make-sparse-keymap) event)))
      (should (lookup-key menu [tired-visit]))
      (should (lookup-key menu [tired-rename]))
      (should (lookup-key menu [tired-delete]))
      (should (lookup-key menu [tired-refresh]))
      ;; The command acts on the clicked row, not on the row at point
      ;; when the menu opened.
      (tired-tests--goto "beta.txt")
      (call-interactively (lookup-key menu [tired-copy-name]))
      (should (equal (current-kill 0) "alpha.txt")))))

(ert-deftest tired-context-menu-skips-a-click-outside-a-row ()
  "A click below the last row keeps the plain Emacs menu."
  (skip-unless (require 'mouse nil t))
  (tired-tests--with-fixture
    (tired root)
    (let* ((event (tired-tests--click 'mouse-3 (point-max)))
           (menu (tired-context-menu (make-sparse-keymap) event)))
      (should-not (lookup-key menu [tired-visit]))
      (should-not (lookup-key menu [tired-refresh])))))

(ert-deftest tired-mode-adds-the-context-menu-function ()
  "A Tired buffer carries the context menu function locally."
  (skip-unless (require 'mouse nil t))
  (tired-tests--with-fixture
    (tired root)
    (should (memq #'tired-context-menu context-menu-functions))))

(ert-deftest tired-refresh-prunes-deleted-selection ()
  "Refresh drops selected entries that no longer exist."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (delete-file (expand-file-name "beta.txt" root))
    (tired-refresh)
    (should-not tired--selection)
    (should-not (member "beta.txt" (tired-tests--names)))))

(ert-deftest tired-refresh-keeps-sort-and-point ()
  "Refresh keeps the sort order and the entry at point."
  (tired-tests--with-fixture
    (tired root)
    (tired--sort-by-column 'size 'reverse)
    (tired-tests--goto "link")
    (tired-refresh)
    (should (equal (tired-entry-name (tired--row-at-point)) "link"))
    (should (eq 'size tired--sort-key))
    (should tired--sort-flip)))

(ert-deftest tired-name-cell-shows-symlink-target ()
  "The name column of a symlink shows its target."
  (tired-tests--with-fixture
    (tired root)
    (let ((cell (tired--name-cell (tired-tests--entry "link"))))
      (should (string-match-p " -> alpha\\.txt\\'" cell)))
    (should (string-suffix-p "/"
                             (tired--name-cell (tired-tests--entry "sub"))))))

(ert-deftest tired-mode-map-offers-a-menu ()
  "The mode map holds a Tired menu bar entry.
The menu names the file commands that a reader cannot find from the
key map alone."
  (let ((menu (lookup-key tired-mode-map [menu-bar tired])))
    (should (keymapp menu))
    (should (equal (cadr menu) "Tired"))
    (should (seq-some (lambda (item)
                        (and (consp item)
                             (eq (nth 3 item) 'tired-delete)))
                      (cdr menu)))))

(ert-deftest tired-command-opens-a-listing ()
  "The `tired' command opens the listing of the directory it gets."
  (tired-tests--with-fixture
    (should (commandp 'tired))
    (let ((buffer (tired (directory-file-name root))))
      (should (eq buffer (current-buffer)))
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-directory-name-cell-paints-its-slash ()
  "The slash of a directory row takes `tired-directory-suffix-face'."
  (tired-tests--with-fixture
    (tired root)
    (let ((cell (tired--name-cell (tired-tests--entry "sub"))))
      (should (string-suffix-p "/" cell))
      (should (eq 'tired-directory-suffix-face
                  (get-text-property (1- (length cell)) 'face cell)))
      (should (eq 'tired-directory-suffix-face
                  (get-text-property (1- (length cell)) 'font-lock-face cell))))))

(ert-deftest tired-faces-inherit-dired-faces ()
  "Each name face takes its look from the matching Dired face."
  (dolist (pair '((tired-directory-face . dired-directory)
                  (tired-symlink-face . dired-symlink)
                  (tired-symlink-target-face . dired-symlink-filename)
                  (tired-broken-symlink-face . dired-broken-symlink)
                  (tired-special-face . dired-special)
                  (tired-ignored-face . dired-ignored)))
    (should (memq (cdr pair)
                  (ensure-list (face-attribute (car pair) :inherit))))))

(ert-deftest tired-name-cell-fontifies-names-like-dired ()
  "Directory, symlink and special names get the Dired face mapping."
  (tired-tests--with-fixture
    (tired root)
    (should (eq 'tired-directory-face
                (tired-tests--cell-face (tired-tests--entry "sub"))))
    (should (eq 'tired-symlink-face
                (tired-tests--cell-face (tired-tests--entry "link"))))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))
    (should (eq 'tired-special-face
                (tired--name-face
                 (tired--entry-create :name "fifo" :type 'special))))))

(ert-deftest tired-size-cell-stays-empty-by-default ()
  "A directory shows no size unless `tired-directory-size' is on."
  (tired-tests--with-fixture
    (tired root)
    (should-not (default-value 'tired-directory-size))
    (should (equal "" (tired--size-cell (tired-tests--entry "sub"))))
    (should (equal (file-size-human-readable 3)
                   (tired--size-cell (tired-tests--entry "alpha.txt"))))))

(ert-deftest tired-size-cell-skips-a-remote-directory ()
  "A remote directory shows no total, because the walk would cross the network."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (original (symbol-function 'file-remote-p)))
      (tired root)
      (cl-letf (((symbol-function 'file-remote-p)
                 (lambda (name &rest args)
                   (if (string-prefix-p "/ssh:" name)
                       "/ssh:"
                     (apply original name args)))))
        (should (equal ""
                       (tired--size-cell
                        (tired--entry-create :name "sub"
                                             :path "/ssh:host:/tmp/sub"
                                             :type 'directory
                                             :dirp t))))
        (should-not (tired--queue-job
                     'size (tired--size-key "/ssh:host:/tmp/sub")))
        (should (tired--queue-job
                 'size (tired--size-key (expand-file-name "sub" root))))))))

(ert-deftest tired--size-excluded-p-matches-the-absolute-name ()
  "An exclude rule matches the absolute name with and without a slash.
A rule that ends in a slash covers a whole subtree, and a rule that
ends in a string-end anchor covers one directory alone."
  (let ((tired-directory-size-exclude '("/mnt/store/" "/tmp/one\\'")))
    (should (tired--size-excluded-p "/mnt/store"))
    (should (tired--size-excluded-p "/mnt/store/"))
    (should (tired--size-excluded-p "/mnt/store/deep/leaf"))
    (should (tired--size-excluded-p "/tmp/one"))
    (should-not (tired--size-excluded-p "/tmp/one/deep"))
    (should-not (tired--size-excluded-p "/mnt/other"))
    (should-not (tired--size-excluded-p nil))))

(ert-deftest tired-size-cell-skips-an-excluded-directory ()
  "An excluded directory shows no total, takes no walk and adds no byte.
The walk of a parent directory leaves the whole subtree out of its
sum, so a mounted directory costs nothing even from above."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (tired-directory-size-exclude
           (list (concat (regexp-quote root) "sub/"))))
      (tired root)
      (tired-tests--flush-sizes)
      (should (equal "" (tired--size-cell (tired-tests--entry "sub"))))
      (should-not (tired--directory-total (expand-file-name "sub" root)))
      (should-not (tired--queue-job
                   'size (tired--size-key (expand-file-name "sub" root))))
      (tired--size-enqueue (tired--size-key root) root)
      (tired-tests--flush-sizes)
      ;; alpha.txt, beta.txt and .hidden alone, because the walk of the
      ;; root pushes no frame for the excluded subtree.
      (should (equal 44 (tired--directory-total root))))))

(ert-deftest tired-excluded-directory-counts-as-non-empty ()
  "An excluded directory keeps the directory face and adds no byte.
No walk reads it, so the empty-directory mark cannot know its size."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (tired-directory-size-exclude
           (list (concat (regexp-quote root) "sub/"))))
      (tired root)
      (should-not (tired--directory-empty-p (expand-file-name "sub" root)))
      (should (eq 'tired-directory-face
                  (tired-tests--cell-face (tired-tests--entry "sub"))))
      (should (zerop (tired--entry-size (tired-tests--entry "sub")))))))

(ert-deftest tired-size-cell-sums-a-directory-recursively ()
  "With `tired-directory-size' on, a directory sums its files."
  (tired-tests--with-fixture
    (let ((tired-directory-size t))
      (tired root)
      (tired-tests--flush-sizes)
      (should (equal (file-size-human-readable 9)
                     (tired--size-cell (tired-tests--entry "sub"))))
      (should (equal 9 (tired--directory-total
                        (expand-file-name "sub" root))))
      (tired--size-enqueue (tired--size-key root) root)
      (tired-tests--flush-sizes)
      (should (equal 53 (tired--directory-total root))))))

(ert-deftest tired--size-walk-reads-each-directory-once ()
  "One walk reads each nested directory once, and a second pass reads nothing."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (calls 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (tired root)
      (cl-letf (((symbol-function 'directory-files-and-attributes)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (apply original args))))
        (tired-tests--flush-sizes)
        (should (equal 9 (tired--directory-total
                          (expand-file-name "sub" root))))
        ;; The child and its grandchild, once each.  The link back to
        ;; the root stays unfollowed.
        (should (= 2 calls))
        (tired--redraw)
        (tired-tests--flush-sizes)
        (should (= 2 calls))))))

(ert-deftest tired--size-key-needs-no-truename ()
  "The size memo keys on the absolute name, not on a resolved link."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (resolved 0))
      (should (equal (directory-file-name root) (tired--size-key root)))
      (should (equal (expand-file-name "sub" root)
                     (tired--size-key (expand-file-name "sub/" root))))
      (tired root)
      (cl-letf (((symbol-function 'file-truename)
                 (lambda (&rest _) (setq resolved (1+ resolved)) 'never)))
        (tired--queue-run))
      (should (equal 9 (tired--directory-total
                        (expand-file-name "sub" root))))
      (should (= 0 resolved)))))

(ert-deftest tired-redraw-reuses-the-size-memo ()
  "A redraw after a redraw reads no directory twice."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (calls 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (tired root)
      (tired-tests--flush-sizes)
      (cl-letf (((symbol-function 'directory-files-and-attributes)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (apply original args))))
        (tired--redraw)
        (tired--redraw)
        (tired-tests--flush-sizes)
        (should (= 0 calls))))))

(ert-deftest tired-refresh-rewalks-a-young-size-total ()
  "A refresh recomputes a young total, and a plain redraw reuses it.
The refresh reads the disk, so a total that `tired-size-cache-ttl'
still covers can hide a file that arrived after its walk."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (reads 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (tired root)
      (tired-tests--flush-sizes)
      (with-temp-file (expand-file-name "sub/inner.txt")
        (insert (make-string 100 ?y)))
      (cl-letf (((symbol-function 'directory-files-and-attributes)
                 (lambda (&rest args)
                   (setq reads (1+ reads))
                   (apply original args))))
        (tired--redraw)
        (tired-tests--flush-sizes)
        (should (= 0 reads))
        (tired-refresh)
        (tired-tests--flush-sizes)
        (should (> reads 0)))
      (should (equal (file-size-human-readable 104)
                     (tired--size-cell (tired-tests--entry "sub")))))))


(ert-deftest tired-size-cache-ttl-zero-sums-every-refresh ()
  "A zero `tired-size-cache-ttl' makes each refresh walk the subtree."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (tired-size-cache-ttl 0))
      (tired root)
      (tired-tests--flush-sizes)
      (with-temp-file (expand-file-name "sub/inner.txt")
        (insert (make-string 100 ?y)))
      (tired-refresh)
      (tired-tests--flush-sizes)
      (should (equal (file-size-human-readable 104)
                     (tired--size-cell (tired-tests--entry "sub")))))))

(ert-deftest tired--size-cache-valid-p-follows-the-ttl ()
  "A total expires when its stamp falls outside the window."
  (let ((tired-size-cache-ttl 60))
    (should (tired--size-cache-valid-p (cons 1 (float-time))))
    (should-not (tired--size-cache-valid-p (cons 1 (- (float-time) 61))))
    (should-not (tired--size-cache-valid-p nil))
    (should-not (tired--size-cache-valid-p 7))))

(ert-deftest tired--size-cache-prune-drops-expired-totals ()
  "Pruning keeps the young totals and drops the expired ones."
  (let ((tired-size-cache-ttl 60))
    (puthash "/expired" (cons 5 (- (float-time) 61)) tired--size-cache)
    (puthash "/young" (cons 5 (float-time)) tired--size-cache)
    (tired--size-cache-prune)
    (should-not (gethash "/expired" tired--size-cache))
    (should (gethash "/young" tired--size-cache))))

(ert-deftest tired--size-cache-clear-drops-every-total ()
  "Clearing the table makes the next row walk the subtree again."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (sub-reads 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (cl-letf (((symbol-function 'directory-files-and-attributes)
                 (lambda (directory &rest args)
                   (when (equal (directory-file-name directory)
                                (expand-file-name "sub" root))
                     (setq sub-reads (1+ sub-reads)))
                   (apply original directory args))))
        (tired root)
        (tired-tests--flush-sizes)
        (should (= 1 sub-reads))
        (tired--size-cache-clear)
        (tired--redraw)
        (tired-tests--flush-sizes)
        (should (= 2 sub-reads))))))

;;; Persistent directories

(ert-deftest tired--persistent-p-matches-a-subtree-rule ()
  "A rule that ends in a slash covers every directory below a mount."
  (let ((tired-persistent-directories '("/nix/store/")))
    (should (tired--persistent-p "/nix/store"))
    (should (tired--persistent-p "/nix/store/abc/bin"))
    (should-not (tired--persistent-p "/home/user/store"))
    (should-not (tired--persistent-p nil)))
  (let ((tired-persistent-directories '("/nix/store/abc\\'")))
    (should (tired--persistent-p "/nix/store/abc"))
    (should-not (tired--persistent-p "/nix/store/abc/bin")))
  (let ((tired-persistent-directories nil))
    (should-not (tired--persistent-p "/nix/store"))))

(ert-deftest tired--size-store-keeps-a-persistent-total ()
  "A walk under a rule stores into the permanent table."
  (tired-tests--with-fixture
    (let ((tired-persistent-directories
           (list (concat "\\`" (regexp-quote root)))))
      (tired--size-store (tired--size-key root) 7 (tired--size-walk-create))
      (should (gethash (tired--size-key root) tired--size-cache-permanent))
      (should-not (gethash (tired--size-key root) tired--size-cache))
      (should (equal 7 (tired--directory-total root))))))

(ert-deftest tired--size-cache-prune-keeps-a-persistent-total ()
  "The permanent table ignores the cache window."
  (tired-tests--with-fixture
    (let ((tired-size-cache-ttl 60)
          (tired-persistent-directories '("/kept/"))
          (tired--size-cache-rules '("/kept/")))
      (puthash "/kept/a" (cons 5 (- (float-time) 61))
               tired--size-cache-permanent)
      (puthash "/cold" (cons 5 (- (float-time) 61)) tired--size-cache)
      (tired--size-cache-prune)
      (should (gethash "/kept/a" tired--size-cache-permanent))
      (should-not (gethash "/cold" tired--size-cache)))))

(ert-deftest tired--size-cache-prune-flushes-on-a-rule-change ()
  "A changed rule empties the permanent table once."
  (tired-tests--with-fixture
    (let ((tired-persistent-directories '("/nix/store/")))
      (puthash "/nix/store/a" (cons 5 (float-time))
               tired--size-cache-permanent)
      (setq tired--size-cache-rules '("/old/"))
      (tired--size-cache-prune)
      (should (= 0 (hash-table-count tired--size-cache-permanent)))
      (should (equal tired-persistent-directories
                     tired--size-cache-rules)))))

(ert-deftest tired-refresh-walks-no-persistent-directory ()
  "A refresh reads no subtree under a rule and keeps its total.
The rule says that the content never changes, so a total that it
holds outlives a refresh and a change inside the subtree."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (tired-persistent-directories
           (list (concat "\\`" (regexp-quote root)))))
      (tired root)
      (tired-tests--flush-sizes)
      (should (gethash (tired--size-key (expand-file-name "sub" root))
                       tired--size-cache-permanent))
      (should (equal 9 (tired--directory-total
                        (expand-file-name "sub" root))))
      (with-temp-file (expand-file-name "sub/inner.txt")
        (insert (make-string 100 ?y)))
      (tired-refresh)
      (should-not (tired-tests--queued-jobs 'size))
      (tired-tests--flush-sizes)
      (should (equal 9 (tired--directory-total
                        (expand-file-name "sub" root)))))))

(ert-deftest tired-sync-watches-skips-a-persistent-directory ()
  "A path under a rule takes no watch, because no change arrives."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t)
          (tired-persistent-directories
           (list (concat "\\`" (regexp-quote root))))
          (added nil)
          (counter 0))
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (directory &rest _)
                   (push directory added)
                   (list 'fake (cl-incf counter))))
                ((symbol-function 'file-notify-rm-watch) #'ignore))
        (tired root)
        (should-not added)
        (should-not tired--watches)))))

(ert-deftest tired-clear-caches-drops-every-table ()
  "The command empties the windowed and the permanent caches."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--flush-sizes)
    (puthash "/kept" (cons 1 (float-time)) tired--size-cache-permanent)
    (puthash "/held" (list nil nil (float-time) 3)
             tired--elements-cache-permanent)
    (tired-clear-caches)
    (should (= 0 (hash-table-count tired--size-cache)))
    (should (= 0 (hash-table-count tired--size-cache-permanent)))
    (should (= 0 (hash-table-count tired--elements-cache)))
    (should (= 0 (hash-table-count tired--elements-cache-permanent)))
    (should (commandp #'tired-clear-caches))
    (should-not (where-is-internal #'tired-clear-caches tired-mode-map))))

(ert-deftest tired-size-walk-waits-for-a-window ()
  "A listing that no window shows queues no directory size walk.
Batch Emacs runs no display, so the gate stub keeps the listing
hidden."
  (tired-tests--with-fixture
    (tired-tests--with-deferred-sizes
      (let ((tired-directory-size t))
        (tired root)
        (should-not (seq-some #'tired--size-walk-job-p tired--queue-jobs))
        (should-not (tired--queue-job
                     'size (tired--size-key (expand-file-name "sub" root))))
        (should tired--size-deferred)
        (should-not (timerp tired--size-timer))
        (should (equal "" (tired--size-cell (tired-tests--entry "sub"))))))))

(ert-deftest tired-size-walk-serves-a-young-total-without-a-window ()
  "A listing that no window shows still reads a young total from the table."
  (tired-tests--with-fixture
    (tired-tests--with-deferred-sizes
      (puthash (tired--size-key root) (cons 42 (float-time)) tired--size-cache)
      (should (equal 42 (tired--directory-total root))))))

(ert-deftest tired--directory-total-reads-the-table-alone ()
  "A missing total returns nil and reads no directory."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (reads 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (tired root)
      (let ((key (tired--size-key (expand-file-name "sub" root))))
        (remhash key tired--size-cache))
      (cl-letf (((symbol-function 'directory-files-and-attributes)
                 (lambda (&rest args)
                   (setq reads (1+ reads))
                   (apply original args))))
        (should-not (tired--directory-total (expand-file-name "sub" root)))
        (should (= 0 reads))))))

(ert-deftest tired-size-budget-stops-a-pass ()
  "A spent budget leaves the walk in the queue for a later pass."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (tired-directory-size-budget 0))
      (tired root)
      (let ((key (tired--size-key (expand-file-name "sub" root))))
        (should (tired--queue-job 'size key))
        (tired--queue-run)
        (should (tired--queue-job 'size key))
        (should-not (tired--directory-total (expand-file-name "sub" root)))
        (setf (tired--job-budget (tired--queue-job 'size key)) nil)
        (tired--queue-run)
        (should-not tired--queue-jobs)
        (should (equal 9 (tired--directory-total
                          (expand-file-name "sub" root))))))))

(ert-deftest tired--size-walk-advances-one-directory-per-step ()
  "One step reads one directory, so one pass holds a bounded read."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (reads 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (tired root)
      (let ((job (tired--queue-job
                  'size (tired--size-key (expand-file-name "sub" root)))))
        (should job)
        (cl-letf (((symbol-function 'directory-files-and-attributes)
                   (lambda (&rest args)
                     (setq reads (1+ reads))
                     (apply original args))))
          (should (eq :more (tired--size-walk-advance job)))
          (should (= 1 reads))
          ;; The next step pushes the child frame and reads nothing.
          (should (eq :more (tired--size-walk-advance job)))
          (should (= 1 reads))
          (should (eq :more (tired--size-walk-advance job)))
          (should (= 2 reads))
          (should (eq :more (tired--size-walk-advance job)))
          (should (eq :done (tired--size-walk-advance job)))
          (should (= 2 reads)))))))

(ert-deftest tired-refresh-drops-a-running-size-walk ()
  "A refresh drops the walk that a stale directory started."
  (tired-tests--with-fixture
    (let ((tired-directory-size t))
      (tired root)
      (let* ((key (tired--size-key (expand-file-name "sub" root)))
             (job (tired--queue-job 'size key)))
        (should job)
        (tired-refresh)
        (should-not (memq job tired--queue-jobs))
        (should (tired--queue-job 'size key))))))

(ert-deftest tired-redraw-reads-no-directory-for-a-size ()
  "A redraw prints from the memo table alone."
  (tired-tests--with-fixture
    (let ((tired-directory-size t))
      (tired root)
      (let ((reads 0)
            (original (symbol-function 'directory-files-and-attributes)))
        (cl-letf (((symbol-function 'directory-files-and-attributes)
                   (lambda (&rest args)
                     (setq reads (1+ reads))
                     (apply original args))))
          (tired--redraw)
          (should (= 0 reads)))))))

(ert-deftest tired-redraw-defers-a-walk-past-its-budget ()
  "A zero budget leaves the size cell of every directory empty."
  (tired-tests--with-fixture
    (let ((tired-directory-size t)
          (tired-directory-size-budget 0))
      (tired root)
      (tired--queue-run)
      (should-not (gethash (tired--size-key (expand-file-name "sub" root))
                           tired--size-cache))
      (should (equal "" (tired--size-cell (tired-tests--entry "sub")))))))

(ert-deftest tired-empty-directory-mark-waits-for-a-window ()
  "A deferred walk keeps the plain directory face and no byte total."
  (tired-tests--with-fixture
    (tired-tests--with-deferred-sizes
      (make-directory (expand-file-name "hollow" root))
      (tired root)
      (should (eq 'tired-directory-face
                  (tired-tests--cell-face (tired-tests--entry "hollow"))))
      (should (zerop (tired--entry-size (tired-tests--entry "hollow")))))))

(ert-deftest tired-window-buffer-changed-schedules-the-size-walk ()
  "A window that starts to show the listing schedules the deferred walk.
Batch Emacs runs no display, so the test calls the hook itself."
  (tired-tests--with-fixture
    (tired-tests--with-deferred-sizes
      (let ((tired-directory-size t))
        (tired root)
        (should tired--size-deferred)
        (let ((tired-tests--window-shown t))
          (tired--window-buffer-changed (selected-window))
          (should (timerp tired--size-timer))
          (cancel-timer tired--size-timer)
          (setq tired--size-timer nil))))))

(ert-deftest tired-name-cell-fontifies-broken-symlink ()
  "A link that does not resolve gets the broken symlink face."
  (tired-tests--with-fixture
    (make-symbolic-link "missing.txt" (expand-file-name "dead"))
    (tired root)
    (let ((entry (tired-tests--entry "dead"))
          (cell nil))
      (should (tired-entry-broken entry))
      (should-not (tired-entry-broken (tired-tests--entry "link")))
      (setq cell (tired--name-cell entry))
      (should (eq 'tired-broken-symlink-face (get-text-property 0 'face cell)))
      (should (eq 'tired-broken-symlink-face
                  (get-text-property (length "dead -> ") 'face cell))))))

(ert-deftest tired-name-cell-fontifies-ignored-suffix ()
  "A name that matches `completion-ignored-extensions' gets the ignored face."
  (tired-tests--with-fixture
    (with-temp-file (expand-file-name "alpha.elc") (insert "x"))
    (tired root)
    (should (eq 'tired-ignored-face
                (tired-tests--cell-face (tired-tests--entry "alpha.elc"))))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))
    (should (equal (tired--ignored-regexp) (tired--ignored-regexp)))))

(ert-deftest tired-name-cell-marks-an-empty-directory ()
  "A directory whose subtree holds no byte takes `tired-ignored-face'.
The slash follows the name, so the row dims as one run."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "hollow" root))
    (tired root)
    (tired-tests--flush-sizes)
    (let* ((entry (tired-tests--entry "hollow"))
           (cell (tired--name-cell entry)))
      (should (zerop (tired--directory-total (tired-entry-path entry))))
      (should (eq 'tired-ignored-face (get-text-property 0 'face cell)))
      (should (eq 'tired-ignored-face
                  (get-text-property 0 'font-lock-face cell)))
      (should (eq 'tired-ignored-face
                  (get-text-property (1- (length cell)) 'face cell))))
    (should (eq 'tired-directory-face
                (tired-tests--cell-face (tired-tests--entry "sub"))))))

(ert-deftest tired-name-cell-marks-a-subtree-of-empty-files ()
  "A directory that holds only empty files and empty children dims too."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "hollow/deeper" root) t)
    (with-temp-file (expand-file-name "hollow/blank.txt") nil)
    (tired root)
    (tired-tests--flush-sizes)
    (should (eq 'tired-ignored-face
                (tired-tests--cell-face (tired-tests--entry "hollow"))))))

(ert-deftest tired-name-face-marks-an-empty-directory-without-the-column ()
  "The mark does not wait for `tired-directory-size'."
  (tired-tests--with-fixture
    (let ((tired-directory-size nil))
      (make-directory (expand-file-name "hollow" root))
      (tired root)
      (tired-tests--flush-sizes)
      (should (eq 'tired-ignored-face
                  (tired-tests--cell-face (tired-tests--entry "hollow")))))))

(ert-deftest tired-refresh-recomputes-a-live-total ()
  "A refresh re-walks a shown directory, so a new file clears the dim.
A total young enough for `tired-size-cache-ttl' would otherwise
keep `tired-ignored-face' and a zero size cell until that window
ends, even though the refresh just read the new file from disk."
  (tired-tests--with-fixture
    (let ((tired-collapse-single-child nil))
      (make-directory (expand-file-name "hollow" root))
      (tired root)
      (tired-tests--flush-sizes)
      (should (zerop (tired--directory-total
                      (expand-file-name "hollow" root))))
      (should (eq 'tired-ignored-face
                  (tired-tests--printed-name-face "hollow")))
      (with-temp-file (expand-file-name "hollow/new.txt") (insert "bytes"))
      (tired-refresh)
      (tired-tests--flush-sizes)
      (should (= 5 (tired--directory-total
                    (expand-file-name "hollow" root))))
      (should (eq 'tired-directory-face
                  (tired-tests--printed-name-face "hollow"))))))

(ert-deftest tired-refresh-keeps-a-forced-walk-until-a-window-shows ()
  "A refresh of a hidden listing waits to queue its walk.
No window shows the listing, so the refresh queues nothing and the
forced walk waits for the display that follows."
  (tired-tests--with-fixture
    (tired-tests--with-deferred-sizes
      (let ((tired-collapse-single-child nil))
        (make-directory (expand-file-name "hollow" root))
        (let ((tired-tests--window-shown t))
          (tired root)
          (tired-tests--flush-sizes))
        (should (zerop (tired--directory-total
                        (expand-file-name "hollow" root))))
        (with-temp-file (expand-file-name "hollow/new.txt") (insert "bytes"))
        (tired-refresh)
        (should tired--size-forced)
        (setq tired-tests--window-shown t)
        (tired--redraw-buffer)
        (should-not tired--size-forced)
        (tired-tests--flush-sizes)
        (should (= 5 (tired--directory-total
                      (expand-file-name "hollow" root))))))))

(ert-deftest tired-name-face-keeps-a-remote-directory-plain ()
  "A remote directory keeps the directory face and costs no walk."
  (let ((reads 0)
        (original (symbol-function 'directory-files-and-attributes)))
    (cl-letf (((symbol-function 'file-remote-p)
               (lambda (&rest _) "/ssh:host:"))
              ((symbol-function 'directory-files-and-attributes)
               (lambda (&rest args)
                 (setq reads (1+ reads))
                 (apply original args))))
      (should (eq 'tired-directory-face
                  (tired--name-face
                   (tired--entry-create :name "sub"
                                        :path "/ssh:host:/tmp/sub"
                                        :type 'directory
                                        :dirp t))))
      (should (= 0 reads)))))

(ert-deftest tired-name-faces-colorizes-a-matching-name ()
  "A `tired-name-faces' rule sets the name face, and a directory keeps its own."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\.txt\\'" . bold)
                              ("." . italic))))
      (tired root)
      (should (eq 'bold (tired-tests--cell-face
                         (tired-tests--entry "alpha.txt"))))
      (should (eq 'tired-directory-face
                  (tired-tests--cell-face (tired-tests--entry "sub"))))
      ;; The first matching rule wins.
      (should (eq 'bold (tired--name-face (tired-tests--entry "beta.txt")))))))

(ert-deftest tired-name-faces-accepts-a-face-list ()
  "A rule value may add attributes to a color with an anonymous face."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\.txt\\'" bold (:underline t)))))
      (tired root)
      (should (equal '(bold (:underline t))
                     (tired-tests--cell-face
                      (tired-tests--entry "alpha.txt"))))
      (should (equal '(bold (:underline t))
                     (get-text-property
                      0 'font-lock-face
                      (tired--name-cell (tired-tests--entry "alpha.txt"))))))))

(ert-deftest tired-name-faces-paints-only-a-submatch ()
  "An integer third element paints the submatch and leaves the name plain."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\(?:\\.txt\\)\\'" bold 0))))
      (tired root)
      (let ((cell (tired--name-cell (tired-tests--entry "alpha.txt"))))
        (should (equal "alpha.txt" (substring-no-properties cell)))
        ;; "alpha" stays plain.
        (should-not (get-text-property 0 'face cell))
        ;; The extension takes the color, with both name properties.
        (should (eq 'bold (get-text-property 5 'face cell)))
        (should (eq 'bold (get-text-property 5 'font-lock-face cell)))
        ;; A partial rule never paints the whole name.
        (should-not (tired--name-face (tired-tests--entry "alpha.txt")))))))

(ert-deftest tired-name-faces-later-partial-rule-wins ()
  "A later partial rule paints over an earlier one on the same text."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\(?:\\.txt\\)\\'" bold 0)
                              ("\\(?:txt\\)\\'" italic 0))))
      (tired root)
      (let ((cell (tired--name-cell (tired-tests--entry "alpha.txt"))))
        (should (eq 'bold (get-text-property 5 'face cell)))
        (should (equal '(italic bold) (get-text-property 6 'face cell)))))))

(ert-deftest tired-name-faces-partial-rule-skips-a-directory ()
  "A directory keeps its own face and no partial span."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\(?:\\.txt\\)\\'" bold 0))))
      (make-directory (expand-file-name "name.txt") t)
      (with-temp-file (expand-file-name "name.txt/keep.txt") (insert "x"))
      (tired root)
      (let ((cell (tired--name-cell (tired-tests--entry "name.txt"))))
        (should (eq 'tired-directory-face (get-text-property 0 'face cell)))
        (should (eq 'tired-directory-face (get-text-property 4 'face cell)))))))

(ert-deftest tired-name-faces-paint-the-extension-of-a-collapsed-row ()
  "A collapsed row paints the base name, never the directory chain."
  (tired-tests--with-fixture
    (let ((tired-name-faces '(("\\(?:\\.txt\\)\\'" bold 0))))
      (make-directory (expand-file-name "chain/a" root) t)
      (with-temp-file (expand-file-name "chain/a/leaf.txt" root)
        (insert "leaf"))
      (tired root)
      (let* ((row (seq-find
                   (lambda (row)
                     (equal (tired-entry-name (car row))
                            "chain/a/leaf.txt"))
                   (tired--display-rows t)))
             (entry (car row))
             (cell (tired--name-cell entry)))
        (should (tired-entry-collapsed entry))
        ;; "chain/a/" keeps the directory face.
        (should (eq 'tired-directory-face (get-text-property 0 'face cell)))
        ;; ".txt" takes the color.
        (should (eq 'bold (get-text-property 15 'face cell)))))))

(ert-deftest tired-name-face-defaults-to-nil ()
  "With no rule and no Dired face, a plain file keeps no face."
  (tired-tests--with-fixture
    (tired root)
    (should-not (default-value 'tired-name-faces))
    (should-not (tired-tests--cell-face (tired-tests--entry "alpha.txt")))))

(ert-deftest tired-name-cell-sets-both-face-properties ()
  "A name cell carries `face' and `font-lock-face', so refontification keeps it."
  (tired-tests--with-fixture
    (tired root)
    (let ((cell (tired--name-cell (tired-tests--entry "sub"))))
      (should (eq 'tired-directory-face (get-text-property 0 'face cell)))
      (should (eq 'tired-directory-face
                  (get-text-property 0 'font-lock-face cell))))))

(ert-deftest tired-file-size-cell-carries-the-size-face ()
  "The size column takes `tired-file-size' and an empty cell stays plain."
  (tired-tests--with-fixture
    (tired root)
    (let* ((entry (tired-tests--entry "alpha.txt"))
           (cell (aref (tired--row entry 0) 1)))
      (should (eq 'tired-file-size (get-text-property 0 'face cell)))
      (should (eq 'tired-file-size
                  (get-text-property 0 'font-lock-face cell)))
      (should (string= cell (tired--size-cell entry))))
    (let ((cell (aref (tired--row (tired-tests--entry "sub") 0) 1)))
      (should (equal "" cell)))))

(ert-deftest tired-date-cell-carries-the-date-face ()
  "The modification time column takes `tired-date'."
  (tired-tests--with-fixture
    (tired root)
    (let* ((entry (tired-tests--entry "alpha.txt"))
           (cell (aref (tired--row entry 0) 3)))
      (should (eq 'tired-date (get-text-property 0 'face cell)))
      (should (eq 'tired-date (get-text-property 0 'font-lock-face cell)))
      (should (string= cell (format-time-string tired-date-format
                                                (tired-entry-mtime entry)))))))

(ert-deftest tired-name-face-survives-font-lock ()
  "Font-lock refontification does not strip the directory face."
  (tired-tests--with-fixture
    (tired root)
    (setq-local font-lock-defaults
                '((("alpha\\.txt\\>" (0 'bold)))))
    (let ((noninteractive nil))
      (font-lock-mode 1))
    (unwind-protect
        (progn
          (font-lock-ensure)
          (tired-tests--goto "sub")
          (should (eq 'tired-directory-face
                      (get-text-property (point) 'font-lock-face)))
          (tired-tests--goto "alpha.txt")
          (should (eq 'bold (get-text-property (point) 'face))))
      (let ((noninteractive nil))
        (font-lock-mode -1)))))

(ert-deftest tired-jump-from-file-buffer ()
  "Jumping from a file buffer opens its directory and marks the file."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-find-file)
    (let ((file-buffer (current-buffer)))
      (unwind-protect
          (progn
            (tired-jump)
            (should (derived-mode-p 'tired-mode))
            (should (equal tired--directory root))
            (should (equal (tired-entry-name (tired--row-at-point))
                           "alpha.txt")))
        (kill-buffer file-buffer)))))

(ert-deftest tired-jump-from-tired-buffer-goes-up ()
  "Jumping from a Tired buffer opens the parent and marks the directory."
  (tired-tests--with-fixture
    (tired root)
    (let ((origin (current-buffer)))
      (tired-tests--goto "sub")
      (tired-find-file)
      (tired-jump)
      (should (eq (current-buffer) origin))
      (should (equal (tired-entry-name (tired--row-at-point)) "sub")))))

(ert-deftest tired-jump-uses-default-directory ()
  "Jumping from a buffer without a file uses `default-directory'."
  (tired-tests--with-fixture
    (with-temp-buffer
      (setq default-directory root)
      (tired-jump)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-bookmark-round-trip ()
  "A Tired bookmark records the directory and restores the buffer."
  (tired-tests--with-fixture
    (tired root)
    (let ((record (tired-bookmark-make-record)))
      (should (equal (car record) (abbreviate-file-name root)))
      (should (eq (cdr (assq 'handler record)) #'tired-bookmark-jump))
      (kill-buffer (current-buffer))
      (tired-bookmark-jump record)
      (should (derived-mode-p 'tired-mode))
      (should (equal tired--directory root)))))

(ert-deftest tired-records-the-directory-in-recentf ()
  "Opening a listing records the directory while recentf holds."
  (skip-unless (require 'recentf nil t))
  (tired-tests--with-fixture
    (let ((recentf-list nil)
          (recentf-mode t))
      (tired root)
      ;; `recentf-add-file' abbreviates the name with the home
      ;; directory, and a check build puts the home directory above
      ;; the temporary tree.  Compare the names without a trailing
      ;; slash in both forms.
      (cl-labels ((normalize (file)
                    (directory-file-name (abbreviate-file-name file))))
        (should (member (normalize root)
                        (mapcar #'normalize recentf-list)))))))

(ert-deftest tired-skips-recentf-when-the-mode-is-off ()
  "A session without recentf keeps an untouched list."
  (skip-unless (require 'recentf nil t))
  (tired-tests--with-fixture
    (let ((recentf-list nil)
          (recentf-mode nil))
      (tired root)
      (should-not recentf-list))))

(ert-deftest tired-insert-subdir-adds-indented-children ()
  "Inserting a directory shows its children below it, indented by depth."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    ;; `deep` holds one file, so it collapses into one row.
    (should (equal (tired-tests--names)
                   '("sub" "deep/leaf.txt" "loop" "inner.txt"
                     ".hidden" "link" "alpha.txt" "beta.txt")))
    (should (equal (mapcar #'cdr (tired--display-rows t))
                   '(0 1 1 1 0 0 0 0)))
    (should (string-prefix-p
             "  inner.txt"
             (aref (tired--row
                    (tired--entry-for-path
                     (expand-file-name "sub/inner.txt" root))
                    1)
                   0)))))

(ert-deftest tired-insert-subdir-nests ()
  "Inserting a child section keeps the tree order."
  (tired-tests--with-fixture
    (let ((tired-collapse-single-child nil))
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-tests--goto "deep")
      (tired-insert-subdir)
      (should (equal (tired-tests--names)
                     '("sub" "deep" "leaf.txt" "loop" "inner.txt"
                       ".hidden" "link" "alpha.txt" "beta.txt")))
      (should (equal (mapcar #'cdr (tired--display-rows t))
                     '(0 1 2 1 1 0 0 0 0))))))

(ert-deftest tired-toggle-subdir-removes-children ()
  "TAB inserts and removes one section."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-toggle-subdir)
    (should (member "inner.txt" (tired-tests--names)))
    (tired-toggle-subdir)
    (should (equal (tired-tests--names)
                   '("sub" ".hidden" "link" "alpha.txt" "beta.txt")))))

(ert-deftest tired-toggle-subdir-keeps-point-at-the-name ()
  "TAB keeps point at the start of the name of its row.
A deeply indented row must not move the cursor to the line start,
because `tired-next-line' leaves it on the name."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "sub/deep/nest" root) t)
    (tired-tests--write "sub/deep/other.txt" "other")
    (tired-tests--write "sub/deep/nest/a.txt" "a")
    (tired-tests--write "sub/deep/nest/b.txt" "b")
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "deep")
    (tired-insert-subdir)
    (tired-tests--goto "nest")
    (tired-next-line 0)
    (should (= 4 (current-column)))
    (tired-toggle-subdir)
    (should (equal "nest" (tired-entry-name (tired--row-at-point))))
    (should (= 4 (current-column)))
    (tired-toggle-subdir)
    (should (equal "nest" (tired-entry-name (tired--row-at-point))))
    (should (= 4 (current-column)))))

(ert-deftest tired-redraw-keeps-the-name-column ()
  "A redraw that a timer runs keeps point on the name of its row.
The idle size pass repaints the listing after a view command, and
`tired--goto-row' leaves point at the line start, so a deep row once
put the cursor inside the indent a moment after the toggle."
  (tired-tests--with-fixture
    (let ((tired-collapse-single-child nil))
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-tests--goto "deep")
      (tired--beginning-of-name)
      (should (= 2 (current-column)))
      (tired-tests--flush-sizes)
      (should (equal "deep" (tired-entry-name (tired--row-at-point))))
      (should (= 2 (current-column)))
      (tired-sort)
      (should (equal "deep" (tired-entry-name (tired--row-at-point))))
      (should (= 2 (current-column))))))

(ert-deftest tired-remove-subdir-drops-descendants ()
  "Removing a section drops nested inserted sections as well."
  (tired-tests--with-fixture
    (let ((tired-collapse-single-child nil))
      (tired root)
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      (tired-tests--goto "deep")
      (tired-insert-subdir)
      (tired-tests--goto "sub")
      (tired-remove-subdir)
      (should (= 0 (hash-table-count tired--inserted)))
      (should (equal (tired-tests--names)
                     '("sub" ".hidden" "link" "alpha.txt" "beta.txt"))))))

(ert-deftest tired-insert-subdir-rejects-files ()
  "Inserting a file signals a user error."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-insert-subdir) :type 'user-error)))

(ert-deftest tired-refresh-keeps-inserted-sections ()
  "Refresh reloads inserted directories and keeps the sections."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (with-temp-file (expand-file-name "sub/new.txt") (insert "new"))
    (tired-refresh)
    (should (member "new.txt" (tired-tests--names)))
    (should (tired--inserted-p (expand-file-name "sub" root)))))

(ert-deftest tired-insert-subdir-expands-symlink-directory ()
  "An inserted symlink to a directory shows its children."
  (tired-tests--with-fixture
    (let ((link (expand-file-name "dirlink" root)))
      (make-symbolic-link (expand-file-name "sub" root) link)
      (tired root)
      (tired-tests--goto "dirlink")
      (should (eq 'symlink (tired-entry-type (tired--row-at-point))))
      (tired-toggle-subdir)
      (should (member "inner.txt" (tired-tests--names)))
      (should (member "deep/leaf.txt" (tired-tests--names)))
      (should (tired--inserted-p link))
      (tired-toggle-subdir)
      (should-not (member "inner.txt" (tired-tests--names))))))

(ert-deftest tired-insert-subdir-guards-symlink-cycles ()
  "A symlink back to an ancestor does not recurse."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "loop")
    (tired-insert-subdir)
    (should (= 8 (length (tired-tests--names))))))

(ert-deftest tired-selection-targets-cover-inserted-entries ()
  "Selection and targets work inside inserted sections."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (should (equal (mapcar #'tired-entry-name (tired--selection-targets))
                   '("inner.txt")))
    (tired-select-none)
    (tired-select-all)
    (should (= 8 (length (tired--selection-targets))))))

(ert-deftest tired-region-drives-targets ()
  "The active region sets the targets when the selection is empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (should (equal (tired-tests--target-names) '("alpha.txt" "beta.txt")))
    (should-not tired--selection)))

(ert-deftest tired-region-includes-the-row-at-point ()
  "A region that ends at a line start keeps that row."
  (tired-tests--with-fixture
    (tired root)
    (transient-mark-mode 1)
    (tired-tests--goto "link")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-tests--goto "alpha.txt")
    (beginning-of-line)
    (should (equal (tired-tests--target-names) '("link" "alpha.txt")))
    (deactivate-mark)
    (tired-tests--goto "alpha.txt")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-tests--goto "link")
    (beginning-of-line)
    (should (equal (tired-tests--target-names) '("link" "alpha.txt")))))

(ert-deftest tired-region-follows-the-line-motions ()
  "A line motion extends the region to the row that it reaches.
The name motion and the plain motion both add the row at point, so
the indent of the row decides nothing."
  (tired-tests--with-fixture
    (tired root)
    (transient-mark-mode 1)
    (tired-tests--goto "link")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-next-line)
    (should (equal (tired-tests--target-names) '("link" "alpha.txt")))
    (tired-next-line)
    (should (equal (tired-tests--target-names)
                   '("link" "alpha.txt" "beta.txt")))
    (deactivate-mark)
    (tired-tests--goto "link")
    (beginning-of-line)
    (push-mark (point) t t)
    (forward-line 1)
    (should (equal (tired-tests--target-names) '("link" "alpha.txt")))))

(ert-deftest tired-region-loses-to-the-selection ()
  "An explicit selection wins over the active region."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "link")
    (tired-select-toggle)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (should (equal (tired-tests--target-names) '("link")))))

(ert-deftest tired-region-copy-path-copies-every-row ()
  "Copy acts on the region and then deactivates it."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (tired-copy-path)
    (should (equal (current-kill 0)
                   (concat (expand-file-name "alpha.txt" root)
                           "\n"
                           (expand-file-name "beta.txt" root))))
    (should-not (use-region-p))))

(ert-deftest tired-region-over-sections-targets-the-file ()
  "A region over the headings of a file reaches that file once.
The file row may lie inside the same region, and it joins once."
  (tired-tests--with-fixture
    (tired-tests--write "notes.org" "* one\n** one-a\n* two\n")
    (tired root)
    (transient-mark-mode 1)
    (tired-expand-file "notes.org")
    (tired-tests--goto-section "one")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-tests--goto-section "two")
    (beginning-of-line)
    (should (equal (tired-tests--target-names) '("notes.org")))
    (deactivate-mark)
    (tired-tests--goto "notes.org")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-tests--goto-section "two")
    (beginning-of-line)
    (should (equal (tired-tests--target-names) '("notes.org")))))

(ert-deftest tired-region-drives-insert-subdir ()
  "Insert acts on every directory that the region holds."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "extra/zeta" root) t)
    (let ((tired-collapse-single-child nil))
      (tired root)
      (tired-tests--mark-row-range "extra" "sub")
      (tired-insert-subdir)
      (should (tired--inserted-p (expand-file-name "extra" root)))
      (should (tired--inserted-p (expand-file-name "sub" root)))
      (should (member "zeta" (tired-tests--names)))
      (should (= 2 (length tired--selection))))))

(ert-deftest tired-region-drives-expand-file ()
  "Expand acts on every file with a handler in the region."
  (tired-tests--with-fixture
    (tired-tests--write "one.org" "* a\n* b\n")
    (tired-tests--write "two.org" "* c\n* d\n")
    (tired root)
    (tired-tests--mark-row-range "one.org" "two.org")
    (tired-expand-file)
    (should (tired--expanded-p (expand-file-name "one.org" root)))
    (should (tired--expanded-p (expand-file-name "two.org" root)))
    (should (member "a" (mapcar #'car (tired-tests--sections))))))

(ert-deftest tired-region-drives-toggle-subdir ()
  "Toggle expands every handled file in the region."
  (tired-tests--with-fixture
    (tired-tests--write "one.org" "* a\n* b\n")
    (tired-tests--write "two.org" "* c\n* d\n")
    (tired root)
    (tired-tests--mark-row-range "one.org" "two.org")
    (tired-toggle-subdir)
    (should (tired--expanded-p (expand-file-name "one.org" root)))
    (should (tired--expanded-p (expand-file-name "two.org" root)))))

(ert-deftest tired-select-none-clears-the-region ()
  "Clear drops both target sources, so a region never survives it."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "link" "alpha.txt")
    (should (use-region-p))
    (tired-select-none)
    (should-not (use-region-p))
    (should-not tired--selection)
    (should (equal (tired-tests--target-names) '("alpha.txt")))))

(ert-deftest tired-narrow-to-selection-accepts-a-region ()
  "Narrow reads the region when the selection stays empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (tired-narrow-to-selection)
    (should (equal (tired-tests--names) '("alpha.txt" "beta.txt")))))

(ert-deftest tired-mode-line-reports-the-region-size ()
  "The mode line gives the region the count and the size of a selection.
A directory in the region adds its whole subtree, as a selected
directory does."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--flush-sizes)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (tired--update-mode-line)
    (should (string-match-p "2 in region, 43" (tired--mode-line)))
    (deactivate-mark)
    (tired-tests--mark-row-range "sub" ".hidden")
    (tired--update-mode-line)
    (should (string-match-p "2 in region, 10" (tired--mode-line)))
    (deactivate-mark)
    (tired-tests--mark-row-range ".hidden" "beta.txt")
    (tired--update-mode-line)
    (should (string-match-p "4 in region, 53" (tired--mode-line)))))

(ert-deftest tired-redraw-restores-the-mark-by-path ()
  "Refresh and sort keep the mark on the same entry."
  (tired-tests--with-fixture
    (tired root)
    (transient-mark-mode 1)
    (tired-tests--goto "beta.txt")
    (beginning-of-line)
    (push-mark (point) t t)
    (tired-refresh)
    (should (equal (tired-entry-name (tired--row-at (mark t)))
                   "beta.txt"))
    (tired--sort-by-column 'size)
    (should (equal (tired-entry-name (tired--row-at (mark t)))
                   "beta.txt"))))

(ert-deftest tired-redraw-keeps-point-in-a-window-that-lost-selection ()
  "A redraw of a background window keeps its point.
The window size hook redraws a listing while another window holds the
selection, so the redraw reads the window point, not the buffer point,
and it puts that window point back after the reprint."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (let* ((listing (selected-window))
           (other (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer other (get-buffer-create " *tired-tests-other*"))
            (select-window other)
            (with-current-buffer (window-buffer listing)
              (tired--redraw listing)
              (should (equal "beta.txt"
                             (tired-entry-name
                              (tired--row-at (window-point listing)))))))
        (delete-window other)
        (when (get-buffer " *tired-tests-other*")
          (kill-buffer " *tired-tests-other*"))))))

(ert-deftest tired-redraw-keeps-the-window-start ()
  "A redraw keeps the scroll position of a long listing.
The reprint erases the buffer, and the erase also collapses the
display start marker, so point would land at the bottom of a window
that starts at the first line."
  (tired-tests--with-fixture
    (dotimes (index 40)
      (tired-tests--write (format "n%02d.txt" index) "x"))
    (tired root)
    (let ((window (selected-window)))
      (goto-char (point-min))
      (forward-line 9)
      (set-window-start window (point))
      (goto-char (point-min))
      (forward-line 29)
      (set-window-point window (point))
      (tired--redraw window)
      (should (= 10 (line-number-at-pos (window-start window))))
      (should (= 30 (line-number-at-pos (window-point window)))))))

(ert-deftest tired-redraw-walks-the-tree-once ()
  "A redraw builds one row list for the width pass and the print.
Before the cache, the name column width walked the tree and the
printer walked it again, so a redraw cost two walks."
  (tired-tests--with-fixture
    (tired root)
    (let ((calls 0)
          (original (symbol-function 'tired--display-rows)))
      (cl-letf (((symbol-function 'tired--display-rows)
                 (lambda (&optional visible-only)
                   (setq calls (1+ calls))
                   (funcall original visible-only))))
        (tired--redraw))
      (should (= calls 1)))))

(ert-deftest tired-mode-line-is-empty-without-state ()
  "A plain listing shows no bracket group in the mode line."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t)
          (tired-collapse-single-child t))
      (tired root)
      (should (equal "" (tired--mode-line)))
      (tired-tests--goto "alpha.txt")
      (tired-select-toggle)
      (should (string-prefix-p " [1 selected" (tired--mode-line))))))

(ert-deftest tired-mode-line-counts-hidden-entries ()
  "The mode line reports the entries that `tired-hidden-regexps' hides."
  (tired-tests--with-fixture
    (let ((tired-hidden-regexps '("\\.txt\\'")))
      (tired root)
      (should (string-match-p "2 hidden" (tired--mode-line))))))

(ert-deftest tired-mode-line-counts-the-region ()
  "The mode line reports the region when the selection is empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "link" "alpha.txt")
    (should (string-match-p "2 in region" (tired--mode-line)))
    (tired-select-toggle)
    (should-not (string-match-p "in region" (tired--mode-line)))))

(ert-deftest tired-mode-line-is-a-plain-string ()
  "The mode line data holds a string, not a `:eval' form.
Redisplay therefore formats no string and walks no tree, which the
old `:eval' element did on every frame refresh."
  (tired-tests--with-fixture
    (tired root)
    (tired-select-all)
    (should (stringp (car (last mode-line-format))))
    (should (equal (car (last mode-line-format)) (tired--mode-line)))
    (should-not (seq-some (lambda (element)
                            (and (consp element) (eq (car element) :eval)))
                          mode-line-format))))

(ert-deftest tired-mode-line-follows-a-region-change ()
  "A new region updates the cached mode line at once.
A redraw does not run for a region change, so the buffer-local
`post-command-hook' must refresh the string."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--mark-row-range "alpha.txt" "beta.txt")
    (should-not (string-match-p "in region" (car (last mode-line-format))))
    ;; Batch Emacs runs no command loop, so the test runs the hook that
    ;; the loop would run.
    (run-hooks 'post-command-hook)
    (should (string-match-p "2 in region" (car (last mode-line-format))))))

(ert-deftest tired-mode-line-escapes-a-percent-sign ()
  "A filter with a percent sign survives the mode line reader.
The reader takes one sign as the start of a substitution, so a
literal one needs two."
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "50%")
    (should (string-match-p "50%%" (car (last mode-line-format))))))

(ert-deftest tired-header-line-escapes-a-percent-sign ()
  "A filter with a percent sign survives the header line reader.
The same substitution rules apply to the header line."
  (tired-tests--with-fixture
    (tired root)
    (tired--apply-filter "50%")
    (should (string-match-p "50%%" (car header-line-format)))))

(ert-deftest tired-select-invert-flips-visible-entries ()
  "Inverting selects every visible entry that was not selected."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-select-invert)
    (should (equal (sort (mapcar #'tired-entry-name
                                 (tired--selection-targets))
                         #'string<)
                   '(".hidden" "beta.txt" "link" "sub")))))

(ert-deftest tired-selection-size-counts-a-directory-subtree ()
  "The selection size adds file sizes and each directory subtree."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--flush-sizes)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-tests--goto "sub")
    (tired-select-toggle)
    (should (= 52 (tired--selection-size)))
    (should (string-match-p "3 selected, 52" (tired--mode-line)))))

(ert-deftest tired-narrow-shows-selection-and-widens ()
  "Narrowing hides unselected entries and widening restores them."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-select-toggle)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (should (equal (tired-tests--names) '("alpha.txt" "beta.txt")))
    (should (string-match-p "narrowed" (tired--header-title)))
    (tired-widen)
    (should (= 5 (length (tired-tests--names))))))

(ert-deftest tired-narrow-keeps-ancestor-directories ()
  "A narrowed entry inside a section keeps its parent row visible."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (should (equal (tired-tests--names) '("sub" "inner.txt")))))

(ert-deftest tired-narrow-prunes-deleted-paths ()
  "Refresh drops narrowed paths that vanished and widens when empty."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "beta.txt")
    (tired-select-toggle)
    (tired-narrow-to-selection)
    (delete-file (expand-file-name "beta.txt" root))
    (tired-refresh)
    (should-not tired--narrowed)
    (should (= 4 (length (tired-tests--names))))))

(ert-deftest tired-watch-directories-follow-inserted-sections ()
  "The watch list holds the root, the insertions and the collapsed chains."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired root)
      (should (equal (tired--watch-paths)
                     (list (directory-file-name root))))
      (tired-tests--goto "sub")
      (tired-insert-subdir)
      ;; `deep` collapses into its one file, so a new sibling there
      ;; breaks the chain and needs its own watch.
      (should (equal (sort (tired--watch-paths) #'string<)
                     (sort (list (directory-file-name root)
                                 (expand-file-name "sub" root)
                                 (expand-file-name "sub/deep" root))
                           #'string<))))))

(ert-deftest tired-sync-watches-adds-and-removes ()
  "Inserted sections gain a watch and removed sections lose it."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (added nil) (removed nil) (counter 0))
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (directory _aspects _callback)
                   (push directory added)
                   (list 'fake (cl-incf counter))))
                ((symbol-function 'file-notify-rm-watch)
                 (lambda (descriptor) (push descriptor removed))))
        (tired root)
        (tired-tests--goto "sub")
        (tired-insert-subdir)
        (should (member (expand-file-name "sub" root) added))
        ;; `sub/deep` collapses, so its own watch joins the list.
        (should (member (expand-file-name "sub/deep" root) added))
        (tired-refresh)
        (should (= 3 (length added)))
        (tired-remove-subdir)
        (should (= 2 (length removed)))))))

(ert-deftest tired-kill-buffer-removes-watches ()
  "Killing a Tired buffer removes its file notification watches."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (removed nil) (counter 0))
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (&rest _) (list 'fake (cl-incf counter))))
                ((symbol-function 'file-notify-rm-watch)
                 (lambda (descriptor) (push descriptor removed))))
        (let ((buffer (tired root)))
          (should (= 1 (length tired--watches)))
          (kill-buffer buffer)
          (should (= 1 (length removed))))))))

(defmacro tired-tests--with-remote (root added &rest body)
  "Treat every path below ROOT as remote and record watches in ADDED."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'file-remote-p)
              (lambda (path &rest _) (string-prefix-p ,root path)))
             ((symbol-function 'file-notify-add-watch)
              (lambda (directory &rest _) (push directory ,added) nil)))
     ,@body))

(ert-deftest tired-auto-revert-remote-is-a-user-option ()
  "The remote watch switch starts off and carries a docstring."
  (should (custom-variable-p 'tired-auto-revert-remote))
  (should-not (default-value 'tired-auto-revert-remote))
  (should (stringp (documentation-property 'tired-auto-revert-remote
                                           'variable-documentation))))

(ert-deftest tired-sync-watches-skips-a-remote-directory ()
  "A remote directory gains no watch while the option stays nil."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t)
          (tired-auto-revert-remote nil)
          (added nil))
      (tired-tests--with-remote root added
        (tired root)
        (should-not added)
        (should-not tired--watches)))))

(ert-deftest tired-sync-watches-follows-the-remote-option ()
  "A user who opts in still gets a watch on a remote directory."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t)
          (tired-auto-revert-remote t)
          (added nil))
      (tired-tests--with-remote root added
        (tired root)
        (should (member (directory-file-name root) added))))))

(ert-deftest tired-toggle-auto-revert-reports-the-remote-state ()
  "The toggle names the state that the buffer really reaches."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t)
          (tired-auto-revert-remote nil)
          (added nil))
      (tired-tests--with-remote root added
        (tired root)
        ;; A remote directory starts without watches even though the
        ;; global option holds.
        (should-not (tired--auto-revert-enabled-p))
        (tired-toggle-auto-revert)
        (should-not tired-auto-revert)
        ;; The local flag and the remote option decide together.
        (let ((tired-auto-revert-remote t))
          (tired-toggle-auto-revert)
          (should (tired--auto-revert-enabled-p)))))))

(ert-deftest tired-remote-listing-stays-offline ()
  "A mocked remote directory costs no watch, no collapse and no size walk.
The test stubs `file-remote-p', so no TRAMP handler runs and nothing
reaches the network."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/inner" root) t)
    (with-temp-file (expand-file-name "chain/inner/only.txt") (insert "x"))
    (let ((tired-auto-revert t)
          (tired-auto-revert-remote nil)
          (tired-directory-size t)
          (added nil)
          (reads 0)
          (original (symbol-function 'directory-files-and-attributes)))
      (tired-tests--with-remote root added
        (cl-letf (((symbol-function 'directory-files-and-attributes)
                   (lambda (&rest args)
                     (setq reads (1+ reads))
                     (apply original args))))
          (tired root)
          (should-not added)
          (let ((entry (tired--entry-for-path (expand-file-name "chain" root))))
            (should-not (tired--collapsed-display-entry root entry)))
          (should (equal "" (tired--size-cell (tired-tests--entry "chain"))))
          (setq reads 0)
          (tired-tests--flush-sizes)
          (should (equal "" (tired--size-cell (tired-tests--entry "chain"))))
          (should (= 0 reads)))))))

(ert-deftest tired-file-change-coalesces-into-one-timer ()
  "A second event keeps the pending timer instead of adding another."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired root)
      (tired--file-changed nil)
      (let ((timer tired--revert-timer))
        (should (timerp timer))
        (tired--file-changed nil)
        (should (eq timer tired--revert-timer))
        (cancel-timer timer)
        (setq tired--revert-timer nil)))))

(ert-deftest tired-auto-revert-refreshes-once-and-skips-minibuffer ()
  "The timer callback refreshes, except while a minibuffer is active."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t) (calls 0))
      (tired root)
      (let ((buffer (current-buffer)))
        (cl-letf (((symbol-function 'tired-refresh)
                   (lambda () (cl-incf calls))))
          (tired--auto-revert-now buffer)
          (should (= 1 calls))
          (setq calls 0)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () t)))
            (tired--auto-revert-now buffer))
          (should (= 0 calls)))))))

(ert-deftest tired-file-change-ignores-lockfiles ()
  "Emacs lock file events do not schedule a refresh."
  (tired-tests--with-fixture
    (let ((tired-auto-revert t))
      (tired root)
      (tired--file-changed '(descriptor created "/tmp/.#alpha.txt"))
      (should-not tired--revert-timer))))

(ert-deftest tired-collapse-single-entry-chain ()
  "A chain of single-entry directories becomes one file row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt")
      (insert "abc"))
    (tired root)
    (should (equal (car (tired-tests--names)) "chain/a/b/file.txt"))
    (should-not (member "chain" (tired-tests--names)))
    (let* ((row (seq-find
                 (lambda (row)
                   (equal (tired-entry-name (car row))
                          "chain/a/b/file.txt"))
                 (tired--display-rows t)))
           (entry (car row)))
      (should (= 3 (tired-entry-size entry)))
      (should-not (tired-entry-dirp entry))
      (should (equal (tired-entry-path entry)
                     (expand-file-name "chain/a/b/file.txt" root))))
    (tired-tests--goto "chain/a/b/file.txt")
    (tired-find-file)
    (should (equal (buffer-file-name)
                   (expand-file-name "chain/a/b/file.txt" root)))
    (kill-buffer (current-buffer))))

(ert-deftest tired-collapse-requires-exactly-one-entry ()
  "A branch or an empty directory stops the chain at its own row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "branch/x" root) t)
    (with-temp-file (expand-file-name "branch/x/one.txt") (insert "1"))
    (with-temp-file (expand-file-name "branch/x/two.txt") (insert "2"))
    (make-directory (expand-file-name "empty" root))
    (tired root)
    (should (member "branch/x" (tired-tests--names)))
    (should (member "empty" (tired-tests--names)))
    (should-not (member "branch" (tired-tests--names)))
    (should-not (member "branch/x/one.txt" (tired-tests--names)))))

(ert-deftest tired-collapse-into-a-directory-leaf ()
  "A chain that ends at a branch collapses into that directory row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (tired-tests--write "chain/a/b/one.txt" "1")
    (tired-tests--write "chain/a/b/two.txt" "2")
    (tired root)
    (should (equal (car (tired-tests--names)) "chain/a/b"))
    (let ((entry (car (seq-find
                       (lambda (row)
                         (equal (tired-entry-name (car row)) "chain/a/b"))
                       (tired--display-rows t)))))
      (should (tired-entry-collapsed entry))
      (should (tired-entry-dirp entry))
      (should (equal (substring-no-properties (tired--name-cell entry))
                     "chain/a/b/")))
    (tired-tests--goto "chain/a/b")
    (tired-insert-subdir)
    (should (member "one.txt" (tired-tests--names)))
    (should (member "two.txt" (tired-tests--names)))))

(ert-deftest tired-collapse-into-an-empty-directory ()
  "A chain that ends at an empty directory collapses to that row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "solo/inner" root) t)
    (tired root)
    (should (member "solo/inner" (tired-tests--names)))
    (should-not (member "solo" (tired-tests--names)))
    (tired-tests--goto "solo/inner")
    (tired-insert-subdir)
    (should (equal (tired-tests--names)
                   '("solo/inner" "sub" ".hidden" "link" "alpha.txt"
                     "beta.txt")))))

(ert-deftest tired-collapse-stops-at-a-hidden-link ()
  "A hidden name in the middle of a chain cancels the collapse."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/.secret/b" root) t)
    (tired-tests--write "chain/.secret/b/one.txt" "1")
    (tired-tests--write "chain/.secret/b/two.txt" "2")
    (let ((tired-hidden-regexps '("^\\.secret\\'")))
      (tired root)
      (should (member "chain" (tired-tests--names)))
      (should-not (member "chain/.secret/b" (tired-tests--names)))
      ;; The chain result follows the toggle, not the first walk.
      (tired-toggle-hidden)
      (should (member "chain/.secret/b" (tired-tests--names))))))

(ert-deftest tired-collapse-hidden-final-file ()
  "A collapsed chain whose file is hidden follows the dotfile toggle."  (tired-tests--with-fixture
    (make-directory (expand-file-name "secret/a" root) t)
    (with-temp-file (expand-file-name "secret/a/.hiddenfile") (insert "h"))
    (tired root)
    (should (member "secret/a/.hiddenfile" (tired-tests--names)))
    (tired-toggle-dotfiles)
    (should-not (member "secret/a/.hiddenfile" (tired-tests--names)))))

(ert-deftest tired-collapse-skips-a-remote-directory ()
  "A remote directory keeps its own row instead of a collapsed one.
The chain walk reads one directory per level, and a remote read
costs a network round trip, so the row stays plain."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/inner" root) t)
    (tired-tests--write "chain/inner/only.txt" "x")
    (tired root)
    (let ((entry (tired--entry-for-path (expand-file-name "chain" root))))
      (should (tired--collapsed-display-entry root entry))
      (cl-letf (((symbol-function 'file-remote-p)
                 (lambda (&rest _) "/ssh:host:")))
        (should-not (tired--collapsed-display-entry root entry))))))

(ert-deftest tired-collapse-paints-the-path-and-the-file-apart ()
  "A collapsed row paints its directory part and its file part apart."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a" root) t)
    (with-temp-file (expand-file-name "chain/a/file.elc") (insert "abc"))
    (tired root)
    (let* ((row (seq-find
                 (lambda (row)
                   (equal (tired-entry-name (car row))
                          "chain/a/file.elc"))
                 (tired--display-rows t)))
           (cell (tired--name-cell (car row)))
           (file-start (length "chain/a/")))
      (should (equal (substring-no-properties cell) "chain/a/file.elc"))
      (should (eq (get-text-property 0 'face cell) 'tired-directory-face))
      (should (eq (get-text-property (1- file-start) 'face cell)
                  'tired-directory-face))
      (should (eq (get-text-property file-start 'face cell)
                  'tired-ignored-face))
      (should (eq (get-text-property file-start 'font-lock-face cell)
                  'tired-ignored-face)))))

(ert-deftest tired-toggle-collapse-shows-real-rows ()
  "C switches between the collapsed row and the directory row."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt") (insert "abc"))
    (tired root)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))
    (tired-toggle-collapse)
    (should (member "chain" (tired-tests--names)))
    (should-not (member "chain/a/b/file.txt" (tired-tests--names)))
    (should (string-match-p "no collapse" (tired--mode-line)))
    (tired-toggle-collapse)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))))

(ert-deftest tired-collapse-cache-clears-on-refresh ()
  "Refresh notices when a former chain gains a second entry."
  (tired-tests--with-fixture
    (make-directory (expand-file-name "chain/a/b" root) t)
    (with-temp-file (expand-file-name "chain/a/b/file.txt") (insert "abc"))
    (tired root)
    (should (member "chain/a/b/file.txt" (tired-tests--names)))
    (with-temp-file (expand-file-name "chain/a/b/other.txt") (insert "x"))
    (tired-refresh)
    (should (member "chain/a/b" (tired-tests--names)))
    (should-not (member "chain" (tired-tests--names)))
    (should-not (member "chain/a/b/file.txt" (tired-tests--names)))))

(ert-deftest tired-find-file-other-window-visits-the-entry ()
  "The other-window command visits the entry at point."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (tired-find-file-other-window)
    (should (equal buffer-file-name
                   (expand-file-name "alpha.txt" root)))))

(ert-deftest tired-find-file-other-window-splits-for-a-directory ()
  "A directory row splits the window the way Dired does."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (let (shown)
      (cl-letf (((symbol-function 'switch-to-buffer-other-window)
                 (lambda (buffer) (push buffer shown) buffer)))
        (tired-find-file-other-window))
      (should (equal shown
                     (list (tired-noselect (expand-file-name "sub" root))))))))

(ert-deftest tired-toggle-subdir-rejects-a-file-without-subtree ()
  "TAB on a plain file reports that no subtree exists."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should-error (tired-toggle-subdir) :type 'user-error)))

(ert-deftest tired-goto-last-entry-lands-on-the-last-row ()
  "The last command lands on the last row, not on the empty line below."
  (tired-tests--with-fixture
    (tired root)
    (goto-char (point-min))
    (tired-goto-last-entry)
    (should (tired-entry-p (tired--row-at-point)))
    (should (equal (tired-entry-name (tired--row-at-point))
                   (car (last (tired-tests--names)))))))

(ert-deftest tired-goto-last-entry-keeps-a-numeric-prefix ()
  "A count above one moves to that line, as the evil motion does."
  (tired-tests--with-fixture
    (tired root)
    (tired-goto-last-entry 2)
    (should (= 2 (line-number-at-pos)))
    (should (tired-entry-p (tired--row-at-point)))))

(ert-deftest tired-goto-last-entry-remaps-end-of-buffer ()
  "M-> reaches the last row too."
  (tired-tests--with-fixture
    (tired root)
    (should (eq (key-binding (key-parse "M->"))
                #'tired-goto-last-entry))))

(ert-deftest tired-next-line-lands-on-the-name ()
  "The line motion stops on the name, past the depth indent."
  (tired-tests--with-fixture
    (tired root)
    (tired-insert-subdir)
    (tired-tests--goto "sub")
    (tired-next-line)
    (should (equal (tired-entry-name (tired--row-at-point))
                   "deep/leaf.txt"))
    (should (= 2 (current-column)))
    (should (looking-at-p "deep/leaf\\.txt"))))

(ert-deftest tired-next-line-drops-the-column-of-the-old-row ()
  "A motion from the size column lands on the name of the next row."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (end-of-line)
    (tired-next-line)
    (should (equal (tired-entry-name (tired--row-at-point)) "beta.txt"))
    (should (= 0 (current-column)))))

(ert-deftest tired-previous-line-lands-on-the-name ()
  "The line motion up stops on the name of the row above."
  (tired-tests--with-fixture
    (tired root)
    (tired-insert-subdir)
    (tired-tests--goto "inner.txt")
    (end-of-line)
    (tired-previous-line)
    (should (equal (tired-entry-name (tired--row-at-point)) "loop"))
    (should (= 2 (current-column)))))

(ert-deftest tired-next-line-takes-a-count ()
  "A count moves that many lines and keeps the name position."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "sub")
    (tired-next-line 2)
    (should (equal (tired-entry-name (tired--row-at-point)) "link"))
    (should (= 0 (current-column)))))

(ert-deftest tired-line-motions-keep-their-keys ()
  "The listing binds the two motions, as `dired' does."
  (tired-tests--with-fixture
    (tired root)
    (should (eq (key-binding (key-parse "n")) #'tired-next-line))
    (should (eq (key-binding (key-parse "p")) #'tired-previous-line))))

(ert-deftest tired-file-sections-keep-no-key ()
  "TAB toggles the sections, so expand and collapse keep no key."
  (tired-tests--with-fixture
    (tired root)
    (should-not (eq (key-binding (key-parse "e")) #'tired-expand-file))
    (should-not (eq (key-binding (key-parse "E")) #'tired-collapse-file))
    (should (eq (key-binding (key-parse "TAB")) #'tired-toggle-subdir))))

(ert-deftest tired-thing-at-point-reads-the-row-name ()
  "A filename thing reads the path of the row under point."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (should (equal (thing-at-point 'filename t)
                   (expand-file-name "alpha.txt" root)))
    (should (equal (thing-at-point 'existing-filename t)
                   (expand-file-name "alpha.txt" root)))))

(ert-deftest tired-thing-at-point-bounds-cover-the-name ()
  "The bounds stop before the size column and before the link arrow."
  (tired-tests--with-fixture
    (tired root)
    (tired-tests--goto "alpha.txt")
    (let ((bounds (bounds-of-thing-at-point 'filename)))
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     "alpha.txt")))
    (tired-tests--goto "link")
    (let ((bounds (bounds-of-thing-at-point 'filename)))
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     "link")))
    ;; The target text after the arrow holds no name.
    (search-forward "alpha.txt")
    (should-not (tired--filename-at-point))
    ;; Neither does the mode column at the end of the line.
    (goto-char (line-end-position))
    (should-not (tired--filename-at-point))))

(ert-deftest tired-thing-at-point-follows-the-depth-indent ()
  "A nested row gives its name from the start of the name column."
  (tired-tests--with-fixture
    (tired root)
    (tired-insert-subdir)
    (tired-tests--goto "sub")
    (tired-next-line)
    (should (equal (tired-entry-name (tired--row-at-point))
                   "deep/leaf.txt"))
    (should (equal (thing-at-point 'filename t)
                   (expand-file-name "sub/deep/leaf.txt" root)))
    (let ((bounds (bounds-of-thing-at-point 'filename)))
      (should (= 2 (- (car bounds) (line-beginning-position))))
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     "deep/leaf.txt")))))

(ert-deftest tired-thing-at-point-reads-the-file-of-a-section ()
  "A section row names the file that holds it."
  (tired-tests--with-fixture
    (tired-tests--write "code.el" "(defun code-foo (a) a)\n")
    (tired root)
    (tired-tests--goto "code.el")
    (tired-toggle-subdir)
    (tired-tests--goto-section "defun code-foo")
    (forward-char (current-indentation))
    (should (equal (thing-at-point 'filename t)
                   (expand-file-name "code.el" root)))
    (let ((bounds (bounds-of-thing-at-point 'filename)))
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     "defun code-foo")))))

(provide 'tired-tests-core)

;;; tired-tests-core.el ends here
