#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; add-vanilla-emacs.scm --- Install vanilla Emacs with minimal configuration
;;; Can be called from any platform's customize tool

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 regex)
             (srfi srfi-1))

;;; Configuration

(define config-file
  (or (getenv "CONFIG_FILE") "/etc/config.scm"))

(define import-emacs-config "")

;;; Terminal colors and output

(define (info . args)
  (format #t "  ~a~%" (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

(define (warn . args)
  (format #t "\n\033[1;33m[warn]\033[0m ~a~%"
          (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

(define (success . args)
  (format #t "\n\033[1;32m[OK]\033[0m ~a~%"
          (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

;;; Utility procedures

(define (file-contains-string? filepath pattern)
  "Check if file contains the given string pattern."
  (call-with-input-file filepath
    (lambda (port)
      (let loop ((line (read-line port)))
        (cond
         ((eof-object? line) #f)
         ((string-contains line pattern) #t)
         (else (loop (read-line port))))))))

(define (read-user-input prompt)
  "Read a line from /dev/tty with the given prompt."
  (display prompt)
  (force-output)
  (call-with-input-file "/dev/tty"
    (lambda (port)
      (let ((line (read-line port)))
        (if (eof-object? line) "" line)))))

(define (yes-response? str)
  "Check if string is a yes response (y or Y)."
  (and (string? str)
       (> (string-length str) 0)
       (or (char=? (string-ref str 0) #\y)
           (char=? (string-ref str 0) #\Y))))

(define (run-command cmd)
  "Execute shell command, return exit status."
  (let ((status (system cmd)))
    (zero? status)))

(define (sed-insert-after-use-modules text)
  "Insert text after (use-modules line in config file."
  (let ((cmd (format #f "sed -i '/(use-modules/a\\             ~a' ~s"
                     text config-file)))
    (run-command cmd)))

(define (sed-replace pattern replacement)
  "Replace pattern with replacement in config file."
  (let ((cmd (format #f "sed -i 's|~a|~a|' ~s"
                     pattern replacement config-file)))
    (run-command cmd)))

(define (backup-file filepath)
  "Create timestamped backup of file."
  (let* ((timestamp (strftime "%Y%m%d-%H%M%S" (localtime (current-time))))
         (backup-path (format #f "~a.backup.~a" filepath timestamp)))
    (run-command (format #f "mv ~s ~s" filepath backup-path))
    (info (format #f "Backed up to: ~a" backup-path))))

(define (backup-emacs-config)
  "Backup existing Emacs configuration files."
  (let ((emacs-dir (string-append (getenv "HOME") "/.emacs.d"))
        (emacs-file (string-append (getenv "HOME") "/.emacs")))
    (when (file-exists? emacs-dir)
      (backup-file emacs-dir))
    (when (file-exists? emacs-file)
      (backup-file emacs-file))))

(define (create-emacs-directory)
  "Create ~/.emacs.d directory if it doesn't exist."
  (let ((emacs-dir (string-append (getenv "HOME") "/.emacs.d")))
    (unless (file-exists? emacs-dir)
      (run-command (format #f "mkdir -p ~s" emacs-dir)))))

;;; Main procedures

(define (add-emacs-to-config)
  "Add Emacs package to config.scm if not already present."
  (if (file-contains-string? config-file "emacs")
      (info "Emacs already in configuration")
      (begin
        (info "Adding Emacs package to config.scm...")
        
        ;; Add package modules if not present
        (unless (file-contains-string? config-file "gnu packages emacs")
          (sed-insert-after-use-modules "(gnu packages emacs)\\n             (gnu packages version-control)"))
        
        ;; Add emacs to packages
        (if (file-contains-string? config-file "(packages %base-packages)")
            ;; Minimal config - expand to use append
            (sed-replace "(packages %base-packages)"
                         "(packages\\n  (append\\n   (list emacs\\n         git)\\n   %base-packages))")
            ;; Already has packages list, add to it
            (run-command (format #f "sed -i '/(packages/,/))/ { /list/ { s/list/list emacs\\n         git/ } }' ~s"
                                 config-file)))
        
        (info "Emacs added to configuration"))))

(define (prompt-import-config)
  "Ask user if they want to import existing Emacs config."
  (newline)
  (let ((response (read-user-input "Do you have an existing vanilla Emacs config to import? [y/N] ")))
    (when (yes-response? response)
      (newline)
      (info "Import options:")
      (info "  1. Git repository URL (for .emacs.d or init.el)")
      (info "  2. Skip import (install fresh, import manually later)")
      (newline)
      (let ((choice (read-user-input "Enter choice [1-2]: ")))
        (cond
         ((string=? choice "1")
          (let ((repo-url (read-user-input "Enter Git repository URL (e.g., https://github.com/user/emacs-config): ")))
            (if (and (string? repo-url) (> (string-length repo-url) 0))
                (begin
                  (info (format #f "Will import config from: ~a" repo-url))
                  (set! import-emacs-config repo-url))
                (warn "No URL provided, will create default config"))))
         ((string=? choice "2")
          (info "Skipping import - you can manually import later")
          (info "See: ~/guix-customize/EMACS_IMPORT_GUIDE.md"))
         (else
          (warn "Invalid choice, will create default config")))))))

(define (import-emacs-config-from-git)
  "Import Emacs configuration from Git repository."
  (info "Importing your Emacs configuration...")
  
  (let ((emacs-dir (string-append (getenv "HOME") "/.emacs.d"))
        (emacs-file (string-append (getenv "HOME") "/.emacs")))
    
    (when (or (file-exists? emacs-dir) (file-exists? emacs-file))
      (warn "Existing Emacs configuration found")
      (let ((response (read-user-input "Backup and replace with imported config? [y/N] ")))
        (when (yes-response? response)
          (backup-emacs-config)
          (info "Backed up existing Emacs configuration"))))
    
    (if (run-command (format #f "git clone ~s ~s" import-emacs-config emacs-dir))
        (success "Emacs config imported successfully!")
        (begin
          (warn "Failed to clone repository, creating default config instead")
          (set! import-emacs-config "")))))

(define emacs-init-el-content
  ";;; init.el --- Minimal Emacs configuration -*- lexical-binding: t -*-

;;; Commentary:
;; A minimal Emacs configuration with sensible defaults

;;; Code:

;; Performance tweaks
(setq gc-cons-threshold 100000000)
(setq read-process-output-max (* 1024 1024))

;; Package management
(require 'package)
(setq package-archives '((\"melpa\" . \"https://melpa.org/packages/\")
                          (\"gnu\" . \"https://elpa.gnu.org/packages/\")))
(package-initialize)

;; UI improvements
(setq inhibit-startup-message t)
(tool-bar-mode -1)
(menu-bar-mode -1)
(scroll-bar-mode -1)
(column-number-mode t)
(show-paren-mode t)
(global-hl-line-mode t)

;; Line numbers
(global-display-line-numbers-mode t)
(setq display-line-numbers-type 'relative)

;; Better defaults
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(setq require-final-newline t)
(setq visible-bell t)
(setq ring-bell-function 'ignore)
(setq backup-directory-alist '((\"\" . \"~/.emacs.d/backups\")))
(setq auto-save-file-name-transforms '((\".*\" \"~/.emacs.d/auto-save-list/\" t)))

;; Recent files
(recentf-mode 1)
(setq recentf-max-menu-items 25)
(setq recentf-max-saved-items 25)

;; IDO mode for better file/buffer switching
(ido-mode 1)
(ido-everywhere 1)
(setq ido-enable-flex-matching t)

;; Electric pair mode
(electric-pair-mode 1)

;; Whitespace cleanup
(add-hook 'before-save-hook 'whitespace-cleanup)

;; Custom key bindings
(global-set-key (kbd \"C-x C-b\") 'ibuffer)
(global-set-key (kbd \"M-/\") 'hippie-expand)

;; Theme (built-in)
(load-theme 'wombat t)

;; Custom file
(setq custom-file (expand-file-name \"custom.el\" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))

;;; init.el ends here
")

(define (create-minimal-emacs-config)
  "Create minimal Emacs configuration if not imported."
  (info "Creating minimal Emacs configuration...")
  
  (let ((emacs-dir (string-append (getenv "HOME") "/.emacs.d"))
        (emacs-file (string-append (getenv "HOME") "/.emacs")))
    
    (when (or (file-exists? emacs-dir) (file-exists? emacs-file))
      (warn "Existing Emacs configuration found")
      (let ((response (read-user-input "Backup and create minimal config? [y/N] ")))
        (if (yes-response? response)
            (begin
              (backup-emacs-config)
              (info "Backed up existing Emacs configuration"))
            (begin
              (info "Keeping existing configuration")
              (exit 0)))))
    
    ;; Create init.el with sensible defaults
    (create-emacs-directory)
    (call-with-output-file (string-append emacs-dir "/init.el")
      (lambda (port)
        (display emacs-init-el-content port)))))

(define (print-next-steps)
  "Print next steps and usage information."
  (success "Vanilla Emacs configuration created!")
  (newline)
  (info "Next steps:")
  (info "  1. Apply config: sudo guix system reconfigure /etc/config.scm")
  (info "  2. Launch Emacs to start using it")
  (when (string=? import-emacs-config "")
    (info "  3. Customize ~/.emacs.d/init.el as needed"))
  (newline)
  (info "Basic Emacs commands:")
  (info "  C-x C-f - Find file")
  (info "  C-x C-s - Save file")
  (info "  C-x b   - Switch buffer")
  (info "  C-x 2   - Split window horizontally")
  (info "  C-x 3   - Split window vertically")
  (info "  C-x 1   - Close other windows")
  (info "  C-x C-c - Quit Emacs")
  (newline)
  (when (string=? import-emacs-config "")
    (info "To add packages:")
    (info "  M-x package-list-packages")
    (info "  i (mark), x (install), d (mark delete)")
    (newline)
    (info "To import your config later, see: ~/guix-customize/EMACS_IMPORT_GUIDE.md"))
  (newline))

(define (add-vanilla-emacs)
  "Main procedure: Install vanilla Emacs with minimal configuration."
  (newline)
  (display "=== Installing Vanilla Emacs ===\n")
  (newline)
  
  (add-emacs-to-config)
  (prompt-import-config)
  
  ;; Import or create config
  (if (and (string? import-emacs-config) (> (string-length import-emacs-config) 0))
      (import-emacs-config-from-git)
      (when (string=? import-emacs-config "")
        (create-minimal-emacs-config)))
  
  (print-next-steps))

;;; Main entry point

(add-vanilla-emacs)