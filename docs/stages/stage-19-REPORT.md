# Stage 19: G1.2 Live End-to-End Substitute Verification

## Status
**Completed**

## Objective
Demonstrate that the Hub (`minius-02`) and Consumer (`z5-02`) can use GIPS to serve and fetch one substitute end-to-end, proving the data plane works completely on Oracle.

## Findings & Discoveries

1. **`gips publish` vs `snapshot create`**: We discovered that `gips publish` creates a "Feed" (a signed list of updates) which the background mirror loop in `gipsd` expects, whereas `snapshot create` makes a Fat Manifest for offline imports. The background loop (`sync_feed`) crashes if it encounters a Fat Manifest CID.
2. **Key Signatures Configuration**: `gips publish` requires `[trust.signing]` to sign the feed JSON itself. Furthermore, it silently fails with an Internal Server Error if `narinfo_private_key` isn't provided.
3. **Narinfo Signatures on the Consumer**: `gipsd` on the Consumer acts as a local substitute server (`http://127.0.0.1:8080`). It generates `.narinfo` files dynamically from its SQLite metadata cache (`StoredNarinfo`). To appease `guix substitute`, the Consumer's `gipsd` MUST be configured with a local `[guix_signing]` key, and that key's public half MUST be authorized via `guix archive --authorize`. It does not serve the Hub's signature; it strips it and re-signs the dynamically generated `narinfo` locally.
4. **Guix Version Derivation Drifts**: A naive `guix build hello` attempts to build from source on the Consumer because the Hub and Consumer are on different Guix commits (Hub on `df2d121`, Consumer on `9f08b3d`), resulting in different derivation hashes.
5. **Testing Substitute Fetch with Fixed-Output Derivations**: To sidestep the Guix commit mismatch, we created a static file, hashed it flat, and used a `url-fetch` fixed-output derivation (FOD) with the exact same name and SHA256 hash. Fixed-output derivations guarantee hash equivalence across Guix revisions.

## Verification Run Commands

**On Hub (`minius-02`):**
```bash
# 1. Create a static test file and calculate its Guix store hash
echo "gips-is-awesome" > /tmp/gips.txt
guix download file:///tmp/gips.txt
# Output: /gnu/store/wbjqpcsj9729lvk9nkx4mr2vb7pnkk2f-gips.txt (hash: 0cs8m1...)

# 2. Publish the single file as a complete tree to generate a feed
gips publish-tree /gnu/store/wbjqpcsj9729lvk9nkx4mr2vb7pnkk2f-gips.txt --gns-name cluster.gips
# Output Feed CID: QmQneD6dwGtZYEoEPAGPZpmRqPaShJMCg9QW6SzCbFuaiE
```

**On Consumer (`z5-02`):**
```bash
# 1. Bypass broken GNS DHT and point the cluster record directly to the Hub's Feed CID
gnunet-namestore -z me -a -n cluster -t TXT -V QmQneD6dwGtZYEoEPAGPZpmRqPaShJMCg9QW6SzCbFuaiE -e never

# 2. Setup local substitute signatures so Guix trusts the Consumer's gipsd facade
gips key generate-guix
# Added [guix_signing] config to gipsd.toml and restarted gipsd
gips key export-guix --path ~/.config/gips/signing-key.sec | sudo guix archive --authorize

# 3. Trigger a manual sync
gips subscribe cluster.me

# 4. Construct the equivalent Fixed-Output Derivation to fetch it
cat << 'SCHEME' > /tmp/test-fod.scm
(use-modules (guix packages) (guix download))
(origin
  (method url-fetch)
  (uri "http://127.0.0.1:9999/doesnt-exist.txt")
  (file-name "gips.txt")
  (sha256 (base32 "0cs8m1rwiy93yk6v3ka73qcl5m2prwq1vyh5d9l2yr950d89g2g2")))
SCHEME

# 5. Fetch the substitute!
guix build -f /tmp/test-fod.scm --substitute-urls="http://127.0.0.1:8080"
```

## Result Output
```
substitute: substitute: looking for substitutes on 'http://127.0.0.1:8080'...   0.0%substitute: looking for substitutes on 'http://127.0.0.1:8080'... 100.0%
The following file will be downloaded:
  /gnu/store/wbjqpcsj9729lvk9nkx4mr2vb7pnkk2f-gips.txt
substituting /gnu/store/wbjqpcsj9729lvk9nkx4mr2vb7pnkk2f-gips.txt...
downloading from http://127.0.0.1:8080/nar/QmaALPi5WbxhexSXrdGCLShjDLGhUyKbXcePGn91S5bEMq ...
..
/gnu/store/wbjqpcsj9729lvk9nkx4mr2vb7pnkk2f-gips.txt
```

The Consumer successfully fetched and unpacked the NAR directly into its Guix store using the `gipsd` facade, confirming the end-to-end data plane works live.
