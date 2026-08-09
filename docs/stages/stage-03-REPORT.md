# Stage 03 REPORT — Oracle first-boot preferences (hostname, timezone, shell)

- **Branch:** `stage-03-oracle-preferences`
- **Base commit:** `b6b7489` (`main` at launch; the worktree was created from
  `38d2e25` and fast-forwarded to `b6b7489` before anything was measured)
- **Commit message:** `feat(oracle): first-boot preferences for hostname, timezone and shell`
- **Push:** attempted — see [Push](#push).

---

## What changed, per file

| File | Change |
|---|---|
| `oracle/postinstall/preferences.scm` | **new.** The interactive script: resolves the config, prompts on `/dev/tty`, validates, edits a temp copy, backs up, writes back, offers reconfigure. |
| `oracle/postinstall/preferences_purpose.txt` | **new.** Reasoning per section, including the three required omissions. |
| `oracle/tests/test-oracle-preferences.scm` | **new.** 61 checks covering the 10 enumerated tests. Fully offline. |
| `lib/guile-config-helper.scm` | **+353 lines, 0 deletions.** Gexp reader, generic record-field accessors, pure transforms, three new subcommands. |
| `oracle/postinstall/README.md` | **+44 lines, 0 deletions.** New "First: your host name, timezone and shell" section. |
| `run-tests.sh` | **+14 lines, 0 deletions.** Registers the suite beside the Oracle capacity block. |

The whole diff is **411 insertions, 0 deletions**. Nothing existing was removed
or rewritten — relevant to guardrail 7 and to the "new subcommands only"
constraint on the helper.

### The three new subcommands

```
guile-config-helper.scm set-host-name    CONFIG-FILE HOST-NAME
guile-config-helper.scm set-timezone     CONFIG-FILE TIMEZONE
guile-config-helper.scm set-login-shell  CONFIG-FILE USER SHELL
```

Each is a thin CLI over a pure function. The transformation layer the tests
assert on directly:

```
set-os-host-name    os-expr host-name          -> os-expr
set-os-timezone     os-expr timezone           -> os-expr
set-os-login-shell  os-expr user-name shell    -> os-expr   ; shell field AND package
config-set-host-name / config-set-timezone / config-set-login-shell
                    exprs  ...                 -> exprs     ; adds use-modules
```

---

## Checklist echo

| # | Enumerated test | Status |
|---|---|---|
| 1 | Hostname rewrites `(host-name ...)` and nothing else | pass |
| 2 | Timezone rewrites `(timezone ...)` and nothing else | pass |
| 3 | zsh adds `(shell (file-append zsh "/bin/zsh"))` | pass |
| 4 | zsh also adds `zsh` to system `packages` | pass (+ `(gnu packages shells)` import) |
| 5 | bash writes **no** `shell` field, removes one if present | pass |
| 6 | An unchanged preference leaves the config byte-identical | pass (asserted on **bytes**, not S-expressions) |
| 7 | Result reads back as one well-formed `operating-system` | pass (+ gexp round-trip stability) |
| 8 | Missing field inserted or refused, never silently dropped | pass (5 insert cases, 4 refusal cases) |
| 9 | Original file untouched when the edit fails | pass (byte comparison after 2 distinct failures) |
| 10 | ASCII only, no octal-escaped ANSI introducer | pass (4 files) |

Other prompt requirements:

- Guile only, extending `lib/guile-config-helper.scm` — yes. **No `sed` path** was
  added; none was removed.
- ASCII only, `"\x1b["` never octal — yes, enforced by test 10 over
  `preferences.scm`, `guile-config-helper.scm`, the test itself, and the purpose
  file.
- All prompts read `/dev/tty` — yes, enforced by test 10.
- Config never edited in place — yes, temp copy + write-back, at two layers.
- Reconfigure offered, never automatic — yes, `[y/N]` defaulting to **no**.
- User rename out of scope — not implemented; reasoning in the purpose file
  section 1 and in `preferences.scm --help`.
- `oracle/image/oracle-image.scm`, `SOURCE_MANIFEST.txt`, `CHECKLIST.md` — untouched.

---

## Gates

### Gate 1 — `lib/validate-before-deploy.sh --verbose`

**Baseline (b6b7489, unmodified):** exit 0

```
=== Validation Summary ===
Passed:   6
Warnings: 15
Failed:   0

[WARN] VALIDATION PASSED WITH WARNINGS
```

**Final:** exit 0

```
Checking for common anti-patterns...
[WARN] Found direct os.Stdin usage (should use /dev/tty for user input)
[WARN] Found 'done < file' pattern (may consume stdin, use process substitution)

=== Validation Summary ===
Passed:   6
Warnings: 15
Failed:   0

[WARN] VALIDATION PASSED WITH WARNINGS
Review warnings before deploying
```

Identical to baseline. **No new warnings introduced.** `Failed: 0` as required.

### Gate 2 — `./run-tests.sh`

**Baseline:** exit 0, with the inherited `14/14 converted-script tests failing`.

**Final:** exit 0

```
399:Testing the Oracle image configuration
411:✓ Oracle image config tests passed
444:[OK] Oracle capacity handling tests passed
531:[OK] Oracle preference tests passed
637:⚠ Converted script tests: 14/14 failed
```

Converted-script failures unchanged at 14/14 — inherited, deliberately
non-gating, not touched.

### Gate 3 — `guile --no-auto-compile -s oracle/tests/test-oracle-preferences.scm`

exit 0

```
10. Readable over the OCI serial console
  [OK]   preferences.scm is ASCII only
  [OK]   preferences.scm uses no octal ANSI escape
  [OK]   guile-config-helper.scm is ASCII only
  [OK]   guile-config-helper.scm uses no octal ANSI escape
  [OK]   test-oracle-preferences.scm is ASCII only
  [OK]   test-oracle-preferences.scm uses no octal ANSI escape
  [OK]   preferences_purpose.txt is ASCII only
  [OK]   preferences_purpose.txt uses no octal ANSI escape
  [OK]   preferences.scm prompts on /dev/tty
  [OK]   preferences.scm never reads (current-input-port) for prompts
  [OK]   preferences.scm offers reconfigure rather than assuming it

All 61 oracle preference checks passed!
```

### `git diff b6b7489 --stat`

```
 lib/guile-config-helper.scm  | 353 +++++++++++++++++++++++++++++++++++++++++++
 oracle/postinstall/README.md |  44 ++++++
 run-tests.sh                 |  14 ++
 3 files changed, 411 insertions(+)
```

plus three untracked new files (`preferences.scm`, `preferences_purpose.txt`,
`test-oracle-preferences.scm`), all inside the whitelist.

---

## The thing the prompt did not anticipate

**Guile's stock reader cannot read any real Guix config.**

```
oracle/image/oracle-image.scm:89:9: Unknown # object: "#~"
```

`#~` / `#$` / `#$@` / `#+` / `#+@` are reader macros installed by `(guix gexp)`,
which a plain `guile -s` has never loaded. The existing helper's `read-config`
hits this on the very file this stage exists to edit, so "extend the existing
machinery" was not sufficient on its own — without a fix, every subcommand would
abort on a real instance before the first assertion mattered.

The fix reads them into the forms Guix itself expands them to — `#~x` *is*
`(gexp x)` — so gexps survive the read/write round trip as ordinary
S-expressions and the written config still evaluates. It is installed **on
demand, from the new subcommands only**, so `add-service`, `check-service` and
`switch-to-desktop` keep byte-for-byte the behaviour they had.

See Deviation 1.

---

## Deviations

1. **A gexp reader was added to `lib/guile-config-helper.scm`, which is more
   than "new subcommands only."** Justification above: without it the new
   subcommands cannot parse the file they exist to edit. Scope was minimised —
   `install-gexp-reader!` is called only from `read-config/gexp`, which only the
   new subcommands use; `read-config` and `write-config` are unmodified; the
   diff has zero deletions. A reviewer who disagrees can revert exactly one
   function and three call sites, at the cost of the feature not working.

2. **Test 10 as literally worded is self-defeating, and I changed the wording,
   not the strictness.** "contains no `\033[`" fails on any file that *mentions*
   the sequence in prose — including the check's own needle, which matched
   itself. Resolved by assembling the needle at run time
   (`(string-append "\\" "033[")`) and rewording the three prose mentions to
   describe the escape instead of spelling it. The check still rejects any
   literal occurrence anywhere in the file; only my ability to document it
   changed.

3. **The suite has 61 checks, not 10.** The 10 enumerated tests are all present
   and all pass; the rest are additional cases within the same categories
   (variable-named accounts, package-list shapes, gexp round-trip stability).
   Additive only — no enumerated test was weakened or merged away.

4. **`preferences.scm` uses privilege only when needed.** The first draft ran
   every `cp`/`chmod` through `sudo` unconditionally. That prompts for nothing
   when the target is a temp file, and it made the whole apply path impossible
   to exercise without privileges. Changed to `run-for-target`, the same
   "writable? then plain, else sudo" shape `postinstall/lib.scm` already uses.
   This is in a new file, so it is not an allow-list deviation, but it is a
   design decision made mid-stage and worth a reviewer's eye.

5. **The prompt does not name a branch.** Used `stage-03-oracle-preferences`,
   following the stage numbering. Rename freely.

6. **Switching a non-bash shell back to bash leaves the shell's package in
   `packages`.** Deliberate: removing a package the user may by then depend on
   is destructive (guardrail 7), and an unused package costs disk, not a login.
   Documented in `preferences_purpose.txt` §4 and asserted by test 5.

7. **Editing the config loses its comments.** `write-config` pretty-prints the
   parsed form, so the whole file is reflown. This is pre-existing behaviour
   that `add-service` and `switch-to-desktop` already have, and it is the price
   of not using `sed`. Mitigated by a timestamped backup before every write and
   by writing nothing at all when nothing changed. Not a regression, but it is
   the change a user will most notice, so it is in the README, the purpose file,
   and here.

8. **`preferences.scm` cannot be run from a bare pipe**, unlike its sibling
   `postinstall/recipes/add/personal-config.scm`, whose one-liner the same
   README advertises. It shells out to the helper, which must exist on disk. It
   searches `GUIX_PLATFORM_INSTALL_ROOT`, `INSTALL_ROOT`, two directories up,
   `$PWD` and `~/guix-platform-install`, and prints the clone command rather
   than failing on an `open()`. Downloading the helper was rejected — see Open
   questions 1.

---

## Verification beyond the test suite

The suite is offline by mandate, which leaves the riskiest claim — *does the
rewritten config still build?* — outside it. Checked by hand:

1. **The real `oracle/image/oracle-image.scm`**, gexps and all, copied to `/tmp`
   and run through `apply-preferences` (host name `my-oracle-box`, timezone
   `Europe/Berlin`, shell `fish`), then evaluated with `guix repl`:

   ```
   OS-OK
   my-oracle-box
   Europe/Berlin
   shell: #<file-append #<package fish@4.7.1 gnu/packages/shells.scm:137> "/bin/fish">
   ```

   The `fish` variable resolved, which means the `(gnu packages shells)` import
   was added correctly and the `file-append` points at a real package.

2. **This workstation's own `/run/current-system/configuration.scm`** — an
   unrelated 25 KB config, much larger than the Oracle one — copied to scratch
   and edited successfully:

   ```
   [OK] Configuration updated
   76: (host-name "probe-host")
   ```

3. **The store-path permission claim**, which the recovery branch depends on:

   ```
   -r--r--r-- 2 root root 25498 /gnu/store/v5x...-configuration.scm
   -r--r--r-- 1 durant users 25498 (after cp -L)
   ```

   Mode 444, inherited by the copy. The `chmod 644` in `ensure-config-file` is
   genuinely load-bearing, not defensive.

4. `preferences.scm --help`, and every detection/validation function
   (`valid-host-name?`, `timezone-status`, `zoneinfo-directory`,
   `current-*`, `find-config-helper`), exercised on this machine.

Nothing in this section touched `/etc/config.scm`.

---

## Unverified claims

Required section. Guardrail 10 — none of the following is upgraded to "works".

- **The reconfigure path was never executed. At all.** Not by the suite (by
  design), and not by hand. `guix system reconfigure` has not been run against a
  config this code produced. What is verified is one step short of it: the
  produced config evaluates to an `<operating-system>` under `guix repl`.
  Evaluation is not a build, and a build is not a boot.
- **`ensure-config-file`'s recovery branch is untested.** This machine has both
  `/etc/config.scm` and `/run/current-system/configuration.scm`, so branch 1 is
  what runs here; exercising branch 2 would mean writing to the real
  `/etc/config.scm`, which the stage forbids. Its two component claims were
  verified separately (the store path is 444; `cp -L` inherits that), but the
  branch as a whole has not run.
- **The `sudo` path never ran.** Every target in testing was already writable, so
  `run-for-target` took the direct branch every time. The passwordless-wheel
  assumption from `oracle-image.scm` is inherited, not demonstrated.
- **Nothing has run on a real Oracle instance.** Specifically untested there:
  whether `/etc/config.scm` is in fact absent on the published image (the whole
  motivation for the recovery branch); how the output looks on the OCI serial
  console (asserted only as ASCII, never observed); and whether a reconfigure on
  1 GiB of RAM completes rather than OOMs.
- **`current-host-name` / `current-timezone` / `current-login-shell` were
  verified on this Guix workstation, not on an instance.** `zoneinfo-directory`
  resolved to a real tzdata store path here; a minimal Oracle image may lay that
  out differently, in which case timezone validation degrades to a `[WARN]` and
  accepts — the intended fallback, but that fallback has not been observed
  firing.
- **The gexp reader is verified against exactly two real configs** (the Oracle
  image and this workstation's). It handles `#~ #$ #$@ #+ #+@`; a config using a
  reader extension from some other module would still fail to parse, and would
  do so before writing anything.

---

## Open questions

Noticed, deliberately not acted on.

1. **Should `preferences.scm` regain the one-liner?** The sibling recipe is
   `wget | guile -s /dev/stdin`; this one needs a clone. Restoring parity means
   fetching and executing code over the network from a script whose job is
   editing `/etc`, and it should go through the same manifest verification
   `bootstrap-installer.sh` does — more than this stage should decide alone.

2. **`run-tests.sh` line 49 uses `return 1` outside a function**, in the
   pre-existing Guile-config-helper block. If those tests ever fail, that is a
   runtime error rather than the intended non-zero exit; the Oracle blocks below
   it correctly use `exit 1`. Not touched — outside this stage's remit even
   though the file is in the allow-list.

3. **`oracle/scripts/03-smoke-test.scm` is named in the prompt's motivation** as
   the reason preferences are QEMU-exercisable, but it is not in the allow-list
   and this stage added nothing to it. Wiring a preferences run into the smoke
   test would close most of the Unverified list without needing OCI.

4. **Comment preservation.** Deviation 7 is now the third feature to inherit
   pretty-print's reflow. A reader that retains comments (or a targeted
   splice-back-into-original-text writer) would benefit `add-service` and
   `switch-to-desktop` equally, and would make the backup a convenience rather
   than a necessity.

5. **`SOURCE_MANIFEST.txt` is unchanged and validation reports it up to date** —
   the manifest covers `bootstrap-installer.sh` and `**/install/*.{go,sh}`, none
   of which this stage touched. Per `docs/stages/README.md` the coordinator
   regenerates it after merge; flagging it so that is a decision rather than an
   oversight.

6. **`docs/ORACLE_ONE_CLICK_ROADMAP.md` step 4 and `CHECKLIST.md`** are not
   updated — both are coordinator-owned and outside the allow-list.

---

## Push

`git push -u origin stage-03-oracle-preferences` **succeeded**, which the stage
protocol did not expect (credentials are usually absent in the sandbox):

```
remote: Create a pull request for 'stage-03-oracle-preferences' on GitHub by visiting:
remote:      https://github.com/durantschoon/guix-platform-install/pull/new/stage-03-oracle-preferences
To github.com:durantschoon/guix-platform-install.git
 * [new branch]      stage-03-oracle-preferences -> stage-03-oracle-preferences
branch 'stage-03-oracle-preferences' set up to track 'origin/stage-03-oracle-preferences'
PUSH_EXIT=0
```

No PR was opened, nothing was pushed to `main`, and nothing was merged.

**One thing the coordinator must know.** The push happened while this report
still carried a `PUSH_RESULT_PLACEHOLDER`, because the result could not be known
until after the commit existed. Fixing it required amending the single stage
commit, so **the remote branch is one commit behind the local one**, and the two
differ *only* in this section of this file.

Resolving it needs a force-push, which an executor is not permitted to do. The
local branch in this worktree is the correct one — review and merge from there.
To refresh the remote first:

```sh
git push --force-with-lease origin stage-03-oracle-preferences
```

The stale remote commit is `ad07250`; the correct one is the current tip.
