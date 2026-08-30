# Invariant

<!-- markdownlint-disable MD013 -->

These are invariant and should be checked before each commit.

1. Any command that can be run on the command line should also be available in the guile scheme repl
2. Documentation, including mermaid diagrams, are updated after design and/or code changes.
3. All markdown files are linted.
4. Reasonable tests should exist for any code we claim works (this includes rust and scheme code).
5. **Safety: Never serve a substitute whose NarHash is unverified**: Content returned from IPFS must always match its cryptographic CID before being processed.
6. **Safety: Empty trust list implies accepting nothing**: Both parsers and HTTP layers will reject signed data by default if no trust roots are explicitly configured.
7. **Safety: No unauthenticated mutation**: Endpoints like `/snapshot/create` and mirror ingestions must only operate via trusted processes or authenticated commands.
8. **Safety: No fabricated integrity fields**: Integrity fields (e.g. CIDs, NarHashes) must never be altered or injected after being parsed and verified.
9. **Safety: Safe Path Resolution**: Configuration and database paths are never resolved blindly relative to the CWD, preventing path traversal attacks.
10. **Safety: Causally Ordered Mirror Updates**: Mirror updates must be strictly causally ordered via Merkle DAGs (TLA+ proven).
