;;; test_sign.scm --- the `just scheme-test' gate: Guix narinfo signing, end to end.
;;;
;;; Usage:
;;;
;;;   guile test_sign.scm            (equivalently: just scheme-test)
;;;
;;; What this proves, and why it is shaped this way:
;;;
;;; The thing production runs is `components/gips-trust/guile/guix-sign.scm',
;;; driven as a subprocess by `gips_trust::guix::GuixSigner'.  So this suite
;;; drives *that file*, as a subprocess, with keys made by *that* keygen helper
;;; -- it does not re-implement signing.  A suite that signed with its own
;;; inline call to `sign' would go green while the shipped helper was broken,
;;; which is exactly the failure mode the previous version of this file had.
;;;
;;; The checking half is written here rather than borrowed, and it mirrors the
;;; two upstream procedures a real Guix client runs:
;;;
;;;   guix/narinfo.scm `narinfo-sha256'  -- the signed region is everything
;;;     before the index of "Signature:", and a narinfo missing any of
;;;     StorePath/NarHash/References is *unsigned* no matter what its
;;;     signature says.
;;;
;;;   guix/pki.scm `%signature-status'   -- the embedded `data' must carry the
;;;     recomputed hash, libgcrypt must verify `sig-val' against that data and
;;;     the embedded `public-key', and that key must be one the ACL
;;;     authorizes.  The ACL here is a single `.pub' file, compared after
;;;     re-rendering so key material and not whitespace is what is compared.
;;;
;;; Four verdicts are printed, and the exit status is 0 only if all four hold:
;;;
;;;   1. valid                        -- a freshly signed narinfo verifies.
;;;   2. tampered-body rejected       -- one changed byte below StorePath flips
;;;                                      the same checker to hash-mismatch.
;;;   3. wrong-key rejected           -- a narinfo signed by another key is
;;;                                      unauthorized-key against this ACL, and
;;;                                      libgcrypt itself rejects a swapped
;;;                                      public-key member.
;;;   4. helper self-check exercised  -- guix-sign.scm refuses (non-zero, no
;;;                                      signature on stdout) a mismatched
;;;                                      .sec/.pub pair and a body that Guix
;;;                                      would treat as unsigned.
;;;
;;; Verdicts 2 and 3 are the non-vacuity proof: the same procedure that says
;;; `valid-signature' for the good narinfo must say something else for the bad
;;; ones, so a checker that returned a constant could not pass this suite.

