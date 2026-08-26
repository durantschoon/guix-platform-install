;;; oci-common.scm --- shared helpers for the Oracle Cloud scripts.
;;;
;;; Loaded (not imported as a module) by the numbered scripts in this
;;; directory, so it must stay free of side effects at load time.
;;;
;;; Design constraints these helpers encode:
;;;   - All user prompts read from /dev/tty, never stdin (repo pattern:
;;;     stdin may be redirected by the caller).
;;;   - The oci CLI is always invoked with --query/--raw-output so no
;;;     JSON parser is needed in Guile (guile-json is not in core and
;;;     this script must run on a bare `guix install python`-level box).
;;;   - Output is plain ASCII: [OK] / [ERROR], no Unicode.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; ---------------------------------------------------------------------
;;; Process helpers

(define (run-command cmd)
  "Run shell command CMD, return its stdout as a trimmed string.
Stderr passes through to the terminal."
  (let* ((port (open-input-pipe cmd))
         (output (get-string-all port))
         (status (close-pipe port)))
    (string-trim-both output)))

(define (run-command/status cmd)
  "Run shell command CMD, return two values: trimmed stdout and exit status."
  (let* ((port (open-input-pipe cmd))
         (output (get-string-all port))
         (status (close-pipe port)))
    (values (string-trim-both output)
            (status:exit-val status))))

(define (command-succeeds? cmd)
  "Return #t if CMD exits 0.  Both stdout and stderr are discarded."
  (call-with-values
      (lambda () (run-command/status (string-append cmd " 2>/dev/null")))
    (lambda (output status) (zero? status))))

