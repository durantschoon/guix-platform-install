#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; postinstall/lib.scm - Shared functions for post-installation customization scripts
;;; Source this file from platform-specific customize scripts
;;; These functions run AFTER the system boots (not on the ISO)

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 ftw)
             (srfi srfi-1)
             (srfi srfi-19))  ; For date/time

;;; ============================================================================
;;; Colors for output
;;; ============================================================================

(define (msg text)
  "Display message in blue"
  (format #t "\n\033[1;34m==> ~a\033[0m\n" text))

(define (warn text)
  "Display warning in yellow"
  (format #t "\n\033[1;33m[warn]\033[0m ~a\n" text))

(define (err text)
  "Display error in red"
  (format #t "\n\033[1;31m[err]\033[0m  ~a\n" text))

(define (info text)
  "Display info message"
  (format #t "  ~a\n" text))

(define (success text)
  "Display success message in green"
  (format #t "\n\033[1;32m[OK] ~a\033[0m\n" text))

;;; ============================================================================
;;; Interactive input helpers
;;; ============================================================================

(define* (ask-yes prompt #:optional (default "N"))
  "Ask yes/no question. Returns #t if yes, #f if no.
   Default can be 'Y' or 'N'."
  (let* ((default-upper (string-upcase default))
         (default-prompt (if (string=? default-upper "Y")
                             "[Y/n]"
                             "[y/N]"))
         (full-prompt (format #f "~a ~a " prompt default-prompt)))
    (display full-prompt)
    (force-output)
    (let ((answer (read-line)))
      (if (or (eof-object? answer) (string=? answer ""))
          (string=? default-upper "Y")
          (let ((ans-upper (string-upcase answer)))
            (or (string=? ans-upper "Y")
                (string=? ans-upper "YES")))))))

;;; ============================================================================
;;; Configuration backup
;;; ============================================================================

(define (backup-config config-file backup-dir)
  "Backup current config file with timestamp.
   Creates backup directory if needed."
  (let* ((timestamp (date->string (current-date) "~Y~m~d-~H~M~S"))
         (backup-file (string-append backup-dir "/config.scm." timestamp)))
    ;; Create backup directory
    (unless (file-exists? backup-dir)
      (mkdir backup-dir))
    
    ;; Copy config file (with sudo if needed)
    (let ((copy-cmd (if (access? config-file W_OK)
                        (format #f "cp ~s ~s" config-file backup-file)
                        (format #f "sudo cp ~s ~s && sudo chown ~a ~s"
                                config-file backup-file
                                (getenv "USER") backup-file))))
      (let ((status (system copy-cmd)))
        (if (zero? status)
            (info (format #f "Backed up config to: ~a" backup-file))
            (err (format #f "Failed to backup config")))
        (zero? status)))))

;;; ============================================================================
;;; Guile helper integration
;;; ============================================================================

(define (find-guile-helper install-root)
  "Find the guile-config-helper.scm relative to INSTALL_ROOT.
   Returns the full path or #f if not found."
  (let ((helper-path (string-append install-root "/lib/guile-config-helper.scm")))
    (if (file-exists? helper-path)
        helper-path
        #f)))

(define* (call-guile-helper config-file subcommand extra-args #:optional (install-root #f))
  "Run guile-config-helper.scm SUBCOMMAND against CONFIG-FILE.

   The edit is performed on a temp copy and only written back on success, so a
   helper failure leaves the config untouched.

   extra-args: list of already-formatted argument strings appended after the
   temp file name.  Empty for subcommands that take only the config.
   Returns #t on success, #f on failure."
  (let* ((root (or install-root
                   (getenv "INSTALL_ROOT")
                   ;; Fallback: try to detect from current directory
                   (getcwd)))
         (guile-helper (find-guile-helper root))
         (tmp-file (tmpnam)))

    (unless guile-helper
      (err (format #f "guile-config-helper.scm not found at: ~a/lib/guile-config-helper.scm"
                   root))
      (err (format #f "INSTALL_ROOT: ~a" (or (getenv "INSTALL_ROOT") "<not set>")))
      (err (format #f "Calculated install_root: ~a" root))
      (throw 'helper-not-found))

    ;; Copy config to temp file
    (let ((copy-cmd (if (access? config-file W_OK)
                        (format #f "cp ~s ~s" config-file tmp-file)
                        (format #f "sudo cp ~s ~s && sudo chown ~a ~s"
                                config-file tmp-file
                                (getenv "USER") tmp-file))))
      (unless (zero? (system copy-cmd))
        (err "Failed to copy config to temp file")
        (throw 'copy-failed)))

    (let* ((helper-cmd (format #f "guile --no-auto-compile -s ~s ~a ~s~a"
                               guile-helper subcommand tmp-file
                               (string-concatenate
                                (map (lambda (a) (string-append " " a)) extra-args))))
           (status (system helper-cmd)))
      (if (zero? status)
          (begin
            ;; Copy back
            (let ((copy-back (if (access? config-file W_OK)
                                 (format #f "cp ~s ~s" tmp-file config-file)
                                 (format #f "sudo cp ~s ~s" tmp-file config-file))))
              (system copy-back))
            (delete-file tmp-file)
            #t)
          (begin
            (delete-file tmp-file)
            #f)))))

(define* (guile-add-service config-file module service #:optional (install-root #f))
  "Add service using Guile S-expression parser.
   module: e.g., \"(gnu services ssh)\"
   service: e.g., \"(service openssh-service-type)\"
   install-root: root directory of installation (optional, will try to detect)"
  (call-guile-helper config-file "add-service"
                     (list (format #f "~s" module) (format #f "~s" service))
                     install-root))

(define* (guile-switch-to-desktop config-file #:optional (install-root #f))
  "Switch the config's base from %base-services to %desktop-services.

   %desktop-services is a SUPERSET of %base-services, so a minimal config's
   explicit network-manager / wpa-supplicant / dbus / polkit / ntp become
   duplicates and the build fails with

     guix system: error: more than one target service of type 'dbus'

   The helper removes those, and rewrites any that carried a configuration
   record into a modify-services clause so the settings are not lost with the
   service.  Returns #t on success, #f on failure."
  (call-guile-helper config-file "switch-to-desktop" '() install-root))

;;; ============================================================================
;;; Safe config editing
;;; ============================================================================

(define (safe-edit-config config-file sed-command)
  "Apply sed command to config file safely via temp file.
   sed-command: sed command string (e.g., 's/old/new/')"
  (let ((tmp-file (tmpnam)))
    ;; Copy config to temp file (readable by user)
    (let ((copy-cmd (if (access? config-file W_OK)
                        (format #f "cp ~s ~s" config-file tmp-file)
                        (format #f "sudo cp ~s ~s && sudo chown ~a ~s"
                                config-file tmp-file
                                (getenv "USER") tmp-file))))
      (unless (zero? (system copy-cmd))
        (err "Failed to copy config to temp file")
        (throw 'copy-failed)))
    
    ;; Apply sed command to temp file
    (let ((sed-cmd (format #f "sed -i '~a' ~s" sed-command tmp-file)))
      (system sed-cmd))
    
    ;; Copy back
    (let ((copy-back (if (access? config-file W_OK)
                         (format #f "cp ~s ~s" tmp-file config-file)
                         (format #f "sudo cp ~s ~s" tmp-file config-file))))
      (system copy-back))
    
    (delete-file tmp-file)))

;;; ============================================================================
;;; Service addition functions
;;; ============================================================================

(define* (add-ssh config-file backup-dir #:optional (install-root #f))
  "Add SSH service to config file.
   Returns #t on success, #f on failure."
  (msg "Adding SSH Service")
  
  ;; Check if already configured
  (let ((config-content (call-with-input-file config-file read-string)))
    (if (string-contains config-content "openssh-service-type")
        (begin
          (warn "SSH service already configured")
          #t)
        (begin
          (backup-config config-file backup-dir)
          
          ;; Use Guile helper to add SSH service
          (if (guile-add-service config-file
                                 "(gnu services ssh)"
                                 "(service openssh-service-type)"
                                 install-root)
              (begin
                (info "[OK] SSH service added")
                (info "After reconfigure, SSH will be available on port 22")
                #t)
              (begin
                (err "Failed to add SSH service")
                (err "Please add SSH manually to /etc/config.scm")
                #f))))))

;;; ============================================================================
;;; Desktop environment addition
;;; ============================================================================

(define* (add-desktop config-file backup-dir #:optional (install-root #f))
  "Add desktop environment to config file.
   Prompts user for selection. Returns #t on success, #f on failure."
  (msg "Desktop Environment Selection")
  (newline)
  (display "Available desktop environments:\n")
  (display "  1) GNOME   - Full-featured, modern desktop\n")
  (display "  2) Xfce    - Lightweight, traditional desktop\n")
  (display "  3) MATE    - Classic GNOME 2 experience\n")
  (display "  4) LXQt    - Very lightweight, minimal resources\n")
  (display "  0) Cancel\n")
  (newline)
  (display "Select desktop [1-4, 0 to cancel]: ")
  (force-output)
  
  (let ((choice (read-line)))
    (if (eof-object? choice)
        (begin
          (info "Cancelled")
          #f)
        (let* ((choice-num (string-trim-both choice))
               (desktop-service (cond
                                 ((string=? choice-num "1")
                                  '("gnome" . "gnome-desktop-service-type"))
                                 ((string=? choice-num "2")
                                  '("xfce" . "xfce-desktop-service-type"))
                                 ((string=? choice-num "3")
                                  '("mate" . "mate-desktop-service-type"))
                                 ((string=? choice-num "4")
                                  '("lxqt" . "lxqt-desktop-service-type"))
                                 ((string=? choice-num "0")
                                  #f)
                                 (else 'invalid))))
          (cond
           ((eq? desktop-service 'invalid)
            (err "Invalid choice")
            #f)
           ((not desktop-service)
            (info "Cancelled")
            #f)
           (else
            (let ((desktop-name (car desktop-service))
                  (service-type (cdr desktop-service)))
              ;; Check if already configured
              (let ((config-content (call-with-input-file config-file read-string)))
                (if (string-contains config-content "desktop-service-type")
                    (begin
                      (warn "Desktop environment already configured")
                      #t)
                    (begin
                      (backup-config config-file backup-dir)

                      ;; The display manager (GDM) lives in %desktop-services,
                      ;; not in the desktop service itself, so a config still
                      ;; built on %base-services would gain the desktop packages
                      ;; and no graphical login.  Switch the base first -- and
                      ;; via the helper, which also drops the services the new
                      ;; base already provides and preserves the configuration
                      ;; of any that carried one.  See guile-switch-to-desktop.
                      (if (and (string-contains config-content "%base-services")
                               (not (string-contains config-content "%desktop-services"))
                               (not (guile-switch-to-desktop config-file install-root)))
                          (begin
                            (err "Could not switch to %desktop-services")
                            (err "Aborting rather than leaving a config that cannot build.")
                            #f)
                          ;; Use Guile helper to add desktop service
                          (if (guile-add-service config-file
                                                 "(gnu services desktop)"
                                                 (format #f "(service ~a)" service-type)
                                                 install-root)
                              (begin
                                (info (format #f "[OK] ~a desktop added" desktop-name))
                                #t)
                              (begin
                                (err "Failed to add desktop service")
                                (err (format #f "Please add ~a manually to /etc/config.scm"
                                             desktop-name))
                                #f)))))))))))))

;;; ============================================================================
;;; Package management
;;; ============================================================================

(define (add-packages config-file backup-dir)
  "Add common packages to config file.
   Returns #t on success, #f on failure."
  (msg "Adding Common Packages")
  
  ;; Check if already configured
  (let ((config-content (call-with-input-file config-file read-string)))
    (if (string-contains config-content "specification->package")
        (begin
          (warn "Custom packages already defined")
          #t)
        (begin
          (backup-config config-file backup-dir)
          
          ;; Replace minimal packages with useful defaults
          (safe-edit-config config-file
                            "s|(packages %base-packages)|(packages\\n  (append (list (specification->package \"emacs\")\\n                (specification->package \"git\")\\n                (specification->package \"vim\")\\n                (specification->package \"htop\")\\n                (specification->package \"curl\")\\n                (specification->package \"wget\")\\n                (specification->package \"go\"))\\n          %base-packages))|")
          
          (info "[OK] Added: emacs, git, vim, htop, curl, wget, go")
          #t))))

;;; ============================================================================
;;; Nonguix channel management
;;; ============================================================================

(define* (add-nonguix-info #:optional (install-root #f))
  "Display nonguix channel information and optionally generate channels.scm.
   install-root: root directory of installation (optional)"
  (msg "Nonguix Channel (for proprietary software/firmware)")
  (newline)
  (info "Nonguix provides:")
  (info "  - Proprietary firmware (WiFi, graphics drivers)")
  (info "  - Non-free software (Steam, Discord, etc.)")
  (newline)
  
  (let* ((root (or install-root
                   (getenv "INSTALL_ROOT")
                   (getcwd)))
         (postinstall-lib (string-append root "/lib/postinstall.sh"))
         (channels-file (string-append (getenv "HOME") "/.config/guix/channels.scm"))
         (channels-dir (dirname channels-file)))
    
    ;; Create config directory if needed
    (unless (file-exists? channels-dir)
      (mkdir channels-dir))
    
    (if (ask-yes "Generate channels.scm with regional mirror optimization?" "Y")
        (begin
          ;; If postinstall.sh exists, use it via bash
          ;; (It has generate_channels_scm function)
          (if (file-exists? postinstall-lib)
              (let* ((cmd (format #f "bash -c 'source ~s && generate_channels_scm' > ~s"
                                  postinstall-lib channels-file))
                     (status (system cmd)))
                (if (zero? status)
                    (begin
                      (success (format #f "Created ~a with optimized mirrors" channels-file))
                      (newline)
                      (display (call-with-input-file channels-file read-string))
                      (newline)
                      (info "Then run: guix pull && sudo guix system reconfigure /etc/config.scm"))
                    (err "Failed to generate channels.scm")))
              ;; Fallback: provide manual instructions
              (begin
                (info "To add nonguix channel manually, create ~/.config/guix/channels.scm:")
                (newline)
                (display "(cons* (channel\n")
                (display "        (name 'nonguix)\n")
                (display "        (url \"https://gitlab.com/nonguix/nonguix\")\n")
                (display "        (branch \"master\")\n")
                (display "        (introduction\n")
                (display "         (make-channel-introduction\n")
                (display "          \"897c1a470da759236cc11798f4e0a5f7d4d59fbc\"\n")
                (display "          (openpgp-fingerprint\n")
                (display "           \"2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5\"))))\n")
                (display "       %default-channels)\n")
                (newline)
                (info "Then run: guix pull && sudo guix system reconfigure /etc/config.scm"))))
        ;; User declined generation
        (begin
          (info "To add nonguix channel manually, create ~/.config/guix/channels.scm:")
          (newline)
          (display "(cons* (channel\n")
          (display "        (name 'nonguix)\n")
          (display "        (url \"https://gitlab.com/nonguix/nonguix\")\n")
          (display "        (branch \"master\")\n")
          (display "        (introduction\n")
          (display "         (make-channel-introduction\n")
          (display "          \"897c1a470da759236cc11798f4e0a5f7d4d59fbc\"\n")
          (display "          (openpgp-fingerprint\n")
          (display "           \"2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5\"))))\n")
          (display "       %default-channels)\n")
          (newline)
          (info "Then run: guix pull && sudo guix system reconfigure /etc/config.scm")))))

;;; ============================================================================
;;; System reconfiguration
;;; ============================================================================

(define (reconfigure config-file)
  "Apply changes by reconfiguring system.
   Returns #t on success, #f on failure."
  (msg "System Reconfigure")
  (newline)
  (info "This will apply all changes to your system.")
  (info (format #f "Current config: ~a" config-file))
  (newline)
  
  (if (ask-yes "Proceed with system reconfigure?")
      (let* ((cmd (format #f "sudo guix system reconfigure ~s" config-file))
             (status (system cmd)))
        (zero? status))
      (begin
        (info "Cancelled")
        #f)))

;;; ============================================================================
;;; Config file viewing and editing
;;; ============================================================================

(define (edit-config config-file)
  "Edit config file with fallback editors.
   Returns #t on success, #f on failure."
  (let ((editor (or (getenv "EDITOR") "nano")))
    (cond
     ((not (zero? (system (format #f "command -v ~a >/dev/null 2>&1" editor))))
      ;; Editor not found, try nano
      (if (zero? (system "command -v nano >/dev/null 2>&1"))
          (zero? (system (format #f "nano ~s" config-file)))
          ;; Try vi as last resort
          (if (zero? (system "command -v vi >/dev/null 2>&1"))
              (zero? (system (format #f "vi ~s" config-file)))
              (begin
                (err "No editor found. Install nano or set EDITOR variable")
                #f))))
     (else
      (zero? (system (format #f "~a ~s" editor config-file)))))))

(define (view-config config-file)
  "View config file with fallback pagers.
   Returns #t on success, #f on failure."
  (cond
   ((zero? (system "command -v less >/dev/null 2>&1"))
    (zero? (system (format #f "less ~s" config-file))))
   ((zero? (system "command -v more >/dev/null 2>&1"))
    (zero? (system (format #f "more ~s" config-file))))
   (else
    ;; No pager, show first 100 lines
    (let* ((port (open-input-pipe (format #f "cat ~s | head -100" config-file)))
           (content (read-string port)))
      (close-pipe port)
      (display content)
      (info "Install 'less' for better viewing (currently showing first 100 lines)")
      (display "Press Enter to continue...")
      (force-output)
      (read-line)
      #t))))

;;; ============================================================================
;;; Screen management
;;; ============================================================================

(define (clear-screen)
  "Clear screen with fallback."
  (if (zero? (system "command -v clear >/dev/null 2>&1"))
      (system "clear")
      (display "\n\n========================================\n\n")))
