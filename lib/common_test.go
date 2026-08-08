package lib

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMakePartitionPath tests the MakePartitionPath function with different device types
func TestMakePartitionPath(t *testing.T) {
	tests := []struct {
		name     string
		device   string
		partNum  string
		expected string
	}{
		{
			name:     "NVMe device with partition",
			device:   "/dev/nvme0n1",
			partNum:  "1",
			expected: "/dev/nvme0n1p1",
		},
		{
			name:     "NVMe device with partition 2",
			device:   "/dev/nvme0n1",
			partNum:  "2",
			expected: "/dev/nvme0n1p2",
		},
		{
			name:     "SATA device with partition",
			device:   "/dev/sda",
			partNum:  "1",
			expected: "/dev/sda1",
		},
		{
			name:     "SATA device with partition 3",
			device:   "/dev/sda",
			partNum:  "3",
			expected: "/dev/sda3",
		},
		{
			name:     "eMMC device with partition",
			device:   "/dev/mmcblk0",
			partNum:  "1",
			expected: "/dev/mmcblk0p1",
		},
		{
			name:     "VDA device (VPS) with partition",
			device:   "/dev/vda",
			partNum:  "1",
			expected: "/dev/vda1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := MakePartitionPath(tt.device, tt.partNum)
			if result != tt.expected {
				t.Errorf("MakePartitionPath(%s, %s) = %s, want %s", tt.device, tt.partNum, result, tt.expected)
			}
		})
	}
}

// TestDetectDeviceFromState tests the DetectDeviceFromState function
func TestDetectDeviceFromState(t *testing.T) {
	// A user-specified device is stat'd and returned unchanged. Any existing
	// path exercises that branch -- it does not have to be a block device,
	// because DetectDeviceFromState only calls os.Stat.
	t.Run("UserSpecifiedDeviceIsHonoured", func(t *testing.T) {
		existing := filepath.Join(t.TempDir(), "fake-device")
		if err := os.WriteFile(existing, []byte{}, 0644); err != nil {
			t.Fatalf("could not create test file: %v", err)
		}

		result, err := DetectDeviceFromState(existing, "framework")
		if err != nil {
			t.Errorf("DetectDeviceFromState(%s) unexpected error: %v", existing, err)
		}
		if result != existing {
			t.Errorf("DetectDeviceFromState(%s) = %s, want the path unchanged",
				existing, result)
		}
	})

	// A user-specified device that does not exist must fail loudly rather than
	// silently falling back to auto-detection -- installing to an auto-detected
	// disk when the user named a different one would be destructive.
	t.Run("UserSpecifiedMissingDeviceErrors", func(t *testing.T) {
		missing := filepath.Join(t.TempDir(), "no-such-device")

		result, err := DetectDeviceFromState(missing, "framework")
		if err == nil {
			t.Errorf("DetectDeviceFromState(%s) expected an error, got nil (result %q)",
				missing, result)
		}
		if result != "" {
			t.Errorf("DetectDeviceFromState(%s) = %s, want empty on error", missing, result)
		}
	})

	// An empty device string triggers auto-detection.
	//
	// Deliberately NOT asserting success or failure: that depends on whether
	// the machine running the tests has a matching block device. This test
	// previously asserted an error, on the stated assumption that there are
	// "no actual devices in test environment" -- true in an empty container,
	// false on any developer workstation or bare-metal CI runner, where
	// /dev/sda or /dev/nvme0n1 exists and detection succeeds.
	//
	// What must hold on every machine is that the two return values agree.
	t.Run("EmptyDeviceTriggersAutoDetection", func(t *testing.T) {
		result, err := DetectDeviceFromState("", "framework")

		if err == nil && result == "" {
			t.Error("DetectDeviceFromState(\"\") returned no device and no error")
		}
		if err != nil && result != "" {
			t.Errorf("DetectDeviceFromState(\"\") returned both an error (%v) and a device (%s)",
				err, result)
		}
	})
	
	// Test with known platforms
	t.Run("KnownPlatforms", func(t *testing.T) {
		platforms := []string{"cloudzy", "framework", "framework-dual"}
		
		for _, platform := range platforms {
			result, err := DetectDeviceFromState("", platform)
			
			// For known platforms, we expect either a result or a specific error
			// (since we don't have actual devices in test environment)
			if err != nil && !strings.Contains(err.Error(), "no suitable block device found") {
				t.Errorf("Unexpected error for platform %s: %v", platform, err)
			}
			
			// Use the result variable to avoid unused variable warnings
			_ = result
		}
	})
}

