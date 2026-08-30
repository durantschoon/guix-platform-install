# Stage 23 (DEFERRED / DESIGN-ONLY) — Sybil resistance via federated, accountable membership

**Motivation:** Signatures and NarHash (Stages 14–16) stop *forged/tampered content*, but they do nothing about *cheap identity* — an adversary can mint many valid publishers to flood, spam, or grief the network. This stage designs an **optional** identity-cost + accountability layer without reintroducing a central chokepoint (which would negate GIPS's censorship-resistance premise). It is design-only: the output is a written spec + a decision on whether/how to implement, not code. *(Note: For the "Personal Multi-Machine Sync" use case, Sybil resistance is entirely irrelevant since you operate as a trusted "Group of 1" and never subscribe to untrusted third-party GNS identities).*

**Design principle — separate the two questions:**

- *Cost of identity* (Sybil resistance) ← membership fee / slashable bond / invitation delegation.
- *Grounds for removal* (integrity) ← **objective, cryptographically-provable fraud proofs**, gossiped and independently verifiable (a signed narinfo whose delivered bytes don't match its signed `NarHash`; equivocation = two conflicting signed feeds at one version). Enforcement must ride on evidence, never on subjective accusation, or the mechanism becomes a censorship weapon.

**The model to specify (federated):**

1. **Local accountability, global amplification.** Small groups vouch for their own members (who they actually know); larger groups vouch for groups. A member's acceptance by a distant peer is transitive through this graph — a web-of-trust / attenuable-capability (macaroon/UCAN/GNUnet-style) delegation chain rooted in signed GNS identities, extending `docs/federation.md`.
2. **The larger group is a shared-defense service, not a gatekeeper.** For a small fee, a sub-group gains: faster revocation/fraud-proof propagation, access to a shared slashable-bond / insurance pool, and a broader trust anchor so its members are accepted by more peers. The fee funds *infrastructure*, not a ban lever.
3. **Bounded, decaying vouching stake.** Inviting/vouching risks a small, decaying amount of the voucher's reputation or a refundable bond — slashed only on a *proven* fraud proof against the vouchee, and never the voucher's whole standing. Repeated bad vouches compound. ("If you vouch for a bad actor your account freezes too," made survivable and non-chilling.)
4. **Optional economic Sybil-cost as a slashable bond, not a pure subscription.** A refundable deposit that is slashed on proven misbehavior gives identity-cost without funding a central banning operator. If a paid-membership operator is desired, it runs as *one group among many*, never the single root.

**Non-negotiable properties (what keeps it censorship-resistant):**

- **No single root.** Multiple overlapping federations must coexist; a node may belong to several larger groups.
- **Cheap exit, no orphaning.** Leaving a group is low-cost and does not make your already-published, still-verifiable content unreachable.
- **No collective capital punishment.** One bad member cannot destroy an honest group; penalties are bounded and evidence-gated.
- **Evidence over fiat.** Every revocation should carry a portable, independently-verifiable fraud proof. Fraud proofs must be completely self-contained and objective, explicitly stripping any client-identifying metadata (IPs, headers) to protect requester privacy.

**Open questions to resolve in the spec:** payment rail vs. bond escrow (and the legal/custody/KYC/AML surface either introduces); how membership tokens are represented and rotated over GNS; how fraud proofs are gossiped and how nodes weight group-level vs. direct trust; adjudication for misbehavior that is *not* cryptographically provable (if any is admitted at all); anti-collusion for a corrupt larger group falsely accusing a sub-group.

**Allowed Files Whitelist (design-only):**

- `docs/federation.md` (extend with the federated-membership model)
- `docs/trust-economics.md` (**already exists** — extend it, do not create anew)
- `SECURITY.md` (link Sybil-resistance limitation → this design)
- `docs/TODO.md` (add as a future milestone)

**Definition of Done:** A written design (`docs/trust-economics.md`) that specifies the model above, satisfies the non-negotiable properties, and either proposes a concrete implementable subset or explicitly records why it stays deferred. No production code in this stage.

**Commit Message:** `[stage-23] docs: design federated accountable-membership / Sybil-resistance layer`

**Report Requirements:** Summarize the recommended concrete subset (if any) to implement first and its dependencies on Stages 14–16.

**Status:** Deferred, design-only. Depends conceptually on Stage 16 (fraud proofs require real NarHash) and Stage 18 (identity/token plumbing).

---
