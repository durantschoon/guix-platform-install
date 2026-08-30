# Stage Pipeline: Verification Gates & Practices

This directory contains numbered stages (`stage-NN-PROMPT.md`) for the Antigravity Stage Pipeline.

## Verification Gates (ORDER IS CRITICAL)

Before any Executor's branch can be merged, the Coordinator MUST independently run and verify the following gates in this exact order:

1. **Security Review Gate (Human/Adversarial Diff Audit)**:
   - Run `git show --stat` and manually review the diff.
   - Check `justfile`, `build.rs`, `deny.toml`, and any new `scheme/` or `.tla` files FIRST.
   - Refer to `SECURITY.md` to ensure the threat model and safety invariants are respected.
   - Do this BEFORE running any code from the branch to avoid executing malicious code smuggled by a compromised executor.
2. **Build & Type Check**: `cargo check` (Run in a disposable/sandboxed environment if unreviewed!)
3. **Formatting**: `just fmt-check`
4. **Tests**: `just test` (Mandatory for all new code)
5. **Dependency Audit**: `just audit` (Enforces cargo-deny bans/licenses)
6. **Linting**: `just lint`
7. **Docs**: Ensure no `TODO.md` or `invariant.md` rules are broken.

## Coordinator Practices

- Agents must claim stages by pushing to `claims/stage-NN.json`.
- **CRITICAL**: Always run `git pull --rebase rad main` immediately before any `git push rad main` to prevent divergent histories on the decentralized network.
- Maximum claim timeout is 2 hours.
- The executor works on an isolated branch.
- The coordinator performs adversarial review on the completed branch following the strict gate order.
- If gates pass, coordinator merges to main and removes the claim.

## Retro (stages 16–20, recorded 2026-08-17)

Systemic patterns from the last five stage reports; future prompts and reviews should
apply these:

- **Known baseline gate failures.** On this environment, `just lint` fails with
  pre-existing markdown errors. Never quote a total: diff the full sorted
  ` error ` list against the base commit and require zero *new* lines.
  `just audit` is vacuous (`cargo-deny`/`cargo-audit` not installed).
  Reviews compare failure output against the base commit instead of
  requiring green; fixing the markdown baseline and installing the audit
  tooling is open hygiene work.
- **`just scheme-test` is expected GREEN as of stage 30.** It is no longer a
  known-broken gate. `guile-gcrypt` is installed here from the Codeberg
  source build (`https://codeberg.org/guile-gcrypt/guile-gcrypt.git`,
  `autoreconf -vif && ./configure --prefix=/opt/homebrew && make install`;
  the notabug upstream is gone), which puts the modules in
  `/opt/homebrew/share/guile/site/3.0/gcrypt/` for guile 3.0.10. Caveat: that
  path is version-keyed, so a `brew upgrade` of `guile`/`guile-next` past
  3.0.10 takes the gate red again. The fix is to rebuild guile-gcrypt against
  the new guile — never to weaken `test_sign.scm`, which drives the committed
  signing helpers in `components/gips-trust/guile/` end to end.
- **Whitelist boilerplate.** Every stage legitimately needed `Cargo.lock`, member
  `Cargo.toml` dependency edits, and `[dev-dependencies]` for new tests, and each
  executor had to flag them as deviations. Stage prompts should include
  "member `Cargo.toml`/`Cargo.lock` for whitelisted dependencies and dev-deps of
  tests" in the allow-list by default.
- **Out-of-order stage numbering.** Stages 17/19/21/23 merged before 16/18/20, so
  prompt references like "Stage 17 will…" can describe already-merged work. The
  coordinator must brief executors on what actually landed since the prompt was
  written, and executors must verify claimed-missing behavior before implementing.
- **Executors must not run `git push`** (no credentials); the coordinator pushes.
  Launch instructions say this, reports confirm it — keep it that way.
- **REPORT files are not committed**; the executor's final message is the report,
  and prompts of completed stages move to `completed/`.

## Retro (stages 25–29, recorded 2026-08-18)

