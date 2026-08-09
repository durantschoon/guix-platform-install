#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; capture-provenance.scm -- record what actually booted this machine.
;;;
;;; Runs on the TARGET (an installed Guix system), from a checkout of this repo.
;;; Copies a system generation's own provenance -- configuration.scm,
;;; channels.scm, provenance -- into known-good/<name>/ and writes an
;;; ATTESTATION.md stub for a human to complete.
;;;
;;; Guile rather than bash per CLAUDE.md: this is a script that runs on an
;;; installed Guix system.  guile-3.0-latest is in %base-packages, so
;;; /run/current-system/profile/bin/guile exists from first boot.
;;;
;;; No Unicode: the output is read on consoles that mangle it.

(use-modules (ice-9 match)
             (ice-9 format)
             (ice-9 popen)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define %profiles "/var/guix/profiles")

(define (die fmt . args)
  (apply format (current-error-port) (string-append "[ERROR] " fmt "~%") args)
  (exit 1))

(define (note fmt . args)
  (apply format #t (string-append "[OK] " fmt "~%") args))

;;; ---------------------------------------------------------------- arguments

(define (parse-args args)
  "Return an alist of options.  Unknown flags are fatal rather than ignored:
a typo in --generation must not silently capture the wrong system."
  (let loop ((args args) (opts '()))
    (match args
      (() opts)
      (("--name" v rest ...)       (loop rest (cons (cons 'name v) opts)))
      (("--generation" v rest ...) (loop rest (cons (cons 'generation v) opts)))
      (("--from" v rest ...)       (loop rest (cons (cons 'from v) opts)))
      (("--force" rest ...)        (loop rest (cons (cons 'force #t) opts)))
      (("--help" _ ...)            (cons (cons 'help #t) opts))
      ((flag _ ...)                (die "unknown argument: ~a (try --help)" flag)))))

(define (usage)
  (display "\
Usage: capture-provenance.scm --name NAME [--generation N] [--force]

  --name NAME       directory under known-good/ to write, e.g.
                    framework-dual-geeeks.  One per machine-and-milestone.
  --generation N    system generation to capture.  Default: the current one.
                    Older generations remain capturable until deleted.
  --from PATH       capture a closure directly, rather than a generation of
                    this machine.  For a target mounted elsewhere, e.g.
                    --from /mnt/guixroot/run/current-system
  --force           overwrite an existing capture.  Refused by default,
                    because a known-good record that moves is not a record.

Run this on the installed Guix system, from a checkout of this repo.
")
  (exit 0))

;;; ------------------------------------------------------------------ helpers

(define (generation-path gen from)
  "Path to the system closure to capture.

FROM wins when given: it names a closure directly, which is how you capture a
system that is not the one you are running -- a target mounted at
/mnt/guixroot during an install, or a generation reached through another
root.  Otherwise GEN selects a generation of THIS machine, defaulting to the
running system."
  (cond (from from)
        (gen  (string-append %profiles "/system-" gen "-link"))
        (else "/run/current-system")))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (write-file path content)
  (call-with-output-file path (lambda (port) (display content port))))

(define (script-directory)
  "Directory holding this script, so the repo root can be derived from it.
Uses the invoked path rather than getcwd: the script must work when called
as known-good/capture-provenance.scm from the repo root, or by absolute path."
  (let ((self (car (command-line))))
    (if (string-index self #\/)
        (dirname self)
        ".")))

(define (run-capture cmd)
  "Run CMD, returning its first line of output, or #f. Used only for
attestation facts -- a failure here degrades the stub, it does not abort."
  (catch #t
    (lambda ()
      (let* ((port (open-input-pipe cmd))
             (line (get-line port)))
        (close-pipe port)
        (if (eof-object? line) #f line)))
    (lambda _ #f)))

;;; --------------------------------------------------------------------- main

(define (main args)
  (let* ((opts (parse-args (cdr args))))
    (when (assq 'help opts) (usage))

    (let* ((name (or (assq-ref opts 'name)
                     (die "--name is required (try --help)")))
           (gen  (assq-ref opts 'generation))
           (src  (generation-path gen (assq-ref opts 'from)))
           (dest (string-append (script-directory) "/" name)))

      ;; The generation must exist. Naming a deleted generation is the most
      ;; likely mistake here, and it must not look like success.
      (unless (file-exists? src)
        (die "no such generation: ~a~%        (deleted generations take their provenance with them)" src))

      ;; provenance-service-type is what puts these three files in the closure.
      ;; A system built without it -- or one whose config was piped in rather
      ;; than passed as a file -- will be missing configuration.scm.
      (let ((cfg (string-append src "/configuration.scm")))
        (unless (file-exists? cfg)
          (die "~a has no configuration.scm.~%        The system was built without provenance, or from a non-file config;~%        there is nothing authoritative to capture." src)))

      (when (and (file-exists? dest) (not (assq-ref opts 'force)))
        (die "~a already exists.  Use a new --name for a new milestone,~%        or --force only if you are certain you are correcting a bad capture." dest))

      (unless (file-exists? dest) (mkdir dest))

      ;; Copy verbatim. These are evidence; reformatting them destroys the
      ;; property that makes them worth keeping.
      (for-each
       (lambda (file)
         (let ((from (string-append src "/" file)))
           (if (file-exists? from)
               (begin
                 (write-file (string-append dest "/" file) (read-file from))
                 (note "captured ~a" file))
               (format #t "[WARN] ~a absent from the closure; skipped~%" file))))
       '("configuration.scm" "channels.scm" "provenance"))

      (write-attestation dest name gen src)
      (note "wrote ~a/ATTESTATION.md -- fill it in by hand, then commit" dest)
      (format #t "~%Captured from: ~a~%         -> ~a~%" (readlink-safe src) dest))))

(define (readlink-safe path)
  (catch #t (lambda () (readlink path)) (lambda _ path)))

(define (write-attestation dest name gen src)
  "Write a stub recording the machine-checkable facts, leaving the
human-checkable ones as explicit unanswered questions.  A blank template gets
filled with 'works'; named questions get real answers."
  (write-file
   (string-append dest "/ATTESTATION.md")
   (format #f "\
# Attestation: ~a

Captured by `known-good/capture-provenance.scm`. The `.scm` files beside this
one came from the system closure and must not be edited.

## Machine-checkable (recorded automatically)

| Fact | Value |
|---|---|
| Generation | ~a |
| Store path | `~a` |
| Kernel | ~a |
| Host | ~a |

## Human-checkable (fill these in)

Replace each `?` with what you actually observed. Delete nothing: a question
left unanswered is more useful than a question quietly removed, because it
tells the next reader what was never checked.

- Boots unattended to a login prompt: ?
- Keyboard works at the console: ?
- Network reaches the internet (and by what path -- wifi, ethernet, tethered): ?
- Graphics: ?
- Suspend / resume: ?
- Audio: ?
- Anything that does NOT work, or was not tried: ?

## What this capture does not claim

It records what booted. It does not claim the config is minimal, idiomatic, or
good -- only that this exact text produced a system that started. Treat it as
evidence, not as a recommendation.
"
           name
           (or gen "current")
           (readlink-safe src)
           (or (run-capture "uname -r") "?")
           (or (run-capture "hostname") "?"))))

(main (command-line))
