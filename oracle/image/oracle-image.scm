;;; Guix System image for Oracle Cloud Infrastructure (OCI) Always Free tier.
;;;
;;; Unlike every other platform in this repository, OCI cannot boot an ISO, so
;;; there is no "boot the installer, partition, guix system init" flow here.
;;; Instead this file is built into a disk image locally and uploaded.
;;;
;;; Build:
;;;
;;;   guix system image -t qcow2 --image-size=50G \
;;;        oracle/image/oracle-image.scm
;;;
;;; Import into OCI with launch mode PARAVIRTUALIZED.
;;;
;;; Every setting below is justified in oracle-image_purpose.txt.  Read that
;;; before changing anything -- several values are load-bearing in ways that
;;; are not obvious from the code (the root file system label in particular).

(use-modules (gnu)
             (guix gexp))

(use-service-modules networking shepherd ssh)
;; wget: for %metadata-ssh-key-service.  It is already in %base-packages, but a
;; shepherd service must reference the store path directly rather than trust
;; PATH, so the module has to be imported to name the package here.
(use-package-modules base linux ssh wget)


;;;
;;; Site-specific settings.
;;;

(define %user-name "guix")
(define %full-name "Guix User")
(define %host-name "guix-oracle")
(define %timezone "America/New_York")

;; Public half of an SSH key permitted to log in, baked into the image.
;;
;; OPTIONAL as of the metadata service below.  Two ways in now exist:
;;
;;   baked-in key   -> /etc/ssh/authorized_keys.d/guix  (written by Guix at
;;                     activation, from the openssh-configuration below)
;;   instance metadata -> ~guix/.ssh/authorized_keys    (written at boot by
;;                     %metadata-ssh-key-service)
;;
;; sshd consults both, because Guix sets
;;   AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 \
;;                      /etc/ssh/authorized_keys.d/%u
;; so neither mechanism can clobber the other.  (Do NOT be tempted to have the
;; service write into /etc/ssh/authorized_keys.d: Guix deletes and recreates
;; that whole directory on every activation.)
;;
;; When authorized-key.pub is absent the image is built with no baked key at
;; all, which is what makes ONE published image usable by anyone: they supply
;; their key at launch and the metadata service installs it.  When the file is
;; present the key is baked in as before, so an existing personal workflow is
;; unchanged.
(define %authorized-key-path
  (string-append (dirname (or (current-filename) ".")) "/authorized-key.pub"))

(define %authorized-key
  (and (file-exists? %authorized-key-path)
       (local-file "authorized-key.pub")))

;; VM.Standard.E2.1.Micro has 1 GiB of RAM.  'guix pull' and 'guix system
;; reconfigure' are memory-hungry and get OOM-killed without swap.
(define %swapfile "/swapfile")
(define %swapfile-size-mib 2048)


;;;
;;; Swap file, created on first boot.
;;;
;;; The 'swap-devices' field cannot be used here: it expects the swap area to
;;; already exist, and nothing in a freshly built image has created one.  So
;;; this is a one-shot shepherd service that creates the file if absent and
;;; enables it, which makes it idempotent across reboots.

