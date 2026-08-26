# Guix Installer Implementation Checklist

This checklist tracks remaining work for the guix-platform-install project.

## 📋 How to Update This Checklist

**When completing an item:**
1. Move the completed item to [archive/CHECKLIST_COMPLETED.md](archive/CHECKLIST_COMPLETED.md) (newest at top)
2. Remove it from the active checklist sections below
3. Update the "Latest Completed Items" section below with the 3 most recent completions
4. Keep the active checklist focused on **remaining work only**

**Format for archive:**
- Use date headers (YYYY-MM-DD) for grouping related completions
- List items with ✅ checkmarks
- Include context/notes when helpful
- Keep newest items at the top

**For implementation history and completed features, see:**
- [archive/CHECKLIST_COMPLETED.md](archive/CHECKLIST_COMPLETED.md) - All completed items (newest first)
- Git commit history
- [docs/INSTALLATION_KNOWLEDGE.md](docs/INSTALLATION_KNOWLEDGE.md) - Hard-won lessons and fixes
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Debugging guides
- Individual platform README files
- [**docs/dev/2026-01-WORKLOG.md**](docs/dev/2026-01-WORKLOG.md) - Active Flight Recorder (Latest Status)

---

## ✅ Latest Completed Items

**Most Recent:**
1. ✅ **Personal Configuration Contract — Postinstall Step One (2026-08-08)**: A platform installer stops at "the machine boots", which is correct but leaves a gap the user crossed by hand on every new machine. `postinstall/recipes/add/personal-config.scm` closes it in one command that assumes nothing is installed: `wget -qO- <raw-url> | guile --no-auto-compile -s /dev/stdin`. That pipe is only safe because every prompt reads `/dev/tty` — stdin is the script itself (verified on Guile 3.0.11). **The constraint that shaped it:** a fresh Guix System's `%base-packages` has `guile`, `wget` and `nss-certs` but **no `git`, `curl`, `gnu-make` or OpenSSH client**, so the script provisions them into the *user profile* (`guix install`, seconds, no root) rather than the system config (minutes, and on the 1 GiB Oracle micro it is what the swap file exists for). What runs is declared by a `guix-personal.scm` at the root of the user's OWN repository — no URL, username or Makefile target is hardcoded here, which is how [docs/PERSONAL_CONFIG_CONTRACT.md](docs/PERSONAL_CONFIG_CONTRACT.md) holds `CLAUDE.md`'s generic-vs-known-good line while still making step two one command. The parser rejects unknown keys **deliberately**: a lenient one drops a typo'd `(require "git")` silently, and the consequence surfaces on a machine reachable only by serial console. Two real bugs caught by its own `--self-test`: `url-host` used `(or (string-index s #\/) (string-index s #\:))`, which yields the first index that *exists* rather than the smallest, so `ssh://git@host:2222/path` returned `host:2222` — unresolvable by `ssh-keyscan`; and `"\033["` is **not an octal escape in Guile** (it reads as NUL + `"33"`, so the colour never applies and a NUL byte goes to the terminal on every message — the correct form is `"\x1b["`). 35 checks in `postinstall/tests/test-personal-config.scm`, itself Guile per the language policy.
2. ✅ **Known-Good Artifacts Separated from the Generic Installer (2026-08-05)**: Added `known-good/`, holding configurations that demonstrably booted a real machine, captured from that machine's own `provenance-service-type` record — `configuration.scm`, `channels.scm` and `provenance`, straight out of the system closure. That is a stronger claim than the copy in someone's home directory, which drifts the moment it is edited for the next attempt; the closure's copy is immutable and is what the kernel actually booted. **Capture is time-sensitive:** a generation's provenance lives only in that generation, so `guix gc` or `delete-generations` destroys it. `known-good/capture-provenance.scm` (Guile, per the language policy — `guile-3.0-latest` is in `%base-packages`) copies the three files, refuses to overwrite an existing capture, and emits an `ATTESTATION.md` stub whose human-checkable questions stay as explicit `?` rather than a template that gets filled with "works". `--from` also captures a target mounted elsewhere, e.g. mid-install at `/mnt/guixroot`. The separation is now a rule in `CLAUDE.md`: one-machine answers (login shell, keymap, FHS shim) go to `known-good/` or `guix home`; their generalization goes to the installer as a prompt, which is the R1-R4 roadmap below.
3. ✅ **Documentation Voice and Dormant Goals (2026-08-05)**: [docs/STORY.md](docs/STORY.md) tells the repin saga as narrative — a pin that could not work because the silicon postdated it, four symptoms read as four problems, a workaround that became the cause while silently dropping an unrelated upstream fix, a system with no supported path to change itself, and one of two required settings applied confidently. [docs/DORMANT_GOALS.md](docs/DORMANT_GOALS.md) records six intentions the repo stated and stopped acting on, recovered from git history: the 90/10 narrative ratio (stated 2025-11-25 in `cdc475e`, then existing **only in that commit message** for eight months while the doc it governed was edited ten more times), Guile conversion Phase 3, reviewer personas never offered at any milestone including first boot, time-tracking retrospectives, retry statistics, and a console-font TODO now cheap to close. The ratio is codified in `CLAUDE.md` — the fix for a goal lost precisely because it was never written there.
4. ✅ **Postinstall Desktop Switch Fixed (2026-08-03)**: `add_desktop` used to `sed` `%base-services` → `%desktop-services` and stop. `%desktop-services` is a **superset**, so the network-manager/wpa-supplicant/dbus/polkit/ntp that a minimal config lists explicitly then existed twice — verified against a real framework-dual config, the build fails with `more than one target service of type 'dbus'`. Worse, the old warning told you to delete the explicit NetworkManager, which would silently take its DNS block with it. Replaced with `guile-config-helper.scm switch-to-desktop`, which works on parsed S-expressions: it switches the base, drops services the new base provides, and rewrites any that carried a configuration record into `modify-services` clauses with `(inherit config)`. Guarded by Test 6 in `postinstall/tests/run-guile-tests.sh`, confirmed to fail against the old sed-only output.
5. ✅ **DNS That Survives a Reconnect (2026-08-03)**: The generated config ships `[global-dns-domain-*]` to `/etc/NetworkManager/conf.d/dns.conf` via the service's `extra-configuration-files` field, so a fresh install has working name resolution before anyone logs in. Found on hardware: after a reboot the machine had connectivity but an unusable `/etc/resolv.conf`, so `guix pull` died in `getaddrinfo` — **and reported the nonguix channel as untrusted**, because a channel introduction is verified against the `keyring` branch of a repo that could not be cloned. One fault, two messages, and the louder one sends you auditing signing keys. Hand-editing `resolv.conf` is only a reprieve; NetworkManager rewrites it on re-association. **Tradeoff:** this overrides DHCP-supplied servers, so split-horizon DNS breaks — opt-out documented in `03-config-dual-boot_purpose.txt`. Guarded by `TestGenerateMinimalConfig_DNS`; diagnosis ladder in [docs/RECOVERY_REBUILD_FROM_HOST_OS.md](docs/RECOVERY_REBUILD_FROM_HOST_OS.md).

**Superseded:**
- ❌ **Framework-dual Kernel Args Restore (2025-12-31)**: Restored `nomodeset`, `noapic`, `nolapic` after a refactor dropped them. **Reversed on 2026-08-01** — the refactor had been closer to correct. Those arguments were a misdiagnosis, not a hardware workaround. See item 1 above.

**See [archive/CHECKLIST_COMPLETED.md](archive/CHECKLIST_COMPLETED.md) for full history.**

---

## 🔄 Currently Working On

### Oracle disposable Guix validation

- Restart checkpoint: `docs/ORACLE_VALIDATION_CHECKPOINT.md` (update after
  every meaningful live-cloud action)
- Staged plan: `docs/ORACLE_VALIDATION_STAGES.md`
- ✅ Mixed planner/executor policy recorded in `MODEL.md`
- ✅ Stage 0 metadata-only SSH probe implemented with offline coverage
- ✅ OV-0 controller foundation and measured live failure preserved; diagnostic
  instance and boot volume terminated
- ✅ OV-1 reliable guest metadata-key installation: bounded retry, serial
  outcomes, permission enforcement, offline coverage, and OCI client timeouts
- ⏳ OV-2 live metadata-only SSH acceptance (active: build/import revised
  generic image, update `.env`, run `make oracle-stage0`)
- ✅ Stage 1 one-shot snapshot/upload/run/log/terminate controller implemented
  with offline coverage
- ⏸ OV-3 executable `IN_TEST` ownership gate
- ⏸ OV-4 Stage 1 live passing and failing validation runs
- ⏸ OV-5 resilient telemetry, reconnect/replay, and console capture
- ⏸ OV-6 handoff and operational hardening

