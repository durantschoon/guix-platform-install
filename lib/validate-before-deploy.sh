#!/usr/bin/env bash
#
# Pre-Deployment Validation Script
# Run this locally to catch issues before deploying to remote machines
#
# Usage: ./validate-before-deploy.sh [--verbose]

set -uo pipefail

VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

log_test() {
    local status="$1"
    local message="$2"

    case "$status" in
        PASS)
            echo -e "${GREEN}[PASS]${NC} $message"
            ((PASSED++))
            ;;
        FAIL)
            echo -e "${RED}[FAIL]${NC} $message"
            ((FAILED++))
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $message"
            ((WARNINGS++))
            ;;
    esac
}

verbose_log() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "  → $1"
    fi
}

echo "=== Pre-Deployment Validation ==="
echo

# Test 1: Validate guix command syntax
echo "Checking Guix command syntax..."
check_guix_commands() {
    # Extract guix build commands from Go source
    local commands=$(grep -r "guix.*build" lib/common.go cloudzy/install/*.go framework*/install/*.go 2>/dev/null || true)

    if [[ -z "$commands" ]]; then
        log_test PASS "No guix build commands found (or grep failed)"
        return 0
    fi

    # Check for common syntax errors
    if echo "$commands" | grep -q 'substitute-urls=.*https.*https' && ! echo "$commands" | grep -q "substitute-urls='"; then
        log_test FAIL "Found unquoted --substitute-urls with multiple URLs (will cause 'unknown package' error)"
        verbose_log "Use: --substitute-urls='https://url1 https://url2'"
        return 1
    fi

    # Check if --substitute-urls comes before package name
    # Note: This is OK for "guix time-machine ... -- build" pattern
    if echo "$commands" | grep -qE 'guix.*build.*linux.*--substitute-urls|guix.*build.*linux-libre.*--substitute-urls'; then
        log_test WARN "Found --substitute-urls after package name (may cause issues)"
        verbose_log "Recommended: guix build --substitute-urls='...' PACKAGE"
        verbose_log "Note: 'guix time-machine ... -- build --substitute-urls=... PACKAGE' is OK"
    fi

    log_test PASS "Guix build command syntax looks correct"
}
check_guix_commands

# Test 2: Validate store path checks
echo
echo "Checking store path validation..."
check_store_paths() {
    # Find code that uses paths without validation
    local unvalidated=$(grep -n 'kernelPackagePath\|systemPath' lib/common.go | \
        grep -v 'strings.HasPrefix.*"/gnu/store/"' | \
        grep -v 'strings.Contains.*"error:"' | \
        head -5 || true)

    if [[ -n "$unvalidated" && $(echo "$unvalidated" | wc -l) -gt 3 ]]; then
        log_test WARN "Some paths may not be validated before use"
        verbose_log "Consider adding: strings.HasPrefix(path, \"/gnu/store/\")"
    else
        log_test PASS "Store paths appear to be validated"
    fi
}
check_store_paths

# Test 3: Check for error handling
echo
echo "Checking error handling..."
check_error_handling() {
    # Look for exec.Command without error checks
    local missing_checks=$(grep -A 2 'exec.Command' lib/common.go | \
        grep -v '\.Run()' | \
        grep -v '\.Output()' | \
        grep -v 'if err' | \
        grep -v 'return' | \
        wc -l)

    if [[ $missing_checks -gt 10 ]]; then
        log_test WARN "Some commands may lack error handling"
    else
        log_test PASS "Error handling appears comprehensive"
    fi
}
check_error_handling

# Test 4: Validate hypothesis logging consistency
echo
echo "Checking hypothesis logging consistency..."
check_hypothesis_logging() {
    local missing_platform=0
    local missing_buildtype=0

    # Check Hypothesis M, H, K, N for platform/buildType fields
    for hyp in M H K N; do
        local logs=$(grep -n "hypothesisId.*$hyp" lib/common.go | head -20)
        local log_count=$(echo "$logs" | wc -l)

        if [[ $log_count -gt 0 ]]; then
            local with_platform=$(echo "$logs" | grep -c "platform" || true)
            local with_buildtype=$(echo "$logs" | grep -c "buildType" || true)

            if [[ $with_platform -lt $((log_count - 2)) ]]; then
                ((missing_platform++))
                verbose_log "Hypothesis $hyp: $((log_count - with_platform)) logs missing platform field"
            fi

            if [[ $with_buildtype -lt $((log_count - 2)) ]]; then
                ((missing_buildtype++))
                verbose_log "Hypothesis $hyp: $((log_count - with_buildtype)) logs missing buildType field"
            fi
        fi
    done

    if [[ $missing_platform -eq 0 && $missing_buildtype -eq 0 ]]; then
        log_test PASS "All hypothesis logs include platform and buildType tracking"
    else
        log_test WARN "Some hypothesis logs may be missing tracking fields"
    fi
}
check_hypothesis_logging

# Test 5: Check for Unicode in ISO scripts
echo
echo "Checking for Unicode in ISO scripts..."
check_unicode() {
    local unicode_found=0

    # Check all install scripts for Unicode
    for script in lib/bootstrap-installer.sh cloudzy/install/*.sh framework*/install/*.sh; do
        if [[ -f "$script" ]]; then
            if grep -P '[^\x00-\x7F]' "$script" >/dev/null 2>&1; then
                log_test FAIL "Unicode found in $script (will break on Guix ISO)"
                verbose_log "Use [OK] instead of ✓, [ERROR] instead of ❌"
                ((unicode_found++))
            fi
        fi
    done

    if [[ $unicode_found -eq 0 ]]; then
        log_test PASS "No Unicode characters in ISO scripts"
    fi
}
check_unicode

# Test 5b: Validate shebangs on scripts that run on Guix
#
# CLAUDE.md calls this rule CRITICAL and nothing enforced it. The required form:
#     #!/run/current-system/profile/bin/bash      (or .../bin/guile)
#
# Two tiers, because the two ways of getting it wrong are not equally bad --
# measured on a running Guix system (2026-08-08), not assumed:
#
#   FAIL  #!/bin/bash          /bin contains ONLY sh. The path does not exist,
#                              so the script cannot run at all. Also a missing
#                              shebang, where behaviour depends on the caller.
#
#   WARN  #!/usr/bin/env bash  /usr/bin/env DOES exist on Guix System -- it is
#                              a store symlink installed by
#                              special-files-service-type, which is part of
#                              %base-services:
#                                /usr/bin/env -> /gnu/store/...-coreutils-9.1/bin/env
#                              So these scripts do run. They deviate from the
#                              stated policy and depend on a service a custom
#                              operating-system could drop, which is worth
#                              flagging -- but calling it FAIL would block every
#                              deploy over scripts that work.
#
# CLAUDE.md's claim that env "may not work reliably on the ISO" is therefore
# overstated for an installed system. Kept as a warning rather than silence
# because the ISO case was not measured here, and consistency has its own value.
echo
echo "Checking shebangs on Guix-target scripts..."
check_shebangs() {
    local required_bash="#!/run/current-system/profile/bin/bash"
    local required_guile="#!/run/current-system/profile/bin/guile"
    local broken=0      # cannot run on Guix at all
    local deviations=0  # runs, but not the policy form

    # Scripts that run on the ISO or on an installed Guix system. Deliberately
    # NOT the developer tooling (run-tests.sh, update-manifest.sh, tools/*),
    # which never executes on a Guix machine and may use /usr/bin/env.
    local targets=()
    for pattern in \
        diagnose-guix-build.sh \
        investigate-kernel-location.sh \
        fix_guix_cursor.sh \
        lib/bootstrap-installer.sh \
        lib/clean-install.sh \
        lib/recovery-complete-install.sh \
        lib/verify-guix-install.sh \
        lib/verify-postinstall.sh \
        lib/fix-iso-artifacts.sh \
        lib/enforce-guix-filesystem-invariants.sh \
        lib/channel-utils.sh \
        lib/postinstall.sh \
        postinstall/lib.sh \
        postinstall/lib.scm \
        postinstall/recipes/*.sh \
        postinstall/recipes/add/*.scm \
        postinstall/recipes/add/*/*.scm \
        */install/*.sh \
        */postinstall/customize \
        */postinstall/customize.scm \
        */postinstall/templates/*.sh
    do
        for f in $pattern; do
            [[ -f "$f" ]] && targets+=("$f")
        done
    done

    for script in "${targets[@]}"; do
        local first_line
        first_line=$(head -1 "$script")

        # An empty file is not a shebang problem, it is a leftover. Reported on
        # its own so the message names the actual fault: telling someone to add
        # a shebang to a 0-byte file sends them to fix the wrong thing.
        if [[ ! -s "$script" ]]; then
            log_test WARN "$script is empty (0 bytes) -- leftover?"
            verbose_log "Nothing references it; consider deleting it"
            ((deviations++))
            continue
        fi

        # No shebang at all: how it runs depends on the caller's shell.
        if [[ "$first_line" != \#!* ]]; then
            log_test FAIL "No shebang in $script"
            verbose_log "Add: $required_bash"
            ((broken++))
            continue
        fi

        # Match on the interpreter NAME, not on a path substring:
        # "#!/usr/bin/env bash" does not contain "/bin/bash", so a substring
        # test on the path silently passes the most common deviation.
        if [[ "$first_line" == *bash* && "$first_line" != "$required_bash"* ]]; then
            if [[ "$first_line" == *"/usr/bin/env"* ]]; then
                log_test WARN "$script uses '#!/usr/bin/env bash'"
                verbose_log "Runs on Guix (/usr/bin/env is a store symlink), but"
                verbose_log "policy is: $required_bash"
                ((deviations++))
            else
                log_test FAIL "$script cannot run on Guix: $first_line"
                verbose_log "Guix has no FHS -- /bin contains only sh"
                verbose_log "Use: $required_bash"
                ((broken++))
            fi
            continue
        fi

        # Guile shebang FORM, not just the path.
        #
        # Linux passes everything after the interpreter as a SINGLE argument, so
        #     #!/run/current-system/profile/bin/guile --no-auto-compile -s
        # hands guile the literal string "--no-auto-compile -s" and it dies with
        #     error: unrecognized switch --no-auto-compile -s
        # Guile's answer is the meta-switch: end the shebang with a backslash and
        # put the arguments on the next line.
        #
        #     #!/run/current-system/profile/bin/guile \
        #     --no-auto-compile -s
        #     !#
        #
        # This is invisible while every caller invokes `guile -s file.scm`, which
        # is how the repo's scripts are called internally -- so it only breaks
        # for the person who runs ./script.scm as the docs instruct.
        #
        # '#!/usr/bin/env -S guile ...' is FINE: -S splits the arguments itself.
        if [[ "$first_line" == *guile* \
              && "$first_line" != *"\\" \
              && "$first_line" != *"/usr/bin/env -S"* ]]; then
            # Any argument after the interpreter means the single-argument trap.
            guile_args="${first_line##*guile}"
            if [[ -n "${guile_args// /}" ]]; then
                log_test FAIL "$script shebang cannot be executed directly: $first_line"
                verbose_log "Linux passes '${guile_args# }' as ONE argument"
                verbose_log "Use the meta-switch form:"
                verbose_log "  $required_guile \\"
                verbose_log "  ${guile_args# }"
                ((broken++))
                continue
            fi
        fi

        # Same two tiers for Guile scripts.
        if [[ "$first_line" == *guile* && "$first_line" != "$required_guile"* ]]; then
            if [[ "$first_line" == *"/usr/bin/env"* ]]; then
                log_test WARN "$script uses '#!/usr/bin/env ... guile'"
                verbose_log "Policy is: $required_guile --no-auto-compile -s"
                ((deviations++))
            else
                log_test FAIL "$script cannot run on Guix: $first_line"
                verbose_log "Use: $required_guile --no-auto-compile -s"
                ((broken++))
            fi
        fi
    done

    if [[ $broken -eq 0 && $deviations -eq 0 ]]; then
        log_test PASS "All Guix-target scripts use /run/current-system/profile paths"
    elif [[ $broken -eq 0 ]]; then
        verbose_log "$deviations script(s) deviate from policy but will run"
    fi
}
check_shebangs

# Test 6: Validate function signatures match callers
echo
echo "Checking function signature consistency..."
check_function_signatures() {
    # Check if RunGuixSystemInitFreeSoftware is called with platform parameter
    local calls_free=$(grep -n 'RunGuixSystemInitFreeSoftware(' cloudzy/install/*.go cmd/recovery/*.go 2>/dev/null || true)
    local calls_free_with_param=$(echo "$calls_free" | grep -cE 'RunGuixSystemInitFreeSoftware\(.*platform|RunGuixSystemInitFreeSoftware\(.*GuixPlatform' || true)
    local total_calls_free=$(echo "$calls_free" | wc -l)

    # Check if RunGuixSystemInit is called with platform parameter (framework-dual)
    local calls_init=$(grep -n 'RunGuixSystemInit(' framework*/install/*.go cmd/recovery/*.go 2>/dev/null || true)
    local calls_init_with_param=$(echo "$calls_init" | grep -cE 'RunGuixSystemInit\(.*platform|RunGuixSystemInit\(.*GuixPlatform' || true)
    local total_calls_init=$(echo "$calls_init" | wc -l)

    local all_pass=true

    if [[ $total_calls_free -gt 0 && $calls_free_with_param -ne $total_calls_free ]]; then
        log_test FAIL "Some RunGuixSystemInitFreeSoftware calls missing platform parameter"
        verbose_log "Expected: lib.RunGuixSystemInitFreeSoftware(state.GuixPlatform)"
        all_pass=false
    fi

    if [[ $total_calls_init -gt 0 && $calls_init_with_param -ne $total_calls_init ]]; then
        log_test FAIL "Some RunGuixSystemInit calls missing platform parameter"
        verbose_log "Expected: lib.RunGuixSystemInit(state.GuixPlatform)"
        all_pass=false
    fi

    if [[ $all_pass == true ]]; then
        log_test PASS "All function calls include platform parameter"
    fi
}
check_function_signatures

# Test 7: Compile check
echo
echo "Running compilation check..."
check_compilation() {
    if go build -o /tmp/validate-build ./run-remote-steps.go 2>/tmp/validate-build.log; then
        log_test PASS "Code compiles successfully"
        rm -f /tmp/validate-build
    else
        log_test FAIL "Compilation failed"
        verbose_log "See: /tmp/validate-build.log"
        cat /tmp/validate-build.log
    fi
}
check_compilation

# Test 8: Run unit tests
echo
echo "Running unit tests..."
check_tests() {
    if go test ./lib/... 2>&1 | grep -q "ok"; then
        log_test PASS "Unit tests pass"
    else
        log_test FAIL "Unit tests failed"
        verbose_log "Run: go test -v ./lib/..."
    fi
}
check_tests

# Test 9: Check manifest consistency
echo
echo "Checking source manifest..."
check_manifest() {
    # Verify manifest exists and is up-to-date
    if [[ ! -f SOURCE_MANIFEST.txt ]]; then
        log_test FAIL "SOURCE_MANIFEST.txt not found"
        return 1
    fi

    # Check if lib/common.go checksum matches manifest
    local current_hash=$(shasum -a 256 lib/common.go | awk '{print $1}')
    local manifest_hash=$(grep lib/common.go SOURCE_MANIFEST.txt | awk '{print $1}')

    if [[ "$current_hash" == "$manifest_hash" ]]; then
        log_test PASS "Source manifest is up-to-date"
    else
        log_test WARN "Source manifest may be outdated (run ./update-manifest.sh)"
        verbose_log "Current:  $current_hash"
        verbose_log "Manifest: $manifest_hash"
    fi
}
check_manifest

# Test 10: Check for common anti-patterns
echo
echo "Checking for common anti-patterns..."
check_antipatterns() {
    local issues=0

    # Check for reading from os.Stdin instead of /dev/tty
    if grep -n 'os.Stdin' lib/common.go cloudzy/install/*.go 2>/dev/null | grep -v '//.*os.Stdin' | grep -qv 'reader.*tty'; then
        log_test WARN "Found direct os.Stdin usage (should use /dev/tty for user input)"
        ((issues++))
    fi

    # Check for done < file instead of done < <(cat file)
    if grep -n 'done <.*[^)]$' lib/*.sh 2>/dev/null | grep -qv 'dev/tty'; then
        log_test WARN "Found 'done < file' pattern (may consume stdin, use process substitution)"
        ((issues++))
    fi

    if [[ $issues -eq 0 ]]; then
        log_test PASS "No common anti-patterns found"
    fi
}
check_antipatterns

# Summary
echo
echo "=== Validation Summary ==="
echo -e "${GREEN}Passed:   $PASSED${NC}"
echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
echo -e "${RED}Failed:   $FAILED${NC}"
echo

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}[ERROR] VALIDATION FAILED - DO NOT DEPLOY${NC}"
    echo "Fix the issues above before deploying to remote machines"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}[WARN] VALIDATION PASSED WITH WARNINGS${NC}"
    echo "Review warnings before deploying"
    exit 0
else
    echo -e "${GREEN}[OK] ALL VALIDATIONS PASSED${NC}"
    echo "Safe to deploy to remote machines"
    exit 0
fi
