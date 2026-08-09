# Stage 04 — Preserve comments and gexp syntax in config edits

## Motivation (measured)

`lib/guile-config-helper.scm` reads a config with `read` and writes it back with
`pretty-print`. Guile's reader **discards comments**, so every edit silently
strips them. Running any subcommand on `oracle/image/oracle-image.scm` destroys
all 134 comment lines — in a repo whose whole documentation convention is that
non-obvious decisions are explained where they live.

Stage 03 added a second problem while working around a third: Guile's stock
reader cannot parse `#~`/`#$`/`#+` at all (`Unknown # object: "#~"`), so it
installed a `read-hash-extend` mapping them to `(gexp …)` / `(ungexp …)`. That
works, but the written config then *spells* gexps as `(gexp …)`, which is
correct and unidiomatic.

**All three problems have one upstream answer.** Guix ships `(guix read-print)`
— the module behind `guix style` — with `read-with-comments`,
`pretty-print-with-comments`, `comment?`, `blank?` and `comment->string`.
Comments become **nodes in the tree**, so they travel with the code instead of
being reattached afterwards.

Measured on the real `oracle/image/oracle-image.scm` (2026-08-08):

```
top-level items read: 106   (73 of them comments)

  ';;' comment lines                     orig=134  roundtrip=134
  the 'dd rather than fallocate' comment orig=  1  roundtrip=  1
  #~ gexp syntax                         orig=  3  roundtrip=  3
  #$ ungexp syntax                       orig= 13  roundtrip= 13
```

Availability was checked, not assumed: the module resolves from
`/run/current-system/profile/share/guile/site/3.0/guix/read-print.scm` — the
**system** profile — and loads under **bare `guile`**, no `guix repl` needed.
`guix` is in `%base-packages`, so a fresh install and the Oracle image both have
it. No caller's invocation has to change.

## The change

Migrate `lib/guile-config-helper.scm` to `(guix read-print)`:

1. `read-config` uses `read-with-comments`; `write-config` uses
   `pretty-print-with-comments`.
2. **Delete `install-gexp-reader!` and its `read-hash-extend` calls**, and the
   `read-config/gexp` variant. `(guix read-print)` handles gexps natively, so
   that code is dead. This is an explicit instruction to remove it — guardrail 7
   does not apply here.
3. All six subcommands (`add-service`, `check-service`, `switch-to-desktop`,
   `set-host-name`, `set-timezone`, `set-login-shell`) preserve comments and
   `#~` syntax.
4. Fail with a clear message if `(guix read-print)` is unavailable, rather than
   crashing with `no code for module`.

### THE HAZARD — read this twice

Comment and blank nodes are now **interleaved among the fields**. Every
structural `match` in the file assumes they are not. For example:

```scheme
(match os-expr
  (('operating-system fields ...)     ; <- 'fields' now contains <comment> records
```

Anything that iterates, counts, matches positionally, or rebuilds a form must
treat `comment?` and `blank?` nodes as **pass-through**: skipped when
inspecting, preserved when rebuilding, and kept in their original relative
position. A transformation that drops them re-introduces exactly the bug this
stage removes; one that mistakes a comment for a field will corrupt the config.

Audit **every** `match` in the file, not just the ones you touch.

## Ground rules

- Guile only. ASCII only. `"\x1b["`, never `"\033["`. `/dev/tty` for input.
- Never edit in place — temp copy, write back on success.
- The existing subcommands' behaviour must not change apart from preservation.
  `postinstall/tests/run-guile-tests.sh` (tests 1-6) and
  `oracle/tests/test-oracle-preferences.scm` (61 checks) must still pass
  **unmodified**, unless an assertion was specifically about output that only
  looked that way because comments were being lost — in which case say so
  explicitly in the report.
- Do not change how any caller invokes the helper.

## Allowed files (whitelist)

```
lib/guile-config-helper.scm
lib/guile-config-helper_purpose.txt          (new)
lib/tests/test-config-helper-comments.scm    (new)
run-tests.sh                                 (registration; this stage owns it)
oracle/tests/test-oracle-preferences.scm     (ONLY if an assertion depended on
                                              comment loss; justify in report)
```

Do not touch `oracle/image/oracle-image.scm`, `oracle/postinstall/*`,
`SOURCE_MANIFEST.txt`, or `CHECKLIST.md`.

## Tests (enumerated — all required)

New `lib/tests/test-config-helper-comments.scm`, Guile, offline, modelled on
`oracle/tests/test-oracle-preferences.scm`. Operate on **copies** in a temp
directory; never touch the real configs.

Use `oracle/image/oracle-image.scm` as the fixture — it is the hard case
(gexps, 134 comment lines, a nested shepherd service):

1. `set-host-name` preserves all 134 `;;` comment lines.
2. `set-timezone` preserves them.
3. `set-login-shell` preserves them.
4. `add-service` preserves them.
5. `switch-to-desktop` preserves them (use a fixture it applies to).
6. `#~` count is unchanged after every subcommand — gexps stay spelled `#~`,
   not `(gexp …)`.
7. `#$` count likewise.
8. The specific comment `dd rather than fallocate` survives, **and is still
   adjacent to the `dd` call it explains** — a comment preserved but relocated
   is worse than one deleted.
9. The edited config still evaluates to an `<operating-system>` (via
   `guix repl`, as `oracle/tests/test-oracle-image.scm` does).
10. An unchanged edit is a no-op: setting a field to its current value leaves
    the file byte-identical.
11. `install-gexp-reader!` / `read-hash-extend` no longer appear in the source.
12. The file is ASCII only and contains no `\033[`.

Register in `run-tests.sh` beside the other suites, guarded by
`command -v guile`.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
guile --no-auto-compile -s lib/tests/test-config-helper-comments.scm   # exit 0
```

Inherited baseline — do not "fix": validation Passed 6 / Failed 0 / ~15
warnings; `run-tests.sh` exit 0 with 14/14 converted-script tests failing.

`lib/guile-config-helper_purpose.txt` is required and must record: why
`(guix read-print)` rather than a sidecar comment file (the keying problem — a
comment's address is a text position, and S-expression editing exists precisely
because positions do not survive; a misplaced comment is worse than a dropped
one), why the gexp reader was deleted, and the comment/blank pass-through rule
for future editors.

## Commit message (exact, single line)

```
fix(config): preserve comments and gexp syntax when editing configs
```

## Report requirements

`docs/stages/stage-04-REPORT.md`: what changed per file; pasted gate output;
**a before/after excerpt of a real edited config** showing comments and `#~`
surviving; every `match` you audited and what you did about interleaved nodes;
deviations; open questions; and an **Unverified claims** section.

## Blocked protocol

If preservation turns out to be impossible for some subcommand without changing
its behaviour, or if `(guix read-print)`'s API cannot express something needed —
**stop and write the REPORT with a `Blocked:` section**, including the specific
form that defeated it. Do not fall back to the old reader silently.
