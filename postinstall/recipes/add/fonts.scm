#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; Shared recipe: Install common fonts for programming and general use
;;; Can be called from any platform's customize tool

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 match)
             (ice-9 pretty-print)
             (srfi srfi-1))

;;; Configuration
(define config-file
  (or (getenv "CONFIG_FILE") "/etc/config.scm"))

;;; Display utilities
(define (info . args)
  (format #t "  ~a\n" (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

(define (success . args)
  (format #t "\n\033[1;32m[[OK]]\033[0m ~a\n" 
          (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

;;; Font package list
(define font-packages
  '("font-fira-code"           ; Popular programming font with ligatures
    "font-jetbrains-mono"      ; JetBrains programming font
    "font-dejavu"              ; DejaVu fonts (good coverage)
    "font-liberation"          ; Liberation fonts (metric-compatible with Arial, etc.)
    "font-gnu-freefont"        ; GNU FreeFont
    "font-awesome"             ; Icon font
    "font-google-noto"))       ; Google Noto (comprehensive Unicode)

;;; Read all S-expressions from config file
(define (read-all-exprs filepath)
  (call-with-input-file filepath
    (lambda (port)
      (let loop ((exprs '()))
        (let ((expr (read port)))
          (if (eof-object? expr)
              (reverse exprs)
              (loop (cons expr exprs))))))))

;;; Check if config has minimal packages definition
(define (has-minimal-packages? exprs)
  (any (lambda (expr)
         (match expr
           (('operating-system fields ...)
            (any (lambda (field)
                   (match field
                     (('packages '%base-packages) #t)
                     (_ #f)))
                 fields))
           (_ #f)))
       exprs))

;;; Check if package is already in config
(define (has-package? package-name content)
  (string-contains content (format #f "\"~a\"" package-name)))

;;; Generate package specification line
(define (package-spec-line package-name indent)
  (format #f "~a(specification->package \"~a\")" 
          (make-string indent #\space)
          package-name))

;;; Read file as string
(define (read-file filepath)
  (call-with-input-file filepath
    (lambda (port)
      (read-string port))))

;;; Write string to file
(define (write-file filepath content)
  (call-with-output-file filepath
    (lambda (port)
      (display content port))))

;;; Add fonts to minimal config
(define (add-fonts-minimal content)
  (let* ((package-lines (map (lambda (pkg)
                               (string-append 
                                 (package-spec-line pkg 16)
                                 "\n"))
                             font-packages))
         (package-list (string-concatenate package-lines))
         (replacement (string-append
                        "(packages\n"
                        "  (append\n"
                        "   (list\n"
                        package-list
                        "         )\n"
                        "   %base-packages))")))
    (regexp-substitute/global #f 
                              "\\(packages %base-packages\\)"
                              content
                              'pre
                              replacement
                              'post)))

;;; Add fonts to existing packages list
(define (add-fonts-existing content)
  (let loop ((packages font-packages)
             (result content))
    (if (null? packages)
        result
        (let ((pkg (car packages)))
          (if (has-package? pkg result)
              (loop (cdr packages) result)
              (let* ((pattern "specification->package")
                     (insertion (string-append 
                                  "\n"
                                  (package-spec-line pkg 16)))
                     (new-content 
                       (regexp-substitute/global #f
                                                 pattern
                                                 result
                                                 'pre
                                                 pattern
                                                 insertion
                                                 'post
                                                 1)))
                (loop (cdr packages) new-content)))))))

;;; Main function to add fonts
(define (add-fonts)
  (display "\n")
  (display "=== Installing Common Fonts ===\n")
  (display "\n")
  
  (info "Adding font packages to config.scm...")
  
  (let* ((exprs (read-all-exprs config-file))
         (content (read-file config-file))
         (new-content
           (if (has-minimal-packages? exprs)
               (add-fonts-minimal content)
               (add-fonts-existing content))))
    
    (write-file config-file new-content)
    
    (success "Font packages added to configuration!")
    (display "\n")
    (info "Fonts added:")
    (info "  - Fira Code (programming, ligatures)")
    (info "  - JetBrains Mono (programming)")
    (info "  - DejaVu (general use)")
    (info "  - Liberation (MS-compatible)")
    (info "  - GNU FreeFont (Unicode coverage)")
    (info "  - Font Awesome (icons)")
    (info "  - Google Noto (comprehensive)")
    (display "\n")
    (info "After reconfiguring, you may need to rebuild font cache:")
    (info "  fc-cache -f -v")
    (display "\n")
    (info "Apply changes with: sudo guix system reconfigure /etc/config.scm")))

;;; Entry point
(add-fonts)