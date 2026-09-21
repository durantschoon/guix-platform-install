#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-gips-benchmark.scm --- offline tests for the GIPS substitute benchmark.
;;;
;;; Guile per language policy.  Covers the pure half of the benchmark
;;; (oracle/scripts/gips-benchmark-common.scm): schedule, command
;;; construction, provenance verdicts, row round-trip and statistics.  Needs no
;;; guix, no network and no cloud, so it runs on the macOS controller.
;;;
;;; Several checks exist to prove a gate can go RED: a benchmark whose analysis
;;; reports "faster" on any input would be the eighth check in this repository
;;; to pass by not looking (see AGENTS.md).

(use-modules (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

(define (absolute path)
  (if (string-prefix? "/" path) path (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(primitive-load (string-append repository-root
                               "/oracle/scripts/gips-benchmark-common.scm"))

(define *failures* 0)
(define *checks* 0)

(define* (check label condition #:optional (reason ""))
  (set! *checks* (+ *checks* 1))
  (if condition
      (format #t "  \x1b[0;32m[OK]\x1b[0m   ~a\n" label)
      (begin
        (set! *failures* (+ *failures* 1))
        (format (current-error-port) "  \x1b[0;31m[FAIL]\x1b[0m ~a\n         ~a\n"
                label reason))))

(define (section title)
  (format #t "\n\x1b[1;34m~a\x1b[0m\n" title))

(format #t "Testing GIPS substitute benchmark (oracle/scripts/gips-benchmark-common.scm)\n")

;;; ---------------------------------------------------------------------------
(section "1. Randomized block schedule")

(let* ((arms '("central" "gips"))
       (schedule (benchmark-schedule arms 40 7))
       (blocks (map (lambda (block)
                      (filter (lambda (entry) (= (first entry) block)) schedule))
                    (iota 40 1)))
       (gips-first (count (lambda (block) (equal? (third (first block)) "gips")) blocks)))
  (check "schedule has blocks x arms entries" (= (length schedule) 80))
  (check "every block runs every arm exactly once"
         (every (lambda (block)
                  (equal? (sort (map third block) string<?) arms))
                blocks))
  (check "positions within a block are 1..n in order"
         (every (lambda (block) (equal? (map second block) '(1 2))) blocks))
  (check "same seed reproduces the schedule"
         (equal? schedule (benchmark-schedule arms 40 7)))
  (check "different seed changes the schedule"
         (not (equal? schedule (benchmark-schedule arms 40 8))))
  (check "order is actually randomized (neither arm always first)"
         (< 8 gips-first 32)
         (format #f "gips ran first in ~a of 40 blocks" gips-first)))

;;; ---------------------------------------------------------------------------
(section "2. Store paths and commands")

(define hello "/gnu/store/abcdefghijklmnopqrstuvwxyz012345-hello-2.12.1")

(check "hash part extracted" (equal? (store-path-hash hello)
                                     "abcdefghijklmnopqrstuvwxyz012345"))
(check "non-store path rejected" (not (store-path-hash "/tmp/hello")))
(check "nested path rejected" (not (store-path-hash (string-append hello "/bin/hello"))))
(check "short name rejected" (not (store-path-hash "/gnu/store/short-x")))
(check "narinfo URL tolerates trailing slash"
       (equal? (narinfo-url "http://127.0.0.1:8080/" hello)
               "http://127.0.0.1:8080/abcdefghijklmnopqrstuvwxyz012345.narinfo"))

(let ((command (benchmark-build-command (list hello)
                                        '("https://a.example" "https://b.example")
                                        "/tmp/it's.log")))
  (check "build command passes the literal store path"
         (string-contains command (string-append "'" hello "'")))
  (check "build command quotes the URL list as one argument"
         (string-contains command "--substitute-urls='https://a.example https://b.example'"))
  (check "build command never enables --fallback"
         (not (string-contains command "--fallback")))
  (check "single quote in log path is escaped"
         (string-contains command "'/tmp/it'\\''s.log'")))

(let* ((reset (benchmark-reset-commands "sudo -n" "ipfs" "/home/g/.config/gips/gipsd.sqlite"
                                        "start-gipsd &"))
       (index (lambda (needle)
                (list-index (lambda (c) (string-contains c needle)) reset))))
  (check "reset collects garbage" (index "guix gc"))
  (check "reset clears the narinfo cache" (index "/var/guix/substitute/cache"))
  (check "reset deletes the gipsd database and its WAL"
         (and (index "gipsd.sqlite'") (index "gipsd.sqlite-wal'")))
  (check "gipsd is stopped before its database is deleted"
         (< (index "pkill -x gipsd") (index "rm -f '/home/g")))
  (check "pins are removed BEFORE repo gc (gc keeps pinned blocks)"
         (< (index "pin rm") (index "repo gc")))
  (check "gipsd is restarted after the wipe"
         (< (index "repo gc") (index "start-gipsd")))
  (check "empty sudo prefix yields bare commands"
         (not (any (lambda (c) (string-prefix? " " c))
                   (benchmark-reset-commands "" "ipfs" "/x.sqlite" "start")))))

(check "items-to-fetch drops what the consumer already holds"
       (equal? (items-to-fetch '("a" "glibc" "b") (lambda (item) (string=? item "glibc")))
               '("a" "b")))
(check "availability: all present is ready" (eq? 'ready (availability-verdict 5 5 10 1000)))
(check "availability: nothing needed is ready at once"
       (eq? 'ready (availability-verdict 0 0 0 1000)))
(check "availability: partial before the deadline waits"
       (eq? 'wait (availability-verdict 5 4 999 1000)))
(check "availability: partial at the deadline times out"
       (eq? 'timeout (availability-verdict 5 4 1000 1000)))

;;; ---------------------------------------------------------------------------
(section "2b. Guards for run")

(check "matching hostname, no marker: may run"
       (not (run-refusal-reason "consumer-1" "consumer-1" #f)))
(check "hub marker refuses even with matching hostname"
       (string? (run-refusal-reason "hub-1" "hub-1" #t)))
(check "missing --consumer-host refuses"
       (string? (run-refusal-reason "consumer-1" #f #f)))
(check "wrong machine refuses and names both hosts"
       (let ((reason (run-refusal-reason "laptop" "consumer-1" #f)))
         (and (string? reason) (string-contains reason "laptop")
              (string-contains reason "consumer-1"))))
(let ((text (run-confirmation-text "consumer-1" 40)))
  (check "prompt names every reset action, the host and the count"
         (every (lambda (needle) (string-contains text needle))
                '("guix gc" "/var/guix/substitute/cache" "DELETE its database"
                  "REMOVE EVERY PIN" "page cache" "consumer-1" "40 trials"))))
(check "df available column parsed"
       (= 5242880 (parse-df-available-kib
                   (string-append "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
                                  "/dev/sda2 47000000 41000000 5242880 89% /\n"))))
(check "unreadable df is #f, not a number"
       (not (parse-df-available-kib "df: /gnu/store: No such file or directory\n")))

;;; ---------------------------------------------------------------------------
(section "3. Observations and provenance verdicts")

(let ((totals (parse-proc-net-dev
               (string-append
                "Inter-|   Receive                |  Transmit\n"
                " face |bytes packets errs drop fifo frame compressed multicast|bytes packets\n"
                "    lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0\n"
                "  ens3: 1000 5 0 0 0 0 0 0 200 3 0 0 0 0 0 0\n"
                "  ens4:  500 5 0 0 0 0 0 0  50 3 0 0 0 0 0 0\n"))))
  (check "rx sums non-loopback interfaces" (= (car totals) 1500))
  (check "tx sums non-loopback interfaces" (= (cdr totals) 250)))

(let* ((log (string-append
             "substitute: updating substitutes from 'http://127.0.0.1:8080'...\n"
             "downloading from http://127.0.0.1:8080/nar/abc-hello-2.12.1 ...\n"
             " hello-2.12.1  52KiB  1.2MiB/s 00:00\n"
             "downloading from https://ci.guix.gnu.org/nar/lzip/def-glibc ...\n"))
       (sources (download-sources log)))
  (check "download sources parsed" (= (length sources) 2))
  (check "downloads classified against the arm's URLs"
         (equal? (classify-downloads sources '("http://127.0.0.1:8080/")) '(2 1 1))))

(check "clean trial is ok" (equal? (trial-verdict 0 '(5 5 0)) "ok"))
(check "nonzero exit is failed" (equal? (trial-verdict 1 '(5 5 0)) "failed"))
(check "download from another source is contaminated"
       (equal? (trial-verdict 0 '(5 4 1)) "contaminated"))
(check "zero parsed downloads is NOT ok (cannot attribute the time)"
       (equal? (trial-verdict 0 '(0 0 0)) "unattributed"))
(check "fetch that moved almost no network bytes is not-cold (pinned-mirror case)"
       (equal? (trial-verdict 0 '(5 5 0) #:rx-bytes 4096 #:min-rx-bytes 50000000)
               "not-cold"))
(check "fetch above the rx floor is ok"
       (equal? (trial-verdict 0 '(5 5 0) #:rx-bytes 60000000 #:min-rx-bytes 50000000)
               "ok"))
(check "unreadable rx counter with a floor set is not-cold, never ok"
       (equal? (trial-verdict 0 '(5 5 0) #:rx-bytes #f #:min-rx-bytes 50000000)
               "not-cold"))

;;; ---------------------------------------------------------------------------
(section "4. Result rows")

(define (make-row workload block arm status wall-ms)
  `((schema . ,gips-benchmark-schema) (run_id . "r1") (workload . ,workload)
    (block . ,block) (position . 1) (arm . ,arm) (status . ,status)
    (exit_code . 0) (wall_ms . ,wall-ms) (first_available_ms . 61000)
    (available_ms . 90000) (install_ms . 4000) (rx_bytes . 1000000) (tx_bytes . 10)
    (downloads_total . 3) (downloads_from_arm . 3) (downloads_other . 0)
    (load1 . 0.25) (started_utc . "2026-09-20T00:00:00Z")))

(let* ((row (make-row "small" 3 "gips" "ok" 4321))
       (text (string-append (benchmark-header-line) "\n"
                            (benchmark-row-line row) "\n"
                            "some-other-schema\tx\n\n"))
       (parsed (parse-benchmark-rows text)))
  (check "header and foreign lines are skipped" (= (length parsed) 1))
  (check "row round-trips" (equal? (car parsed) row)
         (format #f "~s" (car parsed)))
  (check "completed trial detected" (completed-trial? parsed "small" 3 "gips"))
  (check "other arm of the block is not completed"
         (not (completed-trial? parsed "small" 3 "central")))
  (check "tab inside a value cannot add a column"
         (= (length (string-split
                     (benchmark-row-line (make-row "sm\tall" 1 "gips" "ok" 1)) #\tab))
            (length benchmark-row-fields))))

(let ((damaged (parse-benchmark-rows
                (benchmark-row-line (make-row "small" 1 "gips" "ok" "garbage")))))
  (check "unparsable wall_ms stays #f, never 0"
         (not (assq-ref (car damaged) 'wall_ms)))
  (check "row with unparsable time is excluded from statistics"
         (= 0 (assq-ref (arm-summary damaged "small" "gips") 'ok))))

;;; ---------------------------------------------------------------------------
(section "5. Statistics")

(define (close? a b) (< (abs (- a b)) 1e-9))

(check "mean" (close? (mean '(1 2 3 4)) 5/2))
(check "median, odd" (= (median '(5 1 3)) 3))
(check "median, even" (= (median '(4 1 3 2)) 5/2))
(check "sample sd" (close? (sample-standard-deviation '(2 4 4 4 5 5 7 9))
                           (sqrt 32/7)))
(check "sd of one value is 0" (= (sample-standard-deviation '(3)) 0))

;; Exact permutation p-values, checked by hand.  With every difference
;; positive, only the all-plus and all-minus assignments reach |sum|, so
;; p = 2 / 2^n.
(check "sign-flip p for 5 same-sign differences is 2/32"
       (= (sign-flip-p-value '(1 2 3 4 5) 1) 2/32))
(check "sign-flip p for symmetric differences is 1"
       (= (sign-flip-p-value '(1 -1 2 -2) 1) 1))
(let ((monte-carlo (sign-flip-p-value (iota 20 1) 1 #:exact-limit 4
                                      #:monte-carlo-draws 20000)))
  (check "Monte Carlo branch agrees with the exact answer in order of magnitude"
         (< monte-carlo 0.001)
         (format #f "p = ~a" (exact->inexact monte-carlo))))

(let ((interval (bootstrap-interval '(10 11 9 10 12 8 10 11 9 10) mean 42
                                    #:resamples 2000)))
  (check "bootstrap interval brackets the sample mean"
         (and (< (car interval) 10) (> (cdr interval) 10)))
  (check "bootstrap is deterministic given the seed"
         (equal? interval (bootstrap-interval '(10 11 9 10 12 8 10 11 9 10) mean 42
                                              #:resamples 2000))))

;;; ---------------------------------------------------------------------------
(section "6. Paired comparison and the decision rule")

(define (synthetic-rows central-times gips-times)
  (append-map (lambda (block central gips)
                (list (make-row "w" block "central" "ok" central)
                      (make-row "w" block "gips" "ok" gips)))
              (iota (length central-times) 1) central-times gips-times))

(let* ((central '(10000 12000 9000 11000 10500 9800 12500 10200))
       (rows (synthetic-rows central (map (lambda (t) (quotient t 2)) central)))
       (comparison (paired-comparison rows "w" "central" "gips" 1 #:resamples 2000)))
  (check "2x treatment yields speedup 2.0"
         (close? (assq-ref comparison 'speedup) 2.0))
  (check "positive difference means gips was faster"
         (> (assq-ref comparison 'mean_difference_ms) 0))
  (check "verdict: faster" (equal? (comparison-verdict comparison) "faster")))

(let* ((central '(10000 12000 9000 11000 10500 9800 12500 10200))
       (rows (synthetic-rows central (map (lambda (t) (* t 2)) central)))
       (comparison (paired-comparison rows "w" "central" "gips" 1 #:resamples 2000)))
  (check "the rule can go RED: 2x slower yields verdict slower"
         (equal? (comparison-verdict comparison) "slower")))

(let* ((rows (synthetic-rows '(10000 10400 9700 10100 9900 10300 9800 10200)
                             '(10200 10000 9900 9800 10300 9900 10100 10000)))
       (comparison (paired-comparison rows "w" "central" "gips" 1 #:resamples 2000)))
  (check "noise alone yields no-detectable-difference"
         (equal? (comparison-verdict comparison) "no-detectable-difference")
         (format #f "~s" comparison)))

(let* ((rows (append (synthetic-rows '(10000 10000 10000) '(5000 5000 5000))
                     ;; Block 4: the gips half was served by ci -> contaminated.
                     (list (make-row "w" 4 "central" "ok" 10000)
                           (make-row "w" 4 "gips" "contaminated" 100))))
       (pairs (paired-blocks rows "w" "central" "gips")))
  (check "a block with a contaminated arm is dropped whole"
         (equal? (map first pairs) '(1 2 3)))
  (check "attempted still counts the contaminated row"
         (= 4 (assq-ref (arm-summary rows "w" "gips") 'attempted)))
  (check "ok excludes it" (= 3 (assq-ref (arm-summary rows "w" "gips") 'ok)))
  (check "sub-phase medians are reported"
         (= 90000.0 (assq-ref (arm-summary rows "w" "gips") 'median_available_ms))))

(check "arms are put in canonical order, unknown ones kept last"
       (equal? (arms-in-order '("publish-zstd" "weird" "gips" "central"))
               '("central" "gips" "publish-zstd" "weird")))
(check "two arms plan exactly the primary comparison"
       (equal? (planned-comparisons '("central" "gips")) '((primary "central" "gips"))))
(let ((plan (planned-comparisons benchmark-arm-order)))
  (check "four arms plan one primary and three explanatory comparisons"
         (and (= 4 (length plan))
              (= 1 (count (lambda (entry) (eq? (first entry) 'primary)) plan))))
  (check "the compression control compares publish-zstd against publish-none"
         (member '(explanatory "publish-zstd" "publish-none") plan)))
(check "a comparison whose arm was not run is not planned"
       (not (member '(explanatory "publish-none" "gips")
                    (planned-comparisons '("central" "gips" "publish-zstd")))))

(check "fewer than two pairs is insufficient-data"
       (equal? (comparison-verdict
                (paired-comparison (synthetic-rows '(100) '(50)) "w" "central" "gips" 1))
               "insufficient-data"))

;;; ---------------------------------------------------------------------------

(format #t "\n~a checks, ~a failure(s)\n" *checks* *failures*)
(exit (if (zero? *failures*) 0 1))
