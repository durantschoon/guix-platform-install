;;; manifest.scm -- GNU Guix runtime manifest for GIPS.
;;;
;;; Provides all packages required to run and interact with prebuilt GIPS
;;; binaries on GNU Guix System:
;;;
;;; Usage:
;;;   # Enter an ad-hoc shell environment with all GIPS runtime tools:
;;;   guix shell -m gips/manifest.scm
;;;
;;;   # Or install all GIPS tooling into the active user profile:
;;;   guix package -m gips/manifest.scm
;;;
;;; Includes:
;;;   - IPFS: kubo (provides the 'ipfs' CLI and Kubo P2P daemon)
;;;   - Scheme runtime: guile, guile-gcrypt, guile-json
;;;   - Discovery: gnunet
;;;   - Utilities: just, curl, jq

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
                "[WARN] gips/manifest.scm: no package found for ~s~a; it is NOT in this profile\n"
                spec (if fallback (format #f " (nor fallback ~s)" fallback) ""))
        #f)))

(define desired-packages
  (list
   (resolve-package "kubo" "go-ipfs")
   (resolve-package "guile" "guile-3.0")
   (resolve-package "guile-gcrypt" #f)
   (resolve-package "guile-json" #f)
   (resolve-package "gnunet" #f)
   (resolve-package "just" #f)
   (resolve-package "curl" #f)
   (resolve-package "jq" #f)
   (resolve-package "rust" #f)
   (list (resolve-package "rust" #f) "cargo")))

(packages->manifest
 (delete-duplicates
  (filter-map (lambda (x) x) desired-packages)))
