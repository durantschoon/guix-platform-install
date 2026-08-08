#!/run/current-system/profile/bin/guile --no-auto-compile -s
!#

;;; test-oracle-capacity.scm --- offline tests for OCI capacity handling.
;;;
;;; Guile per the language policy; the thing under test is a Guile file.
;;;
;;; These tests run OFFLINE: no OCI account, no oci CLI, no network, no
;;; guix.  That is the whole design constraint.  The behaviour under test
;;; only fires when Oracle refuses a launch with "Out of host capacity",
;;; which cannot be provoked on demand -- so the classification and the
;;; advice text were factored out of 04-deploy.scm as pure procedures and
;;; are exercised here directly on canned CLI output.
;;;
;;; How the procedures are obtained: 04-deploy.scm is a SCRIPT.  It loads
;;; oci-common.scm and calls (main) at the bottom, so plain (load ...)
;;; would try to talk to Oracle and exit.  Instead this file reads the
;;; script's top-level forms and evaluates only the named definitions.
;;; That keeps the test hook out of the production script entirely --
;;; there is no "if running under test" branch in 04-deploy.scm, and
;;; nothing about the deploy path changes because this file exists.
;;;
;;; What these tests CANNOT cover: a real capacity refusal, the exact
;;; wording Oracle emits today, whether walking to a second availability
;;; domain actually succeeds, or the shape of the CLI's stderr on a live
;;; failure.  The fixtures below are the documented forms of the error,
;;; not captured transcripts.  See docs/stages/stage-01-REPORT.md,
;;; "Unverified claims".
;;;
;;; Run: guile --no-auto-compile -s oracle/tests/test-oracle-capacity.scm
;;; Exits 0 if every check passes, 1 otherwise.

