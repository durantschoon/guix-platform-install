;;; guix-oracle.scm --- decide a served narinfo the way Guix decides it.
;;;
;;; Usage:
;;;
;;;   guile -s guix-oracle.scm -- AUTHORIZED-PUBLIC-KEY-PATH < NARINFO
;;;
;;; This is the *checking* half of the stage, written independently of the
;;; signing half and deliberately in the same language Guix itself uses, so
;;; that "our signer and our verifier agree" is not the thing being tested.
;;; It mirrors two upstream procedures:
;;;
;;;   guix/narinfo.scm `narinfo-sha256'  -- the hashed region is everything
;;;     before the index of "Signature:", and a narinfo missing any of
;;;     StorePath/NarHash/References counts as unsigned no matter what the
;;;     signature says.
;;;
;;;   guix/pki.scm `%signature-status'   -- the embedded `data' must carry the
;;;     recomputed hash, libgcrypt must verify the `sig-val' against that data
;;;     and the embedded `public-key', and that key must be one the ACL
;;;     authorizes.  Here the ACL is the single key file named on the command
;;;     line, compared byte-for-byte after re-rendering.
;;;
;;; Output: one `key: value' line per finding, then `verdict: <status>'.
;;; Statuses are upstream's names -- valid-signature, hash-mismatch,
;;; invalid-signature, unauthorized-key -- plus corrupt-signature (the payload
;;; is not a signature sexp at all) and unsigned (no usable signature line).
;;; Exit status is 0 only for valid-signature, so a caller can treat this as a
;;; pass/fail oracle without parsing anything.

(use-modules (gcrypt pk-crypto)
             (gcrypt hash)
             (gcrypt base64)
             (gcrypt base16)
             (rnrs bytevectors)
             (ice-9 match)
             (ice-9 binary-ports)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define %mandatory-fields '("StorePath:" "NarHash:" "References:"))

(define (report key value)
  (format #t "~a: ~a~%" key value))

(define (verdict status)
  (report "verdict" status)
  (exit (if (eq? status 'valid-signature) 0 1)))

(define (narinfo-sha256 text)
  "The sha256 of the signed region of TEXT, or #f when Guix would call this
narinfo unsigned."
  (match (string-contains text "Signature:")
    (#f #f)
    (index
     (let ((above (string-take text index)))
       (and (every (lambda (field) (string-contains above field))
                   %mandatory-fields)
            (sha256 (string->utf8 above)))))))

(define (signature-payload text)
  "The base64 payload of the `Signature: 1;host;payload' line, or #f."
  (let loop ((lines (string-split text #\newline)))
    (match lines
      (() #f)
      ((line . rest)
       (if (string-prefix? "Signature: " line)
           (match (string-split (substring line (string-length "Signature: "))
                                #\;)
             ((version host payload)
              (report "sig-version" version)
              (report "sig-host" host)
              (and (string=? version "1") payload))
             (_ #f))
           (loop rest))))))

(define (main arguments)
  (match arguments
    ((_ "--" authorized-key-path)
     (let* ((text (get-string-all (current-input-port)))
            (hash (narinfo-sha256 text)))
       (unless hash
         (report "reason" "no Signature: line, or a mandatory field is missing")
         (verdict 'unsigned))
       (report "recomputed-hash" (bytevector->base16-string hash))

       (let ((payload (signature-payload text)))
         (unless payload (verdict 'unsigned))

         (let ((signature
                (catch #t
                  (lambda ()
                    (string->canonical-sexp (utf8->string (base64-decode payload))))
                  (lambda args
                    (report "reason" args)
                    (verdict 'corrupt-signature)))))

           ;; Upstream reads all three members by name, so order in the
           ;; envelope is not what is being checked here -- presence is.
           (let ((data (find-sexp-token signature 'data))
                 (sig-val (find-sexp-token signature 'sig-val))
                 (public (find-sexp-token signature 'public-key)))
             (unless (and data sig-val public)
               (report "reason" "signature sexp lacks data, sig-val or public-key")
               (verdict 'corrupt-signature))

             (report "embedded-hash"
                     (bytevector->base16-string (hash-data->bytevector data)))
             (report "is-ecdsa"
                     (if (find-sexp-token sig-val 'ecdsa) "yes" "no"))

             ;; 1. the signed digest is the digest of *this* text
             (unless (bytevector=? (hash-data->bytevector data) hash)
               (verdict 'hash-mismatch))
             (report "hash-matches" "yes")

             ;; 2. libgcrypt agrees the signature covers that data
             (unless (catch #t
                       (lambda () (verify sig-val data public))
                       (lambda _ #f))
               (verdict 'invalid-signature))
             (report "verify" "yes")

             ;; 3. the signer is a key we authorize.  Both sides are rendered
             ;; by libgcrypt from parsed sexps, so this compares key material
             ;; and not the whitespace of whoever wrote the file.
             (let ((authorized (string->canonical-sexp
                                (call-with-input-file authorized-key-path
                                  get-string-all))))
               (unless (string=? (canonical-sexp->string public)
                                 (canonical-sexp->string authorized))
                 (verdict 'unauthorized-key))
               (report "key-matches-authorized" "yes"))

             (verdict 'valid-signature))))))
    (_
     (format (current-error-port)
             "usage: guile -s guix-oracle.scm -- AUTHORIZED-PUBLIC-KEY-PATH < NARINFO~%")
     (exit 2))))

(main (command-line))
