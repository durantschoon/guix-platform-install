# Stage 31 — Real `gips snapshot create`: manifest → closure → published snapshot; working `just sync-push`

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

The personal-sync quickstart's documented push path is broken end to end,
and the fallback script has an authentication bug:

- `gips snapshot create <manifest>` bails: `gips/src/main.rs`,
  `SnapshotCommands::Create` → `anyhow::bail!("Snapshot creation via CLI is
  not fully implemented yet. Please use scripts/create_snapshot.scm
  instead.")`. The `manifest` argument is ignored.
- `just sync-push <gns-name>` (justfile) calls `just snapshot-create
  sync-manifest.scm`, which runs that bailing command; the `gns_name`
  argument is silently dropped (`# NOTE: GNS publishing of the snapshot is
  stubbed in Stage 11`).
- `scripts/create_snapshot.scm` step 2 curls `POST /snapshot/create` with
  **no auth token** (`curl -s -f -X POST http://127.0.0.1:8080/snapshot/create …`,
  no `Authorization` header anywhere in the script — grep it). Since stage
  18 that route sits behind `require_local_token` in the `mutating` router
  (`components/gips-http/src/lib.rs`, `build_router`), so this step returns
  401 and the documented `just snapshot` flow dies at manifest creation.
  (Step 1's `gips publish` calls are fine — the CLI loads the token
  itself via `load_auth_token`.)
- `docs/personal-sync-quickstart.md` presents `just sync-push` as the
  workflow, with only a soft "might be stubbed" caveat; `docs/TODO.md`
  "Still open" records the breakage.

What already works (do NOT rebuild it): `POST /snapshot/create`
(`fn create_snapshot`, `components/gips-http/src/lib.rs` ≈`:2205`) takes
`{"store_paths": [...]}`, validates each path, refuses paths with no
DB-backed artifact or no recorded NarHash, signs the manifest with the feed
key when `[trust].signing` is configured, pins the wrapper to IPFS, and
returns `{"snapshot_cid": ...}`. The CLI's job is closure computation and
orchestration, not manifest building.

> **Anchor by `fn` name + quoted code, not line number** — the file drifts
> every stage.

## The Change

1. **Implement `gips snapshot create <manifest.scm> [--gns-name <name>]`**
   (`gips/src/main.rs`):
   1. Compute the closure of the manifest by shelling out to Guix:
      `guix build -m <manifest>` to obtain the output store paths, then
      `guix gc --requisites <outputs…>` to expand to the full closure.
      **ASSUMPTION TO RECORD, NOT VERIFY HERE:** this machine has no Guix;
      the exact flags cannot be exercised locally. Encode both invocations
      behind a **test seam** (the house pattern: a plain function parameter
      — e.g. a `command_runner: impl Fn(...)` or equivalent — that
      production always passes the real subprocess runner to, never a
      config knob). Unit tests feed canned stdout through the seam; the
      real commands get validated during the Linux-box acceptance run.
      State the final commands prominently in your report.
   2. Treat subprocess output as a boundary (stage 19 rules): apply a
      timeout to each subprocess; validate every returned line as a store
      path (reuse/replicate the `is_valid_store_path` rules — absolute,
      under `/gnu/store/`, no `..`, no embedded newline); reject the whole
      run on any garbage line rather than skipping it. Sort and dedupe the
      final path set.
   3. Publish each closure path through the daemon: `POST /publish` with
      the auth token, reusing the existing CLI client code paths. Then
      `POST /snapshot/create` with `{"store_paths": [...]}` (plus
      `gns_name` when given — item 2) and the auth token. Print the
      returned `snapshot_cid` (and the GNS name, when published) to
      stdout as the final output.
   4. Failure semantics — fail fast, never partial-silent: any failed
      subprocess, validation, or HTTP step aborts with a non-zero exit and
      a message naming the failed step. Paths already published before an
      abort stay published (the daemon's `/publish` dedupe makes reruns
      idempotent); say so in the error message so a rerun is the obvious
      remedy. Do not attempt rollback.
2. **Optional GNS publication, daemon-side** (`components/gips-http/src/lib.rs`):
   add an optional `gns_name: Option<String>` field to
   `CreateSnapshotRequest` (`#[serde(default)]` — existing callers must be
   unaffected). When present, after the manifest is pinned, publish the
   snapshot CID to that name via the existing `GnsClient` on `AppState`
   (which already carries stage 19's name validation, `--` separators,
   and timeouts). GNS failure → 502, matching `/publish`'s contract; the
   error must make clear the snapshot itself was created and pinned. The
   CLI stays a thin HTTP client — no `gips-gns` dependency in `gips`.
3. **Fix the script's missing token** (`scripts/create_snapshot.scm`): send
   `Authorization: Bearer <token>` on the `/snapshot/create` curl. Read
   the token from `GIPS_AUTH_TOKEN_FILE` if set, else the same default
   path the Scheme API client uses (see `scheme/gips/api.scm` and
   `scheme/README.md`: `<config-dir>/gips/auth-token`). A missing token
   file is a hard error naming the path — not a silent unauthenticated
   attempt. (Keep the script's own `gnunet-gns` step as is; it predates
   item 2 and still works for the script flow.)
