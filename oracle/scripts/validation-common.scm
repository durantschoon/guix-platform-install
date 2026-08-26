;;; validation-common.scm --- pure and local helpers for OCI validation runs.
;;;
;;; Loaded by validation scripts, never as a module.  Keep this free of OCI
;;; calls and load-time effects so oracle/tests/test-oracle-validation.scm can
;;; exercise its security-sensitive construction rules offline.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
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

(define (validation-tags-json run-id created-at expires-at)
  "Return the disposable-run tags passed to OCI's --freeform-tags."
  (string-append "{\"managed-by\":\"guix-platform-install\","
                 "\"artifact-state\":\"IN_TEST\","
                 "\"purpose\":\"guix-validation\",\"run-id\":"
                 (validation-json-string run-id)
                 ",\"created-at\":" (validation-json-string created-at)
                 ",\"expires-at\":" (validation-json-string expires-at) "}"))

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

(define (validation-option-ref options key)
  (let ((entry (assoc key options))) (and entry (cdr entry))))

(define (validation-parse-start args)
  "Parse validate.scm's start arguments, returning (values options error).
The small parser keeps Stage 1 dependency-free and makes required inputs
testable without invoking OCI."
  (let loop ((rest args)
             (options `((shape . "VM.Standard.E2.1.Micro")
                        (timeout . "3600")
                        (keep-on-failure . #f)
                        (yes . #f))))
    (cond
     ((null? rest)
      (let ((missing (filter (lambda (key) (not (validation-option-ref options key)))
                             '(image-id subnet-id source command))))
        (if (null? missing)
            (let ((timeout (string->number
                            (validation-option-ref options 'timeout))))
              (if (and timeout (integer? timeout) (> timeout 0))
                  (values options #f)
                  (values #f "--timeout must be a positive integer")))
            (values #f (string-append "missing required option --"
                                      (symbol->string (car missing)))))))
     ((member (car rest) '("--keep-on-failure" "--yes"))
      (loop (cdr rest)
            (acons (if (string=? (car rest) "--yes") 'yes 'keep-on-failure)
                   #t options)))
     ((member (car rest) '("--image-id" "--subnet-id" "--source" "--command"
                           "--shape" "--timeout"))
      (if (null? (cdr rest))
          (values #f (string-append "option requires a value: " (car rest)))
          (loop (cddr rest)
                (acons (string->symbol (substring (car rest) 2)) (cadr rest)
                       options))))
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

(define (validation-write-result-json path run-id status phase message)
  "Write a deliberately small machine-readable result without a JSON library."
  (call-with-output-file path
    (lambda (port)
      (display "{\"run_id\":" port) (display (validation-json-string run-id) port)
      (display ",\"status\":" port) (display (number->string status) port)
      (display ",\"phase\":" port) (display (validation-json-string phase) port)
      (display ",\"message\":" port) (display (validation-json-string message) port)
      (display "}\n" port))))

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