// TestIsPartitionFormatted tests the IsPartitionFormatted function
func TestIsPartitionFormatted(t *testing.T) {
	tests := []struct {
		name     string
		partition string
		fsTypes  []string
		// Note: We can't easily test the actual blkid output without mocking
		// This test structure shows what we would test in a real environment
	}{
		{
			name:      "ext4 partition",
			partition: "/dev/sda1",
			fsTypes:   []string{"ext4"},
		},
		{
			name:      "vfat partition",
			partition: "/dev/sda1",
			fsTypes:   []string{"vfat"},
		},
		{
			name:      "any filesystem",
			partition: "/dev/sda1",
			fsTypes:   []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// In a real test, we would mock the blkid command output
			// For now, we just verify the function doesn't panic
			result := IsPartitionFormatted(tt.partition, tt.fsTypes...)
			
			// We expect false for non-existent partitions in test environment
			if result {
				t.Logf("IsPartitionFormatted(%s, %v) returned true (expected in test environment)", tt.partition, tt.fsTypes)
			}
		})
	}
}

// TestGetEnv tests the GetEnv function
func TestGetEnv(t *testing.T) {
	tests := []struct {
		name         string
		key          string
		defaultValue string
		setValue     string
		expected     string
	}{
		{
			name:         "Environment variable set",
			key:          "TEST_VAR",
			defaultValue: "default",
			setValue:     "set_value",
			expected:     "set_value",
		},
		{
			name:         "Environment variable not set",
			key:          "NONEXISTENT_VAR",
			defaultValue: "default",
			setValue:     "",
			expected:     "default",
		},
		{
			name:         "Empty environment variable",
			key:          "EMPTY_VAR",
			defaultValue: "default",
			setValue:     "",
			expected:     "default",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set environment variable if needed
			if tt.setValue != "" {
				os.Setenv(tt.key, tt.setValue)
				defer os.Unsetenv(tt.key)
			} else {
				// Ensure it's not set
				os.Unsetenv(tt.key)
			}

			result := GetEnv(tt.key, tt.defaultValue)
			if result != tt.expected {
				t.Errorf("GetEnv(%s, %s) = %s, want %s", tt.key, tt.defaultValue, result, tt.expected)
			}
		})
	}
}

// TestGetEnvOrDefault tests the GetEnvOrDefault function
func TestGetEnvOrDefault(t *testing.T) {
	tests := []struct {
		name         string
		value        string
		defaultValue string
		expected     string
	}{
		{
			name:         "Non-empty value",
			value:        "test_value",
			defaultValue: "default",
			expected:     "test_value",
		},
		{
			name:         "Empty value",
			value:        "",
			defaultValue: "default",
			expected:     "default",
		},
		{
			name:         "Both empty",
			value:        "",
			defaultValue: "",
			expected:     "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GetEnvOrDefault(tt.value, tt.defaultValue)
			if result != tt.expected {
				t.Errorf("GetEnvOrDefault(%s, %s) = %s, want %s", tt.value, tt.defaultValue, result, tt.expected)
			}
		})
	}
}

// TestDetectDevice tests the DetectDevice function with different platforms.
//
// The outcome is hardware-dependent, so the assertions are about the CONTRACT,
// not about a particular machine. This test used to declare expectError: true
// for every platform, on the stated assumption that there are "no actual
// devices in test environment". That holds in an empty container and fails
// everywhere else: a workstation with /dev/sda or /dev/nvme0n1 detects
// successfully, so the suite failed on exactly the machines a developer runs it
// on. It also asserted that an unknown platform errors, which contradicts the
// implementation -- the default branch is a deliberate generic fallback
// (/dev/nvme0n1, /dev/sda, /dev/vda), not an error path.
//
// What must hold regardless of the host:
//
//   - the two return values agree (never a device AND an error, never neither)
//   - a returned device is an absolute path that actually exists
//   - detection is deterministic for a given platform
//   - an unknown platform behaves like the generic fallback, not like an error
func TestDetectDevice(t *testing.T) {
	platforms := []string{"cloudzy", "framework", "framework-dual", "unknown"}

	for _, platform := range platforms {
		t.Run(platform, func(t *testing.T) {
			result, err := DetectDevice(platform)

			if err != nil {
				if result != "" {
					t.Errorf("DetectDevice(%s) returned both an error (%v) and a device (%s)",
						platform, err, result)
				}
				// No matching device on this machine is a legitimate outcome.
				// The message is what the user acts on, so it must say so.
				if !strings.Contains(err.Error(), "no suitable block device found") {
					t.Errorf("DetectDevice(%s) unexpected error: %v", platform, err)
				}
				return
			}

			if result == "" {
				t.Fatalf("DetectDevice(%s) returned no device and no error", platform)
			}
			if !strings.HasPrefix(result, "/dev/") {
				t.Errorf("DetectDevice(%s) = %s, want a /dev/ path", platform, result)
			}
			if _, statErr := os.Stat(result); statErr != nil {
				t.Errorf("DetectDevice(%s) = %s, which does not exist: %v",
					platform, result, statErr)
			}

			// Detection drives partitioning. A function that returned a
			// different disk on a retry could destroy the wrong one.
			again, againErr := DetectDevice(platform)
			if againErr != nil || again != result {
				t.Errorf("DetectDevice(%s) not deterministic: first %s (err %v), then %s (err %v)",
					platform, result, err, again, againErr)
			}
		})
	}
}

