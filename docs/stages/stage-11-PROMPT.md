# Stage 11 — GIPS Guix System Service Integration (`(gips service)`)

## Motivation (measured)

Stage 10 integrated the GIPS subsystem and provided a post-install recipe (`postinstall/recipes/add/gips.scm`) for user-profile execution. However, on production Guix System deployments (such as bare-metal Framework laptops or persistent cloud nodes), operators declare long-running system daemons declaratively inside `/etc/config.scm` rather than managing background processes in user sessions.

Integrating `(gips service)` with Guix System's `operating-system` declaration allows:
1. Declarative `<gips-configuration>` in `/etc/config.scm`.
2. Automatic Shepherd daemon lifecycle management (`shepherd-root-service-type`).
3. Dedicated unprivileged system user/group (`gips`) with mode `0700` state directories (`/var/lib/gips/`).
4. Config helper transformation routines in `lib/guile-config-helper.scm` to add, configure, and inspect GIPS services without losing existing configuration comments or S-expression formatting.

## The change

1. Extend `lib/guile-config-helper.scm` with `add-gips-service` and `has-gips-service?` procedures that parse and modify `operating-system` service lists using S-expression matching and comment preservation.
2. Ensure `gips/scheme/gips/service.scm` generates valid Shepherd service specifications and activation scripts for GNU Guix System configurations.
3. Add offline test coverage in `lib/tests/test-config-helper-gips.scm` validating that:
   - Minimal configs correctly receive `(service gips-service-type (gips-configuration ...))`.
   - Existing configs with custom services retain all comments, gexps, and formatting when the GIPS service is added.
   - Repeated additions are idempotent and do not duplicate services.
4. Document declarative service setup in `gips/docs/user_guide.md` and `postinstall/CUSTOMIZATION.md`.

## Ground rules

- Guile for all configuration helpers, transformations, and tests.
- ASCII-only terminal messages (`[OK]`, `[WARN]`, `[ERROR]`).
- Strict comment and formatting preservation: no loss of inline comments or `#~` gexp syntax during configuration file edits.
- Idempotent transformations: running the helper on a configuration that already has GIPS configured must make no modifications.
- Do not edit `CHECKLIST.md` or `SOURCE_MANIFEST.txt`; the coordinator owns shared registration files.

## Allowed files (whitelist)

```
lib/guile-config-helper.scm
lib/tests/test-config-helper-gips.scm
gips/scheme/gips/service.scm
gips/docs/user_guide.md
postinstall/CUSTOMIZATION.md
docs/stages/stage-11-REPORT.md
```

## Tests (enumerated — all required)

1. `has-gips-service?` returns `#f` for minimal configs and `#t` once the GIPS service is attached.
2. `add-gips-service` attaches `(service gips-service-type ...)` without re-formatting unrelated services.
3. Adding the GIPS service preserves surrounding S-expressions, inline comments, and `#~` gexp syntax.
4. Repeated invocations of `add-gips-service` are idempotent and do not insert duplicate service declarations.
5. All 15 existing verdicts in `gips/test_api.scm` and all 4 verdicts in `gips/test_sign.scm` remain green.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; Failed: 0
make gips-test                            # exit 0; all Scheme API and service tests pass
git diff --check                         # exit 0
```

## Commit message (exact, single line)

```
feat(gips): add declarative system service helper and configuration tests
```

## Report requirements

Write `docs/stages/stage-11-REPORT.md` with:
- Summary of changes per file.
- Example input and output `config.scm` transformations.
- Comment and gexp preservation verification.
- Pasted gate output.
- Whitelist audit.
- Unverified claims section.

## Blocked protocol

If configuration transformation cannot guarantee comment preservation, or if S-expression serialization introduces formatting drift, stop and report `Blocked:`. Do not silently strip comments or overwrite user configuration files without preservation.
