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

func TestDotEnvReadAndUpdate(t *testing.T) {
	tempDir := t.TempDir()
	envPath := filepath.Join(tempDir, ".env")

	// Initially empty or non-existent
	if val := readDotEnvKey(envPath, "ORACLE_INSTANCE_IP"); val != "" {
		t.Errorf("expected empty string for non-existent file, got %q", val)
	}

	// Append key
	if err := updateOrAppendDotEnv(envPath, "ORACLE_INSTANCE_IP", "129.159.162.200"); err != nil {
		t.Fatalf("failed to update .env: %v", err)
	}

	if val := readDotEnvKey(envPath, "ORACLE_INSTANCE_IP"); val != "129.159.162.200" {
		t.Errorf("expected 129.159.162.200, got %q", val)
	}

	// Append another key without clobbering
	if err := updateOrAppendDotEnv(envPath, "FOO", "BAR"); err != nil {
		t.Fatalf("failed to update .env: %v", err)
	}

	if val := readDotEnvKey(envPath, "FOO"); val != "BAR" {
		t.Errorf("expected BAR, got %q", val)
	}
	if val := readDotEnvKey(envPath, "ORACLE_INSTANCE_IP"); val != "129.159.162.200" {
		t.Errorf("expected 129.159.162.200 preserved, got %q", val)
	}

	// Update existing key
	if err := updateOrAppendDotEnv(envPath, "ORACLE_INSTANCE_IP", "10.0.0.1"); err != nil {
		t.Fatalf("failed to update .env: %v", err)
	}
	if val := readDotEnvKey(envPath, "ORACLE_INSTANCE_IP"); val != "10.0.0.1" {
		t.Errorf("expected updated 10.0.0.1, got %q", val)
	}
	if val := readDotEnvKey(envPath, "FOO"); val != "BAR" {
		t.Errorf("expected BAR preserved, got %q", val)
	}
}
