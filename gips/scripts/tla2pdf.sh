#!/usr/bin/env bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path-to-tla-file>"
    exit 1
fi

# Get absolute path to the repo root to find tla2tools.jar
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLA_FILE="$1"
DIR=$(dirname "$TLA_FILE")
BASE=$(basename "$TLA_FILE" .tla)

EXPECTED_SHA="ab323b79802aedc3203b3f9af37c6aca3ed43f4e0225b36f2aa77b26de46c05f"
JAR_PATH="$ROOT_DIR/.tools/tla2tools.jar"

fetch_jar() {
    echo "Downloading tla2tools.jar..."
    mkdir -p "$ROOT_DIR/.tools"
    wget --https-only -qO "$JAR_PATH" https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
}

if [ -f "$JAR_PATH" ]; then
    ACTUAL_SHA=$(shasum -a 256 "$JAR_PATH" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        fetch_jar
    fi
else
    fetch_jar
fi

ACTUAL_SHA=$(shasum -a 256 "$JAR_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "Error: Checksum mismatch for tla2tools.jar!"
    exit 1
fi

echo "Compiling $TLA_FILE to PDF..."
cd "$DIR"

BUILD_DIR=".build"
mkdir -p "$BUILD_DIR"
cp "$BASE.tla" "$BUILD_DIR/"
cd "$BUILD_DIR"

# Run tla2tex (creates .tex and .dvi)
java -cp "$ROOT_DIR/.tools/tla2tools.jar" tla2tex.TLA "$BASE.tla" >/dev/null

# Run pdflatex (creates .pdf, .aux, .log)
pdflatex -interaction=nonstopmode "$BASE.tex" >/dev/null

# Move PDF back to original dir
mv "$BASE.pdf" ../

echo "Generated $DIR/$BASE.pdf"
