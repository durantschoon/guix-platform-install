package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseDotEnv(t *testing.T) {
	tempDir := t.TempDir()
	envPath := filepath.Join(tempDir, ".env")

	content := `
# Comment line
ORACLE_INSTANCE_IP=129.153.10.20
export ORACLE_HOST="129.153.10.30"
KEY='~/.ssh/my_key'
EMPTY_VAL=
`
	if err := os.WriteFile(envPath, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write test .env: %v", err)
	}

	result := parseDotEnv(envPath)

	if got := result["ORACLE_INSTANCE_IP"]; got != "129.153.10.20" {
		t.Errorf("expected 129.153.10.20, got %q", got)
	}
	if got := result["ORACLE_HOST"]; got != "129.153.10.30" {
		t.Errorf("expected 129.153.10.30, got %q", got)
	}
	if got := result["KEY"]; got != "~/.ssh/my_key" {
		t.Errorf("expected ~/.ssh/my_key, got %q", got)
	}
	if got := result["EMPTY_VAL"]; got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
}

func TestParseDotEnvNonExistent(t *testing.T) {
	result := parseDotEnv("/non/existent/path/.env")
	if len(result) != 0 {
		t.Errorf("expected empty map for non-existent file, got %v", result)
	}
}
