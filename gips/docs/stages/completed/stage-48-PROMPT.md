# Stage 48 — Live GNUnet CADET Transport Driver & Multi-Transport Aggregator

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In Stage 46, GIPS introduced the `GossipTransport` abstraction with an initial stub for `GnunetCadetTransport`. However, running GIPS without an IPFS Kubo daemon (in pure GNUnet mode) or bridging both networks requires a live CADET runtime driver with message framing, connection pooling, and multi-transport aggregation.

Stage 48 implements the live `GnunetCadetTransport` driver, packet framing over CADET streams, and a `CompositeGossipTransport` that allows simultaneous broadcast and subscription across IPFS PubSub and GNUnet CADET mesh channels.

## The Change

1. **CADET Framing & Transport Driver (`components/gips-ipfs/src/transport.rs`)**:
   - Implement `CadetMessageEnvelope` (topic, sender peer ID, payload base64/binary).
   - Implement `GnunetCadetTransport` with:
     - Async child process / socket runner interfacing with `gnunet-cadet`.
     - In-memory subscriber fanout channels (`tokio::sync::broadcast`) for incoming CADET mesh traffic.
     - Peer connection tracking and live status reporting.
   - Implement `CompositeGossipTransport` that aggregates multiple `Arc<dyn GossipTransport>` instances, fanout-publishing to all and merging subscription streams.

2. **Configuration Integration (`bases/gips-config/src/lib.rs` & `components/gips-http/src/lib.rs`)**:
   - Add `gossip_transport: String` (e.g. `"ipfs"`, `"cadet"`, `"memory"`, `"composite"`) and `cadet_port: String` to `GipsdConfig`.
   - Initialize appropriate `GossipTransport` in `build_app_state`.

3. **Docs & Tests**:
   - Add unit tests for CADET framing, fanout, and composite aggregation in `components/gips-ipfs/src/transport.rs`.
   - Update `README.md`, `docs/user_guide.md`, and `docs/TODO.md`.

## Allowed Files Whitelist

- `components/gips-ipfs/src/transport.rs`
- `components/gips-ipfs/src/lib.rs`
- `bases/gips-config/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `docs/TODO.md`
- `README.md`
- `docs/user_guide.md`
- `docs/stages/stage-48-PROMPT.md` (or completed)

## Enumerated Tests

1. `test_cadet_envelope_roundtrip`
2. `test_cadet_transport_publish_and_subscribe`
3. `test_composite_gossip_transport_aggregation`
4. `cargo test --all` and `just scheme-test`

## Definition of Done

- `cargo test --all` passes 100% green.
- `just scheme-test` passes all verdicts.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-48] feat: live GNUnet CADET transport driver and composite gossip aggregator`
