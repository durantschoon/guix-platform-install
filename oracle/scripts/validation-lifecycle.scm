#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; validation-lifecycle.scm --- guarded lifecycle operations for OCI test VMs.

(define %script-directory (dirname (canonicalize-path (car (command-line)))))
(load (string-append %script-directory "/oci-common.scm"))
(load (string-append %script-directory "/validation-common.scm"))

(define (usage)
  (die "usage: validation-lifecycle.scm status|logs|collect|stop|cleanup|handoff --run-dir DIR [--yes]; review|reap --root DIR [--yes]; status also accepts --json"))

(define (parse args)
  (let loop ((rest args) (run-dir #f) (yes? #f) (json? #f))
    (cond ((null? rest) (values run-dir yes? json?))
          ((string=? (car rest) "--yes") (loop (cdr rest) run-dir #t json?))
          ((string=? (car rest) "--json") (loop (cdr rest) run-dir yes? #t))
          ((member (car rest) '("--run-dir" "--root"))
           (if (null? (cdr rest)) (usage)
               (loop (cddr rest) (cadr rest) yes? json?)))
          (else (usage)))))

(define (facts run-dir)
  (let* ((state-path (string-append run-dir "/state.scm"))
         (state (validation-read-state state-path)))
    (unless state (die "invalid or missing state: " state-path))
    (values state-path state
            (validation-option-ref state 'instance-ocid))))

(define (authorized? state-path state remote operation)
  (validation-ownership-authorized?
   state remote operation
   (file-exists? (validation-handoff-marker-path state-path))))

(define (show-status run-dir json?)
  (call-with-values (lambda () (facts run-dir))
    (lambda (state-path state instance)
      (unless instance (die "run has no instance OCID"))
      (let ((remote (oci-instance-ownership instance))
            (lifecycle (oci-instance-state instance)))
        (if json?
            (display (validation-status-json state remote lifecycle))
            (format #t "local:  ~s~%remote: ~s~%lifecycle: ~a~%"
                    state remote lifecycle))))))

(define (show-logs run-dir)
  "Display only evidence already retained in this exact local run directory."
  (let ((events (string-append run-dir "/events.jsonl"))
        (output (string-append run-dir "/remote-output.log"))
        (reconnect (string-append run-dir "/reconnect.log")))
    (for-each
     (lambda (path)
       (when (file-exists? path)
         (format #t "===== ~a =====~%" path)
         (call-with-input-file path (lambda (port) (display (get-string-all port))))))
     (list events output reconnect))))

(define (collect run-dir)
  "Collect exact-run lifecycle and serial-console evidence without mutation."
  (call-with-values (lambda () (facts run-dir))
    (lambda (state-path state instance)
      (unless instance (die "run has no instance OCID"))
      (let ((remote (oci-instance-ownership instance))
            (lifecycle (oci-instance-state instance))
            (console (string-append run-dir "/console-history.log")))
        (format #t "instance: ~a~%lifecycle: ~a~%ownership: ~s~%"
                instance lifecycle remote)
        (if (oci-capture-console-history instance console)
            (say "[OK] console evidence written to " console)
            (die "console evidence collection failed; inspect " console))))))

(define (cleanup run-dir yes?)
  (call-with-values (lambda () (facts run-dir))
    (lambda (state-path state instance)
      (let ((remote (and instance (oci-instance-ownership instance))))
        (unless (authorized? state-path state remote 'terminate)
          (die "cleanup blocked: local and fresh OCI ownership facts do not match"))
        (unless (or yes? (prompt-yes? (string-append "Terminate exact instance " instance "?")))
          (die "cleanup cancelled"))
        (call-with-values (lambda () (oci-terminate-instance/status instance))
          (lambda (output status)
            (display output) (newline)
            (unless (zero? status) (die "OCI termination failed"))
            (say "[OK] termination requested for " instance)))))))

(define (stop run-dir yes?)
  "Stop is an explicit alias for guarded termination, never an OCI stop call."
  (cleanup run-dir yes?))

(define (handoff run-dir yes?)
  (call-with-values (lambda () (facts run-dir))
    (lambda (state-path state instance)
      (let ((remote (and instance (oci-instance-ownership instance))))
        (unless (authorized? state-path state remote 'handoff)
          (die "handoff blocked: local and fresh OCI ownership facts do not match"))
        (unless (or yes? (prompt-yes? (string-append "Hand off exact instance " instance "?")))
          (die "handoff cancelled"))
        ;; Protect locally first.  From this point cleanup is denied even if the
        ;; OCI update or confirmation is interrupted.
        (let ((marker (validation-handoff-marker-path state-path)))
          (call-with-output-file marker
            (lambda (port) (display "HANDED_OFF pending OCI confirmation\n" port)))
          (validation-write-state
           state-path (validation-state-set state 'artifact-state "HANDED_OFF"))
          (let ((tags (validation-tags-json/state
                       (validation-option-ref state 'run-id)
                       (validation-option-ref remote 'created-at)
                       (validation-option-ref remote 'expires-at)
                       "HANDED_OFF")))
            (call-with-values (lambda () (oci-update-instance-tags/status instance tags))
              (lambda (output status)
                (unless (zero? status) (die "OCI handoff tag update failed: " output))))
            (let ((confirmed (oci-instance-ownership instance)))
              (unless (and (equal? (validation-option-ref confirmed 'instance-ocid) instance)
                           (equal? (validation-option-ref confirmed 'run-id)
                                   (validation-option-ref state 'run-id))
                           (equal? (validation-option-ref confirmed 'artifact-state)
                                   "HANDED_OFF"))
                (die "OCI handoff confirmation failed; local protection remains"))
              (call-with-output-file marker
                (lambda (port) (display "HANDED_OFF confirmed by fresh OCI read\n" port)))
              (say "[OK] handed off protected instance " instance))))))))

(define (stage6-now)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (review-record root path state now)
    (let* ((decision (validation-review-decision state now))
         (facts (append state `((decision . ,(symbol->string (car decision)))
                                (reason . ,(cdr decision))
                                (evidence-path . ,path)))))
    facts))

(define (run-directories root)
  "Enumerate only immediate local checkpoint directories; never OCI inventory."
  (filter (lambda (name)
            (and (not (member name '(#f "." "..")))
                 (file-is-directory? (string-append root "/" name))))
          (scandir root)))

(define (review-root root)
  "Read every exact local state and emit one protected/eligible record."
  (unless (file-is-directory? root) (die "review root is missing: " root))
  (for-each
   (lambda (name)
     (let* ((path (string-append root "/" name "/state.scm"))
            (state (validation-read-state path)))
       (display (validation-review-json
                 (if state
                     (review-record root path state (stage6-now))
                     `((run-id . ,name) (decision . "protected")
                       (reason . "malformed-state") (evidence-path . ,path))))
       (newline)))
   (run-directories root))))

(define (append-reaper-outcome root facts)
  (let* ((path (string-append root "/reaper-outcomes.jsonl"))
         (old (if (file-exists? path)
                  (call-with-input-file path get-string-all)
                  "")))
    (call-with-output-file path
      (lambda (port)
        (display old port)
        (display (validation-reaper-json facts) port)
        (newline port)))))

(define (reap-root root yes?)
  "Reap only reviewed local candidates after a fresh exact-OCID OV-3 read."
  (unless yes? (die "reap requires explicit --yes after review"))
  (unless (file-is-directory? root) (die "reap root is missing: " root))
  (let ((now (stage6-now)))
    (for-each
     (lambda (name)
       (let* ((run-dir (string-append root "/" name))
              (state-path (string-append run-dir "/state.scm"))
              (state (validation-read-state state-path))
              (decision (and state (validation-review-decision state now)))
              (instance (and state (validation-option-ref state 'instance-ocid)))
              (base (append (or state `((run-id . ,name)))
                            `((evidence-path . ,state-path)))))
         (if (or (not decision) (not (eq? (car decision) 'eligible)))
             (begin
               (append-reaper-outcome root
                 (append base `((decision . "protected")
                                (outcome . "skipped")
                                (reason . ,(if decision (cdr decision) "malformed-state")))))
               (display (validation-reaper-json
                         (append base `((decision . "protected")
                                        (outcome . "skipped")
                                        (reason . ,(if decision (cdr decision) "malformed-state")))))
               (newline))
             (let ((remote (catch #t (lambda () (oci-instance-ownership instance))
                             (lambda args #f))))
               (if (not (validation-ownership-authorized?
                         state remote 'terminate
                         (file-exists? (validation-handoff-marker-path state-path))))
                   (begin
                     (append-reaper-outcome root
                       (append base `((decision . "protected")
                                      (outcome . "skipped")
                                      (reason . "fresh-ownership-mismatch"))))
                     (display (validation-reaper-json
                               (append base `((decision . "protected")
                                              (outcome . "skipped")
                                              (reason . "fresh-ownership-mismatch")))))
                     (newline))
                   (call-with-values (lambda () (oci-terminate-instance/status instance))
                     (lambda (output status)
                       (let ((outcome (if (zero? status) "terminated" "termination-failed")))
                         (append-reaper-outcome root
                           (append base `((decision . "authorized")
                                          (outcome . ,outcome))))
                         (display output) (newline)
                         (display (validation-reaper-json
                                   (append base `((decision . "authorized")
                                                  (outcome . ,outcome))))
                         (newline))))))))))
     (run-directories root)))))

(define (main args)
  (unless (pair? args) (usage))
  (let ((command (car args)))
    (call-with-values (lambda () (parse (cdr args)))
      (lambda (run-dir yes? json?)
        (unless run-dir (usage))
        (cond ((string=? command "status") (show-status run-dir json?))
              ((string=? command "logs") (show-logs run-dir))
              ((string=? command "collect") (collect run-dir))
              ((string=? command "stop") (stop run-dir yes?))
              ((string=? command "cleanup") (cleanup run-dir yes?))
              ((string=? command "handoff") (handoff run-dir yes?))
              ((string=? command "review") (review-root run-dir))
              ((string=? command "reap") (reap-root run-dir yes?))
              (else (usage)))))))

(unless (getenv "ORACLE_VALIDATION_TEST_MODE")
  (main (cdr (command-line))))
