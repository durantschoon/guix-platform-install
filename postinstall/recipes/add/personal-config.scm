#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; personal-config.scm -- bootstrap the user's OWN configuration repository on
;;; a freshly installed machine.  This is postinstall step one: the platform
;;; installers produce a system that boots and nothing more, and this is what
;;; turns that into a machine the user recognises.
;;;
;;; Run it with nothing else on the machine:
;;;
;;;   wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
;;;     | guile --no-auto-compile -s /dev/stdin
;;;
;;; That pipe is safe because every prompt below reads /dev/tty, not stdin --
;;; stdin is the script itself.  See CLAUDE.md, "Reading User Input".
;;;
;;; What a fresh Guix system actually has is the constraint that shapes this
;;; file.  %base-packages contains guile, wget and nss-certs; it does NOT
;;; contain git, curl, make or the openssh client.  So the entry point can only
;;; assume wget+guile, and everything else -- git included -- is provisioned
;;; here before it is used.
;;;
;;; Subcommands (the last three exist so the logic is testable without a
;;; network or a real machine):
;;;
;;;   (no arguments)      interactive bootstrap
;;;   --validate FILE     parse and check a contract, exit non-zero if invalid
;;;   --plan DIR          show what would run for an already-cloned repo
;;;   --init [DIR]        write a starter guix-personal.scm
;;;
;;; Every setting is justified in personal-config_purpose.txt.  The contract
;;; format itself is specified in docs/PERSONAL_CONFIG_CONTRACT.md -- that is
;;; the document a user reads to prepare their own repository.
;;;
;;; ASCII only, deliberately.  This is the script most likely to be run over the
;;; OCI serial console, which renders no better than the Guix ISO terminal.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1))


;;;
;;; Output.
;;;