**Primary Focus: Cloudzy Installation Testing**

### Cloudzy Installation Testing (CURRENT PRIORITY)
**Focus**: Verify kernel symlink fix and recovery tool work correctly

**Recent Fixes:**
- ✅ **3-step kernel/initrd workaround implemented for Cloudzy (2025-12-17)**: Kernel tracking logs confirmed that `guix system init` (free-software-only) does NOT create kernel/initrd files - system generation only contains `['gnu','gnu.go','guix']`. Re-introduced 3-step workaround (build → copy → init) for Cloudzy, same as framework-dual.
- ✅ **Kernel tracking parity implemented (2025-12-17)**: Framework-dual now has comprehensive kernel tracking instrumentation matching cloudzy. See [docs/KERNEL_TRACKING.md](docs/KERNEL_TRACKING.md) for details.
- ✅ Kernel/initrd copying now uses `cp -L` to dereference symlinks
- ✅ Recovery tool rewritten in Go to share code with installer
- ✅ Network/DNS troubleshooting documented

**Next Steps:**
1. 🧪 **Test kernel symlink fix on Cloudzy VPS**
   - Run installer on fresh Cloudzy instance
   - Verify kernel files are copied correctly (should be 5-15 MB, not a few bytes)
   - Verify system boots successfully after installation
   - Check `/tmp/kernel_tracking.log` for kernel file journey traces (see [docs/KERNEL_TRACKING.md](docs/KERNEL_TRACKING.md) for how to analyze logs)

2. 🧪 **Test Go recovery tool**
   - Trigger recovery scenario (interrupt installer or simulate failure)
   - Verify recovery tool builds correctly during installation
   - Test recovery tool functionality (mount verification, system init, password setting)
   - Verify automatic retry logic works (up to 3 attempts)

3. 🧪 **Test network configuration**
   - Verify NetworkManager starts correctly after installation
   - Test DNS resolution (`ping ci.guix.gnu.org`)
   - Test `guix install` commands work after network is configured
   - Run `diagnose-guix-build.sh` to verify all checks pass

**Status**: Ready for testing - 3-step workaround implemented for Cloudzy, all fixes documented

**Key Discovery (2025-12-17):**
- Kernel tracking logs showed `guix system init` succeeds but system generation only contains `['gnu','gnu.go','guix']` - no kernel/initrd files
- This confirms the bug affects BOTH free-software-only (Cloudzy) and nonguix (Framework) installations
- Solution: Use 3-step workaround for all platforms (build system → manually copy kernel/initrd → install bootloader)

### Front 1: Framework-dual (Testing & Development)
**Focus**: Real-world installation testing, GNOME configuration, troubleshooting

**Status**: See "Framework-dual postinstall (IN TESTING)" section below

### Front 2: Cloudzy (Guile Conversion & Testing)
**Focus**: Complete conversion to `.scm` scripts and comprehensive testing

**Guile Conversion Project (IN PROGRESS):**

See [docs/GUILE_CONVERSION.md](docs/GUILE_CONVERSION.md) for comprehensive plan.

