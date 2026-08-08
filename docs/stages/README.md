# Stage Pipeline

Delegated implementation with review gates. The coordinator authors prompts and
reviews; a `stage-executor` subagent implements each stage in an isolated git
worktree. **No executor reviews its own work.**

## Numbering

One global sequence. Each stage NN has exactly two files here:

- `stage-NN-PROMPT.md` — authored and committed to `main` **before** the
  executor launches. The committed text is canonical.
- `stage-NN-REPORT.md` — written by the executor.

## The gates

Every stage's Definition of Done uses these verbatim. They come from
`CLAUDE.md`, which calls the first one CRITICAL.

```sh
# 1. Static / pre-deployment validation. Exit 0 required.
#    Warnings are acceptable; "Failed:" must be 0.
lib/validate-before-deploy.sh --verbose

# 2. Full test suite. Exit 0 required.
./run-tests.sh

# 3. Manifest, if any file it covers changed. Run by the COORDINATOR, not the
#    executor -- it is a shared file and would collide across parallel stages.
./update-manifest.sh
```

Baseline as of the pipeline's introduction (2026-08-08), so a stage can tell
its own breakage from inherited state:

- `lib/validate-before-deploy.sh` — Passed 6, **Failed 0**, ~15 warnings
- `./run-tests.sh` — exit 0. Reports **14/14 converted-script tests failing**;
  those are auto-generated, have never passed, and are deliberately non-gating.
  Do not "fix" them as part of an unrelated stage.

## Shared registration files

At most **one in-flight stage** may touch any of these. The coordinator assigns
ownership in the prompt's allow-list.

| File | Why it is shared |
|---|---|
| `run-tests.sh` | every test suite registers here |
| `SOURCE_MANIFEST.txt` | generated; coordinator regenerates after merge |
| `CHECKLIST.md` | coordinator-owned; executors never edit it |
| `lib/validate-before-deploy.sh` | the gate itself |

## Guardrails

**Unifying principle: information, once obtained, is never silently discarded
or degraded.**

Adapted to this repo, which is Guile/Go/Bash rather than a typed-FP codebase.
The STOP-AND-ASK form is preserved: these are the cases where an executor must
stop and report **Blocked** rather than decide.

1. **Language policy is not negotiable.** New scripts that run on Guix (ISO or
   installed) are **Guile**. Bash only for what must run before Guix exists or
   on a non-Guix machine. A stage that seems to need a new `.sh` on a Guix
   target ⇒ **STOP and ask**.
2. **Shebangs.** `#!/run/current-system/profile/bin/bash` (or `.../guile`) for
   anything running on Guix; `#!/usr/bin/env bash` for developer tooling.
   Never `#!/bin/bash` — Guix's `/bin` contains only `sh`.
3. **ASCII only** in anything that may be read over the Guix ISO terminal or
   the OCI serial console. `[OK]` / `[WARN]` / `[ERROR]`, never `✓ ⚠ ❌`.
4. **Guile has no octal string escape.** `"\033["` reads as NUL + `"33"`. Use
   `"\x1b["`.
5. **Read from `/dev/tty`, never stdin.** stdin may be the script itself
   (piped entry points) or a redirected file.
6. **Every unit of code states its purpose.** Non-obvious decisions go in the
   matching `*_purpose.txt`, including statements of omission ("tempting to add
   X; left out because it causes Y").
7. **Do not remove code you were not told to remove.** Flag it in the report
   instead and let the human decide.
8. **Destructive or outward-facing behaviour is ceremony**, never a side
   effect: anything that partitions a disk, deletes a generation, overwrites a
   user's config, or transmits data off the machine must be explicit and
   confirmed ⇒ **STOP and ask** if a stage seems to require it.
9. **Never accept third-party credentials.** Nothing in this repo may be built
   to receive another person's OCI API keys, SSH private keys, or tenancy
   secrets ⇒ **STOP and ask**.
10. **Unverified claims stay labelled unverified.** If something has not been
    run on real hardware or a live instance, the docs and the report say so.
    Do not upgrade "should work" into "works".

## Coordinator practices

- Stage prompts land on `main` before launch (canonical text + number
  reservation).
- At most one in-flight stage touches any shared registration file.
- Executors attempt their own push and are expected to fail on credentials;
  the coordinator pushes and merges.
- Review = read the diff + independently re-run the gates in the executor's
  worktree. Never review by reading the report alone.
- If `main` moved since the executor branched, merge `main` into its branch and
  re-run the gates on the union before merging back.
- Retro every 5 stages (when `NN % 5 == 0`, before authoring stage NN), plus
  whenever the user asks.
- **Blocked-on-human work is not staged.** Steps that depend on a live OCI
  instance launch are gated on the user; see
  [../ORACLE_ONE_CLICK_ROADMAP.md](../ORACLE_ONE_CLICK_ROADMAP.md).

## Stages

| NN | Title | Status |
|---|---|---|
| 01 | OCI capacity handling in `04-deploy.scm` | authored |
| 02 | Presentation-only web page for the Oracle flow | authored |
