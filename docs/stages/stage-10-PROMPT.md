# Stage 10 — GNU Guix IPFS Package Substitutes (GIPS) Subsystem Integration

## Motivation (measured)

Platform installations in `guix-platform-install` produce minimal bootable Guix
systems across cloud and bare-metal targets (Framework 13, Cloudzy VPS, Oracle
Cloud). However, package substitution currently relies exclusively on centralized
upstream HTTP build farms (`ci.guix.gnu.org`, `bordeaux.guix.gnu.org`). When upstream
build farms experience outages, rate limits, or slow network links, fresh systems
must compile packages from source.

Furthermore, users maintaining personal clusters (laptop, home server, cloud VPS)
have had no native mechanism to synchronize self-built package binaries across
machines without configuring custom VPNs, opening firewall ports, or standing up
public HTTP servers.

Integrating **GIPS** (GNS + IPFS Package Substitutes & P2P Mirror Fabric) into this
repository provides:
1. Decentralized, peer-to-peer substitute distribution backed by an IPFS swarm.
2. An automated post-install recipe (`postinstall/recipes/add/gips.scm`) for provisioning
   the GIPS daemon, IPFS integration, and Guix ACL authorization (`/etc/guix/acl`).
3. Contract integration with `docs/PERSONAL_CONFIG_CONTRACT.md` for zero-configuration
   multi-machine package synchronization.
4. Full Guile Scheme REPL parity and test harness verification (`make gips-test`).

## The change

1. Import the complete GIPS subsystem (Polylith Rust workspace, Guile Scheme modules,
   daemon `gipsd`, CLI client `gips`, TLA+ formal models, and documentation) into
   `gips/`.
2. Fix workspace path resolution in `gips/scheme/gips/api.scm` (`find-gips-binary` and
   `locate-guix-keygen`) so that test runners and Scheme scripts dynamically locate
   binaries and helpers whether invoked from repository root, from `gips/`, or via
   environment overrides (`GIPS_BIN`, `GIPS_GUIX_KEYGEN`).
3. Author post-install recipe `postinstall/recipes/add/gips.scm` and its accompanying
   purpose justification `postinstall/recipes/add/gips_purpose.txt`.
4. Update `lib/mirrors.md` with P2P substitute mirror documentation and configuration
   instructions.
5. Update `docs/PERSONAL_CONFIG_CONTRACT.md` with personal multi-machine GIPS package
   synchronization examples.
6. Wire GIPS test targets into `Makefile` (`gips-test`, `gips-rust-test`, `gips-check`)
   and register all offline Guile test suites in `run-tests.sh`.

## Ground rules

- All installer, postinstall, and Guix-facing scripts must be written in **Guile Scheme**
  (`.scm`), following `CLAUDE.md`.
- Shebang policy: `#!/run/current-system/profile/bin/guile --no-auto-compile -s` on
  Guix targets; `#!/usr/bin/env bash` on developer tooling.
- ASCII-only terminal output (`[OK]`, `[WARN]`, `[ERROR]`) for compatibility with
  the Guix ISO terminal and cloud serial consoles.
- Interactive prompts must read from `/dev/tty`, never `stdin`.
- Private signing keys (`0600`) and configuration directories (`0700`) must enforce
  strict fail-closed permissions.
- Pre-deployment validation (`lib/validate-before-deploy.sh --verbose`) and test
  suites must pass cleanly with zero failures.

## Allowed files (whitelist)

```
gips/
postinstall/recipes/add/gips.scm
postinstall/recipes/add/gips_purpose.txt
docs/PERSONAL_CONFIG_CONTRACT.md
lib/mirrors.md
Makefile
Makefile_purpose.txt
run-tests.sh
SOURCE_MANIFEST.txt
docs/stages/stage-10-PROMPT.md
docs/stages/stage-10-REPORT.md
```

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; Failed: 0
make gips-test                            # exit 0; all recipe and API verdicts pass
make oracle-test                          # exit 0; all Oracle capacity and validation checks pass
git diff --check                         # exit 0
```

## Commit message

```
feat(gips): integrate GIPS P2P substitute mirror into dedicated branch
```