(define (sh-quote str)
  "Single-quote STR for safe interpolation into a shell command."
  (string-append "'" (string-join (string-split str #\') "'\\''") "'"))

;;; ---------------------------------------------------------------------
;;; Terminal helpers

(define (say . parts)
  "Print PARTS followed by a newline."
  (for-each display parts)
  (newline))

(define (prompt-tty question)
  "Ask QUESTION and read one line from /dev/tty (never stdin)."
  (display question)
  (display " ")
  (force-output)
  (call-with-input-file "/dev/tty" read-line))

(define (prompt-yes? question)
  "Ask a yes/no QUESTION on /dev/tty; empty answer means yes."
  (let ((answer (prompt-tty (string-append question " [Y/n]"))))
    (or (string-null? answer)
        (memv (string-ref answer 0) '(#\y #\Y)))))

(define (die . parts)
  "Print PARTS as an [ERROR] line and exit 1."
  (display "[ERROR] ")
  (for-each display parts)
  (newline)
  (exit 1))

;;; ---------------------------------------------------------------------
;;; Paths and configuration

(define (home-path . parts)
  "Join PARTS onto $HOME."
  (string-join (cons (getenv "HOME") parts) "/"))

(define %oci-common-directory
  (dirname (or (current-filename) ".")))

(define (darwin?)
  "Return #t only on macOS.  Mac-specific helpers are not loaded elsewhere."
  (string=? (utsname:sysname (uname)) "Darwin"))

(when (darwin?)
  (load (string-append %oci-common-directory "/macos/oci-client.scm")))

(define %oci-cli
  (let ((override (getenv "OCI_CLI"))
        (venv-cli (home-path ".venvs" "oci-cli" "bin" "oci")))
    (cond ((and override (not (string-null? override))) override)
          ((file-exists? venv-cli) venv-cli)
          ((darwin?) (macos-resolve-oci-cli))
          (else venv-cli))))
(define %oci-venv-python (home-path ".venvs" "oci-cli" "bin" "python3"))
(define %oci-config (home-path ".oci" "config"))
(define %oci-global-options "--connection-timeout 10 --read-timeout 30")

(define (oci-config-value key)
  "Read KEY from the [DEFAULT] section of ~/.oci/config, or #f."
  (and (file-exists? %oci-config)
       (let ((match (run-command
                     (string-append "command grep -m1 '^" key "=' "
                                    (sh-quote %oci-config)
                                    " 2>/dev/null | command cut -d= -f2-"))))
         (and (not (string-null? match)) match))))

(define (oci cmd)
  "Run an oci CLI subcommand string CMD, return trimmed stdout.
SUPPRESS_LABEL_WARNING silences the key-label advice on every call."
  (run-command
   (string-append "SUPPRESS_LABEL_WARNING=True " %oci-cli " "
                  %oci-global-options " " cmd)))

(define (oci/status cmd)
  "Like `oci' but returns (values stdout exit-status)."
  (run-command/status
   (string-append "SUPPRESS_LABEL_WARNING=True " %oci-cli " "
                  %oci-global-options " " cmd)))

(define (oci-authenticated?)
  "Return #t if the oci CLI can make an authenticated API call."
  (command-succeeds?
   (string-append "SUPPRESS_LABEL_WARNING=True " %oci-cli
                  " " %oci-global-options
                  " iam region-subscription list --output table"
                  " >/dev/null")))

;;; ---------------------------------------------------------------------
;;; Neutral Compute helpers
;;;
;;; These are deliberately parameterized: 04-deploy.scm owns its named,
;;; idempotent installation resources, while disposable validation runs must
;;; be identified by an OCID recorded locally rather than a display name.

(define (oci-nonempty-or-false text)
  "Return TEXT unless it is empty or OCI's raw-output spelling of null."
  (and (not (string-null? text))
       (not (string=? text "None"))
       text))

(define (oci-first-ocid-line text)
  "Return the first OCID-looking line in TEXT, or #f.
OCI errors are often combined with stdout, so successful raw output cannot be
assumed to be the whole captured string."
  (let loop ((lines (string-split text #\newline)))
    (cond ((null? lines) #f)
          ((string-prefix? "ocid1." (string-trim-both (car lines)))
           (string-trim-both (car lines)))
          (else (loop (cdr lines))))))

(define (oci-compartment)
  "Return the configured tenancy/root compartment, or #f."
  (oci-config-value "tenancy"))

(define (oci-availability-domain-at index)
  "Return availability-domain INDEX, or #f when it is out of range."
  (oci-nonempty-or-false
   (oci (string-append "iam availability-domain list --query 'data["
                       (number->string index) "].name' --raw-output 2>/dev/null"))))

(define (oci-instance-state instance-ocid)
  "Return INSTANCE-OCID's lifecycle state as OCI raw output."
  (oci (string-append "compute instance get --instance-id "
                      (sh-quote instance-ocid)
                      " --query 'data.\"lifecycle-state\"' --raw-output")))

(define (oci-instance-public-ip instance-ocid)
  "Return INSTANCE-OCID's first VNIC public IP, or #f."
  (oci-nonempty-or-false
   (oci (string-append "compute instance list-vnics --instance-id "
                       (sh-quote instance-ocid)
                       " --query 'data[0].\"public-ip\"' --raw-output"))))

(define (oci-terminate-command instance-ocid)
  "Build the explicit disposable-instance termination command.
The false preserve value matters: retaining a boot volume defeats the cleanup
policy and can incur storage charges."
  (string-append "compute instance terminate --instance-id "
                 (sh-quote instance-ocid)
                 " --preserve-boot-volume false --force"))

(define (oci-terminate-instance/status instance-ocid)
  "Terminate INSTANCE-OCID and return OCI output and exit status."
  (oci/status (string-append (oci-terminate-command instance-ocid) " 2>&1")))

(define (oci-capture-console-history instance-ocid output-path)
  "Best-effort capture of INSTANCE-OCID's serial console into OUTPUT-PATH.
Console-history failure must not prevent termination of a disposable instance."
  (call-with-values
      (lambda ()
        (oci/status
         (string-append
          "compute console-history capture --instance-id "
          (sh-quote instance-ocid)
          " --query data.id --raw-output 2>&1")))
    (lambda (capture-output capture-status)
      (if (not (zero? capture-status))
          (begin
            (call-with-output-file output-path
              (lambda (port)
                (display "console-history capture failed:\n" port)
                (display capture-output port)
                (newline port)))
            #f)
          (let ((history-ocid (oci-first-ocid-line capture-output)))
            (if (not history-ocid)
                #f
                (let ((ready?
                       (poll-until
                        "serial console history"
                        (lambda ()
                          (let ((state
                                 (oci
                                  (string-append
                                   "compute console-history get"
                                   " --instance-console-history-id "
                                   (sh-quote history-ocid)
                                   " --query 'data.\"lifecycle-state\"'"
                                   " --raw-output 2>/dev/null"))))
                            (and (string=? state "SUCCEEDED") #t)))
                        5 60)))
                  (if (not ready?)
                      #f
                      (call-with-values
                          (lambda ()
                            (oci/status
                             (string-append
                              "compute console-history get-content"
                              " --instance-console-history-id "
                              (sh-quote history-ocid) " --file "
                              (sh-quote output-path) " 2>&1")))
                        (lambda (output status)
                          (if (zero? status)
                              #t
                              (begin
                                (call-with-output-file output-path
                                  (lambda (port)
                                    (display "console-history retrieval failed:\n" port)
                                    (display output port)
                                    (newline port)))
                                #f))))))))))))

;;; ---------------------------------------------------------------------
;;; Polling

(define (poll-until description thunk interval-seconds max-seconds)
  "Call THUNK every INTERVAL-SECONDS until it returns non-#f or
MAX-SECONDS elapse.  Returns the thunk's value, or #f on timeout.
Prints DESCRIPTION once and a dot per attempt so the user sees life."
  (say "Waiting for " description " (up to " max-seconds "s)...")
  (let loop ((elapsed 0))
    (let ((result (thunk)))
      (cond
       (result
        (newline)
        result)
       ((>= elapsed max-seconds)
        (newline)
        #f)
       (else
        (display ".")
        (force-output)
        (sleep interval-seconds)
        (loop (+ elapsed interval-seconds)))))))
