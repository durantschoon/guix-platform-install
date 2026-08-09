#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; test-oracle-preferences.scm --- tests for first-boot preference editing.
;;;
;;; Guile per the language policy.  Modelled on test-oracle-image.scm, but with
;;; one important difference: these tests are FULLY OFFLINE.  No `guix system`,
;;; no `guix repl`, no network, and -- most importantly -- no contact with the
;;; real /etc/config.scm.  Every config in here is a fixture written into a
;;; temporary directory, because a test suite that edits the machine it runs on
;;; is not a test suite.
;;;
;;; What makes that possible is that the transformation in
;;; lib/guile-config-helper.scm is a pure function from S-expression to
;;; S-expression.  The assertions call it directly.  Only the four checks that
;;; are ABOUT file handling -- byte-identity, failure atomicity -- go through
;;; the subprocess CLI, because that is the property being tested.
;;;
;;; Run: guile --no-auto-compile -s oracle/tests/test-oracle-preferences.scm
;;; Exits 0 if every check passes, 1 otherwise.  Requires guile only.

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
(define preferences-file
  (string-append repository-root "/oracle/postinstall/preferences.scm"))

;;; ---------------------------------------------------------------------------
;;; Reporting
;;; ---------------------------------------------------------------------------
;;;
;;; ASCII only, and every ANSI escape is written "\x1b[".  Guile has no octal
;;; string escape, so writing that introducer with a leading octal 033 instead
;;; yields NUL followed by the two characters "33".

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

;;; ---------------------------------------------------------------------------
;;; Loading the helper's definitions without running it
;;; ---------------------------------------------------------------------------

