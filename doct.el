;;; doct.el --- DOCT: Declarative Org capture templates -*- lexical-binding: t; -*-
;; Author: nv <progfolio@protonmail.com>
;; URL: https://github.com/progfolio/doct
;; Created: December 10, 2019
;; Keywords: org, convenience
;; Package-Requires: ((emacs "25.1"))
;; Version: 0.2

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; This package provides an alternative syntax for declaring Org capture
;; templates. See the doctstring for doct for more details.

;;; Code:

(defgroup doct nil
  "DOCT: Declarative Org Capture Templates"
  :group 'org)

(defcustom doct-default-entry-type 'entry
  "The default template entry type.
Can be overridden by using the :type keyword in an entry."
  :type 'symbol
  :options '(entry item checkitem table-line plain)
  :group 'doct)

(defcustom doct-sort-parents-predicate nil
  "A binary predicate function which sorts a list of the form:
\(((parent) (child)...)...).
If nil, no sorting is performed."
  :type 'function
  :group 'doct)

(defcustom doct-sort-children-predicate nil
  "A binary predicate function which sorts lists of the form:
\((child)...).
If nil, no sorting is performed."
  :type 'function
  :group 'doct)

(defvar doct-option-keywords '(:clock-in
                               :clock-keep
                               :clock-resume
                               :empty-lines
                               :empty-lines-after
                               :empty-lines-before
                               :immediate-finish
                               :jump-to-captured
                               :kill-buffer
                               :no-save
                               :prepend
                               :table-line-pos
                               :time-prompt
                               :tree-type
                               :unnarrowed)
  "List of Org capture template additional options.")

(defvar doct-file-extension-keywords '(:function :headline :olp :regexp)
  "List of doct keywords that refine the insertion location in the target file.")

(defvar doct-exclusive-location-keywords '(:clock :function :id :target :file)
  "List of doct keywords that exclusively set the target location.")

(defvar doct-hook-keywords '(:after-finalize :before-finalize
                                             :hook :prepare-finalize)
  "List of doct keywords that attach hooks for the current template.")

(defvar doct-keywords '(:children
                        :datetree
                        :doct--parent
                        :file
                        :function
                        :headline
                        :keys
                        :olp
                        :regexp
                        :target
                        :template
                        :template-file
                        :template-function
                        :type)
  "List of doct's custom keywords.")

(defvar doct-recognized-keywords (append
                                  doct-option-keywords
                                  doct-file-extension-keywords
                                  doct-exclusive-location-keywords
                                  doct-hook-keywords
                                  doct-keywords)
  "List of the keywords doct recognizes.")

(defsubst doct-error (name msg)
  "Report MSG as an error, so the user knows it came from this package.
NAME is the name of the entry that threw the error."
  (user-error "Doct: Error processing \"%s\" entry\n%s" name msg))

(defun doct--first-in-plist (plist keywords)
  "Find first occurence of one of KEYWORDS in PLIST."
  (car (seq-some (lambda (property)
                   (and (keywordp property) (member property keywords)))
                 plist)))

(defun doct-remove-hooks (&optional keys hooks unintern-functions)
  "Remove hooks matching KEYS from HOOKS.
doct hook functions follow the form:

  doct--hook/<org-capture-hook-variable-name>/KEYS.

KEYS is a regular expression which matches KEYS in the above form.

HOOKS is one of five symbols:
  after-finalize
    removes matching functions from `org-capture-after-finalize-hook'
  before-finalize
    removes matching functions from `org-capture-before-finalize-hook'
  prepare-finalize
    removes matching functions from `org-capture-prepare-finalize-hook'
  mode
    removes matching functions from `org-capture-mode-hook'
  t
    removes matching functions from all of the above hooks.

Or a list including any combination of the first four symbols. e.g.

\\='(after-finalize before-finalize mode prepare-finalize)

is equivalent to passing t as HOOKS.

If UNINTERN-FUNCTIONS is non-nil, the matching functions are uninterned.

Example:

  (doct-remove-hooks \"t.?\" \\='mode t)

Removes:

  doct--hook/mode/t
  doct--hook/mode/tt

But not:

  doct--hook/mode/p

From the `org-capture-mode-hook'."
  (interactive)
  (let* ((keys (or keys (read-string "Remove hooks with keys matching: ")))
         ;;only want to match against the end of the hook function's name
         (keys (if (string= (substring keys -1) "$")
                   keys
                 (concat keys "$")))
         (hook-symbols (pcase hooks
                         ((pred (not)) (mapcar #'intern-soft
                                               (completing-read-multiple
                                                "Hooks: " '("after-finalize"
                                                            "before-finalize"
                                                            "mode"
                                                            "prepare-finalize"
                                                            "t"))))
                         ((pred (lambda (hook)
                                  (memq hook '(after-finalize
                                               before-finalize
                                               mode
                                               prepare-finalize
                                               t))))
                          (list hooks))
                         ((and (pred listp) hooks
                               (guard (seq-every-p 'symbolp hooks)))
                          hooks)
                         (_ (user-error "Unrecognized HOOKS value %s" hooks))))
         (hooks (if (memq t hook-symbols)
                    '(org-capture-after-finalize-hook
                      org-capture-before-finalize-hook
                      org-capture-mode-hook
                      org-capture-prepare-finalize-hook)
                  (mapcar (lambda (symbol)
                            (intern-soft (concat "org-capture-"
                                                 (symbol-name symbol)
                                                 "-hook")))
                          hook-symbols))))
    (dolist (hook hooks)
      (dolist (hook-fn (symbol-value hook))
        (when (string-match keys (symbol-name hook-fn))
          (remove-hook hook hook-fn))
        (when unintern-functions (unintern hook-fn nil))))))


(defun doct--add-hook (keys fn where &optional entry-name)
  "Generate hook function and add to appropriate hook variable.
The generated hook function takes the form \"doct--hook/WHERE/KEYS\".
FN is called when an org-capture-template's keys match KEYS.
WHERE is one of the following strings:
\"mode\"
\"after-finalize\"
\"before-finalize\"
\"prepare-finalize\"
ENTRY-NAME is the name of the entry the hook should run for."
  (if-let ((wrapper (intern (string-join `("doct--hook" ,where ,keys) "/")))
           (hook (intern-soft (concat "org-capture-" where "-hook"))))
      (progn
        (eval `(defun ,wrapper ()
                 ,(string-join
                   `("Auto generated by `doct--add-hook'."
                     ,(concat "It is run as part of `" (symbol-name hook) "'"
                              (if entry-name
                                  (concat " when the \"" entry-name
                                          "\" template is selected.")
                                "'."))
                     "It can be removed using `doct-remove-hooks' like so:"
                     ,(concat "(doct-remove-hooks \""
                              keys "\" \\='" where " t)"))
                   "\n")
                 (when (string= ,keys (plist-get org-capture-plist :key))
                   (funcall (quote ,fn)))))
        (add-hook hook wrapper))
    (user-error "Doct: couldnt add %s as doct--hook/%s to %s" fn keys where)))

