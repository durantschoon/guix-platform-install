#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; preferences.scm --- set host name, timezone and login shell after first boot.
;;;
;;; oracle/image/oracle-image.scm bakes (host-name "guix-oracle") and
;;; (timezone "America/New_York") into the image.  That was fine while every
;;; user built their own image.  It stops being fine the moment ONE image is
;;; published for everyone -- you cannot bake a stranger's timezone.  So the
;;; preferences move out of the build and into first boot, which is here.
;;;
;;; Run it after your first SSH login.  It asks, it shows you what it will do,
;;; and it OFFERS to reconfigure.  It never reconfigures on its own: on the
;;; 1 GiB VM.Standard.E2.1.Micro that is slow and leans on the swap file, and
;;; you should choose when to spend that.
;;;
;;; See preferences_purpose.txt for why each decision is the way it is,
;;; including the user name, which is deliberately NOT settable here.
;;;
;;; ASCII only, and every ANSI escape is written "\x1b[".  Guile has no octal
;;; string escape, so writing that introducer with a leading octal 033 instead
;;; yields NUL followed by the two characters "33" -- garbage on screen rather
;;; than colour.  This output has to stay readable on the OCI serial console.

(use-modules (ice-9 format)
             (ice-9 rdelim)
             (ice-9 popen)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; ============================================================================
;;; Output
;;; ============================================================================

(define (say fmt . args) (apply format #t fmt args))

(define (info text)  (format #t "\x1b[0;34m[INFO]\x1b[0m  ~a\n" text))
(define (ok text)    (format #t "\x1b[0;32m[OK]\x1b[0m    ~a\n" text))
(define (warn text)  (format #t "\x1b[1;33m[WARN]\x1b[0m  ~a\n" text))
(define (oops text)  (format #t "\x1b[0;31m[ERROR]\x1b[0m ~a\n" text))

(define (heading text)
  (format #t "\n\x1b[1;34m~a\x1b[0m\n" text)
  (format #t "~a\n" (make-string (string-length text) #\-)))

(define (die text)
  (oops text)
  (exit 1))

;;; ============================================================================
;;; Prompting
;;; ============================================================================
;;;
;;; Every prompt reads /dev/tty, never stdin.  This script is documented as
;;; runnable from a pipe, and a pipe is exactly the case where stdin is the
;;; script's own text rather than the user.

(define tty-port #f)

(define (tty)
  (unless tty-port
    (set! tty-port
          (catch #t
            (lambda () (open-input-file "/dev/tty"))
            (lambda _ (die "cannot open /dev/tty; run this from a terminal")))))
  tty-port)

(define (ask prompt default)
  "Prompt for a line.  An empty answer keeps DEFAULT, so pressing Enter through
   the whole script is a safe no-op."
  (format #t "~a" prompt)
  (when default (format #t " [~a]" default))
  (format #t ": ")
  (force-output)
  (let ((line (read-line (tty))))
    (if (or (eof-object? line) (string-null? (string-trim-both line)))
        default
        (string-trim-both line))))

(define (yes? prompt)
  "Ask a yes/no question defaulting to NO.  Anything that is not an explicit
   yes is a no -- this script writes to /etc and offers a reconfigure, and
   neither should happen because someone hit Enter."
  (format #t "~a [y/N]: " prompt)
  (force-output)
  (let ((line (read-line (tty))))
    (and (string? line)
         (member (string-downcase (string-trim-both line)) '("y" "yes"))
         #t)))

;;; ============================================================================
;;; Running commands
;;; ============================================================================

(define (root?) (zero? (getuid)))

(define (run-command . args)
  (status:exit-val (apply system* args)))

(define (run-privileged . args)
  "Run ARGS via sudo unless we are already root.  The image gives wheel
   passwordless sudo precisely so this works over SSH with a key and no
   password."
  (if (root?)
      (apply run-command args)
      (apply run-command "sudo" args)))

(define (writable-target? path)
  "Can we write PATH without becoming root?  Either it exists and is writable,
   or it does not exist and its directory is."
  (if (file-exists? path)
      (access? path W_OK)
      (access? (dirname path) W_OK)))

(define (run-for-target path . args)
  "Run ARGS directly when PATH is already ours to write, via sudo otherwise.

   Same shape as postinstall/lib.scm, and for the same reason: /etc/config.scm
   needs root, a temp file under /tmp does not, and invoking sudo for the
   second one prompts for nothing.  It also means the whole apply path can be
   exercised against a fixture without privileges."
  (if (writable-target? path)
      (apply run-command args)
      (apply run-privileged args)))

(define (run-quietly command)
  "Run COMMAND through the shell, returning (STATUS . OUTPUT)."
  (let* ((port (open-input-pipe (string-append command " 2>&1")))
         (output (get-string-all port))
         (status (close-pipe port)))
    (cons (status:exit-val status) output)))

;;; ============================================================================
;;; Locating the config helper
;;; ============================================================================
;;;
;;; The S-expression editing lives in lib/guile-config-helper.scm, which already
;;; does parsed edits for add-service / switch-to-desktop.  It is not duplicated
;;; here, and it is emphatically not replaced by sed: a sed path was removed on
;;; 2026-08-03 in 954bb8b because it cannot tell a field from the same text in a
;;; comment, and the failure mode is a config that no longer parses on a machine
;;; reachable only by SSH.
;;;
;;; This does mean the repository has to be present.  Unlike
;;; postinstall/recipes/add/personal-config.scm, this script cannot be run
;;; straight from a pipe unless the helper is already on disk.

(define (script-directory)
  (let ((self (car (command-line))))
    (if (string-prefix? "/" self)
        (dirname self)
        (string-append (getcwd) "/" (dirname self)))))

(define (find-config-helper)
  (let* ((suffix "/lib/guile-config-helper.scm")
         (roots (filter string?
                        (list (getenv "GUIX_PLATFORM_INSTALL_ROOT")
                              (getenv "INSTALL_ROOT")
                              (string-append (script-directory) "/../..")
                              (getcwd)
                              (string-append (or (getenv "HOME") "/root")
                                             "/guix-platform-install")))))
    (find file-exists? (map (lambda (r) (string-append r suffix)) roots))))

;;; ============================================================================
;;; Locating the system configuration
;;; ============================================================================
;;;
;;; Do NOT assume /etc/config.scm exists.  An image built by `guix system image`
;;; ships the system, not the source that produced it, so on a freshly booted
;;; Oracle instance that file may simply not be there.
;;;
;;; What IS always there is the generation's own provenance:
;;;
;;;   /run/current-system/configuration.scm -> /gnu/store/...-configuration.scm
;;;
;;; That is a STORE path.  The store is read-only, so it has to be copied to
;;; /etc/config.scm and the copy made writable before anything can edit it.
;;; Editing it in place is not merely rude, it is impossible.

(define %config-file "/etc/config.scm")
(define %provenance-file "/run/current-system/configuration.scm")

(define (ensure-config-file)
  "Return the path to an editable system configuration, or die trying."
  (cond
   ((file-exists? %config-file)
    (info (string-append "Using the existing " %config-file))
    %config-file)

   ((file-exists? %provenance-file)
    (info (string-append "No " %config-file "; recovering it from "
                         %provenance-file))
    (unless (zero? (run-for-target %config-file
                                   "cp" "-L" %provenance-file %config-file))
      (die (string-append "failed to copy " %provenance-file " to "
                          %config-file)))
    ;; The store path is read-only (mode 444) and the copy inherits that, so
    ;; without this chmod every later write fails with EACCES on a file that
    ;; looks perfectly ordinary in `ls`.
    (unless (zero? (run-for-target %config-file "chmod" "644" %config-file))
      (die (string-append "failed to make " %config-file " writable")))
    (ok (string-append "Recovered " %config-file
                       " from the current system generation"))
    %config-file)

   (else
    ;; Inventing a config here would be worse than failing.  A generated
    ;; approximation that omits, say, the swap file service or the serial
    ;; console arguments produces a machine that reconfigures successfully and
    ;; then cannot be reached.
    (oops "Cannot find a system configuration to edit.")
    (oops (string-append "Neither " %config-file " nor " %provenance-file
                         " exists."))
    (oops "Refusing to invent one: a guessed config that drops the serial")
    (oops "console or the swap file service would reconfigure cleanly and")
    (oops "leave you with an instance you cannot log in to.")
    (exit 1))))

;;; ============================================================================
;;; Current values
;;; ============================================================================
;;;
;;; Read from the RUNNING system rather than parsed out of the config file.
;;; They are what the user actually experiences, and they stay correct even if
;;; the config expresses them through a variable -- oracle-image.scm writes
;;; (host-name %host-name), from which no useful default could be read.

(define (current-host-name)
  (catch #t (lambda () (gethostname)) (lambda _ "guix-oracle")))

(define (zoneinfo-directory)
  "Locate the tzdata zoneinfo tree.  On Guix /etc/localtime is a symlink into
   the store: /gnu/store/...-tzdata.../share/zoneinfo/America/New_York."
  (catch #t
    (lambda ()
      (let* ((target (readlink "/etc/localtime"))
             (marker "/zoneinfo/")
             (index (string-contains target marker)))
        (and index (substring target 0 (+ index (string-length marker) -1)))))
    (lambda _ #f)))

(define (current-timezone)
  (catch #t
    (lambda ()
      (let* ((target (readlink "/etc/localtime"))
             (marker "/zoneinfo/")
             (index (string-contains target marker)))
        (if index
            (substring target (+ index (string-length marker)))
            "America/New_York")))
    (lambda _ "America/New_York")))

(define (current-user-name)
  (or (getenv "USER")
      (getenv "LOGNAME")
      (catch #t
        (lambda () (passwd:name (getpwuid (getuid))))
        (lambda _ "guix"))))

(define (current-login-shell)
  (catch #t
    (lambda () (basename (passwd:shell (getpwuid (getuid)))))
    (lambda _ "bash")))

;;; ============================================================================
;;; Validation
;;; ============================================================================
;;;
;;; Checked here rather than discovered by `guix system reconfigure`, which on
;;; this instance size is a long wait for the news that you typed a slash in a
;;; host name.

(define (host-name-character? c)
  ;; RFC 1123, ASCII only.  char-alphabetic? would happily accept a non-ASCII
  ;; letter, which is the sort of host name that works until something else
  ;; reads it.
  (or (and (char>=? c #\a) (char<=? c #\z))
      (and (char>=? c #\A) (char<=? c #\Z))
      (and (char>=? c #\0) (char<=? c #\9))
      (char=? c #\-)))

(define (valid-host-name? name)
  (and (string? name)
       (> (string-length name) 0)
       (<= (string-length name) 63)
       (not (string-prefix? "-" name))
       (not (string-suffix? "-" name))
       (string-every host-name-character? name)))

(define (timezone-status tz)
  "One of 'valid, 'invalid or 'unchecked."
  (cond
   ((or (string-null? tz)
        (string-prefix? "/" tz)
        (string-contains tz ".."))
    'invalid)
   (else
    (let ((dir (zoneinfo-directory)))
      (cond ((not dir) 'unchecked)
            ((file-exists? (string-append dir "/" tz)) 'valid)
            (else 'invalid))))))

(define %shells '("bash" "zsh" "fish"))

;;; ============================================================================
;;; Asking
;;; ============================================================================

(define (ask-host-name default)
  (let loop ()
    (let ((answer (ask "Host name" default)))
      (if (valid-host-name? answer)
          answer
          (begin
            (warn "A host name may contain only ASCII letters, digits and")
            (warn "hyphens, may not start or end with a hyphen, and must be")
            (warn "1 to 63 characters long.")
            (loop))))))

(define (ask-timezone default)
  (let loop ()
    (let ((answer (ask "Timezone (Area/Location)" default)))
      (case (timezone-status answer)
        ((valid) answer)
        ((unchecked)
         (warn (string-append "Cannot verify \"" answer
                              "\" against the zoneinfo database; accepting it."))
         answer)
        (else
         (warn (string-append "\"" answer "\" is not a timezone on this system."))
         (warn "Examples: America/New_York, Europe/Berlin, Asia/Tokyo, UTC")
         (loop))))))

(define (ask-login-shell default)
  (say "Login shell. Choose one of: ~a\n" (string-join %shells ", "))
  (say "  bash is the default and needs nothing installed.\n")
  (say "  zsh and fish are added to the system packages as well, because a\n")
  (say "  shell that is not in the closure is a login that fails.\n")
  (let loop ()
    (let ((answer (string-downcase (ask "Shell" default))))
      (if (member answer %shells)
          answer
          (begin
            (warn (string-append "\"" answer "\" is not one of: "
                                 (string-join %shells ", ")))
            (loop))))))

;;; ============================================================================
;;; Applying
;;; ============================================================================
;;;
;;; Never edit the config in place.  The edits are applied to a temporary copy
;;; and written back only once every one of them has succeeded, exactly as
;;; call-guile-helper in postinstall/lib.scm does.  A half-edited
;;; /etc/config.scm on a machine reachable only by SSH is a very bad afternoon.

(define (make-temp-copy config-file)
  (let* ((template (string-copy "/tmp/guix-preferences-XXXXXX"))
         (port (mkstemp! template)))
    (close-port port)
    (if (access? config-file R_OK)
        (unless (zero? (run-command "cp" config-file template))
          (die "failed to copy the configuration to a temporary file"))
        ;; Unreadable to us, so root has to do the copy -- and then hand the
        ;; result back, because the helper that edits it runs unprivileged.
        (begin
          (unless (zero? (run-privileged "cp" config-file template))
            (die "failed to copy the configuration to a temporary file"))
          (run-privileged "chown"
                          (string-append (number->string (getuid)) ":"
                                         (number->string (getgid)))
                          template)
          (run-privileged "chmod" "644" template)))
    template))

(define (backup-config config-file)
  "Timestamped backup beside the config.  Overwriting a user's configuration is
   ceremony, not a side effect, so there is always something to go back to."
  (let ((backup (string-append config-file ".BAK-"
                               (strftime "%Y%m%d-%H%M%S"
                                         (localtime (current-time))))))
    (if (zero? (run-for-target backup "cp" config-file backup))
        (begin (ok (string-append "Backed up the previous config to " backup))
               backup)
        (begin (warn "Could not write a backup of the configuration")
               #f))))

(define (apply-edit helper temp-file arguments description)
  "Run one helper subcommand against TEMP-FILE.  Returns #t on success."
  (let* ((command (string-join
                   (append (list "guile" "--no-auto-compile" "-s" helper)
                           arguments)
                   " "))
         (result (run-quietly command)))
    (if (zero? (car result))
        (begin (ok description) #t)
        (begin (oops (string-append description " -- FAILED"))
               (for-each (lambda (line) (say "        ~a\n" line))
                         (string-split (string-trim-right (cdr result)) #\newline))
               #f))))

(define (apply-preferences helper config-file user-name
                           host-name timezone shell)
  "Apply every requested change to a temp copy; write back only if all of them
   worked.  Returns #t if the configuration was updated."
  (let ((temp (make-temp-copy config-file)))
    (define (cleanup!)
      (when (file-exists? temp) (delete-file temp)))
    (let ((all-ok?
           (and (apply-edit helper temp
                            (list "set-host-name" temp host-name)
                            (string-append "Host name -> " host-name))
                (apply-edit helper temp
                            (list "set-timezone" temp timezone)
                            (string-append "Timezone -> " timezone))
                (apply-edit helper temp
                            (list "set-login-shell" temp user-name shell)
                            (string-append "Login shell -> " shell)))))
      (cond
       ((not all-ok?)
        (cleanup!)
        (oops "No changes were written; your configuration is untouched.")
        #f)
       (else
        (backup-config config-file)
        (if (zero? (run-for-target config-file "cp" temp config-file))
            (begin (cleanup!)
                   (ok (string-append "Wrote " config-file))
                   #t)
            (begin (cleanup!)
                   (oops (string-append "Failed to write " config-file))
                   #f)))))))

;;; ============================================================================
;;; The reconfigure OFFER
;;; ============================================================================
;;;
;;; Offered, never automatic.  On VM.Standard.E2.1.Micro (1 GiB) a reconfigure
;;; is slow and leans on the swap file that oracle-image.scm sets up, and the
;;; user is the one who knows whether now is a good time to lose the machine's
;;; attention for a while.  It is also the step that can break the boot, and a
;;; script that triggers that without being asked is a script nobody should
;;; run.

(define (offer-reconfigure config-file)
  (heading "Reconfigure")
  (say "Nothing has changed on the running system yet. The new values take\n")
  (say "effect when the system is reconfigured:\n\n")
  (say "    sudo guix system reconfigure ~a\n\n" config-file)
  (say "On a 1 GiB E2.1.Micro instance this is slow and will use the swap\n")
  (say "file. It is also the step that can break the boot -- if it does, the\n")
  (say "OCI serial console shows the GRUB menu and older generations are\n")
  (say "still there to boot.\n\n")
  (if (yes? "Run it now?")
      (let ((status (run-privileged "guix" "system" "reconfigure" config-file)))
        (if (zero? status)
            (begin
              (ok "Reconfigure finished.")
              (info "The host name and timezone are live now.")
              (info "A new login shell applies to your NEXT login."))
            (begin
              (oops (format #f "guix system reconfigure exited ~a" status))
              (info (string-append "Your configuration is still at " config-file))
              (info "and the previous generation is still bootable."))))
      (begin
        (info "Not reconfiguring. Run the command above whenever you like.")
        (info "Until then the running system keeps its current values."))))

;;; ============================================================================
;;; Help
;;; ============================================================================

(define (show-help)
  (say "Usage: guile --no-auto-compile -s preferences.scm [--help]\n")
  (newline)
  (say "Sets the host name, timezone and login shell of an Oracle Guix\n")
  (say "instance after first boot, by editing the system configuration and\n")
  (say "offering to reconfigure.\n")
  (newline)
  (say "Why can I not change the user name here?\n")
  (say "  Because renaming an account after first boot moves the home\n")
  (say "  directory, which orphans ~~/.ssh/authorized_keys -- the file the\n")
  (say "  metadata service wrote your key into. On an instance reachable only\n")
  (say "  by SSH that locks you out of the only account there is. The gain is\n")
  (say "  cosmetic and the loss is the machine, so it is left out on purpose.\n")
  (say "  If you want a differently named account, add a second user-account\n")
  (say "  to the configuration, give it your key, verify you can log in as it,\n")
  (say "  and only then remove the first.\n")
  (newline)
  (say "See preferences_purpose.txt for the rest of the reasoning.\n"))

;;; ============================================================================
;;; Main
;;; ============================================================================

(define (main args)
  (when (or (member "--help" args) (member "-h" args))
    (show-help)
    (exit 0))

  (heading "Oracle first boot: preferences")
  (say "The published image ships one host name and one timezone for\n")
  (say "everybody. This is where they become yours.\n\n")
  (say "Press Enter at any prompt to keep the value shown in brackets.\n")
  (say "The user name is deliberately not settable here; run with --help for\n")
  (say "why, and what to do instead.\n")

  (let ((helper (find-config-helper)))
    (unless helper
      (oops "Cannot find lib/guile-config-helper.scm.")
      (oops "This script edits the configuration by parsing it, not with sed,")
      (oops "so it needs the helper from this repository on disk. Clone it and")
      (oops "run from the clone, or point GUIX_PLATFORM_INSTALL_ROOT at it:")
      (oops "")
      (oops "  git clone https://github.com/durantschoon/guix-platform-install")
      (oops "  cd guix-platform-install")
      (oops "  guile --no-auto-compile -s oracle/postinstall/preferences.scm")
      (exit 1))
    (info (string-append "Config helper: " helper))

    (let* ((config-file (ensure-config-file))
           (user-name   (current-user-name)))
      (heading "Preferences")
      (let* ((host-name (ask-host-name (current-host-name)))
             (timezone  (ask-timezone (current-timezone)))
             (shell     (ask-login-shell (current-login-shell))))

        (heading "Review")
        (say "  Host name    : ~a\n" host-name)
        (say "  Timezone     : ~a\n" timezone)
        (say "  Login shell  : ~a\n" shell)
        (say "  Account      : ~a (not changed -- see --help)\n" user-name)
        (say "  Config file  : ~a\n\n" config-file)
        (say "Nothing has been written yet. A timestamped backup is taken\n")
        (say "before anything is.\n\n")

        (if (yes? (string-append "Apply these to " config-file "?"))
            (when (apply-preferences helper config-file user-name
                                     host-name timezone shell)
              (offer-reconfigure config-file))
            (info "Nothing written. Run this again whenever you like."))))))

(main (command-line))
