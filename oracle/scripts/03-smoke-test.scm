#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; 03-smoke-test.scm --- boot the built image in QEMU and prove SSH works.
;;;
;;; An hour of upload + import is a slow way to discover the image does
;;; not boot, so everything OCI will exercise is verified locally first:
;;;
;;;   - boots to a login prompt on the SERIAL console (what OCI's console
;;;     shows; also proves console=ttyS0)
;;;   - root filesystem mounts by its Guix_image label
;;;   - sshd accepts a key from authorized_keys and the login completes
;;;     for the locked-password account (guix:!: in shadow, UsePAM yes)
;;;   - passwordless sudo works
;;;
;;; Two traps this script exists to avoid (both cost real debugging time
;;; on 2026-08-08):
;;;
;;;   1. Do NOT test SSH with the user's own key: it is typically
;;;      passphrase-protected, and `ssh -o BatchMode=yes` then fails as
;;;      "Permission denied (publickey)" even though the server ACCEPTED
;;;      the key (sshd -ddd shows "Accepted key ... Postponed publickey"
;;;      and the CLIENT hanging up, unable to sign).  A fresh throwaway
;;;      key with no passphrase tests the same server path unambiguously.
;;;   2. The serial console is driven over TCP, not a unix socket: the
;;;      108-byte sun_path limit rejects socket paths in deep directories.
;;;
;;; The throwaway key is injected via the serial console into the COPY of
;;; the image the VM runs; the store image is never modified, so what is
;;; uploaded to OCI is exactly what was built.

(load (string-append (dirname (car (command-line))) "/oci-common.scm"))

(use-modules (ice-9 regex))

(define %serial-port 4555)
(define %ssh-port 2222)
(define %workdir (or (getenv "TMPDIR") "/tmp"))
(define %disk (string-append %workdir "/guix-oracle-smoke.qcow2"))
(define %pidfile (string-append %workdir "/guix-oracle-smoke.pid"))
(define %testkey (string-append %workdir "/guix-oracle-smoke-key"))

;;; ---------------------------------------------------------------------
;;; Serial console expect machinery (TCP)

(define (connect-serial)
  "Connect to QEMU's serial console; returns the socket port."
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (connect sock AF_INET (inet-pton AF_INET "127.0.0.1") %serial-port)
    sock))

