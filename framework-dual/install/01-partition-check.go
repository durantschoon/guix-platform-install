package install

import (
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/durantschoon/guix-platform-install/lib"
)

// Step01PartitionCheck performs partition detection and setup
type Step01PartitionCheck struct{}

func (s *Step01PartitionCheck) RunWarnings(state *State) error {
	lib.PrintStepHeader(1, "Partition Check")
	fmt.Println()
	fmt.Println("This step will:")
	fmt.Println("  1. Detect your disk device (or use DEVICE env var if set)")
	fmt.Println("  2. Find your existing EFI partition (sets EFI env var)")
	fmt.Println("  3. Check for existing 'GUIX_ROOT' partition")
	fmt.Println("  4. Format GUIX_ROOT OR create new partition in free space")
	fmt.Println("  5. Detect separate DATA partition if it exists (sets DATA)")
	fmt.Println()
	fmt.Println("Environment variables set by this step:")
	fmt.Println("  DEVICE        - Block device (e.g., /dev/nvme0n1)")
	fmt.Println("  EFI           - EFI System Partition (e.g., /dev/nvme0n1p1)")
	fmt.Println("  ROOT          - Guix root partition (e.g., /dev/nvme0n1p4)")
	fmt.Println("  DATA          - Separate DATA partition if found (optional)")
	fmt.Println()

	// Check if running from Guix live ISO
	if !lib.IsGuixLiveISO() {
		fmt.Println("WARNING: This doesn't appear to be a Guix live ISO environment!")
		fmt.Println("   This script is designed to run from a Guix live ISO.")
		fmt.Println("   If you're not sure you're in the right environment, STOP NOW!")
		fmt.Println()
		fmt.Println("   Press Ctrl+C to abort, or wait 10 seconds to continue...")
		time.Sleep(10 * time.Second)
		fmt.Println()
	}

	// STRATEGY: First look for GUIX_ROOT partition across ALL devices
	// This prevents accidentally using the USB installer device instead of the laptop drive
	fmt.Println()
	fmt.Println("=== Searching for existing GUIX_ROOT partition across all devices ===")
	guixRootPart, guixDevice, err := lib.FindGuixRootPartitionAnyDevice()
	if err != nil {
		fmt.Printf("Error searching for GUIX_ROOT: %v\n", err)
	}

	var device string
	if guixRootPart != "" && guixDevice != "" {
		// Found GUIX_ROOT - use that device
		fmt.Printf("Found GUIX_ROOT partition: %s on device %s\n", guixRootPart, guixDevice)
		device = guixDevice
		state.Device = device
	} else {
		// No GUIX_ROOT found - detect device normally
		fmt.Println("No GUIX_ROOT partition found, detecting device...")
		device, err = lib.DetectDeviceFromState(state.Device, "framework-dual")
		if err != nil {
			return err
		}
		state.Device = device
	}

	// Show current partition layout
	fmt.Println()
	fmt.Println("=== Current Partition Layout ===")
	lib.RunCommand("lsblk", state.Device, "-o", "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL")
	fmt.Println()

	// Find EFI partition
	efiPart, err := lib.FindEFIPartition(state.Device)
	if err != nil {
		return err
	}
	state.EFI = efiPart

	// Check for Pop!_OS
	fmt.Println()
	fmt.Println("=== Checking for Pop!_OS installation ===")
	s.checkPopOS(state)

	// Note: We already found GUIX_ROOT partition above (if it exists)
	fmt.Println()
	fmt.Println("=== Verifying GUIX_ROOT partition on selected device ===")
	if guixRootPart == "" {
		// Double-check on the detected device
		guixRootPart, err = lib.FindGuixRootPartition(state.Device)
	}
	if err != nil {
		return err
	}

	if guixRootPart != "" {
		// Existing GUIX_ROOT partition
		partSize := lib.GetPartitionSizeGiB(guixRootPart)

		fmt.Printf("Found existing partition labeled 'GUIX_ROOT': %s\n", guixRootPart)
		fmt.Printf("Partition size: %.1fGiB\n", partSize)
		fmt.Println()
		fmt.Println("=== Partition Plan ===")
		fmt.Println("This script will:")
		fmt.Printf("  1. Keep existing EFI partition: %s\n", state.EFI)
		fmt.Println("  2. Keep all existing Pop!_OS partitions (untouched)")
		fmt.Printf("  3. Format existing GUIX_ROOT partition: %s (%.1fGiB)\n", guixRootPart, partSize)
		fmt.Println("  4. Install Guix bootloader to EFI (will chain to Pop!_OS)")
	} else {
		// Need to create new partition
		fmt.Println("No partition labeled 'GUIX_ROOT' found.")

		// Show free space
		fmt.Println()
		fmt.Println("=== Available Free Space ===")
		lib.RunCommand("parted", state.Device, "unit", "GiB", "print", "free")
		fmt.Println()

		// Check free space
		freeSpaceGB := lib.GetFreeSpaceGiB(state.Device)
		if freeSpaceGB < 40 {
			fmt.Printf("WARNING: Less than 40GB of free space available (found: %.1fGiB)\n", freeSpaceGB)
			fmt.Println("   Recommended: At least 40-60GB for Guix root partition")
			fmt.Println("   You may need to shrink your Pop!_OS partition first.")
			fmt.Println("   OR: Create a partition labeled 'GUIX_ROOT' using GParted/parted")
			fmt.Println()
			fmt.Println("   Press Ctrl+C to abort, or wait 10 seconds to continue anyway...")
			time.Sleep(10 * time.Second)
			fmt.Println()
		}

		fmt.Println("=== Partition Plan ===")
		fmt.Println("This script will:")
		fmt.Printf("  1. Keep existing EFI partition: %s\n", state.EFI)
		fmt.Println("  2. Keep all existing Pop!_OS partitions (untouched)")
		fmt.Println("  3. Create a new partition for Guix in available free space")
		fmt.Println("  4. Install Guix bootloader to EFI (will chain to Pop!_OS)")
	}

	fmt.Println()
	fmt.Println("IMPORTANT: Make sure you have backed up your data!")
	fmt.Println("   While this script tries to be safe, disk operations are always risky.")
	fmt.Println()

	// Check for home partition
	fmt.Println()
	fmt.Println("=== Checking for separate home partition ===")
	s.findHomePartition(state)

	return nil
}

