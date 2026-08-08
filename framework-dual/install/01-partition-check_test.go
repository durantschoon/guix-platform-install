package install

import (
	"strings"
	"testing"

	"github.com/durantschoon/guix-platform-install/lib"
)

// TestStep01PartitionCheck_Integration tests the integration of refactored functions
func TestStep01PartitionCheck_Integration(t *testing.T) {
	// Test that the step can be created without panicking
	step := &Step01PartitionCheck{}

	// Verify the step has the expected methods (compile-time check)
	_ = step.RunWarnings
	_ = step.RunClean

	// Test that state can be created
	state := &State{}
	// Verify state is usable by setting and reading a field
	state.Device = "/dev/test"
	if state.Device != "/dev/test" {
		t.Error("State fields should be readable and writable")
	}
}

// TestStateStructure tests that the State struct has the expected fields
func TestStateStructure(t *testing.T) {
	state := &State{
		Device:        "/dev/nvme0n1",
		EFI:           "/dev/nvme0n1p1",
		Root:          "/dev/nvme0n1p2",
		HomePartition: "/dev/nvme0n1p3",
		UserName:      "testuser",
		SwapSize:      "4G",
		GuixPlatform:  "framework-dual",
	}

	// Verify all fields are accessible
	if state.Device != "/dev/nvme0n1" {
		t.Errorf("Expected Device to be /dev/nvme0n1, got %s", state.Device)
	}
	if state.EFI != "/dev/nvme0n1p1" {
		t.Errorf("Expected EFI to be /dev/nvme0n1p1, got %s", state.EFI)
	}
	if state.Root != "/dev/nvme0n1p2" {
		t.Errorf("Expected Root to be /dev/nvme0n1p2, got %s", state.Root)
	}
	if state.HomePartition != "/dev/nvme0n1p3" {
		t.Errorf("Expected HomePartition to be /dev/nvme0n1p3, got %s", state.HomePartition)
	}
	if state.UserName != "testuser" {
		t.Errorf("Expected UserName to be testuser, got %s", state.UserName)
	}
	if state.SwapSize != "4G" {
		t.Errorf("Expected SwapSize to be 4G, got %s", state.SwapSize)
	}
	if state.GuixPlatform != "framework-dual" {
		t.Errorf("Expected GuixPlatform to be framework-dual, got %s", state.GuixPlatform)
	}
}

// TestLibFunctionIntegration tests that the lib functions we use are accessible
func TestLibFunctionIntegration(t *testing.T) {
	// Test that MakePartitionPath is accessible and works
	result := lib.MakePartitionPath("/dev/nvme0n1", "1")
	expected := "/dev/nvme0n1p1"
	if result != expected {
		t.Errorf("lib.MakePartitionPath returned %s, expected %s", result, expected)
	}

	// Test that DetectDeviceFromState is accessible.
	//
	// Whether it FINDS a device depends on the machine running the tests, so
	// only the contract is asserted: the two return values must agree. The
	// previous assertion ("expect an error, we have no real devices") held in
	// an empty container and failed on any machine with /dev/nvme0n1 or
	// /dev/sda -- i.e. on the developer workstation this suite is run from.
	device, err := lib.DetectDeviceFromState("", "framework-dual")
	if err == nil && device == "" {
		t.Error("DetectDeviceFromState returned no device and no error")
	}
	if err != nil && device != "" {
		t.Errorf("DetectDeviceFromState returned both an error (%v) and a device (%s)",
			err, device)
	}

	// Test that IsPartitionFormatted is accessible
	// (We expect false since we don't have real partitions in test environment)
	result_bool := lib.IsPartitionFormatted("/dev/nonexistent", "ext4")
	if result_bool {
		t.Error("Expected IsPartitionFormatted to return false for non-existent partition")
	}
}

