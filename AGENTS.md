# Start here

Orientation for any AI agent working in this repository. Vendor-neutral: the
rules below apply whichever assistant you are.

**Written 2026-08-11.** Anything about *current state* rots; the "Conventions"
section does not. When they disagree, trust `git log` and `CHECKLIST.md` over
this file, and fix this file.

## Read in this order

| Read | For |
|---|---|
| **`CLAUDE.md`** | The full operating rules. Despite the name these are **not Claude-specific** — language policy, shebang paths, ASCII constraints, testing workflow. Read it before writing code. |
| **`CHECKLIST.md`** | What is done and what is next. The five most recent completions are at the top; older ones are in `archive/CHECKLIST_COMPLETED.md`. |
| **`docs/ORACLE_ONE_CLICK_ROADMAP.md`** | The work currently in flight, and the single gate blocking it. |
| **`docs/stages/README.md`** | How delegated implementation works here — numbered stage prompts, isolated worktrees, review gates. Four stages are merged. |
| **`docs/STORY.md`** | Narrative of how the hard problems were actually diagnosed. The one doc that inverts the usual technical/narrative ratio. Optional, but it explains *why* several odd-looking decisions are correct. |

## Where the project is (2026-08-11)

The goal: someone with no Guix experience gets a free always-on Guix machine on
Oracle Cloud, configured the way they like.

- **Done**: the personal-config contract (`docs/PERSONAL_CONFIG_CONTRACT.md`),
  instance-metadata SSH keys, capacity handling, first-boot preferences, and a
  published walkthrough at
  <https://durantschoon.github.io/guix-platform-install/>.
- **Blocked**: publishing one generic image, and the console-only path. Both
  wait on a single test.
- **The gate**: launch an instance whose SSH key arrives *only* via
  `--metadata ssh_authorized_keys`, and log in. Everything underneath it —
  endpoint, auth header, fallback, value format, DHCP timing — is measured. Two
  bugs have been found and fixed by running it; it has not yet passed.

## Not in git, and easy to miss

Several things this work depends on are machine-local. An agent on a different
machine does not have them and should not assume they exist:

- `~/.local/bin/oracle-*` — helper scripts (`oracle-ssh`,
  `oracle-verify-metadata`, `oracle-metadata-gate`)
- `~/.oci/` — Oracle CLI credentials
- `.claude/` — gitignored, including the permission allowlist
- The assistant's own memory directory, if it has one

Also: **`guix` only exists on the Guix machine.** Nothing involving
`guix system image`, `guix repl`, or the Oracle image build can run on macOS.
Go tests and documentation work fine anywhere.

## Conventions that are load-bearing

These are the ones most often violated by someone new. `CLAUDE.md` has the full
set and the reasoning.

1. **Guile for anything that runs on Guix.** Bash only for what must run before
   Guix exists, or on a non-Guix machine.
2. **Shebangs.** `#!/run/current-system/profile/bin/bash` (or `.../guile`) on
   Guix targets; `#!/usr/bin/env bash` for developer tooling. Never
   `#!/bin/bash` — Guix's `/bin` contains only `sh`.
3. **Guile has no octal string escape.** `"\033["` reads as NUL followed by the
   characters `3`, `3`. Use `"\x1b["`.
4. **A directly-executable Guile script needs the meta-switch shebang** —
   backslash at the end of the first line, arguments on the second. A shebang
   passes everything after the interpreter as ONE argument.
5. **ASCII only** in anything read over the Guix ISO terminal or an OCI serial
   console: `[OK]`, `[WARN]`, `[ERROR]`. Unicode that is *parsed input* rather
   than output is the exception — write it as `\u` escapes and see
   `lsblkTreePrefixCutset`.
6. **Read prompts from `/dev/tty`, never stdin.** Some entry points are piped
   into the interpreter, so stdin is the script itself.
7. **Every unit of code states its purpose** in a matching `*_purpose.txt`,
   including statements of omission ("tempting to add X; left out because Y").
8. **Do not remove code you were not asked to remove.** Flag it instead.

