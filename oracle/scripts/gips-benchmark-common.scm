;;; gips-benchmark-common.scm --- pure helpers for the GIPS substitute benchmark.
;;;
;;; Loaded by gips-benchmark.scm and by oracle/tests/test-gips-benchmark.scm,
;;; never as a module (same convention as gips-validation-workload.scm).
;;;
;;; Everything here is a pure function of its arguments: no clock, no network,
;;; no filesystem.  That is what lets the schedule, the row format, the
;;; provenance check and the statistics be tested on a machine without Guix.
;;; The protocol these functions implement is docs/GIPS_BENCHMARK_PROTOCOL.md;
;;; if the two disagree, the protocol is the specification.

(use-modules (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

(define gips-benchmark-schema "gips-benchmark-trial-v1")

;;; ---------------------------------------------------------------------------
;;; Deterministic pseudo-random numbers
;;;
;;; The schedule and the bootstrap must be reproducible from a recorded seed on
;;; any Guile version, so we do not use Guile's `random' (its generator is an
;;; implementation detail).  This is Knuth's MMIX 64-bit LCG; the state is
;;; threaded explicitly instead of being mutated.
;;; ---------------------------------------------------------------------------

(define %lcg-modulus (expt 2 64))

(define (lcg-next state)
  "Return the successor of STATE."
  (modulo (+ (* state 6364136223846793005) 1442695040888963407) %lcg-modulus))

(define (lcg-below state bound)
  "Return two values: an integer in [0, BOUND) and the next state.  The high
bits are used because the low bits of an LCG have short periods."
  (let ((next (lcg-next state)))
    (values (modulo (ash next -33) bound) next)))

(define (shuffle-with-state items state)
  "Fisher-Yates shuffle of the list ITEMS.  Returns two values: the shuffled
list and the advanced state."
  (let ((cells (list->vector items)))
    (let loop ((index (- (vector-length cells) 1)) (state state))
      (if (< index 1)
          (values (vector->list cells) state)
          (call-with-values (lambda () (lcg-below state (+ index 1)))
            (lambda (pick next-state)
              (let ((held (vector-ref cells index)))
                (vector-set! cells index (vector-ref cells pick))
                (vector-set! cells pick held))
              (loop (- index 1) next-state)))))))

;;; ---------------------------------------------------------------------------
;;; Schedule: randomized complete blocks
;;;
;;; Each block runs every arm exactly once, in an order drawn from the seed.
;;; Blocking is what makes the comparison paired: network weather that drifts
;;; over an hour hits both arms of a block about equally, and cancels in the
;;; within-block difference.  Running all of one arm and then all of the other
;;; would let time-of-day masquerade as a GIPS effect.
;;; ---------------------------------------------------------------------------

(define (benchmark-schedule arms block-count seed)
  "Return a list of (BLOCK POSITION ARM) entries, blocks numbered from 1."
  (let loop ((block 1) (state seed) (entries '()))
    (if (> block block-count)
        (reverse entries)
        (call-with-values (lambda () (shuffle-with-state arms state))
          (lambda (order next-state)
            (loop (+ block 1) next-state
                  (append (reverse
                           (map (lambda (arm position) (list block position arm))
                                order (iota (length order) 1)))
                          entries)))))))

;;; ---------------------------------------------------------------------------
;;; Shell and store-path helpers
;;; ---------------------------------------------------------------------------

(define (benchmark-sh-quote text)
  (string-append "'" (string-join (string-split text #\') "'\\''") "'"))

(define (store-path-hash store-path)
  "Return the 32-character hash part of STORE-PATH, or #f if it is not a
/gnu/store item.  The narinfo for a path lives at <url>/<hash>.narinfo."
  (let ((prefix "/gnu/store/"))
    (and (string-prefix? prefix store-path)
         (let ((base (substring store-path (string-length prefix))))
           (and (> (string-length base) 33)
                (char=? (string-ref base 32) #\-)
                (not (string-index base #\/))
                (substring base 0 32))))))

(define (narinfo-url substitute-url store-path)
  "Return the narinfo URL for STORE-PATH on SUBSTITUTE-URL, or #f."
  (let ((hash (store-path-hash store-path)))
    (and hash
         (string-append (string-trim-right substitute-url #\/) "/" hash ".narinfo"))))

(define (benchmark-build-command store-paths substitute-urls log-file)
  "Return the shell command for the timed section of one trial.

STORE-PATHS are passed as literal store items, not package names: `guix build
/gnu/store/...' substitutes the item without evaluating any package, so the
timed section contains substitution and nothing else, and it cannot silently
fall back to compiling (there is no derivation to build from).  --no-offload
and the absence of --fallback keep that true."
  (string-append
   "guix build --no-offload --max-silent-time=1800 --substitute-urls="
   (benchmark-sh-quote (string-join substitute-urls " "))
   " " (string-join (map benchmark-sh-quote store-paths) " ")
   " >" (benchmark-sh-quote log-file) " 2>&1"))

(define (benchmark-reset-commands sudo ipfs gipsd-database gipsd-start)
  "Return the ordered list of shell commands that return the consumer to the
cold state before a trial.  SUDO is a command prefix such as \"sudo -n\" (or
\"\" when already root); IPFS is the kubo command; GIPSD-DATABASE is gipsd's
SQLite file; GIPSD-START is a shell command that starts gipsd in the
background.

The list is the SAME for both arms (protocol amendment 3).  gipsd only serves
what its mirror worker has already downloaded and pinned, so \"cold\" for GIPS
means: no subscription, no mirrored rows, no pins, no in-memory signature
cache.  Doing the identical teardown before a central trial also guarantees no
mirror is still pulling data while the central arm is being timed."
  (let ((as-root (lambda (command)
                   (if (string-null? sudo) command (string-append sudo " " command)))))
    (list
     ;; Nothing fetched by a trial is a GC root, so a plain collection removes
     ;; what the previous trial downloaded.
     "guix gc >/dev/null 2>&1"
     ;; The daemon caches narinfos (hits AND misses).  Left in place, the
     ;; second trial of an arm skips the lookups the first one paid for.
     (as-root "sh -c 'rm -rf /var/guix/substitute/cache/*'")
     ;; Stopping gipsd drops its hour-long signature cache; deleting the
     ;; database drops the subscription and every mirrored row.  Keys and the
     ;; config live in separate files and are untouched.  pkill exits 1 when
     ;; nothing matched, which is fine.
     "pkill -x gipsd; true"
     (string-append "rm -f " (benchmark-sh-quote gipsd-database) " "
                    (benchmark-sh-quote (string-append gipsd-database "-wal")) " "
                    (benchmark-sh-quote (string-append gipsd-database "-shm")))
     ;; `ipfs repo gc' keeps pinned blocks, and the mirror worker pins all it
     ;; fetches -- so unpin first.  xargs -r: no pins is not an error.
     (string-append ipfs " pin ls --type=recursive -q | xargs -r " ipfs
                    " pin rm >/dev/null 2>&1")
     (string-append ipfs " repo gc >/dev/null 2>&1")
     gipsd-start
     "sync"
     (as-root "sh -c 'echo 3 > /proc/sys/vm/drop_caches'"))))

(define (items-to-fetch closure present?)
  "The items of CLOSURE the consumer does not already hold, given the predicate
PRESENT?.  Guix never downloads an item that is live in the store (glibc,
bash), so these -- not the whole closure -- are what must become available
before an install can succeed, in either arm."
  (remove present? closure))

(define (availability-verdict needed-count available-count elapsed-ms timeout-ms)
  "Decide what the mirror wait loop does next: 'ready, 'timeout or 'wait."
  (cond ((>= available-count needed-count) 'ready)
        ((>= elapsed-ms timeout-ms) 'timeout)
        (else 'wait)))

;;; ---------------------------------------------------------------------------
;;; Guards for `run'
;;;
;;; `run' garbage-collects the machine it is on.  On the hub that deletes the
;;; very items being served; on a laptop it evicts every `guix shell' cache.
;;; A comment saying "do not do that" is not a guard, so these are.
;;; ---------------------------------------------------------------------------

(define (run-refusal-reason actual-hostname expected-hostname hub-marker-present?)
  "Return #f when `run' may proceed, else a string saying why not.  The caller
must NAME the machine it believes it is on: a command pasted into the wrong
terminal then fails on the hostname instead of collecting the wrong store."
  (cond (hub-marker-present?
         "this machine ran `hub-prepare' (hub marker present); `run' would delete what it serves")
        ((not expected-hostname)
         "--consumer-host NAME is required and must equal this machine's hostname")
        ((not (string=? actual-hostname expected-hostname))
         (string-append "--consumer-host is " expected-hostname
                        " but this machine is " actual-hostname))
        (else #f)))

(define (run-confirmation-text hostname trial-count)
  "The question asked on /dev/tty.  It names every destructive step and how
often it repeats, because consent to `guix gc' once is not consent to forty."
  (string-append
   "On " hostname ", before EACH of " (number->string trial-count) " trials, this will:\n"
   "  - guix gc            (deletes ALL unrooted store items, incl. guix shell caches)\n"
   "  - clear /var/guix/substitute/cache\n"
   "  - stop gipsd, DELETE its database (subscriptions + mirrored rows)\n"
   "  - ipfs: REMOVE EVERY PIN, then repo gc (all IPFS content on this node)\n"
   "  - drop the kernel page cache\n"
   "Profile and system generations are GC roots and are not affected.\n"
   "Continue? [y/N] "))

(define (parse-df-available-kib text)
  "Return the `Available' column of `df -Pk PATH' output in KiB, or #f.  #f
must be treated as failure by the caller: an unreadable disk is not a roomy
one."
  (let ((lines (filter (lambda (line) (not (string-null? (string-trim-both line))))
                       (string-split text #\newline))))
    (and (>= (length lines) 2)
         (let ((fields (filter (lambda (field) (not (string-null? field)))
                               (string-split (last lines) #\space))))
           (and (>= (length fields) 4)
                (string->number (list-ref fields 3)))))))

;;; ---------------------------------------------------------------------------
;;; Observations taken around the timed section
;;; ---------------------------------------------------------------------------

(define (parse-proc-net-dev text)
  "Sum received and transmitted bytes over every non-loopback interface in the
contents of /proc/net/dev.  Returns (RX . TX).  Loopback is excluded so that
guix-daemon talking to gipsd on 127.0.0.1 is not counted as network traffic;
the IPFS transfer itself arrives on a real interface and is counted."
  (fold (lambda (line totals)
          (let ((colon (string-index line #\:)))
            (if (not colon)
                totals
                (let ((name (string-trim-both (substring line 0 colon)))
                      (fields (filter (lambda (field) (not (string-null? field)))
                                      (string-split (substring line (+ colon 1))
                                                    #\space))))
                  (if (or (string=? name "lo") (< (length fields) 9))
                      totals
                      (cons (+ (car totals) (or (string->number (list-ref fields 0)) 0))
                            (+ (cdr totals) (or (string->number (list-ref fields 8)) 0))))))))
        (cons 0 0)
        (string-split text #\newline)))

(define (download-sources log-text)
  "Return the list of URLs that guix reported downloading from, in order."
  (let ((marker "downloading from "))
    (filter-map
     (lambda (line)
       (let ((at (string-contains line marker)))
         (and at
              (let* ((rest (substring line (+ at (string-length marker))))
                     (end (or (string-index rest char-whitespace?)
                              (string-length rest)))
                     (url (substring rest 0 end)))
                (and (not (string-null? url)) url)))))
     (string-split log-text #\newline))))

(define (classify-downloads sources arm-urls)
  "Return (TOTAL FROM-ARM OTHER) for the download SOURCES of a trial whose arm
was configured with ARM-URLS."
  (let* ((from-arm? (lambda (source)
                      (any (lambda (url)
                             (string-prefix? (string-trim-right url #\/) source))
                           arm-urls)))
         (matching (count from-arm? sources)))
    (list (length sources) matching (- (length sources) matching))))

(define* (trial-verdict exit-code downloads #:key (rx-bytes #f) (min-rx-bytes 0))
  "Return the status string for a trial.  A trial only counts as \"ok\" when
the build succeeded AND every download was attributed to the arm under test.
Zero parsed downloads is NOT ok: it means either nothing was cold or the log
format changed, and either way the row proves nothing about its arm.

MIN-RX-BYTES is the floor of network bytes a genuinely cold fetch must move
(a conservative fraction of the closure's nar size).  A trial that \"fetched\"
the workload while receiving less than that was served from a local cache --
gipsd's mirror worker pins whole closures in the background, so this is the
expected failure, not a hypothetical one.  An unreadable counter with a floor
set is also not-cold: a check that cannot run must fail."
  (match downloads
    ((total from-arm other)
     (cond ((not (zero? exit-code)) "failed")
           ((zero? total) "unattributed")
           ((not (zero? other)) "contaminated")
           ((and (> min-rx-bytes 0)
                 (or (not rx-bytes) (< rx-bytes min-rx-bytes)))
            "not-cold")
           (else "ok")))))

;;; ---------------------------------------------------------------------------
;;; Result rows (tab-separated, append-only)
;;; ---------------------------------------------------------------------------

(define benchmark-row-fields
  '(schema run_id workload block position arm status exit_code wall_ms
    first_available_ms available_ms install_ms
    rx_bytes tx_bytes downloads_total downloads_from_arm downloads_other
    load1 started_utc))

(define (benchmark-header-line)
  (string-join (map symbol->string benchmark-row-fields) "\t"))

(define (field->string value)
  (cond ((string? value) value)
        ((symbol? value) (symbol->string value))
        ((number? value) (number->string value))
        ((not value) "")
        (else (format #f "~a" value))))

(define (benchmark-row-line row)
  "Serialize the alist ROW in benchmark-row-fields order.  Tabs and newlines
inside a value would corrupt the table, so they are replaced with spaces."
  (string-join
   (map (lambda (field)
          (string-map (lambda (c) (if (memv c '(#\tab #\newline #\return)) #\space c))
                      (field->string (assq-ref row field))))
        benchmark-row-fields)
   "\t"))

(define (parse-benchmark-rows text)
  "Parse the contents of a results file into a list of alists.  Header lines,
blank lines and rows of another schema are skipped; numeric fields are
converted, and stay #f when unparsable so a damaged row cannot become a zero."
  (let ((numeric '(block position exit_code wall_ms first_available_ms
                   available_ms install_ms rx_bytes tx_bytes
                   downloads_total downloads_from_arm downloads_other load1)))
    (filter-map
     (lambda (line)
       (let ((cells (string-split line #\tab)))
         (and (= (length cells) (length benchmark-row-fields))
              (string=? (car cells) gips-benchmark-schema)
              (map (lambda (field cell)
                     (cons field (if (memq field numeric) (string->number cell) cell)))
                   benchmark-row-fields cells))))
     (string-split text #\newline))))

(define (completed-trial? rows workload block arm)
  "True when ROWS already hold a row for this trial, whatever its status.  A
failed trial is a result and is never silently re-run into a better one."
  (any (lambda (row)
         (and (equal? (assq-ref row 'workload) workload)
              (equal? (assq-ref row 'block) block)
              (equal? (assq-ref row 'arm) arm)))
       rows))

;;; ---------------------------------------------------------------------------
;;; Statistics
;;; ---------------------------------------------------------------------------

(define (mean values)
  (/ (apply + values) (length values)))

(define (median values)
  (let* ((sorted (sort values <))
         (size (length sorted))
         (middle (quotient size 2)))
    (if (odd? size)
        (list-ref sorted middle)
        (/ (+ (list-ref sorted (- middle 1)) (list-ref sorted middle)) 2))))

(define (sample-standard-deviation values)
  "Bessel-corrected standard deviation; 0 for fewer than two values."
  (if (< (length values) 2)
      0
      (let ((center (mean values)))
        (sqrt (/ (apply + (map (lambda (value) (expt (- value center) 2)) values))
                 (- (length values) 1))))))

(define (quantile sorted-values fraction)
  "Nearest-rank quantile of the ascending list SORTED-VALUES."
  (let* ((size (length sorted-values))
         (rank (max 1 (min size (inexact->exact (ceiling (* fraction size)))))))
    (list-ref sorted-values (- rank 1))))

(define (resample samples state)
  "Draw (length SAMPLES) items with replacement.  Returns the sample and the
advanced state."
  (let ((cells (list->vector samples)))
    (let loop ((remaining (vector-length cells)) (state state) (drawn '()))
      (if (zero? remaining)
          (values drawn state)
          (call-with-values (lambda () (lcg-below state (vector-length cells)))
            (lambda (pick next-state)
              (loop (- remaining 1) next-state
                    (cons (vector-ref cells pick) drawn))))))))

(define* (bootstrap-interval samples statistic seed #:key (resamples 10000)
                             (confidence 0.95))
  "Percentile bootstrap confidence interval for STATISTIC over SAMPLES.
Returns (LOW . HIGH).  Deterministic given SEED."
  (let loop ((remaining resamples) (state seed) (estimates '()))
    (if (zero? remaining)
        (let ((sorted (sort estimates <))
              (tail (/ (- 1 confidence) 2)))
          (cons (quantile sorted tail) (quantile sorted (- 1 tail))))
        (call-with-values (lambda () (resample samples state))
          (lambda (sample next-state)
            (loop (- remaining 1) next-state
                  (cons (statistic sample) estimates)))))))

(define* (sign-flip-p-value differences seed #:key (exact-limit 16)
                            (monte-carlo-draws 100000))
  "Two-sided paired permutation test of H0: the arm labels within a block are
exchangeable (mean difference 0).  Under H0 each difference is as likely to
have had the opposite sign, so we compare |mean| against its distribution over
sign assignments: all 2^n of them when n <= EXACT-LIMIT, else a seeded sample.
No normality assumption, which matters because download times are skewed."
  (let* ((size (length differences))
         (observed (abs (apply + differences)))
         ;; Tolerance so that the identity assignment always counts itself
         ;; despite floating-point summation order.
         (threshold (- observed (* 1e-9 (max 1 observed))))
         (extreme? (lambda (total) (>= (abs total) threshold))))
    (if (<= size exact-limit)
        (let loop ((mask 0) (hits 0))
          (if (= mask (expt 2 size))
              (/ hits (expt 2 size))
              (loop (+ mask 1)
                    (if (extreme?
                         (apply + (map (lambda (difference bit)
                                         (if (logbit? bit mask) (- difference) difference))
                                       differences (iota size))))
                        (+ hits 1) hits))))
        (let loop ((remaining monte-carlo-draws) (state seed) (hits 0))
          (if (zero? remaining)
              ;; +1/+1: the observed assignment is itself one of the draws.
              (/ (+ hits 1) (+ monte-carlo-draws 1))
              (let flip ((rest differences) (state state) (total 0))
                (if (null? rest)
                    (loop (- remaining 1) state (if (extreme? total) (+ hits 1) hits))
                    (call-with-values (lambda () (lcg-below state 2))
                      (lambda (coin next-state)
                        (flip (cdr rest) next-state
                              (+ total (if (zero? coin) (car rest) (- (car rest))))))))))))))

;;; ---------------------------------------------------------------------------
;;; Analysis
;;; ---------------------------------------------------------------------------

(define (rows-for rows workload arm)
  (filter (lambda (row)
            (and (equal? (assq-ref row 'workload) workload)
                 (equal? (assq-ref row 'arm) arm)))
          rows))

(define (ok-row? row)
  (and (equal? (assq-ref row 'status) "ok") (number? (assq-ref row 'wall_ms))))

(define (median-of-field rows field)
  "Median of the numeric values of FIELD over ROWS, or #f when there are none."
  (let ((numbers (filter number? (map (lambda (row) (assq-ref row field)) rows))))
    (and (pair? numbers) (exact->inexact (median numbers)))))

(define (arm-summary rows workload arm)
  "Descriptive statistics for one arm.  `attempted' counts every row; the
timing statistics use only \"ok\" rows, and the gap between the two is reported
rather than hidden."
  (let* ((all (rows-for rows workload arm))
         (times (map (lambda (row) (assq-ref row 'wall_ms)) (filter ok-row? all)))
         (received (filter number? (map (lambda (row) (assq-ref row 'rx_bytes))
                                        (filter ok-row? all)))))
    `((arm . ,arm)
      (attempted . ,(length all))
      (ok . ,(length times))
      (mean_ms . ,(and (pair? times) (exact->inexact (mean times))))
      (median_ms . ,(and (pair? times) (exact->inexact (median times))))
      (sd_ms . ,(and (pair? times) (exact->inexact (sample-standard-deviation times))))
      (min_ms . ,(and (pair? times) (apply min times)))
      (max_ms . ,(and (pair? times) (apply max times)))
      (median_rx_bytes . ,(and (pair? received) (exact->inexact (median received))))
      ;; Sub-phases of wall_ms.  Only the gips arm has a mirror wait; they are
      ;; reported beside the total, never subtracted from it.
      (median_first_available_ms . ,(median-of-field (filter ok-row? all) 'first_available_ms))
      (median_available_ms . ,(median-of-field (filter ok-row? all) 'available_ms))
      (median_install_ms . ,(median-of-field (filter ok-row? all) 'install_ms)))))

(define (paired-blocks rows workload baseline-arm treatment-arm)
  "Return a list of (BLOCK BASELINE-MS TREATMENT-MS) for blocks where BOTH arms
produced an \"ok\" row.  A block with one bad arm is dropped whole: keeping its
good half would unpair the design."
  (let ((ok-time (lambda (arm block)
                   (let ((row (find (lambda (row)
                                      (and (equal? (assq-ref row 'block) block)
                                           (ok-row? row)))
                                    (rows-for rows workload arm))))
                     (and row (assq-ref row 'wall_ms))))))
    (filter-map
     (lambda (block)
       (let ((baseline (ok-time baseline-arm block))
             (treatment (ok-time treatment-arm block)))
         (and baseline treatment (list block baseline treatment))))
     (sort (delete-duplicates
            (filter number? (map (lambda (row) (assq-ref row 'block))
                                 (rows-for rows workload baseline-arm))))
           <))))

(define* (paired-comparison rows workload baseline-arm treatment-arm seed
                            #:key (resamples 10000))
  "Compare TREATMENT-ARM against BASELINE-ARM within blocks.  The difference is
baseline minus treatment, so POSITIVE means the treatment was faster.  The
speedup is the geometric mean of baseline/treatment (ratios average
multiplicatively).  Returns #f for fewer than two complete pairs."
  (let ((pairs (paired-blocks rows workload baseline-arm treatment-arm)))
    (and (>= (length pairs) 2)
         (let* ((differences (map (match-lambda ((_ baseline treatment)
                                                 (- baseline treatment)))
                                  pairs))
                (log-ratios (map (match-lambda ((_ baseline treatment)
                                                (log (/ baseline treatment))))
                                 pairs))
                (difference-interval
                 (bootstrap-interval differences mean seed #:resamples resamples))
                (ratio-interval
                 (bootstrap-interval log-ratios mean (lcg-next seed)
                                     #:resamples resamples)))
           `((baseline . ,baseline-arm)
             (treatment . ,treatment-arm)
             (pairs . ,(length pairs))
             (mean_difference_ms . ,(exact->inexact (mean differences)))
             (median_difference_ms . ,(exact->inexact (median differences)))
             (difference_ci95_ms . ,(cons (exact->inexact (car difference-interval))
                                          (exact->inexact (cdr difference-interval))))
             (speedup . ,(exp (mean log-ratios)))
             (speedup_ci95 . ,(cons (exp (car ratio-interval))
                                    (exp (cdr ratio-interval))))
             (treatment_faster_in . ,(count positive? differences))
             (p_value . ,(exact->inexact
                          (sign-flip-p-value differences (lcg-next (lcg-next seed))))))))))

;;; Arms.  `central' and `gips' are the primary pair.  The two `publish-*' arms
;;; are controls for the compression confound (protocol amendment 4): plain
;;; `guix publish' on the hub, same machine and same link as the GIPS hub, once
;;; uncompressed like gipsd and once zstd like the central servers.
(define benchmark-arm-order '("central" "gips" "publish-none" "publish-zstd"))

(define (arms-in-order present)
  "The members of PRESENT in canonical order; unknown arm names go last, in
the order given, rather than being dropped."
  (append (filter (lambda (arm) (member arm present)) benchmark-arm-order)
          (remove (lambda (arm) (member arm benchmark-arm-order))
                  (delete-duplicates present))))

(define (planned-comparisons arms)
  "Return the list of (ROLE BASELINE TREATMENT) to report for ARMS.  Exactly
one is 'primary -- the pre-registered question.  The rest are 'explanatory:
they say WHY the primary came out as it did and carry no verdict of their own
into a headline, which is what keeps four arms from becoming four chances at
a significant result."
  (let ((has? (lambda (arm) (member arm arms))))
    (filter-map
     (match-lambda
       ((role baseline treatment)
        (and (has? baseline) (has? treatment) (list role baseline treatment))))
     '((primary "central" "gips")
       ;; Same hub, same link, same (absent) compression: what is left is the
       ;; cost or benefit of IPFS + the mirror design itself.
       (explanatory "publish-none" "gips")
       ;; Same hub and link, compression on vs off: the compression effect on
       ;; this CPU, with no GIPS involved at all.
       (explanatory "publish-zstd" "publish-none")
       ;; Same protocol and compression, near vs far: the topology effect.
       (explanatory "central" "publish-zstd")))))

(define (comparison-verdict comparison)
  "Apply the pre-registered decision rule (protocol section 7) and return one
of \"faster\", \"slower\", \"no-detectable-difference\" or \"insufficient-data\".
The rule is the 95% interval of the speedup excluding 1, not the p-value, so
that the headline is an effect size with an uncertainty rather than a star."
  (if (not comparison)
      "insufficient-data"
      (match (assq-ref comparison 'speedup_ci95)
        ((low . high)
         (cond ((> low 1) "faster")
               ((< high 1) "slower")
               (else "no-detectable-difference"))))))