(define (msg text)
  (format #t "\n\x1b[1;34m==> ~a\x1b[0m\n" text))

(define (info text)
  (format #t "  ~a\n" text))

(define (warn text)
  (format #t "\n\x1b[1;33m[WARN]\x1b[0m ~a\n" text))

(define (err text)
  (format #t "\n\x1b[1;31m[ERROR]\x1b[0m ~a\n" text))

(define (ok text)
  (format #t "\n\x1b[1;32m[OK]\x1b[0m ~a\n" text))


;;;
;;; Input.
;;;
;;; Always /dev/tty.  The documented entry point pipes this script into guile,
;;; so stdin is source code; reading a prompt from it would consume the script.

(define (tty-port)
  "Return an input port on the controlling terminal, or #f when there is none."
  (catch #t
    (lambda () (open-input-file "/dev/tty"))
    (lambda _ #f)))

(define (read-tty-line)
  "Read one line from the terminal.  Returns \"\" at EOF so callers can treat a
closed terminal as 'accept the default' rather than crashing."
  (let ((port (tty-port)))
    (if (not port)
        ""
        (let ((line (read-line port)))
          (close-port port)
          (if (eof-object? line) "" (string-trim-both line))))))

(define* (ask prompt #:optional (default ""))
  "Prompt for a line of text, returning DEFAULT when the user just hits Enter."
  (if (string-null? default)
      (format #t "~a: " prompt)
      (format #t "~a [~a]: " prompt default))
  (force-output)
  (let ((answer (read-tty-line)))
    (if (string-null? answer) default answer)))

(define* (ask-yes? prompt #:optional (default #f))
  "Ask a yes/no question.  DEFAULT is what Enter means."
  (format #t "~a ~a " prompt (if default "[Y/n]" "[y/N]"))
  (force-output)
  (let ((answer (string-downcase (read-tty-line))))
    (cond ((string-null? answer) default)
          ((member answer '("y" "yes")) #t)
          (else #f))))

(define (pause text)
  (format #t "\n~a" text)
  (force-output)
  (read-tty-line))


;;;
;;; Shell helpers.
;;;

(define (succeeded? status)
  "Did a 'system' call exit cleanly?

status:exit-val returns #f when the child was killed by a signal rather than
exiting -- Ctrl-C during a long 'guix install' is the ordinary way to see that.
Passing #f to zero? would raise a wrong-type error on top of the interruption."
  (let ((code (status:exit-val status)))
    (and code (zero? code))))

(define (run cmd)
  "Run CMD through the shell, echoing it first.  Returns #t on exit status 0.
The echo is not decoration: this script runs commands that came out of the
user's own repository, and showing each one before it runs is the only way the
user can tell what a contract actually did."
  (format #t "  $ ~a\n" cmd)
  (force-output)
  (succeeded? (system cmd)))

(define (run-quiet cmd)
  "Run CMD without echoing it.  For probes whose command text is noise."
  (succeeded? (system (string-append cmd " >/dev/null 2>&1"))))

(define (capture cmd)
  "Run CMD and return its standard output as a string (empty string on error)."
  (catch #t
    (lambda ()
      (let* ((port (open-input-pipe cmd))
             (output (get-string-all port)))
        (close-pipe port)
        (if (eof-object? output) "" output)))
    (lambda _ "")))

(define (home)
  (or (getenv "HOME") "/home/unknown"))

(define (user-profile-bin)
  (string-append (home) "/.guix-profile/bin"))

(define (ensure-profile-on-path!)
  "Put ~/.guix-profile/bin at the front of PATH for the rest of this process.

'guix install' populates the profile but cannot alter the PATH of a process
that is already running -- the login shell picks it up at the NEXT login.  A
script that installs git and then calls git in the same breath must do this
itself, or it installs a package it then cannot find."
  (let ((bin (user-profile-bin))
        (path (or (getenv "PATH") "")))
    (unless (string-contains path bin)
      (setenv "PATH" (string-append bin ":" path)))))

(define (mkdir-p path)
  "Create PATH and any missing parents.  mkdir -p semantics, no error if present."
  (run-quiet (format #f "mkdir -p ~s" path)))


;;;
;;; Package provisioning.
;;;

(define (installed-packages)
  "Names of packages in the user profile, as a list of strings."
  (let ((output (capture "guix package -I 2>/dev/null")))
    (filter-map (lambda (line)
                  (let ((fields (string-tokenize line)))
                    (and (pair? fields) (car fields))))
                (string-split output #\newline))))

(define (spec->name spec)
  "Strip a version qualifier: \"python@3.11\" -> \"python\".
'guix package -I' lists the bare name, so a spec has to be reduced before it can
be compared against that listing."
  (let ((at (string-index spec #\@)))
    (if at (substring spec 0 at) spec)))

(define (ensure-packages! specs)
  "Install any of SPECS not already in the user profile.  Returns #t on success.

The user profile, not the system config: 'guix install' takes seconds and needs
no root, where a 'guix system reconfigure' takes minutes and, on a 1 GiB Oracle
micro instance, leans on the swap file.  Making the machine able to fetch the
user's config should not require rebuilding the system.  Anything that ought to
survive into the system closure belongs in the user's own config repository,
which is exactly what this script is about to clone."
  (let* ((present (installed-packages))
         (missing (remove (lambda (spec)
                            (member (spec->name spec) present))
                          specs)))
    (cond
     ((null? missing)
      (info (format #f "Already installed: ~a" (string-join specs " ")))
      #t)
     (else
      (info (format #f "Installing: ~a" (string-join missing " ")))
      (let ((result (run (format #f "guix install ~a" (string-join missing " ")))))
        (ensure-profile-on-path!)
        (unless result
          (err "guix install failed.")
          (info "If this machine has just booted, check network and DNS first:")
          (info "  ping -c1 ci.guix.gnu.org"))
        result)))))


;;;
;;; Settings cache.
;;;
;;; Re-running this script is normal -- a step fails, the user fixes something,
;;; they run it again.  Retyping the repository URL each time is the kind of
;;; friction that makes people stop using a tool, so the answers are cached.

(define (settings-file)
  (string-append (home) "/.config/guix-personal/settings.scm"))

(define (load-settings)
  "Read the cached answers, returning an alist (possibly empty)."
  (let ((file (settings-file)))
    (if (file-exists? file)
        (catch #t
          (lambda ()
            (call-with-input-file file
              (lambda (port)
                (let ((form (read port)))
                  (if (and (pair? form) (eq? (car form) 'settings))
                      (cdr form)
                      '())))))
          (lambda _ '()))
        '())))

(define (save-settings! alist)
  "Persist ALIST to the settings file."
  (mkdir-p (dirname (settings-file)))
  (call-with-output-file (settings-file)
    (lambda (port)
      (format port ";;; Written by personal-config.scm.  Safe to edit or delete.\n")
      (format port "(settings\n")
      (for-each (lambda (pair)
                  (format port "  (~a . ~s)\n" (car pair) (cdr pair)))
                alist)
      (format port "  )\n"))))

(define (setting alist key default)
  (let ((pair (assq key alist)))
    (if pair (cdr pair) default)))


;;;
;;; The contract.
;;;
;;; See docs/PERSONAL_CONFIG_CONTRACT.md.  The parser is strict about unknown
;;; keys on purpose: the failure mode of a lenient parser is a typo'd clause
;;; being silently dropped, so the user's carefully declared step never runs and
;;; nothing says why.

(define %contract-file-names
  '("guix-personal.scm" ".guix-personal.scm"))

(define %contract-keys
  '(version name description requires channels steps notes))

(define %step-keys
  '(name run description default? working-directory))

(define (contract-error fmt . args)
  (throw 'contract-error (apply format #f fmt args)))

(define (find-contract-file repo-dir)
  "Return the path of the contract file inside REPO-DIR, or #f."
  (find file-exists?
        (map (lambda (name) (string-append repo-dir "/" name))
             %contract-file-names)))

(define (parse-step form)
  "Parse one (step ...) clause into an alist."
  (match form
    (('step clauses ...)
     (let ((alist (map (lambda (clause)
                         (match clause
                           ((key value)
                            (unless (memq key %step-keys)
                              (contract-error
                               "unknown step key '~a' (expected one of: ~a)"
                               key (string-join (map symbol->string %step-keys) ", ")))
                            (cons key value))
                           (_ (contract-error "malformed step clause: ~s" clause))))
                       clauses)))
       (unless (assq 'name alist)
         (contract-error "step is missing (name ...)"))
       (unless (assq 'run alist)
         (contract-error "step '~a' is missing (run ...)" (cdr (assq 'name alist))))
       (for-each (lambda (key)
                   (let ((pair (assq key alist)))
                     (when (and pair (not (string? (cdr pair))))
                       (contract-error "step ~a must be a string, got ~s"
                                       key (cdr pair)))))
                 '(name run description working-directory))
       alist))
    (_ (contract-error "expected a (step ...) form, got: ~s" form))))

(define (parse-clause clause)
  "Parse one top-level contract clause into a (key . value) pair."
  (match clause
    (('requires specs ...)
     (for-each (lambda (spec)
                 (unless (string? spec)
                   (contract-error "requires takes package name strings, got ~s" spec)))
               specs)
     (cons 'requires specs))
    (('steps steps ...)
     (cons 'steps (map parse-step steps)))
    ((key value)
     (unless (memq key %contract-keys)
       (contract-error "unknown key '~a' (expected one of: ~a)"
                       key (string-join (map symbol->string %contract-keys) ", ")))
     (cons key value))
    (_ (contract-error "malformed clause: ~s" clause))))

(define (parse-contract form)
  "Parse and validate a (personal-config ...) FORM into an alist."
  (match form
    (('personal-config clauses ...)
     (let ((alist (map parse-clause clauses)))
       (let ((version (assq 'version alist)))
         (unless version
           (contract-error "missing (version 1)"))
         (unless (equal? (cdr version) 1)
           (contract-error "unsupported version ~s (this tool understands version 1)"
                           (cdr version))))
       (let* ((steps (setting alist 'steps '()))
              (names (map (lambda (step) (cdr (assq 'name step))) steps)))
         (when (null? steps)
           (contract-error "no (steps ...) declared -- there would be nothing to run"))
         (unless (= (length names) (length (delete-duplicates names)))
           (contract-error "duplicate step names: ~a" (string-join names ", "))))
       alist))
    (_ (contract-error
        "file does not contain a (personal-config ...) form (found: ~s)"
        (if (pair? form) (car form) form)))))

(define (read-contract file)
  "Read and validate the contract in FILE.  Throws 'contract-error on any fault."
  (let ((form (catch #t
                (lambda () (call-with-input-file file read))
                (lambda (key . args)
                  (contract-error "cannot read ~a: ~a" file args)))))
    (when (eof-object? form)
      (contract-error "~a is empty" file))
    (parse-contract form)))

(define (default-step? step)
  (eq? #t (setting step 'default? #f)))

(define (describe-contract contract file)
  "Print the plan a contract declares, before anything is run."
  (msg (format #f "Personal configuration: ~a" (setting contract 'name "(unnamed)")))
  (info (format #f "Contract: ~a" file))
  (let ((description (setting contract 'description #f)))
    (when description (info description)))
  (let ((requires (setting contract 'requires '())))
    (unless (null? requires)
      (info (format #f "Requires: ~a" (string-join requires " ")))))
  (let ((channels (setting contract 'channels #f)))
    (when channels (info (format #f "Channels: ~a" channels))))
  (newline)
  (info "Steps:")
  (for-each (lambda (step)
              (format #t "    ~a ~a\n"
                      (if (default-step? step) "[default]" "[  opt  ]")
                      (setting step 'name "?"))
              (let ((description (setting step 'description #f)))
                (when description (format #t "              ~a\n" description)))
              (format #t "              $ ~a\n" (setting step 'run "")))
            (setting contract 'steps '()))
  (let ((notes (setting contract 'notes #f)))
    (when notes
      (newline)
      (info (format #f "Notes: ~a" notes)))))


;;;
;;; Running a contract.
;;;

(define (run-step step repo-dir)
  "Run one STEP inside REPO-DIR.  Returns #t on success."
  (let* ((name (setting step 'name "?"))
         (command (setting step 'run ""))
         (subdir (setting step 'working-directory #f))
         (cwd (if subdir (string-append repo-dir "/" subdir) repo-dir)))
    (msg (format #f "Step: ~a" name))
    (let ((description (setting step 'description #f)))
      (when description (info description)))
    (let ((result (run (format #f "cd ~s && ~a" cwd command))))
      (if result
          (ok (format #f "Step '~a' finished" name))
          (err (format #f "Step '~a' failed" name)))
      result)))

(define (install-channels! repo-dir relative-path)
  "Copy the repository's channels file to ~/.config/guix/channels.scm.

A personal channels.scm is the difference between 'guix pull' giving the user
the packages they expect and giving them plain upstream Guix.  It is offered
rather than applied: a channels file changes what every later 'guix pull'
resolves to, which is too big a consequence to take silently."
  (let ((source (string-append repo-dir "/" relative-path))
        (target (string-append (home) "/.config/guix/channels.scm")))
    (cond
     ((not (file-exists? source))
      (warn (format #f "Contract declares channels ~s but that file is not in the repository"
                    relative-path))
      #f)
     ((and (file-exists? target)
           (not (ask-yes? (format #f "~a already exists.  Overwrite it?" target) #f)))
      (info "Keeping the existing channels.scm.")
      #f)
     (else
      (mkdir-p (dirname target))
      (and (run (format #f "cp ~s ~s" source target))
           (begin
             (ok (format #f "Installed ~a" target))
             (info "Run 'guix pull' to apply it (this takes a while).")
             #t))))))

(define (apply-contract! contract file repo-dir)
  "Show the contract's plan, then run the steps the user approves."
  (describe-contract contract file)
  (newline)
  (unless (ask-yes? "Proceed with this plan?" #t)
    (info "Nothing run.  The repository is cloned; you can run the steps yourself.")
    (exit 0))

  (let ((requires (setting contract 'requires '())))
    (unless (null? requires)
      (msg "Installing what the steps need")
      (unless (ensure-packages! requires)
        (err "Could not install the required packages; steps would fail.")
        (exit 1))))

  (let ((channels (setting contract 'channels #f)))
    (when (and channels
               (ask-yes? (format #f "Install ~a as your channels.scm?" channels) #t))
      (install-channels! repo-dir channels)))

  (let* ((steps (setting contract 'steps '()))
         (results (map (lambda (step)
                         (let ((wanted (if (default-step? step)
                                           (ask-yes? (format #f "Run step '~a'?"
                                                             (setting step 'name "?"))
                                                     #t)
                                           (ask-yes? (format #f "Run optional step '~a'?"
                                                             (setting step 'name "?"))
                                                     #f))))
                           (if wanted
                               (cons (setting step 'name "?") (run-step step repo-dir))
                               (cons (setting step 'name "?") 'skipped))))
                       steps)))
    (newline)
    (msg "Summary")
    (for-each (lambda (result)
                (info (format #f "~a: ~a"
                              (car result)
                              (cond ((eq? (cdr result) 'skipped) "skipped")
                                    ((cdr result) "ok")
                                    (else "FAILED")))))
              results)
    (let ((notes (setting contract 'notes #f)))
      (when notes
        (newline)
        (info notes)))
    (if (any (lambda (result) (eq? (cdr result) #f)) results)
        (begin (err "Some steps failed.  Fix them and re-run this script.") #f)
        (begin (ok "Personal configuration applied.") #t))))


;;;
;;; No contract: fall back to detection.
;;;
;;; A user who has not prepared a contract yet should still get somewhere, and
;;; should be told exactly what they could write so the next machine is one
;;; command.  Detection is a courtesy; the contract is the standard.

(define %detectable
  ;; (file-in-repo . suggested-command)
  '(("Makefile"                . "make")
    ("makefile"                . "make")
    ("bootstrap.sh"            . "./bootstrap.sh")
    ("install.sh"              . "./install.sh")
    ("setup.sh"                . "./setup.sh")
    ("home-configuration.scm"  . "guix home reconfigure home-configuration.scm")))

(define (detect-entry-points repo-dir)
  "Return a list of (file . command) pairs that look like entry points."
  (filter (lambda (candidate)
            (file-exists? (string-append repo-dir "/" (car candidate))))
          %detectable))

(define (make-targets repo-dir)
  "Return the .PHONY target names declared in REPO-DIR's Makefile.

Reading .PHONY rather than every rule is deliberate: the phony targets are the
ones a human is meant to type, and the full rule list of a real Makefile is
mostly file paths."
  (let ((makefile (string-append repo-dir "/Makefile")))
    (if (not (file-exists? makefile))
        '()
        (let ((lines (string-split (call-with-input-file makefile get-string-all)
                                   #\newline)))
          (delete-duplicates
           (append-map (lambda (line)
                         (if (string-prefix? ".PHONY:" (string-trim line))
                             (string-tokenize (substring (string-trim line) 7))
                             '()))
                       lines))))))

(define (offer-detected-entry-points repo-dir)
  "Offer to run something sensible when the repository declares no contract."
  (let ((found (detect-entry-points repo-dir))
        (targets (make-targets repo-dir)))
    (warn (format #f "No contract file in ~a" repo-dir))
    (info (format #f "Looked for: ~a" (string-join %contract-file-names ", ")))
    (newline)
    (info "A contract makes this step one command on the next machine.")
    (info "See docs/PERSONAL_CONFIG_CONTRACT.md, or run this script with --init")
    (info (format #f "inside ~a to write a starter one." repo-dir))
    (newline)
    (cond
     ((null? found)
      (info "Nothing recognisable to run either.  The repository is cloned at:")
      (info repo-dir)
      #f)
     (else
      (info "Found, in the repository:")
      (for-each (lambda (candidate)
                  (info (format #f "  ~a  ->  ~a" (car candidate) (cdr candidate))))
                found)
      (unless (null? targets)
        (info (format #f "  Makefile targets: ~a" (string-join targets " "))))
      (newline)
      (let ((command (ask "Command to run now (empty to skip)"
                          (cdr (car found)))))
        (if (string-null? command)
            (begin (info "Skipped.") #f)
            (begin
              (ensure-packages! '("gnu-make"))
              (run (format #f "cd ~s && ~a" repo-dir command)))))))))


;;;
;;; --init: write a starter contract.
;;;

(define (wrap-words words width)
  "Fold WORDS into lines of at most WIDTH characters.  A real Makefile declares
enough phony targets to produce an unreadable single line otherwise."
  (let loop ((remaining words) (current "") (lines '()))
    (cond
     ((null? remaining)
      (reverse (if (string-null? current) lines (cons current lines))))
     ((string-null? current)
      (loop (cdr remaining) (car remaining) lines))
     ((<= (+ (string-length current) 1 (string-length (car remaining))) width)
      (loop (cdr remaining) (string-append current " " (car remaining)) lines))
     (else
      (loop (cdr remaining) (car remaining) (cons current lines))))))

(define (starter-contract repo-dir)
  "Return the text of a starter contract, pre-filled from what REPO-DIR contains."
  (let* ((targets (make-targets repo-dir))
         (has-make? (file-exists? (string-append repo-dir "/Makefile")))
         (has-channels? (file-exists? (string-append repo-dir "/channels.scm"))))
    (string-append
     ";;; guix-personal.scm -- how to apply this repository to a fresh machine.\n"
     ";;;\n"
     ";;; Read by guix-platform-install's postinstall step:\n"
     ";;;   postinstall/recipes/add/personal-config.scm\n"
     ";;; Format: docs/PERSONAL_CONFIG_CONTRACT.md\n"
     ";;;\n"
     ";;; Generated by --init from what was in this repository.  Edit freely:\n"
     ";;; the generator can only guess, and a wrong guess here runs a wrong\n"
     ";;; command on a new machine.\n"
     "\n"
     "(personal-config\n"
     "  (version 1)\n"
     "  (name \"" (basename repo-dir) "\")\n"
     "  (description \"Personal configuration\")\n"
     "\n"
     "  ;; Installed into the user profile before any step runs.  A fresh Guix\n"
     "  ;; system has none of these.\n"
     "  (requires \"git\"" (if has-make? " \"gnu-make\"" "") ")\n"
     "\n"
     (if has-channels?
         (string-append
          "  ;; Copied to ~/.config/guix/channels.scm, with confirmation.\n"
          "  (channels \"channels.scm\")\n\n")
         "  ;; (channels \"channels.scm\")\n\n")
     (if (and has-make? (pair? targets))
         (string-append
          "  ;; Targets this Makefile declares, for reference while editing:\n"
          (string-concatenate
           (map (lambda (line) (string-append "  ;;   " line "\n"))
                (wrap-words targets 60))))
         "")
     "  (steps\n"
     (if (and has-make? (pair? targets))
         (string-append
          "    (step (name \"" (car targets) "\")\n"
          "          (run \"make " (car targets) "\")\n"
          "          (description \"EDIT ME: what this does\")\n"
          "          (default? #t)))\n")
         (string-append
          "    (step (name \"install\")\n"
          "          (run \"EDIT ME\")\n"
          "          (description \"EDIT ME: what this does\")\n"
          "          (default? #t)))\n"))
     "\n"
     "  (notes \"EDIT ME: anything the user must do by hand afterwards.\"))\n")))

(define (init-contract! repo-dir)
  "Write a starter contract into REPO-DIR.  Refuses to overwrite an existing one."
  (let ((existing (find-contract-file repo-dir)))
    (cond
     (existing
      (err (format #f "~a already exists; refusing to overwrite it." existing))
      #f)
     ((not (file-exists? repo-dir))
      (err (format #f "No such directory: ~a" repo-dir))
      #f)
     (else
      (let ((target (string-append repo-dir "/guix-personal.scm")))
        (call-with-output-file target
          (lambda (port) (display (starter-contract repo-dir) port)))
        (ok (format #f "Wrote ~a" target))
        (info "Edit it, commit it, and the next machine is one command.")
        (info "Check it with:  guile -s personal-config.scm --validate guix-personal.scm")
        #t)))))


;;;
;;; Git: identity, keys, clone.
;;;

(define (git-config-get key)
  "Return the global git config value for KEY, or #f."
  (let ((value (string-trim-both
                (capture (format #f "git config --global --get ~a 2>/dev/null" key)))))
    (if (string-null? value) #f value)))

(define (ensure-git-identity!)
  "Make sure git has a name and email.

Not cosmetic: 'git commit' refuses to run without them, and a user who clones
their config on a new machine will commit from it.  Discovering that at the
first commit, rather than now, costs a round trip."
  (msg "Git identity")
  (let ((name (git-config-get "user.name"))
        (email (git-config-get "user.email")))
    (if (and name email)
        (info (format #f "Already set: ~a <~a>" name email))
        (let ((new-name (ask "Your name for git commits" (or name "")))
              (new-email (ask "Your email for git commits" (or email ""))))
          (unless (string-null? new-name)
            (run (format #f "git config --global user.name ~s" new-name)))
          (unless (string-null? new-email)
            (run (format #f "git config --global user.email ~s" new-email)))))))

(define (ssh-url? url)
  "Is URL an SSH remote?  Covers both scp-style (git@host:path) and ssh://."
  (or (string-prefix? "ssh://" url)
      (and (string-index url #\@)
           (string-index url #\:)
           (not (string-prefix? "http" url)))))

(define (first-index string . chars)
  "Index of the EARLIEST of CHARS in STRING, or #f if none occur.

Not (or (string-index s a) (string-index s b)): 'or' yields the first index that
exists, not the smallest.  For ssh://git@host:2222/path that returns the slash,
and the host comes back as \"host:2222\" -- which ssh-keyscan cannot resolve."
  (let ((indices (filter-map (lambda (char) (string-index string char)) chars)))
    (if (null? indices) #f (apply min indices))))

(define (url-host url)
  "Extract the host from a git URL, or #f."
  (cond
   ((string-prefix? "ssh://" url)
    (let* ((rest (substring url 6))
           (at (string-index rest #\@))
           (after-user (if at (substring rest (+ at 1)) rest))
           (end (first-index after-user #\/ #\:)))
      (if end (substring after-user 0 end) after-user)))
   ((string-index url #\@)
    (let* ((at (string-index url #\@))
           (rest (substring url (+ at 1)))
           (colon (string-index rest #\:)))
      (if colon (substring rest 0 colon) rest)))
   (else #f)))

;; GitHub's published SSH host key fingerprints, from
;; https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
;; Checked against ssh-keyscan output so the first connection is not blind
;; trust-on-first-use.  A mismatch is reported rather than fatal: GitHub has
;; rotated a host key before (the RSA key, March 2023), and a stale constant
;; here must not become a machine nobody can bootstrap.
(define %known-host-fingerprints
  '(("github.com"
     "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"   ; ed25519
     "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"   ; rsa
     "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"))) ; ecdsa

(define (host-already-known? host)
  (let ((known-hosts (string-append (home) "/.ssh/known_hosts")))
    (and (file-exists? known-hosts)
         (not (string-null?
               (capture (format #f "ssh-keygen -F ~s -f ~s 2>/dev/null"
                                host known-hosts)))))))

(define (add-known-host! host)
  "Add HOST's key to known_hosts, verifying the fingerprint where we can."
  (if (host-already-known? host)
      (begin (info (format #f "~a is already in known_hosts" host)) #t)
      (let* ((ssh-dir (string-append (home) "/.ssh"))
             (known-hosts (string-append ssh-dir "/known_hosts"))
             (scanned (capture (format #f "ssh-keyscan -t rsa,ecdsa,ed25519 ~s 2>/dev/null" host))))
        (cond
         ((string-null? scanned)
          (err (format #f "Could not reach ~a to fetch its host key." host))
          #f)
         (else
          (mkdir-p ssh-dir)
          (chmod ssh-dir #o700)
          ;; Fingerprint every scanned key, then compare against the published
          ;; list for hosts we ship fingerprints for.
          (let* ((tmp (string-append "/tmp/keyscan-" (number->string (getpid))))
                 (_ (call-with-output-file tmp
                      (lambda (port) (display scanned port))))
                 (fingerprints (capture (format #f "ssh-keygen -lf ~s 2>/dev/null" tmp)))
                 (expected (assoc host %known-host-fingerprints))
                 (matched? (and expected
                                (any (lambda (fingerprint)
                                       (string-contains fingerprints fingerprint))
                                     (cdr expected)))))
            (delete-file tmp)
            (info "Host key fingerprints offered by the server:")
            (for-each (lambda (line)
                        (unless (string-null? (string-trim line))
                          (info (string-append "  " line))))
                      (string-split fingerprints #\newline))
            (cond
             (matched?
              (ok (format #f "Fingerprint matches the published key for ~a" host)))
             (expected
              (warn (format #f "Fingerprint does NOT match the published keys for ~a." host))
              (info "This tool's copy may simply be out of date -- GitHub last")
              (info "rotated a host key in March 2023.  Compare the fingerprints")
              (info "above against the host's own documentation before accepting."))
             (else
              (info (format #f "No published fingerprints on file for ~a." host))
              (info "Verify the fingerprints above out-of-band before accepting.")))
            (if (ask-yes? (format #f "Add ~a to known_hosts?" host) matched?)
                (begin
                  (let ((port (open-file known-hosts "a")))
                    (display scanned port)
                    (close-port port))
                  (chmod known-hosts #o600)
                  (ok (format #f "~a added to known_hosts" host))
                  #t)
                (begin (info "Not added; an SSH clone will fail.") #f))))))))

(define (ensure-ssh-key! host)
  "Make sure an SSH key exists and the user has had a chance to register it.

A freshly installed machine has no key any forge will accept, which is the one
step in this whole flow that cannot be automated: it needs a human to paste a
public key into a web page.  So the script stops here and waits, rather than
failing at 'git clone' with 'Permission denied (publickey)' and leaving the
user to work out why."
  (let* ((ssh-dir (string-append (home) "/.ssh"))
         (key-file (string-append ssh-dir "/id_ed25519"))
         (public-key-file (string-append key-file ".pub")))
    (msg "SSH key")
    (unless (file-exists? key-file)
      (mkdir-p ssh-dir)
      (chmod ssh-dir #o700)
      (info "No key found; generating an ed25519 key with no passphrase.")
      (info "No passphrase because nothing can type one at boot on a headless")
      (info "machine.  If you want one, generate the key yourself and re-run.")
      (unless (run (format #f "ssh-keygen -t ed25519 -N '' -C ~s -f ~s"
                           (format #f "~a@~a"
                                   (or (getenv "USER") "guix")
                                   (string-trim-both (capture "hostname")))
                           key-file))
        (err "ssh-keygen failed.")
        (exit 1)))

    (newline)
    (info (format #f "Add this public key to your account on ~a:" host))
    (when (string=? host "github.com")
      (info "  https://github.com/settings/keys"))
    (newline)
    (display (call-with-input-file public-key-file get-string-all))
    (newline)
    (pause "Press Enter once the key is registered...")

    ;; Verify before cloning.  GitHub answers a successful 'ssh -T' with exit
    ;; status 1 and the words "successfully authenticated", so the exit status
    ;; alone cannot be the test.
    (let ((output (capture (format #f "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -T git@~a 2>&1" host))))
      (cond
       ((or (string-contains output "successfully authenticated")
            (string-contains output "You've successfully")
            (string-contains output "Welcome to GitLab"))
        (ok (format #f "Authenticated to ~a" host))
        #t)
       (else
        (warn (format #f "Could not confirm authentication to ~a." host))
        (info (string-trim-both output))
        (ask-yes? "Try the clone anyway?" #t))))))

(define (clone-repository! url target)
  "Clone URL into TARGET, or reuse TARGET if it is already a checkout."
  (msg "Cloning your configuration repository")
  (cond
   ((file-exists? (string-append target "/.git"))
    (info (format #f "~a is already a git checkout; leaving it alone." target))
    (when (ask-yes? "Pull the latest changes?" #t)
      (run (format #f "cd ~s && git pull --ff-only" target)))
    #t)
   ((file-exists? target)
    (err (format #f "~a exists and is not a git checkout." target))
    (info "Move it aside or choose another directory, then re-run.")
    #f)
   (else
    (run (format #f "git clone ~s ~s" url target)))))


;;;
;;; The interactive bootstrap.
;;;

(define (bootstrap!)
  (msg "Personal configuration bootstrap")
  (info "This installs git, fetches your own configuration repository, and")
  (info "runs whatever that repository says should run on a new machine.")
  (newline)
  (info "It changes your user profile and home directory.  It does not touch")
  (info "/etc/config.scm or reconfigure the system.")

  (ensure-profile-on-path!)

  (let* ((settings (load-settings))
         (default-url (setting settings 'url ""))
         (url (ask "Configuration repository URL" default-url)))
    (when (string-null? url)
      (err "No repository URL given; nothing to do.")
      (exit 1))

    (let* ((default-dir (setting settings 'directory
                                 (string-append
                                  (home) "/"
                                  (let ((base (basename url)))
                                    (if (string-suffix? ".git" base)
                                        (substring base 0 (- (string-length base) 4))
                                        base)))))
           (target (ask "Clone into" default-dir))
           (host (url-host url)))

      (save-settings! `((url . ,url) (directory . ,target)))

      ;; git first: everything below is a git operation.  openssh supplies
      ;; ssh-keygen, ssh-keyscan and the ssh binary git shells out to; none of
      ;; the three is in %base-packages.
      (msg "Installing git")
      (unless (ensure-packages! (if (ssh-url? url)
                                    '("git" "openssh")
                                    '("git")))
        (exit 1))

      (ensure-git-identity!)

      (when (ssh-url? url)
        (if host
            (begin (add-known-host! host) (ensure-ssh-key! host))
            (warn "Could not work out the host from the URL; skipping key setup.")))

      (unless (clone-repository! url target)
        (exit 1))

      (let ((contract-file (find-contract-file target)))
        (if contract-file
            (catch 'contract-error
              (lambda ()
                (let ((contract (read-contract contract-file)))
                  (if (apply-contract! contract contract-file target)
                      (exit 0)
                      (exit 1))))
              (lambda (key message)
                (err (format #f "Invalid contract in ~a" contract-file))
                (info message)
                (info "See docs/PERSONAL_CONFIG_CONTRACT.md")
                (exit 1)))
            (begin
              (offer-detected-entry-points target)
              (exit 0)))))))


;;;
;;; Entry point.
;;;

(define (validate-command file)
  (catch 'contract-error
    (lambda ()
      (let ((contract (read-contract file)))
        (describe-contract contract file)
        (newline)
        (ok "Contract is valid.")
        (exit 0)))
    (lambda (key message)
      (err (format #f "Invalid contract: ~a" file))
      (info message)
      (exit 1))))

(define (plan-command repo-dir)
  (let ((contract-file (find-contract-file repo-dir)))
    (if contract-file
        (validate-command contract-file)
        (begin
          (err (format #f "No contract file in ~a" repo-dir))
          (info (format #f "Looked for: ~a" (string-join %contract-file-names ", ")))
          (info "Write one with:  --init")
          (exit 1)))))

(define (self-test)
  "Check the pure helpers that URL handling and package probing depend on.

These are the functions with no visible failure mode: a wrong ssh-url? sends an
SSH remote down the HTTPS path and the clone fails with an authentication error
that points nowhere near the cause.  Cheap to assert, expensive to debug on a
machine reachable only by serial console."
  (let ((failures 0))
    (define (check name actual expected)
      (if (equal? actual expected)
          (format #t "  [OK]    ~a\n" name)
          (begin
            (set! failures (+ failures 1))
            (format #t "  [FAIL]  ~a: got ~s, want ~s\n" name actual expected))))

    (msg "Self-test: URL handling")
    (check "scp-style is ssh"
           (ssh-url? "git@github.com:durantschoon/dot_files.git") #t)
    (check "ssh:// is ssh"
           (ssh-url? "ssh://git@github.com/user/repo.git") #t)
    (check "https is not ssh"
           (ssh-url? "https://github.com/user/repo.git") #f)
    (check "https with port is not ssh"
           (ssh-url? "https://git.example.com:8443/user/repo.git") #f)
    (check "host from scp-style"
           (url-host "git@github.com:durantschoon/dot_files.git") "github.com")
    (check "host from ssh://"
           (url-host "ssh://git@gitlab.com/user/repo.git") "gitlab.com")
    (check "host from ssh:// with port"
           (url-host "ssh://git@git.example.com:2222/user/repo.git") "git.example.com")

    (msg "Self-test: package specs")
    (check "bare name" (spec->name "git") "git")
    (check "versioned spec" (spec->name "python@3.11") "python")

    (msg "Self-test: word wrapping")
    (check "wraps at width"
           (wrap-words '("aaa" "bbb" "ccc") 7) '("aaa bbb" "ccc"))
    (check "single long word survives"
           (wrap-words '("aaaaaaaaaa") 3) '("aaaaaaaaaa"))
    (check "empty list" (wrap-words '() 10) '())

    (newline)
    (if (zero? failures)
        (begin (ok "All self-tests passed.") (exit 0))
        (begin (err (format #f "~a self-test(s) failed." failures)) (exit 1)))))

(define (usage)
  (display "\
Usage: personal-config.scm [OPTION]

  (no arguments)      interactive bootstrap: install git, clone your
                      configuration repository, run what it declares
  --validate FILE     parse and check a contract file
  --plan DIR          show what an already-cloned repository would run
  --init [DIR]        write a starter guix-personal.scm (default: .)
  --self-test         check the pure helpers; no network, no side effects
  --help              this message

Contract format: docs/PERSONAL_CONFIG_CONTRACT.md
")
  (exit 0))

(define (main args)
  (match args
    ((_) (bootstrap!))
    ((_ "--help") (usage))
    ((_ "-h") (usage))
    ((_ "--validate" file) (validate-command file))
    ((_ "--plan" dir) (plan-command dir))
    ((_ "--self-test") (self-test))
    ((_ "--init") (exit (if (init-contract! (getcwd)) 0 1)))
    ((_ "--init" dir) (exit (if (init-contract! dir) 0 1)))
    (_ (err "Unrecognised arguments.")
       (usage))))

(main (command-line))
