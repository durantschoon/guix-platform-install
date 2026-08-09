#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-personal-config.scm -- tests for the personal configuration contract.
;;;
;;; Guile rather than bash, per CLAUDE.md's language policy: the thing under
;;; test is a Guile script that runs on a freshly installed Guix system, and the
;;; contract it parses is an S-expression.  Asserting on S-expressions from bash
;;; means grepping for parentheses.
;;;
;;; Exercises only what needs no network, no Guix operations and no real
;;; machine: the pure helpers, the contract parser, and the --init generator.
;;; The interactive bootstrap is not tested here -- it clones repositories and
;;; installs packages -- which is exactly why --validate, --plan and --self-test
;;; exist as separate entry points.
;;;
;;; Run directly, or via postinstall/tests/run-guile-tests.sh:
;;;
;;;   guile --no-auto-compile -s postinstall/tests/test-personal-config.scm
;;;
;;; Exits 0 if every test passes, 1 otherwise.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1))


;;;
;;; Locating the script under test.
;;;

(define script-directory
  (dirname (car (command-line))))

(define repository-root
  (dirname (dirname script-directory)))

(define script-under-test
  (string-append repository-root "/postinstall/recipes/add/personal-config.scm"))

(define work-directory
  (format #f "~a/personal-config-tests-~a"
          (or (getenv "TMPDIR") "/tmp")
          (getpid)))


;;;
;;; Tiny test harness.
;;;
;;; ASCII markers, matching the script under test: these tests are run on the
;;; same terminals it is.

(define failures 0)
(define checks 0)