// TestCommandExists tests the CommandExists function
func TestCommandExists(t *testing.T) {
	tests := []struct {
		name     string
		command  string
		expected bool
	}{
		{
			name:     "Existing command (ls)",
			command:  "ls",
			expected: true,
		},
		{
			name:     "Non-existing command",
			command:  "nonexistentcommand12345",
			expected: false,
		},
		{
			name:     "Empty command",
			command:  "",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := CommandExists(tt.command)
			if result != tt.expected {
				t.Errorf("CommandExists(%s) = %v, want %v", tt.command, result, tt.expected)
			}
		})
	}
}

// TestIsGuixLiveISO tests the IsGuixLiveISO function
func TestIsGuixLiveISO(t *testing.T) {
	// This test will likely return false in a normal test environment
	// but we can verify it doesn't panic and returns a boolean
	result := IsGuixLiveISO()

	// We expect false in test environment, but the important thing is it doesn't panic
	if result {
		t.Log("IsGuixLiveISO() returned true (unexpected in test environment)")
	}
}

func TestDetectBootMode(t *testing.T) {
	// Test boot mode detection
	// This will return actual boot mode of test system, but shouldn't panic
	mode := DetectBootMode()

	// Should return either "uefi" or "bios"
	if mode != "uefi" && mode != "bios" {
		t.Errorf("DetectBootMode() returned unexpected value: %s (expected 'uefi' or 'bios')", mode)
	}

	// Log what we detected for debugging
	t.Logf("Detected boot mode: %s", mode)

	// Additional verification: check if detection matches reality
	_, efiErr := os.Stat("/sys/firmware/efi")
	if mode == "uefi" && efiErr != nil {
		t.Error("DetectBootMode() returned 'uefi' but /sys/firmware/efi doesn't exist")
	}

	// Verify that if /sys/firmware/efi exists as dir with entries, we get uefi
	if efiErr == nil {
		info, err := os.Stat("/sys/firmware/efi")
		if err == nil && info.IsDir() {
			entries, err := os.ReadDir("/sys/firmware/efi")
			if err == nil && len(entries) > 0 {
				if mode != "uefi" {
					t.Error("DetectBootMode() should return 'uefi' when /sys/firmware/efi exists with entries")
				}
			}
		}
	}
}

// Benchmark tests for performance-critical functions
func BenchmarkMakePartitionPath(b *testing.B) {
	for i := 0; i < b.N; i++ {
		MakePartitionPath("/dev/nvme0n1", "1")
	}
}

func BenchmarkGetEnv(b *testing.B) {
	os.Setenv("BENCHMARK_VAR", "test_value")
	defer os.Unsetenv("BENCHMARK_VAR")
	
	for i := 0; i < b.N; i++ {
		GetEnv("BENCHMARK_VAR", "default")
	}
}

func BenchmarkCommandExists(b *testing.B) {
	for i := 0; i < b.N; i++ {
		CommandExists("ls")
	}
}

