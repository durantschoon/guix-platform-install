;;; GIPS Scheme API — REPL parity with the gips CLI.
;;; Load from repo root: (load "scheme/gips/api.scm")
;;; Then: (gips-status) (gips-publish "/gnu/store/...-foo-1.0" "example.gnu")
;;;
;;; Requires: curl on PATH.
;;;
;;; Base URL precedence, most explicit first:
;;;   1. (gips-base-url "http://...")  — an explicit setter wins outright
;;;   2. environment variable GIPS_DAEMON
;;;   3. http://127.0.0.1:8080
;;;
;;; Authentication:
;;; Mutating calls carry gipsd's local auth token, read from the token file
;;; gipsd writes with mode 0600.
;;;
;;; To prevent process argument exposure (e.g. ps aux / /proc), tokens are never
;;; passed on curl's argv. Instead, the Authorization header is passed via a
;;; temporary curl configuration file with mode 0600 in a private directory,
;;; cleaned up immediately upon completion or error via dynamic-wind.

(define-module (gips api)
  #:export (gips-base-url
            gips-auth-token-file
            gips-auth-token
            gips-auth-rotate
            gips-publish
            gips-publish-tree
            gips-status
            gips-subscribe
            gips-link-channel
            gips-pin
            gips-unpin
            gips-reindex
            gips-search
            gips-key-generate-guix
            gips-key-export-guix
            gips-key-generate-feed
            gips-key-export-feed
            gips-key-advertise-gns
            gips-key-fetch-gns
            gips-key-acl-list
            gips-key-acl-check
            gips-key-acl-authorize
            gips-key-acl-revoke
            gips-key-acl-diff
            gips-snapshot-create
            gips-snapshot-list
            gips-snapshot-import
            gips-snapshot-export
            gips-metrics
            gips-metrics-history
            gips-vouch-mint
            gips-vouch-verify
            gips-vouch-inspect
            gips-vouch-ingest
            gips-trust-evaluate
            gips-fraud-proof-generate-hash-mismatch
            gips-fraud-proof-generate-equivocation
            gips-fraud-proof-verify
            gips-fraud-proof-submit
            gips-fraud-proof-list
            gips-gossip-status
            gips-monitor
            gips-search-prefix
            escape-json-string
            json-boolean
            json-string-array
            build-publish-json
            build-subscribe-json
            build-link-channel-json
            build-pin-json
            build-unpin-json
            build-reindex-json
            build-snapshot-create-json
            build-snapshot-import-json
            build-trust-evaluate-json
            build-vouch-ingest-json
            uri-encode
            call-with-auth-config
            guix-public-key-path
            feed-public-key-path
            default-guix-key-path
            default-feed-key-path))

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 binary-ports)
             (ice-9 ftw)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-13)
             (rnrs bytevectors))

(define %default-base-url "http://127.0.0.1:8080")

(define base-url (make-fluid))
(define auth-token-file (make-fluid))

(define (non-empty-string x)
  (and (string? x) (not (string-null? x)) x))

;; Generic "explicit setter beats environment beats default" accessor.
;; Called with no args it reads; called with one arg it sets for the current
;; dynamic extent and returns the value.
(define (make-overridable fluid env-name default-thunk)
  (lambda rest
    (if (null? rest)
        (or (and (fluid-bound? fluid) (non-empty-string (fluid-ref fluid)))
            (non-empty-string (getenv env-name))
            (default-thunk))
        (begin
          (fluid-set! fluid (car rest))
          (car rest)))))

;; Get or set the daemon base URL. Always returns a string when read.
(define gips-base-url
  (make-overridable base-url "GIPS_DAEMON" (lambda () %default-base-url)))

;; Rust's dirs::config_dir, which is where gipsd writes the token.
(define (default-config-dir)
  (let ((home (getenv "HOME")))
    (cond
     ((not (non-empty-string home)) ".")
     ((string=? (utsname:sysname (uname)) "Darwin")
      (string-append home "/Library/Application Support"))
     (else (or (non-empty-string (getenv "XDG_CONFIG_HOME"))
               (string-append home "/.config"))))))

(define (default-auth-token-file)
  (string-append (default-config-dir) "/gips/auth-token"))

