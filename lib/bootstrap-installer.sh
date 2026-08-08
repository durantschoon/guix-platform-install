#!/run/current-system/profile/bin/bash
set -euo pipefail

# Bootstrap script to build and run the Guix installer from source
# Verification strategy:
#   1. Git verifies the commit/tag integrity when cloning
#   2. Go verifies go.mod and go.sum (if external deps exist)
#   3. Source code is compiled locally before execution

REPO_OWNER="${GUIX_INSTALL_REPO:-durantschoon/guix-platform-install}"
REPO_REF="${GUIX_INSTALL_REF:-main}"

# Parse channel arguments
CHANNEL_REPO=""
CHANNEL_BRANCH="main"
CHANNEL_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --channel-repo)
            CHANNEL_REPO="$2"
            shift 2
            ;;
        --channel-branch)
            CHANNEL_BRANCH="$2"
            shift 2
            ;;
        --channel-path)
            CHANNEL_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Use GUIX_PLATFORM environment variable to set platform (cloudzy, framework, framework-dual)"
            exit 1
            ;;
    esac
done

# Get platform from environment variable (default: cloudzy)
PLATFORM="${GUIX_PLATFORM:-cloudzy}"

echo "=== Guix Installer Bootstrap ==="
echo "Repository: ${REPO_OWNER}"
echo "Reference: ${REPO_REF}"
if [[ -n "$CHANNEL_REPO" ]]; then
    echo "Channel Repository: ${CHANNEL_REPO}"
    echo "Channel Branch: ${CHANNEL_BRANCH}"
    echo "Channel Path: ${CHANNEL_PATH}"
fi
echo ""