(define (load-helper-bindings file)
  "Evaluate FILE's top-level definitions into a fresh module and return it.

   lib/guile-config-helper.scm is a script: its last form is
   (main (command-line)).  Loading it the ordinary way would dispatch on this
   test's own argv, print the usage text and exit 1 before a single assertion
   ran.  So the forms are read one at a time and that final application is
   skipped -- everything else, including the (use-modules ...) at the top, is
   evaluated as written.  Nothing in the helper is modified to accommodate
   this."
  (let ((module (make-fresh-user-module)))
    (call-with-input-file file
      (lambda (port)
        (let loop ()
          (let ((form (read port)))
            (unless (eof-object? form)
              (unless (and (pair? form) (eq? (car form) 'main))
                (eval form module))
              (loop))))))
    module))

(define helper-module (load-helper-bindings helper-file))
(define (helper name) (module-ref helper-module name))

(define set-os-host-name    (helper 'set-os-host-name))
(define set-os-timezone     (helper 'set-os-timezone))
(define set-os-login-shell  (helper 'set-os-login-shell))
(define config-set-host-name   (helper 'config-set-host-name))
(define config-set-timezone    (helper 'config-set-timezone))
(define config-set-login-shell (helper 'config-set-login-shell))
(define record-field-ref    (helper 'record-field-ref))
(define record-has-field?   (helper 'record-has-field?))
(define collect-forms       (helper 'collect-forms))
(define user-account-form?  (helper 'user-account-form?))
;;; read-config replaces the stage-03 read-config/gexp, which no longer exists:
;;; (guix read-print) parses gexps natively, so the read-hash-extend variant was
;;; deleted in stage 04 and the ordinary reader is now the gexp-capable one.
(define read-config         (helper 'read-config))

;;; blank? is true for comments, vertical space and page breaks alike -- every
;;; node the reader now interleaves among real forms.  Needed here because a
;;; config's top-level item count is no longer its form count.
(define blank?              (helper 'blank?))

(define (code-forms exprs)
  "The real S-expressions of EXPRS, without comment or blank-line nodes."
  (remove blank? exprs))

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(define %fixture-os
  '(operating-system
    (host-name "guix-oracle")
    (timezone "America/New_York")
    (locale "en_US.utf8")
    (users (cons (user-account
                  (name "guix")
                  (comment "Guix User")
                  (group "users")
                  (home-directory "/home/guix")
                  (supplementary-groups '("wheel" "netdev")))
                 %base-user-accounts))
    (packages %base-packages)
    (services %base-services)))

(define %fixture-config
  (list '(use-modules (gnu))
        %fixture-os))

;;; An account that already carries a shell, to prove bash removes it.
(define %fixture-os/zsh
  (set-os-login-shell %fixture-os "guix" "zsh"))

;;; The name written as a VARIABLE, which is what oracle-image.scm does and
;;; therefore what /run/current-system/configuration.scm contains.  No string
;;; match is possible here.
(define %fixture-os/variable-name
  '(operating-system
    (host-name %host-name)
    (timezone %timezone)
    (users (cons (user-account
                  (name %user-name)
                  (group "users"))
                 %base-user-accounts))
    (packages %base-packages)))

(define (os-fields-except os name)
  "OS's fields with field NAME dropped, for 'and nothing else' assertions."
  (filter (lambda (f) (not (and (pair? f) (eq? (car f) name))))
          (cdr os)))

(define (sole-account os)
  (let ((accounts (collect-forms user-account-form? os)))
    (and (= 1 (length accounts)) (car accounts))))

(define (count-fields os name)
  (length (filter (lambda (f) (and (pair? f) (eq? (car f) name))) (cdr os))))

;;; ---------------------------------------------------------------------------
;;; Temporary working directory
;;; ---------------------------------------------------------------------------

(define work-dir
  (string-append "/tmp/oracle-preferences-test-" (number->string (getpid))))

(unless (file-exists? work-dir) (mkdir work-dir))

(define (work-file name) (string-append work-dir "/" name))

(define (write-text file text)
  (call-with-output-file file (lambda (port) (display text port))))

(define (read-text file)
  (call-with-input-file file get-string-all))

(define (shell-quote s)
  "Single-quote S for /bin/sh, escaping any embedded single quote."
  (string-append "'" (string-join (string-split s #\') "'\\''") "'"))

(define (run-helper . args)
  "Run the helper as a subprocess.  Returns (EXIT-STATUS . COMBINED-OUTPUT).

   The four file-handling checks go through this rather than calling the pure
   functions, because 'writes nothing when nothing changed' and 'leaves the
   file alone when it refuses' are properties of the CLI layer, not of the
   transformation."
  (let* ((command (string-append
                   "guile --no-auto-compile -s " (shell-quote helper-file) " "
                   (string-join (map shell-quote args) " ")
                   " 2>&1"))
         (port (open-input-pipe command))
         (output (get-string-all port))
         (status (close-pipe port)))
    (cons (status:exit-val status) output)))

;;; ---------------------------------------------------------------------------
;;; 1. Setting the hostname rewrites (host-name ...) and nothing else.
;;; ---------------------------------------------------------------------------

(section "1. Host name")

(let ((result (set-os-host-name %fixture-os "my-box")))
  (check "host-name is rewritten"
         (equal? (record-field-ref result 'host-name) "my-box")
         (format #f "got: ~s" (record-field-ref result 'host-name)))
  (check "exactly one host-name field remains"
         (= 1 (count-fields result 'host-name)))
  (check "every other field is untouched"
         (equal? (os-fields-except result 'host-name)
                 (os-fields-except %fixture-os 'host-name))
         (format #f "got: ~s" (os-fields-except result 'host-name))))

;; A host-name written as a variable reference is still replaceable.
(let ((result (set-os-host-name %fixture-os/variable-name "my-box")))
  (check "a variable host-name is replaced by the literal"
         (equal? (record-field-ref result 'host-name) "my-box")))

;;; ---------------------------------------------------------------------------
;;; 2. Setting the timezone rewrites (timezone ...) and nothing else.
;;; ---------------------------------------------------------------------------

(section "2. Timezone")

(let ((result (set-os-timezone %fixture-os "Europe/Berlin")))
  (check "timezone is rewritten"
         (equal? (record-field-ref result 'timezone) "Europe/Berlin")
         (format #f "got: ~s" (record-field-ref result 'timezone)))
  (check "exactly one timezone field remains"
         (= 1 (count-fields result 'timezone)))
  (check "every other field is untouched"
         (equal? (os-fields-except result 'timezone)
                 (os-fields-except %fixture-os 'timezone))))

;;; ---------------------------------------------------------------------------
;;; 3. zsh adds (shell (file-append zsh "/bin/zsh")) to the user-account.
;;; ---------------------------------------------------------------------------

(section "3. Login shell: the shell field")

(let* ((result  (set-os-login-shell %fixture-os "guix" "zsh"))
       (account (sole-account result)))
  (check "the user-account is still the only one"
         (and account #t))
  (check "shell is (file-append zsh \"/bin/zsh\")"
         (equal? (record-field-ref account 'shell)
                 '(file-append zsh "/bin/zsh"))
         (format #f "got: ~s" (and account (record-field-ref account 'shell))))
  (check "the account's other fields are untouched"
         (equal? (filter (lambda (f) (not (eq? (car f) 'shell))) (cdr account))
                 (cdr (sole-account %fixture-os)))))

;; The account whose name is a variable, not a string: matching by name is
;; impossible, and a single account must still be found.
(let* ((result  (set-os-login-shell %fixture-os/variable-name "guix" "fish"))
       (account (sole-account result)))
  (check "an account named by variable is still found"
         (equal? (record-field-ref account 'shell)
                 '(file-append fish "/bin/fish"))
         (format #f "got: ~s" (and account (record-field-ref account 'shell)))))

;;; ---------------------------------------------------------------------------
;;; 4. zsh also joins the system packages.
;;; ---------------------------------------------------------------------------

(section "4. Login shell: the package must be in the closure")

(let ((result (set-os-login-shell %fixture-os "guix" "zsh")))
  (check "zsh is added to packages"
         (equal? (record-field-ref result 'packages)
                 '(append (list zsh) %base-packages))
         (format #f "got: ~s" (record-field-ref result 'packages))))

;; An existing explicit package list is extended, not replaced.
(let* ((os '(operating-system
             (host-name "h")
             (users (cons (user-account (name "guix")) %base-user-accounts))
             (packages (append (list git vim) %base-packages))))
       (result (set-os-login-shell os "guix" "zsh")))
  (check "an existing package list is extended, not replaced"
         (equal? (record-field-ref result 'packages)
                 '(append (list git vim zsh) %base-packages))
         (format #f "got: ~s" (record-field-ref result 'packages))))

;; A package already present is not duplicated.
(let* ((os '(operating-system
             (host-name "h")
             (users (cons (user-account (name "guix")) %base-user-accounts))
             (packages (append (list zsh) %base-packages))))
       (result (set-os-login-shell os "guix" "zsh")))
  (check "an already-present package is not duplicated"
         (equal? (record-field-ref result 'packages)
                 '(append (list zsh) %base-packages))))

;; ... and the module that binds the package variable is imported, or the
;; reconfigure dies with "zsh: unbound variable".
(let ((result (config-set-login-shell %fixture-config "guix" "zsh")))
  (check "(gnu packages shells) is imported"
         (equal? (car result) '(use-modules (gnu) (gnu packages shells)))
         (format #f "got: ~s" (car result))))

;;; ---------------------------------------------------------------------------
;;; 5. bash writes NO shell field, and removes one if present.
;;; ---------------------------------------------------------------------------

(section "5. bash omits the field entirely")

(let* ((result  (set-os-login-shell %fixture-os "guix" "bash"))
       (account (sole-account result)))
  (check "bash writes no shell field"
         (not (record-has-field? account 'shell))
         (format #f "got: ~s" account))
  (check "bash on a config that had none is a complete no-op"
         (equal? result %fixture-os)
         (format #f "got: ~s" result)))

(let* ((account/before (sole-account %fixture-os/zsh))
       (result  (set-os-login-shell %fixture-os/zsh "guix" "bash"))
       (account (sole-account result)))
  (check "the fixture really did carry a zsh shell to begin with"
         (record-has-field? account/before 'shell))
  (check "bash removes an existing shell field"
         (not (record-has-field? account 'shell))
         (format #f "got: ~s" account))
  (check "bash adds no package of its own"
         ;; zsh stays in packages: removing a package the user may now depend
         ;; on is destructive, and an unused package costs disk, not a login.
         (equal? (record-field-ref result 'packages)
                 (record-field-ref %fixture-os/zsh 'packages))))

;;; ---------------------------------------------------------------------------
;;; 6. An unchanged preference leaves the config byte-identical.
;;; ---------------------------------------------------------------------------

(section "6. An unchanged preference changes nothing")

(check "setting the host name it already has is an identity"
       (equal? (set-os-host-name %fixture-os "guix-oracle") %fixture-os))
(check "setting the timezone it already has is an identity"
       (equal? (set-os-timezone %fixture-os "America/New_York") %fixture-os))

;; And at the file level, where "identity" has to mean the bytes, not just the
;; S-expressions: write-config pretty-prints, so a needless write would reflow
;; the whole file and drop every comment in it.
(let* ((file (work-file "unchanged.scm"))
       (text (string-append
              ";; A comment that a needless rewrite would destroy.\n"
              "(use-modules (gnu))\n"
              "\n"
              "(operating-system\n"
              "  (host-name \"guix-oracle\")\n"
              "  (timezone \"America/New_York\"))\n")))
  (write-text file text)
  (let ((result (run-helper "set-host-name" file "guix-oracle")))
    (check "re-setting the same host name exits 0"
           (eqv? 0 (car result)) (cdr result))
    (check "re-setting the same host name leaves the file byte-identical"
           (string=? text (read-text file))
           (read-text file)))
  (let ((result (run-helper "set-timezone" file "America/New_York")))
    (check "re-setting the same timezone leaves the file byte-identical"
           (and (eqv? 0 (car result)) (string=? text (read-text file)))
           (read-text file))))

;;; ---------------------------------------------------------------------------
;;; 7. The result still reads back as one well-formed operating-system form.
;;; ---------------------------------------------------------------------------

(section "7. The written file still parses")

(let ((file (work-file "roundtrip.scm")))
  (write-text file
              (string-append
               "(use-modules (gnu))\n"
               "(operating-system\n"
               "  (host-name \"guix-oracle\")\n"
               "  (timezone \"America/New_York\")\n"
               "  (users (cons (user-account (name \"guix\")"
               " (group \"users\")) %base-user-accounts))\n"
               "  (packages %base-packages))\n"))
  (let ((r1 (run-helper "set-host-name" file "my-box"))
        (r2 (run-helper "set-timezone" file "Europe/Berlin"))
        (r3 (run-helper "set-login-shell" file "guix" "zsh")))
    (check "three successive edits all exit 0"
           (and (eqv? 0 (car r1)) (eqv? 0 (car r2)) (eqv? 0 (car r3)))
           (string-append (cdr r1) (cdr r2) (cdr r3))))
  (let* ((exprs (read-config file))
         (systems (collect-forms (helper 'operating-system-form?) exprs)))
    (check "the file reads back without error"
           (pair? exprs))
    (check "it contains exactly one operating-system form"
           (= 1 (length systems))
           (format #f "found ~a" (length systems)))
    (let ((os (car systems)))
      (check "all three edits are present together"
             (and (equal? (record-field-ref os 'host-name) "my-box")
                  (equal? (record-field-ref os 'timezone) "Europe/Berlin")
                  (equal? (record-field-ref (sole-account os) 'shell)
                          '(file-append zsh "/bin/zsh")))
             (format #f "got: ~s" os)))))

;; A real Guix config contains gexps, which Guile's stock reader cannot read at
;; all ("Unknown # object: \"#~\"").  They must survive the round trip, or the
;; first edit on a real machine writes a config that no longer builds.
(let ((file (work-file "gexps.scm")))
  (write-text file
              (string-append
               "(use-modules (gnu))\n"
               "(define %program (program-file \"p\" #~(begin (display #$foo))))\n"
               "(operating-system\n"
               "  (host-name \"guix-oracle\")\n"
               "  (users (cons (user-account (name \"guix\"))"
               " %base-user-accounts))\n"
               "  (packages %base-packages))\n"))
  (let ((before (code-forms (read-config file))))
    (check "a config containing #~ and #$ can be read at all"
           (= 3 (length before))
           (format #f "read ~a forms" (length before)))
    ;; Stage 03 asserted here that #~ read as (gexp ...) and #$ as (ungexp ...),
    ;; which was true of the read-hash-extend reader it had just added.  Stage 04
    ;; deleted that reader: (guix read-print) keeps gexps in their own syntax
    ;; both ways, so the assertion is inverted -- the round trip must NOT
    ;; rewrite #~ into (gexp ...).  That spelling is what a human then has to
    ;; read in their own config file.
    (let ((result (run-helper "set-host-name" file "my-box")))
      (check "a config containing gexps can be edited" (eqv? 0 (car result))
             (cdr result)))
    (let ((text (read-text file)))
      (check "the written config still spells gexps #~, not (gexp ...)"
             (and (string-contains text "#~") (string-contains text "#$")
                  (not (string-contains text "(gexp ")))
             text))
    (let ((after (code-forms (read-config file))))
      (check "the gexp form survives the write unchanged"
             (equal? (list-ref before 1) (list-ref after 1))
             (format #f "got: ~s" (list-ref after 1)))
      (check "a second read/write is stable"
             (begin (run-helper "set-host-name" file "my-box")
                    (equal? after (code-forms (read-config file))))))))

;;; ---------------------------------------------------------------------------
;;; 8. A config lacking the field being set is handled, never silently dropped.
;;; ---------------------------------------------------------------------------

(section "8. Missing fields are inserted or refused, never dropped")

;; Inserted: host-name and timezone are plain scalars with an obvious place.
(let* ((os '(operating-system (locale "en_US.utf8")))
       (result (set-os-timezone os "Europe/Berlin")))
  (check "an absent timezone is inserted"
         (equal? (record-field-ref result 'timezone) "Europe/Berlin")
         (format #f "got: ~s" result))
  (check "it is inserted exactly once"
         (= 1 (count-fields result 'timezone)))
  (check "the fields that were there are kept"
         (equal? (record-field-ref result 'locale) "en_US.utf8")))

(let* ((os '(operating-system (locale "en_US.utf8")))
       (result (set-os-host-name os "my-box")))
  (check "an absent host-name is inserted"
         (equal? (record-field-ref result 'host-name) "my-box")))

;; Inserted: an absent packages field means the default, %base-packages, so the
;; correct insertion is an append onto it.
(let* ((os '(operating-system
             (host-name "h")
             (users (cons (user-account (name "guix")) %base-user-accounts))))
       (result (set-os-login-shell os "guix" "zsh")))
  (check "an absent packages field is inserted as an append on %base-packages"
         (equal? (record-field-ref result 'packages)
                 '(append (list zsh) %base-packages))
         (format #f "got: ~s" (record-field-ref result 'packages))))

;; Refused: there is no correct guess for which account to edit.
(define (refuses? thunk)
  "Return the refusal message if THUNK throws config-edit-error, else #f."
  (catch 'config-edit-error
    (lambda () (thunk) #f)
    (lambda (key message) message)))

(let ((message (refuses? (lambda ()
                           (set-os-login-shell
                            '(operating-system (host-name "h")) "guix" "zsh")))))
  (check "a config with no user-account is refused, not silently unchanged"
         (and message #t))
  (check "and the refusal says what was wrong"
         (and message (string-contains message "user-account"))
         (or message "no message")))

(let* ((os '(operating-system
             (host-name "h")
             (users (list (user-account (name "alice"))
                          (user-account (name "bob"))))))
       (message (refuses? (lambda () (set-os-login-shell os "carol" "zsh")))))
  (check "an ambiguous account choice is refused rather than guessed"
         (and message #t))
  (check "and the refusal names the user it could not find"
         (and message (string-contains message "carol"))
         (or message "no message")))

(let ((message (refuses? (lambda () (config-set-host-name '((use-modules (gnu)))
                                                          "my-box")))))
  (check "a file with no operating-system form is refused"
         (and message (string-contains message "operating-system"))
         (or message "no message")))

(let ((message (refuses? (lambda () (set-os-login-shell %fixture-os "guix" "ksh")))))
  (check "an unsupported shell is refused and the choices listed"
         (and message
              (string-contains message "bash")
              (string-contains message "zsh")
              (string-contains message "fish"))
         (or message "no message")))

;;; ---------------------------------------------------------------------------
;;; 9. The original file is untouched when the edit fails.
;;; ---------------------------------------------------------------------------

(section "9. A failed edit leaves the file alone")

(let* ((file (work-file "ambiguous.scm"))
       (text (string-append
              "(use-modules (gnu))\n"
              "(operating-system\n"
              "  (host-name \"guix-oracle\")\n"
              "  (users (list (user-account (name \"alice\"))\n"
              "               (user-account (name \"bob\")))))\n")))
  (write-text file text)
  (let ((result (run-helper "set-login-shell" file "carol" "zsh")))
    (check "an ambiguous edit exits non-zero"
           (not (eqv? 0 (car result))) (cdr result))
    (check "it reports the failure as [ERROR]"
           (string-contains (cdr result) "[ERROR]") (cdr result))
    (check "and the file is byte-identical to before"
           (string=? text (read-text file))
           (read-text file))))

(let* ((file (work-file "badshell.scm"))
       (text (string-append
              "(use-modules (gnu))\n"
              "(operating-system\n"
              "  (host-name \"guix-oracle\")\n"
              "  (users (cons (user-account (name \"guix\"))"
              " %base-user-accounts)))\n")))
  (write-text file text)
  (let ((result (run-helper "set-login-shell" file "guix" "ksh")))
    (check "an unsupported shell exits non-zero"
           (not (eqv? 0 (car result))) (cdr result))
    (check "and the file is byte-identical to before"
           (string=? text (read-text file))
           (read-text file))))

;;; ---------------------------------------------------------------------------
;;; 10. ASCII only, and no octal-escaped ANSI introducer.
;;; ---------------------------------------------------------------------------

(section "10. Readable over the OCI serial console")

(define (non-ascii-characters text)
  (delete-duplicates
   (filter (lambda (c) (> (char->integer c) 127)) (string->list text))))

;;; The forbidden escape, assembled at run time rather than written as a
;;; literal.  Spelling it out here would make this file contain the very
;;; sequence it exists to reject, and the check would fail on itself.
(define %octal-escape-introducer (string-append "\\" "033["))

(for-each
 (lambda (file)
   (let* ((name (basename file))
          (text (if (file-exists? file) (read-text file) #f)))
     (if (not text)
         (fail (string-append name " exists") file)
         (let ((offenders (non-ascii-characters text)))
           (check (string-append name " is ASCII only")
                  (null? offenders)
                  (format #f "found: ~s" offenders))
           ;; Guile has no octal string escape, so an ANSI introducer written
           ;; with a leading octal 033 is NUL followed by "33[" -- it must be
           ;; written "\x1b[" instead.
           (check (string-append name " uses no octal ANSI escape")
                  (not (string-contains text %octal-escape-introducer))
                  "use \\x1b[ instead")))))
 (list preferences-file
       helper-file
       (string-append script-directory "/test-oracle-preferences.scm")
       (string-append repository-root
                      "/oracle/postinstall/preferences_purpose.txt")))

;;; preferences.scm must read from /dev/tty.  It is documented as safe to run
;;; from a pipe, and a pipe is exactly when stdin is not the terminal.
(when (file-exists? preferences-file)
  (let ((text (read-text preferences-file)))
    (check "preferences.scm prompts on /dev/tty"
           (string-contains text "/dev/tty"))
    (check "preferences.scm never reads (current-input-port) for prompts"
           (not (string-contains text "(read-line (current-input-port))")))
    ;; The offer must be an offer.  A bare `guix system reconfigure` reachable
    ;; without a prompt is the thing this stage is not allowed to ship.
    (check "preferences.scm offers reconfigure rather than assuming it"
           (string-contains text "reconfigure"))))

;;; ---------------------------------------------------------------------------
;;; Cleanup and summary
;;; ---------------------------------------------------------------------------

(for-each (lambda (name)
            (let ((file (work-file name)))
              (when (file-exists? file) (delete-file file))))
          '("unchanged.scm" "roundtrip.scm" "gexps.scm"
            "ambiguous.scm" "badshell.scm"))
(when (file-exists? work-dir) (rmdir work-dir))

(newline)
(if (zero? failures)
    (begin (format #t "\x1b[0;32mAll ~a oracle preference checks passed!\x1b[0m\n"
                   checks)
           (exit 0))
    (begin (format #t "\x1b[0;31m~a of ~a oracle preference checks FAILED\x1b[0m\n"
                   failures checks)
           (exit 1)))
