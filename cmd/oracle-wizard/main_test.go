package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGetDedicatedKeyPaths(t *testing.T) {
	priv, pub := getDedicatedKeyPaths()
	if !strings.HasSuffix(priv, dedicatedSSHKeyName) {
		t.Errorf("expected private key to end with %s, got %s", dedicatedSSHKeyName, priv)
	}
	if !strings.HasSuffix(pub, dedicatedSSHKeyName+".pub") {
		t.Errorf("expected public key to end with %s.pub, got %s", dedicatedSSHKeyName, pub)
	}
}

func TestVerifyFileSHA256Wizard(t *testing.T) {
	tempDir := t.TempDir()
	testFile := filepath.Join(tempDir, "image.qcow2")
	data := []byte("wizard test payload")
	if err := os.WriteFile(testFile, data, 0644); err != nil {
		t.Fatalf("failed to write file: %v", err)
	}

	hasher := sha256.New()
	hasher.Write(data)
	expectedHash := hex.EncodeToString(hasher.Sum(nil))

	matches, _, err := verifyFileSHA256(testFile, expectedHash)
	if err != nil || !matches {
		t.Errorf("expected match, got match=%v err=%v", matches, err)
	}
}
