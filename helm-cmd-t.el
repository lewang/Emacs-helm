;;; helm-cmd-t.el --- cmd-t style completion

;; this file is not part of Emacs

;; Copyright (C) 2011, 2012 Le Wang
;; Author: Le Wang
;; Maintainer: Le Wang
;; Description: cmd-t style completion of files in repository
;; Author: Le Wang
;; Maintainer: Le Wang

;; Created: Sat Nov  5 16:42:32 2011 (+0800)
;; Version: 0.1
;; Last-Updated: Tue Jul 24 23:27:00 2012 (+0800)
;;           By: Le Wang
;;     Update #: 311
;; URL: https://github.com/lewang/helm-cmd-t
;; Keywords: helm project-management completion convenience cmd-t textmate
;; Compatibility:

;;; Installation:

;; 1. install `helm' from github
;;
;; 2. add to your config
;;
;;      (require 'helm-config)
;;      (require 'helm-cmd-t)
;;      (global-set-key (kbd "M-t") 'helm-cmd-t)
;;
;; 3. additional optional helm settings to make helm more responsive.
;;
;;      (setq helm-ff-lynx-style-map nil
;;            helm-input-idle-delay 0.1
;;            helm-idle-delay 0.1
;;      )
;;
;; 4. have a look at helm-C-x-b.el for more examples of how to use the
;;    `helm-cmd-t' source in your own buffers.
;;
;; 5. read the self-documenting code for additional configuration options.
;;


;;; Commentary:

;; This package provides a helm source for repository (git, hg, etc) based
;; file selection.  The emphasis is on fast file-name completion.  The concept
;; of a "respository" is configurable through `helm-cmd-t-repo-types'.
;;
;; Each repository is cached for fast access (see
;; `helm-cmd-t-cache-threshhold'), and in the future, options will be
;; available to interact with the repository (i.e. grep, etc).
;;
;; `helm-cmd-t' is the simple predefined command that opens a file in the
;; current repository, however, it's highly recommended that you add a helm
;; source like recentf that keeps track of recent files you've worked with.
;; This way, you don't have to worry about your respository cache being out of
;; sync.  See "helm-C-x-b.el" for an example of a custom drop-in
;; replacement for `switch-to-buffer' or "C-x b".
;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Code:

