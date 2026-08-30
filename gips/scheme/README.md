# GIPS Scheme API

<!-- markdownlint-disable MD013 -->

REPL parity with the **gips** CLI: every command you can run on the command line is available as a procedure in the Guile Scheme REPL.

**Requires:** `curl` on `PATH`.

**Base URL precedence**, most explicit first:

1. an explicit `(gips-base-url "http://...")` — the setter wins outright
2. the environment variable `GIPS_DAEMON`
3. `http://127.0.0.1:8080`

Before this was fixed, `GIPS_DAEMON` beat the explicit setter: a stale or hostile env var silently redirected every request while the REPL still reported the URL you had asked for.

**Authentication.** `gipsd` requires a local auth token on every mutating endpoint (`/publish`, `/subscribe`, `/link-channel`, `/pin`, `/unpin`, `/reindex`, `/snapshot/create`). The daemon writes the token to `<config-dir>/gips/auth-token` with mode `0600` on first start, and `(gips api)` reads it from there. Override the location with `GIPS_AUTH_TOKEN_FILE` or `(gips-auth-token-file "/path/to/token")`. Read-only endpoints that Guix itself calls (`/narinfo`, `/nar`, `/status`, `/search`) need no token.

**Security:** To prevent process argument inspection attacks (`ps aux`, `/proc/<pid>/cmdline`), bearer tokens are never passed on `curl`'s `argv`. Instead, the `Authorization` header is passed via a temporary `0600` config file (`curl -K`) inside a private `0700` directory and immediately deleted upon completion or error via `dynamic-wind`.

## Quick start

**Start servers (optional).** To call `gips-status` or `gips-publish` against a real daemon, start **gipsd** (and, for publish to work, an **IPFS** node reachable at gipsd’s configured `ipfs_api`). From the repo root:

```bash
# Terminal 1: IPFS (if you want publish to work)
ipfs daemon
```

Then start the daemon (requires Rust); it listens on `127.0.0.1:8080` by default and mints the auth token on first run:

```sh
just daemon
```

**Start the REPL.** From the repository root:

```bash
./scheme/run-guile
```

(Or `GUILE_LOAD_PATH=scheme guile` if you prefer.)

Then in the REPL:

```scheme
(use-modules (gips api))

(gips-base-url)                                         ;; current daemon URL
(gips-status)                                           ;; GET /status
(gips-publish "/gnu/store/...-foo-1.0" "example.gnu")   ;; POST /publish
(gips-subscribe "publisher.gnu")                        ;; POST /subscribe
(gips-link-channel "guix" "test.gnu")                   ;; POST /link-channel
(gips-pin "Qm...")                                      ;; POST /pin
(gips-unpin "Qm...")                                    ;; POST /unpin
(gips-reindex #:prune-missing? #t)                      ;; POST /reindex
(gips-search "hello")                                   ;; GET /search?q=hello
(gips-key-generate-guix)                                ;; generates signing-key.sec & .pub
(gips-key-export-guix)                                  ;; exports public sexp
(gips-key-generate-feed)                                ;; generates feed-signing-key.pem & .pub.pem
(gips-key-export-feed)                                  ;; exports public PEM
```

To point at another daemon for the rest of the session:

```scheme
(gips-base-url "http://localhost:9999")
(gips-status)
```

This setting wins over `GIPS_DAEMON` for the rest of the session.

## Procedures

