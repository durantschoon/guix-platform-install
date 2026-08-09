#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; 02-build-image.scm --- build the Oracle QCOW2 image locally.
;;;
;;; Wraps `guix system image -t qcow2 --image-size=50G` with the three
;;; operational lessons from the first successful build (2026-08-08):
;;;
;;;   1. A pty is REQUIRED.  Redirecting output to a file kills the
;;;      progress reporter with "terminal-window-size: Inappropriate
;;;      ioctl for device" before the build starts, so the build runs
;;;      under script(1).
;;;   2. The build is detached with setsid so it survives the invoking
;;;      terminal or session dying.  Guix caches every completed
;;;      derivation, so an interrupted build resumes on rerun; the two
;;;      failures that preceded the first success were both killed
;;;      sessions, not build errors.
;;;   3. The SSH public key must exist at oracle/image/authorized-key.pub
;;;      BEFORE evaluation -- it is baked into the image and is the only
;;;      way in (password auth is off by design).
;;;
;;; Prints the resulting /gnu/store/...qcow2 path on success.

(load (string-append (dirname (car (command-line))) "/oci-common.scm"))

(define %script-dir
  (dirname (car (command-line))))

(define %oracle-dir
  ;; oracle/scripts -> oracle
  (dirname %script-dir))

(define %image-scm (string-append %oracle-dir "/image/oracle-image.scm"))
(define %authorized-key (string-append %oracle-dir "/image/authorized-key.pub"))
(define %build-log (home-path "oracle-image-build.log"))

(define (ensure-authorized-key)
  "Make sure the baked-in SSH public key exists, offering ~/.ssh/*.pub."
  (if (file-exists? %authorized-key)
      (say "[OK] authorized key present: "
           (run-command (string-append "command cut -d' ' -f1,3 " (sh-quote %authorized-key))))
      (let ((candidates (run-command "ls $HOME/.ssh/*.pub 2>/dev/null")))
        (when (string-null? candidates)
          (die "no key at " %authorized-key " and no ~/.ssh/*.pub to offer. "
               "Generate one (ssh-keygen -t ed25519) and rerun."))
        (say "The image bakes in one SSH public key; it is the only way in.")
        (say "Found public keys:")
        (for-each (lambda (k) (say "  " k))
                  (string-split candidates #\newline))
        (let ((choice (prompt-tty "Path of the PUBLIC key to bake in:")))
          (unless (and (file-exists? choice)
                       (string-suffix? ".pub" choice))
            (die choice " does not exist or is not a .pub file"))
          (run-command (string-append "cp " (sh-quote choice) " "
                                      (sh-quote %authorized-key)))
          (say "[OK] copied to " %authorized-key
               " (gitignored; never committed)")))))

(define (existing-image-path)
  "If the image was already built, `guix system image` returns the
cached store path in seconds.  Returns the path or #f."
  (let ((last (run-command
               (string-append "command grep -o '/gnu/store/[a-z0-9]*-image.qcow2' "
                              (sh-quote %build-log) " 2>/dev/null | command tail -1"))))
    (and (not (string-null? last))
         (file-exists? last)
         last)))

(define (main)
  (unless (file-exists? %image-scm)
    (die "cannot find " %image-scm " -- run from a checkout of this repo"))
  (ensure-authorized-key)
  (let ((cached (existing-image-path)))
    (when cached
      (say "[OK] previous build found: " cached)
      (unless (prompt-yes? "Rebuild anyway (config changes need this)?")
        (say cached)
        (exit 0))))
  (say "Starting detached build; progress log: " %build-log)
  (say "This survives closing the terminal.  Watch with: tail -f " %build-log)
  ;; setsid detaches from this session; script(1) provides the pty.
  (run-command
   (string-append "setsid script -qec "
                  (sh-quote (string-append
                             "guix system image -t qcow2 --image-size=50G "
                             %image-scm))
                  " " (sh-quote %build-log)
                  " </dev/null >/dev/null 2>&1 &"))
  (if (poll-until "image build (first build can take an hour)"
                  (lambda () (existing-image-path))
                  30 7200)
      (let ((path (existing-image-path)))
        (say "[OK] image built:")
        (say path))
      (die "no image path in " %build-log " after 2 hours; "
           "check the log and rerun (the build resumes from cache)")))

(main)
