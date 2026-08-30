# Stage 13 — Personal Multi-Machine Binary Sync Automation

## Motivation (measured)

Stage 10 introduced GIPS support into `docs/PERSONAL_CONFIG_CONTRACT.md`. When operators maintain multiple Guix machines (for example, a Framework 13 laptop, home server, and cloud VPS), they want automatic binary substitute peering between their machines without manually copying IPFS multiaddresses or exchanging public keys by hand.

Stage 13 builds an automated synchronization orchestration helper that:
1. Coordinates GNS identity advertisements and ACL key discovery across the operator's known nodes.
2. Synchronizes profile package lists and publishes store references to the user's GNS record via `gips-publish` / `gips-snapshot-create`.
3. Integrates directly with `postinstall/recipes/add/personal-config.scm` and `guix-personal.scm` workflow steps.

## The change

1. Create `postinstall/recipes/add/personal-sync.scm` (and its accompanying `personal-sync_purpose.txt`) providing automated personal sync orchestration.
2. Integrate personal sync discovery into `(gips api)` and `(gips config)`.
3. Add offline test coverage in `postinstall/tests/test-personal-sync.scm`.
4. Document the complete multi-machine workflow in `docs/PERSONAL_CONFIG_CONTRACT.md` and `gips/docs/personal-sync-quickstart.md`.

## Ground rules

- Guile for all scripts and tests.
- ASCII-only console output.
- All secret key material and authentication tokens must enforce `0600`/`0700` filesystem permissions.
- Non-destructive execution: synchronization must never delete local store paths or overwrite existing configs without confirmation.

## Allowed files (whitelist)

```
postinstall/recipes/add/personal-sync.scm
postinstall/recipes/add/personal-sync_purpose.txt
postinstall/tests/test-personal-sync.scm
docs/PERSONAL_CONFIG_CONTRACT.md
gips/docs/personal-sync-quickstart.md
docs/stages/stage-13-REPORT.md
```

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; Failed: 0
make gips-test                            # exit 0
git diff --check                         # exit 0
```

## Commit message

```
feat(postinstall): add personal multi-machine sync orchestration
```
