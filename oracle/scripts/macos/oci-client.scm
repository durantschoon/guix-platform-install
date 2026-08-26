;;; oci-client.scm --- OCI CLI discovery used only on macOS.
;;;
;;; oci-common.scm conditionally loads this file after uname reports Darwin.
;;; Keep Homebrew paths here so Guix/Linux controllers never read or depend on
;;; Mac-specific filesystem conventions.

(define (macos-resolve-oci-cli)
  "Return the first executable OCI CLI installed by native or Intel Homebrew."
  (let loop ((candidates '("/opt/homebrew/bin/oci" "/usr/local/bin/oci")))
    (cond ((null? candidates) (home-path ".venvs" "oci-cli" "bin" "oci"))
          ((access? (car candidates) X_OK) (car candidates))
          (else (loop (cdr candidates))))))
