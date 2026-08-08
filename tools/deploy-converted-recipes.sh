#!/usr/bin/env bash
# Deploy converted Guile recipe scripts to replace bash versions
# Creates timestamped backup for easy rollback

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONVERTED_DIR="$REPO_ROOT/tools/converted-scripts"
RECIPES_DIR="$REPO_ROOT/postinstall/recipes"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$REPO_ROOT/archive/recipes-backup-$TIMESTAMP"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Deploying Converted Guile Recipe Scripts${NC}"
echo ""
echo "This will:"
echo "  1. Backup existing .sh files to: archive/recipes-backup-$TIMESTAMP/"
echo "  2. Copy converted .scm files to: postinstall/recipes/"
echo "  3. Update cloudzy/postinstall/customize to call .scm versions"
echo ""
echo -e "${YELLOW}Rollback instructions will be provided after deployment.${NC}"
echo ""
read -p "Continue? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo ""
echo "=== Step 1: Creating backup ==="
mkdir -p "$BACKUP_DIR"

# Backup all existing .sh recipe files
for sh_file in "$RECIPES_DIR"/*.sh; do
    if [ -f "$sh_file" ]; then
        filename=$(basename "$sh_file")
        echo "  Backing up: $filename"
        cp "$sh_file" "$BACKUP_DIR/"
    fi
done

echo -e "${GREEN}✓ Backup created at: $BACKUP_DIR${NC}"
echo ""

echo "=== Step 2: Deploying .scm files ==="

# Deploy each converted script (simpler approach without associative arrays)
deploy_script() {
    local converted_name="$1"
    local target_name="$2"
    local converted_path="$CONVERTED_DIR/$converted_name"
    local target_path="$RECIPES_DIR/$target_name"

    if [ ! -f "$converted_path" ]; then
        echo -e "${YELLOW}  ⚠ Not found: $converted_name (skipping)${NC}"
        return 1
    fi

    echo "  Copying: $converted_name → $target_name"
    cp "$converted_path" "$target_path"
    chmod +x "$target_path"
    return 0
}

# Deploy all recipe scripts
deploy_script "postinstall_recipes_add-development.scm" "add-development.scm"
deploy_script "postinstall_recipes_add-doom-emacs.scm" "add-doom-emacs.scm"
deploy_script "postinstall_recipes_add-fonts.scm" "add-fonts.scm"
deploy_script "postinstall_recipes_add-spacemacs.scm" "add-spacemacs.scm"
deploy_script "postinstall_recipes_add-vanilla-emacs.scm" "add-vanilla-emacs.scm"

echo -e "${GREEN}✓ .scm files deployed to: $RECIPES_DIR/${NC}"
echo ""

echo "=== Step 3: Updating cloudzy/postinstall/customize ==="

CUSTOMIZE_FILE="$REPO_ROOT/cloudzy/postinstall/customize"
CUSTOMIZE_BACKUP="$BACKUP_DIR/customize.backup"

# Backup customize script
cp "$CUSTOMIZE_FILE" "$CUSTOMIZE_BACKUP"
echo "  Backed up: cloudzy/postinstall/customize"

# Update customize script to call .scm instead of .sh
sed -i.tmp \
    -e 's|source "$INSTALL_ROOT/postinstall/recipes/add-spacemacs.sh" && add_spacemacs|guile --no-auto-compile -s "$INSTALL_ROOT/postinstall/recipes/add-spacemacs.scm"|' \
    -e 's|source "$INSTALL_ROOT/postinstall/recipes/add-development.sh" && add_development|guile --no-auto-compile -s "$INSTALL_ROOT/postinstall/recipes/add-development.scm"|' \
    -e 's|source "$INSTALL_ROOT/postinstall/recipes/add-fonts.sh" && add_fonts|guile --no-auto-compile -s "$INSTALL_ROOT/postinstall/recipes/add-fonts.scm"|' \
    "$CUSTOMIZE_FILE"

# Remove sed backup file
rm -f "$CUSTOMIZE_FILE.tmp"

echo -e "${GREEN}✓ Updated: cloudzy/postinstall/customize${NC}"
echo ""

echo "=== Step 4: Verification ==="
echo ""
echo "Changed lines in cloudzy/postinstall/customize:"
diff "$CUSTOMIZE_BACKUP" "$CUSTOMIZE_FILE" || true
echo ""

echo -e "${GREEN}=== Deployment Complete! ===${NC}"
echo ""
echo "Files deployed:"
for scm_file in "$RECIPES_DIR"/add-*.scm; do
    if [ -f "$scm_file" ]; then
        echo "  ✓ $scm_file"
    fi
done
echo ""

echo "=== ROLLBACK INSTRUCTIONS ==="
echo ""
echo "If something goes wrong, restore from backup:"
echo ""
echo -e "${YELLOW}# Restore all recipe files:${NC}"
echo "  cp $BACKUP_DIR/*.sh postinstall/recipes/"
echo "  cp $BACKUP_DIR/customize.backup cloudzy/postinstall/customize"
echo ""
echo -e "${YELLOW}# Or restore individual files:${NC}"
echo "  cp $BACKUP_DIR/add-spacemacs.sh postinstall/recipes/"
echo "  cp $BACKUP_DIR/add-development.sh postinstall/recipes/"
echo "  cp $BACKUP_DIR/add-fonts.sh postinstall/recipes/"
echo ""
echo -e "${YELLOW}# If deployed to git, rollback with:${NC}"
echo "  git checkout HEAD~1 postinstall/recipes/*.scm cloudzy/postinstall/customize"
echo ""
echo "Backup location: $BACKUP_DIR"
echo ""
echo "=== NEXT STEPS ==="
echo ""
echo "1. Test the customize menu locally:"
echo "   cd cloudzy/postinstall && ./customize"
echo ""
echo "2. Update SOURCE_MANIFEST.txt:"
echo "   ./update-manifest.sh"
echo ""
echo "3. Commit changes:"
echo "   git add postinstall/recipes/*.scm cloudzy/postinstall/customize"
echo "   git commit -m \"Deploy Guile recipe scripts for cloudzy\""
echo ""
echo "4. Test on Cloudzy VPS (fresh install recommended)"
echo ""