func (s *Step01PartitionCheck) RunClean(state *State) error {
	// Verify required variables
	if state.Device == "" || state.EFI == "" {
		return fmt.Errorf("required variables not set (DEVICE, EFI)")
	}

	fmt.Println("Looking for existing partition labeled 'GUIX_ROOT'...")
	root, err := lib.FindGuixRootPartition(state.Device)
	if err != nil {
		return err
	}

	if root != "" {
		// Found existing partition
		state.Root = root

		fmt.Printf("Found existing partition labeled 'GUIX_ROOT': %s\n", root)

		// Check if partition is already formatted
		if lib.IsPartitionFormatted(root, "ext4") {
			fmt.Println("Partition is already formatted as ext4")
			fmt.Println("Skipping format step (idempotent - safe for reruns)")
    fmt.Printf("ROOT is %s and EFI is %s\n", state.Root, state.EFI)
    fmt.Println()
    fmt.Println("Verifying partition labels...")
    if state.Device != "" {
        if strings.Contains(state.Device, "nvme") {
            lib.RunCommand("fatlabel", state.Device+"p1")
            // Check if p2 is ext4 before trying e2label (avoid swap partition warnings)
            fmt.Println("Checking partition labels...")
            lib.RunCommand("file", "-s", state.Device+"p2")
            lib.RunCommand("e2label", state.Device+"p2")
        } else {
            lib.RunCommand("fatlabel", state.Device+"1")
            // Check if partition 2 is ext4 before trying e2label (avoid swap partition warnings)
            fmt.Println("Checking partition labels...")
            lib.RunCommand("file", "-s", state.Device+"2")
            lib.RunCommand("e2label", state.Device+"2")
        }
    }
    return nil
		}

		fmt.Println("This partition will be formatted (all data will be lost)")
		fmt.Println()

		if !lib.AskYesNo(fmt.Sprintf("Type 'YES' to format %s: ", root), "YES") {
			return fmt.Errorf("aborted by user")
		}

		fmt.Printf("Formatting %s as ext4 with label GUIX_ROOT...\n", root)
		if err := lib.RunCommand("mkfs.ext4", "-F", "-L", "GUIX_ROOT", root); err != nil {
			return err
		}
	} else {
		// Create new partition
		fmt.Println("No partition labeled 'GUIX_ROOT' found.")
		fmt.Printf("Creating new Guix partition on %s\n", state.Device)
		fmt.Printf("Existing EFI partition: %s (will be reused)\n", state.EFI)

		// Find free space
		freeStartMiB, err := lib.FindFreeSpaceStart(state.Device)
		if err != nil {
			return err
		}

		fmt.Printf("Creating Guix root partition starting at %dMiB\n", freeStartMiB)
		if err := lib.RunCommand("parted", "--script", state.Device,
			"mkpart", "GUIX_ROOT", "ext4", fmt.Sprintf("%dMiB", freeStartMiB), "100%"); err != nil {
			return err
		}

		// Find the partition that was just created
		root, err := lib.GetLastPartition(state.Device)
		if err != nil {
			return err
		}
		state.Root = root

		fmt.Printf("Created Guix root partition: %s\n", root)

		// Format it with label
		fmt.Printf("Formatting %s as ext4 with label GUIX_ROOT...\n", root)
		if err := lib.RunCommand("mkfs.ext4", "-F", "-L", "GUIX_ROOT", root); err != nil {
			return err
		}
	}

	fmt.Printf("ROOT is %s and EFI is %s\n", state.Root, state.EFI)
	return nil
}