# Set console font early if USEBIGFONT is set (before installer runs)
if [[ -n "${USEBIGFONT:-}" ]]; then
    # Check if user wants to keep current font (0 = skip font change)
    if [[ "${USEBIGFONT}" == "0" ]]; then
        echo "USEBIGFONT=0: Keeping current font (skipping font change)"
        echo ""
    else
        echo "Setting larger console font (USEBIGFONT enabled)..."
        
        FONT_DIR="/run/current-system/profile/share/consolefonts"
        FONT_NAME=""
        
        # Determine which font to use
        if [[ "${USEBIGFONT}" == "1" ]] || [[ "${USEBIGFONT}" == "yes" ]] || [[ "${USEBIGFONT}" == "true" ]] || [[ "${USEBIGFONT}" == "t" ]]; then
        # Default to solar24x32 for boolean values
        FONT_NAME="solar24x32"
    else
        # Use the specified font name
        FONT_NAME="${USEBIGFONT}"
    fi
    
    if [[ -d "$FONT_DIR" ]]; then
        # Check if the specified font exists (match on prefix, handles .psf, .psfu, .psf.gz, etc.)
        FONT_FOUND=""
        # First try exact matches
        if [[ -f "$FONT_DIR/${FONT_NAME}.psf" ]]; then
            FONT_FOUND="$FONT_DIR/${FONT_NAME}.psf"
        elif [[ -f "$FONT_DIR/${FONT_NAME}.psfu" ]]; then
            FONT_FOUND="$FONT_DIR/${FONT_NAME}.psfu"
        elif [[ -f "$FONT_DIR/${FONT_NAME}" ]]; then
            FONT_FOUND="$FONT_DIR/${FONT_NAME}"
        else
            # Try prefix matching (handles .psf.gz, .psfu.gz, etc.)
            # Match files that start with font name followed by a dot
            while IFS= read -r font_file; do
                # Extract base name (remove .psf, .psfu, .psf.gz, etc.)
                font_base=$(echo "$font_file" | sed 's/\.psf.*$//' | sed 's/\.psfu.*$//')
                if [[ "$font_base" == "$FONT_NAME" ]]; then
                    FONT_FOUND="$FONT_DIR/$font_file"
                    break
                fi
            done < <(ls "$FONT_DIR" 2>/dev/null | grep -E "^${FONT_NAME}\.")
        fi
        
        # If specified font not found, try default solar24x32
        if [[ -z "$FONT_FOUND" ]]; then
            if [[ -f "$FONT_DIR/solar24x32.psf" ]] || [[ -f "$FONT_DIR/solar24x32.psfu" ]]; then
                FONT_NAME="solar24x32"
                if [[ -f "$FONT_DIR/solar24x32.psf" ]]; then
                    FONT_FOUND="$FONT_DIR/solar24x32.psf"
                else
                    FONT_FOUND="$FONT_DIR/solar24x32.psfu"
                fi
                echo "  [WARN] Font '${USEBIGFONT}' not found, using default: solar24x32"
            fi
        fi
        
        # Set the font if found
        if [[ -n "$FONT_FOUND" ]]; then
            if command -v setfont >/dev/null 2>&1; then
                # Remove extension for setfont command
                FONT_BASE=$(echo "$FONT_FOUND" | sed 's/\.psf.*$//')
                if sudo setfont "$FONT_BASE" 2>/dev/null; then
                    echo "  [OK] Set font: $(basename "$FONT_BASE")"
                else
                    echo "  [WARN] Could not set font (may need sudo)"
                fi
            else
                echo "  [WARN] setfont command not found"
            fi
        else
            # Font not found - but check if we're already using a large font
            CURRENT_FONT=""
            if command -v showconsolefont >/dev/null 2>&1; then
                # Get current font info (this shows the font metadata)
                CURRENT_FONT_INFO=$(showconsolefont 2>/dev/null | head -1)
                # Extract font name if possible (format varies)
                if [[ -n "$CURRENT_FONT_INFO" ]]; then
                    CURRENT_FONT=$(echo "$CURRENT_FONT_INFO" | awk '{print $NF}')
                fi
            fi

            # Check if current font is already a large font (24x32 or bigger)
            if [[ -n "$CURRENT_FONT" ]] && [[ "$CURRENT_FONT" =~ (24|32|36) ]]; then
                echo ""
                echo "  [INFO] Current font appears to be already large: $CURRENT_FONT"
                echo "  Skipping font selection (already using a suitable font)"
                echo ""
            else
                # Font not found - ask user to choose
                echo ""
                echo "  [WARN] Font '${FONT_NAME}' not found in $FONT_DIR"
                echo ""
                echo "  Please choose a font from the list below, or keep the current font:"
                echo ""

                # Mark that we've interacted with user (stdin is working)
                STDIN_VERIFIED=true

                # Only list fonts with size >= 16 in name (large fonts for readability)
                # This prevents small fonts (8, 10, 12, 14) from cluttering the display
                FONTS=()

            if [[ -d "$FONT_DIR" ]]; then
                while IFS= read -r font_file; do
                    # Skip README, ERROR, and other non-font files
                    if [[ "$font_file" =~ README ]] || [[ "$font_file" =~ readme ]] || [[ "$font_file" =~ ERROR ]]; then
                        continue
                    fi

                    # Remove extensions to get base name
                    font_base=$(echo "$font_file" | sed 's/\.psf.*$//')

                    # Extract all 2-digit numbers from font name
                    # Font names like "Lat2-Terminus16.psf.gz" contain the size
                    if [[ "$font_base" =~ ([0-9]{2}) ]]; then
                        size="${BASH_REMATCH[1]}"
                        # Strip leading zeros to avoid octal interpretation (08, 09 would fail)
                        size=$((10#$size))
                        # Only include fonts with size >= 16
                        if [[ $size -ge 16 ]]; then
                            FONTS+=("$font_base")
                        fi
                    fi
                done < <(ls "$FONT_DIR" 2>/dev/null | sort -u)
            fi

            # Show fonts in multiple columns
            if [[ ${#FONTS[@]} -gt 0 ]]; then
                echo "  Available large fonts (size >= 16):"
                # Calculate number of columns (3 columns, or fewer if not enough fonts)
                COLS=3
                ROWS=$(( (${#FONTS[@]} + COLS - 1) / COLS ))
                for ((row=0; row<ROWS; row++)); do
                    printf "    "
                    for ((col=0; col<COLS; col++)); do
                        idx=$((row + col * ROWS))
                        if [[ $idx -lt ${#FONTS[@]} ]]; then
                            printf "%2d) %-25s" $((idx+1)) "${FONTS[$idx]}"
                        fi
                    done
                    echo ""
                done
                echo ""
            fi

            # Option to keep current font
            total_fonts=${#FONTS[@]}
            if [[ $total_fonts -gt 0 ]]; then
                echo "    $(($total_fonts + 1))) Keep current font (skip font change)"
                echo ""

                # Prompt user (stdin already verified by this point)
                while true; do
                    read -p "  Enter your choice [1-$(($total_fonts + 1))]: " choice </dev/tty
                    # Mark stdin as verified
                    STDIN_VERIFIED=true

                    if [[ "$choice" =~ ^[0-9]+$ ]]; then
                        if [[ "$choice" -ge 1 && "$choice" -le $total_fonts ]]; then
                            SELECTED_FONT="${FONTS[$((choice-1))]}"
                            break
                        elif [[ "$choice" -eq $(($total_fonts + 1)) ]]; then
                            echo "  Keeping current font"
                            SELECTED_FONT=""
                            break
                        else
                            echo "  Invalid choice. Please enter a number between 1 and $(($total_fonts + 1))"
                        fi
                    else
                        echo "  Invalid input. Please enter a number"
                    fi
                done
            fi

            # Set selected font if user chose one
            if [[ -n "$SELECTED_FONT" ]]; then
                # Try to find the font file (match on prefix, handles .psf, .psfu, .psf.gz, etc.)
                SELECTED_FONT_FOUND=""
                # First try exact matches
                if [[ -f "$FONT_DIR/${SELECTED_FONT}.psf" ]]; then
                    SELECTED_FONT_FOUND="$FONT_DIR/${SELECTED_FONT}.psf"
                elif [[ -f "$FONT_DIR/${SELECTED_FONT}.psfu" ]]; then
                    SELECTED_FONT_FOUND="$FONT_DIR/${SELECTED_FONT}.psfu"
                elif [[ -f "$FONT_DIR/${SELECTED_FONT}" ]]; then
                    SELECTED_FONT_FOUND="$FONT_DIR/${SELECTED_FONT}"
                else
                    # Try prefix matching (handles .psf.gz, .psfu.gz, etc.)
                    # Match files that start with font name followed by a dot
                    while IFS= read -r font_file; do
                        # Extract base name (remove .psf, .psfu, .psf.gz, etc.)
                        font_base=$(echo "$font_file" | sed 's/\.psf.*$//' | sed 's/\.psfu.*$//')
                        if [[ "$font_base" == "$SELECTED_FONT" ]]; then
                            SELECTED_FONT_FOUND="$FONT_DIR/$font_file"
                            break
                        fi
                    done < <(ls "$FONT_DIR" 2>/dev/null | grep -E "^${SELECTED_FONT}\.")
                fi
                
                if [[ -n "$SELECTED_FONT_FOUND" ]] && command -v setfont >/dev/null 2>&1; then
                    FONT_BASE=$(echo "$SELECTED_FONT_FOUND" | sed 's/\.psf.*$//')
                    if sudo setfont "$FONT_BASE" 2>/dev/null; then
                        echo "  [OK] Set font: $(basename "$FONT_BASE")"
                    else
                        echo "  [WARN] Could not set font (may need sudo)"
                    fi
                else
                    echo "  [WARN] Could not set selected font"
                fi
            fi
            fi  # End of "else" for current font check
        fi
    else
        echo "  [WARN] Font directory not found: $FONT_DIR"
        echo "  Font will be set after installation completes"
    fi
    echo ""
    fi  # End of "else" for USEBIGFONT != "0"
fi

# Test that stdin is working before proceeding (skip if already verified via font selection)
if [[ -z "${STDIN_VERIFIED:-}" ]]; then
    echo "Testing stdin availability..."
    read -p "Press Enter to continue (or Ctrl+C to abort): " -r </dev/tty
    echo ""
fi

# Create temporary directory
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

cd "$WORK_DIR"

# Download repository tarball (avoids git HTTPS issues on Guix ISO)
echo "Downloading repository..."
TARBALL_URL="https://github.com/${REPO_OWNER}/archive/refs/heads/${REPO_REF}.tar.gz"
if ! curl -k -fsSL "$TARBALL_URL" -o repo.tar.gz; then
    echo "Error: Failed to download repository"
    exit 1
fi

# Extract tarball
echo "Extracting..."
tar -xzf repo.tar.gz
cd guix-platform-install-*

# Show what we're building
echo ""
echo "Building from: ${REPO_OWNER} (${REPO_REF})"
echo ""

# Set up Go cache to use /tmp (more space on ISO)
# This needs to be done early as it's used for hash-to-words and main installer builds
mkdir -p /tmp/go-cache /tmp/go-tmp
export GOCACHE=/tmp/go-cache
export GOTMPDIR=/tmp/go-tmp

# Verify source manifest (ensures GitHub CDN has latest version)
if [[ -f SOURCE_MANIFEST.txt ]]; then
    echo "Verifying source file checksums..."
    echo ""

    # Extract and verify Go source files
    # Use process substitution to avoid stdin redirection issues
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        # Parse "hash  filepath" format
        expected_hash=$(echo "$line" | awk '{print $1}')
        filepath=$(echo "$line" | awk '{print $2}')

        # Skip if not a file (might be a header)
        [[ ! -f "$filepath" ]] && continue

        # Calculate actual hash
        actual_hash=$(shasum -a 256 "$filepath" | awk '{print $1}')

        if [[ "$actual_hash" != "$expected_hash" ]]; then
            echo "ERROR: Checksum mismatch for $filepath"
            echo "  Expected: $expected_hash"
            echo "  Got:      $actual_hash"
            echo ""
            echo "This likely means GitHub's CDN hasn't caught up with the latest push."
            echo "Wait a few minutes and try again, or check the repo on GitHub."
            exit 1
        fi

        echo "[OK] $filepath"
    done < <(cat SOURCE_MANIFEST.txt)

    echo ""
    echo "All source files verified!"
    echo ""

    # Build hash-to-words helper tool early (for manifest verification)
    # This is safe because we just verified the source files
    echo "Building hash-to-words helper tool for verification..."
    if go build -o hash-to-words ./cmd/hash-to-words 2>/dev/null; then
        chmod +x hash-to-words
        echo "[OK] hash-to-words tool built"
    else
        echo "[WARN] hash-to-words build failed (will use hex hash only)"
    fi
    echo ""

    # Calculate manifest hash and ask user to verify
    MANIFEST_HASH=$(shasum -a 256 SOURCE_MANIFEST.txt | awk '{print $1}')
    
    # Try to convert to words if hash-to-words is available
    MANIFEST_WORDS=""
    if [[ -f hash-to-words ]]; then
        MANIFEST_WORDS=$(echo "$MANIFEST_HASH" | ./hash-to-words 2>/dev/null)
    fi
    
    echo "================================================================"
    echo "MANIFEST HASH VERIFICATION"
    echo "================================================================"
    echo ""
    echo "The manifest hash for this download is:"
    echo "  Hash: $MANIFEST_HASH"
    if [[ -n "$MANIFEST_WORDS" ]]; then
        echo "  Words: $MANIFEST_WORDS"

        # Extract first 3 and last 3 words
        WORD_ARRAY=($MANIFEST_WORDS)
        FIRST_THREE="${WORD_ARRAY[0]} ${WORD_ARRAY[1]} ${WORD_ARRAY[2]}"
        LAST_IDX=$((${#WORD_ARRAY[@]} - 1))
        LAST_THREE="${WORD_ARRAY[$((LAST_IDX - 2))]} ${WORD_ARRAY[$((LAST_IDX - 1))]} ${WORD_ARRAY[$LAST_IDX]}"
        echo "  Quick: $FIRST_THREE ... $LAST_THREE"

        echo ""
        echo "You can verify using either:"
        echo "  - Compare the hex hash above"
        echo "  - Compare the words above (easier to read aloud)"
    fi
    echo ""
    echo "Before proceeding, you should verify this matches the expected hash"
    echo "from the repository documentation or a trusted source."
    echo ""

    if read -p "Does this hash match what you expect? [y/N] " -n 1 -r </dev/tty; then
        echo ""
    else
        echo ""
        echo "ERROR: Cannot read from stdin"
        exit 1
    fi

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation aborted by user"
        exit 1
    fi
    echo ""
else
    echo "Warning: SOURCE_MANIFEST.txt not found. Skipping checksum verification."
    echo "  (This is okay but means GitHub CDN freshness isn't verified)"
    echo ""
fi

# Copy critical scripts to /root for manual recovery if needed
echo "Installing critical recovery scripts to /root..."
CRITICAL_SCRIPTS=(
    "lib/clean-install.sh"
    "lib/verify-guix-install.sh"
    "lib/recovery-complete-install.sh"
    "tools/serve-logs.scm"
)

for script in "${CRITICAL_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        cp "$script" /root/
        chmod +x "/root/$(basename "$script")"
        echo "[OK] Copied $(basename "$script") to /root/"
    else
        echo "[WARN] $script not found (skipping)"
    fi
done
echo ""

# Verify go.mod exists
if [[ ! -f go.mod ]]; then
    echo "Error: go.mod not found. This doesn't appear to be a Go module."
    exit 1
fi

# Build the installer and helper tools
# Note: We have no external dependencies, so go.sum won't exist
# Go will still verify the build matches go.mod
# Go cache is already set up from earlier (for hash-to-words build)
echo "Building installer from source..."

if ! go build -o run-remote-steps .; then
    echo "Error: Build failed"
    exit 1
fi

# Verify the binary was created
if [[ ! -f run-remote-steps ]]; then
    echo "Error: Binary not created"
    exit 1
fi

# Note: hash-to-words was already built earlier for manifest verification
# If it failed then, we'll try again here as a fallback
if [[ ! -f hash-to-words ]]; then
    echo "Building hash-to-words helper tool..."
    if go build -o hash-to-words ./cmd/hash-to-words; then
        chmod +x hash-to-words
        echo "[OK] hash-to-words tool built"
    else
        echo "[WARN] hash-to-words build failed (not critical, continuing)"
    fi
fi

# Export channel info for Go installer
export GUIX_CHANNEL_REPO="$CHANNEL_REPO"
export GUIX_CHANNEL_BRANCH="$CHANNEL_BRANCH"
export GUIX_CHANNEL_PATH="$CHANNEL_PATH"

# Export platform for Go installer
export GUIX_PLATFORM="$PLATFORM"

# Show which platform will be used
echo "Platform: $PLATFORM"

# Run the installer
echo ""
echo "Starting installation..."
echo ""
./run-remote-steps