// TestRefactoredFunctionCalls tests that our refactored function calls work
func TestRefactoredFunctionCalls(t *testing.T) {
	// These tests verify that the function signatures we use in the refactored code
	// are correct and accessible

	// Test MakePartitionPath signature
	device := "/dev/nvme0n1"
	partNum := "1"
	result := lib.MakePartitionPath(device, partNum)
	if result == "" {
		t.Error("MakePartitionPath should return a non-empty string")
	}

	// Test DetectDeviceFromState signature.
	//
	// The old condition was inverted: `device_result != "" && err == nil` is
	// the SUCCESS case -- a device found and no error -- and it was being
	// reported as a failure. It only ever passed because the surrounding
	// assumption (no devices present) made the branch unreachable.
	device_result, err := lib.DetectDeviceFromState("", "framework-dual")
	if err == nil && device_result == "" {
		t.Error("DetectDeviceFromState returned no device and no error")
	}

	// Test IsPartitionFormatted signature
	formatted := lib.IsPartitionFormatted("/dev/test", "ext4")
	// Should return false for non-existent partition
	if formatted {
		t.Error("Expected IsPartitionFormatted to return false for test partition")
	}
}

// TestStringOperations tests string operations that were fixed in refactoring
func TestStringOperations(t *testing.T) {
	// Test the string trimming operation that was causing linter errors
	testString := "├─nvme0n1p1"
	
	// This is the corrected version without duplicate characters
	trimmed := strings.TrimLeft(testString, "├─└│ ")
	expected := "nvme0n1p1"
	
	if trimmed != expected {
		t.Errorf("String trimming failed: got %s, expected %s", trimmed, expected)
	}
	
	// Test that we don't have duplicate characters in the cutset
	cutset := "├─└│ "
	seen := make(map[rune]bool)
	for _, char := range cutset {
		if seen[char] {
			t.Errorf("Duplicate character found in cutset: %c", char)
		}
		seen[char] = true
	}
}

// TestPartitionPathGeneration tests various partition path generation scenarios
func TestPartitionPathGeneration(t *testing.T) {
	testCases := []struct {
		device   string
		partNum  string
		expected string
	}{
		{"/dev/nvme0n1", "1", "/dev/nvme0n1p1"},
		{"/dev/nvme0n1", "2", "/dev/nvme0n1p2"},
		{"/dev/sda", "1", "/dev/sda1"},
		{"/dev/sda", "3", "/dev/sda3"},
		{"/dev/mmcblk0", "1", "/dev/mmcblk0p1"},
		{"/dev/vda", "1", "/dev/vda1"},
	}

	for _, tc := range testCases {
		t.Run(tc.device+"_"+tc.partNum, func(t *testing.T) {
			result := lib.MakePartitionPath(tc.device, tc.partNum)
			if result != tc.expected {
				t.Errorf("MakePartitionPath(%s, %s) = %s, want %s", 
					tc.device, tc.partNum, result, tc.expected)
			}
		})
	}
}

// TestErrorHandling tests that error handling works correctly
func TestErrorHandling(t *testing.T) {
	// An unrecognised platform is NOT an error: DetectDevice's default branch
	// is a deliberate generic fallback (/dev/nvme0n1, /dev/sda, /dev/vda), so
	// on a machine with any of those it succeeds. Asserting an error here
	// contradicted the implementation and only passed on a device-less host.
	//
	// What is worth testing is that an unknown platform is handled the same
	// way as a known one rather than crashing or returning a half-answer.
	device, err := lib.DetectDeviceFromState("", "nonexistent-platform")
	if err == nil && device == "" {
		t.Error("DetectDeviceFromState returned no device and no error")
	}
	if err != nil && device != "" {
		t.Errorf("DetectDeviceFromState returned both an error (%v) and a device (%s)",
			err, device)
	}

	// A device the user names explicitly must never be silently replaced by an
	// auto-detected one -- that would partition the wrong disk.
	if _, err := lib.DetectDeviceFromState("/dev/nonexistent-device", "framework-dual"); err == nil {
		t.Error("Expected an error for an explicitly named device that does not exist")
	}

	// Test that functions don't panic on empty inputs
	result := lib.MakePartitionPath("", "")
	// MakePartitionPath with empty inputs should return empty string
	if result != "" {
		t.Errorf("MakePartitionPath with empty inputs should return empty string, got %s", result)
	}
}
