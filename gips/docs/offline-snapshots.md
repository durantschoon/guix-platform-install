# Offline Snapshots & Swarm Distribution

Offline snapshots provide a native way to freeze an entire package environment and distribute it over IPFS for perfect reproducibility. This acts effectively like a torrent for an entire operating system or development environment.

## The Snapshot Manifest

A snapshot is represented by a **Snapshot Manifest**, a JSON document stored in IPFS. It lists Guix store paths, their narinfo metadata, and their corresponding IPFS CIDs. By sharing the CID of this manifest (or a GNS name resolving to it), you can distribute a complete, immutable environment.

## Key Benefits

1. **Perfect Reproducibility:** Every single user downloading the snapshot gets the exact same bytes for every package. There is zero risk of "it works on my machine" drift.
2. **Peer-to-Peer Swarming:** Because snapshots are served over IPFS, as soon as the first few people import the snapshot, they automatically start seeding it to the rest of the group. The more people who want that same group of packages, the faster and more resilient the downloads become, completely offloading the central publisher!
3. **Air-gapped Installs:** Once you import a snapshot, your local `gipsd` serves those substitutes to your local `guix-daemon` over HTTP without ever touching the broader internet, making it perfect for secure enclaves or offline trips.
4. **Reproducible Science:** For researchers, a Snapshot Manifest is a cryptographically verifiable artifact of the exact computational environment used for an experiment. By including the snapshot CID in a published paper, any peer reviewer or future scientist can instantly download and instantiate the exact same environment natively from the IPFS swarm, perfectly preventing bit-rot and "it works on my machine" irreproducibility.

## Usage

### 1. Create a Snapshot

First, gather the exact store paths you wish to include. Then, use the provided script to publish them and generate a snapshot manifest (this ensures the daemon handles signing and PINning correctly):

```bash
just snapshot <gns-name> <store-path> [<store-path> ...]
```

Or, to snapshot a whole declarative manifest rather than a hand-listed set of paths:

```bash
gips snapshot create my-manifest.scm [--gns-name <gns-name>]
```

That computes the manifest's closure with `guix build -m` and `guix gc --requisites` (so it needs Guix on this machine), publishes every path in the closure through `gipsd`, and asks the daemon for the snapshot manifest; with `--gns-name` the daemon also publishes the resulting CID under that name. It prints `snapshot_cid: <cid>` on stdout. Every step fails loudly: a subprocess that fails or prints anything that is not a store path aborts the run rather than producing a partial closure, and nothing is rolled back — rerunning the same command is safe.

### 2. List Local Snapshots

To view all snapshots recorded locally in SQLite on your node:

```bash
gips snapshot list
```

Or from Guile Scheme REPL:

```scheme
(use-modules (gips api))
(gips-snapshot-list)
```

### 3. Share and Import

Share the `snapshot_cid` or GNS name with your group. To import a snapshot from IPFS into your local `gipsd` node:

```bash
gips snapshot import <snapshot-cid>
```

Or from Guile Scheme REPL:

```scheme
(gips-snapshot-import "<snapshot-cid>")
```

This fetches the snapshot manifest from IPFS, validates store paths and NarHash integrity, pins the manifest and all constituent NAR artifact CIDs in IPFS, and registers substitute records in the local SQLite database.

Your local `gipsd` can now serve substitutes to `guix-daemon` at `http://127.0.0.1:8080` (or the configured `listen` address) immediately without external network dependencies.

### 4. Export for Physical / Air-Gapped Sneakernet

For completely air-gapped machines without IPFS swarm access, package a snapshot and all constituent NAR artifacts into a single POSIX `.tar` archive:

```bash
gips snapshot export <snapshot-cid> [-o output.tar]
```

Or from Guile Scheme REPL:

```scheme
(gips-snapshot-export "<snapshot-cid>" #:output-file "output.tar")
```

The exported tar archive contains `manifest.json` and `nar/<cid>` entries for every store path in the snapshot closure, suitable for USB transfer and archiving.

## Capabilities & GNS

Each snapshot acts as a **link**. You can bind a snapshot CID to a human-readable GNS name (e.g., `research-env-2026.gnu`). Sharing this name grants anyone the link to perfectly reproduce and mirror that specific snapshot without exposing the rest of your IPFS node's contents.
