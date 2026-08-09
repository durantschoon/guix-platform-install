#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; 01-setup-client.scm --- install and configure the OCI CLI on Guix.
;;;
;;; Reproduces, repeatably, the client-side bootstrap that was first done
;;; by hand on 2026-08-08:
;;;
;;;   1. python into the user's Guix profile (Guix does not package
;;;      oci-cli; only the Go SDK exists as a package)
;;;   2. oci-cli into an isolated venv at ~/.venvs/oci-cli
;;;   3. a symlink at ~/.local/bin/oci
;;;   4. ~/.oci/config via the console-generated API key flow
;;;
;;; The API key flow deliberately has the CONSOLE generate the key pair
;;; (user downloads the private key) rather than generating locally and
;;; pasting the public key up: pasting a multi-line PEM into the console
;;; form proved error-prone in practice, while "Generate API key pair"
;;; plus "Download private key" is two clicks.  See
;;; oracle-scripts_purpose.txt for the fingerprint math.
;;;
;;; Idempotent: every step checks before acting; safe to rerun.

(load (string-append (dirname (car (command-line))) "/oci-common.scm"))

(define (ensure-python)
  "Ensure python3 exists in the user's Guix profile."
  (if (command-succeeds? "command -v python3 || ls $HOME/.guix-profile/bin/python3")
      (say "[OK] python3 present")
      (begin
        (say "python3 is not installed; installing into your Guix profile.")
        (say "(Reversible later with: guix remove python)")
        (run-command "guix install python")
        (unless (file-exists? (home-path ".guix-profile" "bin" "python3"))
          (die "guix install python did not produce ~/.guix-profile/bin/python3")))))

(define (ensure-oci-cli)
  "Ensure the oci CLI is installed in its venv and on PATH."
  (if (file-exists? %oci-cli)
      (say "[OK] oci CLI already installed: " (run-command (string-append %oci-cli " --version")))
      (begin
        (say "Creating venv and installing oci-cli (a few minutes)...")
        (run-command
         (string-append "$HOME/.guix-profile/bin/python3 -m venv "
                        (sh-quote (home-path ".venvs" "oci-cli"))))
        (run-command (string-append %oci-venv-python " -m pip install --quiet --upgrade pip"))
        (run-command (string-append %oci-venv-python " -m pip install --quiet oci-cli"))
        (unless (file-exists? %oci-cli)
          (die "pip install oci-cli failed; rerun with network up"))))
  ;; PATH symlink; ~/.local/bin is assumed to be on PATH already.
  (let ((link (home-path ".local" "bin" "oci")))
    (run-command (string-append "mkdir -p " (sh-quote (dirname link))))
    (run-command (string-append "ln -sf " (sh-quote %oci-cli) " " (sh-quote link)))
    (say "[OK] oci on PATH via " link)))

(define (fingerprint-of-private-key pem-path)
  "Compute the OCI API-key fingerprint (colon-separated MD5 of the DER
public key) using the venv's python, which ships `cryptography'."
  (run-command
   (string-append
    %oci-venv-python " - " (sh-quote pem-path) " <<'PYEOF'\n"
    "import sys, hashlib\n"
    "from cryptography.hazmat.primitives import serialization\n"
    "with open(sys.argv[1], 'rb') as f:\n"
    "    key = serialization.load_pem_private_key(f.read(), password=None)\n"
    "der = key.public_key().public_bytes(serialization.Encoding.DER,\n"
    "                                    serialization.PublicFormat.SubjectPublicKeyInfo)\n"
    "d = hashlib.md5(der).hexdigest()\n"
    "print(':'.join(d[i:i+2] for i in range(0, 32, 2)))\n"
    "PYEOF")))

(define (newest-downloaded-pem)
  "Return the newest *.pem under ~/Downloads, or #f.  The console names
downloads like <account-email>-<timestamp>.pem."
  (let ((found (run-command "ls -t $HOME/Downloads/*.pem 2>/dev/null | head -1")))
    (and (not (string-null? found)) found)))

(define (configure-api-key)
  "Interactive one-time credential setup via a console-generated key."
  (say "")
  (say "== OCI API key setup ==")
  (say "You need two OCIDs from the web console (https://cloud.oracle.com):")
  (say "  - User OCID:    Profile menu -> My profile -> OCID")
  (say "  - Tenancy OCID: Profile menu -> Tenancy -> OCID")
  (say "    (also shown in any 'View configuration file' snippet, and the")
  (say "     root compartment's OCID under Identity -> Compartments)")
  (let* ((user-ocid (prompt-tty "User OCID (ocid1.user.oc1..*):"))
         (tenancy-ocid (prompt-tty "Tenancy OCID (ocid1.tenancy.oc1..*):"))
         (region (let ((r (prompt-tty "Home region [us-ashburn-1]:")))
                   (if (string-null? r) "us-ashburn-1" r))))
    (unless (string-prefix? "ocid1.user." user-ocid)
      (die "that does not look like a user OCID"))
    (unless (string-prefix? "ocid1.tenancy." tenancy-ocid)
      (die "that does not look like a tenancy OCID (a child compartment's "
           "OCID starts with ocid1.compartment. and will not work)"))
    (say "")
    (say "Now in the console: My profile -> API keys -> Add API key")
    (say "  1. Choose 'Generate API key pair'")
    (say "  2. Click 'Download private key'  (shown exactly once!)")
    (say "  3. Click 'Add'")
    (prompt-tty "Press Enter when the .pem file is downloaded...")
    (let ((pem (newest-downloaded-pem)))
      (unless pem
        (die "no *.pem found in ~/Downloads"))
      (unless (prompt-yes? (string-append "Use " pem "?"))
        (die "aborted; rerun after downloading the key"))
      (let ((dest (home-path ".oci" "oci_api_key_console.pem")))
        (run-command (string-append "mkdir -p $HOME/.oci && chmod 700 $HOME/.oci"))
        (run-command (string-append "mv " (sh-quote pem) " " (sh-quote dest)))
        (run-command (string-append "chmod 600 " (sh-quote dest)))
        (let ((fingerprint (fingerprint-of-private-key dest)))
          (say "[OK] key installed, fingerprint " fingerprint)
          (call-with-output-file %oci-config
            (lambda (port)
              (format port "[DEFAULT]~%user=~a~%fingerprint=~a~%key_file=~a~%tenancy=~a~%region=~a~%"
                      user-ocid fingerprint dest tenancy-ocid region)))
          (run-command (string-append "chmod 600 " (sh-quote %oci-config)))
          (say "[OK] wrote " %oci-config))))))

(define (main)
  (ensure-python)
  (ensure-oci-cli)
  (if (oci-authenticated?)
      (say "[OK] oci CLI already authenticates; nothing to do")
      (begin
        (when (file-exists? %oci-config)
          (say "[WARN] ~/.oci/config exists but does not authenticate; redoing setup"))
        (configure-api-key)
        ;; Fresh keys take a little while to propagate; NotAuthenticated
        ;; for the first minute is normal, not a mistake.
        (if (poll-until "API key propagation"
                        (lambda () (and (oci-authenticated?) #t))
                        15 300)
            (say "[OK] authenticated. Home region check: "
                 (oci "iam region-subscription list --query 'data[0].\"region-name\"' --raw-output"))
            (die "still NotAuthenticated after 5 minutes. Check in the console "
                 "that the key was Added (not just downloaded) and that the "
                 "fingerprint shown matches the one printed above.")))))

(main)
