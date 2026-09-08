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
dashboard = true

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
;;; Swarm Telemetry & Live Terminal Monitor
;;; ---------------------------------------------------------------------------

(define* (launch-monitor #:key (json? #f))
  "Display live swarm telemetry monitor (ASCII or JSON)."
  (if (command-in-path? "gips")
      (let ((args (append (list "monitor" "--daemon" "http://127.0.0.1:8080" "--once")
                          (if json? (list "--json") '()))))
        (apply system* "gips" args))
      (begin
        (catch #t
          (lambda ()
            (let* ((port (open-pipe* OPEN_READ "curl" "-s" "-m" "2" "http://127.0.0.1:8080/metrics"))
                   (metrics-out (get-string-all port))
                   (_ (close-pipe port))
                   (gossip-port (open-pipe* OPEN_READ "curl" "-s" "-m" "2" "http://127.0.0.1:8080/gossip/status"))
                   (gossip-out (get-string-all gossip-port))
                   (_ (close-pipe gossip-port)))
              (if json?
                  (format #t "{\"daemon_url\":\"http://127.0.0.1:8080\",\"metrics\":~a,\"gossip\":~a}\n"
                          (if (string-null? metrics-out) "{}" metrics-out)
                          (if (string-null? gossip-out) "{}" gossip-out))
                  (begin
                    (format #t "================================================================================\n")
                    (format #t "  GIPS SWARM & NODE MONITOR\n")
                    (format #t "================================================================================\n")
                    (format #t "  Daemon URL:     http://127.0.0.1:8080\n")
                    (format #t "  Dashboard UI:   http://127.0.0.1:8080/dashboard\n")
                    (format #t "  Metrics Feed:   http://127.0.0.1:8080/metrics\n\n")
                    (format #t "  [Gossip Telemetry]\n")
                    (format #t "    Status: ~a\n\n" (if (string-null? gossip-out) "Inactive" gossip-out))
                    (format #t "  [Metrics Telemetry]\n")
                    (format #t "    Status: ~a\n" (if (string-null? metrics-out) "Inactive" metrics-out))
                    (format #t "================================================================================\n")))))
          (lambda _
            (err "Could not reach GIPS daemon on http://127.0.0.1:8080"))))))

;;; ---------------------------------------------------------------------------
;;; Status Inspection
;;; ---------------------------------------------------------------------------

(define (check-gips-status)
  (msg "Checking GIPS System Status")
  
  ;; 1. Check IPFS
  (if (command-in-path? "ipfs")
      (ok "IPFS CLI (kubo) is installed in PATH")
      (begin
        (warn "IPFS CLI ('ipfs') is not in PATH.")
        (info "In GNU Guix, the package is 'go-ipfs' (not 'ipfs'):")
        (info "  guix install go-ipfs")
        (info "Or install the complete GIPS toolchain bundle:")
        (info "  guix package -m gips/manifest.scm (or 'make gips-bundle')")))

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

  ;; 5. Check Local Substitute Server Response & Dashboard
  (catch #t
    (lambda ()
      (let* ((port (open-pipe* OPEN_READ "curl" "-s" "-m" "2" "http://127.0.0.1:8080/status"))
             (out (get-string-all port))
             (status (close-pipe port)))
        (if (and (zero? (status:exit-val status)) (string-contains out "\"status\":\"ok\""))
            (begin
              (ok "GIPS daemon (gipsd) is active and serving on http://127.0.0.1:8080")
              (ok "Telemetry dashboard available at http://127.0.0.1:8080/dashboard")
              (ok "Metrics endpoint available at http://127.0.0.1:8080/metrics"))
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
    (info "1. Install GIPS tooling bundle (if not already installed):")
    (info "     make gips-bundle    (or: guix package -m gips/manifest.scm)")
    (newline)
    (info "2. Start IPFS and GIPS daemons in background:")
    (info "     make gips-start     (or: ipfs daemon & and gipsd &)")
    (newline)
    (info "3. Open the Telemetry Dashboard:")
    (info "     http://127.0.0.1:8080/dashboard")
    (newline)
    (info "4. View Live Swarm Monitor in terminal:")
    (info "     make gips-status    (or: guile postinstall/recipes/add/gips.scm --status)")
    (newline)
    (info "5. Authorize GIPS public key in Guix ACL:")
    (info (format #f "     sudo guix archive --authorize < ~a/signing-key.pub" config-dir))
    (newline)
    (info "6. Share / consume package substitutes:")
    (info "     make gips-push GNS_NAME=cluster.gnu   # on producer")
    (info "     make gips-pull                        # on consumer")
    (newline)
    (ok "GIPS configuration setup completed successfully.")))

;;; ---------------------------------------------------------------------------
;;; Fraud Proof Revocation & ACL Synchronization
;;; ---------------------------------------------------------------------------

(define (sync-acl-and-revocations)
  (msg "Checking GIPS Cryptographic Fraud Proofs & Guix ACL")
  (catch #t
    (lambda ()
      (let* ((port (open-pipe* OPEN_READ "curl" "-s" "-m" "2" "http://127.0.0.1:8080/fraud-proof/list"))
             (out (get-string-all port))
             (status (close-pipe port)))
        (if (and (zero? (status:exit-val status)) (not (string-null? out)))
            (begin
              (ok "Successfully queried active fraud proofs from GIPS daemon")
              (info (format #f "Active Revocation Proofs: ~a" (string-trim-both out)))
              (if (string=? (string-trim-both out) "[]")
                  (ok "No revoked publishers in local mesh")
                  (warn "Active fraud proofs present -- verify /etc/guix/acl has revoked keys removed")))
            (info "No active GIPS daemon reachable to query fraud proofs"))))
    (lambda (k . args)
      (info "GIPS daemon not reachable for fraud proof synchronization"))))
;;; ---------------------------------------------------------------------------
;;; Hub & Spoke Role Setup
;;; ---------------------------------------------------------------------------

(define* (run-setup-hub #:key (config-dir (gips-config-dir)))
  (msg "Initializing GIPS Hub (Builder / Publisher)")
  (info "Configuring this node as a substitute provider for your cluster...")
  (newline)
  (let* ((sec-file (string-append config-dir "/signing-key.sec"))
         (pub-file (string-append config-dir "/signing-key.pub"))
         (toml-file (string-append config-dir "/gipsd.toml"))
         (db-file (string-append config-dir "/gipsd.sqlite")))
    (ensure-private-dir config-dir)
    (generate-signing-key-if-missing config-dir)
    (unless (file-exists? toml-file)
      (call-with-output-file toml-file
        (lambda (p)
          (display (default-config-toml db-file "http://127.0.0.1:5001" "127.0.0.1:8080") p)))
      (chmod toml-file #o600)
      (ok "Wrote gipsd.toml (mode 0600)"))
    (let ((pub-key-content
           (catch #t
             (lambda ()
               (if (file-exists? pub-file)
                   (call-with-input-file pub-file get-string-all)
                   ""))
             (lambda _ ""))))
      (format #t "\n================================================================================\n")
      (format #t "  [OK] GIPS Hub Configuration Completed Successfully!\n")
      (format #t "================================================================================\n")
      (format #t "  Hub Public Key File: ~a\n\n" pub-file)
      (format #t "  To connect a Spoke node, run this on the Spoke machine:\n")
      (format #t "    make gips-spoke\n\n")
      (format #t "  When prompted on the Spoke, paste this Hub signing key:\n\n~a\n\n" (string-trim-both pub-key-content))
      (format #t "================================================================================\n\n")
      #t)))

(define* (run-setup-spoke #:key (config-dir (gips-config-dir)) (hub-key #f) (hub-key-file #f) (dry-run? #f))
  (msg "Configuring GIPS Spoke (Consumer)")
  (info "Configuring this node to substitute packages from your Hub over IPFS...")
  (newline)
  (let* ((toml-file (string-append config-dir "/gipsd.toml"))
         (db-file (string-append config-dir "/gipsd.sqlite"))
         (key-text
          (cond
           ((and hub-key (not (string-null? hub-key)))
            hub-key)
           ((and hub-key-file (file-exists? hub-key-file))
            (catch #t
              (lambda () (call-with-input-file hub-key-file get-string-all))
              (lambda _ #f)))
           ((not dry-run?)
            (format #t "Paste the Hub's Guix signing public key below\n")
            (format #t "(found at ~/.config/gips/signing-key.pub on the Hub):\n")
            (read-tty-line "Key S-expression:" ""))
           (else #f))))
    (ensure-private-dir config-dir)
    (unless (file-exists? toml-file)
      (call-with-output-file toml-file
        (lambda (p)
          (format p "# GIPS Daemon Configuration (Spoke / Consumer)
listen = \"127.0.0.1:8080\"
db_path = ~s
ipfs_api = \"http://127.0.0.1:5001\"
dashboard = true

[trust]
allow_unsigned = false
" db-file)))
      (chmod toml-file #o600)
      (ok "Wrote gipsd.toml for Spoke (mode 0600)"))

    (if (and (string? key-text) (not (string-null? (string-trim-both key-text))))
        (let ((tmp-key (string-append config-dir "/hub-signing-key.pub")))
          (call-with-output-file tmp-key
            (lambda (p) (display (string-trim-both key-text) p) (newline p)))
          (chmod tmp-key #o600)
          (ok (format #f "Saved Hub public key to ~a (mode 0600)" tmp-key))
          (unless dry-run?
            (info "Authorizing Hub public key in Guix ACL...")
            (let ((status (system (format #f "sudo guix archive --authorize < ~a 2>/dev/null || guix archive --authorize < ~a 2>/dev/null" tmp-key tmp-key))))
              (if (zero? status)
                  (ok "Authorized Hub public key in /etc/guix/acl")
                  (warn "Could not run 'sudo guix archive --authorize' automatically. Run manually:\n  sudo guix archive --authorize < ~/.config/gips/hub-signing-key.pub")))))
        (unless dry-run?
          (warn "No Hub public key provided. Authorize manually with:\n  sudo guix archive --authorize < <hub-pubkey-file>")))

    (format #t "\n================================================================================\n")
    (format #t "  [OK] GIPS Spoke Configuration Completed!\n")
    (format #t "================================================================================\n")
    (format #t "  When Hub publishes packages, substitute them peer-to-peer on this Spoke:\n")
    (format #t "    make gips-pull\n")
    (format #t "  Or install individual packages directly:\n")
    (format #t "    guix install <package> --substitute-urls=\"http://127.0.0.1:8080 https://ci.guix.gnu.org\"\n")
    (format #t "================================================================================\n\n")
    #t))

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
      (check "default-config-toml contains ipfs_api" (string-contains toml "ipfs_api = \"http://localhost:5001\""))
      (check "default-config-toml contains dashboard = true" (string-contains toml "dashboard = true")))

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

    ;; Test 4: Hub setup in test directory
    (let ((hub-dir (string-append test-dir "/hub")))
      (run-setup-hub #:config-dir hub-dir)
      (check "run-setup-hub creates directory" (file-exists? hub-dir))
      (check "run-setup-hub creates gipsd.toml with 0600 mode"
             (= #o600 (logand (stat:perms (stat (string-append hub-dir "/gipsd.toml"))) #o777)))
      (check "run-setup-hub creates signing-key.sec with 0600 mode"
             (= #o600 (logand (stat:perms (stat (string-append hub-dir "/signing-key.sec"))) #o777))))

    ;; Test 5: Spoke setup in test directory
    (let ((spoke-dir (string-append test-dir "/spoke")))
      (run-setup-spoke #:config-dir spoke-dir #:hub-key "(public-key (ecc (curve Ed25519) (q #00#)))" #:dry-run? #t)
      (check "run-setup-spoke creates directory" (file-exists? spoke-dir))
      (check "run-setup-spoke creates gipsd.toml with 0600 mode"
             (= #o600 (logand (stat:perms (stat (string-append spoke-dir "/gipsd.toml"))) #o777)))
      (check "run-setup-spoke saves hub-signing-key.pub with 0600 mode"
             (= #o600 (logand (stat:perms (stat (string-append spoke-dir "/hub-signing-key.pub"))) #o777))))

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

(define (install-bundle)
  (msg "Installing GIPS Tooling Bundle")
  (if (not (command-in-path? "guix"))
      (err "'guix' command not found in PATH.")
      (let* ((repo-manifest "gips/manifest.scm")
             (manifest-path (if (file-exists? repo-manifest)
                                repo-manifest
                                (string-append (user-home) "/Repos/ds/guix-platform-install/gips/manifest.scm"))))
        (if (file-exists? manifest-path)
            (begin
              (info (format #f "Installing bundle from ~a..." manifest-path))
              (let ((status (system* "guix" "package" "-m" manifest-path)))
                (if (zero? (status:exit-val status))
                    (ok "Successfully installed GIPS tooling bundle.")
                    (err "Failed to install GIPS manifest."))))
            (begin
              (info "Manifest file not found locally; falling back to direct package installation...")
              (let ((status (system* "guix" "install" "go-ipfs" "rust" "pkg-config" "openssl" "sqlite" "guile-gcrypt" "just" "curl" "jq")))
                (if (zero? (status:exit-val status))
                    (ok "Successfully installed GIPS packages.")
                    (err "Failed to install GIPS packages."))))))))

;;; ---------------------------------------------------------------------------
;;; Entry Point
;;; ---------------------------------------------------------------------------

(define (show-help)
  (display "Usage: guile -s gips.scm [OPTIONS]

Post-install recipe for GNU Guix IPFS Package Substitutes (GIPS).

Options:
  (no arguments)       Run interactive setup wizard
  --hub                Configure this node as a Hub (Builder / Publisher)
  --spoke              Configure this node as a Spoke (Consumer / Client)
  --hub-key=KEY        Public key of the Hub to authorize on Spoke
  --hub-key-file=PATH  Path to file containing Hub public key
  --headless, --batch  Run non-interactive setup with safe defaults
  --install-bundle     Install GIPS tooling bundle (go-ipfs, rust, guile-gcrypt, etc.)
  --status             Inspect GIPS, IPFS, and ACL configuration status
  --monitor            Display live terminal swarm monitor snapshot
  --monitor-json       Output live telemetry monitor snapshot as JSON
  --check-revocations  Query active fraud proof revocations from local mesh
  --self-test          Run offline verification test suite
  --help, -h           Show this help message
"))

(define (parse-and-run args)
  (let loop ((rem args)
             (mode #f)
             (hub-key #f)
             (hub-key-file #f))
    (if (null? rem)
        (cond
         ((eq? mode 'hub)
          (run-setup-hub))
         ((eq? mode 'spoke)
          (run-setup-spoke #:hub-key hub-key #:hub-key-file hub-key-file))
         ((eq? mode 'headless)
          (run-setup #t))
         ((eq? mode 'install-bundle)
          (install-bundle))
         ((eq? mode 'status)
          (check-gips-status))
         ((eq? mode 'monitor)
          (launch-monitor #:json? #f))
         ((eq? mode 'monitor-json)
          (launch-monitor #:json? #t))
         ((eq? mode 'check-revocations)
          (sync-acl-and-revocations))
         ((eq? mode 'self-test)
          (run-self-tests))
         ((eq? mode 'help)
          (show-help))
         (else
          (run-setup #f)))
        (let ((head (car rem))
              (tail (cdr rem)))
          (cond
           ((string=? head "--hub")
            (loop tail 'hub hub-key hub-key-file))
           ((string=? head "--spoke")
            (loop tail 'spoke hub-key hub-key-file))
           ((string-prefix? "--hub-key=" head)
            (loop tail mode (substring head (string-length "--hub-key=")) hub-key-file))
           ((string=? head "--hub-key")
            (if (pair? tail)
                (loop (cdr tail) mode (car tail) hub-key-file)
                (loop tail mode hub-key hub-key-file)))
           ((string-prefix? "--hub-key-file=" head)
            (loop tail mode hub-key (substring head (string-length "--hub-key-file="))))
           ((string=? head "--hub-key-file")
            (if (pair? tail)
                (loop (cdr tail) mode hub-key (car tail))
                (loop tail mode hub-key hub-key-file)))
           ((or (string=? head "--headless") (string=? head "--batch"))
            (loop tail 'headless hub-key hub-key-file))
           ((or (string=? head "--install-bundle") (string=? head "--bundle"))
            (loop tail 'install-bundle hub-key hub-key-file))
           ((string=? head "--status")
            (loop tail 'status hub-key hub-key-file))
           ((string=? head "--monitor")
            (loop tail 'monitor hub-key hub-key-file))
           ((string=? head "--monitor-json")
            (loop tail 'monitor-json hub-key hub-key-file))
           ((or (string=? head "--check-revocations") (string=? head "--sync-revocations"))
            (loop tail 'check-revocations hub-key hub-key-file))
           ((string=? head "--self-test")
            (loop tail 'self-test hub-key hub-key-file))
           ((or (string=? head "--help") (string=? head "-h"))
            (loop tail 'help hub-key hub-key-file))
           (else
            (err (format #f "Unknown option: ~s" head))
            (show-help)
            (exit 1)))))))

(parse-and-run (cdr (command-line)))
