#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; 05-verify-metadata-ssh.scm --- live proof of OCI metadata-only SSH login.
;;;
;;; This is deliberately a small disposable probe, not a deployment script.
;;; It verifies the one prerequisite that cannot be proven in QEMU: the Guix
;;; shepherd service reads an OCI-provided key early enough for SSH login.

(define %script-directory (dirname (canonicalize-path (car (command-line)))))
(load (string-append %script-directory "/oci-common.scm"))
(load (string-append %script-directory "/validation-common.scm"))

(define (probe-usage)
  (die "usage: 05-verify-metadata-ssh.scm --image-id OCID --subnet-id OCID "
       "[--shape SHAPE] [--yes]"))

(define (probe-root)
  (string-append (getcwd) "/.oracle-validation/runs"))

(define (write-probe-state path run-id phase instance-ocid ip)
  (validation-write-state
   path `((schema . 1) (kind . metadata-ssh-probe) (run-id . ,run-id)
          (phase . ,phase) (instance-ocid . ,instance-ocid) (public-ip . ,ip))))

(define (first-domain-or-die)
  (or (oci-availability-domain-at 0)
      (die "no availability domain returned by OCI")))

(define (wait-for-ssh-login key ip log-path)
  "Retry a real key login.  A denial is failure here, unlike 04's banner probe."
  (let ((ssh (string-append "ssh -i " (validation-sh-quote key)
                            " -o BatchMode=yes -o StrictHostKeyChecking=no"
                            " -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
                            " guix@" (validation-sh-quote ip) " true 2>&1")))
    (poll-until "metadata-only SSH login"
                (lambda ()
                  (zero? (validation-stream-command/status ssh log-path)))
                10 600)))

(define (main args)
  (call-with-values
      (lambda () (validation-parse-probe args))
    (lambda (options parse-error)
      (when parse-error (die parse-error))
      (unless (oci-authenticated?)
        (die "OCI CLI is not authenticated; run 01-setup-client.scm first"))
      (let* ((run-id (validation-run-id))
             (run-dir (string-append (probe-root) "/" run-id))
             (state-path (string-append run-dir "/state.scm"))
             (log-path (string-append run-dir "/remote-output.log"))
             (key (string-append run-dir "/id_ed25519"))
             (image (validation-option-ref options 'image-id))
             (subnet (validation-option-ref options 'subnet-id))
             (shape (or (validation-option-ref options 'shape) "VM.Standard.E2.1.Micro"))
             (display-name (string-append "guix-validation-probe-" run-id)))
        (unless (validation-mkdir-p run-dir) (die "cannot create " run-dir))
        (write-probe-state state-path run-id "prepared" #f #f)
        (unless (validation-option-ref options 'yes)
          (unless (prompt-yes? (string-append "Launch disposable metadata-only SSH probe "
                                       display-name " and delete it afterward?"))
            (say "Cancelled.") (exit 0)))
        (unless (zero? (system* "ssh-keygen" "-q" "-t" "ed25519" "-N" ""
                               "-C" run-id "-f" key))
          (die "ssh-keygen failed"))
        (let* ((public-key (run-command (string-append "command cat "
                                                     (validation-sh-quote
                                                      (string-append key ".pub")))))
               (command (validation-launch-command
                         (or (oci-compartment) (die "no tenancy in ~/.oci/config"))
                         (first-domain-or-die) shape image subnet display-name
                         (validation-metadata-json public-key)
                         (validation-tags-json run-id
                                               (validation-utc-time 0)
                                               (validation-utc-time 3600)))))
          (write-probe-state state-path run-id "launching" #f #f)
          (call-with-values
              (lambda () (oci/status (string-append command " 2>&1")))
            (lambda (output status)
              (call-with-output-file (string-append run-dir "/oci-output.log")
                (lambda (port) (display output port) (newline port)))
              (let ((instance (and (zero? status) (oci-first-ocid-line output))))
                (if (not instance)
                    (begin
                      (write-probe-state state-path run-id "launch-failed" #f #f)
                      (validation-write-result-json (string-append run-dir "/result.json")
                                                    run-id 1 "launch-failed" output)
                      (die "probe launch failed; evidence is in " run-dir))
                    (begin
                      (write-probe-state state-path run-id "launched" instance #f)
                      (let ((ok (and (poll-until "probe instance to reach RUNNING"
                                                 (lambda () (string=? (oci-instance-state instance) "RUNNING"))
                                                 20 900)
                                     (let ((ip (oci-instance-public-ip instance)))
                                       (and ip
                                            (begin (write-probe-state state-path run-id "ssh" instance ip)
                                                   (wait-for-ssh-login key ip log-path)))))))
                        (let ((last-ip (oci-instance-public-ip instance)))
                          (write-probe-state state-path run-id
                                             (if ok "passed" "failed")
                                             instance last-ip))
                        (oci-capture-console-history
                         instance (string-append run-dir "/console-history.log"))
                        ;; The recorded OCID, rather than the display name, is the cleanup target.
                        (call-with-values (lambda () (oci-terminate-instance/status instance))
                          (lambda (termination-output termination-status)
                            (call-with-output-file (string-append run-dir "/termination.log")
                              (lambda (port) (display termination-output port) (newline port)))
                            (validation-write-result-json
                             (string-append run-dir "/result.json") run-id
                             (if (and ok (zero? termination-status)) 0 1)
                             (if ok "passed" "failed")
                             (if ok "metadata-only SSH login succeeded; live result recorded"
                                 "metadata-only SSH probe failed; inspect local evidence"))
                            (if (zero? termination-status)
                                (begin
                                  (when (file-exists? key) (delete-file key))
                                  (if ok
                                      (say "[OK] metadata-only SSH probe passed; instance terminated")
                                      (die "metadata-only SSH probe failed; instance terminated; inspect "
                                           run-dir)))
                                (begin
                                  (say "Manual cleanup command:")
                                  (say "  " %oci-cli " " (oci-terminate-command instance))
                                  (die "probe cleanup failed; inspect " run-dir))))))))))))))))

(unless (getenv "ORACLE_VALIDATION_TEST_MODE")
  (main (cdr (command-line))))
