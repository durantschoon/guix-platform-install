# Stage 46 — Pluggable Gossip Transport Abstraction (IPFS PubSub, In-Memory Mesh, GNUnet CADET)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In Stage 43, automated gossip propagation was wired directly against Kubo IPFS PubSub HTTP endpoints (`state.ipfs.pubsub_pub` / `pubsub_sub`). However, as designed in `docs/federation.md` (Plan B), the federated substitute network must remain transport-agnostic: nodes may propagate vouch tokens and cryptographic fraud proofs across IPFS PubSub, in-memory mesh networks (for deterministic local test harnesses and air-gapped federations), or GNUnet CADET channels.

Stage 46 introduces a clean, async `GossipTransport` trait in `components/gips-ipfs`, implements `IpfsPubsubTransport`, `MemoryMeshTransport` (multi-peer broadcast fabric), and `GnunetCadetTransport` (CADET channel abstraction), and unifies `gips-http` gossip publication, worker subscription, and status inspection behind this trait.

## The Change

1. **`components/gips-ipfs` (New `transport` Module)**:
   - Define `GossipError` and `GossipTransportStatus` (`topics: Vec<String>`, `peer_count: usize`, `transport_type: String`).
   - Define `GossipTransport` trait with `async_trait`:
     - `async fn publish(&self, topic: &str, payload: &[u8]) -> Result<(), GossipError>`
     - `async fn subscribe(&self, topic: &str) -> Result<Pin<Box<dyn futures::Stream<Item = Result<Vec<u8>, GossipError>> + Send>>, GossipError>`
     - `async fn status(&self) -> Result<GossipTransportStatus, GossipError>`
   - Implement `IpfsPubsubTransport` wrapping the Kubo IPFS HTTP API.
   - Implement `MemoryMeshTransport`: a multi-peer in-memory gossip bus backed by `tokio::sync::broadcast` channels, allowing instant test swarms.
   - Implement `GnunetCadetTransport`: CADET transport structure and subprocess/channel integration.
   - Re-export `GossipTransport`, `IpfsPubsubTransport`, `MemoryMeshTransport`, `GnunetCadetTransport`, and `GossipTransportStatus` from `gips_ipfs`.
   - Comprehensive unit tests verifying message broadcast, multi-subscriber fanout, error handling, and status queries across transports.

2. **`components/gips-http` (Integration with `AppState`)**:
   - Update `AppState` to hold `pub gossip: Arc<dyn GossipTransport>`.
   - Update `vouch_ingest` and `fraud_proof_submit` handlers to broadcast via `state.gossip.publish(...)`.
   - Update `start_gossip_worker` to stream messages via `state.gossip.subscribe(...)`.
   - Update `GET /gossip/status` to return combined gossip statistics and transport status.

3. **`tests/e2e_federation.rs` & Tests**:
   - Update `TestNode` in `tests/e2e_federation.rs` to leverage `MemoryMeshTransport` (or mock IPFS) with zero flaky network flushes.
   - Verify `cargo test --all` and `just scheme-test`.

4. **Docs**:
   - Update `docs/TODO.md` to record the pluggable gossip transport abstraction milestone.

## Allowed Files Whitelist

- `components/gips-ipfs/src/transport.rs` (new)
- `components/gips-ipfs/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `components/gips-http/src/gossip.rs`
- `gipsd/src/main.rs`
- `tests/e2e_federation.rs`
- `docs/TODO.md`
- `docs/stages/stage-46-PROMPT.md` (or completed)

## Enumerated Tests

1. `components/gips-ipfs/src/transport.rs` unit tests (in-memory broadcast fan-out, IPFS pubsub mock stream, CADET stub, transport status).
2. `tests/e2e_federation.rs` scenario tests running over the gossip transport.
3. `test_api.scm` Verdict 9 (`gips-gossip-status`).

## Definition of Done

- `cargo test --all` passes 100% green.
- `just scheme-test` passes 10/10 verdicts.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-46] feat: pluggable gossip transport abstraction (GNUnet CADET, In-Memory Mesh, IPFS PubSub)`
