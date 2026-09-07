package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestVerifyFileSHA256(t *testing.T) {
	tempDir := t.TempDir()
	testFile := filepath.Join(tempDir, "sample.bin")
	content := []byte("guix oracle generic test image content")

	if err := os.WriteFile(testFile, content, 0644); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	hasher := sha256.New()
	hasher.Write(content)
	expectedHash := hex.EncodeToString(hasher.Sum(nil))

	matches, actual, err := verifyFileSHA256(testFile, expectedHash)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !matches {
		t.Errorf("expected hash match, got actual=%s expected=%s", actual, expectedHash)
	}

	// Mismatched hash
	wrongHash := "0000000000000000000000000000000000000000000000000000000000000000"
	matchesWrong, _, err := verifyFileSHA256(testFile, wrongHash)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if matchesWrong {
		t.Errorf("expected hash mismatch, but got match")
	}

	// Non-existent file
	_, _, err = verifyFileSHA256(filepath.Join(tempDir, "non-existent"), expectedHash)
	if err == nil {
		t.Errorf("expected error for non-existent file, got nil")
	}
}
