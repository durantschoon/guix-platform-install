#!/usr/bin/env bash
# Rollback recipe deployment - restore bash versions from backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_DIR="$REPO_ROOT/archive"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}Recipe Deployment Rollback${NC}"
echo ""

# Find most recent backup
LATEST_BACKUP=$(ls -td "$ARCHIVE_DIR"/recipes-backup-* 2>/dev/null | head -1)

if [ -z "$LATEST_BACKUP" ]; then
    echo -e "${RED}Error: No backup found in archive/recipes-backup-*${NC}"
    echo ""
    echo "Available backups:"
    ls -ld "$ARCHIVE_DIR"/recipes-backup-* 2>/dev/null || echo "  (none)"
    exit 1
fi

echo "Found backup: $LATEST_BACKUP"
echo ""
echo "This will restore:"
echo "  - All .sh files from backup to postinstall/recipes/"
echo "  - Original cloudzy/postinstall/customize script"
echo ""
echo -e "${YELLOW}Current .scm files will be removed (but preserved in tools/converted-scripts/)${NC}"
echo ""
read -p "Continue with rollback? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Rollback cancelled."
    exit 0
fi

echo ""
echo "=== Rolling back recipe deployment ==="

# Restore .sh files
echo "Restoring .sh files..."
cp "$LATEST_BACKUP"/*.sh "$REPO_ROOT/postinstall/recipes/" 2>/dev/null || echo "  (no .sh files to restore)"

# Restore customize script
if [ -f "$LATEST_BACKUP/customize.backup" ]; then
    echo "Restoring cloudzy/postinstall/customize..."
    cp "$LATEST_BACKUP/customize.backup" "$REPO_ROOT/cloudzy/postinstall/customize"
fi

# Remove deployed .scm files (keep originals in tools/converted-scripts/)
echo "Removing deployed .scm files..."
for scm_file in "$REPO_ROOT/postinstall/recipes"/*.scm; do
    if [ -f "$scm_file" ]; then
        echo "  Removing: $(basename "$scm_file")"
        rm "$scm_file"
    fi
done

echo ""
echo -e "${GREEN}✓ Rollback complete!${NC}"
echo ""
echo "Restored from: $LATEST_BACKUP"
echo ""
echo "Next steps:"
echo "  1. Verify files: ls -la postinstall/recipes/"
echo "  2. Test customize menu: cd cloudzy/postinstall && ./customize"
echo "  3. If using git, discard changes: git checkout postinstall/recipes/ cloudzy/postinstall/customize"
echo ""