(defun doct--convert (name &rest args)
  "Convert declarative form to template named NAME with ARGS.
For a full description of ARGS see `doct'."
  (let ((keys (plist-get args :keys))
        (children (plist-get args :children))
        target
        template
        additional-options
        unrecognized-options)

    (unless keys
      (doct-error name "entry has no :keys value"))

    ;;parent entries should only have keys and children
    ;;and template entries shouldn't have children
    (when children
      (unless (or (= (length args) 4)
                  (and (plist-member args :doct--parent)
                       (= (length args) 6)))
        (doct-error name
                    "Parent entry only accpets name, :keys, and :children args"))
      (unless (listp children)
        (doct-error name ":children must be contained in a list"))
      (unless (or (listp children)
                  (seq-every-p 'listp children))
        (doct-error name "Each child must be a list")))

    (dolist (keyword '(:olp :template))
      (when-let ((val (plist-get args keyword)))
        (unless (or (stringp val)
                    (and (listp val)
                         (seq-every-p 'stringp val)))
          (doct-error
           (format name ":%s must be string or list of strings"
                   keyword  (eval keyword))))))

    ;;recursively convert children
    (when children
      (setf children
            (mapcar (lambda (child)
                      (apply #'doct--convert
                             (append child `(:doct--parent ,args))))
                    (if (not (seq-every-p 'listp children))
                        `(,children)
                      children))))
    ;;inherit keys
    (setq keys (let (inherited-keys
                     parent
                     (current args))
                 (while (setq parent (plist-get current :doct--parent))
                   (push (plist-get parent :keys) inherited-keys)
                   (setq current parent))
                 (concat (string-join inherited-keys) keys)))

    ;;file targets
    (setq target
          (pcase (doct--first-in-plist args doct-exclusive-location-keywords)
            (:clock '(clock))
            (:id `(id ,(plist-get args :id)))
            (:function (unless (plist-get args :file)
                         `(function ,(plist-get args :function))))
            (:target (plist-get args :target))
            (:file (let (target-type target-args)
                     (pcase (doct--first-in-plist args
                                                  doct-file-extension-keywords)
                       (:olp (push (plist-get args :datetree) target-type)
                             (push :olp target-type)
                             (dolist (path (nreverse (plist-get args :olp)))
                               (push path target-args)))
                       (extension (push extension target-type)
                                  (push (plist-get args extension)
                                        target-args)))
                     (push :file target-type)
                     (push  (plist-get args :file) target-args)
                     `(,(intern (string-join
                                 (mapcar (lambda (keyword)
                                           (substring (symbol-name keyword) 1))
                                         (delq nil target-type)) "+"))
                       ,@(delq nil target-args))))))

    ;;template targets
    (pcase (doct--first-in-plist args '(:template
                                        :template-file
                                        :template-function))
      (:template
       (setq template (let ((template (plist-get args :template)))
                        (if (stringp template)
                            template
                          (string-join template "\n")))))
      (:template-file
       (setq template `(file ,(plist-get args :template-file))))
      (:template-function
       (setq template
             `(function ,(plist-get args :template-function)))))

    ;;additional/unrecognized options
    (dolist (keyword (seq-filter (lambda (arg) (keywordp arg)) args))
      (when (plist-get args keyword)
        (pcase keyword
          ((pred (lambda (keyword) (member keyword doct-option-keywords)))
           (push keyword additional-options)
           (push (plist-get args keyword) additional-options))
          ((pred (lambda (keyword)
                   (not (member keyword doct-recognized-keywords))))
           (push keyword unrecognized-options)
           (push (plist-get args keyword) unrecognized-options)))))

    ;;hooks
    (dolist (keyword doct-hook-keywords)
      (when-let ((hook-fn (plist-get args keyword))
                 (hook (if (eq keyword :hook) "mode"
                         ;;remove preceding ':' from keyword
                         (substring (symbol-name keyword) 1))))
        (doct--add-hook keys hook-fn hook name)))

    ;;compose entry
    (let ((entry
           (delq nil `(,keys
                       ,name
                       ;;@FIX logic could be clearer
                       ,(unless (or children (and (= 2 (length args))
                                                  keys))
                          (or (plist-get args :type)
                              doct-default-entry-type))
                       ,target
                       ,template
                       ,@(nreverse additional-options)
                       ,@(nreverse unrecognized-options)))))
      (if children
          `(,entry ,@(if doct-sort-children-predicate
                         (sort children doct-sort-children-predicate)
                       children))
        entry))))

(defun doct (declarations)
  "DECLARATIONS is a list of declarative forms."
  (let (templates
        entries)
    ;;letrec allows local recursive functions without
    ;;resorting to cl-labels
    (letrec ((extract (lambda (list)
                        (dolist (element list)
                          (if (seq-every-p 'listp element)
                              (funcall extract element)
                            (when (listp element)
                              (push element templates)))))))

      (setq entries (mapcar (lambda (form)
                                        (apply 'doct--convert form))
                                      declarations))

      (funcall extract (if doct-sort-parents-predicate
                   (sort entries doct-sort-parents-predicate)
                   entries)))
    (nreverse templates)))

(provide 'doct)

;;; doct.el ends here
