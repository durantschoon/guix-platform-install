;;; validation-common.scm --- pure and local helpers for OCI validation runs.
;;;
;;; Loaded by validation scripts, never as a module.  Keep this free of OCI
;;; calls and load-time effects so oracle/tests/test-oracle-validation.scm can
;;; exercise its security-sensitive construction rules offline.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 ftw)
             (srfi srfi-1))

(define (validation-sh-quote text)
  "Single-quote TEXT for a command string passed to the local shell."
  (string-append "'" (string-join (string-split text #\') "'\\''") "'"))

(define (validation-json-escape text)
  "Encode TEXT as JSON string content without depending on guile-json."
  (list->string
   (append-map
    (lambda (c)
      (cond ((char=? c #\\) (string->list "\\\\"))
            ((char=? c #\") (string->list "\\\""))
            ((char=? c #\newline) (string->list "\\n"))
            ((char=? c #\return) (string->list "\\r"))
            ((char=? c #\tab) (string->list "\\t"))
            ;; Do not silently emit a control character into a JSON document.
            ((< (char->integer c) 32)
             (string->list
              (format #f "\\u~4,'0x" (char->integer c))))
            (else (list c))))
    (string->list text))))

(define (validation-json-string text)
  (string-append "\"" (validation-json-escape text) "\""))

(define (validation-metadata-json public-key)
  "Return launch metadata containing exactly the public SSH key."
  (string-append "{\"ssh_authorized_keys\":"
                 (validation-json-string public-key) "}"))

(define (validation-tags-json/state run-id created-at expires-at artifact-state)
  "Return the disposable-run tags passed to OCI's --freeform-tags."
  (string-append "{\"managed-by\":\"guix-platform-install\","
                 "\"artifact-state\":" (validation-json-string artifact-state) ","
                 "\"purpose\":\"guix-validation\",\"run-id\":"
                 (validation-json-string run-id)
                 ",\"created-at\":" (validation-json-string created-at)
                 ",\"expires-at\":" (validation-json-string expires-at) "}"))

(define (validation-tags-json run-id created-at expires-at)
  (validation-tags-json/state run-id created-at expires-at "IN_TEST"))

(define (validation-safe-run-id? value)
  "Accept only filename/display-name safe validation identifiers."
  (and (> (string-length value) 8)
       (every (lambda (c)
                (or (char-numeric? c)
                    (char-alphabetic? c)
                    (memv c '(#\- #\_))))
              (string->list value))))

(define (validation-run-id)
  "Make a locally unique, readable run ID.  OCI remains the collision arbiter."
  (let* ((now (gettimeofday))
         (stamp (strftime "%Y%m%dT%H%M%SZ" (gmtime (car now)))))
    (string-append stamp "-" (number->string (getpid) 16) "-"
                   (number->string (cdr now) 16))))

(define (validation-utc-time offset-seconds)
  "Return an ISO-8601 UTC timestamp OFFSET-SECONDS from now."
  (strftime "%Y-%m-%dT%H:%M:%SZ"
            (gmtime (+ (current-time) offset-seconds))))

(define (validation-path-safe? value)
  "Reject absolute and traversal paths before constructing a remote command."
  (and (not (string-null? value))
       (not (string-prefix? "/" value))
       (not (member ".." (string-split value #\/)))
       (not (string-contains value "\0"))))

(define (validation-snapshot-excluded? relative)
  "Whether RELATIVE belongs to local runner bookkeeping, not the source tree."
  (or (string=? relative ".git")
      (string-prefix? ".git/" relative)
      (string=? relative ".oracle-validation")
      (string-prefix? ".oracle-validation/" relative)))

(define (validation-remote-directory run-id)
  "The fixed remote parent prevents a caller-controlled absolute target."
  (if (validation-safe-run-id? run-id)
      (string-append "/home/guix/.cache/oracle-validation/" run-id)
      #f))

(define (validation-launch-command compartment availability-domain shape image-id
                                   subnet-id display-name metadata tags)
  "Build an OCI launch command for a new metadata-key-only validation VM."
  (string-append
   "compute instance launch --compartment-id " (validation-sh-quote compartment)
   " --availability-domain " (validation-sh-quote availability-domain)
   " --shape " (validation-sh-quote shape)
   " --image-id " (validation-sh-quote image-id)
   " --subnet-id " (validation-sh-quote subnet-id)
   " --assign-public-ip true --display-name " (validation-sh-quote display-name)
   " --metadata " (validation-sh-quote metadata)
   " --freeform-tags " (validation-sh-quote tags)
   ;; Disabling IMDSv1 makes failure to use IMDSv2 visible rather than falling
   ;; back to the legacy endpoint.  The Guix metadata service sends its v2
   ;; Bearer header first.
   " --instance-options '{\"are-legacy-imds-endpoints-disabled\":true}'"
   " --query data.id --raw-output"))

(define (validation-cleanup-action result keep-on-failure?)
  "Choose 'terminate or 'keep without consulting OCI."
  (if (and (not (zero? result)) keep-on-failure?) 'keep 'terminate))

(define (validation-ownership-authorized? local remote operation handoff-marker?)
  "Deny mutation unless local scope and freshly read OCI ownership all match."
  (define (value facts key)
    (let ((entry (and (list? facts) (assoc key facts))))
      (and entry (cdr entry))))
  (let ((manager (value local 'managed-by))
        (state (value local 'artifact-state))
        (run-id (value local 'run-id))
        (resource (value local 'resource-type))
        (instance (value local 'instance-ocid))
        (scope (value local 'operation-scope)))
    (and (not handoff-marker?)
         (equal? manager "guix-platform-install")
         (equal? state "IN_TEST")
         (string? run-id) (validation-safe-run-id? run-id)
         (equal? resource "instance")
         (string? instance) (string-prefix? "ocid1.instance." instance)
         (list? scope) (member operation scope)
         (equal? (value remote 'managed-by) manager)
         (equal? (value remote 'artifact-state) state)
         (equal? (value remote 'run-id) run-id)
         (equal? (value remote 'instance-ocid) instance))))

(define (validation-option-ref options key)
  (let ((entry (assoc key options))) (and entry (cdr entry))))

(define %validation-request-schema-version 1)
(define %validation-status-schema-version 1)
(define %validation-result-schema-version 1)
(define %validation-default-shape "VM.Standard.E2.1.Micro")
(define %validation-allowed-shapes (list %validation-default-shape))
(define %validation-default-timeout 3600)
(define %validation-maximum-timeout 86400)
(define %validation-default-output-bytes 1048576)
(define %validation-maximum-output-bytes 16777216)

;; Stage 6 review/reaper records are deliberately a separate, additive
;; interface.  Expiry is evidence for review; the existing ownership gate is
;; the only deletion authority.
(define %validation-review-schema-version 1)
(define %validation-reaper-schema-version 1)

(define (validation-iso-utc? value)
  "Accept only the fixed-width UTC timestamps emitted by this controller."
  (and (string? value) (= (string-length value) 20)
       (char=? (string-ref value 4) #\-)
       (char=? (string-ref value 7) #\-)
       (char=? (string-ref value 10) #\T)
       (char=? (string-ref value 13) #\:)
       (char=? (string-ref value 16) #\:)
       (char=? (string-ref value 19) #\Z)
       (every char-numeric?
              (append (string->list (substring value 0 4))
                      (string->list (substring value 5 7))
                      (string->list (substring value 8 10))
                      (string->list (substring value 11 13))
                      (string->list (substring value 14 16))
                      (string->list (substring value 17 19))))))

(define (validation-expired? expires-at now)
  "Compare fixed-width UTC timestamps; malformed expiry is never expired."
  (and (validation-iso-utc? expires-at) (validation-iso-utc? now)
       (string<=? expires-at now)))

(define (validation-review-decision state now)
  "Return an inspectable local decision before any OCI call is considered."
  (let* ((artifact (validation-option-ref state 'artifact-state))
         (expiry (validation-option-ref state 'expires-at))
         (instance (validation-option-ref state 'instance-ocid))
         (run-id (validation-option-ref state 'run-id))
         (manager (validation-option-ref state 'managed-by))
         (resource (validation-option-ref state 'resource-type)))
    (cond
     ((not (list? state)) '(protected . "malformed-state"))
     ((equal? artifact "HANDED_OFF") '(protected . "handed-off"))
     ((not (equal? manager "guix-platform-install")) '(protected . "manager-mismatch"))
     ((not (equal? resource "instance")) '(protected . "resource-mismatch"))
     ((not (equal? artifact "IN_TEST")) '(protected . "unknown-artifact-state"))
     ((not (and (string? run-id) (validation-safe-run-id? run-id)))
      '(protected . "missing-or-malformed-run-id"))
     ((not (and (string? instance) (string-prefix? "ocid1.instance." instance)))
      '(protected . "missing-or-malformed-instance-ocid"))
     ((not (validation-iso-utc? expiry)) '(protected . "missing-or-malformed-expiry"))
     ((validation-expired? expiry now) '(eligible . "expired-awaiting-fresh-ownership"))
     (else '(protected . "unexpired")))))

(define (validation-review-json facts)
  "Encode one review decision without credentials or OCI command material."
  (define (field key default)
    (or (validation-option-ref facts key) default))
  (string-append
   "{\"schema_version\":" (number->string %validation-review-schema-version)
   ",\"run_id\":" (validation-json-string (field 'run-id ""))
   ",\"execution_id\":" (validation-json-string (field 'execution-id ""))
   ",\"instance_ocid\":" (validation-json-string (field 'instance-ocid ""))
   ",\"expires_at\":" (validation-json-string (field 'expires-at ""))
   ",\"decision\":" (validation-json-string (field 'decision "protected"))
   ",\"reason\":" (validation-json-string (field 'reason "unknown"))
   ",\"evidence_path\":" (validation-json-string (field 'evidence-path "")) "}"))

(define (validation-reaper-json facts)
  "Encode one durable reaper outcome with explicit evidence and status."
  (string-append
   "{\"schema_version\":" (number->string %validation-reaper-schema-version)
   ",\"run_id\":" (validation-json-string (or (validation-option-ref facts 'run-id) ""))
   ",\"execution_id\":" (validation-json-string (or (validation-option-ref facts 'execution-id) ""))
   ",\"instance_ocid\":" (validation-json-string (or (validation-option-ref facts 'instance-ocid) ""))
   ",\"expires_at\":" (validation-json-string (or (validation-option-ref facts 'expires-at) ""))
   ",\"decision\":" (validation-json-string (or (validation-option-ref facts 'decision) "protected"))
   ",\"outcome\":" (validation-json-string (or (validation-option-ref facts 'outcome) "skipped"))
   ",\"evidence_path\":" (validation-json-string (or (validation-option-ref facts 'evidence-path) "")) "}"))

(define (validation-positive-bounded-integer text maximum)
  "Parse TEXT once, rejecting malformed, non-positive, and excessive values."
  (let ((value (and (string? text) (string->number text))))
    (and value (integer? value) (> value 0) (<= value maximum) value)))

(define (validation-request-json options run-id execution-id source-sha256)
  "Encode the versioned request without controller credential material."
  (string-append
   "{\"schema_version\":" (number->string %validation-request-schema-version)
   ",\"run_id\":" (validation-json-string run-id)
   ",\"execution_id\":" (validation-json-string execution-id)
   ",\"source_sha256\":" (validation-json-string source-sha256)
   ",\"command\":" (validation-json-string (validation-option-ref options 'command))
   ",\"policy\":{\"timeout_seconds\":"
   (number->string (validation-option-ref options 'timeout))
   ",\"max_output_bytes\":"
   (number->string (validation-option-ref options 'max-output-bytes))
   ",\"shape\":" (validation-json-string (validation-option-ref options 'shape))
   "}}\n"))

(define (validation-parse-start args)
  "Parse validate.scm's start arguments, returning (values options error).
The small parser keeps Stage 1 dependency-free and makes required inputs
testable without invoking OCI."
  (let loop ((rest args)
             (options `((shape . ,%validation-default-shape)
                        (timeout . ,%validation-default-timeout)
                        (max-output-bytes . ,%validation-default-output-bytes)
                        (force-disconnect-after . #f)
                        (keep-on-failure . #f)
                        (yes . #f))))
    (cond
     ((null? rest)
      (let ((missing (filter (lambda (key) (not (validation-option-ref options key)))
                             '(image-id subnet-id source command))))
        (if (null? missing)
            (let* ((timeout (validation-option-ref options 'timeout))
                   (output-limit (validation-option-ref options 'max-output-bytes))
                   (forced-text (validation-option-ref
                                 options 'force-disconnect-after))
                   (forced (and forced-text (string->number forced-text))))
              (if (and (integer? timeout) (> timeout 0)
                       (integer? output-limit) (> output-limit 0)
                       (member (validation-option-ref options 'shape)
                               %validation-allowed-shapes)
                       (or (not forced-text)
                           (and forced (integer? forced) (> forced 0))))
                  (values options #f)
                  (values #f "unsupported execution policy")))
            (values #f (string-append "missing required option --"
                                      (symbol->string (car missing)))))))
     ((member (car rest) '("--keep-on-failure" "--yes"))
      (loop (cdr rest)
            (acons (if (string=? (car rest) "--yes") 'yes 'keep-on-failure)
                   #t options)))
     ((member (car rest) '("--image-id" "--subnet-id" "--source" "--command"
                           "--shape" "--timeout" "--max-output-bytes"
                           "--force-disconnect-after"))
      (if (null? (cdr rest))
          (values #f (string-append "option requires a value: " (car rest)))
          (let* ((key (string->symbol (substring (car rest) 2)))
                 (raw (cadr rest))
                 (parsed (cond ((eq? key 'timeout)
                                (validation-positive-bounded-integer raw %validation-maximum-timeout))
                               ((eq? key 'max-output-bytes)
                                (validation-positive-bounded-integer raw %validation-maximum-output-bytes))
                               (else raw))))
            (if (and (member key '(timeout max-output-bytes)) (not parsed))
                (values #f (string-append "invalid or excessive --" (symbol->string key)))
                (loop (cddr rest) (acons key parsed options))))))
     (else (values #f (string-append "unknown option: " (car rest)))))))

(define (validation-parse-probe args)
  "Parse the Stage 0 probe without performing any OCI operation."
  (let loop ((rest args)
             (options '((shape . "VM.Standard.E2.1.Micro") (yes . #f))))
    (cond
     ((null? rest)
      (if (and (validation-option-ref options 'image-id)
               (validation-option-ref options 'subnet-id))
          (values options #f)
          (values #f "both --image-id and --subnet-id are required")))
     ((string=? (car rest) "--yes")
      (loop (cdr rest) (acons 'yes #t options)))
     ((member (car rest) '("--image-id" "--subnet-id" "--shape"))
      (if (null? (cdr rest))
          (values #f (string-append "option requires a value: " (car rest)))
          (loop (cddr rest)
                (acons (string->symbol (substring (car rest) 2))
                       (cadr rest) options))))
     (else (values #f (string-append "unknown option: " (car rest)))))))

(define (validation-mkdir-p path)
  "Create a local run directory.  The path is generated by the controller."
  (zero? (system* "mkdir" "-p" path)))

(define (validation-write-state path state)
  "Atomically replace PATH with STATE, so an interrupted controller is resumable."
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port) (write state port) (newline port)))
    (rename-file temporary path)))

(define (validation-read-state path)
  "Read one native state record; malformed or trailing input is rejected."
  (catch #t
    (lambda ()
      (call-with-input-file path
        (lambda (port)
          (let ((state (read port)) (trailing (read port)))
            (and (list? state) (eof-object? trailing) state)))))
    (lambda args #f)))

(define (validation-state-set state key value)
  "Return STATE with KEY replaced exactly once."
  (acons key value (filter (lambda (entry) (not (eq? (car entry) key))) state)))

(define (validation-state-restartable? state)
  "Whether STATE is a valid local checkpoint for a later controller resume.
HANDED_OFF and terminal records are deliberately not restartable: resuming
those would either cross a human boundary or duplicate a completed run."
  (and (list? state)
       (equal? (validation-option-ref state 'artifact-state) "IN_TEST")
       (member (validation-option-ref state 'phase)
               '(prepared snapshotted launching launched ssh running))))

(define (validation-status-json state remote lifecycle)
  "Encode the stable, machine-readable status surface for one exact run.
Only scalar fields are exposed; the full native state and OCI evidence remain
available in their run files for detailed diagnosis."
  (let ((field (lambda (facts key default)
                 (let ((value (and (list? facts)
                                   (validation-option-ref facts key))))
                   (if value value default)))))
    (string-append
     "{\"schema_version\":" (number->string %validation-status-schema-version)
     ",\"run_id\":"
     (validation-json-string (field state 'run-id ""))
     ",\"execution_id\":"
     (validation-json-string (field state 'execution-id ""))
     ",\"source_sha256\":"
     (validation-json-string (field state 'source-sha256 ""))
     ",\"instance_ocid\":"
     (validation-json-string (field state 'instance-ocid ""))
     ",\"local_phase\":"
     (validation-json-string
      (let ((phase (field state 'phase "unknown")))
        (if (symbol? phase) (symbol->string phase) phase)))
     ",\"artifact_state\":"
     (validation-json-string (field state 'artifact-state "unknown"))
     ",\"remote_lifecycle\":"
     (validation-json-string (if lifecycle lifecycle "unknown"))
     ",\"remote_artifact_state\":"
     (validation-json-string (field remote 'artifact-state "unknown"))
     ",\"ownership_match\":"
     (if (and (string=? (field state 'run-id "")
                        (field remote 'run-id ""))
              (string=? (field state 'instance-ocid "")
                        (field remote 'instance-ocid "")))
         "true" "false")
     "}\n")))

(define (validation-handoff-marker-path state-path)
  (string-append state-path ".handoff"))

(define (validation-result-json facts)
  "Encode the complete terminal one-shot contract from explicit FACTS."
  (define (field key default)
    (or (validation-option-ref facts key) default))
  (string-append
   "{\"schema_version\":" (number->string %validation-result-schema-version)
   ",\"run_id\":" (validation-json-string (field 'run-id ""))
   ",\"execution_id\":" (validation-json-string (field 'execution-id ""))
   ",\"instance_ocid\":" (validation-json-string (field 'instance-ocid ""))
   ",\"source_sha256\":" (validation-json-string (field 'source-sha256 ""))
   ",\"command\":" (validation-json-string (field 'command ""))
   ",\"exit_status\":" (if (number? (field 'exit-status #f))
                                 (number->string (field 'exit-status #f)) "null")
   ",\"failure_class\":" (if (field 'failure-class #f)
                                  (validation-json-string (field 'failure-class #f)) "null")
   ",\"started_at\":" (validation-json-string (field 'started-at ""))
   ",\"ended_at\":" (validation-json-string (field 'ended-at ""))
   ",\"duration_seconds\":" (number->string (field 'duration-seconds 0))
   ",\"cleanup_disposition\":" (validation-json-string (field 'cleanup-disposition "unknown"))
   ",\"output_truncated\":" (if (field 'output-truncated #f) "true" "false")
   ",\"output_byte_limit\":" (number->string (field 'output-byte-limit 0))
   ",\"full_output_path\":" (if (field 'full-output-path #f)
                                    (validation-json-string (field 'full-output-path #f)) "null")
   ",\"evidence_paths\":["
   (string-join (map validation-json-string (field 'evidence-paths '())) ",")
   "]}\n"))

(define (validation-write-result-json path facts)
  "Atomically write the complete machine-readable terminal result."
  (call-with-output-file path
    (lambda (port) (display (validation-result-json facts) port))))

(define (validation-event-json sequence kind timestamp payload)
  "Encode one telemetry event.  SEQUENCE is monotonic within a run.
PAYLOAD remains a string so replay does not need a JSON parser on stock Guile."
  (unless (and (integer? sequence) (> sequence 0))
    (error "event sequence must be a positive integer" sequence))
  (string-append "{\"seq\":" (number->string sequence)
                 ",\"kind\":" (validation-json-string kind)
                 ",\"timestamp\":" (validation-json-string timestamp)
                 ",\"payload\":" (validation-json-string payload) "}"))

(define (validation-event-sequence line)
  "Read the leading numeric seq field emitted by validation-event-json.
Return #f for malformed input; callers must treat it as a journal fault."
  (let ((prefix "{\"seq\":"))
    (and (string-prefix? prefix line)
         (let* ((start (string-length prefix))
                (end (string-index line #\, start)))
           (and end
                (let ((value (string->number (substring line start end))))
                  (and (integer? value) (> value 0) value)))))))

(define (validation-result-event-status line)
  "Return the numeric payload of a result event, otherwise #f."
  (let ((kind "\"kind\":\"result\"")
        (payload "\"payload\":\""))
    (and (string-contains line kind)
         (let ((start-at (string-contains line payload)))
           (and start-at
                (let* ((start (+ start-at (string-length payload)))
                       (end (string-index line #\" start))
                       (value (and end (string->number (substring line start end)))))
                  (and (integer? value) (>= value 0) (<= value 255) value)))))))

(define (validation-latest-result-status lines)
  "Return the newest valid result status without relying on optional SRFIs."
  (let loop ((rest (reverse lines)))
    (and (pair? rest)
         (or (validation-result-event-status (car rest))
             (loop (cdr rest))))))

(define (validation-replay-events remote-lines last-sequence)
  "Validate and select unseen journal lines after LAST-SEQUENCE.
Returns (values unseen new-last error).  A duplicate prefix is allowed because
reconnect fetches may overlap; any gap or malformed event stops replay."
  (let loop ((lines remote-lines) (expected (+ last-sequence 1)) (unseen '()))
    (if (null? lines)
        (values (reverse unseen) (- expected 1) #f)
        (let* ((line (car lines)) (sequence (validation-event-sequence line)))
          (cond
           ((not sequence)
            (values #f last-sequence "malformed remote journal event"))
           ((<= sequence last-sequence)
            (loop (cdr lines) expected unseen))
           ((= sequence expected)
            (loop (cdr lines) (+ expected 1) (cons line unseen)))
           (else
            (values #f last-sequence
                    (string-append "remote journal gap: expected "
                                   (number->string expected) " but received "
                                   (number->string sequence)))))))))

(define (validation-process-journal remote-lines last-sequence)
  "Validate one fetched journal snapshot and derive its completion atomically.
Returns (values unseen new-last result-status error)."
  (call-with-values
      (lambda () (validation-replay-events remote-lines last-sequence))
    (lambda (unseen new-last error)
      (if error
          (values #f last-sequence #f error)
          (values unseen new-last
                  (validation-latest-result-status remote-lines) #f)))))

(define (validation-append-lines path lines)
  "Append already validated JSONL events and force them to stable local output."
  (unless (null? lines)
    (let ((port (open-file path "a")))
      (for-each (lambda (line) (display line port) (newline port)) lines)
      (force-output port)
      (close-port port))))

(define (validation-stream-command/status command log-path)
  "Run local shell COMMAND, tee its already-combined output incrementally.
Returns the child exit status.  The caller supplies `2>&1' intentionally so
SSH transport errors are preserved beside remote stdout/stderr."
  (let ((input (open-input-pipe command))
        (log (open-output-file log-path)))
    (let loop ((c (read-char input)))
      (unless (eof-object? c)
        (write-char c (current-output-port))
        (write-char c log)
        (force-output)
        (force-output log)
        (loop (read-char input))))
    (close-port log)
    (status:exit-val (close-pipe input))))