- **Ground truth about external systems must be evidence, not memory.** Stage
  29 take 1 was authored with a wrong cryptographic assumption (EdDSA where
  Guix uses libgcrypt ECDSA/rfc6979) and the executor correctly BLOCKED,
  proving the real format from a live narinfo and upstream source. Practices:
  a prompt asserting an external format cites its evidence or marks the
  assumption "verify before building on it"; a blocked run that returns
  evidence is a *success mode* — budget for takes.
- **Stop quoting absolute lint counts.** The markdown-error total drifts every
  time a prompt is authored or archived (three different "baselines" were
  quoted across five stages). The rule is and was: diff the full sorted
  ` error ` list against the base commit; briefings should not name a number.
- **`just audit` has been vacuous for the entire pipeline** (`cargo-deny`/
  `cargo-audit` not installed; the recipe `|| true`s). Either install the
  tools or remove the gate — carrying a gate that checks nothing misleads
  every report that says "audit ran". Open hygiene item, deliberately not
  buried in a stage.
- **Sync the `rad` remote before merging executor branches.** `git pull
  --rebase rad main` linearizes history and drops union-merge commits
  (happened twice; trees verified identical both times). Pull first, merge
  after, and tree-check before force-deleting a rewritten branch.
- **Parameter test-seams are the house pattern** for reaching bounded/error
  exits (stage 25's `store_root`, stage 28's `max_nar_bytes`): a plain
  function parameter production always passes a constant to, never a config
  knob or `#[cfg(test)]` global.

### Addendum from stage 24 (recorded before authoring stage 25)

- **Render what you build.** The stage 24 executor caught four real UI bugs
  only by driving the dashboard in a headless browser. Stages that produce
  a UI must include "run it and look at it" in their Definition of Done.
- **Never fabricate data to satisfy an aesthetic requirement.** The prompt
  asked for a "live node-graph of the IPFS swarm"; the executor correctly
  substituted a diagram backed by measured data. Prompts should ask only
  for visualizations of data the system actually has.
- **A whitelist may anticipate dependencies that go unused** (stage 24
  hand-rolled metrics instead of adding crates); that is a fine outcome,
  not a deviation to punish.
- **Coordinator merge hygiene:** run merges from the main checkout, never
  from inside an executor worktree, and never pipe a `git merge` in a way
  that masks its exit status. Both failure modes occurred once; both are
  now checklist items.

## Retro (stages 36–44, recorded 2026-08-24)

- **Non-interactive Git signing during automated merges & rebases.** When the
  coordinator manages merges, claims, and rebase operations, interactive GPG
  pinentry prompts can stall or time out in non-interactive agent sessions.
  Automated coordinator operations should explicitly configure
  `--no-gpg-sign` / `-c commit.gpgsign=false` to ensure clean, automated merges
  and uninterrupted linear rebase synchronization with `rad main`.
- **Hermetic multi-node simulation harnesses over live daemon requirements.**
  Full end-to-end distributed scenarios (vouch chain propagation, transitive
  reputation decay, objective fraud proof gossip, and air-gapped snapshot
  export/import) can be verified deterministically in pure Rust on any host
  (including macOS) by binding in-process `gipsd` instances to ephemeral loopback
  ports (`127.0.0.1:0`) backed by mock IPFS/GNS doubles, avoiding fragile
  external service dependencies.
- **Strict monotonic capability attenuation.** Monotonic attenuation (depth
  strictly decreasing, stake non-increasing, store-path prefixes narrowing, and
  non-extending expiry) in delegation tokens (`VouchToken`) prevents capability
  widening and privilege escalation along multi-hop delegation graphs.
- **Objective mathematical fraud proofs.** Grounding revocation on
  cryptographically provable facts (signed narinfo vs. recomputed SHA-256
  NarHash, or signed conflicting feed CIDs) allows autonomous peer blacklisting
  without introducing central gatekeepers or subjective voting committees.
- **Scheme REPL parity (Invariant 1) across all command families.** Full
  parity between `gips` CLI and Guile Scheme `(gips api)` is maintained for all
  subcommands (publish, subscribe, link-channel, pin, unpin, reindex, search,
  key, snapshot, vouch, fraud-proof, trust, gossip, acl) with secure bearer token
  passing via private `0600` curl config files.
