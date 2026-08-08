#!/usr/bin/env bash
# Test runner for Guile config helper

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER_SCRIPT="$REPO_ROOT/lib/guile-config-helper.scm"
TEST_CONFIG="$SCRIPT_DIR/test-config.scm"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${BLUE}Testing Guile Config Helper${NC}"
echo ""

# Make helper executable
chmod +x "$HELPER_SCRIPT"

# Test 1: Read and parse config
echo "Test 1: Verify helper can read config..."
cp "$TEST_CONFIG" "$SCRIPT_DIR/test-work.scm"
if guile --no-auto-compile -s "$HELPER_SCRIPT" check-service "$SCRIPT_DIR/test-work.scm" "network-manager-service-type" 2>/dev/null; then
    echo -e "${RED}✗ Should not have found service yet${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Config parsing works${NC}"
echo ""

# Test 2: Add NetworkManager service
echo "Test 2: Add NetworkManager service..."
guile --no-auto-compile -s "$HELPER_SCRIPT" add-service \
    "$SCRIPT_DIR/test-work.scm" \
    "(gnu services networking)" \
    "(service network-manager-service-type)"

if guile --no-auto-compile -s "$HELPER_SCRIPT" check-service "$SCRIPT_DIR/test-work.scm" "network-manager-service-type" 2>/dev/null; then
    echo -e "${GREEN}✓ Service added successfully${NC}"
else
    echo -e "${RED}✗ Service not found after adding${NC}"
    exit 1
fi
echo ""

# Test 3: Verify config structure
echo "Test 3: Verify config structure..."
if grep -q "(services" "$SCRIPT_DIR/test-work.scm" && \
   grep -q "(append" "$SCRIPT_DIR/test-work.scm" && \
   grep -q "network-manager-service-type" "$SCRIPT_DIR/test-work.scm"; then
    echo -e "${GREEN}✓ Config structure is correct${NC}"
else
    echo -e "${RED}✗ Config structure is incorrect${NC}"
    cat "$SCRIPT_DIR/test-work.scm"
    exit 1
fi
echo ""

# Test 4: Add second service to existing list
echo "Test 4: Add GNOME desktop service..."
guile --no-auto-compile -s "$HELPER_SCRIPT" add-service \
    "$SCRIPT_DIR/test-work.scm" \
    "(gnu services desktop)" \
    "(service gnome-desktop-service-type)"

if grep -q "gnome-desktop-service-type" "$SCRIPT_DIR/test-work.scm"; then
    echo -e "${GREEN}✓ Second service added successfully${NC}"
else
    echo -e "${RED}✗ Second service not found${NC}"
    exit 1
fi
echo ""

# Test 5: Verify both services are present
echo "Test 5: Verify both services are in the list..."
if grep -q "network-manager-service-type" "$SCRIPT_DIR/test-work.scm" && \
   grep -q "gnome-desktop-service-type" "$SCRIPT_DIR/test-work.scm"; then
    echo -e "${GREEN}✓ Both services present${NC}"
else
    echo -e "${RED}✗ Services missing${NC}"
    exit 1
fi
echo ""

# Show final config
echo "Final config:"
echo "============="
cat "$SCRIPT_DIR/test-work.scm"
echo ""

# -----------------------------------------------------------------------------
# Test 6: switch-to-desktop
#
# Regression. add_desktop used to sed %base-services -> %desktop-services and
# stop there. %desktop-services is a SUPERSET, so the services a minimal config
# lists explicitly then exist twice and the build dies with
#
#   guix system: error: more than one target service of type 'dbus'
#
# Worse, a service carrying a configuration record -- framework-dual gives
# NetworkManager a DNS block -- must not simply be deleted, or the setting
# disappears with no error at all.
# -----------------------------------------------------------------------------
echo "Test 6: switch-to-desktop removes duplicates and preserves configuration..."

cat > "$SCRIPT_DIR/test-desktop.scm" <<'EOF'
(use-modules (gnu))

(operating-system
  (host-name "test-system")
  (services
   (append
    (list (service network-manager-service-type
                   (network-manager-configuration
                    (extra-configuration-files
                     (list (list "dns.conf" (plain-file "d" "servers=9.9.9.9"))))))
          (service wpa-supplicant-service-type)
          (service dbus-root-service-type)
          (service polkit-service-type)
          (service ntp-service-type))
    (modify-services %base-services
      (guix-service-type
       config => (guix-configuration (inherit config)))))))
EOF

guile --no-auto-compile -s "$HELPER_SCRIPT" switch-to-desktop "$SCRIPT_DIR/test-desktop.scm"

# The base must have switched.
if ! grep -q "%desktop-services" "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ Base was not switched to %desktop-services${NC}"
    exit 1
fi

# ...and the module exporting it must be imported, or the config dies with
# "%desktop-services: unbound variable". switch-to-desktop must be
# self-contained -- not dependent on a later add-service to bring the module in.
if ! grep -q "(gnu services desktop)" "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ (gnu services desktop) not imported${NC}"
    exit 1
fi

# No service %desktop-services already provides may still be INSTANTIATED.
# (A modify-services clause names the same type and is correct -- match only
# the "(service TYPE" instantiation form.)
if grep -qE '\(service (network-manager|wpa-supplicant|dbus-root|polkit|ntp)-service-type' \
     "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ A duplicate service survived -- build would fail with${NC}"
    echo -e "${RED}  \"more than one target service of type ...\"${NC}"
    exit 1
fi

# NetworkManager carried configuration; it must have been preserved as a clause,
# not silently dropped along with the service.
if ! grep -q "network-manager-service-type" "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ NetworkManager configuration was lost entirely${NC}"
    exit 1
fi
if ! grep -q "dns.conf" "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ NetworkManager DNS configuration was dropped${NC}"
    exit 1
fi
if ! grep -q "inherit config" "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ Preserved clause must inherit the base service value${NC}"
    exit 1
fi

# The pre-existing modify-services clause must survive alongside the new one.
if ! grep -q "guix-service-type" "$SCRIPT_DIR/test-desktop.scm"; then
    echo -e "${RED}✗ Existing modify-services clause was clobbered${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Duplicates removed, NetworkManager configuration preserved${NC}"
echo ""

# Clean up
rm -f "$SCRIPT_DIR/test-work.scm" "$SCRIPT_DIR/test-desktop.scm"

# Personal configuration contract.
#
# The suite itself is Guile (CLAUDE.md language policy): the thing under test is
# a Guile script and the contract it parses is an S-expression, so asserting
# from bash would mean grepping for parentheses. Dispatched from here so
# ./run-tests.sh keeps a single entry point.
guile --no-auto-compile -s "$SCRIPT_DIR/test-personal-config.scm"

echo -e "${GREEN}All Guile helper tests passed!${NC}"
