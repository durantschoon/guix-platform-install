#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 match)
             (ice-9 pretty-print)
             (srfi srfi-1))

;;; Shared recipe: Install common development tools
;;; Can be called from any platform's customize tool

;; Configuration
(define config-file 
  (or (getenv "CONFIG_FILE") "/etc/config.scm"))

;; Color output helpers
(define (info . args)
  (format #t "  ~a~%" (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

(define (success . args)
  (format #t "~%\x1b[1;32m[[OK]]\x1b[0m ~a~%"
          (string-join (map (lambda (x) (format #f "~a" x)) args) " ")))

;; List of common development tools
(define dev-packages
  '("git"
    "vim"
    "emacs"
    "make"
    "gcc-toolchain"
    "python"
    "node"
    "go"
    "curl"
    "wget"
    "ripgrep"
    "fd"
    "tmux"
    "htop"))

;; Read all S-expressions from file
(define (read-all-exprs filepath)
  (call-with-input-file filepath
    (lambda (port)
      (let loop ((exprs '()))
        (let ((expr (read port)))
          (if (eof-object? expr)
              (reverse exprs)
              (loop (cons expr exprs))))))))

;; Write all S-expressions to file
(define (write-all-exprs filepath exprs)
  (call-with-output-file filepath
    (lambda (port)
      (for-each (lambda (expr)
                  (pretty-print expr port)
                  (newline port))
                exprs))))

;; Check if config has minimal packages definition
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

;; Check if package already exists in config
(define (package-exists? exprs pkg-name)
  (any (lambda (expr)
         (let ((str (format #f "~s" expr)))
           (string-contains str pkg-name)))
       exprs))

;; Create package specification S-expression
(define (make-package-spec pkg-name)
  `(specification->package ,pkg-name))

;; Transform minimal packages to extended list
(define (expand-minimal-packages field)
  (match field
    (('packages '%base-packages)
     `(packages
       (append
        (list ,@(map make-package-spec dev-packages))
        %base-packages)))
    (_ field)))

;; Add package to existing packages list
(define (add-package-to-list field pkg-name)
  (match field
    (('packages ('append ('list specs ...) rest ...))
     (if (any (lambda (spec)
                (match spec
                  (('specification->package name)
                   (equal? name pkg-name))
                  (_ #f)))
              specs)
         field
         `(packages
           (append
            (list ,@specs ,(make-package-spec pkg-name))
            ,@rest))))
    (_ field)))

;; Process operating-system form to add packages
(define (add-packages-to-os-form expr packages-to-add minimal?)
  (match expr
    (('operating-system fields ...)
     `(operating-system
       ,@(map (lambda (field)
                (if minimal?
                    (expand-minimal-packages field)
                    (fold (lambda (pkg acc)
                            (add-package-to-list acc pkg))
                          field
                          packages-to-add)))
              fields)))
    (_ expr)))

;; Main conversion logic
(define (add-development)
  (display "\n=== Installing Development Tools ===\n\n")
  
  (info "Adding development packages to config.scm...")
  
  (let* ((exprs (read-all-exprs config-file))
         (minimal? (has-minimal-packages? exprs))
         (packages-to-add (if minimal?
                              '()
                              (filter (lambda (pkg)
                                        (not (package-exists? exprs pkg)))
                                      dev-packages)))
         (new-exprs (map (lambda (expr)
                           (if minimal?
                               (add-packages-to-os-form expr '() #t)
                               (add-packages-to-os-form expr packages-to-add #f)))
                         exprs)))
    
    (write-all-exprs config-file new-exprs)
    
    (success "Development tools added to configuration!")
    (newline)
    (info "Packages added:")
    (for-each (lambda (pkg)
                (info (format #f "  - ~a" pkg)))
              dev-packages)
    (newline)
    (info "Apply changes with: sudo guix system reconfigure /etc/config.scm")))

;; Run if called directly
(when (and (not (null? (command-line)))
           (string=? (car (command-line)) config-file))
  (add-development))

;; Export for use as module
(add-development)