(use-modules (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (absolute path)
  "Resolve PATH against the working directory if it is not already absolute."
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define deploy-script
  (string-append repository-root "/oracle/scripts/04-deploy.scm"))
(define this-file
  (string-append repository-root "/oracle/tests/test-oracle-capacity.scm"))

(define failures 0)
(define checks 0)

(define (pass text)
  (set! checks (+ checks 1))
  (format #t "  \x1b[0;32m[OK]\x1b[0m   ~a\n" text))

(define (fail text detail)
  (set! checks (+ checks 1))
  (set! failures (+ failures 1))
  (format #t "  \x1b[0;31m[FAIL]\x1b[0m ~a\n" text)
  (unless (string-null? detail)
    (for-each (lambda (line) (format #t "         ~a\n" line))
              (string-split (string-trim-right detail) #\newline))))

(define* (check text ok? #:optional (detail ""))
  (if ok? (pass text) (fail text detail)))

;;; ---------------------------------------------------------------------
;;; Selective loading

(define (definition-name form)
  "The symbol defined by top-level FORM, or #f if FORM is not a define.
Handles both (define (f args) ...) and (define x value)."
  (and (pair? form)
       (eq? (car form) 'define)
       (pair? (cdr form))
       (let ((target (cadr form)))
         (cond ((symbol? target) target)
               ((pair? target) (car target))
               (else #f)))))

(define (load-definitions file wanted)
  "Read FILE's top-level forms and evaluate only the definitions whose
name is in WANTED.  Returns the list of names actually evaluated, so a
renamed procedure fails loudly here instead of silently skipping tests."
  (call-with-input-file file
    (lambda (port)
      (let loop ((loaded '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (reverse loaded)
              (let ((name (definition-name form)))
                (if (and name (memq name wanted))
                    (begin
                      (eval form (current-module))
                      (loop (cons name loaded)))
                    (loop loaded)))))))))

(format #t "\x1b[1;34mTesting OCI capacity handling\x1b[0m\n")
(format #t "  Script: ~a\n\n" deploy-script)

(define wanted-definitions '(launch-error-kind capacity-advice))
(define loaded-definitions (load-definitions deploy-script wanted-definitions))

(check "launch-error-kind and capacity-advice are defined in 04-deploy.scm"
       (every (lambda (name) (memq name loaded-definitions)) wanted-definitions)
       (format #f "found: ~s, wanted: ~s" loaded-definitions wanted-definitions))

;; Everything below needs those two procedures.  Without them the eval
;; would raise an unbound-variable error mid-suite and lose the counters,
;; so stop here with the failure already recorded.
(when (< (length loaded-definitions) (length wanted-definitions))
  (format #t "\n\x1b[0;31mCannot continue without both definitions.\x1b[0m\n")
  (exit 1))

;;; ---------------------------------------------------------------------
;;; 1-5. Classification
;;;
;;; The distinction that matters: 'capacity is the ONLY kind 04-deploy.scm
;;; walks past.  Misclassifying a quota or a bad subnet OCID as capacity
;;; would send the user round every availability domain collecting the
;;; same refusal, and then print advice about ARM shapes for a problem
;;; that has nothing to do with shapes.

;; 1. The human-readable form, as printed by the CLI on a refused launch.
(define capacity-message
  (string-append
   "ServiceError:\n"
   "{\n"
   "    \"client_version\": \"oci-cli/3.44.0\",\n"
   "    \"message\": \"Out of host capacity.\",\n"
   "    \"status\": 500,\n"
   "    \"target_service\": \"compute\"\n"
   "}"))

(check "\"Out of host capacity\" classifies as capacity"
       (eq? (launch-error-kind capacity-message) 'capacity)
       (format #f "got ~s" (launch-error-kind capacity-message)))

;; 2. The machine-readable service code for the same event.  Both forms
;;    have been reported by users; matching only one would leave half the
;;    failures unhandled.
(define capacity-code-message
  (string-append
   "ServiceError:\n"
   "{\n"
   "    \"code\": \"OutOfCapacity\",\n"
   "    \"message\": \"Out of capacity for shape VM.Standard.E2.1.Micro.\",\n"
   "    \"status\": 500\n"
   "}"))

(check "the service code \"OutOfCapacity\" classifies as capacity"
       (eq? (launch-error-kind capacity-code-message) 'capacity)
       (format #f "got ~s" (launch-error-kind capacity-code-message)))

;; 3. A quota is not capacity.  Same tenancy limit in every AD, so the
;;    walk cannot help and must not be attempted.
(define limit-message
  (string-append
   "ServiceError:\n"
   "{\n"
   "    \"code\": \"LimitExceeded\",\n"
   "    \"message\": \"The following service limits were exceeded: "
   "vm-standard-e2-1-micro-count.\",\n"
   "    \"status\": 400\n"
   "}"))

(check "a LimitExceeded quota error does NOT classify as capacity"
       (not (eq? (launch-error-kind limit-message) 'capacity))
       (format #f "got ~s" (launch-error-kind limit-message)))

(check "a LimitExceeded quota error classifies as limit"
       (eq? (launch-error-kind limit-message) 'limit)
       (format #f "got ~s" (launch-error-kind limit-message)))

;; 4. An unrelated failure -- here a subnet OCID from a deleted VCN.
(define invalid-message
  (string-append
   "ServiceError:\n"
   "{\n"
   "    \"code\": \"InvalidParameter\",\n"
   "    \"message\": \"Subnet ocid1.subnet.oc1..aaaaaaaabogus not found.\",\n"
   "    \"status\": 400\n"
   "}"))

(check "an InvalidParameter/bad-subnet error does NOT classify as capacity"
       (not (eq? (launch-error-kind invalid-message) 'capacity))
       (format #f "got ~s" (launch-error-kind invalid-message)))

(check "an InvalidParameter/bad-subnet error classifies as other"
       (eq? (launch-error-kind invalid-message) 'other)
       (format #f "got ~s" (launch-error-kind invalid-message)))

;; 5. Empty output, whitespace, and a successful launch's OCID all mean
;;    "no error here".  The success case is included because the caller
;;    checks the exit status first and only asks the classifier on
;;    failure -- but a classifier that called a bare OCID a capacity
;;    problem would be a trap for the next person to reuse it.
(check "empty output does NOT classify as capacity"
       (not (eq? (launch-error-kind "") 'capacity))
       (format #f "got ~s" (launch-error-kind "")))

(check "empty output classifies as none"
       (eq? (launch-error-kind "") 'none)
       (format #f "got ~s" (launch-error-kind "")))

(check "whitespace-only output classifies as none"
       (eq? (launch-error-kind "   \n  \n") 'none)
       (format #f "got ~s" (launch-error-kind "   \n  \n")))

(check "a successful launch's OCID classifies as none"
       (eq? (launch-error-kind "ocid1.instance.oc1.iad.anuwcljtexample")
            'none)
       (format #f "got ~s"
               (launch-error-kind "ocid1.instance.oc1.iad.anuwcljtexample")))

;; Case-insensitivity, since the message and the code differ in case and
;; Oracle has changed the capitalisation of messages before.
(check "capacity matching is case-insensitive"
       (and (eq? (launch-error-kind "OUT OF HOST CAPACITY.") 'capacity)
            (eq? (launch-error-kind "out of host capacity.") 'capacity))
       "")

;;; ---------------------------------------------------------------------
;;; 6-7. The advice text
;;;
;;; This is the payload of the whole stage: the user who reaches it has
;;; never used Guix, has just watched an hour-long image import succeed,
;;; and has nothing to show for it.  Each of these strings is a specific
;;; thing they can go and do.

(define advice (capacity-advice))

(check "advice names the alternative Always Free shape VM.Standard.A1.Flex"
       (string-contains advice "VM.Standard.A1.Flex")
       advice)

(check "advice mentions trying a different region"
       (string-contains (string-downcase advice) "region")
       advice)

(check "advice says retrying later is legitimate"
       (and (string-contains (string-downcase advice) "later")
            (string-contains (string-downcase advice) "rerun"))
       advice)

;; 7. Without this warning the A1.Flex pointer is actively harmful: it
;;    reads as "add a flag" and produces an instance that never boots,
;;    with no console output to explain why.
(check "advice warns the repo's image is x86_64"
       (string-contains advice "x86_64")
       advice)

(check "advice warns the x86_64 image will not boot on the ARM shape"
       (and (string-contains (string-downcase advice) "will not")
            (string-contains (string-downcase advice) "boot")
            (string-contains (string-downcase advice) "arm"))
       advice)

;; The A1.Flex pointer must not read as a drop-in flag: the flexible
;; shape needs --shape-config as well as an aarch64 image.
(check "advice notes A1.Flex needs --shape-config"
       (string-contains advice "--shape-config")
       advice)

;;; ---------------------------------------------------------------------
;;; 8-9. Source hygiene of the changed Guile
;;;
;;; Both files are read over plain terminals and, for the deploy script's
;;; output, potentially the OCI serial console.

(define deploy-source (call-with-input-file deploy-script get-string-all))
(define test-source (call-with-input-file this-file get-string-all))

(define (non-ascii-characters text)
  (delete-duplicates
   (filter (lambda (c) (> (char->integer c) 127)) (string->list text))))

(check "04-deploy.scm is ASCII only"
       (null? (non-ascii-characters deploy-source))
       (format #f "found: ~s" (non-ascii-characters deploy-source)))

(check "this test file is ASCII only"
       (null? (non-ascii-characters test-source))
       (format #f "found: ~s" (non-ascii-characters test-source)))

;; 9. Guile has no octal string escape.  A backslash followed by 033 is
;;    read as NUL followed by the literal characters 33 -- the colour
;;    never appears and a NUL goes down the terminal.  "\x1b[" is the
;;    only correct spelling, and the mistake is easy to reintroduce by
;;    copying an escape out of a bash script.
;;
;;    The needle is assembled from two pieces rather than written out,
;;    because a test file that spells the forbidden sequence literally
;;    fails its own check on itself.
(define octal-escape (string-append "\\" "033["))

(check (string-append "04-deploy.scm contains no " octal-escape " escape")
       (not (string-contains deploy-source octal-escape))
       "")

(check (string-append "this test file contains no " octal-escape " escape")
       (not (string-contains test-source octal-escape))
       "")

;;; ---------------------------------------------------------------------
;;; The walk is bounded, and it is the capacity kind alone that walks.
;;; Asserted against the source text because the walk itself does I/O and
;;; cannot run offline.

(check "the availability-domain walk is bounded by %max-availability-domains"
       (and (string-contains deploy-source "(define %max-availability-domains")
            (string-contains deploy-source ">= index %max-availability-domains"))
       "")

(check "only the capacity kind continues the walk"
       (string-contains deploy-source "(eq? (launch-error-kind output) 'capacity)")
       "")

(newline)
(if (zero? failures)
    (begin (format #t "\x1b[0;32mAll ~a oracle capacity checks passed!\x1b[0m\n"
                   checks)
           (exit 0))
    (begin (format #t "\x1b[0;31m~a of ~a oracle capacity checks FAILED\x1b[0m\n"
                   failures checks)
           (exit 1)))
