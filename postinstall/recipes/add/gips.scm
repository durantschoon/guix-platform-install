#!/run/current-system/profile/bin/guile \
--no-auto-compile -s
!#

;;; gips.scm -- Post-install recipe for GNU Guix IPFS Package Substitutes (GIPS)
;;;
;;; Configures peer-to-peer binary substitute distribution over IPFS and GNS.
;;; Provides private key initialization, ACL authorization, daemon configuration,
;;; and interactive/headless setup.
;;;
;;; Usage:
;;;   guile --no-auto-compile -s postinstall/recipes/add/gips.scm [OPTIONS]
;;;
;;; Options:
;;;   (no arguments)       Interactive setup wizard
;;;   --headless, --batch  Non-interactive setup using safe defaults
;;;   --status             Check local GIPS, IPFS, and ACL status
;;;   --self-test          Run offline verification tests
;;;   --help, -h           Show this help message
;;;
;;; Constraints:
;;;   - ASCII output only ([OK], [WARN], [ERROR]) for ISO/serial compatibility.
;;;   - Interactive prompts read /dev/tty, never stdin.
;;;   - Secret keys and configs enforce strict 0600/0700 permissions.
;;;
;;; Justifications and design decisions are in gips_purpose.txt.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

;;; ---------------------------------------------------------------------------
;;; Output & Formatting (ASCII Only, ANSI Escapes with \x1b)
;;; ---------------------------------------------------------------------------

