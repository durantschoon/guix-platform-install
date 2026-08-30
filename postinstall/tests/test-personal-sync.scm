#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-personal-sync.scm --- Tests for personal-sync.scm recipe
;;;
;;; Guile per language policy. Validates GNS advertisement encoding,
;;; headless execution, status reporting, and ASCII invariants.

(use-modules (ice-9 binary-ports)
             (ice-9 format)
             (ice-9 match)
             (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-11))

(define (absolute path)
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define recipe-file (string-append repository-root "/postinstall/recipes/add/personal-sync.scm"))
(define purpose-file (string-append repository-root "/postinstall/recipes/add/personal-sync_purpose.txt"))
(define this-file (string-append script-directory "/test-personal-sync.scm"))

(define *failures* 0)
(define *checks* 0)

(define (pass label)
  (set! *checks* (+ *checks* 1))
  (format #t "  \x1b[0;32m[OK]\x1b[0m   ~a\n" label))

(define (fail label reason)
  (set! *checks* (+ *checks* 1))
  (set! *failures* (+ *failures* 1))
  (format (current-error-port) "  \x1b[0;31m[FAIL]\x1b[0m ~a\n         ~a\n" label reason))

(define* (check label condition #:optional (reason-if-false ""))
  (if condition
      (pass label)
      (fail label reason-if-false)))

(define (run-cmd . args)
  (let* ((pipe (apply open-pipe* OPEN_READ args))
         (output (let loop ((lines '()))
                   (let ((line (read-line pipe)))
                     (if (eof-object? line)
                         (string-join (reverse lines) "\n")
                         (loop (cons line lines))))))
         (status (close-pipe pipe)))
    (values (status:exit-val status) output)))

(format #t "Testing Personal Multi-Machine Sync (postinstall/recipes/add/personal-sync.scm)\n\n")

;;; ---------------------------------------------------------------------------
;;; 1. Recipe self-tests
;;; ---------------------------------------------------------------------------

(format #t "\x1b[1;34m1. Recipe Self-Tests (--self-test)\x1b[0m\n")

(let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" recipe-file "--self-test")))
  (check "personal-sync.scm --self-test exits 0"
         (= code 0)
         (format #f "Expected exit 0, got ~a" code))
  (check "Self-test output reports all tests passed"
         (string-contains out "All personal-sync.scm self-tests passed!")
         "Missing success banner in self-test output"))

;;; ---------------------------------------------------------------------------
;;; 2. Status inspection (--status)
;;; ---------------------------------------------------------------------------

(format #t "\n\x1b[1;34m2. Headless Status Inspection (--status)\x1b[0m\n")

(let-values (((code out) (run-cmd "guile" "--no-auto-compile" "-s" recipe-file "--status")))
  (check "personal-sync.scm --status exits 0"
         (= code 0)
         (format #f "Expected exit 0, got ~a" code))
  (check "Status output contains sync status header"
         (string-contains out "=== GIPS Personal Multi-Machine Sync Status ===")
         "Missing status header")
  (check "Status output contains Local GNS Name field"
         (string-contains out "Local GNS Name:")
         "Missing Local GNS Name field"))

;;; ---------------------------------------------------------------------------
;;; 3. ASCII policy and escape invariants
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

(check "Recipe script is ASCII-only" (file-is-ascii? recipe-file))
(check "Recipe script contains no octal escape" (not (has-octal-escape? recipe-file)))
(check "Purpose doc is ASCII-only" (file-is-ascii? purpose-file))
(check "Purpose doc contains no octal escape" (not (has-octal-escape? purpose-file)))
(check "Test file is ASCII-only" (file-is-ascii? this-file))
(check "Test file contains no octal escape" (not (has-octal-escape? this-file)))

;;; --- Summary ---
(format #t "\nResults: ~a checks, ~a passed, ~a failed\n"
        *checks* (- *checks* *failures*) *failures*)

(if (zero? *failures*)
    (begin (format #t "\x1b[0;32mAll personal sync checks passed!\x1b[0m\n") (exit 0))
    (begin (format (current-error-port) "\x1b[0;31mSome personal sync checks failed!\x1b[0m\n") (exit 1)))
