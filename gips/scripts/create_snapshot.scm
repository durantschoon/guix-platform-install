#!/usr/bin/env guile
!#

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 match)
             (ice-9 getopt-long)
             (ice-9 string-fun)
             (srfi srfi-1)
             (srfi srfi-13))

(define option-spec
  '((help           (single-char #\h) (value #f))))

(define (run-cmd-get-output cmd args)
  (let* ((port (apply open-pipe* OPEN_READ cmd args))
         (output (read-string port))
         (status (close-pipe port)))
    (unless (eqv? (status:exit-val status) 0)
      (format (current-error-port) "Error: command failed: ~a ~a\n" cmd args)
      (exit 1))
    (if (eof-object? output)
        ""
        (string-trim-both output))))

;; Rust's dirs::config_dir, which is where gipsd writes the token. Kept
;; identical to `default-config-dir` in scheme/gips/api.scm on purpose: this
;; script and the REPL client must never disagree about which file holds the
;; daemon's authority.
(define (default-config-dir)
  (let ((home (getenv "HOME")))
    (cond
     ((or (not home) (string-null? home)) ".")
     ((string=? (utsname:sysname (uname)) "Darwin")
      (string-append home "/Library/Application Support"))
     (else (let ((xdg (getenv "XDG_CONFIG_HOME")))
             (if (and xdg (not (string-null? xdg)))
                 xdg
                 (string-append home "/.config")))))))

(define (auth-token-file)
  (let ((from-env (getenv "GIPS_AUTH_TOKEN_FILE")))
    (if (and from-env (not (string-null? from-env)))
        from-env
        (string-append (default-config-dir) "/gips/auth-token"))))

;; Read the daemon's local auth token, or die naming the file we looked in.
;; /snapshot/create sits behind the mutating router's token check, so an
;; unauthenticated attempt is a guaranteed 401 — and a silent one, because
;; curl -f prints nothing. Failing here, before anything is published, is the
;; only honest option.
(define (auth-token)
  (let ((file (auth-token-file)))
    (unless (file-exists? file)
      (format (current-error-port)
              "Error: no gipsd auth token at ~a\n  Start gipsd once to create it, or point GIPS_AUTH_TOKEN_FILE at the right file.\n"
              file)
      (exit 1))
    (let ((token (string-trim-both (call-with-input-file file read-string))))
      (when (string-null? token)
        (format (current-error-port) "Error: gipsd auth token file is empty: ~a\n" file)
        (exit 1))
      token)))

(define (paths->json-array paths)
  (string-append "["
                 (string-join (map (lambda (p) (string-append "\"" p "\"")) paths) ", ")
                 "]"))

(define (main args)
  (let* ((options (getopt-long args option-spec))
         (help (option-ref options 'help #f))
         (positionals (option-ref options '() '())))
    
    (if (or help (< (length positionals) 2))
        (begin
          (format (current-error-port) "Usage: create_snapshot.scm <gns-name> <store-path> [<store-path> ...]\n")
          (exit 1)))

    (let* ((gns-name (car positionals))
           (store-paths (cdr positionals))
           ;; Read before anything is published: a run that cannot authenticate
           ;; must not get as far as uploading half a snapshot's worth of nars.
           (token (auth-token)))

      ;; 1. Publish all paths to the daemon to ensure they are pinned, in DB, and signed.
      (for-each (lambda (path)
                  (format #t "Publishing ~a to daemon...\n" path)
                  (run-cmd-get-output "gips" (list "publish" path "--gns-name" gns-name)))
                store-paths)
      
      ;; 2. Request the daemon to create the snapshot manifest securely
      (format #t "Requesting snapshot creation from daemon...\n")
      (let* ((json-body (string-append "{\"store_paths\": " (paths->json-array store-paths) "}"))
             (output (run-cmd-get-output "curl" (list "-s" "-f" "-X" "POST" "http://127.0.0.1:8080/snapshot/create"
                                                      "-H" "Content-Type: application/json"
                                                      "-H" (string-append "Authorization: Bearer " token)
                                                      "-d" json-body)))
             (marker "\"snapshot_cid\":\"")
             (start-idx (string-contains output marker)))
        (unless start-idx
          (format (current-error-port) "Error: Invalid response from daemon: ~a\n" output)
          (exit 1))
        (let* ((start (+ start-idx (string-length marker)))
               (end (string-index output #\" start))
               (manifest-cid (substring output start end)))
          
          (format #t "Published Fat Manifest to IPFS: ~a\n" manifest-cid)
          
          ;; 3. Publish to GNS
          (run-cmd-get-output "gnunet-gns" (list "record" "-n" gns-name "-t" "65536" "-a" manifest-cid))
          (format #t "Published ~a to GNS name ~a\n" manifest-cid gns-name)
          (display "Done.\n"))))))

(main (program-arguments))
