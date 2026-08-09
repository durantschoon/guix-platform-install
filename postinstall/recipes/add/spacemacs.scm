#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; Shared recipe: Install and configure Spacemacs
;;; Can be called from any platform's customize tool

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 regex)
             (srfi srfi-1))

;;; Configuration
(define config-file
  (or (getenv "CONFIG_FILE") "/etc/config.scm"))

;;; Output helpers
(define (info msg)
  (format #t "  ~a~%" msg))

(define (warn msg)
  (format #t "~%\x1b[1;33m[warn]\x1b[0m ~a~%" msg))

(define (success msg)
  (format #t "~%\x1b[1;32m[[OK]]\x1b[0m ~a~%" msg))

;;; Helper procedures
(define (file-contains? filepath pattern)
  "Check if file contains a pattern (string or regex)"
  (call-with-input-file filepath
    (lambda (port)
      (let loop ((line (read-line port)))
        (cond
         ((eof-object? line) #f)
         ((if (string? pattern)
              (string-contains line pattern)
              (string-match pattern line))
          #t)
         (else (loop (read-line port))))))))

(define (read-user-input prompt)
  "Read a line of input from /dev/tty with a prompt"
  (display prompt)
  (force-output)
  (call-with-input-file "/dev/tty"
    (lambda (port)
      (let ((line (read-line port)))
        (if (eof-object? line) "" line)))))

(define (yes-or-no? prompt)
  "Ask a yes/no question, return #t for yes, #f for no"
  (let ((response (read-user-input prompt)))
    (and (> (string-length response) 0)
         (or (char=? (string-ref response 0) #\y)
             (char=? (string-ref response 0) #\Y)))))

(define (file-exists-and-directory? path)
  "Check if path exists and is a directory"
  (and (file-exists? path)
       (eq? (stat:type (stat path)) 'directory)))

(define (run-command cmd)
  "Execute a shell command, return #t on success"
  (zero? (system cmd)))

(define (backup-path path)
  "Generate backup path with timestamp"
  (let* ((timestamp (strftime "%Y%m%d-%H%M%S" (localtime (current-time)))))
    (format #f "~a.backup.~a" path timestamp)))

;;; Config manipulation helpers
(define (add-emacs-modules-to-config!)
  "Add Emacs package modules to config if not present"
  (let ((temp-file (string-append config-file ".tmp")))
    (call-with-input-file config-file
      (lambda (in-port)
        (call-with-output-file temp-file
          (lambda (out-port)
            (let loop ((line (read-line in-port))
                       (modules-added? #f))
              (cond
               ((eof-object? line)
                (void))
               ((and (not modules-added?)
                     (string-contains line "(use-modules"))
                (display line out-port)
                (newline out-port)
                (display "             (gnu packages emacs)" out-port)
                (newline out-port)
                (display "             (gnu packages version-control))" out-port)
                (newline out-port)
                (loop (read-line in-port) #t))
               (else
                (display line out-port)
                (newline out-port)
                (loop (read-line in-port) modules-added?))))))))))
    (rename-file temp-file config-file)))

(define (add-emacs-to-packages!)
  "Add emacs and git to packages list in config"
  (let ((temp-file (string-append config-file ".tmp")))
    (call-with-input-file config-file
      (lambda (in-port)
        (call-with-output-file temp-file
          (lambda (out-port)
            (let loop ((line (read-line in-port))
                       (in-packages? #f))
              (cond
               ((eof-object? line)
                (void))
               ((string-contains line "(packages %base-packages)")
                ;; Minimal config - expand to use append
                (display "  (packages" out-port)
                (newline out-port)
                (display "   (append" out-port)
                (newline out-port)
                (display "    (list emacs" out-port)
                (newline out-port)
                (display "          git)" out-port)
                (newline out-port)
                (display "    %base-packages))" out-port)
                (newline out-port)
                (loop (read-line in-port) #f))
               ((and (not in-packages?) (string-contains line "(packages"))
                (display line out-port)
                (newline out-port)
                (loop (read-line in-port) #t))
               ((and in-packages? (string-contains line "list"))
                ;; Add emacs to existing list
                (display (string-append (string-trim-right line) " emacs") out-port)
                (newline out-port)
                (display "         git" out-port)
                (newline out-port)
                (loop (read-line in-port) #f))
               (else
                (display line out-port)
                (newline out-port)
                (loop (read-line in-port) in-packages?))))))))))
    (rename-file temp-file config-file)))

(define (ensure-emacs-in-config!)
  "Ensure Emacs is configured in config.scm"
  (unless (file-contains? config-file "emacs")
    (info "Adding Emacs package to config.scm...")
    (unless (file-contains? config-file "gnu packages emacs")
      (add-emacs-modules-to-config!))
    (add-emacs-to-packages!)
    (info "Emacs added to configuration")))

(define (clone-repository url destination)
  "Clone git repository, return #t on success"
  (run-command (format #f "git clone '~a' '~a'" url destination)))

(define (create-default-spacemacs-config!)
  "Create basic .spacemacs configuration"
  (let ((spacemacs-path (string-append (getenv "HOME") "/.spacemacs")))
    (call-with-output-file spacemacs-path
      (lambda (port)
        (display ";; -*- mode: emacs-lisp; lexical-binding: t -*-
;; Basic Spacemacs configuration

(defun dotspacemacs/layers ()
  (setq-default
   dotspacemacs-distribution 'spacemacs
   dotspacemacs-enable-lazy-installation 'unused
   dotspacemacs-ask-for-lazy-installation t
   dotspacemacs-configuration-layer-path '()

   dotspacemacs-configuration-layers
   '(
     ;; Add your layers here
     helm
     auto-completion
     better-defaults
     emacs-lisp
     git
     markdown
     org
     (shell :variables
            shell-default-height 30
            shell-default-position 'bottom)
     syntax-checking
     version-control
     )

   dotspacemacs-additional-packages '()
   dotspacemacs-frozen-packages '()
   dotspacemacs-excluded-packages '()
   dotspacemacs-install-packages 'used-only))

(defun dotspacemacs/init ()
  (setq-default
   dotspacemacs-elpa-https t
   dotspacemacs-elpa-timeout 5
   dotspacemacs-check-for-update nil
   dotspacemacs-elpa-subdirectory nil
   dotspacemacs-editing-style 'vim
   dotspacemacs-verbose-loading nil
   dotspacemacs-startup-banner 'official
   dotspacemacs-startup-lists '((recents . 5)
                                 (projects . 7))
   dotspacemacs-themes '(spacemacs-dark
                          spacemacs-light)
   dotspacemacs-colorize-cursor-according-to-state t
   dotspacemacs-default-font '(\"Source Code Pro\"
                                :size 13
                                :weight normal
                                :width normal)
   dotspacemacs-leader-key \"SPC\"
   dotspacemacs-emacs-command-key \"SPC\"
   dotspacemacs-ex-command-key \":\"
   dotspacemacs-emacs-leader-key \"M-m\"
   dotspacemacs-major-mode-leader-key \",\"
   dotspacemacs-major-mode-emacs-leader-key \"C-M-m\"
   dotspacemacs-distinguish-gui-tab nil
   dotspacemacs-remap-Y-to-y$ nil
   dotspacemacs-retain-visual-state-on-shift t
   dotspacemacs-visual-line-move-text nil
   dotspacemacs-ex-substitute-global nil
   dotspacemacs-default-layout-name \"Default\"
   dotspacemacs-display-default-layout nil
   dotspacemacs-auto-resume-layouts nil
   dotspacemacs-large-file-size 1
   dotspacemacs-auto-save-file-location 'cache
   dotspacemacs-max-rollback-slots 5
   dotspacemacs-helm-resize nil
   dotspacemacs-helm-no-header nil
   dotspacemacs-helm-position 'bottom
   dotspacemacs-helm-use-fuzzy 'always
   dotspacemacs-enable-paste-transient-state nil
   dotspacemacs-which-key-delay 0.4
   dotspacemacs-which-key-position 'bottom
   dotspacemacs-loading-progress-bar t
   dotspacemacs-fullscreen-at-startup nil
   dotspacemacs-fullscreen-use-non-native nil
   dotspacemacs-maximized-at-startup nil
   dotspacemacs-active-transparency 90
   dotspacemacs-inactive-transparency 90
   dotspacemacs-show-transient-state-title t
   dotspacemacs-show-transient-state-color-guide t
   dotspacemacs-mode-line-unicode-symbols t
   dotspacemacs-smooth-scrolling t
   dotspacemacs-line-numbers nil
   dotspacemacs-folding-method 'evil
   dotspacemacs-smartparens-strict-mode nil
   dotspacemacs-smart-closing-parenthesis nil
   dotspacemacs-highlight-delimiters 'all
   dotspacemacs-persistent-server nil
   dotspacemacs-search-tools '(\"ag\" \"pt\" \"ack\" \"grep\")
   dotspacemacs-default-package-repository nil
   dotspacemacs-whitespace-cleanup nil
   ))

(defun dotspacemacs/user-init ()
  \"Initialization function for user code.\")

(defun dotspacemacs/user-config ()
  \"Configuration function for user code.\")

;; Do not write anything past this comment.
" port)))
    (success "Created .spacemacs configuration")))

(define (import-spacemacs-config repo-url config-path)
  "Import .spacemacs from git repository"
  (let ((temp-dir (string-append (getenv "HOME") "/.spacemacs-tmp"))
        (target-path (string-append (getenv "HOME") "/.spacemacs")))
    (info "Importing your .spacemacs from repository...")
    (if (clone-repository repo-url temp-dir)
        (let ((source-file (string-append temp-dir "/" config-path)))
          (if (file-exists? source-file)
              (begin
                (copy-file source-file target-path)
                (run-command (format #f "rm -rf '~a'" temp-dir))
                (success ".spacemacs imported successfully!")
                #t)
              (begin
                (warn (format #f "Could not find ~a in repository" config-path))
                (run-command (format #f "rm -rf '~a'" temp-dir))
                #f)))
        (begin
          (warn "Failed to clone repository, creating default config instead")
          #f))))

(define (install-spacemacs!)
  "Install Spacemacs to ~/.emacs.d"
  (let ((emacs-dir (string-append (getenv "HOME") "/.emacs.d")))
    (info "Installing Spacemacs to ~/.emacs.d...")
    
    (when (file-exists-and-directory? emacs-dir)
      (warn "~/.emacs.d already exists")
      (when (yes-or-no? "Backup and replace with Spacemacs? [y/N] ")
        (let ((backup (backup-path emacs-dir)))
          (rename-file emacs-dir backup)
          (info "Backed up existing .emacs.d"))))
    
    (unless (file-exists? emacs-dir)
      (clone-repository "https://github.com/syl20bnr/spacemacs" emacs-dir))))

(define (show-next-steps imported?)
  "Display next steps after installation"
  (success "Spacemacs installation complete!")
  (newline)
  (info "Next steps:")
  (info "  1. Apply config: sudo guix system reconfigure /etc/config.scm")
  (info "  2. Launch Emacs to complete Spacemacs setup")
  (if imported?
      (info "  3. Imported config will install its packages on first launch")
      (info "  3. First launch will download and install packages (may take a while)"))
  (newline)
  (info "Spacemacs quick start:")
  (info "  SPC f f - Find file")
  (info "  SPC p f - Find file in project")
  (info "  SPC b b - Switch buffer")
  (info "  SPC w / - Split window vertically")
  (info "  SPC w - - Split window horizontally")
  (info "  SPC q q - Quit")
  (newline)
  (unless imported?
    (info "To import your config later, see: ~/guix-customize/EMACS_IMPORT_GUIDE.md"))
  (newline))

(define (add-spacemacs)
  "Main procedure to install and configure Spacemacs"
  (newline)
  (display "=== Installing Spacemacs ===")
  (newline)
  (newline)
  
  ;; Ensure Emacs is in config
  (if (file-contains? config-file "emacs")
      (info "Emacs already in configuration")
      (ensure-emacs-in-config!))
  
  ;; Ask about importing existing config
  (newline)
  (let* ((import? (yes-or-no? "Do you have an existing Spacemacs config (.spacemacs) to import? [y/N] "))
         (imported? #f))
    
    (when import?
      (newline)
      (info "Import options:")
      (info "  1. Git repository URL (for .spacemacs file)")
      (info "  2. Skip import (install fresh, import manually later)")
      (newline)
      (let ((choice (read-user-input "Enter choice [1-2]: ")))
        (cond
         ((string=? choice "1")
          (let ((repo-url (read-user-input "Enter Git repository URL (e.g., https://github.com/user/dotfiles): "))
                (config-path (read-user-input "Path to .spacemacs in repo (e.g., .spacemacs or emacs/.spacemacs): ")))
            (unless (string=? repo-url "")
              (info (format #f "Will import .spacemacs from: ~a" repo-url))
              ;; Install Spacemacs first
              (install-spacemacs!)
              ;; Then try to import config
              (set! imported? (import-spacemacs-config 
                               repo-url 
                               (if (string=? config-path "") ".spacemacs" config-path))))))
         ((string=? choice "2")
          (info "Skipping import - you can manually import later")
          (info "See: ~/guix-customize/EMACS_IMPORT_GUIDE.md"))
         (else
          (warn "Invalid choice, will create default config")))))
    
    ;; Install Spacemacs if not already done
    (unless imported?
      (install-spacemacs!))
    
    ;; Create default config if needed
    (let ((spacemacs-config (string-append (getenv "HOME") "/.spacemacs")))
      (if (and (not imported?) (not (file-exists? spacemacs-config)))
          (begin
            (info "Creating basic .spacemacs configuration...")
            (create-default-spacemacs-config!))
          (info ".spacemacs already exists, keeping your configuration")))
    
    ;; Show next steps
    (show-next-steps imported?)))

;;; Main entry point
(add-spacemacs)