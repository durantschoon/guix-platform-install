# Stage 47 — Terminal Swarm Monitor & Live Telemetry (`gips monitor`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In Stage 24 and Stages 43–46, GIPS introduced live latency histograms (`/metrics`), metrics history (`/metrics/history`), gossip status (`/gossip/status`), and pluggable transport abstractions. However, inspecting a running node's real-time operational status, gossip peering health, message throughput, and substitute resolution performance requires querying multiple independent endpoints.

Stage 47 introduces `gips monitor` — a unified terminal monitor for node health, swarm peering, gossip event counters, trust revocations, and latency metrics. It supports single-pass snapshot output (`--once`), continuous live watch mode (`--watch [--interval-secs <N>]`), machine-readable structured output (`--json`), and Guile Scheme REPL parity (`(gips-monitor)`).

## The Change

1. **`gips` CLI (`gips/src/main.rs`)**:
   - Add `Monitor` command to `Commands` enum:

     ```rust
     Monitor {
         #[arg(long, help = "Print single-pass status snapshot and exit")]
         once: bool,
         #[arg(long, help = "Continuously watch live status (clears screen every interval)")]
         watch: bool,
         #[arg(long, default_value = "2", help = "Watch interval in seconds")]
         interval_secs: u64,
         #[arg(long, help = "Emit structured JSON snapshot")]
         json: bool,
     }
     ```

   - Implement `gips monitor` execution handler:
     - Fetches `/status`, `/gossip/status`, `/metrics`, and `/fraud-proof/list` concurrently.
     - Formats clean terminal dashboard rendering:
       - Header: Daemon URL, uptime, active transport backend, database status.
       - Gossip Swarm: Active topics, peer count, received/accepted/rejected vouches and fraud proofs.
       - Performance Metrics: Request count, P50/P90/P99 latencies for `/narinfo` and `/nar` serving.
       - Security & WoT: Number of active objective revocations / fraud proofs.
     - Supports `--json` emitting consolidated `MonitorSnapshot` JSON.
     - Supports `--once` (default when non-interactive) and `--watch` (interactive terminal loop).

2. **Guile Scheme REPL Parity (`scheme/gips/api.scm` & `test_api.scm`)**:
   - Export and implement `(gips-monitor #:once? #t #:json? #f)`.
   - Add Verdict 11 in `test_api.scm` verifying `gips-monitor` snapshot and JSON formatting against mock daemon endpoints.

3. **Docs**:
   - Update `README.md`, `docs/user_guide.md`, and `docs/TODO.md` documenting `gips monitor`.

## Allowed Files Whitelist

- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `README.md`
- `docs/user_guide.md`
- `docs/TODO.md`
- `docs/stages/stage-47-PROMPT.md` (or completed)

## Enumerated Tests

1. `gips monitor --once` terminal snapshot rendering.
2. `gips monitor --once --json` JSON serialization and schema validity.
3. `test_api.scm` Verdict 11 (`gips-monitor` Scheme REPL parity).

## Definition of Done

- `cargo test --all` passes 100% green.
- `just scheme-test` passes 11/11 verdicts.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-47] feat: terminal swarm monitor and live peering telemetry (gips monitor)`