(define (read-until sock pattern timeout-seconds)
  "Read from SOCK until regexp PATTERN matches the rolling tail or the
timeout elapses.  Returns #t on match, #f on timeout/EOF."
  (let ((deadline (+ (current-time) timeout-seconds)))
    (let loop ((buf ""))
      (cond
       ((string-match pattern buf) #t)
       ((> (current-time) deadline) #f)
       ((char-ready? sock)
        (let ((c (read-char sock)))
          (if (eof-object? c)
              #f
              (loop (string-append
                     ;; bounded tail so the buffer cannot grow unbounded
                     (if (> (string-length buf) 4000) (substring buf 2000) buf)
                     (string c))))))
       (else (usleep 100000) (loop buf))))))

(define (send-line sock line)
  "Send LINE plus carriage return (serial consoles want CR)."
  (display line sock)
  (display "\r" sock)
  (force-output sock))

(define (console-run sock command timeout-seconds)
  "Run COMMAND in the root shell on SOCK and wait for completion.
The sentinel is computed by the guest ($((41+1)) -> 42) so the echoed
command line itself can never match it.  Commands must not end in `&'
(the appended `;' would be a bash syntax error); background with
`... & true' instead."
  (send-line sock (string-append command " ; echo SENTINEL-$((41+1))"))
  (unless (read-until sock "SENTINEL-42" timeout-seconds)
    (die "console command timed out: " command)))

;;; ---------------------------------------------------------------------
;;; Steps

(define (prepare-disk image-path)
  "Copy the read-only store image to a writable scratch disk."
  (say "Copying image to writable scratch disk " %disk " ...")
  (run-command (string-append "cp " (sh-quote image-path) " " (sh-quote %disk)
                              " && chmod +w " (sh-quote %disk))))

(define (start-qemu)
  "Boot the scratch disk headless: serial on TCP, SSH forwarded."
  (unless (command-succeeds? "command -v qemu-system-x86_64")
    (die "qemu-system-x86_64 not found (guix install qemu, or add to your profile)"))
  (run-command
   (string-append
    "setsid qemu-system-x86_64 -m 2048"
    " -drive file=" %disk ",format=qcow2"
    " -display none"
    " -serial tcp:127.0.0.1:" (number->string %serial-port) ",server=on,wait=off"
    " -nic user,hostfwd=tcp:127.0.0.1:" (number->string %ssh-port) "-:22"
    " -pidfile " (sh-quote %pidfile)
    " </dev/null >/dev/null 2>&1 &"))
  (unless (poll-until "QEMU to start" (lambda () (file-exists? %pidfile)) 1 15)
    (die "QEMU did not start; rerun with the same command minus "
         "-display none to see why")))

(define (stop-qemu)
  (when (file-exists? %pidfile)
    (run-command (string-append "kill $(command cat " (sh-quote %pidfile) ") 2>/dev/null; true"))))

(define (wait-for-login-and-inject-key)
  "Wait for the serial login prompt, log in as root (no password is set
in the image), and install the throwaway key for the guix user."
  (run-command (string-append "rm -f " (sh-quote %testkey) " "
                              (sh-quote (string-append %testkey ".pub"))))
  (run-command (string-append "ssh-keygen -q -t ed25519 -N '' -C smoke-test -f "
                              (sh-quote %testkey)))
  (let ((sock (connect-serial)))
    (send-line sock "")
    (unless (read-until sock "login:" 120)
      (stop-qemu)
      (die "no login prompt on the serial console within 120s -- "
           "the image likely does not boot; inspect by rerunning QEMU "
           "without -display none"))
    (say "[OK] serial console login prompt (validates console=ttyS0)")
    (send-line sock "root")
    (unless (read-until sock "# " 20)
      (stop-qemu)
      (die "no root shell after console login"))
    (let ((pubkey (run-command (string-append "command cat "
                                              (sh-quote (string-append %testkey ".pub"))))))
      (console-run sock
                   (string-append
                    "install -d -m 700 -o guix -g users /home/guix/.ssh"
                    " && echo " (sh-quote pubkey) " > /home/guix/.ssh/authorized_keys"
                    " && chown guix:users /home/guix/.ssh/authorized_keys"
                    " && chmod 600 /home/guix/.ssh/authorized_keys")
                   30)
      (say "[OK] throwaway key injected via serial console"))
    (close-port sock)))

(define (verify-ssh)
  "Prove a full SSH login and passwordless sudo with the throwaway key."
  (let ((ssh-base (string-append
                   "ssh -p " (number->string %ssh-port)
                   " -i " (sh-quote %testkey)
                   " -o BatchMode=yes -o StrictHostKeyChecking=no"
                   " -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
                   " guix@127.0.0.1 ")))
    (unless (poll-until "SSH login with injected key"
                        (lambda ()
                          (command-succeeds? (string-append ssh-base "true")))
                        5 90)
      (stop-qemu)
      (die "SSH login failed. Server-side diagnosis: rerun QEMU, log in as "
           "root on the serial console, `herd stop ssh-daemon`, then run "
           "sshd -ddd from the store openssh and read its log."))
    (say "[OK] SSH key-only login works")
    (if (command-succeeds? (string-append ssh-base "'sudo -n true'"))
        (say "[OK] passwordless sudo works")
        (begin (stop-qemu)
               (die "sudo -n failed for the guix user")))
    (say "Guest facts: "
         (run-command (string-append ssh-base "'uname -sr; swapon --noheadings --show=NAME,SIZE'")))))

(define (main)
  (let ((image-path
         (if (> (length (command-line)) 1)
             (cadr (command-line))
             (let ((from-log (run-command
                              "command grep -o '/gnu/store/[a-z0-9]*-image.qcow2' $HOME/oracle-image-build.log 2>/dev/null | command tail -1")))
               (if (string-null? from-log)
                   (die "usage: 03-smoke-test.scm /gnu/store/...-image.qcow2 "
                        "(or run 02-build-image.scm first)")
                   from-log)))))
    (unless (file-exists? image-path)
      (die image-path " does not exist"))
    (say "Smoke-testing " image-path)
    (prepare-disk image-path)
    (start-qemu)
    (wait-for-login-and-inject-key)
    (verify-ssh)
    (stop-qemu)
    (run-command (string-append "rm -f " (sh-quote %disk)))
    (say "")
    (say "[OK] smoke test PASSED -- the image is safe to upload")))

(main)
