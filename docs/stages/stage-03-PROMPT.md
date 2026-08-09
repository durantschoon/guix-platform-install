# Stage 03 — Oracle first-boot preferences (hostname, timezone, shell)

## Motivation

`oracle/image/oracle-image.scm` hardcodes site-specific values:

```scheme
(define %user-name "guix")
(define %full-name "Guix User")
(define %host-name "guix-oracle")
(define %timezone "America/New_York")
```

Baking those was correct while every user built their own image. It stops being
correct the moment **one** image is published for everyone
([docs/ORACLE_ONE_CLICK_ROADMAP.md](../ORACLE_ONE_CLICK_ROADMAP.md) step 2) —
you cannot bake a stranger's timezone into an image they download.

So the preferences move out of the build and into first boot. This is roadmap
**step 4**, and note it is **not** gated on the live-instance verification that
blocks steps 2–3: preferences never touch the metadata service, so they are
fully exercisable in QEMU via `oracle/scripts/03-smoke-test.scm`.

## The change

A Guile script `oracle/postinstall/preferences.scm` that a user runs after their
first SSH login. It prompts for preferences, rewrites the system configuration,
and offers to reconfigure.

### Where the configuration comes from

Do **not** assume `/etc/config.scm` exists — an image built by `guix system
image` may not ship one. The reliable source on any running Guix system is the
generation's own provenance:

```
/run/current-system/configuration.scm -> /gnu/store/...-configuration.scm
```

Resolution order, with the reason stated in the code:

1. `/etc/config.scm` if present (the user may already be maintaining it)
2. otherwise copy `/run/current-system/configuration.scm` to `/etc/config.scm`
   (it is a read-only store path, so it must be copied before editing, and the
   copy must be made writable)
3. if neither exists, fail with a clear message — do not invent a config

### What is settable

| Preference | Field |
|---|---|
| Hostname | `(host-name ...)` on the `operating-system` |
| Timezone | `(timezone ...)` |
| Login shell | `(shell (file-append <pkg> "/bin/<sh>"))` on the user-account |

Shell choices: bash (default — **omit the field entirely**, do not write an
explicit bash shell), zsh, fish. A non-bash choice must also add the package to
the system `packages` field, or `file-append` refers to something absent from
the closure and the account gets a shell that does not exist.

### Explicitly OUT of scope

**Changing the user name.** It is listed in the roadmap's "minimum useful set",
but renaming an account after first boot moves the home directory, orphans
`~/.ssh/authorized_keys` (which is what the metadata service just wrote), and
can lock the user out of the only account on a machine reachable solely by SSH.
That is guardrail 8 — destructive, and not worth it for cosmetics. State this
in the purpose file as a deliberate omission with the reasoning, and have the
script say so if asked.

## Ground rules

- **Guile only**, per the language policy. Extend the existing machinery in
  `lib/guile-config-helper.scm`, which already does parsed S-expression edits
  (`add-service`, `check-service`, `switch-to-desktop`) with a subcommand
  interface. **Do not** add a `sed`-based path — that footgun was already
  removed once (2026-08-03, `954bb8b`) and must not come back.
- **ASCII only.** `[OK]` / `[WARN]` / `[ERROR]`. This is read over the OCI
  serial console.
- Guile has **no octal escape**: `"\x1b["`, never `"\033["`.
- All prompts read `/dev/tty`, never stdin.
- **Never edit the config in place.** Edit a temp copy and write back only on
  success, exactly as `call-guile-helper` in `postinstall/lib.scm` does — a
  half-edited `/etc/config.scm` on a remote machine is a very bad afternoon.
- **`guix system reconfigure` is offered, never automatic.** On the 1 GiB
  `E2.1.Micro` it is slow and leans on the swapfile; the user decides when.
- Do not remove code you were not asked to remove.

## Allowed files (whitelist)

```
oracle/postinstall/preferences.scm          (new)
oracle/postinstall/preferences_purpose.txt  (new)
oracle/postinstall/README.md                (document the new step)
lib/guile-config-helper.scm                 (new subcommands only)
oracle/tests/test-oracle-preferences.scm    (new)
run-tests.sh                                (registration; this stage owns it)
```

Do **not** touch `oracle/image/oracle-image.scm` — the image keeps its defaults;
this stage changes them after boot, it does not remove them. Do not touch
`SOURCE_MANIFEST.txt` or `CHECKLIST.md`.

## Tests (enumerated — all required)

New `oracle/tests/test-oracle-preferences.scm`, Guile, modelled on
`oracle/tests/test-oracle-image.scm`. **Fully offline** — no `guix system`
invocation, no network, and it must not touch the real `/etc/config.scm`. Use
fixture configs in a temp directory.

Assert on the transformation, which means it must be a pure function from
S-expression to S-expression:

1. Setting the hostname rewrites `(host-name ...)` and nothing else.
2. Setting the timezone rewrites `(timezone ...)` and nothing else.
3. Choosing zsh adds `(shell (file-append zsh "/bin/zsh"))` to the user-account.
4. Choosing zsh also adds `zsh` to the system `packages` — a shell that is not
   in the closure is a broken login.
5. Choosing bash writes **no** `shell` field (and removes one if present).
6. An unchanged preference leaves the config byte-identical.
7. The result still reads back as a single well-formed `operating-system` form.
8. A config lacking the field being set is handled — either inserted correctly
   or refused with a clear error, but never silently dropped.
9. The original file is untouched when the edit fails.
10. The file is ASCII only and contains no `\033[`.

Register the suite in `run-tests.sh` beside the other Oracle blocks, guarded by
`command -v guile`.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
guile --no-auto-compile -s oracle/tests/test-oracle-preferences.scm   # exit 0
```

Inherited baseline — do **not** "fix" these: validation Passed 6 / Failed 0 /
~15 warnings; `run-tests.sh` exit 0 with 14/14 converted-script tests failing
(auto-generated, never passed, deliberately non-gating).

`oracle/postinstall/preferences_purpose.txt` is required, and must include at
least: why the user name is deliberately not settable, why bash omits the field
rather than setting it explicitly, and why reconfigure is offered rather than
run.

## Commit message (exact, single line)

```
feat(oracle): first-boot preferences for hostname, timezone and shell
```

## Report requirements

`docs/stages/stage-03-REPORT.md` with: what changed per file; pasted output
tails for all three gates; deviations with reasoning; open questions; and an
explicit **Unverified claims** section — in particular, whether you were able to
exercise the reconfigure path at all, and what remains untested because it needs
a real Oracle instance.

## Blocked protocol

If the change appears to require editing the config in place, a `sed` path,
running `guix system reconfigure` unattended, renaming the user account, or
touching files outside the whitelist — **stop and write the REPORT with a
`Blocked:` section**. Do not improvise.
