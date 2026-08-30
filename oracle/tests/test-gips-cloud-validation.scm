#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-gips-cloud-validation.scm --- Tests for GIPS disposable cloud validation harness
;;;
;;; Guile per language policy. Verifies that the disposable validation workload
;;; constructs safe commands, correctly classifies verification outcomes, and
;;; emits structured evidence without leaking credentials.

(use-modules (ice-9 binary-ports)
             (ice-9 format)
             (ice-9 match)
             (ice-9 rdelim)
             (srfi srfi-1))

(define (absolute path)
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define workload-file (string-append repository-root "/oracle/scripts/gips-validation-workload.scm"))
(define this-file (string-append script-directory "/test-gips-cloud-validation.scm"))

;; Load workload module
(primitive-load workload-file)

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

(format #t "Testing GIPS Cloud Validation Harness (oracle/scripts/gips-validation-workload.scm)\n\n")

;;; ---------------------------------------------------------------------------
;;; 1. Workload command construction
;;; ---------------------------------------------------------------------------

(format #t "\x1b[1;34m1. Workload Command Generation\x1b[0m\n")

(let* ((run-id "test-run-12345678")
       (cmd (gips-validation-workload-command run-id)))
  (check "Workload command contains run-id workspace path"
         (string-contains cmd (string-append "/tmp/gips-val-" run-id)))
  (check "Workload command includes Scheme API test suite"
         (string-contains cmd "guile --no-auto-compile -s gips/test_api.scm"))
  (check "Workload command includes narinfo signing test suite"
         (string-contains cmd "guile --no-auto-compile -s gips/test_sign.scm"))
  (check "Workload command includes recipe self-test"
         (string-contains cmd "guile --no-auto-compile -s postinstall/recipes/add/gips.scm --self-test"))
  (check "Workload command contains no private-key paths or passwords"
         (and (not (string-contains cmd ".pem"))
              (not (string-contains cmd "password"))
              (not (string-contains cmd "secret")))))

;;; ---------------------------------------------------------------------------
;;; 2. Result parsing and classification
;;; ---------------------------------------------------------------------------

(format #t "\n\x1b[1;34m2. Result Parsing & Failure Classification\x1b[0m\n")

(let* ((passing-output "=== GIPS Cloud Validation Workload ===\n
Step 2: Testing Scheme API test suite\n
test_api.scm: all fifteen verdicts hold\n
Step 3: Testing Narinfo Signing & Verification\n
test_sign.scm: all four verdicts hold\n
=== GIPS Validation Workload Completed Successfully ===")
       (res (parse-gips-validation-result passing-output 0)))
  (check "Passing output parsed as PASS status" (string=? (assq-ref res 'status) "PASS"))
  (check "Passing output records 15 API verdicts" (= (assq-ref res 'api_verdicts) 15))
  (check "Passing output records 4 signing verdicts" (= (assq-ref res 'sign_verdicts) 4))
  (check "Passing output has failure_class none" (string=? (assq-ref res 'failure_class) "none")))

(let* ((hash-mismatch-output "verdict 2/4: tampered-body rejected\n  failed: hash-mismatch detected")
       (res (parse-gips-validation-result hash-mismatch-output 1)))
  (check "Tampered body failure classified as narinfo-hash-mismatch"
         (string=? (assq-ref res 'failure_class) "narinfo-hash-mismatch"))
  (check "Failing run parsed as FAIL status" (string=? (assq-ref res 'status) "FAIL")))

(let* ((unauth-output "verdict 3/4: wrong-key rejected\n  failed: unauthorized-key")
       (res (parse-gips-validation-result unauth-output 1)))
  (check "Unauthorized key failure classified as unauthorized-key"
         (string=? (assq-ref res 'failure_class) "unauthorized-key")))

(let* ((inval-sig-output "verdict 3/4: foreign signature refused: invalid-signature")
       (res (parse-gips-validation-result inval-sig-output 1)))
  (check "Invalid signature classified as invalid-signature"
         (string=? (assq-ref res 'failure_class) "invalid-signature")))

(let* ((conn-refused-output "curl: (7) Failed to connect to 127.0.0.1 port 8080: Connection refused")
       (res (parse-gips-validation-result conn-refused-output 7)))
  (check "Connection refused classified as daemon-connection-failed"
         (string=? (assq-ref res 'failure_class) "daemon-connection-failed")))

;;; ---------------------------------------------------------------------------
;;; 3. JSON summary serialization
;;; ---------------------------------------------------------------------------

(format #t "\n\x1b[1;34m3. JSON Summary Serialization\x1b[0m\n")

(let* ((res `((status . "PASS")
              (exit_code . 0)
              (api_verdicts . 15)
              (sign_verdicts . 4)
              (failure_class . "none")
              (workload_version . "1.0.0")))
       (json-str (gips-validation-summary-json "run-abc-123" res)))
  (check "JSON summary contains schema_version" (string-contains json-str "\"schema_version\": \"gips-cloud-validation-v1\""))
  (check "JSON summary contains run_id" (string-contains json-str "\"run_id\": \"run-abc-123\""))
  (check "JSON summary contains status PASS" (string-contains json-str "\"status\": \"PASS\""))
  (check "JSON summary contains api_verdicts_passed 15" (string-contains json-str "\"api_verdicts_passed\": 15"))
  (check "JSON summary contains sign_verdicts_passed 4" (string-contains json-str "\"sign_verdicts_passed\": 4")))

;;; ---------------------------------------------------------------------------
;;; 4. ASCII policy and escape invariants
;;; ---------------------------------------------------------------------------

(format #t "\n\x1b[1;34m4. ASCII policy and escape invariants\x1b[0m\n")

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

(check "Workload script is ASCII-only" (file-is-ascii? workload-file))
(check "Workload script contains no octal escape" (not (has-octal-escape? workload-file)))
(check "Test file is ASCII-only" (file-is-ascii? this-file))
(check "Test file contains no octal escape" (not (has-octal-escape? this-file)))

;;; --- Summary ---
(format #t "\nResults: ~a checks, ~a passed, ~a failed\n"
        *checks* (- *checks* *failures*) *failures*)

(if (zero? *failures*)
    (begin (format #t "\x1b[0;32mAll GIPS cloud validation checks passed!\x1b[0m\n") (exit 0))
    (begin (format (current-error-port) "\x1b[0;31mSome GIPS cloud validation checks failed!\x1b[0m\n") (exit 1)))
