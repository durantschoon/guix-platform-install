# Stage 51 — Guix System Service Definition (`gips-service-type`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

For users deploying GIPS on GNU Guix System machines, manually configuring systemd units, Shepherd services, config paths, and user permissions is error-prone. Providing an idiomatic GNU Guix `(gips service)` module with `<gips-configuration>` and `gips-service-type` allows operators to declare their GIPS substitute server and peer-to-peer daemon directly in their system configuration (`/etc/config.scm`).

## The Change

1. **Guix Service Module (`scheme/gips/service.scm`)**:
   - Define `<gips-configuration>` record with fields for:
     - `package` (default: `#f` or gips package placeholder)
     - `listen` (default: `"127.0.0.1:8080"`)
     - `db-path` (default: `"/var/lib/gips/gipsd.sqlite"`)
     - `ipfs-api` (default: `"http://127.0.0.1:5001"`)
     - `gns-command` (default: `"gnunet-gns"`)
     - `gossip-transport` (default: `"ipfs"`)
     - `cadet-port` (default: `"gips-gossip"`)
     - `cadet-command` (default: `"gnunet-cadet"`)
     - `trusted-publishers` (default: `'()`)
     - `allow-unsigned?` (default: `#f`)
     - `guix-signing-key` (default: `#f`)
   - Define `gips-service-type` with:
     - `shepherd-root-service-type` extension generating the `gipsd` Shepherd daemon service with start/stop actions.
     - `account-service-type` extension (or system user/group definitions for `gips`).
     - `activation-service-type` creating `/var/lib/gips` directory with mode `0700` and `gips` ownership.

2. **Scheme REPL Parity & Test Suite (`scheme/gips/service.scm`, `test_api.scm`)**:
   - Export `gips-configuration`, `gips-configuration?`, `gips-service-type`, `gips-configuration->toml`, and field accessors.
   - Add Verdict 14 in `test_api.scm` testing configuration record instantiation, serialization, and default properties.

3. **Documentation**:
   - Update `README.md`, `docs/user_guide.md`, and `docs/TODO.md`.

## Allowed Files Whitelist

- `scheme/gips/service.scm`
- `scheme/gips/api.scm`
- `test_api.scm`
- `README.md`
- `docs/user_guide.md`
- `docs/TODO.md`
- `docs/stages/stage-51-PROMPT.md` (or completed)

## Enumerated Tests

1. `test_api.scm` Verdict 14 (`(gips service)` `<gips-configuration>` record and serialization)
2. `just scheme-test`
3. `cargo test --all`

## Definition of Done

- All 14 verdicts in `test_api.scm` hold.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-51] feat: Guix System service definition (gips-service-type)`
