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
;;;   - IPFS: kubo (provides the 'ipfs' CLI and Kubo P2P daemon)
;;;   - Rust toolchain: rust, pkg-config, openssl, sqlite (rust includes cargo)
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
  "Resolve SPEC, or FALLBACK if SPEC is unavailable.  A spec that resolves to
nothing is still dropped (so one renamed package does not make the whole
manifest unusable), but it is reported on stderr: a manifest that silently
omits kubo installs cleanly and then GIPS cannot start, which is a worse
failure than a warning."
  (or (safe-specification->package spec)
      (and fallback (safe-specification->package fallback))
      (begin
        (format (current-error-port)
                "[WARN] gips/manifest.scm: no package found for ~s~a; it is NOT in this profile\n"
                spec (if fallback (format #f " (nor fallback ~s)" fallback) ""))
        #f)))

;; Specifications with sensible fallbacks:
;; - Kubo is packaged as 'kubo' in current GNU Guix (provides /bin/ipfs).
;; - The 'rust' package provides both rustc and cargo.
;; - Guile 3.0 is aliased to 'guile'.
(define desired-packages
  (list
   (resolve-package "kubo" "go-ipfs")
   (resolve-package "rust" #f)
   (resolve-package "pkg-config" #f)
   (resolve-package "openssl" #f)
   (resolve-package "sqlite" #f)
   (resolve-package "guile" "guile-3.0")
   (resolve-package "guile-gcrypt" #f)
   ;; gipsd's narinfo-signing helpers (components/gips-trust/guile/) import
   ;; (json); without it every signing attempt fails at run time.
   (resolve-package "guile-json" #f)
   ;; Discovery is real GNS (decision 2026-09-21): a spoke finds a hub's feed
   ;; by resolving its name through a local GNUnet peer, and the hub publishes
   ;; it with gnunet-namestore.  No GNUnet, no cross-machine sync.
   (resolve-package "gnunet" #f)
   (resolve-package "just" #f)
   (resolve-package "curl" #f)
   (resolve-package "jq" #f)))

(packages->manifest
 (delete-duplicates
  (filter-map (lambda (x) x) desired-packages)))