(use-modules (gcrypt pk-crypto)
             (gcrypt hash)
             (gcrypt base64)
             (gcrypt base16)
             (rnrs bytevectors)
             (ice-9 popen)
             (ice-9 match)
             (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; ---------------------------------------------------------------------------
;;; Locations
;;; ---------------------------------------------------------------------------

(define %repo-root
  ;; `current-filename' is resolved when this file is read, so the suite finds
  ;; the committed helpers whatever directory `guile' was started from.
  (let ((file (current-filename)))
    (if (string? file)
        (dirname (if (absolute-file-name? file)
                     file
                     (in-vicinity (getcwd) file)))
        (getcwd))))

(define %keygen (string-append %repo-root "/components/gips-trust/guile/guix-keygen.scm"))
(define %signer (string-append %repo-root "/components/gips-trust/guile/guix-sign.scm"))

(define %guile
  ;; The same interpreter that is running this suite, when we can name it;
  ;; `guile' on PATH otherwise (which is what the `scheme-test' recipe used to
  ;; get here in the first place).
  (let ((bindir (false-if-exception (assq-ref %guile-build-info 'bindir))))
    (if (and (string? bindir) (file-exists? (string-append bindir "/guile")))
        (string-append bindir "/guile")
        "guile")))

(define %tmp-dir
  ;; Owned by this process and removed on the way out.  0700 because it holds
  ;; secret keys, throwaway or not.
  (let* ((base (or (getenv "TMPDIR") "/tmp"))
         (dir (format #f "~a/gips-test-sign-~a" (string-trim-right base #\/) (getpid))))
    (when (file-exists? dir)
      (system* "/bin/rm" "-rf" dir))
    (mkdir dir #o700)
    dir))

(define (tmp name)
  (string-append %tmp-dir "/" name))

;;; ---------------------------------------------------------------------------
;;; Reporting
;;; ---------------------------------------------------------------------------

(define %failures 0)

(define (note fmt . args)
  (apply format #t (string-append "    " fmt "~%") args))

(define (check name ok?)
  "Record one assertion.  Returns OK? so callers can chain."
  (if ok?
      (format #t "  ok    ~a~%" name)
      (begin
        (set! %failures (+ %failures 1))
        (format #t "  FAIL  ~a~%" name)))
  ok?)

(define (verdict n name)
  (format #t "verdict ~a/4: ~a~%" n name))

;;; ---------------------------------------------------------------------------
;;; Subprocesses
;;; ---------------------------------------------------------------------------

(define (write-file path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (shell-quote s)
  (string-append "'" (string-join (string-split s #\') "'\\''") "'"))

(define (run-script script args stdin-file)
  "Run SCRIPT under Guile with ARGS, stdin read from STDIN-FILE (or /dev/null
when #f).  Returns (values EXIT-STATUS STDOUT-TEXT STDERR-TEXT).

Stdin comes from a file and stderr goes to a file so neither side can deadlock
against a pipe buffer, and so the exit status is observed rather than inferred
from the output."
  (let* ((err-file (tmp "stderr.txt"))
         (command (string-join
                   (append (list (shell-quote %guile) "-q" "--no-auto-compile"
                                 "-s" (shell-quote script) "--")
                           (map shell-quote args)
                           (list "<" (shell-quote (or stdin-file "/dev/null"))
                                 "2>" (shell-quote err-file)))
                   " "))
         (port (open-input-pipe command))
         (out (get-string-all port))
         (status (close-pipe port)))
    (values (status:exit-val status) out (read-file err-file))))

(define (generate-key-pair name)
  "Make a throwaway pair with the committed keygen helper.  Returns the secret
path; the public half is its `.pub' sibling, exactly as gips_trust pairs them."
  (let ((secret (tmp (string-append name ".sec")))
        (public (tmp (string-append name ".pub"))))
    (call-with-values (lambda () (run-script %keygen (list secret public) #f))
      (lambda (status out err)
        (unless (eqv? status 0)
          (format #t "  FAIL  guix-keygen.scm could not make key `~a' (status ~a)~%"
                  name status)
          (note "stderr: ~a" (string-trim-right err))
          (exit 1))))
    secret))

(define (public-key-path secret)
  (string-append (string-drop-right secret (string-length ".sec")) ".pub"))

(define (sign-body secret body)
  "Sign BODY with the committed signer helper.  Returns (values STATUS SEXP ERR)."
  (let ((body-file (tmp "body.narinfo")))
    (write-file body-file body)
    (run-script %signer (list secret (public-key-path secret)) body-file)))

;;; ---------------------------------------------------------------------------
;;; The checker: guix/narinfo.scm + guix/pki.scm, mirrored
;;; ---------------------------------------------------------------------------

(define %mandatory-fields '("StorePath:" "NarHash:" "References:"))

(define (narinfo-sha256 text)
  "The sha256 of the signed region of TEXT, or #f when Guix would call this
narinfo unsigned."
  (match (string-contains text "Signature:")
    (#f #f)
    (index
     (let ((above (string-take text index)))
       (and (every (lambda (field) (string-contains above field)) %mandatory-fields)
            (sha256 (string->utf8 above)))))))

(define (signature-payload text)
  "The base64 payload of the `Signature: 1;host;payload' line, or #f."
  (let loop ((lines (string-split text #\newline)))
    (match lines
      (() #f)
      ((line . rest)
       (if (string-prefix? "Signature: " line)
           (match (string-split (substring line (string-length "Signature: ")) #\;)
             ((version _ payload) (and (string=? version "1") payload))
             (_ #f))
           (loop rest))))))

(define (narinfo-status text authorized-key-path)
  "Decide TEXT the way a Guix client with AUTHORIZED-KEY-PATH in its ACL would.

Returns one of the upstream status names -- valid-signature, hash-mismatch,
invalid-signature, unauthorized-key -- or corrupt-signature / unsigned."
  (let ((hash (narinfo-sha256 text)))
    (if (not hash)
        'unsigned
        (let ((payload (signature-payload text)))
          (if (not payload)
              'unsigned
              (let ((signature
                     (catch #t
                       (lambda ()
                         (string->canonical-sexp (utf8->string (base64-decode payload))))
                       (lambda _ #f))))
                (if (not signature)
                    'corrupt-signature
                    ;; Upstream reads all three members by name, so presence is
                    ;; what matters here and not their order in the envelope.
                    (let ((data (find-sexp-token signature 'data))
                          (sig-val (find-sexp-token signature 'sig-val))
                          (public (find-sexp-token signature 'public-key)))
                      (cond
                       ((not (and data sig-val public)) 'corrupt-signature)
                       ;; 1. the signed digest is the digest of *this* text
                       ((not (bytevector=? (hash-data->bytevector data) hash))
                        'hash-mismatch)
                       ;; 2. libgcrypt agrees the signature covers that data
                       ((not (catch #t
                               (lambda () (verify sig-val data public))
                               (lambda _ #f)))
                        'invalid-signature)
                       ;; 3. the signer is a key the ACL authorizes.  Both
                       ;; sides are re-rendered by libgcrypt, so this compares
                       ;; key material, not the file's whitespace.
                       ((not (string=? (canonical-sexp->string public)
                                       (canonical-sexp->string
                                        (string->canonical-sexp
                                         (read-file authorized-key-path)))))
                        'unauthorized-key)
                       (else 'valid-signature))))))))))

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(define %store-hash "0hzmc5r1yvcmsrb3wp0pn4jd0mjpx8p3")

(define %body
  ;; A realistic narinfo body: the exact bytes served before the `Signature:'
  ;; token, trailing newline included.  StorePath/NarHash/References are all
  ;; present, because without them Guix ignores the signature entirely.
  (string-append
   "StorePath: /gnu/store/" %store-hash "-hello-2.12.1\n"
   "URL: nar/gzip/" %store-hash "-hello-2.12.1\n"
   "Compression: gzip\n"
   "FileHash: sha256:1c1p1v0kx6dm11a3s5x1blvyk1w0nyz8s0j0f4hp4r1zqvhq3h20\n"
   "FileSize: 51200\n"
   "NarHash: sha256:0f8p1k2z9m3q7r5t1v6w8x0y2a4c6e8g0i2k4m6o8q0s2u4w6y8\n"
   "NarSize: 245760\n"
   "References: " %store-hash "-hello-2.12.1 1b8p8g2s7j0m9d3n5k7q9v1x3z5b7d9f-glibc-2.35\n"
   "Deriver: 3k9m1p5r7t9v1x3z5b7d9f1h3j5l7n9p-hello-2.12.1.drv\n"
   "System: x86_64-linux\n"))

(define (assemble body sexp)
  "BODY plus the `Signature:' line gipsd would append -- the bytes on the wire.
Guix base64s the *advanced* rendering's UTF-8 bytes, which is what
`gips_trust::guix::signature_payload' does on the Rust side."
  (string-append body
                 "Signature: 1;builder.example;"
                 (base64-encode (string->utf8 sexp))
                 "\n"))

(define (envelope data sig-val public)
  "Re-assemble a `(signature data sig-val public-key)' envelope from members,
the way guix-sign.scm does: every byte is rendered by libgcrypt, so a spliced
envelope is as well-formed as an honest one and the checker has to reject it on
the cryptography rather than on the syntax.  Returns the advanced rendering."
  (canonical-sexp->string
   (string->canonical-sexp
    (string-append "(signature\n"
                   (canonical-sexp->string data)
                   (canonical-sexp->string sig-val)
                   (canonical-sexp->string public)
                   ")"))))

(define (substitute text from to)
  (match (string-contains text from)
    (#f (error "substitute: fixture text does not contain" from))
    (index (string-append (string-take text index)
                          to
                          (string-drop text (+ index (string-length from)))))))

;;; ---------------------------------------------------------------------------
;;; The suite
;;; ---------------------------------------------------------------------------

(define (main)
  (format #t "test_sign.scm: Guix narinfo signing, end to end~%")
  (format #t "  guile:  ~a~%" %guile)
  (format #t "  signer: ~a~%" %signer)
  (format #t "  tmpdir: ~a~%~%" %tmp-dir)

  (let* ((mine (generate-key-pair "signing-key"))
         (theirs (generate-key-pair "other-key"))
         (my-pub (public-key-path mine))
         (their-pub (public-key-path theirs)))

    (check "guix-keygen.scm wrote both halves of two distinct pairs"
           (and (file-exists? mine) (file-exists? my-pub)
                (file-exists? theirs) (file-exists? their-pub)
                (not (string=? (read-file my-pub) (read-file their-pub)))))

    ;; ---------------------------------------------------------------------
    (verdict 1 "valid")
    (let ((narinfo
           (call-with-values (lambda () (sign-body mine %body))
             (lambda (status sexp err)
               (unless (check "guix-sign.scm exited 0" (eqv? status 0))
                 (note "stderr: ~a" (string-trim-right err)))
               (check "its output is an advanced (signature ...) sexp"
                      (and (string-prefix? "(signature" (string-trim sexp))
                           (string-contains sexp "(sig-val")
                           (string-contains sexp "(ecdsa")
                           (string-contains sexp "(public-key")))
               (assemble %body sexp)))))

    (let ((status (narinfo-status narinfo my-pub)))
      (unless (check (format #f "the served narinfo verifies: ~a" status)
                     (eq? status 'valid-signature))
        (note "expected valid-signature")))

    ;; The digest the client recomputes is the digest of the region above the
    ;; `Signature:' token -- state it as its own assertion so a checker that
    ;; hashed the whole document could not sneak past verdict 1.
    (check "the recomputed hash covers exactly the pre-Signature: region"
           (bytevector=? (narinfo-sha256 narinfo) (sha256 (string->utf8 %body))))

    ;; ---------------------------------------------------------------------
    (verdict 2 "tampered-body rejected")
    ;; Deliberately break the body *after* signing: one digit of NarSize, the
    ;; field a substitute server would lie about to smuggle a different nar.
    ;; The signature bytes are untouched, so only the hash comparison can catch
    ;; it -- and it must, or verdict 1 above proves nothing.
    (let* ((tampered (substitute narinfo "NarSize: 245760" "NarSize: 245761"))
           (status (narinfo-status tampered my-pub)))
      (check "a changed NarSize is rejected"
             (not (eq? status 'valid-signature)))
      (check (format #f "and rejected as hash-mismatch, not by accident: ~a" status)
             (eq? status 'hash-mismatch)))

    ;; A body Guix would call unsigned must not be reported as valid either,
    ;; whatever the signature line says.
    (let* ((no-refs (substitute narinfo "References: " "Refs: "))
           (status (narinfo-status no-refs my-pub)))
      (check (format #f "a narinfo with no References: line is unsigned: ~a" status)
             (eq? status 'unsigned)))

    ;; ---------------------------------------------------------------------
    (verdict 3 "wrong-key rejected")
    ;; Same good narinfo, a client whose ACL holds someone else's key.
    (let ((status (narinfo-status narinfo their-pub)))
      (check (format #f "an unauthorized signer is refused: ~a" status)
             (eq? status 'unauthorized-key)))

    ;; And the other direction: a narinfo genuinely signed by the other key is
    ;; refused by a client that authorizes only ours.
    (call-with-values (lambda () (sign-body theirs %body))
      (lambda (status sexp err)
        (unless (check "guix-sign.scm signs with the second key too" (eqv? status 0))
          (note "stderr: ~a" (string-trim-right err)))
        (let ((status (narinfo-status (assemble %body sexp) my-pub)))
          (check (format #f "a foreign signature over the same body is refused: ~a" status)
                 (eq? status 'unauthorized-key)))))

    ;; Splicing our authorized public key into someone else's signature does
    ;; not launder it: libgcrypt rejects the sig-val before the ACL is reached.
    (call-with-values (lambda () (sign-body theirs %body))
      (lambda (_status sexp _err)
        (let* ((foreign (string->canonical-sexp sexp))
               (spliced (envelope (find-sexp-token foreign 'data)
                                  (find-sexp-token foreign 'sig-val)
                                  (string->canonical-sexp (read-file my-pub))))
               (status (narinfo-status (assemble %body spliced) my-pub)))
          (check (format #f "swapping in an authorized public key does not launder it: ~a"
                         status)
                 (eq? status 'invalid-signature)))))

    ;; ---------------------------------------------------------------------
    (verdict 4 "helper self-check exercised")
    ;; guix-sign.scm verifies its own output before printing it. Hand it a
    ;; `.sec' and a `.pub' that do not belong together: it must fail loudly and
    ;; print no signature, rather than emit something no client can check.
    (let ((mismatched (tmp "mismatched.sec")))
      (write-file mismatched (read-file mine))
      (write-file (public-key-path mismatched) (read-file their-pub))
      (call-with-values (lambda () (sign-body mismatched %body))
        (lambda (status out err)
          (check "a mismatched .sec/.pub pair is refused (non-zero)"
                 (not (eqv? status 0)))
          (check "and nothing that looks like a signature reaches stdout"
                 (not (string-contains out "(signature")))
          (check "and the reason names the self-check"
                 (string-contains err "self-check failed")))))

    ;; The helper also refuses to sign a body Guix would ignore, so the useless
    ;; signature is never made in the first place.
    (call-with-values
        (lambda () (sign-body mine (substitute %body "References: " "Refs: ")))
      (lambda (status out err)
        (check "a body with no References: line is refused (non-zero)"
               (not (eqv? status 0)))
        (check "and the reason names the missing field"
               (string-contains err "References:"))
        (check "and nothing reaches stdout" (string-null? out))))

    ;; Signing something that already carries a `Signature:' token would hash a
    ;; region no client recomputes; the helper refuses that too.
    (call-with-values (lambda () (sign-body mine narinfo))
      (lambda (status out err)
        (check "an already-signed body is refused (non-zero)"
               (not (eqv? status 0)))
        (check "and the reason names the Signature: token"
               (string-contains err "Signature:"))))))

  (newline)
  (if (zero? %failures)
      (begin
        (format #t "test_sign.scm: all four verdicts hold~%")
        0)
      (begin
        (format #t "test_sign.scm: ~a assertion(s) failed~%" %failures)
        1)))

(define %status
  ;; Run under a handler so an unexpected exception is a loud failure with a
  ;; backtrace rather than a green gate.
  (catch #t
    main
    (lambda (key . args)
      (format #t "~%test_sign.scm: unhandled exception: ~a ~a~%" key args)
      1)
    (lambda (key . args)
      (backtrace))))

(system* "/bin/rm" "-rf" %tmp-dir)
(exit %status)
