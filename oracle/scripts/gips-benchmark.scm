#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#
;;; gips-benchmark.scm --- paired cold-cache benchmark: central substitutes vs GIPS.
;;;
;;; Protocol and rationale: docs/GIPS_BENCHMARK_PROTOCOL.md.  Guile per the
;;; language policy: every subcommand except `report' and `plan' runs on a Guix
;;; guest.  Output is ASCII only because it is read over an OCI serial console.
;;;
;;;   gips-benchmark.scm plan        --blocks N --seed S
;;;   gips-benchmark.scm hub-prepare --manifest FILE --out-dir DIR
;;;                                  [--publish --gns-name NAME]
;;;   gips-benchmark.scm preflight   --closure FILE [--central-urls U] [--gips-url U]
;;;   gips-benchmark.scm run         --paths FILE --closure FILE --workload NAME
;;;                                  --out FILE --consumer-host NAME
;;;                                  --gns-name NAME --gipsd-database FILE
;;;                                  --blocks N --seed S [--mirror-timeout SEC]
;;;                                  [--min-free-mib N] [--min-rx-bytes N]
;;;                                  [--gipsd-start CMD] [--yes] [...]
;;;                                  [--publish-none-url URL] [--publish-zstd-url URL]
;;;   gips-benchmark.scm report      --in FILE [--seed S]
;;;
;;; `run' is destructive on the machine it runs on: before every trial it
;;; calls `guix gc', clears the narinfo cache, deletes gipsd's database and
;;; removes every IPFS pin.  Run it only on the
;;; disposable consumer, never on the hub (that would delete what it serves).

(define %script-directory
  (dirname (canonicalize-path (or (current-filename) (car (command-line))))))
(load (string-append %script-directory "/gips-benchmark-common.scm"))

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports))

(define %default-central-urls
  "https://ci.guix.gnu.org https://bordeaux.guix.gnu.org")
(define %default-gips-url "http://127.0.0.1:8080")

(define (say . parts)
  (for-each display parts)
  (newline)
  (force-output))

(define (die . parts)
  (apply say "[ERROR] " parts)
  (exit 1))

;;; ---------------------------------------------------------------------------
;;; Options: --key value pairs and bare --flags into an alist.
;;; ---------------------------------------------------------------------------