4. **Wire the just recipes** (`justfile`): `sync-push gns_name:` becomes a
   call of `gips snapshot create sync-manifest.scm --gns-name {{gns_name}}`
   (via `cargo run -p gips --`, matching sibling recipes); delete the
   "stubbed in Stage 11" note. Update `snapshot-create` so it still works
   without a GNS name.
5. **Docs to update** (only the lines these changes make true):
   - `docs/personal-sync-quickstart.md`: drop the "(… might be stubbed …)"
     note under `just sync-push`; add one sentence that the push side
     requires Guix (`guix build`/`guix gc`) on the builder machine.
   - `docs/offline-snapshots.md`: replace the "`gips snapshot create` …
     currently unimplemented" note with the real usage; keep the
     list/import notes (still unimplemented).
   - `docs/TODO.md`: tick the `just sync-push` line in "Still open" with a
     stage-31 citation.
   - `README.md`: the one sentence describing snapshot CLI commands.

## Non-goals (do not touch)

- `gips snapshot list` / `import` stay loud unimplemented bails.
- No Scheme REPL binding for `snapshot` (recorded debt in `docs/TODO.md`
  "Still open"; do not extend `scheme/gips/api.scm`).
- No `gips key generate-feed` (a later stage).
- No closure computation in the daemon; no changes to the snapshot
  manifest format, signing, or serving paths.

## Allowed Files Whitelist

- `gips/src/main.rs`
- `components/gips-http/src/lib.rs` (`CreateSnapshotRequest` + `fn
  create_snapshot` + its `#[cfg(test)]` coverage only)
- `scripts/create_snapshot.scm`
- `justfile` (`sync-push` / `snapshot-create` recipes only)
- `docs/personal-sync-quickstart.md`, `docs/offline-snapshots.md`,
  `docs/TODO.md`, `README.md` (listed lines only)
- Member `Cargo.toml`/`Cargo.lock` for whitelisted dependencies and
  dev-deps of tests (standing retro allowance)

## Enumerated Tests

1. **Closure parsing (seam):** canned `guix build` + `guix gc --requisites`
   stdout produces a sorted, deduped store-path set; a line that is not a
   valid store path (relative, outside `/gnu/store/`, embedded newline)
   fails the whole run before any HTTP request is made.
2. **Subprocess failure (seam):** a non-zero guix exit aborts with a
   non-zero CLI exit and a message naming the failed command; nothing is
   published. A hanging subprocess (seam-injected) hits the timeout and
   aborts — no indefinite hang.
3. **Happy path against a stub daemon** (in-process axum/hyper stub bound
   to a loopback port, as dev-dependency): the CLI publishes every closure
   path, then posts `/snapshot/create`, and prints the stub's
   `snapshot_cid`. Assert the `Authorization` header is present on every
   mutating request.
4. **Missing token file:** the CLI aborts with an error naming the token
   path before any network request.
5. **Daemon `gns_name` accepted:** `POST /snapshot/create` with `gns_name`
   invokes GNS publication (existing gips-http test-double pattern) and
   succeeds; a GNS failure returns 502; **without** `gns_name` behavior is
   byte-identical to today (regression: the existing snapshot tests still
   pass unmodified).
6. **Script token line:** `scripts/create_snapshot.scm` contains the
   Authorization header wiring and fails hard with a path-naming message
   when the token file is absent (assert by running the script with
   `GIPS_AUTH_TOKEN_FILE` pointed at a nonexistent file — no daemon
   needed for that exit path).

## Definition of Done

- All enumerated tests implemented and green.
- Gates, in the stages-README order: adversarial diff audit first, then
  `cargo check`, `just fmt-check`, `just test`, `just audit` (known
  vacuous — note it, don't fix it), `just lint` (diff the full sorted
  ` error ` list against the base commit; zero new lines outside the new
  prompt file itself), `just scheme-test` **green** (stage-30 baseline).
- `just sync-push` and `just snapshot-create` invoke the new CLI path
  (verified by reading the recipes; execution requires Guix and is
  deferred to the Linux acceptance run).
- No behavior change for `/snapshot/create` callers that omit `gns_name`.

## Commit Message

`[stage-31] feat: real gips snapshot create (manifest→closure→publish), daemon-side snapshot GNS publish, sync-push wired, script auth fix`

## Report Requirements

- The exact guix invocations encoded behind the seam, flagged as
  **unverified on real Guix** and listed as the first item for the
  Linux-box acceptance checklist.
- The failure-semantics table: each step, what aborts it, what state
  remains, and why rerun is safe.
- Confirmation of which requests now carry the auth token (CLI and
  script), and the header format used.
- Any deviation from the whitelist, disclosed per house rules.

## Blocked Protocol

If ground truth contradicts this prompt — the guix flags are wrong in a
way the seam cannot absorb, `CreateSnapshotRequest` cannot grow a field
compatibly, the token default path differs from `scheme/README.md`'s
claim — STOP. Commit nothing beyond your branch, write a report stating
the evidence (command output, file+line), and end the run BLOCKED. A
blocked run that returns evidence is a success mode; do not improvise
around the prompt.
