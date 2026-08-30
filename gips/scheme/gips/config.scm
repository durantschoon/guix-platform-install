(define-module (gips config)
  #:export (<gipsd-configuration>
            gipsd-configuration
            gipsd-configuration?
            gipsd-configuration-listen
            gipsd-configuration-db-path
            gipsd-configuration-ipfs-api
            gipsd-configuration-gns-command
            gipsd-configuration-snapshot-cid
            gipsd-configuration-gossip-transport
            gipsd-configuration-cadet-port
            gipsd-configuration-cadet-command
            gipsd-configuration-trusted-publishers
            gipsd-configuration-allow-unsigned?
            gipsd-configuration-guix-signing
            <trusted-publisher>
            trusted-publisher
            trusted-publisher?
            trusted-publisher-gns-name
            trusted-publisher-public-key
            <guix-signing>
            guix-signing
            guix-signing?
            guix-signing-secret-key
            guix-signing-host
            guix-signing-guile
            gipsd-configuration->toml))

(use-modules (srfi srfi-9)
             (ice-9 format))

;;; A publisher this daemon accepts signatures from. Mirrors the Rust
;;; `gips_trust::TrustedPublisher`.
(define-record-type <trusted-publisher>
  (%make-trusted-publisher gns-name public-key)
  trusted-publisher?
  (gns-name   trusted-publisher-gns-name)
  (public-key trusted-publisher-public-key))

