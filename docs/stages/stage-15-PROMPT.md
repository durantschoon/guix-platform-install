# Stage 15 — Transitive Web-of-Trust Evaluation and Cryptographic Fraud Proof Gossip

## Motivation (measured)

When scaling beyond a personal cluster to federated peer swarms, substitute authenticity cannot rely exclusively on pre-shared static keys. GIPS incorporates:
1. Capability delegation vouches (`VouchToken`) allowing transitive trust delegation with attenuation (depth, expiration, prefix constraints, stake scores).
2. Objective cryptographic fraud proofs (hash mismatch and equivocation proofs) that provably convict malicious signers.
3. Automated gossip propagation over IPFS PubSub and GNUnet CADET (`gips.vouch.v1`, `gips.fraud.v1`).

Stage 15 exposes and validates this trust fabric within the repository's Scheme APIs and post-install tooling, allowing Guix operators to inspect delegation chains, evaluate trust scores, and automatically propagate fraud proof revocations.

## The change

1. Integrate trust evaluation workflows into `(gips api)` (`gips-trust-evaluate`, `gips-vouch-mint`, `gips-vouch-verify`, `gips-fraud-proof-generate-*`, `gips-fraud-proof-submit`).
2. Add ACL auto-synchronization and fraud proof revocation hooks in `postinstall/recipes/add/gips.scm`.
3. Add offline simulation tests covering multi-hop capability delegation, trust decay, fraud proof generation, and automatic peer revocation.
4. Document the trust economics and fraud proof protocol in `docs/GUIDE_SEASONED_GUIX.md` and `gips/docs/trust-economics.md`.

## Ground rules

- Guile for all configuration helpers and Scheme APIs.
- ASCII-only terminal output.
- Fail-closed cryptographic verification: broken chains or forged signatures must fail immediately with non-zero exit codes.
- Zeroizing and mode `0600` protection for all in-memory and disk keys.

## Allowed files (whitelist)

```
gips/scheme/gips/api.scm
gips/scheme/gips/config.scm
postinstall/recipes/add/gips.scm
docs/GUIDE_SEASONED_GUIX.md
gips/docs/trust-economics.md
gips/docs/security-roadmap.md
docs/stages/stage-15-REPORT.md
```

## Tests (enumerated — all required)

1. `gips-vouch-mint` and `gips-vouch-verify` successfully validate multi-hop delegation chains with prefix attenuation.
2. `gips-fraud-proof-generate-hash-mismatch` generates valid verifiable fraud proof payloads against conflicting narinfo/nar pairs.
3. Submitting a verified fraud proof automatically severs downstream web-of-trust scoring to zero.
4. Gossip transport status (`gips-gossip-status`) accurately reports active peering topics and message propagation counts.
5. All 15 existing verdicts in `gips/test_api.scm` and all 4 verdicts in `gips/test_sign.scm` remain green.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; Failed: 0
make gips-test                            # exit 0
git diff --check                         # exit 0
```

## Commit message (exact, single line)

```
feat(gips): add web-of-trust evaluation and fraud proof gossip tooling
```

## Report requirements

Write `docs/stages/stage-15-REPORT.md` with:
- Summary of changes per file.
- Multi-hop vouch and fraud proof verification examples.
- Offline simulation results.
- Whitelist audit.
- Unverified claims section.

## Blocked protocol

If trust scoring cannot guarantee monotonic attenuation (e.g. child token stake exceeds parent stake or expiration is extended), stop and report `Blocked:`. Attenuation invariants must never be violated.
