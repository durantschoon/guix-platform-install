;;; manifest.scm -- GNU Guix manifest for GIPS dependencies and runtime tools.
;;;
;;; Provides all packages required to build, run, and interact with GIPS
;;; (GNU Guix IPFS Package Substitutes) on GNU Guix System:
;;;
;;; Usage:
;;;   # Enter an ad-hoc shell environment with all GIPS tools:
;;;   guix shell -m gips/manifest.scm
;;;
;;;   # Or install all GIPS tooling into the active user profile:
;;;   guix package -m gips/manifest.scm
;;;
;;; Includes:
;;;   - IPFS: go-ipfs (provides the 'ipfs' CLI and Kubo P2P daemon)
;;;   - Rust toolchain: rust, cargo, pkg-config, openssl, sqlite
;;;   - Scheme runtime: guile, guile-gcrypt (for libgcrypt narinfo signing)
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
      (and fallback (safe-specification->package fallback))))

;; Specifications with sensible fallbacks:
;; - IPFS is packaged as 'go-ipfs' in official GNU Guix (provides /bin/ipfs).
;; - Rust toolchain provides 'cargo'; in some channels 'cargo' is a distinct package.
;; - Guile 3.0 is aliased to 'guile'.
(define desired-packages
  (list
   (resolve-package "go-ipfs" "ipfs")
   (resolve-package "rust" #f)
   (resolve-package "cargo" #f)
   (resolve-package "pkg-config" #f)
   (resolve-package "openssl" #f)
   (resolve-package "sqlite" #f)
   (resolve-package "guile" "guile-3.0")
   (resolve-package "guile-gcrypt" #f)
   (resolve-package "just" #f)
   (resolve-package "curl" #f)
   (resolve-package "jq" #f)))

(packages->manifest
 (delete-duplicates
  (filter-map (lambda (x) x) desired-packages)))