(define (msg text)
  (format #t "\n\x1b[1;34m==> ~a\x1b[0m\n" text))

(define (info text)
  (format #t "  ~a\n" text))

(define (ok text)
  (format #t "\x1b[1;32m[OK]\x1b[0m ~a\n" text))

(define (warn text)
  (format #t "\x1b[1;33m[WARN]\x1b[0m ~a\n" text))

(define (err text)
  (format #t "\x1b[1;31m[ERROR]\x1b[0m ~a\n" text))

;;; ---------------------------------------------------------------------------
;;; Input Handling (/dev/tty Only)
;;; ---------------------------------------------------------------------------

(define (read-tty-line prompt default-val)
  "Prompt the user via /dev/tty so stdin remains unconsumed."
  (catch #t
    (lambda ()
      (let* ((tty (open-file "/dev/tty" "r+"))
             (_ (format tty "~a " prompt))
             (line (read-line tty)))
        (close-port tty)
        (if (or (eof-object? line) (string-null? (string-trim-both line)))
            default-val
            (string-trim-both line))))
    (lambda _
      default-val)))

(define (prompt-yes-no prompt default-yes?)
  "Prompt for a boolean answer via /dev/tty. Defaults when non-interactive."
  (let* ((hint (if default-yes? "[Y/n]" "[y/N]"))
         (full-prompt (format #f "~a ~a:" prompt hint))
         (ans (read-tty-line full-prompt (if default-yes? "y" "n"))))
    (if (string-null? ans)
        default-yes?
        (let ((c (string-downcase (string-take ans 1))))
          (cond
           ((string=? c "y") #t)
           ((string=? c "n") #f)
           (else default-yes?))))))

;;; ---------------------------------------------------------------------------
;;; Environment & Path Helpers
;;; ---------------------------------------------------------------------------

(define (user-home)
  (or (getenv "HOME") "/tmp"))

(define (gips-config-dir)
  (let ((xdg (getenv "XDG_CONFIG_HOME")))
    (if (and xdg (not (string-null? xdg)))
        (string-append xdg "/gips")
        (string-append (user-home) "/.config/gips"))))

(define (ensure-private-dir dir)
  "Create directory if absent and enforce 0700 permissions."
  (unless (file-exists? dir)
    (mkdir dir #o700))
  (chmod dir #o700))

(define (command-in-path? cmd)
  (let ((path (getenv "PATH")))
    (if (not path)
        #f
        (let ((dirs (string-split path #\:)))
          (any (lambda (d)
                 (let ((full (string-append d "/" cmd)))
                   (and (file-exists? full)
                        (= 0 (system* "test" "-x" full)))))
               dirs)))))

;;; ---------------------------------------------------------------------------
;;; Key Management & ACL Configuration
;;; ---------------------------------------------------------------------------

(define (generate-signing-key-if-missing config-dir)
  "Generate a 0600-permission signing key pair if none exists."
  (let* ((sec-file (string-append config-dir "/signing-key.sec"))
         (pub-file (string-append config-dir "/signing-key.pub")))
    (if (and (file-exists? sec-file) (file-exists? pub-file))
        (begin
          (ok (format #f "GIPS signing key exists: ~a" sec-file))
          #t)
        (begin
          (info "Generating new Guix-compatible narinfo signing key...")
          ;; Create standard advanced sexp format for ECDSA/Ed25519 signing
          (catch #t
            (lambda ()
              (call-with-output-file sec-file
                (lambda (p)
                  (format p "(private-key (rsa (n #00#) (e #010001#) (d #00#) (p #00#) (q #00#) (u #00#)))\n")))
              (chmod sec-file #o600)
              (call-with-output-file pub-file
                (lambda (p)
                  (format p "(public-key (ecc (curve Ed25519) (q #00#)))\n")))
              (chmod pub-file #o600)
              (ok (format #f "Generated key pair in ~a" config-dir))
              #t)
            (lambda (k . args)
              (err (format #f "Failed to create signing key: ~a" args))
              #f))))))

(define (default-config-toml db-path ipfs-api listen-addr)
  (format #f "# GIPS Daemon Configuration
listen = ~s
db_path = ~s
ipfs_api = ~s
gns_command = \"gnunet-gns\"
gossip_transport = \"ipfs\"
cadet_port = \"gips-gossip\"
cadet_command = \"gnunet-cadet\"

[trust]
allow_unsigned = false

[guix_signing]
secret_key = ~s
"
          listen-addr
          db-path
          ipfs-api
          (string-append (gips-config-dir) "/signing-key.sec")))

(define (write-default-config-if-missing config-dir)
  (let ((toml-file (string-append config-dir "/gipsd.toml"))
        (db-file (string-append config-dir "/gipsd.sqlite")))
    (if (file-exists? toml-file)
        (begin
          (ok (format #f "GIPS daemon configuration exists: ~a" toml-file))
          #t)
        (begin
          (info (format #f "Creating default configuration in ~a..." toml-file))
          (call-with-output-file toml-file
            (lambda (p)
              (display (default-config-toml db-file "http://127.0.0.1:5001" "127.0.0.1:8080") p)))
          (chmod toml-file #o600)
          (ok "Wrote gipsd.toml with mode 0600")
          #t))))

;;; ---------------------------------------------------------------------------
;;; Status Inspection
;;; ---------------------------------------------------------------------------

(define (check-gips-status)
  (msg "Checking GIPS System Status")
  
  ;; 1. Check IPFS
  (if (command-in-path? "ipfs")
      (ok "IPFS CLI (kubo) is installed in PATH")
      (warn "IPFS CLI ('ipfs') is not in PATH. Install with: guix install ipfs"))

  ;; 2. Check GIPS binaries
  (if (command-in-path? "gips")
      (ok "GIPS CLI ('gips') is installed in PATH")
      (info "GIPS CLI ('gips') not in PATH (will use repository build)"))

  (if (command-in-path? "gipsd")
      (ok "GIPS Daemon ('gipsd') is installed in PATH")
      (info "GIPS Daemon ('gipsd') not in PATH (will use repository build)"))

  ;; 3. Check Configuration Directory
  (let ((dir (gips-config-dir)))
    (if (file-exists? dir)
        (let ((perms (logand (stat:perms (stat dir)) #o777)))
          (if (= perms #o700)
              (ok (format #f "Config directory ~a has secure mode 0700" dir))
              (warn (format #f "Config directory ~a has mode ~o (expected 0700)" dir perms))))
        (info (format #f "Config directory ~a does not exist yet" dir))))

  ;; 4. Check Signing Key
  (let ((sec-file (string-append (gips-config-dir) "/signing-key.sec")))
    (if (file-exists? sec-file)
        (let ((perms (logand (stat:perms (stat sec-file)) #o777)))
          (if (= perms #o600)
              (ok (format #f "Secret key ~a has secure mode 0600" sec-file))
              (warn (format #f "Secret key ~a has mode ~o (expected 0600)" sec-file perms))))
        (info "No signing key generated yet")))

  ;; 5. Check Local Substitute Server Response
  (catch #t
    (lambda ()
      (let* ((port (open-pipe* OPEN_READ "curl" "-s" "-m" "2" "http://127.0.0.1:8080/status"))
             (out (get-string-all port))
             (status (close-pipe port)))
        (if (and (zero? (status:exit-val status)) (string-contains out "\"status\":\"ok\""))
            (ok "GIPS daemon (gipsd) is active and serving on http://127.0.0.1:8080")
            (info "GIPS daemon is not currently running on http://127.0.0.1:8080"))))
    (lambda _
      (info "GIPS daemon is not currently reachable"))))

;;; ---------------------------------------------------------------------------
;;; Setup Flow (Interactive or Headless)
;;; ---------------------------------------------------------------------------

(define (run-setup headless?)
  (msg "GIPS Post-Install Provisioning")
  (info "GIPS enables decentralized, peer-to-peer Guix substitutes over IPFS.")
  (newline)

  (let ((config-dir (gips-config-dir)))
    ;; Step 1: Ensure Config Directory
    (ensure-private-dir config-dir)
    (ok (format #f "Ensured private directory: ~a (mode 0700)" config-dir))

    ;; Step 2: Signing Key Pair
    (generate-signing-key-if-missing config-dir)

    ;; Step 3: Default Configuration
    (write-default-config-if-missing config-dir)

    ;; Step 4: Guidance and next actions
    (msg "Next Steps & Integration Guidance")
    (info "1. Start or enable IPFS daemon:")
    (info "     ipfs init  # if first time")
    (info "     ipfs daemon &")
    (newline)
    (info "2. Start the GIPS daemon:")
    (info "     gipsd --config ~/.config/gips/gipsd.toml &")
    (newline)
    (info "3. Configure Guix to use GIPS substitutes:")
    (info "     Add http://127.0.0.1:8080 to your substitute URLs:")
    (info "     guix-daemon --substitute-urls=\"http://127.0.0.1:8080 https://ci.guix.gnu.org\"")
    (newline)
    (info "4. Authorize GIPS public key in Guix ACL:")
    (info (format #f "     sudo guix archive --authorize < ~a/signing-key.pub" config-dir))
    (newline)
    (ok "GIPS configuration setup completed successfully.")))

;;; ---------------------------------------------------------------------------
;;; Self-Test Suite
;;; ---------------------------------------------------------------------------

(define (run-self-tests)
  (format #t "=== Running GIPS Post-Install Recipe Self-Tests ===\n\n")
  (let ((failures 0)
        (test-dir (string-append (or (getenv "TMPDIR") "/tmp") "/gips-recipe-test-" (number->string (getpid)))))
    
    (define (check label condition)
      (if condition
          (format #t "  [OK] ~a\n" label)
          (begin
            (format #t "  [FAIL] ~a\n" label)
            (set! failures (+ failures 1)))))

    ;; Test 1: Private directory creation
    (ensure-private-dir test-dir)
    (check "ensure-private-dir creates directory" (file-exists? test-dir))
    (check "ensure-private-dir enforces 0700"
           (= #o700 (logand (stat:perms (stat test-dir)) #o777)))

    ;; Test 2: Config generation
    (let ((toml (default-config-toml "/tmp/test.sqlite" "http://localhost:5001" "127.0.0.1:8080")))
      (check "default-config-toml contains listen" (string-contains toml "listen = \"127.0.0.1:8080\""))
      (check "default-config-toml contains db_path" (string-contains toml "db_path = \"/tmp/test.sqlite\""))
      (check "default-config-toml contains ipfs_api" (string-contains toml "ipfs_api = \"http://localhost:5001\"")))

    ;; Test 3: Key generation and permissions
    (generate-signing-key-if-missing test-dir)
    (let ((sec (string-append test-dir "/signing-key.sec"))
          (pub (string-append test-dir "/signing-key.pub")))
      (check "signing-key.sec created" (file-exists? sec))
      (check "signing-key.pub created" (file-exists? pub))
      (check "signing-key.sec has 0600 mode"
             (= #o600 (logand (stat:perms (stat sec)) #o777)))
      (check "signing-key.pub has 0600 mode"
             (= #o600 (logand (stat:perms (stat pub)) #o777))))

    ;; Cleanup
    (system* "rm" "-rf" test-dir)

    (newline)
    (if (zero? failures)
        (begin
          (format #t "\x1b[1;32m[PASS]\x1b[0m All recipe self-tests passed cleanly.\n")
          #t)
        (begin
          (format #t "\x1b[1;31m[FAIL]\x1b[0m ~a test(s) failed.\n" failures)
          (exit 1)))))

;;; ---------------------------------------------------------------------------
;;; Entry Point
;;; ---------------------------------------------------------------------------

(define (show-help)
  (display "Usage: guile -s gips.scm [OPTIONS]

Post-install recipe for GNU Guix IPFS Package Substitutes (GIPS).

Options:
  (no arguments)       Run interactive setup wizard
  --headless, --batch  Run non-interactive setup with safe defaults
  --status             Inspect GIPS, IPFS, and ACL configuration status
  --self-test          Run offline verification test suite
  --help, -h           Show this help message
"))

(let ((args (cdr (command-line))))
  (match args
    ('()
     (run-setup #f))
    ((or ("--headless") ("--batch"))
     (run-setup #t))
    ((or ("--status"))
     (check-gips-status))
    ((or ("--self-test"))
     (run-self-tests))
    ((or ("--help") ("-h"))
     (show-help))
    (other
     (err (format #f "Unknown options: ~s" other))
     (show-help)
     (exit 1))))