(eval-when-compile (require 'cl))


(provide 'helm-cmd-t)
(require 'helm-config)
(require 'helm-locate)

(defcustom helm-cmd-t-cache-threshhold 1000
  "If a repo has more entries than this value it will be cached.

`nil' to disable caching completely.

Alternatively, this can be a function that takes three parameters:

    repository-type
    repo-root
    entries

It should return nil to stop caching.
"
  :group 'helm-command
  :type 'sexp)

(defcustom helm-cmd-t-default-repo nil
  "A path that points to a default repo root.
If the current file does not belong to a repo then this path is used.
"
  :group 'helm-command
  :type 'string)

(defcustom helm-cmd-t-find-prunes '("SCCS" "RCS" "CVS" "MCVS" ".svn" ".git" ".hg" ".bzr" "_MTN" "_darcs" "{arch}")
  "list used to prune \"find\" search.

see: `grep-find-ignored-directories' for inspiration"
  :group 'helm-command
  :type 'list)

(defcustom helm-cmd-t-find-ignored-files (nconc '("#*#" ".#*" "*.o" "*~" "*.bin" "*.lbin" "*.so" "*.a" "*.ln" "*.blg" "*.bbl" "*.elc" "*.lof" "*.glo" "*.idx" "*.lot" "*.fmt" "*.tfm" "*.class" "*.fas" "*.lib" "*.mem" "*.x86f" "*.sparcf" "*.dfsl" "*.pfsl" "*.d64fsl" "*.p64fsl" "*.lx64fsl" "*.lx32fsl" "*.dx64fsl" "*.dx32fsl" "*.fx64fsl" "*.fx32fsl" "*.sx64fsl" "*.sx32fsl" "*.wx64fsl" "*.wx32fsl" "*.fasl" "*.ufsl" "*.fsl" "*.dxl" "*.lo" "*.la" "*.gmo" "*.mo" "*.toc" "*.aux" "*.cp" "*.fn" "*.ky" "*.pg" "*.tp" "*.vr" "*.cps" "*.fns" "*.kys" "*.pgs" "*.tps" "*.vrs" "*.pyc" "*.pyo")
                                                 helm-cmd-t-find-prunes)
  "list of file extensions which should be ignored.

see `grep-find-ignored-files' for inspiration."
  :group 'helm-command
  :type 'list)

(defvar helm-cmd-t-data nil
  "data only relevant in helm source buffer.")
(make-variable-buffer-local 'helm-cmd-t-data)

(defvar helm-cmd-t-find-command "find"
  "command to execute to get list of files it should be some variant of the Unix `find' command.")


(defvar helm-cmd-t-repo-types
  `(("git"           . "cd %d && git --no-pager ls-files --full-name")
    ("hg"            . "cd %d && hg manifest")
    ("bzr"           . "cd %d && bzr ls --versioned")
    ("dir-locals.el" . helm-cmd-t-elisp-find-insert))
  "root types supported.
this is an alist of (type . \"format-string\").

\"%d\" is replaced with the project root in the format-string.

format string can also be symbol that takes:

    repo-root

as its parameter. ")

(defvar helm-cmd-t-cookies (mapcar (lambda (repo-type)
                                     (cons (concat "." (car repo-type)) (car repo-type)))
                               helm-cmd-t-repo-types)
  "A list of files that mark the root of a repository")

(defvar helm-cmd-t-anti-cookie ".emacs-helm-no-spider"
  "Marker file that disqualifies a directory from being considered a repo.")

(defvar helm-cmd-t-source-buffer-format
  " *helm-cmd-t source - [%s]*")

(defvar helm-cmd-t-header-format
  "[%r] (%l in %t%a)"
  "format for project header
  %r - project root
  %t - type of repo
  %a - age of cache
  %l - line count")

(defun helm-cmd-t-root (&optional buff)
  "return repo root of buffer as string"
  (with-current-buffer (or buff
                           (and helm-alive-p
                                helm-current-buffer)
                           (current-buffer))
    (cdr (helm-cmd-t-root-data))))

(defun helm-cmd-t-locate-dominating-files (dir cookies-data anti-cookie)
  "return first ancestor that has any file in files
return (<repo type> . <root.>)"
  (if (null dir)
      nil)
  (let (best-root
        best-type
        cookie
        root)
    (dolist (cookie-data cookies-data)
      (setq cookie (car cookie-data)
            root   dir)
      (loop while (and (setq root (locate-dominating-file root cookie))
                       (file-exists-p (expand-file-name anti-cookie root))
                       (setq root (expand-file-name ".." root))))
      (when root
        (if (> (length root) (length best-root))
            (setq best-root root
                  best-type (cdr cookie-data)))))
    (when best-root
      (cons best-type best-root))))

(defun helm-cmd-t-root-data (&optional file)
  "get repo directory of file
return (<repo type> . <root.)"
  (setq file (or file
                 default-directory))
  (let (res)
    (setq res (helm-cmd-t-locate-dominating-files file helm-cmd-t-cookies helm-cmd-t-anti-cookie))
    (unless res
      (if helm-cmd-t-default-repo
          (setq res (helm-cmd-t-locate-dominating-files helm-cmd-t-default-repo helm-cmd-t-cookies helm-cmd-t-anti-cookie))
        (error "Appropriate repo not found, no default repo defined..")))
    res))

(defun helm-cmd-t-format-age (age)
  "convert age in float to reasonable time explanation"
  (cond ((< age 10)
         "")
        ((< age 3600)
         (format " %i min ago" (ceiling (/ age 60))))
        (t
         (format " %.1f hours ago" (/ age 3600)))))

(defun helm-cmd-t-format-lines (lines)
  "convert lines to reasonable presentation"
  (cond ((< lines 1000)
         (format "%s files" lines))
        (t
         (format "%.1fk files" (/ lines 1000.0)))))

(defun helm-cmd-t-format-title (buffer)
  "format header line according to `helm-cmd-t-header-format'"
  (with-current-buffer buffer
    (let* ((repo-root (cdr (assq 'repo-root helm-cmd-t-data)))
           (repo-type (cdr (assq 'repo-type helm-cmd-t-data)))
           (age (- (float-time) (or (cdr (assq 'time-stamp helm-cmd-t-data))
                                    (float-time))))
           (age-str (helm-cmd-t-format-age age))
           (lines (helm-cmd-t-format-lines
                   (cdr (assq 'lines helm-cmd-t-data)))))
      (format-spec helm-cmd-t-header-format (format-spec-make ?r repo-root
                                                              ?t repo-type
                                                              ?a age-str
                                                              ?l lines)))))

(defun helm-cmd-t-get-create-source (repo-root-data)
  "source for repo-root"
  (let* ((repo-root (cdr repo-root-data))
         (repo-type (car repo-root-data))
         (source-buffer-name (helm-cmd-t-get-source-buffer-name repo-root))
         (candidates-buffer (get-buffer-create source-buffer-name))
         (data (with-current-buffer candidates-buffer
                 helm-cmd-t-data))
         (my-source (cdr (assq 'helm-source data))))
    (when data
      (let ((lines (cdr (assq 'lines data))))
        (cond ((null helm-cmd-t-cache-threshhold)
               (setq my-source nil))
              ((functionp helm-cmd-t-cache-threshhold)
               (let ((res (funcall helm-cmd-t-cache-threshhold repo-type repo-root lines)))
                 (when (null res)
                   (setq my-source nil))))
              ((numberp helm-cmd-t-cache-threshhold)
               (when (< lines helm-cmd-t-cache-threshhold)
                 (setq my-source nil))))))
    (or my-source
        (with-current-buffer candidates-buffer
          (erase-buffer)
          (helm-cmd-t-insert-listing repo-type repo-root)
          (setq my-source `((name . ,(format "[%s]" (abbreviate-file-name repo-root)))
                            (header-name . (lambda (_)
                                             (helm-cmd-t-format-title ,candidates-buffer)))
                            (init . (lambda ()
                                      (helm-candidate-buffer ,candidates-buffer)))
                            (candidates-in-buffer)
                            (match helm-c-match-on-file-name
                                   helm-c-match-on-directory-name)
                            (action . ,(cdr (helm-get-actions-from-type helm-c-source-locate)))
                            (type . file)))
          (setq helm-cmd-t-data (list (cons 'helm-source my-source)
                                      (cons 'repo-root repo-root)
                                      (cons 'repo-type repo-type)
                                      (cons 'time-stamp (float-time))
                                      (cons 'lines (count-lines (point-min) (point-max)))))
          my-source))))

(defun helm-cmd-t-find-file (candidate)
  "find file"
  (find-file (expand-file-name candidate
                               (with-current-buffer (helm-candidate-buffer)
                                 (cdr (assq 'repo-root helm-cmd-t-data))))))

(defun helm-cmd-t-get-source-buffer-name (root)
  (format helm-cmd-t-source-buffer-format (file-name-as-directory root)))

(defun helm-cmd-t-insert-listing (repo-type repo-root)
  (let ((cmd (cdr (assoc repo-type helm-cmd-t-repo-types))))
    (if (functionp cmd)
        (funcall cmd repo-root)
      (shell-command (format-spec cmd (format-spec-make ?d repo-root)) t))))

(defun helm-cmd-t (arg)
  "Choose file from current repo.

With prefix arg \"-\", run `helm-cmd-t-caches'.
"
  (interactive "P")
  (when (eq arg '-)
    (call-interactively 'helm-cmd-t-caches))
  (let ((helm-ff-transformer-show-only-basename nil))
    (helm :sources (helm-cmd-t-get-create-source (helm-cmd-t-root-data))
          :candidate-number-limit 20
          :buffer "*helm-cmd-t:*")))

(defun helm-cmd-t-get-caches ()
  "return list of (display-text buffer) for caches suitable for completion"
  (let ((regexp (replace-regexp-in-string
                 "%s" "\\\\(.*\\\\)"
                 (regexp-quote helm-cmd-t-source-buffer-format)))
        res)
    (mapc (lambda (buf)
            (with-current-buffer buf
              (let ((b-name (buffer-name)))
                (when (and helm-cmd-t-data
                           (string-match regexp b-name))
                  (push (cons (helm-cmd-t-format-title buf)
                              b-name)
                        res)))))
          (buffer-list))
    res))

(defvar helm-c-source-cmd-t-caches
  `((name . "Cmd-t repo caches")
    (candidates . helm-cmd-t-get-caches)
    (persistent-action . helm-c-switch-to-buffer)
    (persistent-help . "Show buffer")
    (action . (("INVALIDATE" . helm-kill-marked-buffers)))
    (volatile)))


(defun helm-cmd-t-cache (&optional root)
  "Manage helm-cmd-t caches."
  (interactive)
  (let* ((root (or root (helm-cmd-t-root)))
         (source-buffer (get-buffer
                         (helm-cmd-t-get-source-buffer-name root))))
    (if (called-interactively-p 'any)
        (helm :sources helm-c-source-cmd-t-caches
              :preselect (when source-buffer
                           (helm-cmd-t-format-title source-buffer)))
      (when source-buffer
        (kill-buffer source-buffer)))))

(defun helm-cmd-t-elisp-find-insert (root)
  "insert contents of directory recursively."
  (require 'helm-cmd-t-find)
  (let ((reject-regexp (helm-cmd-t-dumb-glob-to-regexp (append
                                                        helm-cmd-t-find-ignored-files
                                                        helm-cmd-t-find-prunes
                                                        '("." ".."))))
        (default-directory (expand-file-name root)))
    (helm-cmd-t-insert-tree-1 nil reject-regexp)))

(defun helm-cmd-t-shell-find-insert (root)
  (let ((cmd (let ((default-directory "."))
               (find-cmd `(prune (name ,@helm-cmd-t-find-prunes))
                         `(not (name ,@helm-cmd-t-find-ignored-files)))))
        (default-directory root))
    (shell-command cmd t)
    (goto-char (point-min))
    (while (re-search-forward "^\\./?\n?" nil t)
      (replace-match "" nil nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; helm-cmd-t.el ends here