;; Get or set the auth token file. Same precedence rule as gips-base-url.
(define gips-auth-token-file
  (make-overridable auth-token-file "GIPS_AUTH_TOKEN_FILE" default-auth-token-file))

(define (string-trim-both* str)
  (string-trim-both str (lambda (c) (or (char-whitespace? c) (char=? c #\nul)))))

;; Read the daemon's local auth token. Errors rather than silently sending an
;; unauthenticated request: gipsd would reject it anyway, and a quiet failure
;; here is how a "why did nothing publish?" afternoon starts.
(define (gips-auth-token)
  (let ((file (gips-auth-token-file)))
    (if (not (file-exists? file))
        (error "gips: no auth token at" file
               "- start gipsd once to create it, or (gips-auth-token-file \"/path\")")
        (let ((token (string-trim-both* (call-with-input-file file get-string-all))))
          (if (string-null? token)
              (error "gips: auth token file is empty:" file)
              token)))))

;; Generate a random 64-hex lowercase token from /dev/urandom.
(define (generate-random-token-hex)
  (call-with-input-file "/dev/urandom"
    (lambda (port)
      (let ((bv (get-bytevector-n port 32)))
        (let loop ((i 0) (acc '()))
          (if (>= i (bytevector-length bv))
              (string-concatenate-reverse acc)
              (let* ((b (bytevector-u8-ref bv i))
                     (hex (number->string b 16))
                     (padded (if (< (string-length hex) 2) (string-append "0" hex) hex)))
                (loop (+ i 1) (cons (string-downcase padded) acc)))))))))

(define (ensure-dir-exists dir)
  (unless (file-exists? dir)
    (let ((parent (dirname dir)))
      (when (and (not (string=? parent dir)) (not (string=? parent "")))
        (ensure-dir-exists parent))
      (catch #t
        (lambda () (mkdir dir #o700))
        (lambda _ #f)))))

;; Rotate the auth token file at `token-file` (or the default).
;; Writes mode 0600 atomically via a temporary file in the same directory.
(define* (gips-auth-rotate #:key (token-file #f))
  (let* ((file (or token-file (gips-auth-token-file)))
         (dir (dirname file))
         (token (generate-random-token-hex))
         (tmp (string-append dir "/.token.tmp." (number->string (getpid)))))
    (ensure-dir-exists dir)
    (call-with-output-file tmp
      (lambda (port)
        (chmod tmp #o600)
        (display token port)
        (newline port)))
    (rename-file tmp file)
    (chmod file #o600)
    token))

;; Ensure a private 0700 temporary directory exists for this process.
(define (ensure-private-tmp-dir)
  (let* ((base (or (getenv "TMPDIR") "/tmp"))
         (dir (format #f "~a/gips-api-~a" (string-trim-right base #\/) (getpid))))
    (unless (file-exists? dir)
      (mkdir dir #o700))
    (chmod dir #o700)
    dir))

;; Pass the Authorization bearer token to curl via a temporary config file
;; with 0600 mode in a 0700 directory, unlinking it reliably via dynamic-wind.
(define (call-with-auth-config token proc)
  (let* ((dir (ensure-private-tmp-dir))
         (tmpl (string-append dir "/curl-cfg-XXXXXX"))
         (port (mkstemp! tmpl))
         (path tmpl))
    (chmod path #o600)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (display (string-append "header = \"Authorization: Bearer " token "\"\n") port)
        (close-port port)
        (proc path))
      (lambda ()
        (false-if-exception (close-port port))
        (when (file-exists? path)
          (false-if-exception (delete-file path)))))))

(define (escape-json-string str)
  (string-concatenate
   (map (lambda (c)
          (case c
            ((#\") "\\\"")
            ((#\\) "\\\\")
            ((#\newline) "\\n")
            ((#\return) "\\r")
            ((#\tab) "\\t")
            (else (string c))))
        (string->list str))))

(define (json-boolean b)
  (if b "true" "false"))

(define (json-string-array lst)
  (string-append "["
                 (string-join (map (lambda (s)
                                     (string-append "\"" (escape-json-string s) "\""))
                                   lst)
                              ",")
                 "]"))

(define* (build-publish-json store-path #:optional gns-name #:key (deriver #f) (system #f))
  (string-append
   "{\"store_path\":\"" (escape-json-string store-path) "\""
   (if (and gns-name (not (string-null? gns-name)))
       (string-append ",\"gns_name\":\"" (escape-json-string gns-name) "\"")
       "")
   (if (and deriver (not (string-null? deriver)))
       (string-append ",\"deriver\":\"" (escape-json-string deriver) "\"")
       "")
   (if (and system (not (string-null? system)))
       (string-append ",\"system\":\"" (escape-json-string system) "\"")
       "")
   "}"))

(define (build-subscribe-json gns-name)
  (string-append "{\"gns_name\":\"" (escape-json-string gns-name) "\"}"))

(define* (build-link-channel-json channel-name gns-name #:key (allow-repoint? #f))
  (string-append
   "{\"channel_name\":\"" (escape-json-string channel-name) "\","
   "\"gns_name\":\"" (escape-json-string gns-name) "\","
   "\"allow_repoint\":" (json-boolean allow-repoint?) "}"))

(define (build-pin-json ipfs-cid)
  (string-append "{\"ipfs_cid\":\"" (escape-json-string ipfs-cid) "\"}"))

(define (build-unpin-json ipfs-cid)
  (string-append "{\"ipfs_cid\":\"" (escape-json-string ipfs-cid) "\"}"))

(define* (build-reindex-json #:key (prune-missing? #f) (store-paths '()))
  (string-append
   "{\"prune_missing\":" (json-boolean prune-missing?)
   (if (and (pair? store-paths) (not (null? store-paths)))
       (string-append ",\"store_paths\":" (json-string-array store-paths))
       "")
   "}"))

(define* (build-snapshot-create-json store-paths #:key (gns-name #f))
  (string-append
   "{\"store_paths\":" (json-string-array store-paths)
   (if (and gns-name (not (string-null? gns-name)))
       (string-append ",\"gns_name\":\"" (escape-json-string gns-name) "\"")
       "")
   "}"))

(define (build-snapshot-import-json cid)
  (string-append "{\"cid\":\"" (escape-json-string cid) "\"}"))

(define* (build-trust-evaluate-json publisher-pubkey #:key (store-path #f) (chain #f))
  (string-append
   "{\"publisher_key\":\"" (escape-json-string publisher-pubkey) "\""
   (if (and store-path (not (eq? store-path #f)) (not (string-null? store-path)))
       (string-append ",\"store_path\":\"" (escape-json-string store-path) "\"")
       "")
   (if (and chain (not (eq? chain #f)))
       (let ((chain-str (if (string? chain) chain (format #f "~a" chain))))
         (if (string-prefix? "[" (string-trim-both chain-str))
             (string-append ",\"chain\":" chain-str)
             (string-append ",\"chain\":[" chain-str "]")))
       "")
   "}"))

(define (build-vouch-ingest-json chain)
  (let ((chain-str (if (string? chain) chain (format #f "~a" chain))))
    (if (string-prefix? "[" (string-trim-both chain-str))
        (string-append "{\"chain\":" chain-str "}")
        (string-append "{\"chain\":[" chain-str "]}"))))

;; RFC 3986 percent-encoding for query string parameter values.
(define (uri-encode str)
  (let ((bv (string->utf8 str)))
    (let loop ((i 0) (acc '()))
      (if (>= i (bytevector-length bv))
          (string-concatenate-reverse acc)
          (let ((b (bytevector-u8-ref bv i)))
            (cond
             ;; Unreserved characters: A-Z, a-z, 0-9, '-', '_', '.', '~'
             ((or (and (>= b 65) (<= b 90))
                  (and (>= b 97) (<= b 122))
                  (and (>= b 48) (<= b 57))
                  (= b 45) (= b 95) (= b 46) (= b 126))
              (loop (+ i 1) (cons (string (integer->char b)) acc)))
             (else
              (let ((hex (string-upcase (number->string b 16))))
                (loop (+ i 1)
                      (cons (string-append "%" (if (< b 16) (string-append "0" hex) hex))
                            acc))))))))))

;; Run curl with `opts`, then `--`, then the URL. The terminator stops option
;; injection from URLs that begin with `-`.
(define (run-curl* opts url)
  (let ((port (apply open-pipe* OPEN_READ "curl" "-sS"
                     (append opts (list "--" url)))))
    (let ((out (get-string-all port)))
      (close-pipe port)
      (if (string? out) out ""))))

;; POST JSON to url, body as string, authenticated via secure temporary config file.
(define (http-post-json url body)
  (let ((token (gips-auth-token)))
    (call-with-auth-config token
      (lambda (config-path)
        (run-curl* (list "-K" config-path
                         "-X" "POST"
                         "-H" "Content-Type: application/json"
                         "-d" body)
                   url)))))

;; GET url, unauthenticated (for /status and /search).
(define (http-get url)
  (run-curl* '() url))

;; Publish store-path; optional gns-name or #:deriver and #:system keyword args.
(define (gips-publish store-path . rest)
  (let* ((gns-name (and (pair? rest) (string? (car rest)) (car rest)))
         (kw-args (if (and (pair? rest) (string? (car rest))) (cdr rest) rest))
         (deriver (and (pair? kw-args) (let ((d (member #:deriver kw-args))) (and d (pair? (cdr d)) (cadr d)))))
         (system (and (pair? kw-args) (let ((s (member #:system kw-args))) (and s (pair? (cdr s)) (cadr s))))))
    (http-post-json (string-append (gips-base-url) "/publish")
                    (build-publish-json store-path gns-name #:deriver deriver #:system system))))

;; Publish store-path directory tree as native UnixFS DAG; optional gns-name or #:deriver and #:system keyword args.
(define (gips-publish-tree store-path . rest)
  (let* ((gns-name (and (pair? rest) (string? (car rest)) (car rest)))
         (kw-args (if (and (pair? rest) (string? (car rest))) (cdr rest) rest))
         (deriver (and (pair? kw-args) (let ((d (member #:deriver kw-args))) (and d (pair? (cdr d)) (cadr d)))))
         (system (and (pair? kw-args) (let ((s (member #:system kw-args))) (and s (pair? (cdr s)) (cadr s))))))
    (http-post-json (string-append (gips-base-url) "/publish-tree")
                    (build-publish-json store-path gns-name #:deriver deriver #:system system))))

;; GET /status. Unauthenticated: /status is a read-only endpoint.
(define (gips-status)
  (http-get (string-append (gips-base-url) "/status")))

;; POST /subscribe. Authenticated.
(define (gips-subscribe gns-name)
  (http-post-json (string-append (gips-base-url) "/subscribe")
                  (build-subscribe-json gns-name)))

;; POST /link-channel. Authenticated.
(define* (gips-link-channel channel-name gns-name #:key (allow-repoint? #f))
  (http-post-json (string-append (gips-base-url) "/link-channel")
                  (build-link-channel-json channel-name gns-name #:allow-repoint? allow-repoint?)))

;; POST /pin. Authenticated.
(define (gips-pin ipfs-cid)
  (http-post-json (string-append (gips-base-url) "/pin")
                  (build-pin-json ipfs-cid)))

;; POST /unpin. Authenticated.
(define (gips-unpin ipfs-cid)
  (http-post-json (string-append (gips-base-url) "/unpin")
                  (build-unpin-json ipfs-cid)))

;; POST /reindex. Authenticated.
(define* (gips-reindex #:key (prune-missing? #f) (store-paths '()))
  (http-post-json (string-append (gips-base-url) "/reindex")
                  (build-reindex-json #:prune-missing? prune-missing? #:store-paths store-paths)))

;; GET /search?q=<query>. Unauthenticated.
(define (gips-search query)
  (http-get (string-append (gips-base-url) "/search?q=" (uri-encode query))))

;; ---------------------------------------------------------------------------
;; Key Management & Snapshot Helpers
;; ---------------------------------------------------------------------------

(define (guix-public-key-path secret)
  (if (string-suffix? ".sec" secret)
      (string-append (string-drop-right secret 4) ".pub")
      (string-append secret ".pub")))

(define (feed-public-key-path secret)
  (let ((stem (if (string-suffix? ".pem" secret)
                  (string-drop-right secret 4)
                  secret)))
    (string-append stem ".pub.pem")))

(define (default-guix-key-path)
  (string-append (default-config-dir) "/gips/signing-key.sec"))

(define (default-feed-key-path)
  (string-append (default-config-dir) "/gips/feed-signing-key.pem"))

(define (locate-guix-keygen)
  (let ((from-env (getenv "GIPS_GUIX_KEYGEN")))
    (if (and from-env (file-exists? from-env))
        from-env
        (let* ((file (current-filename))
               (dir (if (string? file)
                        (dirname (if (absolute-file-name? file) file (in-vicinity (getcwd) file)))
                        (getcwd)))
               (candidates (list (string-append dir "/../../components/gips-trust/guile/guix-keygen.scm")
                                 (string-append (getcwd) "/components/gips-trust/guile/guix-keygen.scm")
                                 (string-append (getcwd) "/gips/components/gips-trust/guile/guix-keygen.scm"))))
          (or (find file-exists? candidates)
              (error "gips: cannot find components/gips-trust/guile/guix-keygen.scm"))))))

(define (find-gips-binary)
  (let ((from-env (getenv "GIPS_BIN")))
    (if (and from-env (file-exists? from-env))
        from-env
        (let* ((file (current-filename))
               (dir (if (string? file)
                        (dirname (if (absolute-file-name? file) file (in-vicinity (getcwd) file)))
                        (getcwd)))
               (candidates (list (string-append (getcwd) "/target/debug/gips")
                                 (string-append (getcwd) "/target/release/gips")
                                 (string-append (getcwd) "/gips/target/debug/gips")
                                 (string-append (getcwd) "/gips/target/release/gips")
                                 (string-append dir "/../../target/debug/gips")
                                 (string-append dir "/../../target/release/gips"))))
          (or (find file-exists? candidates)
              "gips")))))

;; Generate Guix-format narinfo signing key pair (ECDSA/Ed25519 advanced sexp).
;; Refuses to overwrite existing files. Sets 0600 permissions.
(define* (gips-key-generate-guix #:key (path #f) (guile #f))
  (let* ((secret (or path (default-guix-key-path)))
         (public (guix-public-key-path secret))
         (parent (dirname secret)))
    (when (or (file-exists? secret) (file-exists? public))
      (error "gips-key-generate-guix: key already exists; refusing to overwrite" secret))
    (unless (file-exists? parent)
      (mkdir parent #o700))
    (chmod parent #o700)
    (let* ((guile-bin (or guile
                          (let ((bindir (false-if-exception (assq-ref %guile-build-info 'bindir))))
                            (if (and (string? bindir) (file-exists? (string-append bindir "/guile")))
                                (string-append bindir "/guile")
                                "guile"))))
           (keygen-script (locate-guix-keygen))
           (sec-port (open secret (logior O_WRONLY O_CREAT O_EXCL) #o600))
           (pub-port (open public (logior O_WRONLY O_CREAT O_EXCL) #o600)))
      (close-port sec-port)
      (close-port pub-port)
      (chmod secret #o600)
      (chmod public #o600)
      (let* ((port (open-pipe* OPEN_READ guile-bin "-q" "--no-auto-compile" "-s" keygen-script "--" secret public))
             (out (get-string-all port))
             (status (close-pipe port)))
        (unless (and (status:exit-val status) (zero? (status:exit-val status)))
          (false-if-exception (delete-file secret))
          (false-if-exception (delete-file public))
          (error "gips-key-generate-guix: keygen helper failed" out))
        (chmod secret #o600)
        (chmod public #o600)
        (list secret public)))))

;; Export Guix public key sexp string (.pub sibling).
(define* (gips-key-export-guix #:key (path #f))
  (let* ((secret (or path (default-guix-key-path)))
         (public (guix-public-key-path secret)))
    (unless (file-exists? public)
      (error "gips-key-export-guix: public key not found at" public))
    (call-with-input-file public get-string-all)))

;; Generate Ed25519 feed key pair (PKCS#8 and SPKI PEM).
;; Refuses to overwrite existing files. Sets 0600 permissions.
(define* (gips-key-generate-feed #:key (path #f))
  (let* ((secret (or path (default-feed-key-path)))
         (public (feed-public-key-path secret))
         (parent (dirname secret)))
    (when (or (file-exists? secret) (file-exists? public))
      (error "gips-key-generate-feed: key already exists; refusing to overwrite" secret))
    (unless (file-exists? parent)
      (mkdir parent #o700))
    (chmod parent #o700)
    (let* ((gips-bin (find-gips-binary))
           (port (open-pipe* OPEN_READ gips-bin "key" "generate-feed" "--path" secret))
           (out (get-string-all port))
           (status (close-pipe port)))
      (unless (and (status:exit-val status) (zero? (status:exit-val status)))
        (error "gips-key-generate-feed: failed" out))
      (list secret public))))

;; Export Ed25519 feed public key PEM string (.pub.pem sibling).
(define* (gips-key-export-feed #:key (path #f))
  (let* ((secret (or path (default-feed-key-path)))
         (public (feed-public-key-path secret)))
    (unless (file-exists? public)
      (error "gips-key-export-feed: public key not found at" public))
    (call-with-input-file public get-string-all)))

;; Advertise a public key (Guix or feed) to GNS via the daemon
(define* (gips-key-advertise-gns gns-name #:key (key-path #f) (key-type "guix"))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "key" "advertise-gns"
                             "--name" gns-name
                             "--key-type" key-type
                             "--daemon" (gips-base-url)
                             "--auth-token-file" (gips-auth-token-file))
                       (if key-path (list "--path" key-path) '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-key-advertise-gns: command failed" out))
    out))

;; Fetch an advertised public key from GNS via the daemon
(define* (gips-key-fetch-gns gns-name #:key (key-type "guix"))
  (let* ((gips-bin (find-gips-binary))
         (args (list "key" "fetch-gns"
                     "--name" gns-name
                     "--key-type" key-type
                     "--daemon" (gips-base-url)))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-key-fetch-gns: command failed" out))
    out))

;; List authorized Guix keys from ACL file (/etc/guix/acl)
(define* (gips-key-acl-list #:key (acl-file #f) (json? #f))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "key" "acl" "list")
                       (if acl-file (list "--acl-file" acl-file) '())
                       (if json? (list "--json") '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-key-acl-list: command failed" out))
    out))

;; Check if a public key is authorized in Guix ACL file
(define* (gips-key-acl-check #:key (acl-file #f) (key-file #f) (name #f) (key #f))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "key" "acl" "check"
                             "--daemon" (gips-base-url))
                       (if acl-file (list "--acl-file" acl-file) '())
                       (if key-file (list "--key-file" key-file) '())
                       (if name (list "--name" name) '())
                       (if key (list "--key" key) '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (and (status:exit-val status) (zero? (status:exit-val status)))))

;; Authorize a public key into Guix ACL file
(define* (gips-key-acl-authorize #:key (acl-file #f) (key-file #f) (name #f) (key #f) (dry-run? #f))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "key" "acl" "authorize"
                             "--daemon" (gips-base-url))
                       (if acl-file (list "--acl-file" acl-file) '())
                       (if key-file (list "--key-file" key-file) '())
                       (if name (list "--name" name) '())
                       (if key (list "--key" key) '())
                       (if dry-run? (list "--dry-run") '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-key-acl-authorize: command failed" out))
    out))

;; Revoke a public key from Guix ACL file
(define* (gips-key-acl-revoke #:key (acl-file #f) (key-file #f) (name #f) (key #f) (dry-run? #f))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "key" "acl" "revoke"
                             "--daemon" (gips-base-url))
                       (if acl-file (list "--acl-file" acl-file) '())
                       (if key-file (list "--key-file" key-file) '())
                       (if name (list "--name" name) '())
                       (if key (list "--key" key) '())
                       (if dry-run? (list "--dry-run") '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-key-acl-revoke: command failed" out))
    out))

;; Diff authorized Guix ACL keys against candidate/trusted key files
(define* (gips-key-acl-diff #:key (acl-file #f) (key-files '()) (json? #f))
  (let* ((gips-bin (find-gips-binary))
         (key-args (fold-right (lambda (kf acc) (cons* "--key-file" kf acc)) '() key-files))
         (args (append (list "key" "acl" "diff")
                       (if acl-file (list "--acl-file" acl-file) '())
                       key-args
                       (if json? (list "--json") '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-key-acl-diff: command failed" out))
    out))

;; Create an offline snapshot capability from a manifest.
;; Computes closure, publishes paths, and posts /snapshot/create via CLI.
(define* (gips-snapshot-create manifest #:key (gns-name #f))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "snapshot" "create" manifest
                             "--daemon" (gips-base-url)
                             "--auth-token-file" (gips-auth-token-file))
                       (if (and gns-name (not (string-null? gns-name)))
                           (list "--gns-name" gns-name)
                           '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-snapshot-create: command failed" out))
    out))

;; List all snapshots known to the daemon (GET /snapshot/list). Unauthenticated.
(define (gips-snapshot-list)
  (http-get (string-append (gips-base-url) "/snapshot/list")))

;; Import a snapshot from an IPFS CID (POST /snapshot/import). Authenticated.
(define (gips-snapshot-import cid)
  (http-post-json (string-append (gips-base-url) "/snapshot/import")
                  (build-snapshot-import-json cid)))

;; Export a snapshot and its constituent NAR artifacts as a tar archive (GET /snapshot/export/:cid). Unauthenticated.
;; If output-file is provided, downloads to that path. Otherwise defaults to <cid>.tar. Returns the target file path.
(define* (gips-snapshot-export cid #:key (output-file #f))
  (let* ((url (string-append (gips-base-url) "/snapshot/export/" (uri-encode cid)))
         (target (or output-file (string-append cid ".tar"))))
    (run-curl* (list "-o" target) url)
    target))

;; Fetch current metrics snapshot (optionally in Prometheus format)
(define* (gips-metrics #:key (prometheus? #f))
  (let ((token (gips-auth-token))
        (url (string-append (gips-base-url) "/metrics" (if prometheus? "?format=prometheus" ""))))
    (call-with-auth-config token
      (lambda (cfg-file)
        (let* ((cmd (format #f "curl -s -f -K ~a ~a ~a"
                            cfg-file
                            (if prometheus? "-H 'Accept: text/plain'" "-H 'Accept: application/json'")
                            url))
               (port (open-input-pipe cmd))
               (output (get-string-all port))
               (status (close-pipe port)))
          (unless (zero? (status:exit-val status))
            (error "gips-metrics failed" status))
          output)))))

;; Fetch recorded rolling metrics history snapshots
(define* (gips-metrics-history #:key (limit 50))
  (let ((token (gips-auth-token))
        (url (format #f "~a/metrics/history?limit=~a" (gips-base-url) limit)))
    (call-with-auth-config token
      (lambda (cfg-file)
        (let* ((cmd (format #f "curl -s -f -K ~a -H 'Accept: application/json' ~a"
                            cfg-file
                            url))
               (port (open-input-pipe cmd))
               (output (get-string-all port))
               (status (close-pipe port)))
          (unless (zero? (status:exit-val status))
            (error "gips-metrics-history failed" status))
          output)))))

;; Mint an attenuable capability delegation token.
(define* (gips-vouch-mint issuer-key-path subject-pubkey
                          #:key (parent-token #f)
                                (expires-in 86400)
                                (max-depth 2)
                                (stake-score 100)
                                (path-prefixes '("/gnu/store/")))
  (let* ((gips-bin (find-gips-binary))
         (prefix-args (append-map (lambda (p) (list "--prefix" p)) path-prefixes))
         (parent-args (if (and parent-token (not (eq? parent-token #f)))
                          (list "--parent-token" parent-token)
                          '()))
         (args (append (list "vouch" "mint"
                             "--issuer-key" issuer-key-path
                             "--subject" subject-pubkey
                             "--expires-in" (number->string expires-in)
                             "--depth" (number->string max-depth)
                             "--stake" (number->string stake-score))
                       parent-args
                       prefix-args))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-vouch-mint: command failed" out))
    out))

;; Verify a delegation token chain.
(define* (gips-vouch-verify root-pubkey chain-json #:key (target-subject #f))
  (let* ((gips-bin (find-gips-binary))
         (target-args (if (and target-subject (not (eq? target-subject #f)))
                          (list "--target" target-subject)
                          '()))
         (args (append (list "vouch" "verify"
                             "--root-key" root-pubkey
                             "--chain" chain-json)
                       target-args))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-vouch-verify: verification failed" out))
    out))

;; Inspect a delegation token.
(define (gips-vouch-inspect token-json)
  (let* ((gips-bin (find-gips-binary))
         (args (list "vouch" "inspect" "--token" token-json))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-vouch-inspect: command failed" out))
    out))

;; Generate a HashMismatch fraud proof.
(define (gips-fraud-proof-generate-hash-mismatch narinfo sig artifact publisher)
  (let* ((gips-bin (find-gips-binary))
         (args (list "fraud-proof" "generate" "hash-mismatch"
                     "--narinfo" narinfo
                     "--signature" sig
                     "--artifact" artifact
                     "--publisher" publisher))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-fraud-proof-generate-hash-mismatch failed" out))
    out))

;; Generate an Equivocation fraud proof.
(define (gips-fraud-proof-generate-equivocation feed-a feed-b publisher)
  (let* ((gips-bin (find-gips-binary))
         (args (list "fraud-proof" "generate" "equivocation"
                     "--feed-a" feed-a
                     "--feed-b" feed-b
                     "--publisher" publisher))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-fraud-proof-generate-equivocation failed" out))
    out))

;; Verify a cryptographic fraud proof independently.
(define (gips-fraud-proof-verify proof-json)
  (let* ((gips-bin (find-gips-binary))
         (args (list "fraud-proof" "verify" "--proof" proof-json))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-fraud-proof-verify failed" out))
    out))

;; Submit a verified cryptographic fraud proof to the daemon (POST /fraud-proof/submit).
(define (gips-fraud-proof-submit proof-json)
  (let ((url (string-append (gips-base-url) "/fraud-proof/submit")))
    (run-curl* (list "-X" "POST"
                     "-H" "Content-Type: application/json"
                     "-d" proof-json)
               url)))

;; List recorded active fraud proofs / revocations from the daemon (GET /fraud-proof/list).
(define (gips-fraud-proof-list)
  (http-get (string-append (gips-base-url) "/fraud-proof/list")))

;; Ingest a verified delegation chain into the daemon (POST /vouch/ingest). Authenticated.
(define (gips-vouch-ingest chain)
  (http-post-json (string-append (gips-base-url) "/vouch/ingest")
                  (build-vouch-ingest-json chain)))

;; Evaluate web-of-trust reputation score for a publisher (POST /trust/evaluate).
(define* (gips-trust-evaluate publisher-pubkey #:key (store-path #f) (chain #f))
  (let ((url (string-append (gips-base-url) "/trust/evaluate"))
        (body (build-trust-evaluate-json publisher-pubkey #:store-path store-path #:chain chain)))
    (run-curl* (list "-X" "POST"
                     "-H" "Content-Type: application/json"
                     "-d" body)
               url)))

;; GET /gossip/status. Unauthenticated: /gossip/status is a read-only endpoint.
(define (gips-gossip-status)
  (http-get (string-append (gips-base-url) "/gossip/status")))

;; Terminal swarm monitor snapshot (single pass or json)
(define* (gips-monitor #:key (once? #t) (json? #f))
  (let* ((gips-bin (find-gips-binary))
         (args (append (list "monitor" "--daemon" (gips-base-url))
                       (if once? (list "--once") '())
                       (if json? (list "--json") '())))
         (port (apply open-pipe* OPEN_READ gips-bin args))
         (out (get-string-all port))
         (status (close-pipe port)))
    (unless (and (status:exit-val status) (zero? (status:exit-val status)))
      (error "gips-monitor: command failed" out))
    out))

;; Query substitutes by hash prefix (GET /substitute/prefix/:prefix)
(define (gips-search-prefix prefix)
  (http-get (string-append (gips-base-url) "/substitute/prefix/" (uri-encode prefix))))