// Helper functions



func (s *Step01PartitionCheck) checkPopOS(state *State) {
	cmd := exec.Command("lsblk", "-n", "-o", "NAME,FSTYPE,LABEL", state.Device)
	output, _ := cmd.Output()

	found := false
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, "Pop_OS") || strings.Contains(line, "PopOS") {
			found = true
			fields := strings.Fields(line)
			if len(fields) > 0 {
				fmt.Printf("Found Pop!_OS partition: /dev/%s\n", fields[0])
			}
		}
	}
	if !found {
		fmt.Println("Note: No Pop!_OS partitions detected")
	}
}


// lsblkTreePrefixCutset is the set of characters lsblk uses to draw its device
// tree, plus the trailing space. A child partition arrives from lsblk looking
// like "|-nvme0n1p1" -- drawn with box-drawing characters, not ASCII pipes --
// and that prefix has to come off before the name can become a /dev path.
//
// The characters are written as Go \u escapes rather than as literals so that
// this source file contains no non-ASCII byte. That is deliberate, and it is
// not cosmetic. Two rules collide here:
//
//   - CLAUDE.md forbids Unicode in code that runs on the Guix ISO, because the
//     ISO terminal renders it as garbage. lib/validate-before-deploy.sh
//     enforces this by scanning these files for any byte >= 0x80.
//   - But this Unicode is INPUT, not output. It is never printed. lsblk emits
//     these bytes and we consume them, so they cannot simply be removed --
//     deleting them silently breaks partition-name parsing, and this is the
//     code path that decides which device gets written to.
//
// The \u form satisfies both: the compiled string is byte-identical to the
// literal, while the file itself stays pure ASCII.
//
// If you are debugging partition detection, these are the real characters
// (shown as ASCII approximations so this comment stays ASCII too):
//
//	\u251c  drawn as  |-   BOX DRAWINGS LIGHT VERTICAL AND RIGHT
//	\u2500  drawn as  -    BOX DRAWINGS LIGHT HORIZONTAL
//	\u2514  drawn as  |_   BOX DRAWINGS LIGHT UP AND RIGHT
//	\u2502  drawn as  |    BOX DRAWINGS LIGHT VERTICAL
//
// To see what lsblk is actually emitting on a machine that is misparsing:
//
//	lsblk -n -o NAME,LABEL /dev/nvme0n1 | hexdump -C | head
//
// Do not rewrite this as a literal string: validate-before-deploy.sh will fail
// it. Do not drop the characters: partition parsing will break.
const lsblkTreePrefixCutset = "\u251c\u2500\u2514\u2502 "

func (s *Step01PartitionCheck) findHomePartition(state *State) {
	// Search for partition with filesystem label "DATA"
	cmd := exec.Command("lsblk", "-n", "-o", "NAME,LABEL", state.Device)
	output, _ := cmd.Output()

	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, "DATA") {
			fields := strings.Fields(line)
			if len(fields) >= 2 && fields[1] == "DATA" {
				// Extract full device path from partition name (strip tree characters)
				partName := fields[0]
				partName = strings.TrimLeft(partName, lsblkTreePrefixCutset)
				state.HomePartition = "/dev/" + partName
				homeSize := lib.GetPartitionSizeGiB(state.HomePartition)
				fmt.Printf("Found DATA partition: %s\n", state.HomePartition)
				fmt.Printf("DATA partition size: %.1fGiB\n", homeSize)
				fmt.Println("This partition will be mounted at /home and shared between Pop!_OS and Guix")
				return
			}
		}
	}

	fmt.Println("No separate DATA partition found - home directories will be in root partition")
}

