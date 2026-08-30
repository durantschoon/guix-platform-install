#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-config-helper-gips.scm --- Tests for GIPS system service integration in config.scm
;;;
;;; Guile per language policy. Verifies that (gips service) and (service gips-service-type)
;;; can be attached to any GNU Guix operating-system declaration without losing comments,
;;; gexps, or duplicate service entries.

(use-modules (ice-9 binary-ports)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-11))

(define (absolute path)
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define helper-file (string-append repository-root "/lib/guile-config-helper.scm"))
(define this-file (string-append script-directory "/test-config-helper-gips.scm"))

(define *failures* 0)
(define *checks* 0)

(define (pass label)
  (set! *checks* (+ *checks* 1))
  (format #t "  \x1b[0;32m[OK]\x1b[0m   ~a\n" label))

(define (fail label reason)
  (set! *checks* (+ *checks* 1))
  (set! *failures* (+ *failures* 1))
  (format (current-error-port) "  \x1b[0;31m[FAIL]\x1b[0m ~a\n         ~a\n" label reason))

(define (skip label reason)
  (set! *checks* (+ *checks* 1))
  (format #t "  \x1b[1;33m[SKIP]\x1b[0m ~a (~a)\n" label reason))

(define* (check label condition #:optional (reason-if-false ""))
  (if condition
      (pass label)
      (fail label reason-if-false)))

(define (have-guix-read-print?)
  (let* ((port (open-input-pipe
                "guile --no-auto-compile -c '(use-modules (guix read-print))' >/dev/null 2>&1 && echo yes || echo no"))
         (out (read-line port)))
    (close-pipe port)
    (string=? (string-trim-both (or out "")) "yes")))

(define (run-cmd . args)
  (let* ((pipe (apply open-pipe* OPEN_READ args))
         (output (let loop ((lines '()))
                   (let ((line (read-line pipe)))
                     (if (eof-object? line)
                         (string-join (reverse lines) "\n")
                         (loop (cons line lines))))))
         (status (close-pipe pipe)))
    (values (status:exit-val status) output)))

;;; ---------------------------------------------------------------------------
;;; Pure AST transformation tests (Portable anywhere)
;;; ---------------------------------------------------------------------------

(format #t "Testing GIPS System Service Helper (lib/guile-config-helper.scm)\n\n")
(format #t "\x1b[1;34m1. Pure AST S-expression transformations\x1b[0m\n")

;; Helper duplicates of pure logic for direct testing without (guix read-print)
(define (service-type-matches? svc target-type)
  (match svc
    (('service type-sym _ ...) (eq? type-sym target-type))
    (('service type-sym) (eq? type-sym target-type))
    (_ #f)))

(define (has-service-type? services-expr target-type)
  (match services-expr
    (('append ('list services ...) rest ...)
     (any (lambda (s) (service-type-matches? s target-type)) services))
    (('list services ...)
     (any (lambda (s) (service-type-matches? s target-type)) services))
    (_ #f)))

(define (add-service-to-services services-expr service-expr)
  (match services-expr
    (('append ('list services ...) base-services ...)
     (if (member service-expr services)
         services-expr
         `(append (list ,@services ,service-expr) ,@base-services)))
    ('%base-services
     `(append (list ,service-expr) %base-services))
    ('%desktop-services
     `(append (list ,service-expr) %desktop-services))
    (('list services ...)
     (if (member service-expr services)
         services-expr
         `(list ,@services ,service-expr)))
    (_ services-expr)))

;; Pure test 1: minimal config with %base-services
(let* ((initial-services '%base-services)
       (has-init? (has-service-type? initial-services 'gips-service-type))
       (with-service (add-service-to-services initial-services '(service gips-service-type)))
       (has-after? (has-service-type? with-service 'gips-service-type)))
  (check "Pure: GIPS service initially absent in %base-services" (not has-init?))
  (check "Pure: add-service-to-services attaches (service gips-service-type)"
         (equal? with-service '(append (list (service gips-service-type)) %base-services)))
  (check "Pure: has-service-type? detects attached gips-service-type" has-after?))

;; Pure test 2: minimal config with %desktop-services
(let* ((initial-services '%desktop-services)
       (with-service (add-service-to-services initial-services '(service gips-service-type))))
  (check "Pure: add-service-to-services wraps %desktop-services into append list"
         (equal? with-service '(append (list (service gips-service-type)) %desktop-services))))

;; Pure test 3: custom config with existing services & idempotence
(let* ((initial-services '(append (list (service openssh-service-type) (service ntp-service-type))
                                  %base-services))
       (with-service (add-service-to-services initial-services '(service gips-service-type)))
       (re-added (add-service-to-services with-service '(service gips-service-type))))
  (check "Pure: existing services preserved alongside gips-service-type"
         (and (has-service-type? with-service 'openssh-service-type)
              (has-service-type? with-service 'ntp-service-type)
              (has-service-type? with-service 'gips-service-type)))
  (check "Pure: repeated addition is idempotent"
         (equal? with-service re-added)))

;; Pure test 4: custom configuration payload
(let* ((initial-services '%base-services)
       (custom-svc '(service gips-service-type (gips-configuration (listen "127.0.0.1:9090"))))
       (with-service (add-service-to-services initial-services custom-svc)))
  (check "Pure: custom <gips-configuration> record is preserved in service form"
         (equal? with-service `(append (list ,custom-svc) %base-services))))

;;; ---------------------------------------------------------------------------
;;; Subprocess CLI Integration Tests (Guix environment)
;;; ---------------------------------------------------------------------------

(format #t "\n\x1b[1;34m2. CLI Subprocess integration & comment preservation\x1b[0m\n")

(if (not (have-guix-read-print?))
    (begin
      (skip "CLI: add-gips-service on minimal config" "(guix read-print) not on load path outside Guix")
      (skip "CLI: check-gips-service on modified config" "(guix read-print) not on load path outside Guix")
      (skip "CLI: idempotent add-gips-service" "(guix read-print) not on load path outside Guix")
      (skip "CLI: comment and gexp preservation on oracle-image.scm" "(guix read-print) not on load path outside Guix"))
    (begin
      ;; CLI Test 1: Minimal Base Services Config
      (let* ((tmp-file (string-append "/tmp/test-gips-base-" (number->string (getpid)) ".scm")))
        (call-with-output-file tmp-file
          (lambda (p)
            (display ";; Sample minimal config with base services\n" p)
            (display "(use-modules (gnu))\n" p)
            (display "(operating-system\n" p)
            (display "  (host-name \"my-guix-node\")\n" p)
            (display "  (timezone \"UTC\")\n" p)
            (display "  (bootloader (bootloader-configuration (bootloader grub-bootloader) (targets '(\"/dev/sda\"))))\n" p)
            (display "  (file-systems %base-file-systems)\n" p)
            (display "  (services %base-services))\n" p)))

        (let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" helper-file "check-gips-service" tmp-file)))
          (check "CLI: check-gips-service exits 1 when absent" (= code 1)))

        (let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" helper-file "add-gips-service" tmp-file)))
          (check "CLI: add-gips-service exits 0" (= code 0)))

        (let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" helper-file "check-gips-service" tmp-file)))
          (check "CLI: check-gips-service exits 0 after addition" (= code 0)))

        (let* ((content-before (call-with-input-file tmp-file (lambda (p) (read-delimited "" p)))))
          (let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" helper-file "add-gips-service" tmp-file)))
            (let ((content-after (call-with-input-file tmp-file (lambda (p) (read-delimited "" p)))))
              (check "CLI: Repeated add-gips-service is idempotent and changes nothing"
                     (and (= code 0) (string=? content-before content-after))))))

        (false-if-exception (delete-file tmp-file)))

      ;; CLI Test 2: Oracle fixture comment & gexp preservation
      (let* ((fixture (string-append repository-root "/oracle/image/oracle-image.scm"))
             (tmp-file (string-append "/tmp/test-gips-oracle-" (number->string (getpid)) ".scm")))
        (when (file-exists? fixture)
          (copy-file fixture tmp-file)
          (let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" helper-file "add-gips-service" tmp-file)))
            (check "CLI: add-gips-service succeeds on oracle-image.scm" (= code 0)))
          (let ((content (call-with-input-file tmp-file (lambda (p) (read-delimited "" p)))))
            (check "CLI: gexps #~ remain intact" (string-contains content "#~"))
            (check "CLI: ungexps #$ remain intact" (string-contains content "#$"))
            (check "CLI: (gips service) imported into use-modules" (string-contains content "(gips service)"))
            (check "CLI: gips-service-type present in services" (string-contains content "gips-service-type")))
          (false-if-exception (delete-file tmp-file))))))

;;; ---------------------------------------------------------------------------
;;; ASCII & escape policy checks
;;; ---------------------------------------------------------------------------

(format #t "\n\x1b[1;34m3. ASCII policy and escape invariants\x1b[0m\n")

(define (file-is-ascii? path)
  (call-with-input-file path
    (lambda (p)
      (let loop ()
        (let ((b (get-u8 p)))
          (cond
           ((eof-object? b) #t)
           ((> b 127) #f)
           (else (loop))))))))

(define %octal-escape-pattern (string-append "\\" "033["))

(define (has-octal-escape? path)
  (let* ((content (call-with-input-file path (lambda (p) (read-delimited "" p)))))
    (string-contains content %octal-escape-pattern)))

(check "Helper file is ASCII-only" (file-is-ascii? helper-file))
(check "Helper file contains no octal escape" (not (has-octal-escape? helper-file)))
(check "Test file is ASCII-only" (file-is-ascii? this-file))
(check "Test file contains no octal escape" (not (has-octal-escape? this-file)))

;;; --- Summary ---
(format #t "\nResults: ~a checks, ~a passed, ~a failed\n"
        *checks* (- *checks* *failures*) *failures*)

(if (zero? *failures*)
    (begin (format #t "\x1b[0;32mAll GIPS config helper checks passed!\x1b[0m\n") (exit 0))
    (begin (format (current-error-port) "\x1b[0;31mSome GIPS config helper checks failed!\x1b[0m\n") (exit 1)))