(define %swapfile-service
  (simple-service
   'oracle-swapfile shepherd-root-service-type
   (list
    (shepherd-service
     (provision '(swapfile))
     (requirement '(file-systems))
     (documentation "Create a swap file if absent, then enable it.")
     (one-shot? #t)
     (start
      #~(lambda _
          (define (run . args)
            (zero? (apply system* args)))
          (and (or (file-exists? #$%swapfile)
                   ;; dd rather than fallocate: fallocate produces unwritten
                   ;; extents on ext4 and swapon refuses to use such a file.
                   (and (run #$(file-append coreutils "/bin/dd")
                             "if=/dev/zero"
                             (string-append "of=" #$%swapfile)
                             "bs=1M"
                             #$(string-append
                                "count=" (number->string %swapfile-size-mib)))
                        (begin (chmod #$%swapfile #o600) #t)
                        (run #$(file-append util-linux "/sbin/mkswap")
                             #$%swapfile)))
               (run #$(file-append util-linux "/sbin/swapon") #$%swapfile))))
     (stop
      #~(lambda _
          (system* #$(file-append util-linux "/sbin/swapoff") #$%swapfile)
          #f))))))


;;;
;;; SSH keys from the OCI instance metadata service.
;;;
;;; This is the one piece of cloud-init that matters, and its absence is why
;;; every other distribution's cloud image can be generic while this one could
;;; not.  With it, `--metadata ssh_authorized_keys=...` at launch works -- which
;;; is also what the OCI console's "Add SSH keys" box populates -- so a single
;;; published image serves everyone instead of one build per person.
;;;
;;; The endpoint is IMDSv2, which REQUIRES the "Authorization: Bearer Oracle"
;;; header; v1 is disabled on instances created with v2-only enforcement, so v1
;;; is only a fallback for older instances.
;;;
;;; wget rather than Guile's (web client): the header parsers in (web http)
;;; validate known header names against typed values, and 'authorization' is one
;;; of them, so handing it a raw string is a trap.  wget is already in
;;; %base-packages, and file-append pins the exact store path rather than
;;; trusting PATH inside a shepherd service.

(define %metadata-ssh-key-service
  (simple-service
   'oracle-metadata-ssh-keys shepherd-root-service-type
   (list
    (shepherd-service
     (provision '(metadata-ssh-keys))
     ;; Needs a network (dhcpcd provides 'networking) and a mounted /home.
     (requirement '(networking file-systems))
     (documentation
      "Install SSH keys from the OCI instance metadata service, if present.")
     (one-shot? #t)
     (start
      #~(lambda _
          (let* ((user #$%user-name)
                 (home (string-append "/home/" user))
                 (ssh-dir (string-append home "/.ssh"))
                 (target (string-append ssh-dir "/authorized_keys"))
                 (scratch "/run/metadata-ssh-keys")
                 (wget #$(file-append wget "/bin/wget")))

            (define (log fmt . args)
              (apply format (current-error-port)
                     (string-append "metadata-ssh-keys: " fmt "~%") args))

            (define (fetch! url . extra)
              ;; Short timeouts: on a machine with no metadata service (a local
              ;; QEMU smoke test) this must fail in seconds, not stall boot.
              (and (zero? (apply system* wget "-q" "-O" scratch
                                 "--timeout=5" "--tries=2"
                                 (append extra (list url))))
                   (file-exists? scratch)
                   (> (stat:size (stat scratch)) 0)))

            (define (read-scratch)
              (call-with-input-file scratch
                (lambda (port)
                  (let loop ((lines '()))
                    (let ((line (read-line port)))
                      (if (eof-object? line)
                          (reverse lines)
                          (loop (cons line lines))))))))

            ;; Leaf values may come back JSON-quoted ("ssh-ed25519 AAAA...")
            ;; rather than raw.  Probed on a live instance 2026-08-08 via
            ;; /opc/v2/instance/shape, but an instance WITHOUT keys cannot
            ;; demonstrate the keys endpoint specifically -- so strip a
            ;; surrounding pair of quotes rather than depend on the answer.
            ;; Getting this wrong is invisible: every real key would be
            ;; rejected and the service would log "no usable public keys"
            ;; while looking perfectly healthy.
            (define (unquote-value line)
              (let* ((trimmed (string-trim-both line))
                     (n (string-length trimmed)))
                (if (and (>= n 2)
                         (char=? (string-ref trimmed 0) #\")
                         (char=? (string-ref trimmed (- n 1)) #\"))
                    (substring trimmed 1 (- n 1))
                    trimmed)))

            ;; Only lines that actually look like a public key are installed.
            ;; The metadata endpoint returns an HTML error body in some failure
            ;; modes, and writing that into authorized_keys would be silent.
            (define (key-line? line)
              (let ((trimmed (unquote-value line)))
                (and (> (string-length trimmed) 0)
                     (or (string-prefix? "ssh-" trimmed)
                         (string-prefix? "ecdsa-" trimmed)
                         (string-prefix? "sk-ssh-" trimmed)
                         (string-prefix? "sk-ecdsa-" trimmed)))))

            (define (install! keys)
              (let* ((pw (getpwnam user))
                     (uid (passwd:uid pw))
                     (gid (passwd:gid pw)))
                (unless (file-exists? ssh-dir)
                  (mkdir ssh-dir))
                (chmod ssh-dir #o700)
                (chown ssh-dir uid gid)
                (call-with-output-file target
                  (lambda (port)
                    (format port "# Installed from OCI instance metadata.~%")
                    (format port "# Rewritten on every boot -- edit the instance metadata, not this file.~%")
                    (for-each (lambda (key) (format port "~a~%" key)) keys)))
                (chmod target #o600)
                (chown target uid gid)
                (log "installed ~a key(s) into ~a" (length keys) target)))

            (catch #t
              (lambda ()
                (if (or (fetch! (string-append
                                 "http://169.254.169.254/opc/v2/instance/"
                                 "metadata/ssh_authorized_keys")
                                "--header=Authorization: Bearer Oracle")
                        (fetch! (string-append
                                 "http://169.254.169.254/opc/v1/instance/"
                                 "metadata/ssh_authorized_keys")))
                    ;; map unquote-value, not just filter: accepting a quoted
                    ;; line and then WRITING it with its quotes intact would
                    ;; produce an authorized_keys sshd silently ignores.
                    (let ((keys (map unquote-value
                                     (filter key-line? (read-scratch)))))
                      (if (null? keys)
                          (log "metadata returned no usable public keys")
                          (install! keys)))
                    (log "no instance metadata available (not on OCI?)")))
              (lambda args
                (log "failed: ~s" args)))

            (when (file-exists? scratch)
              (delete-file scratch))

            ;; Always report success.  A one-shot that returns #f is marked
            ;; failed and shows up as a scary red line at boot -- but "no
            ;; metadata" is the normal, correct state during a local QEMU smoke
            ;; test, and on OCI an image that also has a baked-in key is still
            ;; perfectly reachable.  The log line above is the real signal.
            #t)))))))


;;;
;;; The system.
;;;

(operating-system
 (host-name %host-name)
 (timezone %timezone)
 (locale "en_US.utf8")

 ;; Free software only, consistent with the cloudzy platform.  linux-libre is
 ;; sufficient here: OCI paravirtualized instances present virtio devices, and
 ;; virtio needs no redistributable firmware.
 (kernel linux-libre)

 ;; Initrd modules are deliberately NOT overridden.  %base-initrd-modules
 ;; already contains virtio_pci, virtio_blk, virtio_net and virtio_scsi, which
 ;; is everything a paravirtualized OCI instance needs to find its root disk
 ;; and its network card.

 ;; console=tty0 keeps output on the emulated VGA console; console=ttyS0 is
 ;; what the OCI serial console attaches to.  Listing ttyS0 last makes it the
 ;; primary console, so kernel panics are visible in the OCI console.  This
 ;; also gives a login prompt on the serial line for free: %base-services runs
 ;; agetty with (tty #f), which auto-detects the console from this very line.
 (kernel-arguments
  (append '("console=tty0" "console=ttyS0,115200n8")
          %default-kernel-arguments))

 (bootloader
  (bootloader-configuration
   ;; BIOS GRUB, matching the 'qcow2' image type (MBR + hybrid ESP) and the
   ;; PARAVIRTUALIZED launch mode.  Using grub-efi-bootloader here would
   ;; require the 'qcow2-gpt' image type and the NATIVE launch mode instead.
   (bootloader grub-bootloader)
   ;; /dev/sda, not /dev/vda: OCI's PARAVIRTUALIZED launch mode attaches the
   ;; boot volume via virtio-scsi, so it enumerates as sda.  Observed with
   ;; lsblk on the first live instance (2026-08-08).  This only matters at
   ;; `guix system reconfigure` time -- the image build writes GRUB itself.
   (targets '("/dev/sda"))
   ;; Mirror the boot menu onto the serial line so the OCI console can be used
   ;; to pick an older generation when a reconfigure breaks the system.
   (terminal-outputs '(console serial_0))
   (terminal-inputs '(console serial_0))
   (serial-unit 0)
   (serial-speed 115200)
   (timeout 3)))

 ;; "Guix_image" is not a name we chose: it is the label 'guix system image'
 ;; writes onto the root partition (gnu/system/image.scm, root-label).  If this
 ;; string does not match, the initrd cannot find the root file system and the
 ;; instance drops to a Guile rescue REPL on the serial console.
 (file-systems
  (cons (file-system
         (mount-point "/")
         (device (file-system-label "Guix_image"))
         (type "ext4"))
        %base-file-systems))

 (users (cons (user-account
               (name %user-name)
               (comment %full-name)
               (group "users")
               (home-directory (string-append "/home/" %user-name))
               ;; No password field: the account gets a locked password, so
               ;; password login is impossible while SSH key login still works.
               (supplementary-groups '("wheel" "netdev")))
              %base-user-accounts))

 ;; Passwordless sudo for wheel.  This is not gratuitous: the account above has
 ;; no password by design, so ordinary sudo would prompt for one that does not
 ;; exist and the user could never become root.  This mirrors what cloud-init
 ;; does for the default user on other distributions' cloud images.
 (sudoers-file
  (plain-file "sudoers"
              (string-append "root ALL=(ALL) ALL\n"
                             "%wheel ALL=NOPASSWD:ALL\n")))

 ;; Minimal: nss-certs is already in %base-packages (via
 ;; %base-packages-networking), so 'guix pull' has working TLS out of the box.
 (packages %base-packages)

 (services
  (append
   (list
    ;; OCI hands out addresses, routes and DNS over DHCP on the VNIC.
    ;; dhcpcd-service-type, not dhcp-client-service-type: the latter is
    ;; deprecated in this Guix (17c2142) and warns on every evaluation.
    (service dhcpcd-service-type)

    (service openssh-service-type
             (openssh-configuration
              ;; -sans-x avoids pulling X11 into a headless server image.
              (openssh openssh-sans-x)
              (permit-root-login #f)
              (password-authentication? #f)
              ;; Conditional, because %authorized-key is #f when
              ;; authorized-key.pub is absent (the generic published image).
              ;; An unconditional `((,%user-name ,%authorized-key)) emits
              ;; ((guix #f)), and the authorized-keys builder then calls
              ;; (open-file #f "r") and dies with
              ;;   ERROR: In procedure open-file: Wrong type (expecting string): #f
              ;; That failure is invisible to `guix system` EVALUATION -- the
              ;; builder only runs at BUILD time -- so it cost a full image
              ;; build to discover (2026-08-09).  See the regression test in
              ;; oracle/tests/test-oracle-image.scm, which inspects the
              ;; service's value instead of building it.
              (authorized-keys
               (if %authorized-key
                   `((,%user-name ,%authorized-key))
                   '()))))

    %swapfile-service
    %metadata-ssh-key-service)

   %base-services)))
