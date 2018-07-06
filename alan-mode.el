;;; alan-mode.el --- Major mode for editing M-industries Alan files

;; Copyright (C) 2018 M-industries

;; Author: Paul van Dam <pvandam@m-industries.com>
;; Maintainer: Paul van Dam <pvandam@m-industries.com>
;; Version: 1.0.0
;; Created: 13 October 2017
;; URL: https://github.com/M-industries/AlanForEmacs
;; Homepage: https://alan-platform.com/
;; Keywords: alan, languages
;; Package-Requires: ((flycheck "32") (emacs "25.1") (s "1.12"))

;; MIT License

;; Copyright (c) 2017 M-industries

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.


;; This file is not part of GNU Emacs.

;;; Commentary:
;; A major mode for editing Alan files.

(require 'flycheck)
(require 'timer)
(require 'xref)
(require 's)
(require 'seq)

;;; Code:

(add-to-list 'auto-mode-alist '("\\.alan\\'" . alan-mode))

(defgroup alan nil
  "Alan mode."
  :prefix "alan-"
  :group 'tools)

(defcustom alan-xref-limit-to-project-scope t
  "Limits symbol lookup to the open buffers in project scope.
Only available when projectile is loaded, because it is based on
the function `projectile-project-root'"
  :group 'alan
  :type '(boolean))

(defcustom alan-compiler "compiler-project"
  "The alan compiler.
This one is used when the variable `alan-project-root' cannot be
resolved to an existing directory."
  :group 'alan
  :type '(string))

(defcustom alan-script "alan"
  "The alan build script file."
  :group 'alan
  :type '(string))

(defcustom alan-language-definition nil
  "The Alan language to use.
Setting this will try to use the `alan-compiler' instead of the `alan-script'."
  :group 'alan
  :safe 'stringp)
(make-variable-buffer-local 'alan-language-definition)

;;; Alan mode

(defvar-local alan-mode-font-lock-keywords
  '((("'\\([^'\n\\]\\|\\(\\\\'\\)\\|\\\\\\\)*'" . font-lock-variable-name-face))
	nil nil nil nil
	(font-lock-syntactic-face-function . alan-font-lock-syntactic-face-function))
  "Highlighting for alan mode")

(defvar alan-mode-syntax-table
  (let ((alan-mode-syntax-table (make-syntax-table)))
    (modify-syntax-entry ?* ". 23b" alan-mode-syntax-table)
	(modify-syntax-entry ?/ ". 124" alan-mode-syntax-table)
	(modify-syntax-entry ?\n ">" alan-mode-syntax-table)
	(modify-syntax-entry ?' "\"" alan-mode-syntax-table)
	(modify-syntax-entry ?{ "(}" alan-mode-syntax-table)
	(modify-syntax-entry ?} "){" alan-mode-syntax-table)
	alan-mode-syntax-table)
  "Syntax table for ‘alan-mode’.")

;;;###autoload
(define-derived-mode alan-mode prog-mode "Alan"
  "Major mode for editing Alan files."
  :syntax-table alan-mode-syntax-table
  :group 'alan
  (setq comment-start "//")
  (setq comment-end "")
  (setq block-comment-start "/*")
  (setq block-comment-end "*/")
  (modify-syntax-entry ?\] "_" alan-mode-syntax-table)
  (modify-syntax-entry ?\[ "_" alan-mode-syntax-table)
  (setq font-lock-defaults alan-mode-font-lock-keywords)
  (add-hook 'xref-backend-functions #'alan--xref-backend nil t)
  (set (make-local-variable 'indent-line-function) 'alan-mode-indent-line)
  (add-hook 'post-command-hook #'alan-update-header nil t)
  (setq header-line-format ""))

(defvar alan-parent-regexp "\\s-*\\('\\([^'\n\\]\\|\\(\\\\'\\)\\|\\\\\\\)*'\\)")

(defmacro alan-define-mode (name &optional docstring &rest body)
  "Define NAME as an Alan major mode.

The mode derives from the generic `alan-mode'.

BODY can define keyword aguments.
:file-pattern
	The file pattern to associate with the major mode.  If none is
	provided it will associate it with NAME.alan.
:keywords
	A list of cons cells where the first is a regexp or a list of keywords
	and the second element is the font-face.
:language
	The path to the Alan language definition.
:pairs
	A list of cons cells that match open and close parameters.
:propertize-rules
	A list of rules used by `syntax-propertize-rules' When set will set the
	propertize function for this mode.

The rest of the BODY is evaluated in the body of the derived-mode.
Optional argument DOCSTRING for the major mode."

  (declare
   (doc-string 2)
   (indent 2))
  (let* ((mode-name (intern (concat "alan-" (symbol-name name) "-mode")))
		 (language-name ;; name based on language naming convention.
		  (s-chop-suffix "-mode" (s-chop-prefix "alan-" (symbol-name name))))
		 (file-pattern ;; the naming convention for the file pattern is to use underscores.
		  (concat (s-replace "-" "_" language-name) "\\.alan\\'"))
		 (keywords)
		 (language)
		 (pairs '())
		 (propertize-rules))

	;; Process the keyword args.
    (while (keywordp (car body))
      (pcase (pop body)
		(`:file-pattern (setq file-pattern (pop body)))
		(`:keywords (setq keywords (pop body)))
		(`:language (setq language (pop body)))
		(`:pairs (setq pairs (pop body)))
		(`:propertize-rules (setq propertize-rules (pop body)))
		(_ (pop body))))

	(when keywords
	  (setq keywords (mapcar (lambda (keyword-entry)
							   (if (listp (car keyword-entry))
								   (cons (regexp-opt (car keyword-entry)) (cdr keyword-entry))
								 keyword-entry)
							   ) keywords)))

	`(progn
	   (add-to-list 'auto-mode-alist '(,file-pattern . ,name))
	   (flycheck-add-mode 'alan ',name)

	   (define-derived-mode ,name alan-mode ,language-name
		 ,docstring
		 :group 'alan
		 :after-hook (alan-setup-build-system)
		 ,(when language
			`(progn
			   (setq alan-language-definition ,language)))
		 ,(when keywords
			`(progn
			   (font-lock-add-keywords nil ',keywords "at end")))
		 ,@(mapcar
			(lambda (pair)
			  `(progn
				 (modify-syntax-entry ,(string-to-char (car pair)) ,(concat "(" (cdr pair)) alan-mode-syntax-table)
				 (modify-syntax-entry ,(string-to-char (cdr pair)) ,(concat ")" (car pair)) alan-mode-syntax-table)))
			pairs)
		 ,(when propertize-rules
			`(progn
			   (set (make-local-variable 'syntax-propertize-function) (syntax-propertize-rules ,@propertize-rules))))
		 ,@body))))

;;; Xref backend

(defun alan-boundry-of-identifier-at-point ()
  "Return the beginning and end of an alan identifier or nil if point is not on an identifier."
  (let ((text-properties (nth 1 (text-properties-at (point)))))
	(when (or (and (listp text-properties)
				   (member font-lock-variable-name-face text-properties))
			  (eq font-lock-variable-name-face text-properties))
	  (save-excursion
		(when-let* ((beginning (nth 8 (syntax-ppss)))
				   (end (progn (goto-char beginning) (forward-sexp) (point))))
		  (cons beginning end))))))
(put 'identifier 'bounds-of-thing-at-point 'alan-boundry-of-identifier-at-point)
(defun alan-thing-at-point ()
  "Find alan variable at point."
  (let ((boundary-pair (bounds-of-thing-at-point 'identifier)))
    (if boundary-pair
        (buffer-substring-no-properties
         (car boundary-pair) (cdr boundary-pair)))))
(put 'identifier 'thing-at-point 'alan-thing-at-point)

;; todo add view definitions
;; todo add widget definitions
;; todo add control definitions

(defun alan--xref-backend () 'alan)

(defvar alan--xref-format
  (let ((str "%s %s :%d"))
    (put-text-property 0 2 'face 'font-lock-variable-name-face str)
    (put-text-property 3 5 'face 'font-lock-function-name-face str)
    str))

(defun alan--xref-make-xref (symbol type buffer symbol-position)
  (xref-make (format alan--xref-format symbol type (line-number-at-pos symbol-position))
			 (xref-make-buffer-location buffer symbol-position)))

(defun alan--projectile-project-root ()
  "Finds the project root of a buffer if projectile is available.
Return default-directory if the buffer is not in a project or
projectile is not available."
  (if (featurep 'projectile)
	(let ((projectile-require-project-root nil))
	  (projectile-project-root))
	default-directory))

(defun alan--xref-find-definitions (symbol)
  "Find all definitions matching SYMBOL."
  (let ((xrefs)
		(project-scope-limit (and
							  alan-xref-limit-to-project-scope
							  (alan--projectile-project-root))))
	(dolist (buffer (buffer-list))
	  (with-current-buffer buffer
		(when (and (derived-mode-p 'alan-mode)
				   (or (null project-scope-limit)
					   (string= project-scope-limit (alan--projectile-project-root))))
		  (save-excursion
			(save-restriction
			  (widen)
			  (goto-char (point-min))
			  (while (re-search-forward "^\\s-*\\('\\([^'\n\\]\\|\\(\\\\'\\)\\|\\\\\\\)*'\\)" nil t)
				(when (string= (match-string 1) symbol)
				  (add-to-list 'xrefs (alan--xref-make-xref symbol "" buffer (match-beginning 1)) t))))))))
	xrefs))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql alan)))
  (alan-thing-at-point))

(cl-defmethod xref-backend-definitions ((_backend (eql alan)) symbol)
  (alan--xref-find-definitions symbol))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql alan)))
  (let (words)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward "^\\s-*\\('\\([^'\n\\]\\|\\(\\\\'\\)\\|\\\\\\\)*'\\)" nil t)
          (add-to-list 'words (match-string-no-properties 1)))
        (seq-uniq words)))))

;;; Alan functions

(defun alan--has-parent ()
  "Return point of parent or nil otherwise."
  (let ((line-to-ignore-regex "^\\s-*\\(//.*\\)?$"))
	(save-excursion
	  (move-beginning-of-line 1)
	  (while (and (not (bobp))
				  (looking-at line-to-ignore-regex))
		(forward-line -1))

	  (let ((start-indent (current-indentation))
			(curr-indent (current-indentation))
			(curr-point (point))
			(start-line-number (line-number-at-pos)))
		(defvar new-point)
		(while (and (not (bobp))
					(> start-indent 0)
					(or (not (looking-at "\\s-*'\\([^'\n\\]\\|\\(\\\\'\\)\\|\\\\\\\)*'"))
						(looking-at line-to-ignore-regex)
						(> (current-indentation) curr-indent)
						(<= start-indent (current-indentation))))
		  (forward-line -1)
		  (unless  (looking-at line-to-ignore-regex)
			(setq curr-indent (min curr-indent (current-indentation))))
		  (setq new-point (point)))
		(if
			(and
			 (looking-at alan-parent-regexp)
			 (not (equal start-line-number (line-number-at-pos))))
			(match-beginning 1))))))

(defun alan-goto-parent ()
  "Goto the parent of this property."
  (interactive)
  (let ((parent-position (alan--has-parent)))
	(when (alan--has-parent)
	  (push-mark (point) t)
	  (goto-char parent-position))))

(defun alan-copy-path-to-clipboard ()
  "Copy the path as shown in the header of the buffer.
This uses the `alan-path' function to get its value."
  (interactive)
  (let ((path (alan-path)))
	(when path
	  (kill-new path))))

(defun alan-path ()
  "Gives the location as a path of where you are in a file.
E.g. 'views' . 'queries' . 'context' . 'candidates' . 'of'"
  (let ((path-list '())
		has-parent)
	(save-excursion
	  (while (setq has-parent (alan--has-parent))
		(goto-char has-parent)
		(add-to-list 'path-list (match-string 1))))
	(if (> (length path-list) 0)
		(mapconcat 'identity path-list " . ")
	  "")))

(defun alan-mode-indent-line ()
  "Indentation based on parens.
Not suitable for white space significant languages."
  (interactive)
  (let (new-indent)
	(save-excursion
	  (beginning-of-line)
	  (if (bobp)
		  ;;at the beginning indent to 0
		  (indent-line-to 0))
	  ;; take the current indentation of the enclosing expression
	  (let ((parent-position (nth 1 (syntax-ppss)))
			(previous-line-indentation
			 (and (not (bobp))
				  (save-excursion (forward-line -1) (current-indentation)))))
		(cond
		 (parent-position
		  (let ((parent-indent
				 (save-excursion
				   (goto-char parent-position)
				   (current-indentation))))
			(if (looking-at "\\s-*\\s)") ;; looking at closing paren.
				(setq new-indent parent-indent)
			  (setq new-indent ( + parent-indent tab-width)))))
		 (previous-line-indentation
		  (setq new-indent previous-line-indentation)))
		;; check for single block and add a level of indentation.
		(save-excursion
		  (back-to-indentation)
		  (if (and (looking-at "\\s(")
				   (eq (line-number-at-pos)
					   (progn (forward-sexp) (line-number-at-pos))))
			  (setq new-indent (min (if previous-line-indentation (+ previous-line-indentation tab-width) tab-width )
									(+ new-indent tab-width)))))))
	(when new-indent
	  (indent-line-to new-indent))))

(defun alan-font-lock-syntactic-face-function (state)
  "Don't fontify single quoted strings.
STATE is the result of the function `parse-partial-sexp'."
  (if (nth 3 state)
      (let ((startpos (nth 8 state)))
        (if (eq (char-after startpos) ?')
            ;; This is not a string, but an identifier.
            nil
		  font-lock-string-face))
    font-lock-comment-face))

(defvar-local alan--update-headline-timer nil)
(defun alan-update-header ()
  "Update the header line after 0.5 seconds of idle time."
  (when (timerp alan--update-headline-timer)
	(cancel-timer alan--update-headline-timer))
  (setq alan--update-headline-timer
		(run-with-idle-timer
		 0.5 nil
		 (lambda (buffer-to-update)
		   (with-current-buffer buffer-to-update
			 (setq header-line-format (format " %s  " (alan-path)))
			 (force-mode-line-update)))
		 (current-buffer))))

;;; Flycheck

(defun alan-flycheck-error-filter (error-list)
  "Flycheck error filter for the Alan comopiler.
Do not include /dev/null and only show errors for the current buffer."
  (seq-remove (lambda (error)
				(or (string= (flycheck-error-filename error) "/dev/null")
					(not (string= (flycheck-error-filename error) (buffer-file-name)))))
			  error-list))

(defvar-local alan--flycheck-language-definition nil
  "The real path to the language definition if `alan-language-definition' can be resolved.")

(flycheck-define-checker alan
  "An Alan syntax checker."
  :command ("alan"
			(eval (if (null alan--flycheck-language-definition)
					  '("build" "--format" "emacs")
					`(,alan--flycheck-language-definition "--format" "emacs" "--log" "warning" "/dev/null"))))
  :error-patterns
  ((error line-start (file-name) ":" line ":" column ": error:" (zero-or-one " " (one-or-more digit) ":" (one-or-more digit))
		  ;; Messages start with a white space after the error.
		  (message (zero-or-more not-newline)
				   (zero-or-more "\n " (zero-or-more not-newline)))
		  line-end)
   (warning line-start (file-name) ":" line ":" column ": warning: " (one-or-more digit) ":" (one-or-more digit)
			(message (zero-or-more not-newline)
					 (zero-or-more "\n " (zero-or-more not-newline)))
			line-end))
  :error-filter alan-flycheck-error-filter
  :modes (alan-mode)) ;; all other modes are added using the `alan-define-mode' macro.
(add-to-list 'flycheck-checkers 'alan)

;;; Project root and build system

(defvar-local alan-project-root nil
  "The project root set by function `alan-project-root'.")
(defun alan-project-root ()
  "Project root folder determined based on the presence of a project.json or versions.json file.

If `alan-language-definition' is set prefer to use the
project.json over versions.json."
  (or
   alan-project-root
   (setq alan-project-root
		 (expand-file-name
		  (or (let ((project-files ["versions.json" "project.json"]))
				(seq-find
				 #'stringp
				 (seq-map (lambda (project-file)
							(locate-dominating-file default-directory project-file))
						  ;; Prefer to use project.json if `alan-language-definition' is set.
						  (if alan-language-definition (seq-reverse project-files) project-files))))
			  (progn
				(message  "Couldn't locate project root folder with a versions.json or project.json file. Using' %s' as project root." default-directory)
				default-directory))))))

(defun alan-file-executable (file)
  "Check if FILE is executable and return FILE."
  (when (file-executable-p file) file))

(defun alan-find-alan-script ()
  "Try to find the alan script in the dominating directory starting from the function `alan-project-root'.
Return nil if the script can not be found."
  (when-let ((alan-project-script
			  (locate-dominating-file
			   (alan-project-root)
			   (lambda (name)
				 (let ((alan-script-candidate (concat name "alan")))
				   (and (file-executable-p alan-script-candidate)
						(not (file-directory-p alan-script-candidate))))))))
	(expand-file-name (concat alan-project-script "alan"))))

(defun alan--file-exists (name)
  "Return the file NAME if it exists."
  (when (file-exists-p name) name))

(defun alan-setup-build-system ()
  "Setup Flycheck and the `compile-command'."
  (let ((alan-project-script (or (alan-find-alan-script)
								 (executable-find alan-script)))
		(alan-project-compiler (cond ((alan-file-executable (concat (alan-project-root) "dependencies/dev/internals/alan/tools/compiler-project")))
									   ((alan-file-executable (concat (alan-project-root) "devenv/platform/project-compiler/tools/compiler-project")))))
		(alan-project-language (concat (alan-project-root) alan-language-definition)))
	(set (make-local-variable 'compilation-error-screen-columns) nil)
	(cond
	 ((and alan-project-compiler alan-language-definition)
	  (set (make-local-variable 'flycheck-alan-executable) alan-project-compiler)
	  (setq alan--flycheck-language-definition alan-project-language)
	  (set (make-local-variable 'compile-command)
		   (concat alan-project-compiler " " alan-project-language " --format emacs --log warning /dev/null ")))
	 ((and  alan-project-script)
	  (setq flycheck-alan-executable alan-project-script)
	  (set (make-local-variable 'compile-command) (concat alan-project-script " build --format emacs ")))
	 (t (message "No alan compiler or script found.")))))

;;; Modes

(defvar alan-imenu-generic-expression
  ;; Patterns to identify alan definitions
  '(("dictionary" "^\\s-+'\\(\\(?:\\sw\\|\\s-+\\)*\\)'\\s-+->\\s-* dictionary" 1)
	("state group" "^\\s-+'\\(\\(?:\\sw\\|\\s-+\\)*\\)'\\s-+->\\s-* stategroup" 1)
	("component" "^\\s-+'\\(\\(?:\\sw\\|\\s-+\\)*\\)'\\s-+->\\s-* component" 1)
	("text" "^\\s-+'\\(\\(?:\\sw\\|\\s-+\\)*\\)'\\s-+->\\s-* text" 1)
	("number" "^\\s-+'\\(\\(?:\\sw\\|\\s-+\\)*\\)'\\s-+->\\s-* number" 1)
	("matrix" "^\\s-+'\\(\\(?:\\sw\\|\\s-+\\)*\\)'\\s-+->\\s-* \\(?:dense\\|sparse\\)matrix" 1)))

;;;###autoload (autoload 'alan-schema-mode "alan-mode")
(alan-define-mode alan-schema-mode
	"Major mode for editing Alan schema files."
  :language "dependencies/dev/internals/alan/language"
  :keywords (("->\\s-+\\(stategroup\\|component\\|group\\|dictionary\\|command\\|densematrix\\|sparsematrix\\|reference\\|number\\|text\\)\\(\\s-+\\|$\\)" 1 font-lock-type-face)
			 (( "component" "types" "external" "->" "plural" "numerical"
				"integer" "natural" "root" "]" ":" "*" "?"  "~" "+" "constrain"
				"acyclic" "ordered" "dictionary" "densematrix" "sparsematrix"
				"$" "==" "!=" "group" "number" "reference" "stategroup" "text"
				"."  "!"  "!&" "&" ".^" "+^" "}" ">" "*&" "?^" ">>" "forward"
				"self" "{" "graph" "usage" "implicit" "ignore" "experimental"
				"libraries" "using") . font-lock-builtin-face)))

(defun alan-grammar-update-keyword ()
  "Update the keywords section based on all used keywords in this grammar file."
  (interactive)
  (save-excursion
	(save-restriction
	  (widen)
	  (goto-char (point-min))

	  (let ((keyword-point (re-search-forward "^keywords$"))
			(root-point (re-search-forward "^root$"))
			(root-point-start (match-beginning 0)) ;; because the last search was for root
			(alan-keywords (list)))
		(while (re-search-forward "\\[\\(\\s-?'[^'
]+'\\s-?,?\\)+\\]" nil t) ;; there is a line end in the regex. Hence the weird break.
		  (let ((keyword-group (match-string 0))
				(search-start 0))
			(while (string-match "'[^']+'" keyword-group search-start)
			  (add-to-list 'alan-keywords (match-string 0 keyword-group))
			  (setq search-start (match-end 0)))))
		(delete-region (+ 1 keyword-point) root-point-start)
		(goto-char (+ 1 keyword-point))
		(insert (string-join (mapcar (lambda (k) (concat "\t" k)) (sort (delete-dups alan-keywords ) 'string<)) "
"))
		(insert "
")
		(insert "
")))))

(defun alan-grammar-mode-indent-line ()
  "Indentation based on parens and toggle indentation to min and max indentation possible."
  (interactive)
  (let
	  (new-indent)
 	(save-mark-and-excursion
	  (beginning-of-line)
	  (when (bobp) (indent-line-to 0)) ;;at the beginning indent at 0
	  (let* ((parent-position (nth 1 (syntax-ppss))) ;; take the current indentation of the enclosing expression
			 (parent-indent (if parent-position
								(save-excursion (goto-char parent-position) (current-indentation))
							  0))
			 (current-indent (current-indentation))
			 (previous-line-indentation (and
										 (not (bobp))
										 (save-excursion
										   (forward-line -1)
										   (current-indentation))))
			 (min-indentation (if parent-position (+ parent-indent tab-width) 0))
			 (max-indentation (+ previous-line-indentation tab-width)))
		(cond
		 ((and parent-position (looking-at "\\s-*\\s)"))
		  (setq new-indent parent-indent))
		 ((= current-indent min-indentation)
		  (setq new-indent max-indentation))
		 ((< current-indent min-indentation) ;; usually after a newline.
		  (setq new-indent (max previous-line-indentation min-indentation)))
		 ((> current-indent max-indentation)
		  (setq new-indent max-indentation))
		 ((<= current-indent max-indentation)
		  (setq new-indent (- current-indent tab-width))))))
 	(when new-indent
 	  (indent-line-to new-indent))))

;;;###autoload (autoload 'alan-grammar-mode "alan-mode")
(alan-define-mode alan-grammar-mode
	"Major mode for editing Alan grammar files."
  :language "dependencies/dev/internals/alan/language"
  :pairs (("[" . "]"))
  :keywords ((("rules" "root" "component" "indent" "keywords" "collection" "order"
			   "predecessors" "successors" "group" "number" "reference" "stategroup"
			   "has" "first" "last" "predecessor" "successor" "text" "[" "]" ","
			   ) . font-lock-builtin-face))
  (electric-indent-local-mode -1)
  (local-set-key (kbd "RET") 'newline-and-indent)
  (set (make-local-variable 'indent-line-function) 'alan-grammar-mode-indent-line))

(defun alan-template-yank ()
  "Yank but wrap as template."
  (interactive)
  (let ((string-to-yank (current-kill 0 t)))
	(insert (mapconcat 'identity
					   (mapcar (lambda (s)
								 (format "\"%s\"" (replace-regexp-in-string "\"" "\\\\\"" s)))
							   (split-string string-to-yank "\n"))
					   "\n"))))

;;;###autoload (autoload 'alan-template-mode "alan-mode")
(alan-define-mode alan-template-mode
	"Major mode for editing Alan template files."
  :file-pattern "\\.template\\'"
  :language "dependencies/dev/internals/alan-to-text-transformation/language")

(defun alan-list-nummerical-types ()
  "Return a list of all nummerical types."
  (save-mark-and-excursion
	(save-restriction
	  (widen)
	  (goto-char (point-max))
	  (let ((numerical-types-point (re-search-backward "^numerical-types"))
			(numerical-types (list)))
		(when numerical-types-point
		  (while (re-search-forward "^\\s-*'\\([^']*\\)'" nil t)
			(add-to-list 'numerical-types (match-string 1))))
		numerical-types))))

;;;###autoload (autoload 'alan-application-mode "alan-mode")
(alan-define-mode alan-application-mode
	"Major mode for editing Alan application model files."
  :pairs (("{" . "}"))
  :keywords (
			 ("^\\(users\\|roles\\|root\\|numerical-types\\)" . font-lock-keyword-face)
			 ("\\(:\\|:=\\)\\s-+\\(stategroup\\|component\\|group\\|file\\|collection\\|command\\|reference-set\\|natural\\|integer\\|text\\)\\(\\s-+\\|$\\)" 2 font-lock-type-face)
			 (("today" "now" "zero" "true" "false") . font-lock-constant-face)
			 (( "@date" "@date-time" "@default:" "@description:" "@desired"
			   "@dormant" "@duration:" "@factor:" "@guid" "@hidden"
			   "@identifying" "@key-description:" "@label:" "@linked" "@max:"
			   "@metadata" "@min:" "@multi-line" "@name" "@namespace" "@small"
			   "@sticky" "@validate:" "@verified" "@visible" )
			   . font-lock-keyword-face)
			 (("add" "branch" "ceil" "convert" "count" "division" "floor" "increment"
			   "max" "min" "remainder" "subtract" "sum" "sumlist" "base" "diff"
			   "product")
			  . font-lock-function-name-face)
			 (("#" "#reader" "#writer" "$" "$^" "%" "%^" "%}" "&#" "&" "*" "+" "+^" ","
			   "-" "-<" "->" "." ".^" ".key" ".self" ".}" "/" "10^" ":" ":=" "<" "<-"
			   "<=" "=" "==" "=>" ">" ">=" ">key" "?" "?^" "@%^" "@" "@?^" "@date"
			   "@date-time" "@default:" "@description:" "@desired" "@dormant"
			   "@duration:" "@factor:" "@guid" "@hidden" "@identifying"
			   "@key-description:" "@label:" "@linked" "@max:" "@metadata" "@min:"
			   "@multi-line" "@name" "@namespace" "@small" "@sticky" "@validate:"
			   "@verified" "@visible" "[" "]" "^" "acyclic-graph" "add" "and" "anonymous"
			   "any" "as" "base" "ceil" "collection" "command" "component" "count"
			   "create" "created" "creation-time" "delete" "dense" "deprecated"
			   "dictionary" "diff" "division" "do" "dynamic" "entry" "external" "false"
			   "file" "floor" "forward" "from" "group" "hours" "if" "ignore" "in"
			   "increment" "integer" "interface" "invalidate" "inverse" "join"
			   "life-time" "log" "mapping" "match" "match-branch" "matrix" "max" "min"
			   "minutes" "mutation-time" "natural" "new" "node" "now" "number"
			   "numerical-types" "on" "one" "ontimeout" "ordered-graph" "password"
			   "product" "reference" "reference-set" "referencer" "remainder" "remove"
			   "rename" "roles" "root" "seconds" "space" "sparse" "stategroup" "std"
			   "subtract" "sum" "sumlist" "switch" "text" "timer" "today" "true" "union"
			   "unsafe" "update" "users" "with" "workfor" "zero" "|" "~>" ) . font-lock-builtin-face))
  :propertize-rules (("[\\.%]\\(}\\)" (1 "_"))))

;;;###autoload (autoload 'alan-widget-mode "alan-mode")
(alan-define-mode alan-widget-mode
	"Major mode for editing Alan widget model files."
  :file-pattern "widgets/.*\\.ui\\.alan\\'"
  :pairs (("{" . "}") ("[" . "]"))
  :keywords ((( "#" "$" "*" "," "->" "."  ".}"  ":" "::" "=>" ">" ">>" "?"  "@"
				"^" "binding" "configuration" "control" "current" "dictionary"
				"empty" "engine" "file" "format" "inline" "instruction" "interval"
				"let" "list" "markup" "number" "on" "set" "state" "stategroup"
				"static" "switch" "text" "time" "to" "transform" "unconstrained"
				"view" "widget" "window" "|" ) . font-lock-builtin-face))
  :propertize-rules (("\\.\\(}\\)" (1 "_"))))

;;;###autoload (autoload 'alan-views-mode "alan-mode")
(alan-define-mode alan-views-mode
	"Major mode for editing Alan views files."
  :pairs (("{" . "}") ("[" . "]"))
  :file-pattern "views/.*\\.ui\\.alan\\'"
  :propertize-rules (("/?%\\(}\\)" (1 "_")))
  :keywords ((( "$" "%" "%^" "%}" "*" "+" "+^" "-" "->" "."  ".>" ".^" "/%}" "/>"
				":>" "<" "<<" "<=" "=" "==" ">" ">=" ">>" "?"  "?^" "@" "as"
				"candidates" "collection" "command" "disabled" "enabled" "entity"
				"file" "filter" "from" "group" "id" "inline" "key" "limit" "link"
				"matrix" "node" "none" "now" "number" "of" "on" "open" "path"
				"query" "reference" "refresh" "role" "root" "selected"
				"stategroup" "subscribe" "text" "using" "view" "window")
			  . font-lock-builtin-face)))

;;;###autoload (autoload 'alan-wiring-mode "alan-mode")
(alan-define-mode alan-wiring-mode
	"Major mode for editing Alan wiring files."
  :keywords ((("interfaces:" "external-systems:" "systems:" "provides:"
			   "consumes:" "provided-connections:" "from" "external" "internal"
			   "(" ")" "."  "=" "message" "custom")
			  . font-lock-builtin-face)))

;;;###autoload (autoload 'alan-deployment-mode "alan-mode")
(alan-define-mode alan-deployment-mode
	"Major mode for editing Alan deployment files."
  :language "devenv/platform/project-build-environment/language"
  :keywords ((("external-systems:" "instance-data:" "system-options:"
			   "provided-connections:" ":" "."  "from" "local" "remote" "stack"
			   "system" "migrate" "timezone" "interface" "message" "custom"
			   "socket" "schedule" "at" "never" "every" "day" "hour" "Monday"
			   "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday" )
			  . font-lock-builtin-face)))

;;;###autoload (autoload 'alan-mapping-mode "alan-mode")
(alan-define-mode alan-mapping-mode
	"Major mode for editing Alan mapping files."
  :keywords ((("#" "%" "(" ")" "+" "."  "/" ":" ":=" "=" "=>" ">" "?"  "@" "|"
			   "causal" "collection" "command" "do" "file" "group" "integer"
			   "interfaces" "log" "natural" "number" "on" "reference-set"
			   "roles" "root" "stategroup" "switch" "text" "with")
			  . font-lock-builtin-face)))

(provide 'alan-mode)

;;; alan-mode.el ends here
