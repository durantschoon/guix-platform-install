# Stage 38 — GNS Key Distribution & Discovery (`gips key advertise-gns` / `gips key fetch-gns`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In GIPS, package substitutes are signed with Guix-format libgcrypt keys and GIPS Ed25519 feed keys. Today, operators must manually copy public key files out-of-band to run `guix archive --authorize`.

`docs/stages/completed/stage-22-SKETCH-expanded-into-29-30.md` item 2 identifies this gap:

- *"Provide a `guix archive --authorize`-compatible key-advertisement/authorization workflow, and key distribution over GNS."*

By providing GNS key advertisement (`gips key advertise-gns`) and discovery (`gips key fetch-gns`), consumers can resolve a trusted publisher's public key directly from their decentralized GNS domain name and authorize it with `gips key fetch-gns --name <publisher.gnu> | sudo guix archive --authorize`.

## The Change

1. **GNS TXT Record Publishing & Resolution in `components/gips-gns`**:
   - Add `publish_txt(&self, name: &str, value: &str) -> Result<()>` (record type 16 / TXT).
   - Add `resolve_txt(&self, name: &str) -> Result<String>` (record type 16 / TXT).
   - Clean up `mut child` unused mutability warning on `resolve`.
   - Add unit tests for GNS TXT record validation and formatting.
2. **HTTP Endpoints in `components/gips-http`**:
   - Add authenticated route `POST /key/advertise` accepting `{ "gns_name": String, "public_key": String, "key_type": Option<String> }` to publish key records to GNS via the daemon's configured GNS client.
   - Add public route `GET /key/resolve` with `?name=<gns_name>&type=<key_type>` resolving public keys via GNS.
   - Add unit tests.
3. **CLI Commands in `gips/src/main.rs`**:
   - Extend `KeyCommands` with:
     - `AdvertiseGns { name: String, path: Option<PathBuf>, #[arg(long, default_value = "guix")] key_type: String }`
     - `FetchGns { name: String, #[arg(long, default_value = "guix")] key_type: String }`
   - Handle command dispatching, printing key contents to stdout so they pipe cleanly into `guix archive --authorize`.
4. **Scheme API in `scheme/gips/api.scm` & `test_api.scm`**:
   - Export and implement `(gips-key-advertise-gns name #:key-path #f #:key-type "guix")` and `(gips-key-fetch-gns name #:key-type "guix")`.
   - Add unit tests in `test_api.scm`.
5. **Docs**:
   - Update `docs/TODO.md` and related trust documentation.

## Allowed Files Whitelist

- `components/gips-gns/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`

## Enumerated Tests

1. **GNS TXT Record Handling**: `GnsClient::publish_txt` and `resolve_txt` execute the underlying command with record type 16 and parse the result.
2. **HTTP Key Advertisement & Resolution**: `POST /key/advertise` publishes to GNS and requires auth; `GET /key/resolve` resolves GNS keys.
3. **CLI & Scheme Parity**: `gips key advertise-gns` / `fetch-gns` CLI and Scheme procedures execute and pipe clean public key text.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-38] feat: GNS key distribution and discovery (advertise-gns, fetch-gns, Scheme API)`