- ✅ Phase 1: Library infrastructure complete → [See archive](archive/CHECKLIST_COMPLETED.md#guile-conversion-project---phase-1-2025-11-15)
- ✅ Phase 2: Update postinstall scripts to use Guile helper → [See archive](archive/CHECKLIST_COMPLETED.md#guile-conversion-project---phase-2-2025-11-15)
- ✅ Phase 3: All scripts converted (20 total) → See "Batch Conversion System" section below
- ✅ **Phase 4: Cloudzy Deployment** (IN PROGRESS - 2025-12-18)
  - ✅ Deployed `postinstall/lib.scm` (converted from `postinstall/lib.sh`)
  - ✅ Deployed all recipe scripts to `postinstall/recipes/add/` (development, fonts, spacemacs, doom-emacs, vanilla-emacs)
  - ✅ Converted `cloudzy/postinstall/customize` to `cloudzy/postinstall/customize.scm`
  - ✅ Updated `lib/common.go` to download `.scm` version for cloudzy platform
  - ⏳ **Remaining**: Test converted scripts on actual Cloudzy VPS installation
  - ⏳ **Remaining**: Remove original `.sh` files after successful testing
  - **Goal**: Complete Guile conversion for cloudzy platform

- ✅ Batch Conversion Tools (COMPLETED) → [See archive](archive/CHECKLIST_COMPLETED.md#batch-conversion-tools-improvements-2025-11-15)

**Testing Strategy:**

- ✅ **Guile (.scm) scripts**: Fully tested in Docker + run-tests.sh → [See archive](archive/CHECKLIST_COMPLETED.md#testing-infrastructure-2025-11-15)
- ⏸️ **Shell (.sh) scripts**: Not actively testing, will migrate to Guile

**Framework-dual postinstall (IN TESTING):**

- ✅ All fixes complete → [See archive](archive/CHECKLIST_COMPLETED.md#framework-dual-postinstall-improvements-2025-11-15)
- ✅ Bootstrap script fixes → [See archive](archive/CHECKLIST_COMPLETED.md#recent-bootstrap--path-resolution-fixes-2025-11-15)
- ✅ GNOME launches successfully - display manager working
- ✅ **ROOT CAUSE IDENTIFIED**: GDM login loop is AMD GPU firmware issue, not authentication problem
  - TTY login works perfectly
  - GDM accepts password but drops back to login because GNOME session fails to start
  - `dmesg` shows: `Direct firmware load for amdgpu/psp_14_0_4_toc.bin failed with error -2`
  - ~~Issue: Current guix/nonguix master commits don't provide working AMD firmware for Framework 13 AMD~~
  - **Corrected 2026-08-01**: the diagnosis was backwards. `psp_14_0_4` is the
    **Strix Point** PSP. This laptop is a Framework 13 **Ryzen AI 300**
    (`1002:1114`, gfx11.5), which shipped July 2024. Its firmware entered
    linux-firmware mid-2024 and gfx11.5 entered Linux 6.10. Recent master has
    the firmware; it was the *old* pin that lacked it.
- ❌ **FIX WAS WRONG**: Wingo-era channel pinning (2024-02-16)
  - Guix commit: `91d80460296e2d5a01704d0f34fb966a45a165ae`
  - NonGuix commit: `10318ef7dd53c946bae9ed63f7e0e8bb8941b6b1`
  - Those commits predate the hardware by ~5 months, so the pin **guaranteed**
    the `psp_14_0_4_toc.bin ... error -2` failure it was adopted to fix.
    Pinning backwards cannot supply firmware for hardware that did not exist.
  - Wingo's post is about the earlier **Ryzen 7040** Framework 13. The pin was
    valid there and was transferred without re-validating against this machine.
  - `framework-dual/wingolog-channels.scm` is retained for Ryzen 7040 only, with
    a warning header.
- ✅ **REPINNED (2026-08-01)**: recent commits, still pinned for reproducibility
  - Constants `FrameworkDualGuixCommit` / `FrameworkDualNonguixCommit` /
    `FrameworkDualPinDate` in `lib/common.go`
  - guix `df2d121208127ac22f10e0f7c2f38d6c74e106a3` (confirmed identical on
    Savannah and Codeberg), nonguix `73baab37361b3a81f326aa3fdec78840f5acc577`
  - At that pin `(kernel linux)` = `linux-7.1`, `linux-lts` = `linux-6.18`;
    both comfortably exceed the >= 6.10 requirement
  - Policy rewritten in `docs/CHANNEL_PINNING_POLICY.md`: pinning is for
    reproducibility, and the pin must always be **newer** than the hardware
- ⏳ **NOT YET TESTED ON HARDWARE**: needs a reinstall or reconfigure to confirm
  amdgpu binds and GDM accepts input
  - ✅ **ISO artifacts cleanup complete** → [See archive](archive/CHECKLIST_COMPLETED.md#iso-artifacts-cleanup-implementation-2025-11-20)
    - **Problem**: When copying `/var/guix` from ISO using rsync/cp, ISO's filesystem structure was copied
    - **Solution**: Added `CleanupISOArtifacts()` function to fix filesystem invariants after ISO copy
    - **Implementation**: Fixes `/var/run` → `/run` symlink, `/etc/mtab` symlink, removes ISO artifacts
    - **Integration**: Added to all mount steps (cloudzy, framework, framework-dual)
    - **Recovery scripts**:
      - `lib/fix-iso-artifacts.sh` - Quick symlink fixes
      - `lib/recover-filesystem-invariants.sh` - Complete recovery with system rebuild
    - **Status**: ✅ Complete - future installs automatically fix these issues
  - ✅ **D-Bus activation failure fixed** → Root cause was ISO artifacts copying `/var/run` as directory
    - **Status**: ✅ Fixed by ensuring `/var/run` is correct symlink before system init
    - **For existing installations**: Use `lib/recover-filesystem-invariants.sh` for complete recovery

**System Recovery Status (2025-11-23):**

### 🔄 **Fresh Start Approach - Clean Install Testing**

**Previous Recovery Attempts:**
- Original Problem: Guix install was built by rsync'ing the live ISO, causing deep structural issues:
  - `/run` was copied as a real directory instead of tmpfs
  - `/var/run` was copied as a directory instead of symlink
  - Stale ISO sockets and runtime files in `/mnt/run`
  - ISO artifacts in `/etc/machine-id`, `/etc/mtab`, `/var/guix`
  - Activation scripts copied from ISO and out of sync
  - Result: PAM failed, sudo failed, reconfigure failed, dbus complained, system didn't boot cleanly

**Recovery Lessons Learned:**
- ✅ `/run` can be correctly mounted as tmpfs (fixes ISO leftovers)
- ✅ `sudo -v` can work (confirms PAM, dbus, elogind, session services are healthy)
- ✅ ISO artifacts can be removed (`/etc/mtab`, `/etc/machine-id`, `/etc/resolv.conf`, `/var/guix` ownership, `/run` stale contents)
- ⚠️ **Could not prevent `/var/run` from returning as a directory**: Current Guix intentionally recreates `/var/run` as a directory during early boot cleanup phase. This is **normal and correct** for this version (symlink approach coming in future patch upstream), but caused issues with wingolog time-machine reconfigure

**Current Status: Boot Hang Diagnosis (Framework-Dual)**
- ✅ **Clean Install Completed**: Filesystem created successfully.
- 🚧 **Boot Hang**: System hangs on startup (suspected AMD GPU firmware/GDM issue).
- ✅ **Environment Fixes**: Solved `curl` SSL errors by correcting system clock (ISO defaults to 2025, real year is 2026).
- 🧪 **Next Step**: Chroot into system, check `/var/log/messages` for firmware errors, and apply "Wingo" channel fix (`guix time-machine`).

**Action Plan for Fresh Install Test:**

1. **Boot the Guix ISO**
2. **Run install script on empty GUIX_ROOT partition**
3. **Verify clean install creates correct filesystem structure:**
   - `/run` should be tmpfs (not a directory)
   - `/var/run` behavior should be correct from the start
   - No ISO artifacts should be present
   - System should boot cleanly
4. **Test wingolog time-machine reconfigure on clean install:**
   - Verify if `/var/run/dbus` directory issue still occurs
   - If needed, apply DNS and PATH fixes in chroot (see notes below)
5. **Document results** - Compare clean install behavior vs recovered rsync install

**Notes for Future Reference (if chroot fixes needed):**

**DNS Fix for Chroot:**
- Before entering chroot (on ISO shell):
  ```sh
  rm -f /mnt/etc/resolv.conf
  cp /etc/resolv.conf /mnt/etc/resolv.conf
  ```

**PATH Fix Inside Chroot:**
- After chrooting:
  ```sh
  SYSTEM=$(readlink -f /var/guix/profiles/system)
  export PATH="$SYSTEM/profile/bin:/run/setuid-programs:$PATH"
  hash -r
  ```

**Status:** Starting fresh with clean install test. Previous partition contents saved to external drive for reference.

**Bootstrap Command for Testing:**

```bash
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/lib/bootstrap-postinstall.scm | guile
cd ~/guix-customize
./customize
# Select option 2 (Add desktop), then option 1 (GNOME)
```

**What's Ready:**

- GNOME installation uses Guile S-expression parser (no more sed!)
- NetworkManager, SSH, and desktop services all use guile_add_service()
- Full checksum verification via SOURCE_MANIFEST.txt
- Platform auto-detection (framework-dual)
- All Guile tests passing in Docker
- Bootstrap script fixed (syntax errors, path resolution, Go detection)
- Hash-to-words conversion requires Go (fatal error if missing)
- Customize scripts properly resolve paths (symlink support, INSTALL_ROOT)
- postinstall/lib.sh functions correctly use INSTALL_ROOT
- Batch conversion tools ready for production use

*(For detailed completion history, see [archive/CHECKLIST_COMPLETED.md](archive/CHECKLIST_COMPLETED.md))*

**Note:** Framework-dual postinstall testing should focus on GNOME configuration workflow. See [docs/POSTINSTALL_DEV.md](docs/POSTINSTALL_DEV.md) for testing and development instructions.

---

## 🔀 Parallel Projects

### Batch Conversion System

**Goal**: Automated bash-to-Guile conversion using Anthropic Batch API with comprehensive validation.

**Status Summary:**

| Component | Status | Details |
| --------- | ------ | ------- |
| **Tools** | ✅ Complete | All batch conversion tools built and tested |
| **Conversions** | ✅ Complete | All 20 scripts converted (7 lib scripts + 13 postinstall recipes) |
| **Review** | ⏸️ Not Started | Converted scripts not yet reviewed or tested |
| **Deployment** | ⏸️ Not Started | Converted scripts not yet integrated into main codebase |

**Conversion Status:**

**✅ Converted Scripts (20 total in `tools/converted-scripts/`):**

**Lib Scripts (7):**
1. `lib_bootstrap-installer.scm` (from `lib/bootstrap-installer.sh` - 267 lines)
2. `lib_channel-utils.scm` (from `lib/channel-utils.sh` - 235 lines)
3. `lib_clean-install.scm` (from `lib/clean-install.sh` - 134 lines)
4. `lib_postinstall.scm` (from `lib/postinstall.sh` - 31 lines)
5. `lib_recovery-complete-install.scm` (from `lib/recovery-complete-install.sh` - 458 lines)
6. `lib_verify-guix-install.scm` (from `lib/verify-guix-install.sh` - 305 lines)
7. `lib_verify-postinstall.scm` (from `lib/verify-postinstall.sh`)

**Postinstall Recipes (13):**
- `postinstall/recipes/add-development.scm`
- `postinstall/recipes/add-fonts.scm`
- `postinstall/recipes/add-spacemacs.scm`
- `postinstall/recipes/add-doom-emacs.scm`
- `postinstall/recipes/add-vanilla-emacs.scm`
- Plus test files and templates

**✅ Deployment Status (2025-12-18):**
- ✅ `postinstall/lib.scm` deployed (converted from `postinstall/lib.sh`)
- ✅ All recipe scripts deployed to `postinstall/recipes/add/`:
  - `development.scm`, `fonts.scm`, `spacemacs.scm`
  - `doom/emacs.scm`, `vanilla/emacs.scm`
- ✅ `cloudzy/postinstall/customize.scm` created (converted from bash)
- ✅ `lib/common.go` updated to download `.scm` version for cloudzy platform
- ⏳ **Testing**: Scripts deployed but not yet tested on actual Cloudzy VPS

**Next Steps (Cloudzy Focus):**
1. ⏳ **Test** converted scripts on Cloudzy VPS (verify functionality matches bash versions)
2. ⏳ **Remove** original `.sh` files after successful testing (`postinstall/lib.sh`, `cloudzy/postinstall/customize`)
3. ⏳ **Comprehensive testing** of cloudzy installer with all `.scm` scripts
4. ⏳ **Document** any issues found during testing

**Documentation:**
- **Getting Started**: [tools/README.md](tools/README.md) - Complete workflow and usage guide
- **Detailed Plan**: [tools/BATCH_CONVERSION_PLAN.md](tools/BATCH_CONVERSION_PLAN.md) - Roadmap and enhancement plan
- **Best Practices**: [docs/BATCH_CONVERSION_BEST_PRACTICES.md](docs/BATCH_CONVERSION_BEST_PRACTICES.md) - Pre-conversion preparation guide
- **Deployment Guide**: [tools/DEPLOYMENT_CHECKLIST.md](tools/DEPLOYMENT_CHECKLIST.md) - Steps to deploy converted scripts

**Why Parallel**: Can be developed independently while framework-dual testing proceeds. Low risk, high value for future script migrations.

**Cost**: ~$0.12 for 3 scripts (50% savings vs interactive conversion)

---

**Testing cloudzy installer with latest improvements:**

- ✅ **Kernel symlink fix implemented (2025-12-16)**: Fixed critical issue where kernel/initrd copying failed because files are symlinks
  - **Discovery**: Runtime investigation revealed kernel/initrd in system generation are symlinks pointing to other store paths
  - **Fix**: Updated all `cp` commands to use `-L` flag (dereference symlinks) in both Go code and bash recovery script
  - **Status**: Fix applied to `lib/common.go` and `lib/recovery-complete-install.sh`, documented in `INSTALLATION_KNOWLEDGE.md`
  - **Next steps**: Test on cloudzy VPS to verify kernel files are now copied correctly (should be 5-15 MB, not a few bytes)
- ✅ **Recovery tool rewritten in Go (2025-12-16)**: Complete rewrite eliminates sync issues between recovery and installer
  - **Implementation**: Created `cmd/recovery/main.go` that reuses functions from `lib/common.go`
  - **Benefits**: Single source of truth, automatic sync, consistent behavior
  - **Status**: Implemented and documented, falls back to bash script if Go build fails
  - **Next steps**: Test recovery tool on actual installation failures to verify it works correctly
- ✅ **Network/DNS troubleshooting documented (2025-12-16)**: Comprehensive troubleshooting guide added
  - **Documentation**: Added section to `INSTALLATION_KNOWLEDGE.md` covering DNS failures, network interface issues, firewall problems
  - **Tools**: Documents `diagnose-guix-build.sh` and `lib/fix-network.scm` scripts (Guile)
  - **Status**: Complete, ready for users encountering network issues
- 🧪 **Proactive fixes implemented (2025-12-16)**: Implemented proactive approach to prevent kernel/initrd issues
  - **Proactive symlink creation**: After `guix system init` completes, check if `/mnt/run/current-system` symlink exists. If missing, find latest system generation in `/gnu/store` and create symlink immediately
  - **Proactive kernel/initrd copying**: Right after ensuring symlink exists, immediately check if kernel/initrd exist in `/mnt/boot/`. If missing, copy them proactively from system generation (which we know exists)
  - **Benefits**: Avoids multiple recovery retry attempts, more efficient, cleaner approach
  - **Status**: Implemented in `lib/common.go:RunGuixSystemInitFreeSoftware()`, ready for testing
  - **Next steps**: Test on cloudzy VPS to verify proactive fixes prevent kernel/initrd issues
- ✅ **Recovery script kernel/initrd verification improvements (2025-12-16)**: Added comprehensive verification for framework-dual
  - **Issue**: Recovery script reported "bootloader installed successfully" even when kernel files were missing
  - **Fix**: Verify kernel/initrd exist in system generation BEFORE copying, verify files copied successfully, verify before Step 3 bootloader install
  - **Behavior**: Fails early with clear error messages if kernel files missing, prevents false success messages
  - **Status**: Implemented in `lib/recovery-complete-install.sh`, better error messages for AMD GPU/nonguix issues
- ✅ **Auto-recovery from hung processes (2025-12-16)**: Added automatic process termination after 10 consecutive "hung" warnings
  - **Issue**: Installer could hang indefinitely on cloudzy VPS during `guix system init` phase
  - **Fix**: `RunCommandWithSpinner` now detects hung processes (no output + log not growing for 15+ minutes) and automatically stops after 10 warnings
  - **Behavior**: Kills hung process and suggests running recovery script
  - **Status**: Implemented in `lib/common.go`, prevents indefinite hangs
- ✅ **Recovery script automatic kernel/initrd recovery (2025-12-16)**: Added recovery logic for missing kernel/initrd after `guix system init`
  - **Issue**: `guix system init` reports success but kernel/initrd files are missing (especially on free software installs)
  - **Fix**: Recovery script now attempts to copy kernel/initrd from system generation if missing after init
  - **Behavior**: Finds system generation, copies kernel/initrd, creates symlink, verifies files exist
  - **Status**: Implemented in `lib/recovery-complete-install.sh`, handles both time-machine and free software paths
- ✅ **Recovery script exit trap verification (2025-12-16)**: Added EXIT trap to ensure verification always runs
  - **Issue**: If recovery script exits early (error, interrupt), verification might not run
  - **Fix**: EXIT trap runs verification function regardless of exit method
  - **Behavior**: Checks kernel/initrd, runs comprehensive verification script, offers automatic rerun if fails
  - **Status**: Implemented with proper loop prevention flags
- ✅ **Initrd configuration fix (2025-11-17)**: Removed explicit `base-initrd` specification for cloudzy
  - **Issue**: `base-initrd` doesn't accept `#:linux` and `#:linux-modules` keyword arguments that Guix passes when `(kernel linux-libre)` is specified
  - **Error**: `Invalid keyword: (#:linux ...)` during config validation
  - **Fix**: Omit initrd specification entirely for free software installations - Guix uses default initrd generation which automatically handles kernel and modules
  - **Documentation**: Updated `INSTALLATION_KNOWLEDGE.md` to clarify when to use explicit initrd vs defaults
  - **Status**: Fixed in `cloudzy/install/03-config.go`, ready for testing
- ✅ 3-step kernel/initrd fix applied and tested
- ✅ Color-coded output with cycling headers
- ✅ Enhanced manifest verification with Quick checksum view
- ✅ Improved swap creation error messages
- ✅ Daemon startup timeout increased to 2 minutes
- ✅ Graceful validation skip if daemon not responsive
- ✅ Robust daemon startup: functional approach that ensures daemon is actually ready (restarts until responsive, not just retries)
- ✅ Post-install steps made resilient: password setting always attempted, verification non-fatal
- ✅ Better error handling: clear messages when post-install steps incomplete, suggests recovery script
- ✅ Comprehensive verification at end: runs full verify-guix-install.sh script, ensures EFI mounted, prevents reboot if verification fails
- ✅ Framework-dual kernel fixes applied to cloudzy: checks broken symlink, automatic fallback copy of kernel/initrd if missing
- ✅ Verification after guix system init: checks for kernel/initrd files and broken symlink, retries with manual copy if needed
- ✅ VERBOSE=1 instructions added everywhere verify script is mentioned (helps debug file detection issues)

**Oracle Cloud Free Tier Support (In Progress, 2026-07-31):**

- ⏳ **Goal**: Run Guix System on Oracle Cloud Free Tier
- **Why**: Oracle Cloud Free Tier offers ARM64 and x86_64 instances with generous free tier limits, expanding platform support

- 🚩 **Blocking finding**: **OCI cannot boot an ISO.** Importing an ISO is not
  supported; OCI accepts only QCOW2/VMDK custom images uploaded to Object
  Storage. Every platform in this repo — cloudzy included — is built on "boot
  the Guix live ISO → partition → mount → `guix system init`", so that model
  does not transfer. Oracle is an **image-build** platform, not an ISO-boot
  platform, and is therefore not a `cp -r cloudzy oracle` job.

- **Approach adopted**: build locally with `guix system image -t qcow2
  --image-size=50G` → upload to Object Storage → import as custom image
  (launch mode `PARAVIRTUALIZED`) → launch `VM.Standard.E2.1.Micro`.

- ✅ `oci` CLI installed and authenticating (home region `us-ashburn-1`)
- ✅ `oracle/image/oracle-image.scm` written — headless, SSH-key-only,
  serial console on `ttyS0`, swap file service for the 1 GiB shape
- ✅ Validated: `guix system image ... --dry-run` evaluates cleanly and
  computes a full derivation
- ✅ `oracle/image/oracle-image_purpose.txt` documents every setting and the
  deliberate omissions (no `initrd-modules`, root label must stay
  `Guix_image`, swap as a shepherd service rather than `swap-devices`)
- ✅ **Build blocker resolved (2026-08-08): it was the full disk.** The
  2026-08-02 "database is locked" failure during `register-closure` never
  reproduced once `/` moved from the ~97%-full 58.6 G Pop!_OS partition to the
  96 G Guix partition with 43 G free. SQLite reports a lock error, not a disk
  error, when it cannot create its rollback journal — hypothesis confirmed by
  absence. Built with Guix `17c2142` (pulled 2026-08-04). A pty is still
  REQUIRED (`script -qec '...' /dev/null`); redirecting output kills the
  progress reporter with `terminal-window-size: Inappropriate ioctl for
  device`. Also note: a `setsid`-detached build survives the invoking session;
  two earlier attempts died only because their session was killed.
- ✅ Image builds: `/gnu/store/ihym40qx8l08iq1jz3kkj3xnj0gdbw65-image.qcow2`
  (617 MiB compressed for the nominal 50 G)
- ✅ **QEMU smoke test passed (2026-08-08):** boots to a serial-console login
  prompt in ~10 s, root mounts by the `Guix_image` label, host keys generate,
  the baked authorized key lands in `/etc/ssh/authorized_keys.d/guix`,
  kernel 6.18.13-gnu, 2 G `/swapfile` active, layout is 40 M BIOS-boot +
  50 G root.
- ✅ **SSH key-only login verified end-to-end** (throwaway key injected into
  the running VM's `~guix/.ssh/authorized_keys` — the store image is
  untouched): login succeeds, `sudo -n true` passes. This also proves the
  purpose-file's assumption that a locked-password account (`guix:!:` in
  shadow) still completes pubkey auth under `UsePAM yes`.
- ⚠️ **Test-harness trap worth remembering:** `ssh -o BatchMode=yes` with a
  passphrase-protected key and no agent fails as `Permission denied
  (publickey)` even though the server accepted the key (`sshd -ddd` shows
  `Accepted key ... Postponed publickey` then the *client* disconnecting).
  Looks exactly like README failure mode #2 but is client-side.
- ⚠️ Benign-looking early-boot artifact: initrd logs one transient
  `init[1]: segfault ... in guile` yet boot always completes; not chased.
- ✅ **Deployed and RUNNING on OCI (2026-08-08).** Upload (617 MiB to
  Object Storage bucket `guix-images`) → import as custom image
  `guix-oracle` (PARAVIRTUALIZED, reached AVAILABLE) → VCN + internet
  gateway + default route + public subnet created via CLI → launched
  `VM.Standard.E2.1.Micro` in us-ashburn-1 → sshd answering on the public
  IP with key-only auth enforced. Client side was rebuilt from scratch on
  the new Guix laptop: python via `guix install python`, `oci-cli` in
  `~/.venvs/oci-cli`, API key via the console's generate-and-download flow
  (pasting a locally generated PEM through chat/copy corrupted it once —
  avoid).
- ✅ **Whole flow scripted** in `oracle/scripts/01-setup-client.scm`,
  `02-build-image.scm`, `03-smoke-test.scm`, `04-deploy.scm` (Guile, per
  repo language policy; idempotent; no JSON parsing — `--query`/
  `--raw-output` only). Reasoning and traps in
  `oracle/scripts/oracle-scripts_purpose.txt`; `oracle/README.md` updated,
  its upload/import/launch sections now marked verified.
- ⏳ Scripts are transcriptions of the verified manual run; they have not
  themselves been run end-to-end yet (parse-checked only). Next fresh
  deploy should use them and note divergences.
- ✅ Open question resolved (2026-08-08): `lsblk` on the live instance shows
  the boot volume as **`/dev/sda`** (paravirtualized boot volumes attach via
  virtio-scsi), matching QEMU's IDE default. `(targets ...)` in
  `oracle-image.scm` updated from `/dev/vda` to `/dev/sda` before anyone ran
  a `guix system reconfigure`, so the failure mode never fired

- **Superseded analysis** — the Top 5 below was written assuming the cloudzy
  ISO installer could be adapted. Kept for reference, but items 1–2 and 5
  (device detection, boot mode, partitioning) are now handled declaratively by
  the image definition rather than by runtime detection. Items 3–4 (network
  interface naming, serial console) remain relevant.
- **Top 5 Things Needed to Update Cloudzy Scripts:**

  1. **Device Detection Updates** (`cloudzy/install/01-partition.go`):
     - Oracle Cloud may use different device naming (e.g., `/dev/sda` vs `/dev/vda`)
     - May need to detect device type (NVMe, SCSI, VirtIO) and handle accordingly
     - Oracle Cloud Free Tier ARM64 instances might use different storage controllers

  2. **Boot Mode Detection** (`cloudzy/install/01-partition.go`, `lib/common.go`):
     - Oracle Cloud Free Tier typically uses UEFI, but detection might differ
     - May need to handle Oracle Cloud's specific EFI partition requirements
     - Verify EFI partition detection works correctly in Oracle Cloud environment

  3. **Network Configuration** (`cloudzy/install/03-config.go`, `postinstall/customize`):
     - Oracle Cloud uses different network interface naming (may be `ens3` instead of `eth0`)
     - May need Oracle Cloud-specific network service configuration
     - Consider Oracle Cloud's cloud-init integration (if applicable)

  4. **Console/Serial Access** (`lib/bootstrap-installer.sh`):
     - Oracle Cloud uses web-based console access (different from Cloudzy's VNC/KVM)
     - May need to handle serial console differently
     - Font selection and display might need adjustments for Oracle Cloud console

  5. **Storage and Partitioning** (`cloudzy/install/01-partition.go`):
     - Oracle Cloud Free Tier has specific storage limits and configurations
     - May need to handle Oracle Cloud's block volume attachments differently
     - Consider Oracle Cloud's boot volume vs block volume distinction
     - Verify partitioning works with Oracle Cloud's storage backend

**Framework 13 Post-Install Process (2025-11-10):**

Learned the complete workflow for getting Framework 13 fully operational after minimal install:

1. **First Boot State:**
   - Wired ethernet works (dhclient running)
   - WiFi/Bluetooth NOT working (missing firmware)
   - No NetworkManager (can't easily switch to WiFi)
   - Guix 1.4.0 from ISO (old, doesn't support channel introductions)

2. **Post-Install Steps Required:**

   ```bash
   # Step 1: First guix pull (upgrade Guix to support channel introductions)
   guix pull
   # Takes 10-30 min, upgrades to latest Guix from master

   # Step 2: Create channels.scm with nonguix
   mkdir -p ~/.config/guix
   cat > ~/.config/guix/channels.scm <<'EOF'
   (cons* (channel
           (name 'nonguix)
           (url "https://gitlab.com/nonguix/nonguix")
           (branch "master")
           (introduction
            (make-channel-introduction
             "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
             (openpgp-fingerprint
              "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
          %default-channels)
   EOF

   # Step 3: Second guix pull (add nonguix channel)
   guix pull
   # Takes 10-30 min, fetches nonguix

   # Step 4: Fix PATH to use pulled Guix
   export PATH="$HOME/.config/guix/current/bin:$PATH"
   # Add to ~/.bashrc for persistence

   # Step 5: Verify nonguix is available
   guix describe  # Should show both guix and nonguix
   guix show linux  # Should find non-free kernel
   guix show linux-firmware  # Should find proprietary firmware

   # Step 6: Add NetworkManager to /etc/config.scm
   sudo nano /etc/config.scm
   # Add (service network-manager-service-type) to services

   # Step 7: Reconfigure system
   sudo guix system reconfigure /etc/config.scm
   # Takes 5-15 min, installs NetworkManager

   # Step 8: Connect to WiFi
   nmcli device wifi list
   nmcli device wifi connect "SSID" --ask

   # Step 9: Run customize script
   ~/guix-customize/customize
   # Add desktop, packages, etc.
   ```

3. **Common Pitfalls:**
   - **PATH issue:** `guix describe` shows old Guix if PATH not updated
   - **Generation mismatch:** Pulled Guix is generation 2, system uses generation 1
   - **Channel introduction required:** Old Guix 1.4.0 can't authenticate nonguix without upgrade
   - **Two-step pull required:** Can't add nonguix until after first pull upgrades Guix

4. **Automation Opportunities:**
   - Post-install script could automate the two-pull process
   - Could pre-populate ~/.bashrc with correct PATH
   - Could check for and fix PATH issues automatically
   - Customize script should detect missing NetworkManager and offer to add it

---

## 📋 Remaining Work

### 🟢 APPROVED FUTURE WORK — "Friend Clicks a Button, Gets Guix on Oracle" (2026-08-08)

**Full plan: [docs/ORACLE_ONE_CLICK_ROADMAP.md](docs/ORACLE_ONE_CLICK_ROADMAP.md).**
Approved by the user; step 1 is implemented, steps 2-6 are not started.

**Target:** someone who has never used Guix, and has no Guix installed anywhere,
makes an Oracle free-tier account, chooses a few preferences, waits, and is up
and running.

**Steps 1, 5 and 6 are DONE.** Step 1 (`59987c9`) is the unlock; steps 5
(capacity handling) and 6 (presentation-only web page at `web/index.html`) were
built through the stage pipeline — see [docs/stages/](docs/stages/). Steps 2-4
remain blocked on the gate below.

**Step 1 — Instance-metadata SSH keys — DONE (`59987c9`).** The unlock. Without
it a key could only be baked in, so a published image could serve nobody but its
builder, so every user needed their own build, so every user needed Guix. Now
`--metadata ssh_authorized_keys` works and **one published image serves
everyone**.

> ✅ **GATE PASSED (2026-08-11).** A live instance launched with the key
> supplied only via `--metadata ssh_authorized_keys` installed it and the login
> worked:
>
> ```
> metadata-ssh-keys: reached .../ssh_authorized_keys on attempt 4
> metadata-ssh-keys: installed 1 key(s) into /home/guix/.ssh/authorized_keys
> ```
>
> Guix writes a baked-in key to `/etc/ssh/authorized_keys.d/` and never to
> `~/.ssh/authorized_keys`, so it can only have come from instance metadata.
> **Steps 2-3 are unblocked.** Three bugs were found by running it — an `#f`
> reaching the authorized-keys builder, a fetch that gave up before DHCP had a
> lease (the address was reachable on attempt 4, ~20s in), and `read-line` being
> unbound inside a shepherd gexp. Automated end-to-end by
> `~/.local/bin/oracle-metadata-gate`.
>
> *Caveat kept deliberately:* the confirming image also carried a baked-in key,
> because a keyless image that fails leaves no way in to read the logs — which is
> exactly why two earlier attempts taught nothing. The service is verified; the
> keyless image is confirmed to build; step 2 exercises the last inch.

| Step | Effort | Blocked by |
|---|---|---|
| 2. Publish one generic image (release + checksum, import from URL) | Small | ✅ **UNBLOCKED — next up** |
| 3. Console-only path (no CLI, no Guix — docs + screenshots) | Small | step 2 |
| 4. Preferences at first boot (hostname, timezone, shell, user) | Medium | ✅ **DONE** (stage 03) |
| 5. Capacity handling | Small | ✅ **DONE** (stage 01) — reasoned, never seen a real refusal |
| 6. Web UI to show friends | Medium | ✅ **DONE** presentation-only (stage 02) — hedges until 2-3 land |

**On step 4:** `oracle-image.scm` hardcodes `%user-name`, `%host-name`,
`%timezone` and locale. With a shared image these *must* move to first
boot — you cannot bake a stranger's timezone into an image everyone downloads.
Note **R1 below does not help here**: it targets framework-dual's Go generator,
and oracle is a separate Guile path. Oracle's preferences are closer in shape to
the personal-config contract.

**On step 6 (web UI):** scope it before building. A *presentation-only* page
(explains the steps, generates commands to paste, links the image) is most of
the value at a fraction of the risk. Anything that **launches** OCI resources
needs the visitor's credentials — do not build a service that accepts other
people's OCI API keys; generate a config they run locally, or lean on OCI's own
console.

---

### 🟠 Bash Reduction — Audit Result (2026-08-08)

**Question asked:** is bash used only where it must be, i.e. where bash exists
but Guile does not?

**Answer: no, and by a wide margin.** 42 tracked `.sh` files outside `archive/`
and `tools/converted-scripts/`; roughly **one** has a defensible
"Guile unavailable" justification.

**The premise most of these rest on is false.** `guile` is in `%base-packages`,
so it is present on the Guix ISO *and* on every freshly installed system.
Verify:

```sh
guix repl -q <<'EOF'
(use-modules (gnu system) (guix packages))
(display (member "guile" (map package-name %base-packages)))
EOF
```

"It runs on the ISO" is therefore an argument *for* Guile, not for bash. The
policy's escape hatch — "scripts that must run on non-Guix systems" — genuinely
applies only to workstation tooling.

**Tier 1 — duplicates of already-deployed Guile (6 files).** A `.scm` doing the
same job is already committed:

| bash | Guile counterpart |
|---|---|
| `postinstall/lib.sh` | `postinstall/lib.scm` |
| `postinstall/recipes/add-development.sh` | `postinstall/recipes/add/development.scm` |
| `postinstall/recipes/add-fonts.sh` | `postinstall/recipes/add/fonts.scm` |
| `postinstall/recipes/add-spacemacs.sh` | `postinstall/recipes/add/spacemacs.scm` |
| `postinstall/recipes/add-doom-emacs.sh` | `postinstall/recipes/add/doom/emacs.scm` |
| `postinstall/recipes/add-vanilla-emacs.sh` | `postinstall/recipes/add/vanilla/emacs.scm` |

They cannot simply be deleted: `framework/postinstall/customize`,
`framework-dual/postinstall/customize` and `raspberry-pi/postinstall/customize`
are still bash and `source` them. **Only cloudzy migrated** to `customize.scm`.
That is the actual blocker behind Phase 4's "Remaining: remove original `.sh`
files after successful testing" — the removal is gated on three unconverted
`customize` scripts, which the note does not say.

**Tier 2 — converted, never deployed (7 files).** Finished conversions sit
unused in `tools/converted-scripts/`: `lib_bootstrap-installer.scm`,
`lib_channel-utils.scm`, `lib_clean-install.scm`, `lib_postinstall.scm`,
`lib_recovery-complete-install.scm`, `lib_verify-guix-install.scm`,
`lib_verify-postinstall.scm`. Work already paid for, not banked.

**Tier 3 — Guix-target bash with no conversion at all.**
`lib/fix-iso-artifacts.sh`, `lib/enforce-guix-filesystem-invariants.sh`,
`diagnose-guix-build.sh`, `investigate-kernel-location.sh`,
`fix_guix_cursor.sh`, `raspberry-pi/postinstall/templates/setup-config.sh`,
plus the three `customize` scripts above.

**Tier 4 — defensibly bash.** Workstation tooling that never touches a Guix
machine: `run-tests.sh`, `update-manifest.sh`, `lib/validate-before-deploy.sh`,
`test-docker.sh`, `test/*`, `tools/*`, the `*/tests/run-guile-tests.sh` runners.
Keep, or convert last.

**Shebang enforcement — DONE (2026-08-08).** `lib/validate-before-deploy.sh`
never checked shebangs despite `CLAUDE.md` calling the rule CRITICAL. It does
now, in **two tiers**, because measurement on a running Guix system showed the
two ways of getting it wrong are not equally bad:

- **FAIL** — `#!/bin/bash`. `/bin` contains **only `sh`**, so the script cannot
  run at all. Found and fixed: `raspberry-pi/postinstall/templates/setup-config.sh`.
- **WARN** — `#!/usr/bin/env bash`. **`/usr/bin/env` does exist on Guix**: it is
  a store symlink installed by `special-files-service-type`, which is in
  `%base-services`. These 9 scripts do run. Treating them as FAIL would block
  every deploy over scripts that work, so they are flagged, not gated:
  `lib/channel-utils.sh`, `lib/postinstall.sh`, `postinstall/lib.sh`, the five
  `postinstall/recipes/add-*.sh`, and `cloudzy/postinstall/customize.scm`.

`CLAUDE.md`'s claim that env "may not work reliably on the ISO" is overstated
for an *installed* system — the ISO case was not measured, which is why these
stay warnings rather than passes.

**Also surfaced: `fix_guix_cursor.sh` is a 0-byte file**, the only empty tracked
file in the repo, referenced by nothing, committed by accident in `56757b3` (a
framework-dual initrd commit). Left in place — deletion is your call.

**The bigger find: `run-tests.sh` could not run on a Guix workstation at all.**
It carried `#!/bin/bash`, and `/bin` on Guix contains only `sh`:

```
$ ./run-tests.sh
bad interpreter: /bin/bash: no such file or directory
```

Eight scripts had this, including **all three** `run-guile-tests.sh` runners and
`test-docker.sh` — i.e. the script `CLAUDE.md` instructs you to run before every
commit was unrunnable on the machine you develop on. It only ever worked when
invoked as `bash run-tests.sh`, which bypasses the shebang. Fixed to
`#!/usr/bin/env bash` rather than the Guix path, deliberately: this tier should
also run on CI and on a contributor's non-Guix machine, and `env` satisfies
both.

**Two further bugs fell out of making it runnable:**

1. **`set -e` defeated the suite's own failure tolerance.** `run-tests.sh` ran
   `TEST_OUTPUT=$(...)` then `TEST_EXIT=$?`; under `set -e` a failing assignment
   aborts before the next line, so the suite died on the FIRST failing
   converted-script test — despite an explicit `# Don't fail the entire test
   suite for auto-generated test failures` and a commented-out `return 1`.
   Rewritten as an `if` condition, which is exempt from `set -e`. The suite now
   runs to completion and exits 0.
2. **14/14 converted-script tests fail** (`tools/converted-scripts/test-*.scm`).
   Not a regression — they had never executed, because the runner never started.
   This is the missing half of the Tier 2 story above: the conversions were
   generated, their generated tests never passed, so nothing was ever deployed.
   They do not gate the suite, by the author's explicit decision.

**Device-detection tests were environment-dependent (fixed).** `TestDetectDevice`,
`TestDetectDeviceFromState`, and three tests in
`framework-dual/install/01-partition-check_test.go` asserted `expectError: true`
on the stated assumption of "no actual devices in test environment". True in an
empty container; false on any workstation with `/dev/sda` or `/dev/nvme0n1`, so
they failed exactly where a developer runs them. Two were also wrong about the
code: an unknown platform does **not** error (`DetectDevice`'s `default` branch
is a deliberate generic fallback), and one condition was inverted such that the
success case was reported as a failure. Rewritten to assert the contract — the
return values agree, a returned path exists, detection is deterministic — which
holds on any host.

**Suggested order:** shebang check in `validate-before-deploy.sh` → convert the
three `customize` scripts to `.scm` (unblocks deleting six duplicates) → deploy
the Tier 2 conversions → Tier 3 as each file is next touched.

**Impact:** ⭐⭐ Medium — nothing is broken today; the cost is that the stated
policy and the tree disagree, so each new script re-litigates the question.

---

### 🔴 Next Up — Roadmap to "New Laptop → Prompts → Full Guix" (2026-08-04)

**North star:** someone buys a new Framework laptop, boots the installer, answers
a few prompts (username, shell, desktop), and ends up with a working Guix
system. Gap analysis done 2026-08-04 against a hand-evolved config that is
running the full stack; these three items are the distance, in order of
leverage. Documented now, deliberately not started — other priorities first.

#### R1. Preference Prompts → Generated Config (shell, desktop)

**Status:** ❌ Not started — but the target config content already exists and is validated

**Current gap:** `generateMinimalConfig` emits a fixed console-only config:
`%base-services`, no `(shell ...)` on the user-account (login shell silently
bash), no desktop. Shell and desktop are exactly the preferences a new user
would state up front.

**The content to emit is already known-good.** A hand-evolved copy of the
generated config (`~/config-framework-dual-new.scm` on the Pop!_OS partition,
validated by evaluation to `<operating-system>`, 58 services) contains every
piece:

- Login shell: `(shell (file-append zsh "/bin/zsh"))` on the user-account.
  Must be a SYSTEM setting: `file-append` pulls the shell into the system
  closure so it exists at first boot, before guix home runs; `chsh` is futile
  on Guix because reconfigure regenerates `/etc/passwd` from the declaration.
- Desktop: `(service gnome-desktop-service-type)` + swap `%base-services` →
  `%desktop-services` in `modify-services`. **The swap requires REMOVING the
  five explicit services** (network-manager, wpa-supplicant, dbus-root,
  polkit, ntp) — `%desktop-services` supplies all five, and duplicates fail
  the reconfigure. GDM defaults to `(wayland? #t)`.
- Bootstrap packages: `(append (list git openssh gnu-make) %base-packages)`.
  `%base-packages` has none of the three; a fresh system cannot clone a
  dotfiles repo or run `make` without them.

**Implementation shape:** prompts modeled on the existing
`lib.PromptKeyboardLayout` (see `03-config-dual-boot.go`), feeding the Go
template. Shell: bash/zsh/fish → one field (bash = omit the field). Desktop:
none/GNOME/Xfce → one service + the services-base swap.

**Relation to the postinstall desktop switch:** the old sed-based
`add_desktop` footgun was already fixed (2026-08-03, `954bb8b`) by
`guile-config-helper.scm switch-to-desktop`, which rewrites the parsed
S-expressions and drops the services `%desktop-services` supplies. R1 is the
complement, not a duplicate: emitting the desktop at *generation* time means a
user who states the preference up front never needs the switch tool at all —
the postinstall path stays for users who start minimal and upgrade later.

**Impact:** ⭐⭐⭐ High — this is the "enter some information" half of the vision

---

#### R2. Blank-Disk Support (create the ESP)

**Status:** ❌ Not started

**Current gap:** the installer is a *dual-boot* installer: step 01
(`FindEFIPartition`, `framework-dual/install/01-partition-check.go`) only
*finds* an ESP and hard-fails with `required variables not set (DEVICE, EFI)`
when none exists. Nothing anywhere runs `mkfs.fat`. A genuinely new laptop —
blank NVMe, no OS — fails at the first step.

**Needed:** when no ESP exists on the chosen device, create GPT + ESP
(`mkfs.fat -F32`, partition type EF00) + `GUIX_ROOT`, then proceed down the
existing path. The find-or-create pattern already used for `GUIX_ROOT`
(`parted --script` + `mkfs.ext4 -L GUIX_ROOT`) is the model.

Related, already fixed (2026-08-04, `44a591c`): the Pop!_OS chainload entry is
now conditional — on a machine without Pop!_OS the generated config omits it
(three-state probe, fails open on EACCES so a user-level `guix system build`
cannot silently drop the entry).

**Impact:** ⭐⭐⭐ High — the difference between "dual-boot installer" and
"new-machine installer"

---

#### R3. Channel Pin Lifecycle

**Status:** ⚠️ Policy exists (docs/CHANNEL_PINNING_POLICY.md); recurring cost, not a feature

Two clocks tick against the pin (`lib/common.go`:
`FrameworkDualGuixCommit` / `FrameworkDualNonguixCommit`, dated
`FrameworkDualPinDate`):

1. **New hardware revisions** — the pin must be NEWER than the target silicon
   (see the Ryzen AI 300 postmortem: a pin that predates the hardware cannot
   contain its firmware). Each new Framework generation likely needs a
   move-forward before the installer works on it.
2. **Substitute GC** — once build farms garbage-collect substitutes for the
   pinned commits, installs still work but compile from source (hours).

**Needed:** a documented cadence (or CI check) that verifies the current pin
still has substitute coverage and is newer than supported hardware, rather
than discovering staleness mid-install.

**Impact:** ⭐⭐ Medium — nothing breaks today; it rots silently

---

#### R4. Generic Dual-Boot: Guix + an OS of Your Choice (default Pop!_OS)

**Status:** ❌ Not started — and cheaper than it sounds

**Why it is cheap:** the installer's Pop!_OS coupling is almost entirely one
string pair. The partitioning and mounting logic never touches the other OS —
it finds the ESP and `GUIX_ROOT` by label and leaves everything else alone,
which is already OS-agnostic by design. What actually says "Pop!_OS":

- the chainload target `/EFI/systemd/systemd-bootx64.efi` (systemd-boot —
  a Pop!_OS choice; Ubuntu/Fedora use shim+GRUB, Windows uses bootmgfw)
- the GRUB menu label
- a handful of user-facing prints and the dual-boot docs

**Implementation shape:** turn the conditional-entry probe (`fa9d8c2`) into a
loader *table* instead of a single path — each row `{label, esp-paths}`:

| OS | loader on the shared ESP |
|---|---|
| Pop!_OS (systemd-boot) | `/EFI/systemd/systemd-bootx64.efi` |
| Ubuntu | `/EFI/ubuntu/shimx64.efi` |
| Fedora | `/EFI/fedora/shimx64.efi` |
| Windows | `/EFI/Microsoft/Boot/bootmgfw.efi` |

The generated config probes every row with the same three-state (present /
absent / unknown-fails-open) logic and emits one `menu-entry` per loader
found. GRUB's `search --label` + `chainloader` works identically for all of
them. No per-OS code beyond the table row; "default Pop!_OS" stops being a
special case and becomes just the row that matches on this hardware.

**The honest cost** is not code but testing and docs: each claimed OS needs at
least one real chainload test, and `docs/GUIDE_DUAL_BOOT.md` (written against
Pop!_OS) needs per-OS notes — especially Windows, where BitLocker measures the
boot path and a chainload can trip recovery-key prompts. Ship the table with
only the tested rows enabled.

**Impact:** ⭐⭐ Medium-High — widens the audience from "Pop!_OS owners" to
"anyone with an EFI system," R2's natural companion

---

**Explicitly out of scope for the general-user vision:** keyd remapping, the
`/lib64` FHS loader shim, and personal dotfiles. Those belong to the `dot_files`
repo — this repo installs the *system*; the user brings their own machine. That
separation is working and should be kept.

Note that "user layer" does not mean "`guix home`" for all three. Dotfiles ride
on `guix home`; keyd and the loader shim cannot. keyd reads `/dev/input/event*`
and writes `/dev/uinput`, both root-only, which is why `dot_files`' `setup-keyd`
target refuses to run on Guix System and why keyd is a hand-written
`shepherd-service` in the user's own `operating-system` config instead. Those
live in `dot_files/system/`; see `known-good/README.md` for how that state
relates to the generated and captured configs here. Worth stating precisely,
because reading "user layers riding on `guix home`" literally sends a system
concern somewhere structurally unable to host it, and the config it belongs to
then has no home in either repo.

---

### 🟡 Medium Priority

#### 1. Add NetworkManager to Framework Customize Script

**Status:** ❌ Missing from customize script

**Current gap:** Framework 13 first boot has no persistent networking. User must manually add NetworkManager service to config.scm before running customize script.

**Proposed solution:**

- Add NetworkManager as high-priority option (option 0 or automatic)
- Include in Framework-specific hardware setup
- Document in first-boot instructions

**Impact:** ⭐⭐⭐ High - Critical for laptop usability

---

#### 2. Dual-Boot GRUB UX Improvements

**Status:** ❌ Not implemented

Ensure readable GRUB theme and visible timeout; add explicit chainloader entry for Pop!_OS in EFI if auto-detection fails.

**Current state:**

- ✅ Timeout set to 5 seconds
- ✅ os-prober configured in recovery script
- ❌ Need to test chainloader detection
- ❌ GRUB theme not customized

**Impact:** ⭐⭐ Medium - Smoother dual-boot selection

---

#### 2a. Generalize Dual-Boot Documentation and Configuration

**Status:** ❌ Not implemented

Make the dual-boot section more generic and helpful for users dual-booting with other OSes (not just Pop!_OS), and enable easy high-level configuration.

**Goals:**

- Generalize `docs/GUIDE_DUAL_BOOT.md` to work with any Linux distribution (Ubuntu, Fedora, Arch, etc.), not just Pop!_OS
- Make installer scripts configurable at a high level for different dual-boot scenarios
- Document common dual-boot patterns (systemd-boot, GRUB, Windows, etc.)
- Enable contributions from others who modify scripts for their own dual-boot setups
- Provide clear extension points for customizing bootloader detection and configuration

**Current limitations:**

- Documentation assumes Pop!_OS (systemd-boot) as the existing OS
- Installer scripts have Pop!_OS-specific detection logic
- GRUB configuration assumes Pop!_OS chainloading pattern
- Limited guidance for other bootloader types (GRUB, Windows Boot Manager, etc.)

**Proposed approach:**

- Extract Pop!_OS-specific logic into configurable parameters
- Document bootloader detection patterns for common distributions
- Create extension guide for contributors adapting scripts to other OSes
- Add high-level configuration options (bootloader type, detection method, etc.)
- Include examples for common dual-boot scenarios (Ubuntu, Fedora, Arch, Windows)

**Impact:** ⭐⭐⭐ High - Makes dual-boot installer useful for broader audience, enables community contributions

---

#### 3. Bootloader Timeout Configuration

**Status:** ⚠️ Partially implemented

**Current:**

```scheme
(bootloader-configuration
  (bootloader grub-efi-bootloader)
  (targets '("/boot/efi"))
  (timeout 5))  ; Already set in framework-dual
```

**Need to verify:**

- Framework single-boot installer also has timeout
- Cloudzy installer has appropriate timeout
- Timeout is documented in generated configs

**Impact:** ⭐⭐ Medium - Affects dual-boot usability

---

#### 4. Storage Options Documentation

**Status:** ❌ Not documented

Provide documented flows for:

- LUKS + ext4 root
- btrfs with subvolumes and periodic scrub hooks
- Flag to reserve N GiB unallocated and/or create separate `/home`

**Impact:** ⭐⭐ Medium - Security/flexibility options for advanced users

---

#### 5. Safer Retries and Diagnostics

**Status:** ❌ Not implemented

Toggle verbose vs quiet logging; capture `guix describe` and `guix weather` summaries into the log and receipt.

**Impact:** ⭐⭐ Medium - Easier troubleshooting

---

#### 6. Post-Install Customization Profiles

**Status:** ❌ Not implemented

Split `/etc/config.scm` into base OS vs hardware profile; provide a "first reconfigure" profile that adds firmware, NetworkManager, SSH, time sync, and trim in one step.

**Impact:** ⭐⭐ Medium - Faster, cleaner onboarding

---

### 🟢 Low Priority (Nice to Have)

#### 7. Label Verification Output

**Status:** ❌ Not shown to user

Should display:

```bash
# Show labels after formatting
echo "Verifying partition labels..."
e2label /dev/nvme0n1p2        # Should show: GUIX_ROOT
fatlabel /dev/nvme0n1p1       # Should show: EFI
parted /dev/nvme0n1 print     # Should show GPT names
```

**Impact:** ⭐ Low - Nice for debugging

---

#### 8. Stronger Installation Receipts

**Status:** ⚠️ Partially implemented

**Current:**

- ✅ Basic receipt written
- ✅ Channel commits included (via recovery script)
- ❌ Need `/run/current-system` derivation
- ❌ Need complete substitute server list
- ❌ Need authorization keys list

**Impact:** ⭐ Low - Better provenance tracking

---

#### 9. Raspberry Pi Track Enhancements

**Status:** ❌ Not implemented

Add optional image build recipe and Pi-specific initrd modules/services (chrony, headless SSH with key drop).

**Impact:** ⭐ Low - Broader hardware support

---

#### 10. Labels vs Device Paths Explanation

**Status:** ❌ Not documented

Add a one-sentence explanation and simple diagram where labels first appear in documentation.

**Impact:** ⭐ Low - Easier mental model for new users

---

#### 11. Optional Channel Pinning Toggle Documentation

**Status:** ❌ Not documented

Provide a short on/off toggle doc section; default remains safe/unpinned.

**Impact:** ⭐ Low - Simpler onboarding choice

---

#### 12. Swap Partition Support

**Status:** ⚠️ Only swapfile support

**Current:** Only supports creating swapfile in step 4

**Could add:** Detection and use of existing swap partition

**Impact:** ⭐ Low - Swapfile works fine for most users

---

#### 13. Reserved Disk Space Option

**Status:** ❌ Not implemented

**Could add:**

- Allow leaving 10-20GB unallocated
- User configurable via env var

**Impact:** ⭐ Low - Most users don't need this

---

#### 14. Script Directory Reorganization

**Status:** ✅ Complete (v1.1.0)

**Completed:**

- ✅ Moved critical scripts to `lib/` subdirectory:
  - `lib/verify-guix-install.sh`
  - `lib/recovery-complete-install.sh`
  - `lib/bootstrap-installer.sh`
  - `lib/postinstall.sh` (already in lib/)
- ✅ Kept development/repo scripts at top level:
  - `update-manifest.sh`
  - `run-tests.sh`
- ✅ Updated bootstrap script internal paths
- ✅ Updated SOURCE_MANIFEST.txt with new paths
- ✅ Updated documentation references:
  - README.md
  - QUICKSTART.md
  - docs/INSTALLATION_KNOWLEDGE.md
  - postinstall/CHANNEL_MANAGEMENT.md
- ✅ All tests pass after reorganization

**Breaking changes (v1.1.0):**

- GitHub download URLs changed to use `lib/bootstrap-installer.sh`
- Users should update their bookmarks/documentation

**Benefits achieved:**

- Clear separation between Guix runtime scripts and development scripts
- Consistent with `lib/common.go` pattern
- Easier to understand repository structure

**Impact:** ⭐ Low - Better organization with minimal disruption

---

## 🎯 Core Design Principles

These principles guide all implementation work:

### 1. Super-Minimal Initial config.scm

- Keep only: host-name, locale, timezone, bootloader, file-systems, users
- No desktop environment, SSH, or optional services in initial install
- Goal: Reliably install a bootable Guix system shell

### 2. Verify Before Reboot

- Check kernel and initrd exist in `/mnt/boot/`
- Verify GRUB EFI files exist
- Refuse to reboot if critical files missing

### 3. Pre-Set User Password

- After `guix system init` but before reboot
- Use `chroot` and `passwd` command
- Avoids storing secrets in version control

### 4. Hardware-Aware Defaults

- Framework-specific: include AMD GPU, NVMe, USB modules in initrd
- Include linux-firmware via nonguix for real-world hardware
- Set stable kernel arguments

---

## 📊 Implementation Phases

| Phase | Goal | Status |
| ----- | ---- | ------ |
| **Phase 1: Core Installer** | Reliable single-boot installation | ✅ Complete |
| **Phase 2: Dual-Boot Support** | Framework-dual installer working | ✅ Complete |
| **Phase 3: Recovery & Safety** | Recovery script and verification | ✅ Complete |
| **Phase 4: Documentation** | First-boot guides and customization | ✅ Complete |
| **Phase 5: Advanced Options** | LUKS, btrfs, profiles | ⏳ In Progress |
| **Phase 6: Raspberry Pi** | ARM support and image building | ❌ Not Started |

---

## 📝 Notes

- All critical safety features are implemented
- Focus is now on advanced user options and polish
- Recovery script handles most installation failures
- Framework 13 is primary target, other platforms secondary

For detailed implementation history, see:

- Git commit log
- docs/INSTALLATION_KNOWLEDGE.md
- Individual platform README files
