# Stage 49 — Privacy-Preserving Substitute Queries & Bloom Filter Swarm Summaries

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

When a client queries a peer, gossip swarm, or remote mirror for a specific Guix store path hash (`<hash>.narinfo`), revealing the exact hash leaks which specific package versions, dependencies, or private developer environments the user is building.

Stage 49 introduces privacy-preserving substitute queries:

1. **$k$-Anonymity Hash Prefix Querying**: Clients can query peers by truncated hash prefixes (e.g., 4 to 8 characters), receiving candidate sets while keeping the exact requested item private within the $k$-anonymous bucket.
2. **Compact Bloom Filter Substitute Summaries**: Publishers and mirrors emit compact Bloom filter bitsets (`gips_trust::bloom`) of their indexed store paths, allowing clients to obliviously test substitute availability locally before initiating requests.

## The Change

1. **Bloom Filter Module (`components/gips-trust/src/bloom.rs`)**:
   - Implement `BloomFilter` with parameterized bit capacity, optimal hash count calculation, and serialization/deserialization.
   - Support `insert(&mut self, hash: &str)`, `contains(&self, hash: &str) -> bool`, and byte array export/import.
   - Unit tests verifying membership, non-membership, and false-positive bounds.

2. **Prefix Lookup Endpoint (`components/gips-http/src/lib.rs`) & Database Index (`components/gips-db`)**:
   - Add DB query `find_by_hash_prefix(prefix: &str, limit: usize) -> Result<Vec<SubstituteRow>>`.
   - Add HTTP endpoint `GET /substitute/prefix/:prefix` (public read-only) returning candidate substitute summaries matching the prefix.

3. **CLI & Scheme Parity (`gips/src/main.rs`, `scheme/gips/api.scm`, `test_api.scm`)**:
   - Add `gips search --prefix <hash-prefix>` support or `gips search-prefix <prefix>`.
   - Add Guile Scheme REPL procedure `(gips-search-prefix prefix)`.
   - Add Verdict 12 in `test_api.scm` testing prefix queries.

4. **Docs**:
   - Update `README.md`, `docs/user_guide.md`, and `docs/TODO.md`.

## Allowed Files Whitelist

- `components/gips-trust/src/bloom.rs`
- `components/gips-trust/src/lib.rs`
- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `README.md`
- `docs/user_guide.md`
- `docs/TODO.md`
- `docs/stages/stage-49-PROMPT.md` (or completed)

## Enumerated Tests

1. `test_bloom_filter_membership_and_bounds`
2. `test_substitute_prefix_query_endpoint`
3. `test_api.scm` Verdict 12 (`gips-search-prefix` parity)
4. `cargo test --all` and `just scheme-test`

## Definition of Done

- `cargo test --all` passes 100% green.
- `just scheme-test` passes all verdicts.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-49] feat: privacy-preserving substitute prefix queries and bloom filter summaries`
