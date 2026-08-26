;;; metadata-ssh-keys.scm --- testable OCI metadata SSH-key runtime helpers.

(use-modules (ice-9 rdelim)
             (srfi srfi-1))

(define %metadata-max-attempts 12)
(define %metadata-retry-delay 3)

(define (metadata-unquote-value line)
  "Trim LINE and remove one surrounding pair of JSON quotes, if present."
  (let* ((trimmed (string-trim-both line))
         (n (string-length trimmed)))
    (if (and (>= n 2)
             (char=? (string-ref trimmed 0) #\")
             (char=? (string-ref trimmed (- n 1)) #\"))
        (substring trimmed 1 (- n 1))
        trimmed)))

(define (metadata-key-line? line)
  "Return true only for a plausible OpenSSH public-key line."
  (let ((trimmed (metadata-unquote-value line)))
    (and (> (string-length trimmed) 0)
         (or (string-prefix? "ssh-" trimmed)
             (string-prefix? "ecdsa-" trimmed)
             (string-prefix? "sk-ssh-" trimmed)
             (string-prefix? "sk-ecdsa-" trimmed)))))

(define (metadata-usable-keys lines)
  "Normalize and retain only plausible public keys from LINES."
  (map metadata-unquote-value (filter metadata-key-line? lines)))

(define (metadata-retry fetch-lines wait! log! max-attempts retry-delay)
  "Retry FETCH-LINES until it yields usable keys or MAX-ATTEMPTS is reached.
WAIT! and LOG! are injected so the policy is fully testable without sleeping or
network access.  Return (installed ATTEMPT KEY ...) or (exhausted ATTEMPT)."
  (let loop ((attempt 1))
    (let* ((lines (or (fetch-lines) '()))
           (keys (metadata-usable-keys lines)))
      (cond ((not (null? keys))
             (cons* 'installed attempt keys))
            ((>= attempt max-attempts)
             (list 'exhausted attempt))
            (else
             (log! attempt max-attempts retry-delay)
             (wait! retry-delay)
             (loop (+ attempt 1)))))))

(define (metadata-read-lines path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((lines '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse lines)
              (loop (cons line lines))))))))

(define (metadata-install-from-oci! user wget required?)
  "Fetch and install USER's OCI metadata keys with bounded retries.
Return false after exhaustion only when REQUIRED? says there is no baked-key
fallback.  Log outcomes to stderr and /dev/console without logging key data."
  (let* ((home (string-append "/home/" user))
         (ssh-dir (string-append home "/.ssh"))
         (target (string-append ssh-dir "/authorized_keys"))
         (scratch "/run/metadata-ssh-keys"))

    (define (emit line)
      (format (current-error-port) "metadata-ssh-keys: ~a~%" line)
      (force-output (current-error-port))
      (catch #t
        (lambda ()
          (call-with-output-file "/dev/console"
            (lambda (port)
              (format port "metadata-ssh-keys: ~a~%" line))))
        (lambda _ #f)))

    (define (fetch! url . extra)
      (when (file-exists? scratch) (delete-file scratch))
      (and (zero? (apply system* wget "-q" "-O" scratch
                         "--timeout=2" "--tries=1"
                         (append extra (list url))))
           (file-exists? scratch)
           (> (stat:size (stat scratch)) 0)))

    (define (fetch-lines)
      (and (or (fetch! (string-append
                        "http://169.254.169.254/opc/v2/instance/"
                        "metadata/ssh_authorized_keys")
                       "--header=Authorization: Bearer Oracle")
               (fetch! (string-append
                        "http://169.254.169.254/opc/v1/instance/"
                        "metadata/ssh_authorized_keys")))
           (metadata-read-lines scratch)))

    (define (install! keys)
      (let* ((pw (getpwnam user))
             (uid (passwd:uid pw))
             (gid (passwd:gid pw)))
        (unless (file-exists? ssh-dir) (mkdir ssh-dir))
        (chmod ssh-dir #o700)
        (chown ssh-dir uid gid)
        (call-with-output-file target
          (lambda (port)
            (format port "# Installed from OCI instance metadata.~%")
            (format port "# Rewritten on every boot; edit metadata, not this file.~%")
            (for-each (lambda (key) (format port "~a~%" key)) keys)))
        (chmod target #o600)
        (chown target uid gid)
        (emit (format #f "installed ~a key(s); directory mode 0700, file mode 0600"
                      (length keys)))))

    (let ((result
           (metadata-retry
            fetch-lines sleep
            (lambda (attempt maximum delay)
              (emit (format #f "attempt ~a/~a found no usable key; retrying in ~as"
                            attempt maximum delay)))
            %metadata-max-attempts %metadata-retry-delay)))
      (when (file-exists? scratch) (delete-file scratch))
      (if (eq? (car result) 'installed)
          (begin (install! (cddr result)) #t)
          (begin
            (emit (format #f "ERROR: no usable metadata key after ~a attempts"
                          (cadr result)))
            (if required?
                #f
                (begin
                  (emit "baked-key fallback present; continuing boot")
                  #t)))))))
