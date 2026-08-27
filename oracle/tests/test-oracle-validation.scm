#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-oracle-validation.scm --- offline tests for disposable OCI validation.
;;;
;;; The helpers under test are deliberately loaded directly: validation-common
;;; and oci-common contain no OCI calls or controller dispatch at load time.
;;; The two controllers are inspected as source because loading them would
;;; define their live entry points and make this suite needlessly fragile.

(use-modules (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (absolute path)
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define validation-common
  (string-append repository-root "/oracle/scripts/validation-common.scm"))
(define oci-common
  (string-append repository-root "/oracle/scripts/oci-common.scm"))
(define validate-script
  (string-append repository-root "/oracle/scripts/validate.scm"))
(define probe-script
  (string-append repository-root "/oracle/scripts/05-verify-metadata-ssh.scm"))
(define inspect-script
  (string-append repository-root "/oracle/scripts/oci-inspect.scm"))
(define lifecycle-script
  (string-append repository-root "/oracle/scripts/validation-lifecycle.scm"))
(define guest-runner-script
  (string-append repository-root "/oracle/scripts/validation-guest-runner.scm"))
(define macos-oci-client
  (string-append repository-root "/oracle/scripts/macos/oci-client.scm"))
(define makefile (string-append repository-root "/Makefile"))

;;; Both files are helper libraries in script form.  Loading them in the test
;;; process is safe by design and avoids copying their implementation here.
(load oci-common)
(load validation-common)

(define failures 0)
(define checks 0)

(define (pass text)
  (set! checks (+ checks 1))
  (format #t "  [OK]   ~a\n" text))

(define (fail text detail)
  (set! checks (+ checks 1))
  (set! failures (+ failures 1))
  (format #t "  [FAIL] ~a\n" text)
  (unless (string-null? detail)
    (for-each (lambda (line) (format #t "         ~a\n" line))
              (string-split (string-trim-right detail) #\newline))))

(define (check text ok? . details)
  (if ok?
      (pass text)
      (fail text (if (null? details) "" (car details)))))

(define (read-text path)
  (call-with-input-file path get-string-all))

(define validate-source (read-text validate-script))
(define probe-source (read-text probe-script))
(define inspect-source (read-text inspect-script))
(define lifecycle-source (read-text lifecycle-script))
(define guest-runner-source (read-text guest-runner-script))
(define oci-common-source (read-text oci-common))
(define macos-oci-source (read-text macos-oci-client))
(define makefile-source (read-text makefile))

(format #t "Testing Oracle validation helpers (offline)\n")
(format #t "  Helpers: ~a, ~a\n\n" validation-common oci-common)

(check "common OCI helper loads Mac paths only after Darwin detection"
       (and (string-contains oci-common-source "(when (darwin?)")
            (string-contains oci-common-source "/macos/oci-client.scm")
            (not (string-contains oci-common-source "/opt/homebrew/bin/oci"))
            (string-contains macos-oci-source "/opt/homebrew/bin/oci")))

(check "all shared OCI calls have explicit connection/read timeouts"
       (and (string-contains oci-common-source "--connection-timeout 10")
            (string-contains oci-common-source "--read-timeout 30")
            (string-contains oci-common-source "%oci-global-options")))

;;; ---------------------------------------------------------------------------
;;; JSON and metadata construction

(check "JSON escaping protects quotes, slashes, and controls"
       (string=?
        (validation-json-escape "a\\b\"c\n\r\t\x01")
        "a\\\\b\\\"c\\n\\r\\t\\u0001")
       (validation-json-escape "a\\b\"c\n\r\t\x01"))

(define public-key "ssh-ed25519 AAAA-public-key 'with-quote\\suffix")
(define metadata (validation-metadata-json public-key))

(check "metadata contains exactly the public SSH key field"
       (string=? metadata
                 (string-append "{\"ssh_authorized_keys\":\""
                                (validation-json-escape public-key) "\"}"))
       metadata)
(check "metadata does not contain a private-key fixture"
       (and (string-contains metadata "ssh-ed25519")
            (not (string-contains metadata "PRIVATE-KEY-FIXTURE")))
       metadata)

;;; ---------------------------------------------------------------------------
;;; Identifiers, paths, and snapshot policy

(check "safe run IDs accept readable generated-style identifiers"
       (validation-safe-run-id? "20260823T120000Z-abc-123"))
(check "run IDs reject short, empty, and shell/path punctuation"
       (and (not (validation-safe-run-id? "short"))
            (not (validation-safe-run-id? "20260823T120000Z;rm"))
            (not (validation-safe-run-id? "20260823T120000Z/x"))))
(check "generated run ID satisfies its own safety predicate"
       (validation-safe-run-id? (validation-run-id)))

(check "relative source paths are accepted"
       (and (validation-path-safe? "src/main.scm")
            (validation-path-safe? "./source")))
(check "absolute and traversal paths are rejected"
       (and (not (validation-path-safe? "/etc/passwd"))
            (not (validation-path-safe? "../outside"))
            (not (validation-path-safe? "source/../../outside"))
            (not (validation-path-safe? ""))
            (not (validation-path-safe? "nul\x00byte"))))

(check "snapshot excludes the repository's .git tree"
       (and (validation-snapshot-excluded? ".git")
            (validation-snapshot-excluded? ".git/config")
            (not (validation-snapshot-excluded? "src/.git/config"))))
(check "snapshot excludes only local validation bookkeeping"
       (and (validation-snapshot-excluded? ".oracle-validation")
            (validation-snapshot-excluded? ".oracle-validation/runs/x")
            (not (validation-snapshot-excluded? "src/.oracle-validation/file"))
            (not (validation-snapshot-excluded? "README.md"))))
(check "remote directory is fixed beneath the validation cache"
       (and (string=? (validation-remote-directory "20260823T120000Z-run_1")
                      "/home/guix/.cache/oracle-validation/20260823T120000Z-run_1")
            (not (validation-remote-directory "../escape-run"))))

;;; ---------------------------------------------------------------------------
;;; Argument parsers

(define (parse-start args)
  (call-with-values (lambda () (validation-parse-start args)) cons))

(define valid-start
  (parse-start '("--image-id" "ocid1.image.fixture"
                 "--subnet-id" "ocid1.subnet.fixture"
                 "--source" "." "--command" "make check"
                 "--shape" "VM.Standard.E2.1.Micro" "--timeout" "60"
                 "--keep-on-failure" "--yes")))

(check "start parser accepts all required options and flags"
       (and (car valid-start)
            (not (cdr valid-start))
            (string=? (validation-option-ref (car valid-start) 'timeout) "60")
            (validation-option-ref (car valid-start) 'keep-on-failure)
            (validation-option-ref (car valid-start) 'yes)))

(check "start parser supplies safe defaults"
       (let ((options (car (parse-start '("--image-id" "image"
                                          "--subnet-id" "subnet"
                                          "--source" "." "--command" "true")))))
         (and (string=? (validation-option-ref options 'shape)
                        "VM.Standard.E2.1.Micro")
              (string=? (validation-option-ref options 'timeout) "3600")
              (not (validation-option-ref options 'keep-on-failure)))))
(check "start parser accepts a positive forced-disconnect sequence"
       (let ((options (car (parse-start '("--image-id" "image"
                                          "--subnet-id" "subnet"
                                          "--source" "." "--command" "true"
                                          "--force-disconnect-after" "2")))))
         (string=? (validation-option-ref options 'force-disconnect-after) "2")))
(check "start parser rejects an invalid forced-disconnect sequence"
       (let ((result (parse-start '("--image-id" "image" "--subnet-id" "subnet"
                                    "--source" "." "--command" "true"
                                    "--force-disconnect-after" "0"))))
         (and (not (car result)) (string-contains (cdr result) "positive integers"))))

(for-each
 (lambda (timeout)
   (let ((result (parse-start (list "--image-id" "image"
                                    "--subnet-id" "subnet"
                                    "--source" "." "--command" "true"
                                    "--timeout" timeout))))
     (check (string-append "start parser rejects invalid timeout " timeout)
            (and (not (car result))
                 (string-contains (cdr result) "positive integer"))
            (format #f "~s" result))))
 '("0" "-1" "abc" "1.5"))

(let ((result (parse-start '("--image-id" "image" "--subnet-id" "subnet"
                            "--source" "."))))
  (check "start parser reports missing --command"
         (and (not (car result))
              (string-contains (cdr result) "--command"))))

(define (parse-probe args)
  (call-with-values (lambda () (validation-parse-probe args)) cons))

(check "probe parser accepts image, subnet, shape, and --yes"
       (let ((result (parse-probe '("--image-id" "image"
                                    "--subnet-id" "subnet"
                                    "--shape" "shape" "--yes"))))
         (and (car result) (not (cdr result))
              (validation-option-ref (car result) 'yes)
              (string=? (validation-option-ref (car result) 'shape) "shape"))))
(check "probe parser requires both image and subnet"
       (let ((result (parse-probe '("--image-id" "image"))))
         (and (not (car result))
              (string-contains (cdr result) "both"))))

;;; ---------------------------------------------------------------------------
;;; Launch and cleanup command policy

(define run-id "20260823T120000Z-test-run")
(define tags (validation-tags-json run-id "fixture-created" "fixture-expiry"))
(define launch
  (validation-launch-command "ocid1.compartment.fixture"
                             "AD-1" "VM.Standard.E2.1.Micro"
                             "ocid1.image.fixture" "ocid1.subnet.fixture"
                             "guix-validation-test" metadata tags))

(check "launch command carries metadata and disposable tags"
       (and (string-contains launch "--metadata")
            (string-contains launch (validation-sh-quote metadata))
            (string-contains launch "--freeform-tags")
            (string-contains launch (validation-sh-quote tags))
            (string-contains tags "\"managed-by\":\"guix-platform-install\"")
            (string-contains tags "\"artifact-state\":\"IN_TEST\"")
            (string-contains tags "guix-validation")
            (string-contains tags run-id)))
(check "launch command disables legacy IMDS endpoints"
       (and (string-contains launch "are-legacy-imds-endpoints-disabled")
            (string-contains launch "true")))
(check "launch command fixture contains no private secret"
       (and (string-contains launch "AAAA-public-key")
            (not (string-contains launch "PRIVATE-KEY-FIXTURE"))))

(check "successful validation always terminates the instance"
       (eq? (validation-cleanup-action 0 #t) 'terminate))
(check "failed validation keeps the instance only when requested"
       (and (eq? (validation-cleanup-action 1 #t) 'keep)
            (eq? (validation-cleanup-action 1 #f) 'terminate)))

(define ownership-local
  `((managed-by . "guix-platform-install") (artifact-state . "IN_TEST")
    (run-id . ,run-id) (resource-type . "instance")
    (instance-ocid . "ocid1.instance.fixture")
    (operation-scope . (inspect collect-console terminate handoff))))
(define ownership-remote
  `((managed-by . "guix-platform-install") (artifact-state . "IN_TEST")
    (run-id . ,run-id) (instance-ocid . "ocid1.instance.fixture")))

(check "ownership gate permits an exact IN_TEST termination match"
       (validation-ownership-authorized? ownership-local ownership-remote
                                         'terminate #f))
(check "ownership gate denies absent OCI tags"
       (not (validation-ownership-authorized? ownership-local '() 'terminate #f)))
(check "ownership gate denies mismatched run IDs"
       (not (validation-ownership-authorized?
             ownership-local
             (acons 'run-id "20260823T120000Z-other-run" ownership-remote)
             'terminate #f)))
(check "ownership gate denies a mismatched exact OCID"
       (not (validation-ownership-authorized?
             ownership-local
             (acons 'instance-ocid "ocid1.instance.other" ownership-remote)
             'terminate #f)))
(check "ownership gate denies operations outside declared scope"
       (not (validation-ownership-authorized? ownership-local ownership-remote
                                              'delete-image #f)))
(check "ownership gate denies local HANDED_OFF state"
       (not (validation-ownership-authorized?
             (acons 'artifact-state "HANDED_OFF" ownership-local)
             ownership-remote 'terminate #f)))
(check "ownership gate denies remote HANDED_OFF state"
       (not (validation-ownership-authorized?
             ownership-local
             (acons 'artifact-state "HANDED_OFF" ownership-remote)
             'terminate #f)))
(check "ownership gate denies an interrupted handoff marker"
       (not (validation-ownership-authorized? ownership-local ownership-remote
                                              'terminate #t)))
(check "OCI ownership query is one fresh exact-instance read"
       (let ((source oci-common-source))
         (and (string-contains source "(define (oci-instance-ownership")
              (string-contains source "to_string(data.\\\"freeform-tags\\\".\\\"managed-by\\\")")
              (string-contains source "to_string(data.\\\"freeform-tags\\\".\\\"artifact-state\\\")")
              (string-contains source "to_string(data.\\\"freeform-tags\\\".\\\"run-id\\\")"))))
(check "both disposable controllers gate termination on fresh ownership"
       (and (string-contains validate-source "oci-instance-ownership")
            (string-contains validate-source "validation-ownership-authorized?")
            (string-contains probe-source "oci-instance-ownership")
            (string-contains probe-source "validation-ownership-authorized?")))
(check "lifecycle handoff protects locally before OCI mutation"
       (let ((local-write (string-contains lifecycle-source "validation-write-state"))
             (oci-update (string-contains lifecycle-source
                                          "oci-update-instance-tags/status")))
         (and local-write oci-update (< local-write oci-update)
              (string-contains lifecycle-source "local protection remains"))))
(check "lifecycle cleanup and handoff both use the ownership gate"
       (and (string-contains lifecycle-source "'terminate")
            (string-contains lifecycle-source "'handoff")
            (string-contains lifecycle-source "validation-ownership-authorized?")
            (string-contains lifecycle-source "oci-instance-ownership")))
(check "handoff confirmation requires exact OCID, run ID, and HANDED_OFF"
       (and (string-contains lifecycle-source "'instance-ocid")
            (string-contains lifecycle-source "'run-id")
            (string-contains lifecycle-source "\"HANDED_OFF\"")))
(check "lifecycle surface exposes logs, collect, and stop"
       (and (string-contains lifecycle-source "status|logs|collect|stop|cleanup|handoff")
            (string-contains lifecycle-source "(define (show-logs")
            (string-contains lifecycle-source "(define (collect")
            (string-contains lifecycle-source "(define (stop")
            (string-contains lifecycle-source "(string=? command \"logs\")")
            (string-contains lifecycle-source "(string=? command \"collect\")")
            (string-contains lifecycle-source "(string=? command \"stop\")")))
(check "logs is local-only and collect uses the recorded exact OCID"
       (and (string-contains lifecycle-source "events.jsonl")
            (string-contains lifecycle-source "remote-output.log")
            (string-contains lifecycle-source "reconnect.log")
            (string-contains lifecycle-source "(oci-instance-state instance)")
            (string-contains lifecycle-source "oci-capture-console-history instance console")
            (not (string-contains lifecycle-source "oci-instance-public-ip instance"))))
(check "stop shares cleanup's fresh ownership gate and termination path"
       (let ((stop-at (string-contains lifecycle-source "(define (stop run-dir yes?)"))
             (cleanup-at (string-contains lifecycle-source "(define (cleanup run-dir yes?)")))
         (and stop-at cleanup-at
              (string-contains lifecycle-source "(cleanup run-dir yes?)")
              (string-contains lifecycle-source "validation-ownership-authorized?")
              (string-contains lifecycle-source "oci-terminate-instance/status"))))
(check "Make exposes all exact-run lifecycle commands"
       (and (string-contains makefile-source "oracle-run-status oracle-logs oracle-collect oracle-stop")
            (string-contains makefile-source "oracle-logs RUN_DIR")
            (string-contains makefile-source "oracle-collect RUN_DIR")
            (string-contains makefile-source "oracle-stop RUN_DIR")))

;;; ---------------------------------------------------------------------------
;;; Resilient telemetry journal and replay

(define event-1 (validation-event-json 1 "started" "fixture-time" "command"))
(define event-2 (validation-event-json 2 "heartbeat" "fixture-time" "alive"))
(define event-3 (validation-event-json 3 "output" "fixture-time" "a\"b\\c\n"))

(check "telemetry events are single-line escaped JSON with a sequence"
       (and (= (validation-event-sequence event-3) 3)
            (not (string-contains event-3 "a\"b\\c\n"))
            (string-contains event-3 "a\\\"b\\\\c\\n")))
(check "telemetry parser rejects missing, zero, and nonnumeric sequences"
       (and (not (validation-event-sequence "{}"))
            (not (validation-event-sequence "{\"seq\":0,\"kind\":\"x\"}"))
            (not (validation-event-sequence "{\"seq\":x,\"kind\":\"x\"}"))))
(check "result event is the authoritative numeric completion signal"
       (and (= (validation-result-event-status
                (validation-event-json 9 "result" "fixture-time" "7")) 7)
            (= (validation-result-event-status
                (validation-event-json 10 "result" "fixture-time" "0")) 0)
            (not (validation-result-event-status event-2))
            (not (validation-result-event-status
                  (validation-event-json 11 "result" "fixture-time" "999")))))
(check "latest result lookup needs no optional find-map binding"
       (and (= (validation-latest-result-status
                (list event-1 (validation-event-json 4 "result" "fixture" "7"))) 7)
            (not (validation-latest-result-status (list event-1 event-2)))
            (not (string-contains validate-source "find-map"))))

(call-with-values
    (lambda () (validation-replay-events (list event-1 event-2 event-3) 0))
  (lambda (events last error)
    (check "initial telemetry replay is contiguous"
           (and (not error) (= last 3) (equal? events (list event-1 event-2 event-3))))))
(call-with-values
    (lambda () (validation-replay-events (list event-1 event-2 event-3) 2))
  (lambda (events last error)
    (check "reconnect replay ignores an overlapping prefix"
           (and (not error) (= last 3) (equal? events (list event-3))))))
(call-with-values
    (lambda () (validation-replay-events (list event-1 event-3) 0))
  (lambda (events last error)
    (check "telemetry replay fails loudly on an event gap"
           (and (not events) (= last 0) (string-contains error "expected 2")))))
(call-with-values
    (lambda () (validation-replay-events (list event-1 "not-json") 0))
  (lambda (events last error)
    (check "telemetry replay fails loudly on malformed input"
           (and (not events) (= last 0) (string-contains error "malformed")))))

(call-with-values
    (lambda () (validation-process-journal (list event-1 event-2) 0))
  (lambda (unseen new-last result error)
    (check "journal state transition records an incomplete prefix"
           (and (not error) (not result) (= new-last 2)
                (equal? unseen (list event-1 event-2))))))
(call-with-values
    (lambda ()
      (validation-process-journal
       (list event-1 event-2 (validation-event-json 3 "result" "fixture" "0")) 2))
  (lambda (unseen new-last result error)
    (check "journal state transition completes across reconnect overlap"
           (and (not error) (= result 0) (= new-last 3) (= (length unseen) 1)))))

;;; Execute the real controller loop with transport snapshots. This catches
;;; parenthesis/control-flow defects that pure journal helpers cannot see.
(define (read-lines path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((lines '()))
        (let ((line (read-line port)))
          (if (eof-object? line) (reverse lines)
              (loop (cons line lines))))))))

(setenv "ORACLE_VALIDATION_TEST_MODE" "1")
(load validate-script)
(let* ((controller-dir (string-append "/tmp/oracle-validation-controller-test-"
                                     (number->string (getpid))))
       (events-path (string-append controller-dir "/events.jsonl"))
       (log-path (string-append controller-dir "/remote.log"))
       (reconnect-path (string-append controller-dir "/reconnect.log"))
       (result-event (validation-event-json 3 "result" "fixture" "0"))
       (snapshots (list (string-join (list event-1 event-2) "\n")
                        (string-join (list event-1 event-2 result-event) "\n")))
       (reads 0)
       (original-read remote-read)
       (original-sleep sleep)
       (original-evidence poll-run-evidence))
  (system* "mkdir" "-p" controller-dir)
  (for-each (lambda (path) (when (file-exists? path) (delete-file path)))
            (list events-path log-path reconnect-path))
  (set! remote-read
        (lambda (base path)
          (let ((snapshot (list-ref snapshots (min reads 1))))
            (set! reads (+ reads 1))
            (values snapshot 0))))
  (set! sleep (lambda (seconds) #t))
  (set! poll-run-evidence (lambda (instance run-dir) #f))
  (let ((status (replay-until-result "fixture-ssh" "/fixture" "30"
                                     events-path log-path #f reconnect-path
                                     "ocid1.instance.fixture" controller-dir)))
    (set! remote-read original-read)
    (set! sleep original-sleep)
    (set! poll-run-evidence original-evidence)
    (let ((lines (read-lines events-path)))
      (check "actual controller loop stops after overlapped result snapshot"
             (and (= status 0) (= reads 2) (= (length lines) 3)
                  (equal? (map validation-event-sequence lines) '(1 2 3)))))))
(let* ((loss-dir (string-append "/tmp/oracle-validation-loss-test-"
                                (number->string (getpid))))
       (loss-reads 0)
       (original-read remote-read)
       (original-evidence poll-run-evidence))
  (system* "mkdir" "-p" loss-dir)
  (set! remote-read (lambda (base path) (set! loss-reads (+ loss-reads 1))
                      (values (string-join (list event-1 event-2) "\n") 0)))
  (set! poll-run-evidence (lambda (instance run-dir) "TERMINATED"))
  (let ((status (replay-until-result "fixture-ssh" "/fixture" "30"
                                     (string-append loss-dir "/events.jsonl")
                                     (string-append loss-dir "/remote.log")
                                     #f (string-append loss-dir "/reconnect.log")
                                     "ocid1.instance.fixture" loss-dir)))
    (set! remote-read original-read)
    (set! poll-run-evidence original-evidence)
    (check "permanent guest loss is classified before another remote read"
           (and (= status 127) (= loss-reads 0)))))
(let* ((evidence-dir (string-append "/tmp/oracle-validation-evidence-test-"
                                    (number->string (getpid))))
       (console-calls 0)
       (original-state oci-instance-state)
       (original-console oci-capture-console-history))
  (system* "mkdir" "-p" evidence-dir)
  (set! oci-instance-state (lambda (instance) "RUNNING"))
  (set! oci-capture-console-history
        (lambda (instance path)
          (set! console-calls (+ console-calls 1))
          (call-with-output-file path (lambda (port) (display "mock console\n" port)))
          #t))
  (let ((state (poll-run-evidence "ocid1.instance.fixture" evidence-dir)))
    (set! oci-instance-state original-state)
    (set! oci-capture-console-history original-console)
    (check "periodic evidence poll records lifecycle with mocked OCI"
           (and (string=? state "RUNNING")
                (= console-calls 1)
                (file-exists? (string-append evidence-dir "/lifecycle.jsonl")))))
  (set! oci-instance-state (lambda (instance) "TERMINATED"))
  (set! oci-capture-console-history
        (lambda (instance path)
          (set! console-calls (+ console-calls 1))
          (call-with-output-file path (lambda (port) (display "mock console\n" port)))
          #t))
  (poll-run-evidence "ocid1.instance.fixture" evidence-dir)
  (set! oci-instance-state original-state)
  (set! oci-capture-console-history original-console)
  (check "terminal evidence poll refreshes latest console with mocked OCI"
         (and (= console-calls 2)
              (= (length (read-lines
                          (string-append evidence-dir "/lifecycle.jsonl"))) 2)
              (file-exists? (string-append evidence-dir "/console-history.log")))))
(unsetenv "ORACLE_VALIDATION_TEST_MODE")

(let* ((fixture-dir (string-append "/tmp/oracle-validation-guest-test-"
                                  (number->string (getpid))))
       (command (string-append fixture-dir "/command.sh"))
       (journal (string-append fixture-dir "/events.jsonl"))
       (result (string-append fixture-dir "/result")))
  (system* "mkdir" "-p" fixture-dir)
  (call-with-output-file command
    (lambda (port)
      (display "printf 'before quiet\\n'\nsleep 2\nprintf 'after quiet\\n'\nexit 7\n" port)))
  (let ((status
         (status:exit-val
          (system
           (string-append
            "VALIDATION_GUEST_SHELL=/bin/sh VALIDATION_HEARTBEAT_SECONDS=1 guile"
            " --no-auto-compile -s " (validation-sh-quote guest-runner-script)
            " " (validation-sh-quote journal) " " (validation-sh-quote result)
            " " (validation-sh-quote command) " 30")))))
    (let ((lines (read-lines journal)))
      (call-with-values (lambda () (validation-replay-events lines 0))
        (lambda (events new-last error)
          (check "guest runner emits contiguous output, heartbeat, and result events"
                 (and (= status 7) (not error) (= new-last (length lines))
                      (any (lambda (line) (string-contains line "\"kind\":\"heartbeat\"")) events)
                      (string-contains (last events) "\"payload\":\"7\"")))))))
  (check "guest runner persists the same numeric command result"
         (string=? (call-with-input-file result read-line) "7")))
(check "termination explicitly deletes the boot volume"
       (let ((command (oci-terminate-command "ocid1.instance.fixture")))
         (and (string-contains command "--preserve-boot-volume false")
              (string-contains command "--force")
              (string-contains command "ocid1.instance.fixture"))))

;;; ---------------------------------------------------------------------------
;;; Controller source contracts.  These checks remain offline and make it
;;; difficult to accidentally remove the test escape hatch or log streaming.

(check "validate controller has a test-mode dispatch guard"
       (and (string-contains validate-source
                              "(unless (getenv \"ORACLE_VALIDATION_TEST_MODE\")")
            (string-contains validate-source "(main (cdr (command-line)))")))
(check "probe controller has a test-mode dispatch guard"
       (and (string-contains probe-source
                              "(unless (getenv \"ORACLE_VALIDATION_TEST_MODE\")")
            (string-contains probe-source "(main (cdr (command-line)))")))
(check "inspection controller is explicitly non-destructive"
       (and (string-contains inspect-source "repeatable, non-destructive")
            (string-contains inspect-source "compute instance list")
            (string-contains inspect-source "compute instance get")
            (string-contains inspect-source "compute instance list-vnics")
            (not (string-contains inspect-source "instance launch"))
            (not (string-contains inspect-source "instance terminate"))))
(check "inspection controller requires exact instance OCIDs"
       (and (string-contains inspect-source "ocid1.instance.")
            (string-contains inspect-source "invalid instance OCID")))
(check "validate controller uses incremental command-log streaming"
       (and (string-contains validate-source "validation-stream-command/status")
            (string-contains validate-source "remote-output.log")))
(check "OV-5 controller detaches and replays the durable guest journal"
       (and (string-contains validate-source "setsid /run/current-system/profile/bin/guile")
            (string-contains validate-source "replay-until-result")
            (string-contains validate-source "validation-process-journal")
            (string-contains validate-source "events.jsonl")))
(check "OV-5 completion comes from the sequenced result event"
       (and (string-contains validate-source "validation-process-journal")
            (not (string-contains validate-source "remote-read base result"))))
(check "OV-5 evidence gaps return a status so cleanup still runs"
       (and (string-contains validate-source "(begin (say \"[ERROR] \" error) 125)")
            (not (string-contains validate-source "(when error (die error))"))))
(check "OV-5 forced reconnect kills one SSH session after a durable sequence"
       (and (string-contains validate-source "timeout 1 ")
            (string-contains validate-source "'sleep 30'")
            (string-contains validate-source "forced SSH interruption after sequence")
            (string-contains validate-source "reconnect.log")))
(check "guest runner enforces timeout and is the only journal writer"
       (and (string-contains guest-runner-source "timeout \" timeout-text")
            (string-contains guest-runner-source "(define (event kind payload)")
            (string-contains guest-runner-source "(force-output journal)")))
(check "probe controller uses incremental command-log streaming"
       (and (string-contains probe-source "validation-stream-command/status")
            (string-contains probe-source "remote-output.log")))
(check "probe reports manual cleanup only when termination itself fails"
       (and (string-contains probe-source "(if (zero? termination-status)")
            (string-contains probe-source
                             "metadata-only SSH probe failed; instance terminated")
            (string-contains probe-source "probe cleanup failed")))

(newline)
(if (zero? failures)
    (begin
      (format #t "All ~a Oracle validation checks passed!\n" checks)
      (exit 0))
    (begin
      (format #t "~a of ~a Oracle validation checks FAILED\n" failures checks)
      (exit 1)))
