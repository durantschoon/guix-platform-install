#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-config-helper-comments.scm --- comments and gexps survive config edits.
;;;
;;; Guile per the language policy.  Modelled on test-oracle-preferences.scm, and
;;; offline in the same sense: every config edited here is a COPY in a temporary
;;; directory, so the suite never touches oracle/image/oracle-image.scm itself.
;;;
;;; Why this suite exists.  lib/guile-config-helper.scm used to read configs
;;; with Guile's stock `read', which discards comments, and write them back with
;;; `pretty-print'.  The round trip was therefore lossy in the worst possible
;;; way: it succeeded.  Any subcommand run against oracle-image.scm deleted all
;;; 134 of its comment lines and reported "[OK] Configuration updated".  In a
;;; repository whose documentation convention is that non-obvious decisions are
;;; explained where they live, that is not a formatting nit -- it is the
;;; justification for the settings being destroyed by the tool meant to adjust
;;; them.
;;;
;;; oracle-image.scm is the fixture because it is the hard case: 134 comment
;;; lines, three #~ gexps, thirteen #$ ungexps, and a nested shepherd service
;;; whose comments sit deep inside a gexp rather than at top level.
;;;
;;; Run: guile --no-auto-compile -s lib/tests/test-config-helper-comments.scm
;;; Exits 0 if every check passes, 1 otherwise.  Requires guile; the one
;;; evaluation check additionally requires guix and is skipped without it.

(use-modules (ice-9 popen)
             (ice-9 format)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; ---------------------------------------------------------------------------
;;; Locating the repository
;;; ---------------------------------------------------------------------------

(define (absolute path)
  "Resolve PATH against the working directory if it is not already absolute."
  (if (string-prefix? "/" path)
      path
      (string-append (getcwd) "/" path)))

(define script-directory (absolute (dirname (car (command-line)))))
(define repository-root (dirname (dirname script-directory)))
(define helper-file
  (string-append repository-root "/lib/guile-config-helper.scm"))
(define fixture-file
  (string-append repository-root "/oracle/image/oracle-image.scm"))
(define this-file
  (string-append script-directory "/test-config-helper-comments.scm"))

;;; ---------------------------------------------------------------------------
;;; Reporting
;;; ---------------------------------------------------------------------------
;;;
;;; ASCII only, and every ANSI escape is written "\x1b[".  Guile has no octal
;;; string escape, so an introducer written with a leading octal 033 yields NUL
;;; followed by the two characters "33".

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

(define (section title)
  (format #t "\n\x1b[1;34m~a\x1b[0m\n" title))

(define (skip text why)
  (format #t "  \x1b[1;33m[SKIP]\x1b[0m ~a (~a)\n" text why))

;;; ---------------------------------------------------------------------------
;;; Text helpers
;;; ---------------------------------------------------------------------------

(define (read-text file)
  (call-with-input-file file get-string-all))

(define (write-text file text)
  (call-with-output-file file (lambda (port) (display text port))))

(define (lines text) (string-split text #\newline))

(define (lines-containing text pattern)
  "The lines of TEXT that contain PATTERN.  Counting LINES rather than
   occurrences is deliberate: it is what `grep -c' reports, so the numbers in
   this suite can be checked by hand against the fixture with one command."
  (filter (lambda (line) (string-contains line pattern)) (lines text)))

(define (count-lines-containing text pattern)
  (length (lines-containing text pattern)))

(define (count-occurrences text pattern)
  "How many times PATTERN appears in TEXT, counting repeats on one line.

   Gexps are counted this way rather than by line, because reflowing is
   legitimate and line counts are not preserved by it: oracle-image.scm has 13
   '#$' occurrences on 11 lines, two of which carry two each, and the printer
   splits those.  The number of GEXPS must not change; the number of lines they
   occupy may."
  (let ((plen (string-length pattern)))
    (let loop ((start 0) (n 0))
      (let ((hit (string-contains text pattern start)))
        (if hit (loop (+ hit plen) (+ n 1)) n)))))

