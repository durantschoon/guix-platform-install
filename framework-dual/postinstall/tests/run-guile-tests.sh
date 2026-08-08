#!/usr/bin/env bash
# Test runner for Guile config helper

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SCRIPT="$SCRIPT_DIR/../../../lib/guile-config-helper.scm"
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

# Clean up
rm -f "$SCRIPT_DIR/test-work.scm"

echo -e "${GREEN}All Guile helper tests passed!${NC}"