## Before you commit

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
./update-manifest.sh                      # if it covers a file you changed
```

Inherited state, not your breakage: about 15 validation warnings, and
`run-tests.sh` reports 14/14 converted-script tests failing. Those are
auto-generated, have never passed, and are deliberately non-gating. Do not
"fix" them as part of unrelated work.

## When to verify instead of trust

Much of this project runs on machines that are slow or awkward to reach: an
image build, an upload, an import, a boot. A wrong assumption is not found in
seconds — it is found in half an hour, on a box you may not be able to log into.
That asymmetry, not diligence, is what the rule below is about.

**The trigger is a ratio.** If discovering a mistake would take roughly ten
times longer than checking for it, check. Every expensive failure in this
repository's history cost a 30–60 minute cloud cycle; every check that would
have caught it cost under two minutes.

**Verify when your belief came from somewhere else.** The failures here were not
carelessness; each was a confident model of *another system's* behaviour that
had never been tested against that system:

| Assumed | The boundary not crossed |
|---|---|
| "the config evaluates" ⇒ it builds | evaluation → **build** (the builder only runs at build time) |
| a flag valid on `image import` is valid on `instance launch` | one API verb → **another** |
| a helper returns an exit status | your code → **the helper's actual contract** |
| `read-line` exists | Guile core → **the shepherd gexp's module set** |

Each was cheap to check and expensive to discover. So: **verify at boundaries
you have not personally crossed** — a library's internals, a CLI's accepted
flags, a runtime's available modules, another layer's return contract. Trust
your own code within a layer you just wrote and can see fail immediately.

**Name the phase your evidence comes from.** "Verified" is not a claim until it
says *verified how far*. Evaluating is not building; building is not booting;
booting is not logging in. Writing "both paths verified to evaluate" and
treating it as "both paths work" is exactly how the `#f`-in-authorized-keys bug
reached a real image build. If something has not been run on real hardware or a
live instance, the docs and the report say so.

**Design the test so failure teaches.** The first gate attempt built an image
with no key, so a failure meant no key → no login → no logs → the reason
stranded on the machine. Two rounds later the same test kept a baked key purely
so the failure could be *read*, and the very next run produced a timestamped
`Unbound variable: read-line`. Prefer a test that is slightly less pure and
actually diagnosable. Ask before running it: *if this fails, what will I know?*

**A report is a claim; a diff and a rerun are evidence.** When a subagent says
its work is clean, check the changed files against its allow-list, read the
diff, and re-run the gates yourself in its worktree. One stage's report was
accurate and still understated what it had done — it had also fixed two latent
bugs that would have silently dropped a NetworkManager DNS block.

**Trust freely where failure is immediate and loud.** A typo in a test file
surfaces in seconds. Re-checking that costs more than the failure does.

## A warning this repository earned

**Seven of its checks passed by not looking.** Not one bug seven times — seven
separate gates, found over two days in 2026-08, each reporting success while
inspecting almost nothing. Three of them lived in the same file,
`lib/validate-before-deploy.sh`, the script `CLAUDE.md` calls CRITICAL and tells
you to run before every commit.

| The gate | What it actually did |
|---|---|
| Shebang rule | Nothing enforced it. 8 scripts carried `#!/bin/bash`, which cannot run on Guix (`/bin` holds only `sh`) — including `run-tests.sh` itself, so the mandated pre-commit command was unrunnable on the development machine. It "worked" only because everyone typed `bash run-tests.sh`, which bypasses the shebang. |
| Manifest check | Hashed **1 file of 54**. Any other file could drift forever. It was also a `WARN`, so it never gated. |
| Unicode check | Scanned **1 file**, and used GNU-only `grep -P` whose error went to `/dev/null` — so on macOS it passed **without reading anything**. |
| Unit-test check | Piped `go test` into `grep -q "ok"`. That matches one passing package — or any path containing the substring `ok` — while other packages fail. A partially failing suite reported PASS. |
| `run-tests.sh` | `set -e` aborted the suite on the first *deliberately tolerated* failure, defeating an explicit `# Don't fail the entire test suite` decision three lines below it. |
| Device-detection tests | Asserted the *environment* ("no devices here") rather than the contract, so they failed on any real machine and passed only in an empty container. One condition was inverted: the success case was reported as failure. |
| Evaluation tests | Structurally unable to catch a build-time fault. "Both paths verified to evaluate" was read as "both paths work"; the failing builder only runs at build time, and the bug reached a real image build. |

Every one was invisible **precisely because it was green**. A red check gets
fixed; a green one that inspects nothing is trusted for years.

Three habits follow, and they are cheap:

1. **Make a check report what it inspected** — a count, a list, the command it
   ran. `21 files scanned` and `54 files verified` are what turn a silent glob
   failure into an obvious one. A gate that cannot say what it looked at is not
   a gate.
2. **Gate on exit status, not on matching text.** `grep -q "ok"` asks whether a
   reassuring word appeared. `if output=$(go test ./lib/...)` asks whether it
   passed.
3. **A check that cannot run must fail, never pass.** If the tool is missing,
   the glob matched nothing, or the flag was rejected, that is a FAIL. Silence
   is not success.

When you add or touch a gate, prove it fails: break the thing on purpose, watch
it go red, then fix it back. Several of the above would never have shipped if
anyone had done that once.