(define %flags '("--yes" "--publish"))

(define (parse-options arguments)
  (let loop ((rest arguments) (options '()))
    (match rest
      (() options)
      (((? (lambda (argument) (member argument %flags)) flag) . tail)
       (loop tail (acons (string->symbol (substring flag 2)) #t options)))
      (((? (lambda (argument) (string-prefix? "--" argument)) key) value . tail)
       (loop tail (acons (string->symbol (substring key 2)) value options)))
      ((unknown . _) (die "unexpected argument: " unknown)))))

(define (option options key . default)
  (or (assq-ref options key) (and (pair? default) (car default))))

(define (required options key)
  (or (assq-ref options key) (die "--" (symbol->string key) " is required")))

(define (numeric-option options key default)
  (let ((value (string->number (option options key (number->string default)))))
    (or (and value (exact-integer? value) (>= value 0) value)
        (die "--" (symbol->string key) " must be a non-negative integer"))))

(define (split-urls text)
  (filter (lambda (url) (not (string-null? url))) (string-split text #\space)))

;;; ---------------------------------------------------------------------------
;;; Effects
;;; ---------------------------------------------------------------------------

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (read-lines path)
  (filter (lambda (line) (not (string-null? line)))
          (map string-trim-both (string-split (read-file path) #\newline))))

(define (shell-status command)
  (let ((status (system command)))
    (or (status:exit-val status) 255)))

(define (shell-output command)
  "Return two values: the command's stdout and its exit code."
  (let* ((port (open-input-pipe command))
         (text (get-string-all port))
         (status (close-pipe port)))
    (values text (or (status:exit-val status) 255))))

(define (append-line path line)
  "Append LINE and flush, so a guest lost mid-run keeps every finished trial."
  (let ((port (open-file path "a")))
    (display line port)
    (newline port)
    (force-output port)
    (close-port port)))

(define (milliseconds-since start)
  (quotient (* 1000 (- (get-internal-real-time) start))
            internal-time-units-per-second))

(define (utc-now)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (load-average-1)
  (catch #t
    (lambda () (string->number (car (string-split (read-file "/proc/loadavg") #\space))))
    (lambda _ #f)))

(define (network-bytes)
  (catch #t
    (lambda () (parse-proc-net-dev (read-file "/proc/net/dev")))
    (lambda _ (cons #f #f))))

(define (confirm-on-tty question)
  "Ask on /dev/tty, never stdin: this script may be piped into the interpreter."
  (catch #t
    (lambda ()
      (let ((tty (open-file "/dev/tty" "r+")))
        (display question tty)
        (force-output tty)
        (let ((answer (read-line tty)))
          (close-port tty)
          (and (string? answer)
               (member (string-downcase (string-trim-both answer)) '("y" "yes"))))))
    (lambda _ #f)))

;;; ---------------------------------------------------------------------------
;;; plan
;;; ---------------------------------------------------------------------------

(define %arms '("central" "gips"))

(define (command-plan options)
  (say "block\tposition\tarm")
  (for-each (match-lambda
              ((block position arm)
               (say block "\t" position "\t" arm)))
            (benchmark-schedule (arms-in-order
                                 (string-split (option options 'arms "central,gips") #\,))
                                (numeric-option options 'blocks 20)
                                (numeric-option options 'seed 1))))

;;; ---------------------------------------------------------------------------
;;; hub-prepare: fix the workload as literal store paths
;;; ---------------------------------------------------------------------------

;; Written by `hub-prepare', checked by `run'.  Under /var/tmp rather than a
;; home directory so it holds whichever user runs either command, and survives
;; a reboot (a hub stays a hub).  Remove it by hand to repurpose the machine.
(define %hub-marker "/var/tmp/gips-benchmark-hub")

(define (store-paths-from command failure)
  "Run COMMAND and return the /gnu/store items it printed, one per line."
  (call-with-values (lambda () (shell-output command))
    (lambda (text code)
      (unless (zero? code) (die failure " (exit " code ")"))
      (filter store-path-hash
              (map string-trim-both (string-split text #\newline))))))

(define (write-lines path lines)
  (call-with-output-file path
    (lambda (port)
      (for-each (lambda (line) (display line port) (newline port)) lines))))

(define (publish-failures closure gns-name)
  "Publish every item of CLOSURE to the local gipsd under GNS-NAME, the feed a
consumer subscribes to; return the failure count."
  (count (lambda (path)
           (not (zero? (shell-status (string-append "gips publish "
                                                    (benchmark-sh-quote path)
                                                    " --gns-name "
                                                    (benchmark-sh-quote gns-name)
                                                    " >/dev/null")))))
         closure))

(define (command-hub-prepare options)
  "Realize the manifest once, on the hub, and freeze the workload as literal
store paths.  Both arms then fetch exactly these items, so the comparison does
not depend on the consumer's channel state and no trial evaluates a package."
  (let* ((manifest (required options 'manifest))
         (out-dir (required options 'out-dir))
         (_ (shell-status (string-append "mkdir -p " (benchmark-sh-quote out-dir))))
         (__ (say "[INFO] Realizing " manifest " on the hub (substitutes allowed)"))
         (paths (store-paths-from
                 (string-append "guix build -m " (benchmark-sh-quote manifest))
                 "guix build -m failed"))
         (closure (if (null? paths)
                      '()
                      (store-paths-from
                       (string-append "guix gc --requisites "
                                      (string-join (map benchmark-sh-quote paths) " "))
                       "guix gc --requisites failed"))))
    (when (null? paths) (die "guix build printed no store paths"))
    (write-lines %hub-marker (list (utc-now) manifest))
    (write-lines (string-append out-dir "/workload.paths") paths)
    (write-lines (string-append out-dir "/workload.closure") closure)
    (say "[OK] " (length paths) " output(s), " (length closure)
         " closure item(s) -> " out-dir)
    (when (option options 'publish)
      (let ((failures (publish-failures closure (required options 'gns-name))))
        (if (zero? failures)
            (say "[OK] published " (length closure) " item(s) to GIPS")
            (die failures " of " (length closure) " item(s) failed to publish"))))))

;;; ---------------------------------------------------------------------------
;;; preflight: both arms must be ABLE to serve the whole closure
;;; ---------------------------------------------------------------------------

(define (narinfo-available? urls store-path)
  (any (lambda (url)
         (zero? (shell-status
                 (string-append "curl --silent --fail --max-time 20 --output /dev/null "
                                (benchmark-sh-quote (narinfo-url url store-path))))))
       urls))

(define (command-preflight options)
  "A trial that fails because an arm never had the item measures nothing.  This
is a gate, so it reports what it inspected and fails when it could inspect
nothing."
  (let* ((closure (read-lines (required options 'closure)))
         (arms `(("central" . ,(split-urls (option options 'central-urls
                                                   %default-central-urls)))
                 ("gips" . ,(split-urls (option options 'gips-url %default-gips-url))))))
    (when (null? closure) (die "closure file is empty; nothing was checked"))
    (let ((missing-total
           (fold (lambda (arm total)
                   (let ((missing (remove (lambda (path)
                                            (narinfo-available? (cdr arm) path))
                                          closure)))
                     (say (if (null? missing) "[OK]   " "[FAIL] ") (car arm) ": "
                          (- (length closure) (length missing)) "/" (length closure)
                          " narinfos available")
                     (for-each (lambda (path) (say "         missing: " path))
                               (take missing (min 10 (length missing))))
                     (+ total (length missing))))
                 0 arms)))
      (unless (zero? missing-total)
        (die "preflight failed; do not start trials"))
      (say "[OK] preflight passed for " (length closure) " closure item(s)"))))

;;; ---------------------------------------------------------------------------
;;; run
;;; ---------------------------------------------------------------------------

(define (reset-to-cold settings)
  "Run the reset.  A failed step is a broken environment, not a result: stop
before writing a row, so the trial is retried on resume instead of being
recorded as a half-cold measurement."
  (for-each (lambda (command)
              (let ((code (shell-status command)))
                (unless (zero? code)
                  (die "reset step exited " code " (no row recorded): " command))))
            (benchmark-reset-commands (assq-ref settings 'sudo) (assq-ref settings 'ipfs)
                                      (assq-ref settings 'gipsd-database)
                                      (assq-ref settings 'gipsd-start)))
  (let wait ((remaining 60))
    (cond ((zero? (shell-status (string-append "curl --silent --fail --max-time 2 --output /dev/null "
                                               (benchmark-sh-quote
                                                (string-append (assq-ref settings 'gips-url)
                                                               "/status")))))
           #t)
          ((zero? remaining) (die "gipsd did not answer /status within 60 s of restart (no row recorded)"))
          (else (sleep 1) (wait (- remaining 1)))))
  (let ((available (call-with-values
                       (lambda () (shell-output "df -Pk /gnu/store 2>/dev/null"))
                     (lambda (text code) (and (zero? code) (parse-df-available-kib text)))))
        (min-free-mib (assq-ref settings 'min-free-mib)))
    (unless (and available (>= available (* 1024 min-free-mib)))
      (die "free space on /gnu/store is " (or available "unreadable") " KiB; need "
           min-free-mib " MiB (--min-free-mib) (no row recorded)"))))

(define (wait-until-mirrored needed settings start)
  "Subscribe, then poll gipsd until every item of NEEDED has a narinfo.
Returns (VERDICT FIRST-AVAILABLE-MS AVAILABLE-MS).  FIRST-AVAILABLE-MS
approximates the mirror worker's tick wait (up to 60 s of pure idling) plus the
first item's transfer; it is recorded so that wait can be reported, not so it
can be subtracted."
  (let ((gips-url (assq-ref settings 'gips-url))
        (timeout-ms (* 1000 (assq-ref settings 'mirror-timeout))))
    (unless (zero? (shell-status (string-append "gips subscribe "
                                                (benchmark-sh-quote (assq-ref settings 'gns-name))
                                                " >/dev/null 2>&1")))
      (die "`gips subscribe' failed (no row recorded)"))
    (let loop ((pending needed) (first-ms #f))
      (let* ((still-pending (remove (lambda (path) (narinfo-available? (list gips-url) path))
                                    pending))
             (elapsed (milliseconds-since start))
             (first-ms (or first-ms
                           (and (< (length still-pending) (length needed)) elapsed))))
        (case (availability-verdict (length needed)
                                    (- (length needed) (length still-pending))
                                    elapsed timeout-ms)
          ((ready) (list 'ready first-ms elapsed))
          ((timeout) (list 'timeout first-ms #f))
          (else (sleep 1) (loop still-pending first-ms)))))))

(define (run-trial run-id workload store-paths closure arm-urls arm block position
                   settings log-directory)
  "Reset to cold and time one arm.  central: a cold `guix build' from the
central servers.  gips: time-to-available -- from `gips subscribe' until the
mirror holds every item guix would fetch, plus the install from the local
gipsd.  wall_ms is the whole of it in both arms."
  (reset-to-cold settings)
  (let ((base `((schema . ,gips-benchmark-schema) (run_id . ,run-id) (workload . ,workload)
                (block . ,block) (position . ,position) (arm . ,arm)
                (started_utc . ,(utc-now))))
        (needed (items-to-fetch closure file-exists?)))
    (if (any file-exists? store-paths)
        ;; Live paths survive `guix gc'.  Timing them would time nothing.
        (append base '((status . "not-cold") (exit_code . -1)))
        (let* ((log-file (format #f "~a/~a-b~2,'0d-~a.log" log-directory workload block arm))
               (load-before (load-average-1))
               (bytes-before (network-bytes))
               (start (get-internal-real-time))
               (mirror (if (string=? arm "gips")
                           (wait-until-mirrored needed settings start)
                           (list 'ready #f #f))))
          (if (eq? (first mirror) 'timeout)
              (append base `((status . "mirror-timeout") (exit_code . -1)
                             (first_available_ms . ,(second mirror))
                             (wall_ms . ,(milliseconds-since start)) (load1 . ,load-before)))
              (let* ((install-start (get-internal-real-time))
                     (exit-code (shell-status
                                 (benchmark-build-command store-paths arm-urls log-file)))
                     (install-ms (milliseconds-since install-start))
                     (wall-ms (milliseconds-since start))
                     (bytes-after (network-bytes))
                     (downloads (classify-downloads (download-sources (read-file log-file))
                                                    arm-urls))
                     (delta (lambda (select)
                              (and (select bytes-before) (select bytes-after)
                                   (- (select bytes-after) (select bytes-before))))))
                (append base
                        `((status . ,(trial-verdict exit-code downloads #:rx-bytes (delta car)
                                                    #:min-rx-bytes
                                                    (assq-ref settings 'min-rx-bytes)))
                          (exit_code . ,exit-code) (wall_ms . ,wall-ms)
                          (first_available_ms . ,(second mirror))
                          (available_ms . ,(third mirror)) (install_ms . ,install-ms)
                          (rx_bytes . ,(delta car)) (tx_bytes . ,(delta cdr))
                          (downloads_total . ,(first downloads))
                          (downloads_from_arm . ,(second downloads))
                          (downloads_other . ,(third downloads))
                          (load1 . ,load-before)))))))))

(define (command-run options)
  (let* ((store-paths (read-lines (required options 'paths)))
         (workload (required options 'workload))
         (out (required options 'out))
         (blocks (numeric-option options 'blocks 20))
         (seed (numeric-option options 'seed 1))
         (closure (read-lines (required options 'closure)))
         (settings
          `((sudo . ,(option options 'sudo "sudo -n"))
            (ipfs . ,(option options 'ipfs "ipfs"))
            (gns-name . ,(required options 'gns-name))
            (gips-url . ,(option options 'gips-url %default-gips-url))
            (gipsd-database . ,(required options 'gipsd-database))
            ;; Same command line `make gips-start' uses.
            (gipsd-start . ,(option options 'gipsd-start
                                    "nohup gipsd --config \"${XDG_CONFIG_HOME:-$HOME/.config}/gips/gipsd.toml\" >>\"${XDG_CONFIG_HOME:-$HOME/.config}/gips/gipsd.log\" 2>&1 &"))
            (mirror-timeout . ,(numeric-option options 'mirror-timeout 3600))
            (min-free-mib . ,(numeric-option options 'min-free-mib 3072))
            (min-rx-bytes . ,(numeric-option options 'min-rx-bytes 0))))
         (control-urls (filter cdr
                               `(("publish-none" . ,(option options 'publish-none-url))
                                 ("publish-zstd" . ,(option options 'publish-zstd-url)))))
         (arms (arms-in-order (append %arms (map car control-urls))))
         (schedule (benchmark-schedule arms blocks seed))
         (refusal (run-refusal-reason (gethostname) (option options 'consumer-host)
                                      (file-exists? %hub-marker)))
         (arm-urls `(("central" . ,(split-urls (option options 'central-urls
                                                       %default-central-urls)))
                     ;; GIPS alone, with no central fallback: otherwise a GIPS
                     ;; miss is quietly served by ci.guix.gnu.org and credited
                     ;; to GIPS.
                     ("gips" . ,(split-urls (option options 'gips-url %default-gips-url)))
                     ,@(map (lambda (control) (cons (car control) (split-urls (cdr control))))
                            control-urls)))
         (log-directory (string-append out ".logs"))
         (run-id (option options 'run-id (strftime "%Y%m%dT%H%M%SZ" (gmtime (current-time))))))
    (when (null? store-paths) (die "no store paths in " (required options 'paths)))
    (unless (every store-path-hash store-paths)
      (die "--paths must contain only /gnu/store items"))
    ;; Checked before --yes is honoured: --yes skips the question, never the guard.
    (when refusal (die "refusing to run: " refusal))
    (unless (or (option options 'yes)
                (confirm-on-tty (run-confirmation-text (gethostname) (length schedule))))
      (die "not confirmed; pass --yes for unattended use"))
    (shell-status (string-append "mkdir -p " (benchmark-sh-quote log-directory)))
    (unless (file-exists? out)
      (append-line out (benchmark-header-line)))
    (say "[INFO] run " run-id ": workload " workload ", " blocks " block(s), seed " seed
         ", arms " (string-join arms ","))
    (for-each
     (match-lambda
       ((block position arm)
        (if (completed-trial? (parse-benchmark-rows (read-file out)) workload block arm)
            (say "[SKIP] block " block " " arm " already recorded")
            (let ((row (run-trial run-id workload store-paths closure
                                  (assoc-ref arm-urls arm) arm block position
                                  settings log-directory)))
              (append-line out (benchmark-row-line row))
              (say "[" (if (equal? (assq-ref row 'status) "ok") "OK" "WARN") "] block "
                   block " " arm ": " (assq-ref row 'status) " "
                   (or (assq-ref row 'wall_ms) "-") " ms")))))
     schedule)
    (say "[OK] schedule complete; results in " out)))

;;; ---------------------------------------------------------------------------
;;; report
;;; ---------------------------------------------------------------------------

(define (show-number value)
  (cond ((not value) "-")
        ((exact-integer? value) (number->string value))
        (else (format #f "~,1f" value))))

(define (say-comparison rows workload role baseline treatment seed)
  (let ((comparison (paired-comparison rows workload baseline treatment seed)))
    (say "")
    (say "  [" role "] " baseline " vs " treatment)
    (if (not comparison)
        (say "    insufficient-data (need >= 2 complete blocks)")
        (let ((difference (assq-ref comparison 'difference_ci95_ms))
              (ratio (assq-ref comparison 'speedup_ci95)))
          (say "    complete pairs:    " (assq-ref comparison 'pairs)
               " (" treatment " faster in " (assq-ref comparison 'treatment_faster_in) ")")
          (say (format #f "    ~a - ~a: mean ~,1f ms, 95% CI [~,1f, ~,1f]"
                       baseline treatment (assq-ref comparison 'mean_difference_ms)
                       (car difference) (cdr difference)))
          (say (format #f "    speedup (geomean): ~,3fx, 95% CI [~,3f, ~,3f]"
                       (assq-ref comparison 'speedup) (car ratio) (cdr ratio)))
          (say (format #f "    sign-flip p-value: ~,4f" (assq-ref comparison 'p_value)))))
    (say "    " (if (eq? role 'primary) "VERDICT:           " "direction:         ")
         (comparison-verdict comparison))))

(define (command-report options)
  (let* ((rows (parse-benchmark-rows (read-file (required options 'in))))
         (seed (numeric-option options 'seed 1))
         (workloads (delete-duplicates (map (lambda (row) (assq-ref row 'workload)) rows))))
    (when (null? rows) (die "no " gips-benchmark-schema " rows found; nothing to report"))
    (say "GIPS substitute benchmark -- " (length rows) " trial row(s), analysis seed " seed)
    (for-each
     (lambda (workload)
       (let ((arms (arms-in-order
                    (map (lambda (row) (assq-ref row 'arm))
                         (filter (lambda (row) (equal? (assq-ref row 'workload) workload))
                                 rows)))))
         (say "")
         (say "Workload: " workload)
         (say (format #f "  ~13a ~9a ~4a ~10a ~10a ~9a ~12a"
                      "arm" "attempted" "ok" "median_ms" "mean_ms" "sd_ms" "median_rx_MB"))
         (for-each
          (lambda (arm)
            (let ((summary (arm-summary rows workload arm)))
              (say (format #f "  ~13a ~9a ~4a ~10a ~10a ~9a ~12a"
                           arm (assq-ref summary 'attempted) (assq-ref summary 'ok)
                           (show-number (assq-ref summary 'median_ms))
                           (show-number (assq-ref summary 'mean_ms))
                           (show-number (assq-ref summary 'sd_ms))
                           (show-number (and (assq-ref summary 'median_rx_bytes)
                                             (/ (assq-ref summary 'median_rx_bytes) 1e6)))))))
          arms)
         (let ((summary (arm-summary rows workload "gips")))
           (say "  gips wall_ms = mirror wait + install; medians: first item visible "
                (show-number (assq-ref summary 'median_first_available_ms))
                " ms, all items mirrored "
                (show-number (assq-ref summary 'median_available_ms))
                " ms, install " (show-number (assq-ref summary 'median_install_ms)) " ms"))
         (for-each (match-lambda
                     ((role baseline treatment)
                      (say-comparison rows workload role baseline treatment seed)))
                   (planned-comparisons arms))))
     workloads)))

;;; ---------------------------------------------------------------------------

(define (main arguments)
  (match arguments
    ((_ "plan" . rest) (command-plan (parse-options rest)))
    ((_ "hub-prepare" . rest) (command-hub-prepare (parse-options rest)))
    ((_ "preflight" . rest) (command-preflight (parse-options rest)))
    ((_ "run" . rest) (command-run (parse-options rest)))
    ((_ "report" . rest) (command-report (parse-options rest)))
    (_ (die "usage: gips-benchmark.scm plan|hub-prepare|preflight|run|report [options]"))))

(main (command-line))