| Procedure | Mirrors CLI | Notes |
| --- | --- | --- |
| `gips-base-url` | `--daemon` | Get or set base URL (one optional arg = set). Set wins over `GIPS_DAEMON`. |
| `gips-auth-token-file` | `--auth-token-file` | Get or set the auth token path. Set wins over `GIPS_AUTH_TOKEN_FILE`. |
| `gips-auth-token` | — | The token itself; errors if the file is missing or empty. |
| `gips-auth-rotate` `#:key token-file` | `gips auth rotate` | Rotates daemon auth token with 0600 permissions. |
| `gips-publish` *store-path* [*gns-name*] | `gips publish ...` / `just snapshot ...` | Returns response body string. Authenticated. |
| `gips-status` | `gips status` / `just status` | Returns response body string. Unauthenticated. |
| `gips-subscribe` *gns-name* | `gips subscribe ...` | Subscribes to a publisher. Returns response body string. Authenticated. |
| `gips-link-channel` *channel* *gns-name* `#:key allow-repoint?` | `gips link-channel ...` | Links channel to GNS name. Returns response body string. Authenticated. |
| `gips-pin` *cid* | `gips pin ...` | Requests daemon to pin IPFS CID. Authenticated. |
| `gips-unpin` *cid* | `gips unpin ...` | Requests daemon to unpin IPFS CID. Authenticated. |
| `gips-reindex` `#:key prune-missing? store-paths` | `gips reindex ...` | Triggers substitute reindex. Authenticated. |
| `gips-search` *query* | `gips search ...` | Searches substitutes with URL-encoded query. Unauthenticated. |
| `gips-key-generate-guix` `#:key path guile` | `gips key generate-guix` | Generates Guix narinfo key pair with 0600 permissions. |
| `gips-key-export-guix` `#:key path` | `gips key export-guix` | Returns public key sexp ready for `guix archive --authorize`. |
| `gips-key-generate-feed` `#:key path` | `gips key generate-feed` | Generates Ed25519 feed key pair with 0600 permissions. |
| `gips-key-export-feed` `#:key path` | `gips key export-feed` | Returns public feed PEM. |
| `gips-key-advertise-gns` *name* `#:key key-path key-type` | `gips key advertise-gns` | Publishes public key to GNS TXT record. Authenticated. |
| `gips-key-fetch-gns` *name* `#:key key-type` | `gips key fetch-gns` | Resolves public key from GNS TXT record. Unauthenticated. |
| `gips-snapshot-create` *manifest* `#:key gns-name` | `gips snapshot create ...` | Computes closure, publishes paths, and posts snapshot creation. |
| `gips-snapshot-list` | `gips snapshot list` | Lists all known local snapshot manifests. Unauthenticated. |
| `gips-snapshot-import` *cid* | `gips snapshot import <cid>` | Imports snapshot manifest and pins referenced CIDs. Authenticated. |
| `gips-snapshot-export` *cid* `#:key output-file` | `gips snapshot export <cid>` | Downloads streaming POSIX `.tar` snapshot archive. |
| `gips-vouch-mint` *issuer-key* *subject* `...` | `gips vouch mint ...` | Mints attenuable UCAN delegation token signed with Ed25519 feed key. |
| `gips-vouch-verify` *root-key* *chain-json* `...` | `gips vouch verify ...` | Validates multi-hop delegation chain with strict capability attenuation. |
| `gips-vouch-inspect` *token-json* | `gips vouch inspect ...` | Human-readable inspection of delegation token payload and status. |
| `gips-vouch-ingest` *chain-json* | `gips vouch ingest ...` | Submits valid vouch chain to daemon database and triggers gossip. Authenticated. |
| `gips-fraud-proof-generate-hash-mismatch` *...* | `gips fraud-proof generate hash-mismatch` | Generates objective `HashMismatch` fraud proof. |
| `gips-fraud-proof-generate-equivocation` *...* | `gips fraud-proof generate equivocation` | Generates objective `Equivocation` fraud proof. |
| `gips-fraud-proof-verify` *proof-json* | `gips fraud-proof verify` | Mathematically verifies self-contained fraud proof. |
| `gips-fraud-proof-submit` *proof-json* | `gips fraud-proof submit` | Submits verified fraud proof to daemon, blacklists publisher, and gossips. |
| `gips-fraud-proof-list` | `gips fraud-proof list` | Lists active fraud proof revocations. Unauthenticated. |
| `gips-trust-evaluate` *publisher-key* `...` | `gips trust evaluate` | Dynamically evaluates transitive web-of-trust score with stake decay. |
| `gips-gossip-status` | `gips gossip status` | Inspects pubsub topic peering and propagation statistics. |

## Configuration API

The `(gips config)` module provides an API to generate the `gipsd.toml` configuration file natively from Guile Scheme.

```scheme
(use-modules (gips config))

;; Instantiate a configuration record with optional overrides
(define my-config
  (gipsd-configuration
    #:listen "127.0.0.1:9090"
    #:ipfs-api "http://192.168.1.100:5001"))

;; Serialize it to TOML
(display (gipsd-configuration->toml my-config))
```

This matches the behavior of the Rust `GipsdConfig` and allows advanced users to maintain their configuration entirely in Scheme.

### Keep `listen` on loopback

`gipsd` refuses to start on a non-loopback address (`0.0.0.0`, `[::]`, a LAN address) unless `insecure_bind = true` is set in `gipsd.toml`, and logs a prominent warning when it is.

This does not restrict multi-machine sync. IPFS carries all cross-machine transport; `gipsd` only ever needs to talk to the `guix-daemon` on its own host, so `127.0.0.1` is sufficient. Exposing the socket instead hands `/publish`, `/pin`, `/unpin`, `/subscribe`, `/link-channel`, and `/snapshot/create` to anyone who can reach the port and learn the token.