(define (heading text)
  (format #t "\n\x1b[1;34m~a\x1b[0m\n" text))

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


;;;
;;; Running the script under test.
;;;

(define (run-script . args)
  "Run the script with ARGS.  Returns (exit-code . combined-output)."
  (let* ((quoted (map (lambda (arg) (format #f "~s" arg)) args))
         (command (format #f "guile --no-auto-compile -s ~s ~a 2>&1"
                          script-under-test
                          (string-join quoted " ")))
         (port (open-input-pipe command))
         (output (get-string-all port))
         (status (close-pipe port)))
    (cons (or (status:exit-val status) -1)
          (if (eof-object? output) "" output))))

(define (exit-code result) (car result))
(define (output result) (cdr result))

(define (contains? haystack needle)
  (and (string-contains haystack needle) #t))

(define (write-file path content)
  (call-with-output-file path
    (lambda (port) (display content port))))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (make-directory! path)
  (system* "mkdir" "-p" path))


;;;
;;; Test 1: the pure helpers.
;;;

(define (test-self-test)
  (heading "Pure helpers (URL parsing, package specs, word wrapping)")
  (let ((result (run-script "--self-test")))
    (check "--self-test passes"
           (zero? (exit-code result))
           (output result))
    ;; The self-test's own assertions must actually have run; a script that
    ;; printed nothing and exited 0 would pass the check above.
    (check "--self-test ran its URL assertions"
           (contains? (output result) "scp-style is ssh")
           (output result))))


;;;
;;; Test 2: a well-formed contract is accepted, and the plan is honest.
;;;

(define %valid-contract
  "(personal-config
  (version 1)
  (name \"test-config\")
  (requires \"git\" \"gnu-make\")
  (steps
    (step (name \"links\")
          (run \"make set_up_links\")
          (description \"Symlink dotfiles\")
          (default? #t))
    (step (name \"keyd\")
          (run \"make setup-keyd\")
          (description \"Physical machines only\"))))
")

(define (test-valid-contract)
  (heading "A valid contract is accepted")
  (let* ((path (string-append work-directory "/guix-personal.scm"))
         (_ (write-file path %valid-contract))
         (result (run-script "--validate" path))
         (text (output result)))
    (check "--validate exits 0" (zero? (exit-code result)) text)

    ;; The plan is the user's only preview of what will run on their machine.
    ;; Showing step names without the commands would be a plan you cannot audit.
    (check "plan shows the default step's command"
           (contains? text "make set_up_links") text)
    (check "plan shows the optional step's command"
           (contains? text "make setup-keyd") text)
    (check "plan lists required packages"
           (contains? text "git gnu-make") text)

    ;; default? is what separates "part of the one command" from "offered",
    ;; so it has to be visible before anything runs.
    (check "plan marks the default step"
           (contains? text "[default] links") text)
    (check "plan marks the optional step"
           (and (contains? text "keyd")
                (contains? text "opt")) text)))


;;;
;;; Test 3: --plan finds a contract given only a directory.
;;;

(define (test-plan-discovery)
  (heading "--plan discovers the contract in a directory")
  (let ((result (run-script "--plan" work-directory)))
    (check "--plan finds guix-personal.scm"
           (zero? (exit-code result))
           (output result)))

  ;; The hidden spelling is documented as accepted, so it must be.
  (let ((hidden (string-append work-directory "/hidden")))
    (make-directory! hidden)
    (write-file (string-append hidden "/.guix-personal.scm") %valid-contract)
    (let ((result (run-script "--plan" hidden)))
      (check "--plan accepts the hidden .guix-personal.scm"
             (zero? (exit-code result))
             (output result))))

  (let ((empty (string-append work-directory "/empty")))
    (make-directory! empty)
    (let ((result (run-script "--plan" empty)))
      (check "--plan fails when there is no contract"
             (not (zero? (exit-code result)))
             (output result)))))


;;;
;;; Test 4: every malformed contract is rejected.
;;;
;;; The most important test here.  A lenient parser's failure mode is a typo'd
;;; clause silently dropped -- the package never installed, the step never run
;;; -- discovered on a machine reachable only by a serial console.

(define %malformed-contracts
  `(("missing version"
     "(personal-config (name \"x\") (steps (step (name \"a\") (run \"b\"))))")
    ("unsupported version"
     "(personal-config (version 2) (steps (step (name \"a\") (run \"b\"))))")
    ("typo in a top-level key"
     "(personal-config (version 1) (require \"git\") (steps (step (name \"a\") (run \"b\"))))")
    ("typo in a step key"
     "(personal-config (version 1) (steps (step (name \"a\") (cmd \"b\"))))")
    ("no steps declared"
     "(personal-config (version 1) (name \"x\"))")
    ("duplicate step names"
     "(personal-config (version 1) (steps (step (name \"a\") (run \"x\")) (step (name \"a\") (run \"y\"))))")
    ("step without run"
     "(personal-config (version 1) (steps (step (name \"a\"))))")
    ("step name is not a string"
     "(personal-config (version 1) (steps (step (name a) (run \"b\"))))")
    ("non-string in requires"
     "(personal-config (version 1) (requires git) (steps (step (name \"a\") (run \"b\"))))")
    ("wrong top-level form"
     "(operating-system (host-name \"x\"))")
    ("empty file" "")))

(define (test-malformed-contracts)
  (heading "Malformed contracts are rejected")
  (let ((path (string-append work-directory "/bad.scm")))
    (for-each
     (lambda (entry)
       (let ((label (car entry))
             (content (cadr entry)))
         (write-file path content)
         (let ((result (run-script "--validate" path)))
           (check (format #f "rejected: ~a" label)
                  (not (zero? (exit-code result)))
                  (output result)))))
     %malformed-contracts))

  ;; The message has to name what is wrong.  "Invalid contract" alone would
  ;; leave the user diffing their file against the documentation.
  (let ((path (string-append work-directory "/bad.scm")))
    (write-file path
                "(personal-config (version 1) (require \"git\") (steps (step (name \"a\") (run \"b\"))))")
    (let ((text (output (run-script "--validate" path))))
      (check "error names the offending key"
             (contains? text "require") text)
      (check "error lists the acceptable keys"
             (contains? text "requires") text))))


;;;
;;; Test 5: --init generates a contract this same parser accepts.
;;;
;;; A generator whose output its own validator rejects would send users off to
;;; edit a file that was broken before they touched it.

(define %test-makefile
  ".PHONY: apply set_up_links setup-keyd
apply:
\techo apply
set_up_links:
\techo links
setup-keyd:
\techo keyd
")

(define (test-init)
  (heading "--init generates a valid starter contract")
  (let ((init-dir (string-append work-directory "/init")))
    (make-directory! init-dir)
    (write-file (string-append init-dir "/Makefile") %test-makefile)
    (write-file (string-append init-dir "/channels.scm") "(list)\n")

    (let ((result (run-script "--init" init-dir)))
      (check "--init exits 0" (zero? (exit-code result)) (output result)))

    (let ((generated (string-append init-dir "/guix-personal.scm")))
      (check "--init wrote guix-personal.scm" (file-exists? generated) "")

      (when (file-exists? generated)
        (let ((result (run-script "--validate" generated))
              (text (read-file generated)))
          (check "generated contract validates"
                 (zero? (exit-code result))
                 (string-append (output result) "\n--- generated ---\n" text))

          ;; It must reflect what was actually in the repository, or the user
          ;; is editing a template rather than a starting point.
          (check "picked up gnu-make for a Makefile repo"
                 (contains? text "gnu-make") text)
          (check "picked up channels.scm"
                 (contains? text "(channels \"channels.scm\")") text)
          (check "listed the Makefile's phony targets"
                 (contains? text "setup-keyd") text)
          ;; The EDIT ME markers are load-bearing: the generator guesses, and an
          ;; unedited guess runs a wrong command on a new machine.
          (check "kept the EDIT ME markers"
                 (contains? text "EDIT ME") text))))

    ;; Refuses to clobber.  Losing a hand-written contract to a stray --init
    ;; would be the worst failure this tool could have.
    (let ((result (run-script "--init" init-dir)))
      (check "--init refuses to overwrite an existing contract"
             (not (zero? (exit-code result)))
             (output result)))))


;;;
;;; Test 6: terminal safety.
;;;

(define (test-terminal-safety)
  (heading "Terminal safety on the serial console")
  (let ((source (read-file script-under-test)))

    ;; ASCII only.  CLAUDE.md permits Unicode in postinstall scripts, but this
    ;; is the one most likely to be run over the Oracle serial console, which
    ;; renders no better than the Guix ISO terminal.
    (let ((non-ascii (filter (lambda (character)
                               (> (char->integer character) 127))
                             (string->list source))))
      (check "script is ASCII only"
             (null? non-ascii)
             (if (null? non-ascii)
                 ""
                 (format #f "found: ~s" (delete-duplicates non-ascii)))))

    ;; Guile has no octal string escape.  "\033[1;34m" reads as NUL followed by
    ;; the literal characters 3, 3, [, 1 ... so the colour never applies and a
    ;; NUL byte goes to the terminal on every message.  Verified on Guile 3.0.11:
    ;;   (string->list "\033[1m") => (#\nul #\3 #\3 #\[ #\1 #\m)
    ;;   (string->list "\x1b[1m") => (#\esc #\[ #\1 #\m)
    (check "no \\033 escapes (Guile writes those as NUL + \"33\")"
           (not (contains? source "\\033["))
           "use \\x1b[ instead")

    ;; And prove it at runtime, not only in the source.
    (let ((text (output (run-script "--self-test"))))
      (check "output contains no NUL bytes"
             (not (memv #\nul (string->list text)))
             ""))))


;;;
;;; Run everything.
;;;

(define (main)
  (unless (file-exists? script-under-test)
    (format #t "\x1b[0;31mCannot find script under test: ~a\x1b[0m\n"
            script-under-test)
    (exit 1))

  (format #t "\x1b[1;34mTesting Personal Configuration Contract\x1b[0m\n")
  (format #t "  Script: ~a\n" script-under-test)

  (make-directory! work-directory)

  (test-self-test)
  (test-valid-contract)
  (test-plan-discovery)
  (test-malformed-contracts)
  (test-init)
  (test-terminal-safety)

  (system* "rm" "-rf" work-directory)

  (newline)
  (if (zero? failures)
      (begin
        (format #t "\x1b[0;32mAll ~a personal-config checks passed!\x1b[0m\n" checks)
        (exit 0))
      (begin
        (format #t "\x1b[0;31m~a of ~a personal-config checks FAILED\x1b[0m\n"
                failures checks)
        (exit 1))))

(main)