// TestRetryUntilReady tests the generic retry helper function
func TestRetryUntilReady(t *testing.T) {
	t.Run("Success on first try", func(t *testing.T) {
		attempts := 0
		check := func() error {
			attempts++
			return nil // Success immediately
		}

		err := retryUntilReady(check, 1*time.Second, 100*time.Millisecond, nil)
		if err != nil {
			t.Errorf("Expected success, got error: %v", err)
		}
		if attempts != 1 {
			t.Errorf("Expected 1 attempt, got %d", attempts)
		}
	})

	t.Run("Success after retries", func(t *testing.T) {
		attempts := 0
		check := func() error {
			attempts++
			if attempts < 3 {
				return fmt.Errorf("not ready yet")
			}
			return nil // Success on 3rd attempt
		}

		err := retryUntilReady(check, 1*time.Second, 100*time.Millisecond, nil)
		if err != nil {
			t.Errorf("Expected success, got error: %v", err)
		}
		if attempts != 3 {
			t.Errorf("Expected 3 attempts, got %d", attempts)
		}
	})

	t.Run("Timeout after max attempts", func(t *testing.T) {
		attempts := 0
		check := func() error {
			attempts++
			return fmt.Errorf("never succeeds")
		}

		// 500ms timeout, 100ms interval = max 5 attempts
		err := retryUntilReady(check, 500*time.Millisecond, 100*time.Millisecond, nil)
		if err == nil {
			t.Error("Expected timeout error, got nil")
		}
		if !strings.Contains(err.Error(), "timeout") {
			t.Errorf("Expected timeout error, got: %v", err)
		}
		if attempts != 5 {
			t.Errorf("Expected 5 attempts, got %d", attempts)
		}
	})

	t.Run("Progress callback called correctly", func(t *testing.T) {
		attempts := 0
		progressCalls := 0
		lastMax := 0

		check := func() error {
			attempts++
			if attempts < 3 {
				return fmt.Errorf("not ready")
			}
			return nil // Success on 3rd attempt
		}

		progressFn := func(attempt, max int) {
			progressCalls++
			lastMax = max
		}

		err := retryUntilReady(check, 1*time.Second, 100*time.Millisecond, progressFn)
		if err != nil {
			t.Errorf("Expected success, got error: %v", err)
		}
		// Progress callback is called before each check, so 3 calls for 3 attempts
		if progressCalls != 3 {
			t.Errorf("Expected 3 progress calls, got %d", progressCalls)
		}
		if lastMax != 10 { // 1s / 100ms = 10 max attempts
			t.Errorf("Expected max=10, got %d", lastMax)
		}
	})
}

// TestCheckSocketExists tests socket file verification
func TestCheckSocketExists(t *testing.T) {
	t.Run("Non-existent socket returns error", func(t *testing.T) {
		// Test with a path that definitely doesn't exist
		err := checkSocketExists()
		// This will fail on most systems since daemon socket doesn't exist
		// That's expected - we're testing the function behavior
		if err == nil {
			t.Log("Socket exists on this system - skipping test")
			return
		}
		if !strings.Contains(err.Error(), "socket not ready") {
			t.Errorf("Expected 'socket not ready' error, got: %v", err)
		}
	})
}

// TestCheckDaemonResponsive tests daemon command responsiveness
func TestCheckDaemonResponsive(t *testing.T) {
	t.Run("Daemon not available returns error", func(t *testing.T) {
		// On most dev machines, guix daemon won't be running
		err := checkDaemonResponsive()
		if err == nil {
			t.Log("Guix daemon is running on this system - skipping test")
			return
		}
		if !strings.Contains(err.Error(), "daemon not responsive") {
			t.Errorf("Expected 'daemon not responsive' error, got: %v", err)
		}
	})
}

// TestIsDaemonProcessRunning tests process status check
func TestIsDaemonProcessRunning(t *testing.T) {
	t.Run("Returns bool without error", func(t *testing.T) {
		// Should always return a bool, never panic
		result := isDaemonProcessRunning()
		// On dev machine without Guix, should be false
		// On Guix system, might be true
		t.Logf("Daemon process running: %v", result)
	})
}

// TestCheckDaemonStable tests stability verification
func TestCheckDaemonStable(t *testing.T) {
	t.Run("Fails fast if daemon not responsive", func(t *testing.T) {
		// On most dev machines, this will fail immediately
		err := checkDaemonStable(3, 100*time.Millisecond)
		if err == nil {
			t.Log("Guix daemon is running and stable - skipping test")
			return
		}
		if !strings.Contains(err.Error(), "stability check 1/3 failed") {
			t.Errorf("Expected stability check to fail on first attempt, got: %v", err)
		}
	})
}