(define (line-index text pattern)
  "Index of the first line of TEXT containing PATTERN, or #f."
  (let loop ((ls (lines text)) (i 0))
    (cond ((null? ls) #f)
          ((string-contains (car ls) pattern) i)
          (else (loop (cdr ls) (+ i 1))))))

(define (have-command? name)
  (let* ((port (open-input-pipe
                (string-append "command -v " name " >/dev/null 2>&1"
                               " && echo yes || echo no")))
         (out (get-string-all port)))
    (close-pipe port)
    (string-contains out "yes")))

;;; ---------------------------------------------------------------------------
;;; The fixture's baseline, measured rather than hardcoded
;;; ---------------------------------------------------------------------------
;;;
;;; The expected counts are read from the fixture at run time.  Writing 134 as a
;;; literal would turn every future edit of oracle-image.scm into a spurious
;;; failure here, and this suite is about preservation, not about the fixture
;;; staying one particular size.  The absolute number is still printed, so a
;;; fixture that lost its comments some other way is visible.

(define fixture-text (read-text fixture-file))
(define %comment-lines (count-lines-containing fixture-text ";;"))
(define %gexp-lines    (count-occurrences fixture-text "#~"))
(define %ungexp-lines  (count-occurrences fixture-text "#$"))
(define %dd-comment    "dd rather than fallocate")

;;; ---------------------------------------------------------------------------
;;; Temporary working directory
;;; ---------------------------------------------------------------------------

(define work-dir
  (string-append "/tmp/config-helper-comments-test-"
                 (number->string (getpid))))

(unless (file-exists? work-dir) (mkdir work-dir))

(define (work-file name) (string-append work-dir "/" name))

(define (fresh-copy name)
  "A private copy of the fixture, so no test can observe another's edits."
  (let ((file (work-file name)))
    (write-text file fixture-text)
    file))

(define (shell-quote s)
  "Single-quote S for /bin/sh, escaping any embedded single quote."
  (string-append "'" (string-join (string-split s #\') "'\\''") "'"))

(define (run-helper . args)
  "Run the helper as a subprocess.  Returns (EXIT-STATUS . COMBINED-OUTPUT).

   A subprocess rather than a direct call because what is under test here is the
   whole read-edit-write pipeline as a caller experiences it -- the file on disk
   afterwards, not the S-expression in memory."
  (let* ((command (string-append
                   "guile --no-auto-compile -s " (shell-quote helper-file) " "
                   (string-join (map shell-quote args) " ")
                   " 2>&1"))
         (port (open-input-pipe command))
         (output (get-string-all port))
         (status (close-pipe port)))
    (cons (status:exit-val status) output)))

;;; Every subcommand under test, as (LABEL FILE-NAME ARGS-AFTER-THE-FILE).
;;; Driving tests 1-8 from one table is what makes "every subcommand" a fact
;;; about the code rather than about how many blocks someone remembered to
;;; write: adding a subcommand here adds it to all of them at once.
(define %subcommands
  `(("set-host-name"     "hostname.scm" ("set-host-name" "my-box"))
    ("set-timezone"      "timezone.scm" ("set-timezone" "Europe/Berlin"))
    ("set-login-shell"   "shell.scm"    ("set-login-shell" "guix" "zsh"))
    ("add-service"       "service.scm"
     ("add-service" "(gnu services networking)"
      "(service network-manager-service-type)"))
    ("switch-to-desktop" "desktop.scm"  ("switch-to-desktop"))))

;;; Run each subcommand once, up front, and keep the resulting text.  Tests 1-8
;;; are all assertions about these same five results.
(define %results
  (map (lambda (entry)
         (match entry
           ((label name (subcommand args ...))
            (let* ((file (fresh-copy name))
                   (result (apply run-helper subcommand file args)))
              (list label file (car result) (cdr result) (read-text file))))))
       %subcommands))

(define (result-label r)  (list-ref r 0))
(define (result-file r)   (list-ref r 1))
(define (result-status r) (list-ref r 2))
(define (result-output r) (list-ref r 3))
(define (result-text r)   (list-ref r 4))

;;; ---------------------------------------------------------------------------
;;; 0. The edits actually happened.
;;; ---------------------------------------------------------------------------
;;;
;;; Preservation is trivial to satisfy by doing nothing at all, so every
;;; preservation check below is worthless without this one.

(section "0. Every subcommand ran and changed the file")

(format #t "  fixture: ~a\n" fixture-file)
(format #t "  baseline: ~a ';;' lines, ~a '#~~' gexps, ~a '#$' ungexps\n\n"
        %comment-lines %gexp-lines %ungexp-lines)

(check "the fixture really does carry comments to begin with"
       (> %comment-lines 100)
       (format #f "only ~a comment lines" %comment-lines))
(check "the fixture really does contain gexps"
       (and (> %gexp-lines 0) (> %ungexp-lines 0))
       (format #f "#~~ ~a, #$ ~a" %gexp-lines %ungexp-lines))

(for-each
 (lambda (r)
   (check (string-append (result-label r) " exits 0")
          (eqv? 0 (result-status r))
          (result-output r))
   (check (string-append (result-label r) " actually modified the file")
          (not (string=? (result-text r) fixture-text))
          "the file is unchanged, so nothing was tested"))
 %results)

;;; ---------------------------------------------------------------------------
;;; 1-5. Every subcommand preserves every comment line.
;;; ---------------------------------------------------------------------------

(section "1-5. Comments survive every subcommand")

(for-each
 (lambda (r)
   (let ((got (count-lines-containing (result-text r) ";;")))
     (check (format #f "~a preserves all ~a ';;' comment lines"
                    (result-label r) %comment-lines)
            (= got %comment-lines)
            (format #f "got ~a, lost ~a" got (- %comment-lines got)))))
 %results)

;;; The count could in principle be met while the TEXT changed, so check a
;;; specific long comment survives verbatim rather than merely a comment count.
(define %sample-comment
  "OCI hands out addresses, routes and DNS over DHCP on the VNIC.")

(for-each
 (lambda (r)
   (check (format #f "~a preserves a comment's text verbatim" (result-label r))
          (string-contains (result-text r) %sample-comment)
          "the sample comment's wording changed or vanished"))
 %results)

;;; ---------------------------------------------------------------------------
;;; 6-7. Gexps stay spelled #~ and #$, not (gexp ...) / (ungexp ...).
;;; ---------------------------------------------------------------------------
;;;
;;; Stage 03 read #~ through read-hash-extend into (gexp ...).  That evaluated
;;; correctly and was still wrong to WRITE: it silently rewrote the user's file
;;; into a spelling no Guix manual uses.  (guix read-print) round-trips the
;;; reader syntax, so the check is that the file still looks like the file.

(section "6-7. Gexp syntax survives every subcommand")

(for-each
 (lambda (r)
   (let ((g (count-occurrences (result-text r) "#~"))
         (u (count-occurrences (result-text r) "#$")))
     (check (format #f "~a keeps all ~a '#~~' gexps" (result-label r) %gexp-lines)
            (= g %gexp-lines) (format #f "got ~a" g))
     (check (format #f "~a keeps all ~a '#$' ungexps" (result-label r) %ungexp-lines)
            (= u %ungexp-lines) (format #f "got ~a" u))
     (check (format #f "~a does not rewrite #~~ into (gexp ...)" (result-label r))
            (not (string-contains (result-text r) "(gexp "))
            "found the (gexp ...) spelling in the written config")
     (check (format #f "~a does not rewrite #$ into (ungexp ...)" (result-label r))
            (not (string-contains (result-text r) "(ungexp "))
            "found the (ungexp ...) spelling in the written config")))
 %results)

;;; ---------------------------------------------------------------------------
;;; 8. One specific comment, and it must still be where it explains something.
;;; ---------------------------------------------------------------------------
;;;
;;; A comment preserved but relocated is worse than one deleted: a deleted
;;; comment loses information, a moved one asserts something false about the
;;; code it has landed next to.  "dd rather than fallocate" is meaningless
;;; anywhere except beside the dd call, and it sits several levels deep inside a
;;; #~ gexp -- exactly where a naive "reattach the comments afterwards" scheme
;;; would put it back in the wrong place.

(section "8. The 'dd rather than fallocate' comment stays next to its dd call")

(define %max-comment-to-dd-lines 8)

(for-each
 (lambda (r)
   (let* ((text (result-text r))
          (n    (count-lines-containing text %dd-comment))
          (ci   (line-index text %dd-comment))
          (di   (line-index text "/bin/dd")))
     (check (format #f "~a keeps the dd comment exactly once" (result-label r))
            (= 1 n) (format #f "found ~a copies" n))
     (check (format #f "~a keeps the dd call" (result-label r))
            (and di #t) "no /bin/dd in the written config")
     (check (format #f "~a keeps the comment ABOVE the dd call" (result-label r))
            (and ci di (< ci di))
            (format #f "comment at line ~a, dd at line ~a" ci di))
     (check (format #f "~a keeps them adjacent (within ~a lines)"
                    (result-label r) %max-comment-to-dd-lines)
            (and ci di (<= (- di ci) %max-comment-to-dd-lines))
            (format #f "comment at line ~a, dd at line ~a -- ~a lines apart"
                    ci di (and ci di (- di ci))))))
 %results)

;;; ---------------------------------------------------------------------------
;;; 9. The edited config still evaluates to an <operating-system>.
;;; ---------------------------------------------------------------------------
;;;
;;; Preserving comments is pointless if the result no longer builds.  This is
;;; the same evaluation check oracle/tests/test-oracle-image.scm makes, applied
;;; to an edited copy rather than the pristine file.

(section "9. The edited config still evaluates")

(if (not (have-command? "guix"))
    (skip "the edited config evaluates to an <operating-system>"
          "guix is not on PATH")
    (let* ((edited (result-file (car %results)))
           (program (work-file "evaluate.scm")))
      ;; Written to a file rather than piped through printf, which would
      ;; interpret the backslash escapes and mangle the program.
      (call-with-output-file program
        (lambda (port)
          (format port "(use-modules (gnu system))\n")
          (format port "(let ((os (load ~s)))\n" edited)
          (format port
                  "  (display (if (operating-system? os) \"OS-OK\" \"NOT-AN-OS\"))\n")
          (format port "  (newline))\n")))
      (let* ((port (open-input-pipe
                    (string-append "guix repl -q " (shell-quote program) " 2>&1")))
             (output (get-string-all port)))
        (close-pipe port)
        (check "the edited config still evaluates to an <operating-system>"
               (string-contains output "OS-OK")
               output))))

;;; ---------------------------------------------------------------------------
;;; 10. An edit that changes nothing writes nothing.
;;; ---------------------------------------------------------------------------
;;;
;;; The fixture's host-name is the variable %host-name, so "set it to what it
;;; already is" cannot be expressed against the pristine file.  Setting it twice
;;; is the same property and is expressible: the second run must be a byte-level
;;; no-op.  This is what stops a scheduled or retried preferences run from
;;; reflowing a user's config every time it is invoked.

(section "10. Re-setting the same value leaves the file byte-identical")

(let* ((file (fresh-copy "idempotent.scm"))
       (r1 (run-helper "set-host-name" file "my-box"))
       (after-first (read-text file))
       (r2 (run-helper "set-host-name" file "my-box"))
       (after-second (read-text file)))
  (check "the first set-host-name exits 0" (eqv? 0 (car r1)) (cdr r1))
  (check "the second set-host-name exits 0" (eqv? 0 (car r2)) (cdr r2))
  (check "the second run reports that it changed nothing"
         (string-contains (cdr r2) "Already set")
         (cdr r2))
  (check "and the file is byte-identical after the second run"
         (string=? after-first after-second)
         "the file was rewritten despite nothing changing"))

;;; ---------------------------------------------------------------------------
;;; 11. The read-hash-extend gexp reader is gone.
;;; ---------------------------------------------------------------------------
;;;
;;; (guix read-print) parses gexps natively, so the stage-03 reader is dead
;;; code.  Left in place it would be a second, divergent answer to the same
;;; question -- and the one that rewrites #~ into (gexp ...).

(section "11. The stage-03 gexp reader has been removed")

(let ((source (read-text helper-file)))
  (check "install-gexp-reader! is gone from the helper"
         (not (string-contains source "install-gexp-reader!"))
         "the deleted reader is still referenced")
  (check "read-hash-extend is gone from the helper"
         (not (string-contains source "read-hash-extend"))
         "the reader macros are still installed")
  (check "read-config/gexp is gone from the helper"
         (not (string-contains source "read-config/gexp"))
         "the gexp-specific reader variant is still defined")
  ;; ...and the module that replaced it is genuinely the one in use.
  (check "the helper uses (guix read-print)"
         (string-contains source "(guix read-print)"))
  (check "the helper reads with read-with-comments"
         (string-contains source "read-with-comments"))
  (check "the helper writes with pretty-print-with-comments"
         (string-contains source "pretty-print-with-comments")))

;;; ---------------------------------------------------------------------------
;;; 12. Readable over the OCI serial console.
;;; ---------------------------------------------------------------------------

(section "12. ASCII only, no octal ANSI escape")

(define (non-ascii-characters text)
  (delete-duplicates
   (filter (lambda (c) (> (char->integer c) 127)) (string->list text))))

;;; Assembled at run time: written as a literal, this file would contain the
;;; very sequence it exists to reject and the check would fail on itself.
(define %octal-escape-introducer (string-append "\\" "033["))

(for-each
 (lambda (file)
   (let ((name (basename file)))
     (if (not (file-exists? file))
         (fail (string-append name " exists") file)
         (let* ((text (read-text file))
                (offenders (non-ascii-characters text)))
           (check (string-append name " is ASCII only")
                  (null? offenders)
                  (format #f "found: ~s" offenders))
           (check (string-append name " uses no octal ANSI escape")
                  (not (string-contains text %octal-escape-introducer))
                  "use \\x1b[ instead")))))
 (list helper-file
       this-file
       (string-append repository-root "/lib/guile-config-helper_purpose.txt")))

;;; ---------------------------------------------------------------------------
;;; Cleanup and summary
;;; ---------------------------------------------------------------------------

(for-each (lambda (name)
            (let ((file (work-file name)))
              (when (file-exists? file) (delete-file file))))
          '("hostname.scm" "timezone.scm" "shell.scm" "service.scm"
            "desktop.scm" "idempotent.scm" "evaluate.scm"))
(when (file-exists? work-dir) (rmdir work-dir))

(newline)
(if (zero? failures)
    (begin (format #t "\x1b[0;32mAll ~a comment-preservation checks passed!\x1b[0m\n"
                   checks)
           (exit 0))
    (begin (format #t "\x1b[0;31m~a of ~a comment-preservation checks FAILED\x1b[0m\n"
                   failures checks)
           (exit 1)))
