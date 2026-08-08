#!/usr/bin/env bash
# Master test runner for all Guile library tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/.."

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${BLUE}Testing Guile Library${NC}"
echo ""

# Run config helper tests
echo "Running config helper tests..."
"$SCRIPT_DIR/../../framework-dual/postinstall/tests/run-guile-tests.sh"

echo ""
echo -e "${GREEN}All Guile library tests passed![NC}"
