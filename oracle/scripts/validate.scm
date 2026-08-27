#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; validate.scm --- one-shot disposable Oracle Guix validation controller.
;;;
;;; OCI credentials and this run's private key remain on the local controller.
;;; The guest receives a source archive, a command file, and only the matching
;;; public key through instance metadata.

(define %script-directory
  (dirname (canonicalize-path (or (current-filename) (car (command-line))))))
(load (string-append %script-directory "/oci-common.scm"))
(load (string-append %script-directory "/validation-common.scm"))

(define (validate-usage)
  (die "usage: validate.scm start --image-id OCID --subnet-id OCID --source PATH "
       "--command COMMAND [--shape SHAPE] [--timeout SECONDS] "
       "[--keep-on-failure] [--yes]"))

(define (validation-run-root source)
  (string-append source "/.oracle-validation/runs"))

(define (write-run-state path run-id phase options instance ip source-hash)
  (validation-write-state
   path `((schema . 1) (kind . oracle-validation) (run-id . ,run-id)
          (managed-by . "guix-platform-install")
          (artifact-state . "IN_TEST") (resource-type . "instance")
          (operation-scope . (inspect collect-console terminate handoff))
          (phase . ,phase) (instance-ocid . ,instance) (public-ip . ,ip)
          (source . ,(validation-option-ref options 'source))
          (command . ,(validation-option-ref options 'command))
          (source-sha256 . ,source-hash)
          (keep-on-failure . ,(validation-option-ref options 'keep-on-failure)))))

(define (snapshot-source source archive manifest hash-file)
  "Archive regular files, directories and symlinks without dereferencing them.
find prunes runner state and excludes sockets/devices before tar sees them."
  (let ((command
         (string-append
          "cd " (validation-sh-quote source)
          " && find . \\("
          " -path './.git' -o -path './.git/*'"
          " -o -path './.oracle-validation' -o -path './.oracle-validation/*' \\) -prune -o"
          " \\(" " -type f -o -type d -o -type l \\) -print0"
          " | tar --null --no-recursion --files-from=- -cf "
          (validation-sh-quote archive))))
    (and (zero? (status:exit-val (system command)))
         (zero? (status:exit-val
                 (system (string-append "tar -tf " (validation-sh-quote archive)
                                        " | sort > " (validation-sh-quote manifest)))))
         (zero? (status:exit-val
                 (system (string-append "sha256sum " (validation-sh-quote archive)
                                        " > " (validation-sh-quote hash-file))))))))

(define (first-field path)
  (let ((line (call-with-input-file path read-line)))
    (and (not (eof-object? line)) (car (string-split line #\space)))))

(define (write-command-file path command)
  "Save user command bytes locally; never interpolate them into an SSH command."
  (call-with-output-file path
    (lambda (port)
      (display "#!/run/current-system/profile/bin/sh\n" port)
      (display command port)
      (newline port)))
  (chmod path #o700))

(define (ssh-base key ip)
  (string-append "ssh -i " (validation-sh-quote key)
                 " -o BatchMode=yes -o StrictHostKeyChecking=no"
                 " -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
                 " guix@" (validation-sh-quote ip)))

(define (cleanup-instance run-dir state-path instance)
  "Terminate only after the complete local/fresh-OCI ownership gate passes."
  (and instance
       (let* ((local (validation-read-state state-path))
              (remote (oci-instance-ownership instance))
              (handoff? (file-exists? (validation-handoff-marker-path state-path))))
         (if (not (validation-ownership-authorized? local remote 'terminate handoff?))
             (begin
               (call-with-output-file (string-append run-dir "/termination.log")
                 (lambda (port)
                   (display "termination blocked: ownership facts did not match\n" port)))
               #f)
             (call-with-values
                 (lambda () (oci-terminate-instance/status instance))
               (lambda (output status)
                 (call-with-output-file (string-append run-dir "/termination.log")
                   (lambda (port) (display output port) (newline port)))
                 (zero? status)))))))

(define (remote-read base path)
  (run-command/status
   (string-append base " 'test -f " path " && cat " path "' 2>/dev/null")))

(define (record-reconnect path text)
  (let ((port (open-file path "a")))
    (display text port) (newline port) (force-output port) (close-port port)))

(define (record-lifecycle run-dir state)
  "Append one bounded OCI lifecycle observation to the exact run evidence."
  (let ((port (open-file (string-append run-dir "/lifecycle.jsonl") "a")))
    (format port "{\"timestamp\":\"~a\",\"state\":\"~a\"}~%"
            (validation-utc-time 0) state)
    (force-output port)
    (close-port port)))

(define (poll-run-evidence instance run-dir)
  "Read lifecycle and refresh console evidence for one exact instance."
  (let ((state (oci-instance-state instance)))
    (record-lifecycle run-dir state)
    ;; Refresh the latest serial history on every evidence cadence, including
    ;; RUNNING, so a later guest loss retains the newest useful console view.
    (oci-capture-console-history
     instance (string-append run-dir "/console-history.log"))
    state))

(define (replay-until-result base remote timeout events-path log-path
                             force-disconnect-after reconnect-path instance run-dir)
  "Reconnect and replay the durable journal until its result file appears."
  (let ((journal (string-append remote "/events.jsonl"))
        (deadline (+ (current-time) (string->number timeout) 180)))
    (let loop ((last-sequence 0) (failures 0) (forced? #f)
               (last-evidence (- (current-time) 30)))
      (if (> (current-time) deadline)
          124
          (let* ((now (current-time))
                 (evidence-state
                  (and (>= (- now last-evidence) 30)
                       (poll-run-evidence instance run-dir))))
            (if (member evidence-state '("TERMINATING" "TERMINATED"))
                (begin
                  (say "[ERROR] guest lost before a result event; evidence retained in " run-dir)
                  127)
                (call-with-values (lambda () (remote-read base journal))
            (lambda (output status)
              (if (zero? status)
                  (let ((lines (if (string-null? output) '()
                                   (string-split output #\newline))))
                    (call-with-values
                        (lambda () (validation-process-journal lines last-sequence))
                      (lambda (unseen new-last result-status error)
                        (if error
                            (begin (say "[ERROR] " error) 125)
                            (begin
                              (validation-append-lines events-path unseen)
                              (validation-append-lines log-path unseen)
                              (for-each (lambda (line) (display line) (newline)) unseen)
                              (if (and force-disconnect-after (not forced?)
                                       (>= new-last force-disconnect-after)
                                       (not result-status))
                                  (let ((forced-status
                                         (status:exit-val
                                          (system (string-append
                                                   "timeout 1 " base
                                                   " 'sleep 30' >/dev/null 2>&1")))))
                                    (record-reconnect
                                     reconnect-path
                                     (string-append "forced SSH interruption after sequence "
                                                    (number->string new-last)
                                                    "; transport status "
                                                    (number->string forced-status)))
                                    (if (zero? forced-status) 126
                                        (loop new-last 0 #t now)))
                                  (if (and result-status (integer? result-status))
                                      result-status
                                      (begin (sleep 5)
                                             (loop new-last 0 forced?
                                                   (if evidence-state now last-evidence))))))))))
                  (begin
                    (when (= (modulo failures 3) 0)
                      (say "[WARN] SSH telemetry unavailable; reconnecting"))
                    (sleep 5)
                    (loop last-sequence (+ failures 1) forced?
                          (if evidence-state now last-evidence)))))))))))
            )

(define (transfer-and-execute key ip run-id archive command-file runner-file
                              remote timeout log events force-disconnect-after
                              reconnect-path instance run-dir)
  "Upload once, detach the guest runner, then reconnect/replay its journal."
  (let* ((base (ssh-base key ip))
         (make-temp (string-append base " 'mkdir -p /tmp/" run-id "' 2>&1"))
         (copy (string-append "scp -i " (validation-sh-quote key)
                              " -o BatchMode=yes -o StrictHostKeyChecking=no"
                              " -o UserKnownHostsFile=/dev/null "
                              (validation-sh-quote archive) " "
                              (validation-sh-quote command-file) " "
                              (validation-sh-quote runner-file) " guix@"
                              (validation-sh-quote ip) ":/tmp/" run-id "/ 2>&1"))
         (prepare
          (string-append base " 'set -e; mkdir -p " remote "/source; tar -xf /tmp/"
                         run-id "/source.tar -C " remote "/source' 2>&1"))
         (start
          (string-append base " 'setsid /run/current-system/profile/bin/guile"
                         " --no-auto-compile -s /tmp/" run-id
                         "/validation-guest-runner.scm " remote "/events.jsonl "
                         remote "/result /tmp/" run-id "/command.sh " timeout
                         " </dev/null >/tmp/" run-id "/runner.log 2>&1 &' 2>&1")))
    ;; RUNNING only means the control plane started the VM.  Wait for the
    ;; metadata-key Shepherd service to install the key before attempting the
    ;; first transfer; otherwise Stage 1 races the same boot-time retry window
    ;; that Stage 0 deliberately measures.
    (if (not (poll-until "authenticated SSH readiness"
                         (lambda ()
                           (zero? (validation-stream-command/status
                                   (string-append base " true 2>&1") log)))
                         10 180))
        1
        (if (not (zero? (validation-stream-command/status make-temp log)))
        1
        (if (not (zero? (validation-stream-command/status copy log)))
            1
            (if (not (zero? (validation-stream-command/status prepare log)))
                1
                (if (not (zero? (validation-stream-command/status start log)))
                    1
                    (replay-until-result base remote timeout events log
                                         force-disconnect-after reconnect-path
                                         instance run-dir))))))))

(define (run-validation options)
  (let* ((source-input (validation-option-ref options 'source))
         (source (and (file-is-directory? source-input)
                      (canonicalize-path source-input)))
         (options (if source
                      (acons 'source source options)
                      options))
         (run-id (validation-run-id))
         (run-dir (string-append (validation-run-root source) "/" run-id))
         (state-path (string-append run-dir "/state.scm"))
         (archive (string-append run-dir "/source.tar"))
         (manifest (string-append run-dir "/source-manifest.txt"))
         (hash-file (string-append run-dir "/source.sha256"))
         (command-file (string-append run-dir "/command.sh"))
         (runner-file (string-append %script-directory "/validation-guest-runner.scm"))
         (key-dir (string-append run-dir "/ssh"))
         (key (string-append key-dir "/id_ed25519"))
         (log (string-append run-dir "/remote-output.log"))
         (events (string-append run-dir "/events.jsonl"))
         (reconnect-log (string-append run-dir "/reconnect.log"))
         (image (validation-option-ref options 'image-id))
         (subnet (validation-option-ref options 'subnet-id))
         (shape (validation-option-ref options 'shape))
         (display-name (string-append "guix-validation-" run-id))
         (instance #f) (ip #f) (source-hash #f))
    (unless (and source (validation-mkdir-p key-dir))
      (die "cannot read source or create run directory: " source-input))
    (write-run-state state-path run-id "prepared" options #f #f #f)
    (write-command-file command-file (validation-option-ref options 'command))
    (unless (snapshot-source source archive manifest hash-file)
      (die "could not create complete source snapshot"))
    (set! source-hash (first-field hash-file))
    (write-run-state state-path run-id "snapshotted" options #f #f source-hash)
    (unless (oci-authenticated?)
      (die "OCI CLI is not authenticated; run 01-setup-client.scm first"))
    (unless (validation-option-ref options 'yes)
      (unless (prompt-yes? (string-append "Upload snapshot " source-hash
                                   " and launch disposable " display-name "?"))
        (say "Cancelled.") (exit 0)))
    (unless (zero? (system* "ssh-keygen" "-q" "-t" "ed25519" "-N" ""
                           "-C" run-id "-f" key))
      (die "ssh-keygen failed"))
    (let* ((public-key (run-command (string-append "command cat "
                                                 (validation-sh-quote (string-append key ".pub")))))
           (domain (or (oci-availability-domain-at 0)
                       (die "no availability domain returned by OCI")))
           (launch (validation-launch-command
                    (or (oci-compartment) (die "no tenancy in ~/.oci/config"))
                    domain shape image subnet display-name
                    (validation-metadata-json public-key)
                    (validation-tags-json run-id
                                          (validation-utc-time 0)
                                          (validation-utc-time
                                           (+ 3600
                                              (string->number
                                               (validation-option-ref options 'timeout))))))))
      (write-run-state state-path run-id "launching" options #f #f source-hash)
      (call-with-values (lambda () (oci/status (string-append launch " 2>&1")))
        (lambda (output status)
          (call-with-output-file (string-append run-dir "/oci-output.log")
            (lambda (port) (display output port) (newline port)))
          (set! instance (and (zero? status) (oci-first-ocid-line output)))))
      (if (not instance)
          (begin
            (write-run-state state-path run-id "launch-failed" options #f #f source-hash)
            (validation-write-result-json (string-append run-dir "/result.json") run-id 1
                                          "launch-failed" "OCI did not return an instance OCID")
            (die "launch failed; evidence is in " run-dir))
          (begin
            (write-run-state state-path run-id "launched" options instance #f source-hash)
            (let* ((running? (poll-until "instance to reach RUNNING"
                                         (lambda () (string=? (oci-instance-state instance) "RUNNING"))
                                         20 900))
                   (exit-status
                    (if (not running?)
                        1
                        (begin
                          (set! ip (oci-instance-public-ip instance))
                          (write-run-state state-path run-id "ssh" options instance ip source-hash)
                          (if (not ip)
                              1
                              (begin
                                (write-run-state state-path run-id "running" options instance ip source-hash)
                                (transfer-and-execute key ip run-id archive command-file runner-file
                                                      (validation-remote-directory run-id)
                                                      (validation-option-ref options 'timeout)
                                                      log events
                                                      (let ((value (validation-option-ref
                                                                    options 'force-disconnect-after)))
                                                        (and value (string->number value)))
                                                      reconnect-log instance run-dir))))))
                   (action (validation-cleanup-action
                            exit-status (validation-option-ref options 'keep-on-failure)))
                   (_console (oci-capture-console-history
                              instance (string-append run-dir "/console-history.log")))
                   (clean? (or (eq? action 'keep)
                               (cleanup-instance run-dir state-path instance)))
                   (final (if (and (zero? exit-status) clean?) 0 1)))
              (when (and clean? (eq? action 'terminate) (file-exists? key))
                (delete-file key))
              (write-run-state state-path run-id (if (zero? final) "complete" "failed")
                               options instance ip source-hash)
              (validation-write-result-json
               (string-append run-dir "/result.json") run-id final
               (if (zero? exit-status) "complete" "failed")
               (if (eq? action 'keep)
                   (string-append "failure retained instance; terminate with: "
                                  (oci-terminate-command instance))
                   (if clean? "instance terminated" "instance cleanup failed; inspect termination.log")))
              (if (zero? final)
                  (say "[OK] validation completed; result: " run-dir "/result.json")
                  (begin
                    (when (or (eq? action 'keep) (not clean?))
                      (say "Instance OCID: " instance)
                      (say "Manual cleanup command:")
                      (say "  " %oci-cli " " (oci-terminate-command instance)))
                    (die "validation failed; evidence: " run-dir)))))))))

(define (main args)
  (unless (and (pair? args) (string=? (car args) "start")) (validate-usage))
  (call-with-values
      (lambda () (validation-parse-start (cdr args)))
    (lambda (options parse-error)
      (when parse-error (die parse-error))
      (run-validation options))))

(unless (getenv "ORACLE_VALIDATION_TEST_MODE")
  (main (cdr (command-line))))
