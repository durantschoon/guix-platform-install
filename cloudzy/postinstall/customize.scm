#!/usr/bin/env -S guile --no-auto-compile
!#

;;; VPS Server Customization Tool
;;; Optimized for headless VPS/server environments (Cloudzy, DigitalOcean, AWS, etc.)

(use-modules (ice-9 format)
             (ice-9 rdelim)
             (ice-9 popen)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; Find INSTALL_ROOT relative to this script
(define (find-install-root)
  "Find INSTALL_ROOT relative to this script location."
  (let* ((install-root-env (getenv "INSTALL_ROOT"))
         (script-path (car (command-line)))
         (script-dir (dirname script-path))
         (calculated-root (dirname (dirname script-dir))))
    (or install-root-env
        calculated-root
        (string-append (getenv "HOME") "/guix-customize"))))

(define install-root (find-install-root))
(setenv "INSTALL_ROOT" install-root)

;;; Load postinstall/lib.scm functions
(define lib-path (string-append install-root "/postinstall/lib.scm"))
(if (file-exists? lib-path)
    (load lib-path)
    (begin
      (format #t "Error: postinstall/lib.scm not found at ~a\n" lib-path)
      (format #t "Script location: ~a\n" (car (command-line)))
      (format #t "Install root: ~a\n" install-root)
      (display "Please run bootstrap-postinstall.scm first to download all required files.\n")
      (exit 1)))

;;; Configuration
(define config-file "/etc/config.scm")
(define backup-dir (string-append (getenv "HOME") "/.config/guix-customize/backups"))

;;; Main menu loop
(define (main-menu)
  "Main menu loop - recursive procedure."
  (clear-screen)
  (msg "VPS Server Customization Tool")
  (newline)
  (display "Platform: Cloudzy / VPS / Cloud Server\n")
  (format #t "Current config: ~a\n" config-file)
  (newline)
  (display "First Step:\n")
  (display "  p) Load my personal config (git + clone + apply)\n")
  (newline)
  (display "Essential Services:\n")
  (display "  1) Add SSH service (required for remote access)\n")
  (display "  3) Add common packages (git, vim, emacs, go, etc.)\n")
  (newline)
  (display "Server Features:\n")
  (display "  5) Show nonguix channel info (proprietary software)\n")
  (newline)
  (display "Shared Recipes:\n")
  (display "  s) Install Spacemacs (Emacs distribution)\n")
  (display "  d) Install development tools (git, vim, python, etc.)\n")
  (display "  f) Install fonts (Fira Code, JetBrains Mono, etc.)\n")
  (newline)
  (display "Actions:\n")
  (display "  r) Apply changes (reconfigure system)\n")
  (display "  e) Edit config manually\n")
  (display "  v) View current config\n")
  (display "  q) Quit\n")
  (newline)
  (info "Note: This is a VPS-focused tool. Desktop/hardware features removed.")
  (info "      For Framework 13 laptop, use framework-dual/postinstall/customize")
  (newline)
  (display "Select option: ")
  (force-output)
  
  (let ((choice (read-line)))
    (if (eof-object? choice)
        (begin
          (msg "Goodbye!")
          (exit 0))
        (let ((choice-trimmed (string-trim-both choice)))
          (cond
           ((string=? choice-trimmed "1")
            (add-ssh config-file backup-dir install-root)
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string=? choice-trimmed "3")
            (add-packages config-file backup-dir)
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string=? choice-trimmed "5")
            (add-nonguix-info install-root)
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string-ci=? choice-trimmed "s")
            (let ((recipe-path (string-append install-root "/postinstall/recipes/add/spacemacs.scm")))
              (if (file-exists? recipe-path)
                  (system (format #f "guile --no-auto-compile -s ~s" recipe-path))
                  (begin
                    (err (format #f "Recipe not found: ~a" recipe-path))
                    (info "Please ensure bootstrap-postinstall.scm has been run"))))
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ;; Bootstrapping the user's own configuration repository.  Listed
           ;; first in the menu because it is what someone wants immediately
           ;; after an install finishes, and because everything else here is
           ;; a fallback for a user who has not written a contract yet.
           ;; See docs/PERSONAL_CONFIG_CONTRACT.md.
           ((string-ci=? choice-trimmed "p")
            (let ((recipe-path (string-append install-root "/postinstall/recipes/add/personal-config.scm")))
              (if (file-exists? recipe-path)
                  (system (format #f "guile --no-auto-compile -s ~s" recipe-path))
                  (begin
                    (err (format #f "Recipe not found: ~a" recipe-path))
                    (info "Please ensure bootstrap-postinstall.scm has been run"))))
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))

           ((string-ci=? choice-trimmed "d")
            (let ((recipe-path (string-append install-root "/postinstall/recipes/add/development.scm")))
              (if (file-exists? recipe-path)
                  (system (format #f "guile --no-auto-compile -s ~s" recipe-path))
                  (begin
                    (err (format #f "Recipe not found: ~a" recipe-path))
                    (info "Please ensure bootstrap-postinstall.scm has been run"))))
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string-ci=? choice-trimmed "f")
            (let ((recipe-path (string-append install-root "/postinstall/recipes/add/fonts.scm")))
              (if (file-exists? recipe-path)
                  (system (format #f "guile --no-auto-compile -s ~s" recipe-path))
                  (begin
                    (err (format #f "Recipe not found: ~a" recipe-path))
                    (info "Please ensure bootstrap-postinstall.scm has been run"))))
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string-ci=? choice-trimmed "r")
            (reconfigure config-file)
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string-ci=? choice-trimmed "e")
            (edit-config config-file)
            (display "Press Enter to continue...")
            (force-output)
            (read-line)
            (main-menu))
           
           ((string-ci=? choice-trimmed "v")
            (view-config config-file)
            (main-menu))
           
           ((string-ci=? choice-trimmed "q")
            (msg "Goodbye!")
            (exit 0))
           
           (else
            (err "Invalid option")
            (sleep 1)
            (main-menu)))))))

;;; Check if running as root
(let* ((whoami-cmd "id -u")
       (port (open-input-pipe whoami-cmd))
       (uid-str (read-line port))
       (status (close-pipe port)))
  (when (and (zero? status) uid-str (not (eof-object? uid-str)))
    (let ((uid (string->number uid-str)))
      (when (and uid (zero? uid))
        (format #t "\n\033[1;31m[err]\033[0m  Do not run this script as root\n")
        (format #t "  Run as normal user (will prompt for sudo when needed)\n")
        (exit 1)))))

;;; Check if config exists
(unless (file-exists? config-file)
  (err (format #f "Config file not found: ~a" config-file))
  (info "Are you running this on an installed Guix system?")
  (exit 1))

;;; Run main menu
(main-menu)
