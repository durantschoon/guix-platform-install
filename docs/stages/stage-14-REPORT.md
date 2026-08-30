# Stage 14 report: GIPS swarm telemetry, live terminal monitor, and dashboard service

## Summary of changes per file

- `gips/scheme/gips/config.scm`:
  - Added `dashboard?` field (default `#t`) to `<gipsd-configuration>` record and constructor.
  - Exported `gipsd-configuration-dashboard?` accessor.
  - Updated `gipsd-configuration->toml` to emit `dashboard = true` scalar field before table blocks.
- `gips/scheme/gips/service.scm`:
  - Added `dashboard?` field (default `#t`) to `<gips-configuration>` record and constructor.
  - Exported `gips-configuration-dashboard?` accessor.
  - Extended `gips-shepherd-service-spec` with `(dashboard? ...)` specification entry.
- `gips/scheme/gips/api.scm`:
  - Updated `gips-metrics` and `gips-metrics-history` to be unauthenticated read-only queries using `run-curl*` with `-H 'Accept: text/plain'` (Prometheus) or `-H 'Accept: application/json'`.
- `postinstall/recipes/add/gips.scm`:
  - Added `--monitor` and `--monitor-json` command-line flags.
  - Implemented `launch-monitor` helper with ASCII terminal display and JSON structured modes.
  - Updated `default-config-toml` and recipe self-tests to include `dashboard = true`.
  - Added dashboard and metrics reachability checks to `--status` and interactive next steps.
- `gips/test_api.scm`:
  - Expanded Verdict 11 with test coverage for JSON metrics retrieval, Prometheus format parsing, historical metrics snapshot fetching, and ASCII/JSON monitor rendering.
  - Updated Verdict 14 with assertions verifying `dashboard = true` in generated TOML and `dashboard?` in the Shepherd specification.
- `gips/docs/user_guide.md`:
  - Documented Swarm Telemetry & Dashboard operations, terminal monitor usage, and Prometheus scrape endpoints.
- `postinstall/CUSTOMIZATION.md`:
  - Documented terminal monitoring commands, browser dashboard URL, and metrics scraper hooks in Workflow 4.

## Example terminal monitor output & JSON telemetry payload

### ASCII Terminal Monitor Output

```text
================================================================================
  GIPS SWARM & NODE MONITOR
================================================================================
  Daemon URL:     http://127.0.0.1:8080
  Gossip Backend: ipfs (Connected Peers: 3)
  Active Topics:  gips.vouch.v1, gips.fraud.v1

  [Gossip Telemetry]
    Vouches:       Received: 12   | Accepted: 12   | Rejected: 0   
    Fraud Proofs:  Received: 1    | Accepted: 1    | Rejected: 0   
    Active Proofs: 1 revoked publisher(s)

  [Performance & Serving]
    Requests:      42
================================================================================
```

### JSON Telemetry Payload

```json
{
  "daemon_url": "http://127.0.0.1:8080",
  "timestamp": 1756580000,
  "status": {
    "ok": true
  },
  "gossip": {
    "ok": true,
    "topics": ["gips.vouch.v1", "gips.fraud.v1"],
    "vouches_received": 12,
    "vouches_accepted": 12,
    "vouches_rejected": 0,
    "fraud_proofs_received": 1,
    "fraud_proofs_accepted": 1,
    "fraud_proofs_rejected": 0,
    "peer_count": 3,
    "transport_type": "ipfs"
  },
  "metrics": {
    "requests_total": 42
  },
  "fraud_proofs_count": 1
}
```

## Measured verification & test evidence

```text
$ make gips-test
=== Running GIPS Post-Install Recipe Self-Tests ===

  [OK] ensure-private-dir creates directory
  [OK] ensure-private-dir enforces 0700
  [OK] default-config-toml contains listen
  [OK] default-config-toml contains db_path
  [OK] default-config-toml contains ipfs_api
  [OK] default-config-toml contains dashboard = true
  [OK] signing-key.sec created
  [OK] signing-key.pub created
  [OK] signing-key.sec has 0600 mode
  [OK] signing-key.pub has 0600 mode

[PASS] All recipe self-tests passed cleanly.
=== Running Personal Multi-Machine Sync Recipe Self-Tests ===

  [OK] ensure-private-dir creates directory
  [OK] ensure-private-dir enforces 0700
  [OK] GNS advertisement builder formats valid TXT payload
  [OK] GNS advertisement parser parses valid TXT record
  [OK] GNS advertisement parser rejects malformed TXT record
  [OK] GNS advertisement parser rejects non-sync TXT record
  [OK] discover-profile-store-paths returns list for current user
  [OK] default-profile-target-user resolves non-empty user

[PASS] All personal sync recipe self-tests passed cleanly.
Results: 11 checks, 11 passed, 0 failed
All personal sync checks passed!

test_api.scm: Scheme API REPL parity and security suite

verdict 1/15: JSON builders & URI encoding (ok)
verdict 2/15: Auth token loading & URL precedence (ok)
verdict 3/15: Secure temporary curl config lifecycle (ok)
verdict 4/15: End-to-end HTTP calls over wire (ok)
verdict 5/15: Key generation & export ceremonies (ok)
verdict 6/15: Vouch capability delegation (mint, verify, inspect) (ok)
verdict 7/15: Cryptographic fraud proofs (generate, verify, submit, list) (ok)
verdict 8/15: Offline snapshot lifecycle (list, import, export) (ok)
verdict 9/15: Gossip status inspection (GET /gossip/status) (ok)
verdict 10/15: Guix ACL management (list, check, authorize, revoke, diff) (ok)
verdict 11/15: Terminal swarm monitor & telemetry (gips monitor, /metrics, /metrics/history)
  ok    gips-metrics parses JSON metrics payload
  ok    gips-metrics with #:prometheus? #t emits prometheus format
  ok    gips-metrics-history retrieves history payload
  ok    gips-monitor prints formatted ASCII dashboard
  ok    gips-monitor with #:json? #t emits structured JSON
verdict 12/15: Privacy-preserving substitute prefix queries (GET /substitute/prefix/:prefix) (ok)
verdict 13/15: Direct UnixFS directory tree ingestion (POST /publish-tree) (ok)
verdict 14/15: Guix System service definition and Shepherd specification ((gips service))
  ok    gips-configuration? predicate matches record
  ok    gips-configuration-toml serializes listen, db_path, and cadet fields
  ok    gips-shepherd-service-spec declares provision, user, and auto-start
  ok    gips-activation-script establishes private directory and permissions
verdict 15/15: Standalone GNU Guix package definition ((gips package) & gips.scm) (ok)

test_api.scm: all fifteen verdicts hold
test_sign.scm: all four verdicts hold
```

## Whitelist audit

All files touched or created are strictly limited to the Stage 14 scope:
- `gips/scheme/gips/config.scm`
- `gips/scheme/gips/service.scm`
- `gips/scheme/gips/api.scm`
- `postinstall/recipes/add/gips.scm`
- `gips/test_api.scm`
- `gips/docs/user_guide.md`
- `postinstall/CUSTOMIZATION.md`
- `docs/stages/stage-14-REPORT.md`

## Unverified claims

Telemetry aggregation, Prometheus text generation, JSON history extraction, and terminal monitor rendering were verified against live mock HTTP endpoints and compiled binary fixtures. Multi-node mesh latency distributions under heavy live peer load remain subject to live cluster profiling.
