#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 ftw)
             (srfi srfi-1)
             (srfi srfi-26))

;;; Shared recipe: Install and configure Doom Emacs
;;; Can be called from any platform's customize tool

;;; Configuration
(define config-file
  (or (getenv "CONFIG_FILE") "/etc/config.scm"))

(define import-doom-config "")

;;; Color output helpers
(define (info msg . args)
  (apply format #t (string-append "  " msg "\n") args))

(define (warn msg . args)
  (display "\n\x1b[1;33m[warn]\x1b[0m ")
  (apply format #t (string-append msg "\n") args))

(define (success msg . args)
  (display "\n\x1b[1;32m[OK]\x1b[0m ")
  (apply format #t (string-append msg "\n") args))

;;; Utility procedures
(define (run-command cmd)
  "Execute shell command and return exit status"
  (system cmd))

(define (run-command-output cmd)
  "Execute shell command and return output as string"
  (let* ((port (open-input-pipe cmd))
         (output (read-string port))
         (status (close-pipe port)))
    (values output status)))

(define (file-contains? filepath pattern)
  "Check if file contains the given pattern"
  (let ((content (call-with-input-file filepath read-string)))
    (string-contains content pattern)))

(define (read-line-interactive)
  "Read a line from /dev/tty for interactive input"
  (let ((port (open-input-file "/dev/tty")))
    (let ((line (read-line port)))
      (close-port port)
      line)))

(define (yes-or-no? prompt)
  "Ask a yes/no question and return boolean"
  (display prompt)
  (flush-all-ports)
  (let ((answer (read-line-interactive)))
    (and (string? answer)
         (or (string=? answer "y")
             (string=? answer "Y")))))

(define (directory-exists? path)
  "Check if directory exists"
  (and (file-exists? path)
       (eq? (stat:type (stat path)) 'directory)))

(define (backup-directory path)
  "Create timestamped backup of directory"
  (let* ((timestamp (strftime "%Y%m%d-%H%M%S" (localtime (current-time))))
         (backup-path (string-append path ".backup." timestamp)))
    (run-command (format #f "mv ~s ~s" path backup-path))
    backup-path))

;;; Config file manipulation
(define (add-emacs-modules)
  "Add Emacs-related use-modules to config.scm if not present"
  (unless (file-contains? config-file "gnu packages emacs")
    (info "Adding Emacs package modules to config.scm...")
    (run-command
     (format #f "sed -i '/(use-modules/a\\             (gnu packages emacs)\\n             (gnu packages version-control)\\n             (gnu packages rust-apps))' ~s"
             config-file))))

(define (add-emacs-packages)
  "Add Emacs and dependencies to packages list"
  (info "Adding Emacs and dependencies to configuration...")
  (if (file-contains? config-file "(packages %base-packages)")
      ;; Minimal config - expand to use append
      (run-command
       (format #f "sed -i 's|(packages %base-packages)|(packages\\n  (append\\n   (list emacs\\n         git\\n         ripgrep\\n         fd)\\n   %base-packages))|' ~s"
               config-file))
      ;; Already has packages list, add to it
      (run-command
       (format #f "sed -i '/(packages/,/))/ { /list/ { s/list/list emacs\\n         git\\n         ripgrep\\n         fd/ } }' ~s"
               config-file))))

(define (ensure-emacs-in-config)
  "Ensure Emacs is configured in config.scm"
  (if (file-contains? config-file "emacs")
      (info "Emacs already in configuration")
      (begin
        (add-emacs-modules)
        (add-emacs-packages)
        (info "Emacs and dependencies added to configuration"))))

;;; Import configuration handling
(define (prompt-import-config)
  "Ask user about importing existing Doom config"
  (newline)
  (when (yes-or-no? "Do you have an existing Doom Emacs config to import? [y/N] ")
    (newline)
    (info "Import options:")
    (info "  1. Git repository URL")
    (info "  2. Skip import (install fresh, import manually later)")
    (newline)
    (display "Enter choice [1-2]: ")
    (flush-all-ports)
    (let ((choice (read-line-interactive)))
      (cond
       ((string=? choice "1")
        (display "Enter Git repository URL (e.g., https://github.com/user/doom-config): ")
        (flush-all-ports)
        (let ((repo-url (read-line-interactive)))
          (if (and (string? repo-url) (not (string=? repo-url "")))
              (begin
                (info "Will import config from: ~a" repo-url)
                (set! import-doom-config repo-url))
              (warn "No URL provided, will create default config"))))
       ((string=? choice "2")
        (info "Skipping import - you can manually import later")
        (info "See: ~/guix-customize/EMACS_IMPORT_GUIDE.md"))
       (else
        (warn "Invalid choice, will create default config"))))))

;;; Doom Emacs installation
(define (backup-existing-emacs)
  "Backup existing Emacs configuration if present"
  (let ((config-emacs (string-append (getenv "HOME") "/.config/emacs"))
        (emacs-d (string-append (getenv "HOME") "/.emacs.d")))
    (when (or (directory-exists? config-emacs)
              (directory-exists? emacs-d))
      (warn "Existing Emacs configuration found")
      (when (yes-or-no? "Backup and replace with Doom Emacs? [y/N] ")
        (when (directory-exists? config-emacs)
          (backup-directory config-emacs)
          (info "Backed up ~/.config/emacs"))
        (when (directory-exists? emacs-d)
          (backup-directory emacs-d)
          (info "Backed up ~/.emacs.d"))
        #t))))

(define (clone-doom-emacs)
  "Clone Doom Emacs framework"
  (let ((doom-path (string-append (getenv "HOME") "/.config/emacs")))
    (info "Installing Doom Emacs to ~/.config/emacs...")
    (zero? (run-command
            (format #f "git clone --depth 1 https://github.com/doomemacs/doomemacs ~s"
                    doom-path)))))

(define (install-doom)
  "Run Doom installer"
  (let ((doom-bin (string-append (getenv "HOME") "/.config/emacs/bin/doom")))
    (info "Running Doom installer...")
    (zero? (run-command (format #f "~s install --no-env --no-fonts" doom-bin)))))

(define (import-doom-config-from-git url)
  "Import Doom config from git repository"
  (let ((doom-config (string-append (getenv "HOME") "/.config/doom"))
        (temp-dir (string-append (getenv "HOME") "/.config/doom.tmp")))
    (info "Importing your Doom config from repository...")
    (if (zero? (run-command (format #f "git clone ~s ~s" url temp-dir)))
        (begin
          (run-command (format #f "mv ~s/* ~s/" temp-dir doom-config))
          (run-command (format #f "rm -rf ~s" temp-dir))
          (success "Config imported successfully!")
          (info "Running doom sync to install packages...")
          (run-command
           (format #f "~s/.config/emacs/bin/doom sync" (getenv "HOME")))
          #t)
        (begin
          (warn "Failed to clone repository, creating default config instead")
          #f))))

(define (create-default-init-el)
  "Create default Doom init.el"
  (let ((init-file (string-append (getenv "HOME") "/.config/doom/init.el")))
    (call-with-output-file init-file
      (lambda (port)
        (display ";;; init.el -*- lexical-binding: t; -*-\n\n" port)
        (display "(doom! :input\n\n" port)
        (display "       :completion\n" port)
        (display "       company\n" port)
        (display "       vertico\n\n" port)
        (display "       :ui\n" port)
        (display "       doom\n" port)
        (display "       doom-dashboard\n" port)
        (display "       hl-todo\n" port)
        (display "       modeline\n" port)
        (display "       ophints\n" port)
        (display "       (popup +defaults)\n" port)
        (display "       treemacs\n" port)
        (display "       vc-gutter\n" port)
        (display "       vi-tilde-fringe\n" port)
        (display "       workspaces\n\n" port)
        (display "       :editor\n" port)
        (display "       (evil +everywhere)\n" port)
        (display "       file-templates\n" port)
        (display "       fold\n" port)
        (display "       (format +onsave)\n" port)
        (display "       multiple-cursors\n" port)
        (display "       rotate-text\n" port)
        (display "       snippets\n\n" port)
        (display "       :emacs\n" port)
        (display "       dired\n" port)
        (display "       electric\n" port)
        (display "       ibuffer\n" port)
        (display "       undo\n" port)
        (display "       vc\n\n" port)
        (display "       :term\n" port)
        (display "       vterm\n\n" port)
        (display "       :checkers\n" port)
        (display "       syntax\n\n" port)
        (display "       :tools\n" port)
        (display "       (eval +overlay)\n" port)
        (display "       lookup\n" port)
        (display "       lsp\n" port)
        (display "       magit\n" port)
        (display "       make\n" port)
        (display "       tree-sitter\n\n" port)
        (display "       :os\n" port)
        (display "       (:if IS-MAC macos)\n" port)
        (display "       tty\n\n" port)
        (display "       :lang\n" port)
        (display "       (cc +lsp)\n" port)
        (display "       data\n" port)
        (display "       emacs-lisp\n" port)
        (display "       (go +lsp)\n" port)
        (display "       (javascript +lsp)\n" port)
        (display "       json\n" port)
        (display "       (markdown +grip)\n" port)
        (display "       (org +pretty)\n" port)
        (display "       (python +lsp)\n" port)
        (display "       (rust +lsp)\n" port)
        (display "       sh\n" port)
        (display "       web\n" port)
        (display "       yaml\n\n" port)
        (display "       :email\n\n" port)
        (display "       :app\n\n" port)
        (display "       :config\n" port)
        (display "       (default +bindings +smartparens))\n" port)))))

(define (create-default-config-el)
  "Create default Doom config.el"
  (let ((config-el (string-append (getenv "HOME") "/.config/doom/config.el")))
    (call-with-output-file config-el
      (lambda (port)
        (display ";;; config.el -*- lexical-binding: t; -*-\n\n" port)
        (display ";; Basic settings\n" port)
        (display "(setq user-full-name \"Your Name\"\n" port)
        (display "      user-mail-address \"your@email.com\")\n\n" port)
        (display ";; Theme\n" port)
        (display "(setq doom-theme 'doom-one)\n\n" port)
        (display ";; Line numbers\n" port)
        (display "(setq display-line-numbers-type 'relative)\n\n" port)
        (display ";; Font\n" port)
        (display "(setq doom-font (font-spec :family \"monospace\" :size 14))\n" port)))))

(define (create-default-packages-el)
  "Create default Doom packages.el"
  (let ((packages-el (string-append (getenv "HOME") "/.config/doom/packages.el")))
    (call-with-output-file packages-el
      (lambda (port)
        (display ";; -*- no-byte-compile: t; -*-\n" port)
        (display ";;; packages.el\n\n" port)
        (display ";; Add your custom packages here\n" port)))))

(define (create-default-doom-config)
  "Create default Doom configuration files"
  (let ((doom-config-dir (string-append (getenv "HOME") "/.config/doom"))
        (init-file (string-append (getenv "HOME") "/.config/doom/init.el"))
        (config-file-path (string-append (getenv "HOME") "/.config/doom/config.el"))
        (packages-file (string-append (getenv "HOME") "/.config/doom/packages.el")))
    (info "Creating basic Doom configuration...")
    (unless (file-exists? init-file)
      (create-default-init-el))
    (unless (file-exists? config-file-path)
      (create-default-config-el))
    (unless (file-exists? packages-file)
      (create-default-packages-el))))

(define (setup-doom-config)
  "Setup Doom configuration - import from git or create default"
  (let ((doom-config-dir (string-append (getenv "HOME") "/.config/doom")))
    (unless (directory-exists? doom-config-dir)
      (run-command (format #f "mkdir -p ~s" doom-config-dir)))
    
    (if (and (not (string=? import-doom-config ""))
             (import-doom-config-from-git import-doom-config))
        (set! import-doom-config "imported")
        (begin
          (set! import-doom-config "")
          (create-default-doom-config)))))

(define (print-next-steps)
  "Print next steps and helpful information"
  (success "Doom Emacs installation complete!")
  (newline)
  (info "Next steps:")
  (info "  1. Apply config: sudo guix system reconfigure /etc/config.scm")
  (if (string=? import-doom-config "")
      (begin
        (info "  2. Run: ~/.config/emacs/bin/doom sync")
        (info "  3. Launch Emacs to complete setup"))
      (info "  2. Launch Emacs (packages already synced)"))
  (newline)
  (info "Doom Emacs quick start:")
  (info "  SPC f f - Find file")
  (info "  SPC p f - Find file in project")
  (info "  SPC b b - Switch buffer")
  (info "  SPC w v - Split window vertically")
  (info "  SPC w s - Split window horizontally")
  (info "  SPC q q - Quit")
  (newline)
  (when (string=? import-doom-config "")
    (info "To import your config later, see: ~/guix-customize/EMACS_IMPORT_GUIDE.md"))
  (info "Documentation: https://docs.doomemacs.org")
  (newline))

;;; Main procedure
(define (add-doom-emacs)
  "Main procedure to install and configure Doom Emacs"
  (newline)
  (display "=== Installing Doom Emacs ===\n")
  (newline)
  
  ;; Ensure Emacs is in config.scm
  (ensure-emacs-in-config)
  
  ;; Ask about importing config
  (prompt-import-config)
  
  ;; Handle existing Emacs installations
  (when (or (not (directory-exists? (string-append (getenv "HOME") "/.config/emacs")))
            (backup-existing-emacs))
    
    ;; Clone and install Doom
    (when (clone-doom-emacs)
      (when (install-doom)
        
        ;; Setup configuration
        (setup-doom-config)
        
        ;; Print completion message
        (print-next-steps)))))

;;; Entry point
(add-doom-emacs)