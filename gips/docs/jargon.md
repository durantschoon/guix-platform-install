# Jargon and concepts

<!-- markdownlint-disable MD013 -->

A short glossary for anyone new to GIPS, Guix, or the terms we use. See also [README](../README.md) and [docs/architecture.md](architecture.md).

---

## GIPS

**GIPS** stands for **GNS + IPFS Package Substitutes**. It’s a system that lets you publish and fetch Guix package artifacts over IPFS instead of a central HTTP server, using GNS for stable names. The repo contains the **gipsd** daemon and **gips** CLI.

---

## Guix and the store

- **Guix store** – The directory tree (usually `/gnu/store/`) where Guix keeps built packages and other artifacts. Each path is content-addressed: the hash in the path reflects the contents.

- **Store path** – A path like `/gnu/store/abc123...-hello-2.12`. It uniquely identifies a build output. GIPS only accepts store paths under `/gnu/store/` when you publish.

- **Substitute** – A pre-built binary (or other artifact) that a user can download instead of building from source. A “substitute server” is a service that serves these binaries; GIPS is a substitute server that uses IPFS and GNS instead of plain HTTP.

---

## Nar and narinfo

- **Nar** – **N**ix **Ar**chive. A simple archive format used by Nix and Guix to ship store paths. When you “fetch a nar,” you’re downloading the serialized contents of a store path (e.g. a built package). In GIPS, the nar bytes are stored in IPFS; the daemon fetches them via the IPFS API and streams them to the client.

- **Narinfo** – Metadata that describes one substitute: which store path it is, where to get the nar (e.g. URL or, in GIPS, an IPFS CID), optional signature, etc. Guix requests a narinfo first, then uses it to fetch the nar. In GIPS we store narinfo as JSON in the database and serve it from the `/narinfo` endpoint.

---

## IPFS

- **IPFS** – **I**nter**P**lanetary **F**ile **S**ystem. A peer-to-peer content-addressed storage network. GIPS uses the IPFS HTTP API to add files (e.g. a nar) and to retrieve them by content hash.

- **CID** – **C**ontent **ID**entifier. The hash that IPFS assigns to a piece of content (e.g. `Qm...`). After publishing a store path, GIPS records the CID so it can later serve the nar via `/nar` by asking IPFS for that CID.

- **Pin** – Telling IPFS to keep a CID stored so it isn’t garbage-collected. GIPS uses `pin=true` when adding content so published substitutes remain available.

---

## GNS

- **GNS** – **G**NU **N**ame **S**ystem. A decentralized naming system (like DNS, but censorship-resistant and privacy-preserving). In GIPS, a publisher can associate a human-readable GNS name (e.g. `example.gnu`) with their published data so clients can discover substitutes by name instead of by raw CID or URL.

---

## GIPS components

- **gipsd** – The GIPS daemon. It runs an HTTP server, talks to IPFS and (optionally) GNS, and keeps a local SQLite database of store path → CID → narinfo. Clients (including the **gips** CLI and Guix) talk to it over HTTP.

- **gips** – The GIPS command-line client. It can ask **gipsd** to publish a store path, check status, link channels, pin/unpin CIDs, trigger a reindex, rotate auth tokens, view metrics, and manage signing keys (`gips key generate-guix`/`export-guix`, `generate-feed`/`export-feed`, `advertise-gns`/`fetch-gns`). It does not talk to IPFS or GNS directly.

- **Channel** – In Guix, a channel is a source of package definitions (e.g. the main `guix` channel). “Linking” a channel to a GNS name in GIPS (planned) would let that name point at the channel’s substitute feed.

---

## Trust and signing

- **Keyring** – In Guix, the set of public keys that the user trusts for substitute signatures. GIPS supports the same model: you configure trusted publishers (by GNS name and public key) in `[trust]`, and the daemon verifies feed signatures fail-closed — an empty trust list accepts nothing from the network.

- **Narinfo signing** – Signing narinfo metadata with a private key so clients can verify that a substitute really came from a trusted publisher. GIPS signs its own feeds with an Ed25519 key and, when `[guix_signing]` is configured, additionally signs served narinfos in stock-Guix format so an unmodified `guix` can verify them against its ACL (`guix archive --authorize`).
