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
    (let ((result (evaluate-config)))
      (rename-file stashed authorized-key)
      (check "evaluates with NO authorized-key.pub (generic published image)"
             (car result) (cdr result))))

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

  ;; It must never write to /etc/ssh/authorized_keys.d: Guix deletes and
  ;; recreates that directory on every activation, so anything written there
  ;; disappears. This is the single easiest mistake to reintroduce.
  (check "does not write into /etc/ssh/authorized_keys.d"
         (not (string-contains source "\"/etc/ssh/authorized_keys.d"))
         "")

  ;; IMDSv2 refuses the request without this header.
  (check "sends the IMDSv2 Authorization header"
         (string-contains source "Bearer Oracle") "")

  ;; ASCII only -- this config is read over the OCI serial console.
  (let ((non-ascii (filter (lambda (c) (> (char->integer c) 127))
                           (string->list source))))
    (check "config is ASCII only"
           (null? non-ascii)
           (if (null? non-ascii) "" (format #f "found: ~s" non-ascii)))))

(newline)
(if (zero? failures)
    (begin (format #t "\x1b[0;32mAll ~a oracle image checks passed!\x1b[0m\n" checks)
           (exit 0))
    (begin (format #t "\x1b[0;31m~a of ~a oracle image checks FAILED\x1b[0m\n"
                   failures checks)
           (exit 1)))
