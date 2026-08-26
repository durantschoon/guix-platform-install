#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#
;;; oci-inspect.scm --- repeatable, non-destructive OCI inspection commands.

(define %inspect-script-directory
  (canonicalize-path (dirname (car (command-line)))))

(load (string-append %inspect-script-directory "/oci-common.scm"))

(define (usage)
  (say "Usage:")
  (say "  oci-inspect.scm auth")
  (say "  oci-inspect.scm inventory")
  (say "  oci-inspect.scm instance --instance-id OCID")
  (say "  oci-inspect.scm evidence --instance-id OCID --output-dir DIR")
  (say "")
  (say "All cloud operations are non-destructive.  evidence writes instance,")
  (say "VNIC, and best-effort serial-console records beneath DIR."))

(define (instance-ocid? value)
  (and value (string-prefix? "ocid1.instance." value)
       (not (string-any char-whitespace? value))))

(define (parse-options args)
  (let loop ((rest args) (options '()))
    (cond ((null? rest) options)
          ((not (member (car rest) '("--instance-id" "--output-dir")))
           (die "unknown option: " (car rest)))
          ((null? (cdr rest)) (die "option requires a value: " (car rest)))
          (else
           (loop (cddr rest)
                 (acons (string->symbol (substring (car rest) 2))
                        (cadr rest) options))))))

(define (required-option options key)
  (let ((entry (assoc key options)))
    (or (and entry (cdr entry))
        (die "missing required option --" (symbol->string key)))))

(define (require-instance-id options)
  (let ((value (required-option options 'instance-id)))
    (if (instance-ocid? value) value
        (die "invalid instance OCID"))))

(define (write-text path content)
  (call-with-output-file path
    (lambda (port) (display content port) (newline port))))

(define (auth)
  (unless (oci-authenticated?)
    (die "OCI authentication failed; inspect ~/.oci/config and key_file"))
  (say "[OK] OCI authentication succeeded")
  (say (oci "iam region-subscription list --query 'data[].\"region-name\"' --output table")))

(define (inventory)
  (let ((compartment (or (oci-compartment)
                         (die "no tenancy in ~/.oci/config"))))
    (say (oci
          (string-append
           "compute instance list --all --compartment-id "
           (sh-quote compartment)
           " --query 'data[?\"lifecycle-state\"!=`TERMINATED`]."
           "{id:id,name:\"display-name\",state:\"lifecycle-state\","
           "shape:shape,created:\"time-created\"}' --output table")))))

(define (instance-record instance-id)
  (oci
   (string-append
    "compute instance get --instance-id " (sh-quote instance-id)
    " --query 'data.{id:id,name:\"display-name\",state:\"lifecycle-state\","
    "shape:shape,created:\"time-created\",metadata:metadata,"
    "instanceOptions:\"instance-options\"}' --output json")))

(define (vnic-record instance-id)
  (oci
   (string-append
    "compute instance list-vnics --instance-id " (sh-quote instance-id)
    " --query 'data[].{id:id,publicIp:\"public-ip\",privateIp:\"private-ip\","
    "state:\"lifecycle-state\"}' --output json")))

(define (inspect-instance options)
  (let ((instance-id (require-instance-id options)))
    (say (instance-record instance-id))
    (say (vnic-record instance-id))))

(define (collect-evidence options)
  (let* ((instance-id (require-instance-id options))
         (output-dir (required-option options 'output-dir)))
    (unless (zero? (system* "mkdir" "-p" output-dir))
      (die "could not create output directory: " output-dir))
    (write-text (string-append output-dir "/instance.json")
                (instance-record instance-id))
    (write-text (string-append output-dir "/vnics.json")
                (vnic-record instance-id))
    (if (oci-capture-console-history
         instance-id (string-append output-dir "/console-history.log"))
        (say "[OK] wrote OCI evidence beneath " output-dir)
        (begin
          (say "[WARN] instance/VNIC evidence written, but console capture failed")
          (exit 2)))))

(define (main args)
  (if (null? args)
      (begin (usage) (exit 1))
      (let ((command (car args)) (options (parse-options (cdr args))))
        (cond ((string=? command "auth") (auth))
              ((string=? command "inventory") (inventory))
              ((string=? command "instance") (inspect-instance options))
              ((string=? command "evidence") (collect-evidence options))
              ((member command '("help" "--help" "-h")) (usage))
              (else (usage) (die "unknown command: " command))))))

(unless (getenv "ORACLE_VALIDATION_TEST_MODE")
  (main (cdr (command-line))))
