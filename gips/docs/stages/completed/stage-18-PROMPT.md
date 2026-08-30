# Stage 18 — Authentication and network-exposure hardening

**Motivation:** There is no authentication on any endpoint; mutating endpoints (`/publish`, `/pin`, `/unpin`, `/subscribe`, `/link-channel`, **and `/snapshot/create`**) are fully open, `/nar/:cid` is an open unauthenticated IPFS proxy, and `scheme/README.md:74` demonstrates binding `0.0.0.0`. Anyone who can reach the socket can publish, pin arbitrary CIDs (disk-fill / host arbitrary content), evict everything, or forge a signed-looking snapshot manifest.

> **Anchor by `fn` name + quoted code, not line number.** The mutating routes are wired in `build_router` (≈`gips-http:134-148`).

> **CRITICAL — the route list.** The actual router registers `/snapshot/create` (≈`:145`, `post(create_snapshot)`) — it was missing from the original endpoint list and MUST be authenticated. Also note the native-narinfo route is `.route("/:file", get(get_native_narinfo))` (≈`:140`), a **bare single-segment catch-all**, not the `/:hash.narinfo` some prompts assume: `file` is a fully attacker-controlled string, so any auth/validation reasoning that assumes a constrained `:hash` parameter is on a false premise.

**The Change:**

1. **Loopback by default, refuse public bind unless opted in.** At startup, if `listen` is non-loopback and `insecure_bind` (new, default `false`) is not set, **refuse to start** with a clear error. When opted in, log a prominent warning. *(Note: This does not break personal multi-machine sync! Since IPFS handles all cross-machine transport, `gipsd` only ever needs to listen on `127.0.0.1` to talk to the local `guix-daemon` on that specific machine).*
2. **Local auth token for mutating endpoints.** Generate a token via a CSPRNG (e.g., 32 bytes from `/dev/urandom`), store it with mode `0600`, and require it on **all** mutating endpoints: `/publish`, `/pin`, `/unpin`, `/subscribe`, `/link-channel`, **and `/snapshot/create`**. The token verification in `gips-http` must use constant-time string comparison (`subtle::ConstantTimeEq`) to prevent timing attacks. The `gips` CLI reads and sends it automatically. Read-only endpoints Guix needs (`/narinfo`, `/nar`, the `/:file` native-narinfo route) stay unauthenticated but are governed by Stages 14–16 verification.
3. Scope `/nar/:cid` so it only serves CIDs the node actually tracks/pins (no arbitrary-CID proxying), or require the token for the raw-CID form.
4. **Harden `/link-channel` semantics.** It uses `ON CONFLICT(channel_name) DO UPDATE SET gns_name = excluded.gns_name` (an unconditional repoint of an existing channel to a different publisher), unlike `/subscribe`'s `INSERT OR IGNORE`. Even behind the token, make repointing explicit/rejected-by-default rather than a silent overwrite, or document why overwrite is intended. (The `channels` table is currently never read anywhere — confirm it is actually needed before adding auth around dead write-only state.)
5. **Fix the REPL/CLI client's own exposure bugs** (`scheme/gips/api.scm`): `GIPS_DAEMON` is consulted **before** the fluid set by `(gips-base-url ...)` (≈`:29-35`), so a stale/hostile env var silently redirects every request — including the store paths published and the new auth token — while the REPL reports the URL the user asked for. Make the explicit setter authoritative over the env fallback. Also add `--` before the URL in the `curl` invocation (≈`:59-63`) so a base URL beginning with `-` cannot inject curl options (`-K`, `-o`, `--upload-file`); this is the same flag-injection class Stage 19 fixes for `gnunet-gns`.
6. Update `scheme/README.md` to stop demonstrating `0.0.0.0` without the explicit opt-in + warning context, and correct the `(gips-base-url ...)` documentation to match the fixed precedence.

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs` (auth extractor/middleware, `/nar/:cid` scoping, `/snapshot/create` auth, `/link-channel` semantics)
- `bases/gips-config/src/lib.rs` (`insecure_bind`, token path)
- `gipsd/src/main.rs` (bind refusal, token load)
- `gips/src/main.rs` (send token)
- `scheme/gips/api.scm` (GIPS_DAEMON precedence, curl `--`)
- `scheme/README.md`
- `components/gips-http/Cargo.toml` (add `tower-http` if used)
- `#[cfg(test)]` modules

**Enumerated Tests:**

1. `POST /publish` without the token ⇒ 401; with the correct token ⇒ proceeds. Same for **`POST /snapshot/create`** (explicitly test it — it was the missing endpoint).
2. Starting `gipsd` with `listen = "0.0.0.0:9090"` and no `insecure_bind` **fails to start**.
3. `/nar/:cid` for an untracked CID is refused (or requires the token).
4. The `gips` CLI round-trips a mutating command using the on-disk token.
5. With `GIPS_DAEMON` set in the environment, `(gips-base-url "http://explicit")` still directs requests to `http://explicit` (explicit setter wins over env).

**Definition of Done:** No unauthenticated mutation is possible on **any** mutating route (including `/snapshot/create`); the daemon cannot silently expose itself publicly; the open IPFS proxy is closed; the REPL client cannot be silently redirected or curl-flag-injected. Gates pass.

**Commit Message:** `[stage-18] feat: local auth token for ALL mutating endpoints + refuse public bind + fix REPL client redirect/injection`

**Report Requirements:** Document the token format, storage location/permissions, and the exact endpoint auth matrix — the matrix MUST list `/snapshot/create`.

---
