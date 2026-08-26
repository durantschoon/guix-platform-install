#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-oracle-image.scm --- evaluation tests for the Oracle image config.
;;;
;;; Guile per the language policy; the thing under test is a Guile file that
;;; evaluates to an <operating-system>.
;;;
;;; These are EVALUATION tests, not build tests. `guix system image` takes an
;;; hour; evaluation takes seconds and catches the entire class of error that
;;; actually bit during development -- unbalanced parens, an unbound variable
;;; because a package module was not imported (wget), a field that does not
;;; exist. None of that should require an hour to discover, and none of it
;;; should reach an image upload.
;;;
;;; What these tests CANNOT cover: the metadata service's behaviour on a live
;;; OCI instance. QEMU has no metadata service at 169.254.169.254, so only the
;;; "no metadata available" path is reachable locally. See
;;; docs/ORACLE_ONE_CLICK_ROADMAP.md -- a live-instance launch with
;;; --metadata ssh_authorized_keys and no baked-in key is the real test.
;;;
;;; Run: guile --no-auto-compile -s oracle/tests/test-oracle-image.scm
;;; Exits 0 if every check passes, 1 otherwise. Requires guix on PATH.

(use-modules (ice-9 popen)
             (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (absolute path)
  "Resolve PATH against the working directory if it is not already absolute.
Required because the generated program is loaded from /tmp, and Guile's 'load'
resolves a relative path against the LOADING file's directory -- which would
look for the config under /tmp."
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define image-config
  (string-append repository-root "/oracle/image/oracle-image.scm"))
(define authorized-key
  (string-append repository-root "/oracle/image/authorized-key.pub"))
(define metadata-helper
  (string-append repository-root "/oracle/image/metadata-ssh-keys.scm"))

(load metadata-helper)

(define failures 0)
(define checks 0)

(define (pass text)
  (set! checks (+ checks 1))
  (format #t "  \x1b[0;32m[OK]\x1b[0m   ~a\n" text))

(define (fail text detail)
  (set! checks (+ checks 1))
  (set! failures (+ failures 1))
  (format #t "  \x1b[0;31m[FAIL]\x1b[0m ~a\n" text)
  (unless (string-null? detail)
    (for-each (lambda (line) (format #t "         ~a\n" line))
              (string-split (string-trim-right detail) #\newline))))

(define* (check text ok? #:optional (detail ""))
  (if ok? (pass text) (fail text detail)))

(define (authorized-keys-verdict)
  "Inspect the openssh service's authorized-keys VALUE, keyless.

Evaluation is not enough here, and that gap cost a full image build on
2026-08-09.  Making %authorized-key optional without also making the
authorized-keys FIELD conditional emitted

    ((\"guix\" #f))

which evaluates to a perfectly good <operating-system> and then dies an hour
later inside the builder:

    ERROR: In procedure open-file: Wrong type (expecting string): #f

The builder only runs at BUILD time, so `guix system image` was the first thing
to notice.  Reading the service's value catches it in seconds.  Returns
\"clean\", \"HAS-FALSE\", or an error string."
  (let ((program-file (string-append "/tmp/oracle-keys-probe-"
                                     (number->string (getpid)) ".scm")))
    (call-with-output-file program-file
      (lambda (port)
        (format port "(use-modules (gnu system) (gnu services) (gnu services ssh) (srfi srfi-1))\n")
        (format port "(let* ((os (load ~s))\n" image-config)
        (format port "       (svcs (operating-system-user-services os))\n")
        (format port "       (ssh (find (lambda (s) (eq? (service-kind s) openssh-service-type)) svcs)))\n")
        (format port "  (if (not ssh) (display \"NO-SSH-SERVICE\")\n")
        (format port "      (let ((keys (openssh-configuration-authorized-keys (service-value ssh))))\n")
        (format port "        (display (if (any (lambda (e) (any not e)) keys) \"HAS-FALSE\" \"clean\"))))\n")
        (format port "  (newline))\n")))
    (let* ((command (format #f "guix repl -q ~s 2>&1" program-file))
           (port (open-input-pipe command))
           (output (get-string-all port)))
      (close-pipe port)
      (delete-file program-file)
      (cond ((not (string? output)) "no output")
            ((string-contains output "HAS-FALSE") "HAS-FALSE")
            ((string-contains output "clean") "clean")
            (else (string-trim-both output))))))

(define (evaluate-config)
  "Load the image config through 'guix repl' and report whether it yields an
<operating-system>.  Returns (success? . output).

The program is written to a file rather than piped in via printf: printf
interprets backslash escapes, which mangles a Scheme program into something
whose error message ('\\n: unbound variable') points nowhere near the cause."
  (let ((program-file (string-append "/tmp/oracle-image-eval-"
                                     (number->string (getpid)) ".scm")))
    (call-with-output-file program-file
      (lambda (port)
        (format port "(use-modules (gnu system))\n")
        (format port "(let ((os (load ~s)))\n" image-config)
        (format port "  (display (if (operating-system? os) \"OS-OK\" \"NOT-AN-OS\"))\n")
        (format port "  (newline))\n")))
    (let* ((command (format #f "guix repl -q ~s 2>&1" program-file))
           (port (open-input-pipe command))
           (output (get-string-all port)))
      (close-pipe port)
      (delete-file program-file)
      (cons (and (string? output) (string-contains output "OS-OK") #t)
            (if (string? output) output "")))))

(format #t "\x1b[1;34mTesting the Oracle image configuration\x1b[0m\n")
(format #t "  Config: ~a\n\n" image-config)

;; Metadata parsing and retry policy are pure when their effects are injected.
(define fixture-key "ssh-ed25519 AAAATEST metadata@test")

(check "metadata keys accept raw and JSON-quoted leaf values"
       (equal? (metadata-usable-keys
                (list fixture-key (string-append "  \"" fixture-key "\"  ")))
               (list fixture-key fixture-key)))

(check "metadata keys reject empty, HTML, and non-key lines"
       (null? (metadata-usable-keys
               '("" "<html>not found</html>" "AAAA only" "rsa-sha2-512 bad"))))

(let ((calls 0) (waits '()) (messages '()))
  (let ((result
         (metadata-retry
          (lambda ()
            (set! calls (+ calls 1))
            (if (= calls 3) (list fixture-key) #f))
          (lambda (seconds) (set! waits (cons seconds waits)))
          (lambda args (set! messages (cons args messages)))
          5 3)))
    (check "metadata retry succeeds after a delayed third response"
           (and (eq? (car result) 'installed)
                (= (cadr result) 3)
                (equal? (cddr result) (list fixture-key))
                (= calls 3)
                (equal? (reverse waits) '(3 3))
                (= (length messages) 2)))))

(let ((calls 0) (waits 0))
  (let ((result
         (metadata-retry
          (lambda () (set! calls (+ calls 1)) #f)
          (lambda _ (set! waits (+ waits 1)))
          (lambda _ #t)
          4 1)))
    (check "metadata retry exhaustion is bounded exactly"
           (and (equal? result '(exhausted 4)) (= calls 4) (= waits 3)))))

;; 1. The normal case: a baked-in key is present.
(let ((had-key? (file-exists? authorized-key)))
  (unless had-key?
    (call-with-output-file authorized-key
      (lambda (port)
        (display "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@test\n" port))))

  (let ((result (evaluate-config)))
    (check "evaluates with a baked-in authorized-key.pub"
           (car result) (cdr result)))

  ;; 2. The case the whole roadmap depends on: NO baked-in key.
  ;;
  ;; This is what makes one published image usable by anyone -- the key arrives
  ;; from instance metadata instead. If this stops evaluating, the generic image
  ;; cannot be built and nobody notices until an image build fails an hour in.
  (let ((stashed (string-append authorized-key ".test-stash")))
    (rename-file authorized-key stashed)
    (let ((result (evaluate-config))
          (keys (authorized-keys-verdict)))
      (rename-file stashed authorized-key)
      (check "evaluates with NO authorized-key.pub (generic published image)"
             (car result) (cdr result))
      ;; The check evaluation CANNOT make: a #f where a filename belongs.
      ;; See authorized-keys-verdict for the hour this cost.
      (check "keyless config emits no #f into authorized-keys"
             (string=? keys "clean")
             (format #f "verdict: ~a (expected \"clean\")" keys))))

  (unless had-key?
    (delete-file authorized-key)))

;; 3. The service must be wired into the services list, not merely defined.
;;    Defining it and forgetting to add it is a silent no-op: the image builds,
;;    boots, and simply never installs a key.
(let ((source (call-with-input-file image-config get-string-all)))
  (check "%metadata-ssh-key-service is defined"
         (string-contains source "(define %metadata-ssh-key-service") "")
  (check "%metadata-ssh-key-service is in the services list"
         (string-contains source "    %metadata-ssh-key-service)") "")

  (check "compiled service resolves the dynamically loaded helper at runtime"
         (and (string-contains source
                               "(module-ref (current-module) 'metadata-install-from-oci!)")
              (not (string-contains source
                                    "          (metadata-install-from-oci!"))) "")

  (check "service start and runtime exceptions are visible on serial console"
         (and (string-contains source "(console-log \"service starting\")")
              (string-contains source "ERROR: runtime exception:")) "")

  ;; It must never write to /etc/ssh/authorized_keys.d: Guix deletes and
  ;; recreates that directory on every activation, so anything written there
  ;; disappears. This is the single easiest mistake to reintroduce.
  (check "does not write into /etc/ssh/authorized_keys.d"
         (not (string-contains source "\"/etc/ssh/authorized_keys.d"))
         "")

  ;; IMDSv2 refuses the request without this header.
  (check "sends the IMDSv2 Authorization header"
         (let ((helper-source (call-with-input-file metadata-helper get-string-all)))
           (string-contains helper-source "Bearer Oracle")) "")

  (let ((helper-source (call-with-input-file metadata-helper get-string-all)))
    (check "metadata runtime has bounded retries and short fetch attempts"
           (and (string-contains helper-source "%metadata-max-attempts 12")
                (string-contains helper-source "%metadata-retry-delay 3")
                (string-contains helper-source "\"--timeout=2\"")
                (string-contains helper-source "\"--tries=1\"")))
    (check "metadata outcomes are visible on the serial console"
           (and (string-contains helper-source "\"/dev/console\"")
                (string-contains helper-source "ERROR: no usable metadata key")))
    (check "metadata install fixes directory/file ownership and modes"
           (and (string-contains helper-source "(chmod ssh-dir #o700)")
                (string-contains helper-source "(chmod target #o600)")
                (string-contains helper-source "(chown ssh-dir uid gid)")
                (string-contains helper-source "(chown target uid gid)")))
    (check "runtime logs counts and outcomes, never public-key values"
           (and (not (string-contains helper-source "(emit key"))
                (not (string-contains helper-source "(emit keys"))
                (string-contains helper-source "installed ~a key(s)"))))

  ;; ASCII only -- this config is read over the OCI serial console.
  (let* ((helper-source (call-with-input-file metadata-helper get-string-all))
         (non-ascii (filter (lambda (c) (> (char->integer c) 127))
                            (string->list (string-append source helper-source)))))
    (check "config and metadata runtime are ASCII only"
           (null? non-ascii)
           (if (null? non-ascii) "" (format #f "found: ~s" non-ascii)))))

(newline)
(if (zero? failures)
    (begin (format #t "\x1b[0;32mAll ~a oracle image checks passed!\x1b[0m\n" checks)
           (exit 0))
    (begin (format #t "\x1b[0;31m~a of ~a oracle image checks FAILED\x1b[0m\n"
                   failures checks)
           (exit 1)))
