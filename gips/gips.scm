;;; gips.scm --- GNU Guix package entrypoint for GIPS
;;;
;;; Usage:
;;;   guix build -f gips.scm
;;;   guix shell -f gips.scm

(use-modules (ice-9 format)
             (srfi srfi-1))

(define %repo-root
  (let ((file (current-filename)))
    (if (string? file)
        (dirname (if (absolute-file-name? file) file (in-vicinity (getcwd) file)))
        (getcwd))))

(set! %load-path (cons (string-append %repo-root "/scheme") %load-path))

(use-modules (gips package))

(gips-package)
