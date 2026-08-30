# Stage 21 — SECURITY.md, threat model, honest docs, and safety invariants

**Motivation:** The explicit ask — trust *within stated limits, which we must state*. Today there is no `SECURITY.md`, no threat model, `docs/invariant.md` has zero safety invariants, `docs/TODO.md:38-41` falsely marks "Trust & signing" complete, `docs/architecture.md` predates stages 03–12, `docs/RISK_ASSESSMENT.md` cites Stage 14/19 mitigations as if already shipped, and the concurrency/permissions policy in `.agents/rules/git-permissions.md` classifies `git push` to a p2p remote as "reversible".

> **Two roadmap claims here are already stale — do NOT act on them blindly:** `.agents/` is **already git-tracked** (`.agents/rules/git-permissions.md` and `.agents/skills/stage-pipeline/SKILL.md` are committed), and `docs/trust-economics.md` **already exists**. Item 5 below is therefore *correct-and-reword*, not *track-from-scratch*.

**The Change:**

1. Add **`SECURITY.md`**: the threat model (adversaries: malicious publisher, hostile IPFS node/gateway, GNS zone compromise, local unprivileged process, network attacker), what GIPS *does* protect against after Stages 14–20, and — plainly — what it does **not** yet:
   - not a drop-in Guix keyring (phased crypto → Stage 22);
   - privacy leakage (publish/search/nar disclose your package set);
   - no revocation;
   - **no Sybil resistance** (integrity ≠ identity-cost → Stage 23);
   - security-through-unguessable-GNS-name is not a capability model;
   - IPFS pubsub is unauthenticated;
   - **store-path ownership is first-writer-wins** — `substitutes` has no `UNIQUE(store_path)` and `process_feed`'s dedupe (`SELECT 1 FROM substitutes WHERE store_path = ?`) is **not publisher-scoped**, so the first subscription to advertise a path owns it with no update path. State this limitation (and file a follow-up to add publisher-scoped rows/uniqueness);
   - **the pipeline itself is a trust boundary** — stage prompts, `.agents/rules/*`, and `justfile` arrive over the unauthenticated `rad` remote and are executed by tool-enabled agents; there is no commit-signature verification. Document the expected repo DID and the "audit-diff-before-running-gates" rule (Stage 13).
   Include how to report a vulnerability.
2. Add **safety invariants** to `docs/invariant.md`: e.g. "never serve a substitute whose NarHash is unverified", "empty trust list ⇒ accept nothing (both parsers)", "no unauthenticated mutation (including `/snapshot/create`)", "no fabricated integrity fields", "config and DB paths are never resolved relative to CWD", and "mirror updates must be strictly causally ordered via Merkle DAGs (TLA+ proven)".
3. **Correct `docs/TODO.md`:** un-tick the false "Trust & signing" completions (≈`:38-41`); reflect the real state and the new hardening milestone.
4. Update `docs/architecture.md` (routes — including `/snapshot/create` and the `/:file` catch-all, `AppState`, the `http→trust` edge, fail-closed default) and `docs/federation.md`/`docs/offline-snapshots.md` to remove overpromises ("signed narinfos", "capability", "censorship-resistant") or qualify them accurately. **Fix `docs/RISK_ASSESSMENT.md`** so it no longer presents Stage 14/19 mitigations as shipped when they are the very work being staged.
5. **Correct (not create) the `.agents/` policy files:** `.agents/rules/git-permissions.md` is already tracked — **reclassify** `git push`/`rebase`/`checkout` as non-trivial (publication/history-rewrite) in the p2p context; ensure the odd/even sharding rule lives in tracked docs so a fresh clone retains it. **Also address claim-protocol integrity:** `claimed_at` is self-attested/unsigned with no owner check on stale-claim removal (any node can backdate to park a stage, or declare another node's active claim stale and take it over). Document the weakness and the mitigation (signed claims / owner-only removal / authority clock) or explicitly record it as an accepted limitation.
6. **Align the consumer-facing docs and recipes with reality.** `just install <package>` (`justfile:72-74`) and `docs/user_guide.md:36-41` add GIPS as a Guix substitute source with **no mention** of `guix archive --authorize`, the ACL, or that narinfo signature verification is what stands between the user and arbitrary substituted binaries. Add the authorization step and an honest note that following the guide against an unmodified Guix will fail verification until Stage 22 (do not imply the workaround is disabling verification).

**Allowed Files Whitelist:**

- `SECURITY.md` (new)
- `docs/invariant.md`, `docs/TODO.md`, `docs/architecture.md`, `docs/federation.md`, `docs/offline-snapshots.md`, `docs/user_guide.md`, `docs/jargon.md`, `docs/RISK_ASSESSMENT.md`
- `README.md` (align claims with reality)
- `justfile` (add the `guix archive --authorize` step / honest comment on `just install`)
- `.agents/rules/git-permissions.md` (reword + claim-protocol note)
- `docs/stages/README.md` (reference SECURITY.md from the security gate)

**Enumerated Tests:**

1. `just lint` (markdownlint) passes on all changed docs.
2. A reviewer checklist: every "censorship-resistant"/"signed"/"capability"/"trusted" claim in the docs is either backed by shipped behavior or explicitly marked as a stated limitation.
3. No `docs/TODO.md` box is ticked for behavior that isn't implemented and tested; `docs/RISK_ASSESSMENT.md` cites no mitigation as shipped that is not.

**Definition of Done:** GIPS ships an accurate `SECURITY.md` + threat model, safety invariants are recorded, the pipeline's own trust boundary and store-path/claim limitations are stated, and no doc overpromises relative to the code. This is the "state the limits" deliverable.

**Commit Message:** `[stage-21] docs: SECURITY.md, threat model, safety invariants, honest claims`

**Report Requirements:** Provide the final list of "protects against" vs "does not yet protect against" bullets from SECURITY.md.

---
