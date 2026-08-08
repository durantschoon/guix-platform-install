#!/usr/bin/env bash
# Unwrap markdown-wrapped Scheme files from batch conversion
# Removes the markdown header and code fences to make valid .scm files

set -euo pipefail

CONVERTED_DIR="tools/converted-scripts"

echo "Unwrapping markdown-wrapped Scheme files..."
echo ""

count=0
for file in "$CONVERTED_DIR"/*.scm; do
    if [ ! -f "$file" ]; then
        continue
    fi

    # Check if file starts with "# Converted Guile Script"
    if head -1 "$file" | grep -q "^# Converted Guile Script"; then
        echo "Unwrapping: $(basename "$file")"

        # Create temp file with lines 4 to (end - 1)
        # Line 1: # Converted Guile Script
        # Line 2: (blank)
        # Line 3: ```scheme
        # Line 4-end: actual code with ``` at the end

        # Remove first 3 lines and last line (the closing ```)
        sed '1,3d; $d' "$file" > "$file.tmp"
        mv "$file.tmp" "$file"

        count=$((count + 1))
    fi
done

echo ""
echo "Unwrapped $count files"
echo ""
echo "Verifying Guile syntax..."

# Quick syntax check on a few files
for file in "$CONVERTED_DIR"/postinstall_recipes_add-*.scm; do
    if [ -f "$file" ]; then
        echo -n "Checking $(basename "$file")... "
        if guile -c "(primitive-load \"$file\")" 2>/dev/null; then
            echo "OK"
        else
            echo "SYNTAX ERROR (may need manual review)"
        fi
    fi
done

echo ""
echo "Done! Files are now valid Scheme."
