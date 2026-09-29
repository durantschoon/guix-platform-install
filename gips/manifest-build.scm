;;; manifest-build.scm -- GNU Guix manifest for GIPS build dependencies.
;;;
;;; Provides all packages required to build GIPS from source:
;;;
;;; Usage:
;;;   guix shell -m gips/manifest.scm -m gips/manifest-build.scm
;;;
;;; Includes:
;;;   - Rust toolchain: rust, pkg-config, openssl, sqlite (rust includes cargo)

(use-modules (guix profiles)
             (gnu packages)
             (srfi srfi-1))

(define (safe-specification->package spec)
  "Look up SPEC in Guix package index; return #f if not found."
  (catch #t
    (lambda ()
      (specification->package spec))
    (lambda _
      #f)))

(define (resolve-package spec fallback)
  "Resolve SPEC, or FALLBACK if SPEC is unavailable."
  (or (safe-specification->package spec)
      (and fallback (safe-specification->package fallback))
      (begin
        (format (current-error-port)
                "[WARN] gips/manifest-build.scm: no package found for ~s~a\n"
                spec (if fallback (format #f " (nor fallback ~s)" fallback) ""))
        #f)))

(define desired-packages
  (list
   (resolve-package "rust" #f)
   (resolve-package "pkg-config" #f)
   (resolve-package "openssl" #f)
   (resolve-package "sqlite" #f)))

(packages->manifest
 (delete-duplicates
  (filter-map (lambda (x) x) desired-packages)))
