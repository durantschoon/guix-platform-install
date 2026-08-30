;;; guix-sign.scm --- sign a narinfo body the way `guix publish' does.
;;;
;;; Usage:
;;;
;;;   guile -s guix-sign.scm -- SECRET-KEY-PATH PUBLIC-KEY-PATH < BODY
;;;
;;; BODY is the exact byte sequence the narinfo serves *before* the
;;; `Signature:' token -- trailing newline included.  That is precisely what
;;; `narinfo-sha256' in guix/narinfo.scm hashes: it takes the contents up to
;;; the index of "Signature:" and sha256s their UTF-8 bytes.
;;;
;;; On success the advanced rendering of
;;;
;;;   (signature (data (flags rfc6979) (hash sha256 #...#))
;;;              (sig-val (ecdsa (r #...#) (s #...#)))
;;;              (public-key (ecc (curve Ed25519) (q #...#))))
;;;
;;; goes to stdout and nothing else does.  The caller base64s those bytes into
;;; `Signature: 1;<host>;<base64>'.
;;;
;;; Why the body rather than a precomputed digest: the hash region, the
;;; mandatory-field rule and the signature are one indivisible fact about one
;;; text.  Splitting the digest out to a caller in another language means two
;;; implementations of `narinfo-sha256' that can drift; keeping them here means
;;; the script cannot be made to sign a digest of something Guix would hash
;;; differently.
;;;
;;; Exit status: 0 on success, 2 on bad arguments, non-zero on a rejected body,
;;; a bad key, or a libgcrypt failure.  Never 0 with an unusable signature on
;;; stdout: the signature is verified here before it is printed.

(use-modules (gcrypt pk-crypto)
             (gcrypt hash)
             (rnrs bytevectors)
             (ice-9 match)
             (ice-9 binary-ports)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define %mandatory-fields
  ;; guix/narinfo.scm treats a narinfo as *unsigned* -- silently, no error --
  ;; unless all three appear above the signature.  Refusing here turns that
  ;; silent uselessness into a loud failure at the moment the signature is
  ;; made.
  '("StorePath:" "NarHash:" "References:"))

(define (die fmt . args)
  (apply format (current-error-port) fmt args)
  (newline (current-error-port))
  (exit 1))

(define (read-key path)
  "Parse the advanced-rendered key sexp stored at PATH."
  (catch #t
    (lambda ()
      (string->canonical-sexp (call-with-input-file path get-string-all)))
    (lambda (key . args)
      (die "guix-sign: cannot read key ~a: ~a ~a" path key args))))

(define (read-body)
  "Read the whole of stdin as bytes.  An empty body is not an error here; the
mandatory-field check below rejects it."
  (let ((bv (get-bytevector-all (current-input-port))))
    (if (eof-object? bv) #vu8() bv)))

(define (check-body text)
  (for-each (lambda (field)
              (unless (string-contains text field)
                (die "guix-sign: refusing to sign: the body has no ~a line; \
Guix would treat the result as unsigned"
                     field)))
            %mandatory-fields)
  (when (string-contains text "Signature:")
    (die "guix-sign: refusing to sign: the body already contains a Signature: \
token, so the hashed region would not be the one Guix recomputes")))

(define (signature-sexp data sig public)
  "Assemble the `signature' envelope.  The three members are rendered by
libgcrypt and re-parsed by libgcrypt, so every byte on stdout is libgcrypt's
own -- this script never formats an sexp by hand."
  (string->canonical-sexp
   (string-append "(signature\n"
                  (canonical-sexp->string data)
                  (canonical-sexp->string sig)
                  (canonical-sexp->string public)
                  ")")))

(define (main arguments)
  (match arguments
    ((_ "--" secret-path public-path)
     (let* ((body (read-body))
            (text (catch #t
                    (lambda () (utf8->string body))
                    (lambda _ (die "guix-sign: the body is not valid UTF-8")))))
       (check-body text)
       (let* ((secret (read-key secret-path))
              (public (read-key public-path))
              (data (bytevector->hash-data (sha256 body) #:key-type 'ecc))
              (sig (sign data secret)))
         ;; Verify before printing.  A signature this process cannot itself
         ;; check is one no client will be able to check either, and emitting
         ;; it would put a broken `Signature:' line on the wire under a 200.
         (unless (verify sig data public)
           (die "guix-sign: self-check failed: the fresh signature does not \
verify against the public key -- the .sec and .pub files do not match"))
         (display (canonical-sexp->string (signature-sexp data sig public)))
         (exit 0))))
    (_
     (format (current-error-port)
             "usage: guile -s guix-sign.scm -- SECRET-KEY-PATH PUBLIC-KEY-PATH < BODY~%")
     (exit 2))))

(main (command-line))
