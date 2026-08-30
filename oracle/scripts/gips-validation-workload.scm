;;; Loaded by validation scripts, never as a module.

(use-modules (ice-9 format)
             (ice-9 match)
             (ice-9 rdelim)
             (srfi srfi-1))

(define gips-validation-workload-version "1.0.0")

(define (gips-sh-quote text)
  (string-append "'" (string-join (string-split text #\') "'\\''") "'"))

(define (gips-json-escape text)
  (list->string
   (append-map
    (lambda (c)
      (cond ((char=? c #\\) (string->list "\\\\"))
            ((char=? c #\") (string->list "\\\""))
            ((char=? c #\newline) (string->list "\\n"))
            ((char=? c #\return) (string->list "\\r"))
            ((char=? c #\tab) (string->list "\\t"))
            ((< (char->integer c) 32)
             (string->list (format #f "\\u~4,'0x" (char->integer c))))
            (else (list c))))
    (string->list text))))

(define (gips-json-string text)
  (string-append "\"" (gips-json-escape text) "\""))

(define (gips-validation-workload-command run-id . maybe-target-path)
  "Generate a deterministic shell command sequence that tests GIPS publication
and substitute retrieval end-to-end on the guest VM."
  (let ((target (if (pair? maybe-target-path) (car maybe-target-path) "/run/current-system"))
        (work-dir (string-append "/tmp/gips-val-" run-id)))
    (string-append
     "mkdir -p " (gips-sh-quote work-dir) " && "
     "cd " (gips-sh-quote work-dir) " && "
     "echo '=== GIPS Cloud Validation Workload ===' && "
     "echo 'Step 1: Inspecting environment and binaries' && "
     "which guile && which curl && "
     "echo 'Step 2: Testing Scheme API test suite' && "
     "guile --no-auto-compile -s gips/test_api.scm && "
     "echo 'Step 3: Testing Narinfo Signing & Verification' && "
     "guile --no-auto-compile -s gips/test_sign.scm && "
     "echo 'Step 4: Testing Post-Install Recipe Self-Test' && "
     "guile --no-auto-compile -s postinstall/recipes/add/gips.scm --self-test && "
     "echo '=== GIPS Validation Workload Completed Successfully ==='")))

(define (gips-validation-error-classify output-text)
  "Classify validation workload failure into standard failure classes."
  (cond
   ((string-contains output-text "Unbound variable: (guix read-print)")
    'missing-guix-module)
   ((string-contains output-text "hash-mismatch")
    'narinfo-hash-mismatch)
   ((string-contains output-text "unauthorized-key")
    'unauthorized-key)
   ((string-contains output-text "invalid-signature")
    'invalid-signature)
   ((string-contains output-text "Connection refused")
    'daemon-connection-failed)
   ((string-contains output-text "No such file or directory")
    'binary-or-path-not-found)
   (else 'workload-command-failed)))

(define (parse-gips-validation-result output-text exit-code)
  "Parse output text and exit code into a structured verification report alist."
  (let* ((passed? (and (= exit-code 0)
                       (string-contains output-text "all fifteen verdicts hold")
                       (string-contains output-text "all four verdicts hold")
                       (string-contains output-text "GIPS Validation Workload Completed Successfully")))
         (verdicts-api (if (string-contains output-text "all fifteen verdicts hold") 15 0))
         (verdicts-sign (if (string-contains output-text "all four verdicts hold") 4 0))
         (failure-class (if passed? 'none (gips-validation-error-classify output-text))))
    `((status . ,(if passed? "PASS" "FAIL"))
      (exit_code . ,exit-code)
      (api_verdicts . ,verdicts-api)
      (sign_verdicts . ,verdicts-sign)
      (failure_class . ,(symbol->string failure-class))
      (workload_version . ,gips-validation-workload-version))))

(define (gips-validation-summary-json run-id result-alist)
  "Serialize result alist into standard JSON summary format."
  (let ((status (or (assq-ref result-alist 'status) "UNKNOWN"))
        (exit-code (or (assq-ref result-alist 'exit_code) -1))
        (api-v (or (assq-ref result-alist 'api_verdicts) 0))
        (sign-v (or (assq-ref result-alist 'sign_verdicts) 0))
        (fail-cls (or (assq-ref result-alist 'failure_class) "none"))
        (ver (or (assq-ref result-alist 'workload_version) gips-validation-workload-version)))
    (string-append
     "{\n"
     "  \"schema_version\": \"gips-cloud-validation-v1\",\n"
     "  \"run_id\": " (gips-json-string run-id) ",\n"
     "  \"status\": " (gips-json-string status) ",\n"
     "  \"exit_code\": " (number->string exit-code) ",\n"
     "  \"api_verdicts_passed\": " (number->string api-v) ",\n"
     "  \"sign_verdicts_passed\": " (number->string sign-v) ",\n"
     "  \"failure_class\": " (gips-json-string fail-cls) ",\n"
     "  \"workload_version\": " (gips-json-string ver) "\n"
     "}\n")))