(define* (trusted-publisher #:key gns-name public-key)
  "Declare trust in GNS-NAME, whose Ed25519 public key is the file PUBLIC-KEY.
Both are required: a publisher with no key cannot be verified, and silently
dropping it would be a trust decision made by omission."
  (unless (string? gns-name)
    (error "trusted-publisher: #:gns-name must be a string" gns-name))
  (unless (string? public-key)
    (error "trusted-publisher: #:public-key must be a path string" public-key))
  (%make-trusted-publisher gns-name public-key))

;;; The Guix-format key this node signs served narinfos with. Mirrors the Rust
;;; `gips_trust::guix::GuixSigningConfig`.
;;;
;;; This is a *different* key from `trusted-publishers`: those verify the GIPS
;;; feed's Ed25519 signatures, this one signs narinfos the way `guix publish`
;;; does, and the two formats are not interconvertible. Only the secret key's
;;; path is configured — the public half is its `.pub` sibling, so there is no
;;; way to name a `.sec` and a `.pub` that do not belong together.
(define-record-type <guix-signing>
  (%make-guix-signing secret-key host guile)
  guix-signing?
  (secret-key guix-signing-secret-key)
  (host       guix-signing-host)
  (guile      guix-signing-guile))

(define* (guix-signing #:key secret-key (host #f) (guile #f))
  "Sign served narinfos with SECRET-KEY, an advanced-sexp key as written by
`gips key generate-guix'.

HOST is what appears in `Signature: 1;<host>;…'; #f lets the daemon use this
machine's host name, which is what `guix publish' does. GUILE names the
interpreter the signing helper runs under; #f resolves `guile' on PATH.

SECRET-KEY is required: a signing block with no key cannot sign, and emitting
one anyway would make a daemon refuse to start over a typo in a *declaration*
rather than here, where the mistake was made."
  (unless (string? secret-key)
    (error "guix-signing: #:secret-key must be a path string" secret-key))
  (unless (or (not host) (string? host))
    (error "guix-signing: #:host must be a string or #f" host))
  (unless (or (not guile) (string? guile))
    (error "guix-signing: #:guile must be a path string or #f" guile))
  (%make-guix-signing secret-key host guile))

;;; The `gipsd-configuration` record mirrors the Rust `GipsdConfig` struct.
;;;
;;; `trusted-publishers` and `allow-unsigned?` are the Scheme half of
;;; `GipsdConfig.trust`. Before they existed the emitter could not express
;;; trust at all, so every Scheme-configured daemon deserialized an empty trust
;;; list and rejected every signed substitute with no way to say otherwise.
(define-record-type <gipsd-configuration>
  (%make-gipsd-configuration listen db-path ipfs-api gns-command snapshot-cid
                             gossip-transport cadet-port cadet-command
                             trusted-publishers allow-unsigned? guix-signing)
  gipsd-configuration?
  (listen             gipsd-configuration-listen)
  (db-path            gipsd-configuration-db-path)
  (ipfs-api           gipsd-configuration-ipfs-api)
  (gns-command        gipsd-configuration-gns-command)
  (snapshot-cid       gipsd-configuration-snapshot-cid)
  (gossip-transport   gipsd-configuration-gossip-transport)
  (cadet-port         gipsd-configuration-cadet-port)
  (cadet-command      gipsd-configuration-cadet-command)
  (trusted-publishers gipsd-configuration-trusted-publishers)
  (allow-unsigned?    gipsd-configuration-allow-unsigned?)
  (guix-signing       gipsd-configuration-guix-signing))

(define* (gipsd-configuration #:key
                              (listen "127.0.0.1:8080")
                              (db-path "~/.config/gips/gipsd.sqlite")
                              (ipfs-api "http://127.0.0.1:5001")
                              (gns-command "gnunet-gns")
                              (snapshot-cid #f)
                              (gossip-transport "ipfs")
                              (cadet-port "gips-gossip")
                              (cadet-command "gnunet-cadet")
                              (trusted-publishers '())
                              (allow-unsigned? #f)
                              (guix-signing #f))
  (unless (and (list? trusted-publishers)
               (every-trusted-publisher? trusted-publishers))
    (error "gipsd-configuration: #:trusted-publishers must be a list of <trusted-publisher>"
           trusted-publishers))
  (unless (or (not guix-signing) (guix-signing? guix-signing))
    (error "gipsd-configuration: #:guix-signing must be a <guix-signing> or #f"
           guix-signing))
  (%make-gipsd-configuration listen db-path ipfs-api gns-command snapshot-cid
                             gossip-transport cadet-port cadet-command
                             trusted-publishers allow-unsigned? guix-signing))

(define (every-trusted-publisher? lst)
  (or (null? lst)
      (and (trusted-publisher? (car lst))
           (every-trusted-publisher? (cdr lst)))))

(define (toml-boolean value)
  (if value "true" "false"))

(define (trusted-publisher->toml publisher)
  "Emit one `[[trust.trusted_publishers]]` array-of-tables entry."
  (format #f "\n[[trust.trusted_publishers]]\ngns_name = ~s\npublic_key = ~s\n"
          (trusted-publisher-gns-name publisher)
          (trusted-publisher-public-key publisher)))

(define (trust->toml config)
  "Emit the `[trust]` table.

Always emitted, even when empty: this record *is* the daemon's configuration,
so \"no publishers listed\" has to reach the daemon as an explicit empty trust
list rather than as an absent key the merge would fill in from elsewhere."
  (string-append
   (format #f "\n[trust]\nallow_unsigned = ~a\n"
           (toml-boolean (gipsd-configuration-allow-unsigned? config)))
   (apply string-append
          (map trusted-publisher->toml
               (gipsd-configuration-trusted-publishers config)))))

(define (guix-signing->toml signing)
  "Emit the `[guix_signing]` table, or the empty string when SIGNING is #f.

Absence is meaningful and is expressed by absence: an omitted table leaves the
daemon serving narinfos unsigned, exactly as it did before this key existed.
Emitting an empty `[guix_signing]` instead would be a block with no
`secret_key`, which the daemon rejects — a configuration that says nothing must
not fail to start."
  (if (not signing)
      ""
      (string-append
       (format #f "\n[guix_signing]\nsecret_key = ~s\n"
               (guix-signing-secret-key signing))
       ;; `host` and `guile` are `Option`s on the Rust side, and their
       ;; `#[serde(default)]` means an omitted key is `None`. So an unset field
       ;; is omitted rather than emitted as an empty string, which would
       ;; configure an unusable host name instead of no host name.
       (if (guix-signing-host signing)
           (format #f "host = ~s\n" (guix-signing-host signing))
           "")
       (if (guix-signing-guile signing)
           (format #f "guile = ~s\n" (guix-signing-guile signing))
           ""))))

(define (gipsd-configuration->toml config)
  "Serialize a <gipsd-configuration> record to a TOML string suitable for the Rust daemon.

Scalar keys come first: in TOML every key after a table header belongs to that
table, so emitting `[trust]` before `listen` would silently reparent it."
  (let* ((base (format #f "listen = ~s\ndb_path = ~s\nipfs_api = ~s\ngns_command = ~s\ngossip_transport = ~s\ncadet_port = ~s\ncadet_command = ~s\n"
                       (gipsd-configuration-listen config)
                       (gipsd-configuration-db-path config)
                       (gipsd-configuration-ipfs-api config)
                       (gipsd-configuration-gns-command config)
                       (gipsd-configuration-gossip-transport config)
                       (gipsd-configuration-cadet-port config)
                       (gipsd-configuration-cadet-command config)))
         (with-snapshot
          (if (gipsd-configuration-snapshot-cid config)
              (string-append base (format #f "snapshot_cid = ~s\n"
                                          (gipsd-configuration-snapshot-cid config)))
              base)))
    (string-append with-snapshot
                   (trust->toml config)
                   ;; After `[trust]` and its `[[trust.trusted_publishers]]`
                   ;; entries: a new table header ends the previous table, so
                   ;; ordering these two is safe, while putting either before
                   ;; the scalars would not be.
                   (guix-signing->toml (gipsd-configuration-guix-signing config)))))
