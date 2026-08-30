;;; guix-keygen.scm --- generate a Guix-compatible narinfo signing key pair.
;;;
;;; Usage:
;;;
;;;   guile -s guix-keygen.scm -- SECRET-KEY-PATH PUBLIC-KEY-PATH
;;;
;;; The pair is an ECC key on the Ed25519 curve carrying libgcrypt's `rfc6979'
;;; flag, which is what `guix publish' signs narinfos with and what
;;; `guix archive --authorize' consumes.  Both halves are written in
;;; libgcrypt's *advanced* (human-readable) rendering, byte-for-byte the shape
;;; of /etc/guix/signing-key.{sec,pub}.
;;;
;;; Nothing here decides file permissions: the caller creates both paths 0600
;;; inside a 0700 directory *before* invoking this script and refuses to
;;; overwrite an existing key, so the ceremony's fail-closed behaviour lives in
;;; one place (Rust, next to the rest of the filesystem-integrity checks) and
;;; this script stays a pure "make me a key" function.
;;;
;;; Exit status: 0 on success, 2 on bad arguments, non-zero on any libgcrypt or
;;; I/O failure.  A partial success is not possible to observe as success --
;;; the public half is written first, so a crash mid-way leaves a secret file
;;; that is still empty rather than a secret with no matching public key.

(use-modules (gcrypt pk-crypto)
             (ice-9 match))

(define %genkey-spec
  ;; The parameters libgcrypt is asked to generate against.  `rfc6979' selects
  ;; deterministic ECDSA: the same key and the same digest always yield the
  ;; same signature, which is what makes serve-time signature caching sound.
  ;; (`transient' is *not* passed: the installed libgcrypt rejects the
  ;; combination.)
  "(genkey (ecc (curve Ed25519) (flags rfc6979)))")

(define (write-sexp sexp path)
  "Write the advanced rendering of SEXP into PATH, truncating it."
  (call-with-output-file path
    (lambda (port)
      (display (canonical-sexp->string sexp) port))))

(define (die fmt . args)
  (apply format (current-error-port) fmt args)
  (newline (current-error-port))
  (exit 1))

(define (main arguments)
  (match arguments
    ((_ "--" secret-path public-path)
     (let* ((pair (generate-key (string->canonical-sexp %genkey-spec)))
            (public (find-sexp-token pair 'public-key))
            (secret (find-sexp-token pair 'private-key)))
       (unless public
         (die "guix-keygen: libgcrypt returned no public-key half"))
       (unless secret
         (die "guix-keygen: libgcrypt returned no private-key half"))
       (write-sexp public public-path)
       (write-sexp secret secret-path)
       (exit 0)))
    (_
     (format (current-error-port)
             "usage: guile -s guix-keygen.scm -- SECRET-KEY-PATH PUBLIC-KEY-PATH~%")
     (exit 2))))

(main (command-line))