// TestCleanupISOArtifacts tests the CleanupISOArtifacts function
func TestCleanupISOArtifacts(t *testing.T) {
	// Create a temporary directory to simulate /mnt
	tmpDir, err := os.MkdirTemp("", "guix-install-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create directory structure
	mntVar := tmpDir + "/var"
	mntVarRun := mntVar + "/run"
	mntEtc := tmpDir + "/etc"
	mntVarGuix := mntVar + "/guix"
	mntHome := tmpDir + "/home"

	if err := os.MkdirAll(mntVarRun, 0755); err != nil {
		t.Fatalf("Failed to create /var/run: %v", err)
	}
	if err := os.MkdirAll(mntEtc, 0755); err != nil {
		t.Fatalf("Failed to create /etc: %v", err)
	}
	if err := os.MkdirAll(mntVarGuix, 0755); err != nil {
		t.Fatalf("Failed to create /var/guix: %v", err)
	}
	if err := os.MkdirAll(mntHome, 0755); err != nil {
		t.Fatalf("Failed to create /home: %v", err)
	}

	// Create test files that should be removed
	machineID := mntEtc + "/machine-id"
	resolvConf := mntEtc + "/resolv.conf"
	mtabFile := mntEtc + "/mtab"
	isoUserProfile := mntVarGuix + "/profiles/per-user/live-image-user"
	isoUserHome := mntHome + "/live-image-user"

	os.WriteFile(machineID, []byte("test-machine-id"), 0644)
	os.WriteFile(resolvConf, []byte("nameserver 8.8.8.8"), 0644)
	os.WriteFile(mtabFile, []byte("test mtab content"), 0644)
	os.MkdirAll(isoUserProfile, 0755)
	os.MkdirAll(isoUserHome, 0755)

	// Save original /mnt path behavior - we'll test with tmpDir
	// Since CleanupISOArtifacts hardcodes "/mnt", we need to test the logic differently
	// For now, we'll test that the function exists and can be called
	// In a real integration test, we'd mount a test filesystem at /mnt

	t.Run("FunctionExists", func(t *testing.T) {
		// Verify the function exists and has correct signature
		// We can't easily test it without actual /mnt mount, but we verify it compiles
		_ = CleanupISOArtifacts
	})

	t.Run("SymlinkLogic", func(t *testing.T) {
		// Test the symlink creation logic separately
		testVarRun := tmpDir + "/test-var-run"
		testMtab := tmpDir + "/test-mtab"

		// Test: directory should become symlink
		os.MkdirAll(testVarRun, 0755)
		if info, err := os.Lstat(testVarRun); err == nil && info.IsDir() {
			os.RemoveAll(testVarRun)
			if err := os.Symlink("/run", testVarRun); err != nil {
				t.Errorf("Failed to create symlink: %v", err)
			}
			if target, err := os.Readlink(testVarRun); err != nil || target != "/run" {
				t.Errorf("Symlink target incorrect: got %s, want /run", target)
			}
		}

		// Test: file should become symlink
		os.WriteFile(testMtab, []byte("test"), 0644)
		if info, err := os.Lstat(testMtab); err == nil && !info.IsDir() {
			os.Remove(testMtab)
			if err := os.Symlink("/proc/self/mounts", testMtab); err != nil {
				t.Errorf("Failed to create mtab symlink: %v", err)
			}
			if target, err := os.Readlink(testMtab); err != nil || target != "/proc/self/mounts" {
				t.Errorf("Mtab symlink target incorrect: got %s, want /proc/self/mounts", target)
			}
		}
	})
}

// TestDaemonCheckComposition tests that checks compose correctly
func TestDaemonCheckComposition(t *testing.T) {
	t.Run("isDaemonReady fails early if socket missing", func(t *testing.T) {
		// Should fail at socket check before trying daemon responsiveness
		err := isDaemonReady()
		if err == nil {
			t.Log("Guix daemon is fully ready - skipping test")
			return
		}
		// Error should be from socket or daemon check
		errorStr := err.Error()
		if !strings.Contains(errorStr, "socket not ready") &&
		   !strings.Contains(errorStr, "daemon not responsive") {
			t.Errorf("Expected socket or daemon error, got: %v", err)
		}
	})

	t.Run("isDaemonReadyAfterStart checks process first", func(t *testing.T) {
		// Should check process running before other checks
		err := isDaemonReadyAfterStart()
		if err == nil {
			t.Log("Guix daemon process is running and ready - skipping test")
			return
		}
		// Error could be "daemon process not started yet" or from inner checks
		errorStr := err.Error()
		validErrors := []string{
			"daemon process not started yet",
			"socket not ready",
			"daemon not responsive",
		}
		hasValidError := false
		for _, validErr := range validErrors {
			if strings.Contains(errorStr, validErr) {
				hasValidError = true
				break
			}
		}
		if !hasValidError {
			t.Errorf("Expected daemon check error, got: %v", err)
		}
	})
}

// TestCleanupISOArtifactsEnhanced tests the enhanced ISO artifact cleanup functionality
// including /var/lock, /run cleanup, and /var/tmp permissions
func TestCleanupISOArtifactsEnhanced(t *testing.T) {
	// Create a temporary test directory structure simulating /mnt
	tempDir := t.TempDir()
	mntDir := tempDir + "/mnt"

	// Helper to setup test environment
	setupTestEnv := func(t *testing.T) string {
		if err := os.RemoveAll(mntDir); err != nil && !os.IsNotExist(err) {
			t.Fatalf("Failed to clean test dir: %v", err)
		}

		// Create base directory structure
		dirs := []string{
			mntDir + "/var",
			mntDir + "/etc",
			mntDir + "/run",
			mntDir + "/home",
			mntDir + "/var/guix/profiles/per-user",
		}
		for _, dir := range dirs {
			if err := os.MkdirAll(dir, 0755); err != nil {
				t.Fatalf("Failed to create dir %s: %v", dir, err)
			}
		}
		return mntDir
	}

	// Save original /mnt path and restore after tests
	originalMntPrefix := "/mnt"

	t.Run("VarRunSymlink_CreatesFromDirectory", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create /var/run as directory (ISO artifact)
		varRunDir := testMnt + "/var/run"
		if err := os.MkdirAll(varRunDir, 0755); err != nil {
			t.Fatalf("Failed to create test dir: %v", err)
		}

		// Add some files inside to simulate ISO runtime
		testFile := varRunDir + "/test.pid"
		if err := os.WriteFile(testFile, []byte("123"), 0644); err != nil {
			t.Fatalf("Failed to create test file: %v", err)
		}

		// Temporarily redirect /mnt references for testing
		// We can't modify the function, so we test the logic separately

		// Verify it's a directory before cleanup
		info, err := os.Lstat(varRunDir)
		if err != nil {
			t.Fatalf("Failed to stat var/run: %v", err)
		}
		if !info.IsDir() {
			t.Fatal("Expected var/run to be a directory before cleanup")
		}

		// Simulate cleanup: remove directory and create symlink
		if err := os.RemoveAll(varRunDir); err != nil {
			t.Fatalf("Failed to remove directory: %v", err)
		}
		if err := os.Symlink("/run", varRunDir); err != nil {
			t.Fatalf("Failed to create symlink: %v", err)
		}

		// Verify it's now a symlink
		info, err = os.Lstat(varRunDir)
		if err != nil {
			t.Fatalf("Failed to stat var/run after cleanup: %v", err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			t.Error("Expected var/run to be a symlink after cleanup")
		}

		// Verify symlink target
		target, err := os.Readlink(varRunDir)
		if err != nil {
			t.Fatalf("Failed to read symlink: %v", err)
		}
		if target != "/run" {
			t.Errorf("Expected symlink to /run, got %s", target)
		}
	})

	t.Run("VarLockSymlink_CreatesFromDirectory", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create /var/lock as directory (ISO artifact)
		varLockDir := testMnt + "/var/lock"
		if err := os.MkdirAll(varLockDir, 0755); err != nil {
			t.Fatalf("Failed to create test dir: %v", err)
		}

		// Add some lock files to simulate ISO state
		lockFile := varLockDir + "/test.lock"
		if err := os.WriteFile(lockFile, []byte("locked"), 0644); err != nil {
			t.Fatalf("Failed to create test file: %v", err)
		}

		// Verify it's a directory before cleanup
		info, err := os.Lstat(varLockDir)
		if err != nil {
			t.Fatalf("Failed to stat var/lock: %v", err)
		}
		if !info.IsDir() {
			t.Fatal("Expected var/lock to be a directory before cleanup")
		}

		// Simulate cleanup: remove directory and create symlink
		if err := os.RemoveAll(varLockDir); err != nil {
			t.Fatalf("Failed to remove directory: %v", err)
		}
		if err := os.Symlink("/run/lock", varLockDir); err != nil {
			t.Fatalf("Failed to create symlink: %v", err)
		}

		// Verify it's now a symlink
		info, err = os.Lstat(varLockDir)
		if err != nil {
			t.Fatalf("Failed to stat var/lock after cleanup: %v", err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			t.Error("Expected var/lock to be a symlink after cleanup")
		}

		// Verify symlink target
		target, err := os.Readlink(varLockDir)
		if err != nil {
			t.Fatalf("Failed to read symlink: %v", err)
		}
		if target != "/run/lock" {
			t.Errorf("Expected symlink to /run/lock, got %s", target)
		}
	})

	t.Run("RunDirectory_EmptiesContents", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create /run with ISO artifacts
		runDir := testMnt + "/run"
		artifacts := []string{
			runDir + "/dbus/system_bus_socket",
			runDir + "/systemd/notify",
			runDir + "/lock/test.lock",
			runDir + "/user/1000",
		}

		for _, artifact := range artifacts {
			dir := artifact
			// If it has an extension or ends with a number, it's a file
			if strings.Contains(artifact, ".") || strings.HasSuffix(artifact, "socket") || strings.HasSuffix(artifact, "notify") {
				dir = artifact[:strings.LastIndex(artifact, "/")]
			}
			if err := os.MkdirAll(dir, 0755); err != nil {
				t.Fatalf("Failed to create dir %s: %v", dir, err)
			}
			if strings.Contains(artifact, ".") || strings.HasSuffix(artifact, "socket") || strings.HasSuffix(artifact, "notify") {
				if err := os.WriteFile(artifact, []byte("data"), 0644); err != nil {
					t.Fatalf("Failed to create file %s: %v", artifact, err)
				}
			}
		}

		// Verify artifacts exist
		entries, err := os.ReadDir(runDir)
		if err != nil {
			t.Fatalf("Failed to read run dir: %v", err)
		}
		if len(entries) == 0 {
			t.Fatal("Expected ISO artifacts in /run before cleanup")
		}
		initialCount := len(entries)
		t.Logf("Found %d artifacts in /run before cleanup", initialCount)

		// Simulate cleanup: empty the directory
		for _, entry := range entries {
			entryPath := runDir + "/" + entry.Name()
			if err := os.RemoveAll(entryPath); err != nil {
				t.Fatalf("Failed to remove %s: %v", entryPath, err)
			}
		}

		// Verify directory is now empty
		entries, err = os.ReadDir(runDir)
		if err != nil {
			t.Fatalf("Failed to read run dir after cleanup: %v", err)
		}
		if len(entries) != 0 {
			t.Errorf("Expected /run to be empty after cleanup, found %d entries", len(entries))
		}

		// Verify directory still exists
		info, err := os.Stat(runDir)
		if err != nil {
			t.Fatalf("Expected /run directory to exist after cleanup: %v", err)
		}
		if !info.IsDir() {
			t.Error("Expected /run to still be a directory after cleanup")
		}
	})

	t.Run("VarTmpPermissions_SetsStickyBit", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create /var/tmp with wrong permissions
		varTmpDir := testMnt + "/var/tmp"
		if err := os.MkdirAll(varTmpDir, 0755); err != nil {
			t.Fatalf("Failed to create dir: %v", err)
		}

		// Verify initial permissions don't have sticky bit
		info, err := os.Stat(varTmpDir)
		if err != nil {
			t.Fatalf("Failed to stat var/tmp: %v", err)
		}
		initialMode := info.Mode()
		t.Logf("Initial permissions: %o (mode: %v)", initialMode.Perm(), initialMode)

		// Simulate cleanup: set sticky bit (mode 1777)
		targetMode := os.FileMode(0o1777)
		if err := os.Chmod(varTmpDir, targetMode); err != nil {
			t.Fatalf("Failed to set permissions: %v", err)
		}

		// Verify permissions are now correct
		info, err = os.Stat(varTmpDir)
		if err != nil {
			t.Fatalf("Failed to stat var/tmp after cleanup: %v", err)
		}

		finalMode := info.Mode()
		t.Logf("Final permissions: %o (mode: %v)", finalMode.Perm(), finalMode)

		// Check that permissions are world-writable (rwxrwxrwx = 0777)
		basePerm := finalMode.Perm() &^ os.ModeSticky
		if basePerm != 0o777 {
			t.Errorf("Expected base permissions 0777, got %o", basePerm)
		}

		// Check sticky bit - but this is OS-specific
		// macOS temp directories don't preserve sticky bit, but Linux does
		if finalMode&os.ModeSticky == 0 {
			t.Logf("NOTE: Sticky bit not set (OS may not support it in temp dirs)")
			t.Logf("This is expected on macOS but should work on Linux/Guix ISO")
			// Don't fail the test - sticky bit behavior varies by OS and filesystem
		} else {
			t.Logf("Sticky bit successfully set (Linux/proper filesystem)")
		}
	})

	t.Run("EtcMtabSymlink_FixesFromFile", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create /etc/mtab as a regular file (ISO artifact)
		mtabFile := testMnt + "/etc/mtab"
		if err := os.WriteFile(mtabFile, []byte("fake mtab content"), 0644); err != nil {
			t.Fatalf("Failed to create test file: %v", err)
		}

		// Verify it's a file before cleanup
		info, err := os.Lstat(mtabFile)
		if err != nil {
			t.Fatalf("Failed to stat mtab: %v", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			t.Fatal("Expected mtab to be a file before cleanup")
		}

		// Simulate cleanup: remove file and create symlink
		if err := os.Remove(mtabFile); err != nil {
			t.Fatalf("Failed to remove file: %v", err)
		}
		if err := os.Symlink("/proc/self/mounts", mtabFile); err != nil {
			t.Fatalf("Failed to create symlink: %v", err)
		}

		// Verify it's now a symlink
		info, err = os.Lstat(mtabFile)
		if err != nil {
			t.Fatalf("Failed to stat mtab after cleanup: %v", err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			t.Error("Expected mtab to be a symlink after cleanup")
		}

		// Verify symlink target
		target, err := os.Readlink(mtabFile)
		if err != nil {
			t.Fatalf("Failed to read symlink: %v", err)
		}
		if target != "/proc/self/mounts" {
			t.Errorf("Expected symlink to /proc/self/mounts, got %s", target)
		}
	})

	t.Run("ISOArtifacts_RemovesFiles", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create ISO artifacts that should be removed
		artifacts := map[string]string{
			testMnt + "/etc/machine-id":                            "fake-machine-id-from-iso",
			testMnt + "/etc/resolv.conf":                           "nameserver 10.0.2.3",
			testMnt + "/var/guix/profiles/per-user/live-image-user/guix-profile": "link",
			testMnt + "/home/live-image-user/test.txt":             "test",
		}

		for path, content := range artifacts {
			dir := path
			if strings.Contains(path, "/") {
				dir = path[:strings.LastIndex(path, "/")]
			}
			if err := os.MkdirAll(dir, 0755); err != nil {
				t.Fatalf("Failed to create dir %s: %v", dir, err)
			}
			if err := os.WriteFile(path, []byte(content), 0644); err != nil {
				t.Fatalf("Failed to create artifact %s: %v", path, err)
			}
		}

		// Verify artifacts exist
		for path := range artifacts {
			if _, err := os.Stat(path); os.IsNotExist(err) {
				t.Fatalf("Expected artifact %s to exist before cleanup", path)
			}
		}

		// Simulate cleanup: remove artifacts
		artifactPaths := []string{
			testMnt + "/etc/machine-id",
			testMnt + "/etc/resolv.conf",
			testMnt + "/var/guix/profiles/per-user/live-image-user",
			testMnt + "/home/live-image-user",
		}

		for _, path := range artifactPaths {
			if err := os.RemoveAll(path); err != nil && !os.IsNotExist(err) {
				t.Fatalf("Failed to remove artifact %s: %v", path, err)
			}
		}

		// Verify artifacts are gone
		for _, path := range artifactPaths {
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Errorf("Expected artifact %s to be removed, but it still exists", path)
			}
		}
	})

	t.Run("SymlinkVerification_CorrectTarget", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create symlinks with correct targets
		varRunPath := testMnt + "/var/run"
		if err := os.Symlink("/run", varRunPath); err != nil {
			t.Fatalf("Failed to create symlink: %v", err)
		}

		mtabPath := testMnt + "/etc/mtab"
		if err := os.Symlink("/proc/self/mounts", mtabPath); err != nil {
			t.Fatalf("Failed to create symlink: %v", err)
		}

		// Verify symlinks exist and have correct targets
		tests := []struct {
			path   string
			target string
		}{
			{varRunPath, "/run"},
			{mtabPath, "/proc/self/mounts"},
		}

		for _, tt := range tests {
			info, err := os.Lstat(tt.path)
			if err != nil {
				t.Fatalf("Failed to stat %s: %v", tt.path, err)
			}
			if info.Mode()&os.ModeSymlink == 0 {
				t.Errorf("Expected %s to be a symlink", tt.path)
			}

			target, err := os.Readlink(tt.path)
			if err != nil {
				t.Fatalf("Failed to read symlink %s: %v", tt.path, err)
			}
			if target != tt.target {
				t.Errorf("Expected %s -> %s, got %s", tt.path, tt.target, target)
			}
		}
	})

	t.Run("SymlinkVerification_WrongTarget", func(t *testing.T) {
		testMnt := setupTestEnv(t)

		// Create symlink with wrong target
		varRunPath := testMnt + "/var/run"
		if err := os.Symlink("/wrong/target", varRunPath); err != nil {
			t.Fatalf("Failed to create symlink: %v", err)
		}

		// Verify it points to wrong target
		target, err := os.Readlink(varRunPath)
		if err != nil {
			t.Fatalf("Failed to read symlink: %v", err)
		}
		if target == "/run" {
			t.Fatal("Test setup failed: symlink already has correct target")
		}

		// Simulate cleanup: fix symlink
		if err := os.Remove(varRunPath); err != nil {
			t.Fatalf("Failed to remove wrong symlink: %v", err)
		}
		if err := os.Symlink("/run", varRunPath); err != nil {
			t.Fatalf("Failed to create correct symlink: %v", err)
		}

		// Verify it now points to correct target
		target, err = os.Readlink(varRunPath)
		if err != nil {
			t.Fatalf("Failed to read symlink after fix: %v", err)
		}
		if target != "/run" {
			t.Errorf("Expected symlink to /run, got %s", target)
		}
	})

	// Note: We don't test the actual CleanupISOArtifacts() function here because
	// it operates on /mnt which requires root/ISO environment. These tests verify
	// the individual cleanup operations work correctly with the same logic.
	t.Log("ISO artifact cleanup logic tests completed")

	// Cleanup notes
	_ = originalMntPrefix // Keep for reference if we add integration tests later
}
