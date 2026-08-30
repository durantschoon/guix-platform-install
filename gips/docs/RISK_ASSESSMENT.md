# GIPS Risk Assessment for Early Adopters

<!-- markdownlint-disable MD013 -->

**Document Version:** 1.1 (Security Roadmap Stages 13–21 shipped; updated 2026-08-18 for the Guix-native signing work of stages 29–30)
**Target Audience:** Early Adopters & System Operators

This document outlines the residual risks for early adopters operating the Guix IPFS Peer-to-Peer Substitute (GIPS) network, **with the security roadmap (Stages 13–21) shipped**. While the hardened design provides strong content integrity and fail-closed trust, GIPS operates in a decentralized, adversarial environment where certain trade-offs are intentional.

## 1. What You Can Trust (The Guarantees)

With the security roadmap implemented, GIPS guarantees:

- **Content Integrity:** A package downloaded via GIPS mathematically matches the `NarHash` signed by the publisher.
- **Fail-Closed Authorization:** Your node will strictly reject any substitute (even from a known IPFS peer) unless it is explicitly signed by a publisher you have authorized in your configuration.
- **Local Isolation:** The daemon will not expose mutating endpoints to the public internet without explicit opt-in, and requires a local cryptographic auth token to publish or pin packages.

## 2. Residual Risks (What You Must Accept)

As an early user, you must understand and accept the following risks:

### A. Privacy Leakage (High Risk)

GIPS is a public, peer-to-peer network.

- **Fetching:** When your node queries IPFS or the gossip network for a substitute, you are broadcasting your interest in that specific software package.
- **Publishing:** When you publish a package, your IP address (via your IPFS node) and the contents of your Guix store are publicly associated with your GNS identity.
- **Mitigation:** Do not use GIPS to distribute or fetch proprietary, sensitive, or legally encumbered software unless you are comfortable with that metadata becoming public.

### B. Lack of Key Revocation (Medium Risk)

GIPS does not currently have a dynamic key revocation or expiration mechanism (the remaining design lives in `docs/stages/completed/stage-22-SKETCH-expanded-into-29-30.md`).

- **The Risk:** If your publisher signing key is stolen, the attacker can sign malicious packages under your identity indefinitely.
- **Mitigation:** You must manually distribute out-of-band notices to your subscribers to remove your compromised key from their `trusted_publishers` configuration. Guard your signing key (`chmod 0600`) as you would a high-value PGP or SSH key.

### C. GNS Compromise (Medium Risk)

GIPS roots its trust in the GNU Name System (GNS).

- **The Risk:** If your local `gnunet-gns` resolver is compromised, or if you accidentally configure a malicious GNS zone as a trust root, an attacker could spoof a trusted publisher's identity.
- **Mitigation:** Maintain strict operational security over your GNUnet installation. Only subscribe to GNS names published by operators you independently verify out-of-band.

### D. Availability & Griefing Attacks (Low to Medium Risk)

While attackers cannot *forge* packages (due to signatures), they can attempt to disrupt the network.

- **The Risk:** Malicious nodes can flood the IPFS DHT or pubsub topics with garbage data. While your node will gracefully reject this garbage (thanks to resource limits and signature checks), handling the flood may consume excess bandwidth and CPU, potentially degrading your substitute download speeds.
- **Mitigation:** Resource bounds are in place, but you may need to manually block abusive IPFS peers at the firewall level if targeted by a determined volumetric attack.

### E. Manual Key Ceremony (Operational Friction)

GIPS can now sign served narinfos in stock-Guix format: `gips key generate-guix` produces a `guix publish`-style key, and after a one-time `guix archive --authorize` an unmodified `guix-daemon` verifies GIPS substitutes natively (the original "Phased Crypto" gap from Stage 22 was closed by stages 29–30).

- **The Risk:** Everything *around* the key is still manual. The public key is copied and authorized by hand on every consumer machine — there is no key distribution over GNS, no rotation, and no revocation (see B). A mistake in that ceremony (authorizing the wrong key, or forgetting a machine) either silently rejects your substitutes (fall back to source builds) or trusts a key you did not intend.

## Conclusion

For an early adopter, GIPS is **safe for integrity** but **unsafe for privacy**. If you are building standard open-source packages and want a resilient, decentralized alternative to central build farms, GIPS is ready. If you require anonymity or are distributing sensitive software, do not use this system.
