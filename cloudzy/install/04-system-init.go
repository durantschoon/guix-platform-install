package install

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/durantschoon/guix-platform-install/lib"
)

// Step04SystemInit performs the final system initialization
type Step04SystemInit struct{}

func (s *Step04SystemInit) RunWarnings(state *State) error {
	lib.PrintStepHeader(4, "System Initialization (Final Step)")
	fmt.Println()
	fmt.Println("This step will:")
	fmt.Println("  1. Create swap file in /mnt/swapfile (size from SWAP_SIZE env var)")
	fmt.Println("  2. Activate swap for installation process")
	fmt.Println("  3. Optionally run 'guix pull' (if RUN_GUIX_PULL env var is set)")
	fmt.Println("  4. Download customization tools to /mnt/root/guix-customize/")
	fmt.Println("  5. Run 'guix system init /mnt/etc/config.scm /mnt'")
	fmt.Println("  6. Unmount all partitions")
	fmt.Println("  7. Reboot into your new Guix system")
	fmt.Println()
	fmt.Println("Environment variables used by this step:")
	fmt.Printf("  SWAP_SIZE       - %s (default: 4G)\n", lib.GetEnvOrDefault(state.SwapSize, "4G"))
	fmt.Printf("  RUN_GUIX_PULL   - %s (default: not set, skip pull)\n", lib.GetEnvOrDefault(os.Getenv("RUN_GUIX_PULL"), "not set"))
	fmt.Printf("  GUIX_GIT_URL    - %s\n", lib.GetEnv("GUIX_GIT_URL", "https://git.savannah.gnu.org/git/guix.git"))
	fmt.Printf("  GUIX_VERSION    - %s\n", lib.GetEnv("GUIX_VERSION", "v1.4.0"))
	fmt.Println()
	fmt.Println("Estimated time: 5-10 minutes (or 15-30 min if RUN_GUIX_PULL is set)")
	fmt.Println()
	fmt.Println("After reboot, you'll have a minimal bootable Guix system.")
	fmt.Println("Use ~/guix-customize/customize to add SSH, desktop, packages, etc.")
	fmt.Println()

	return nil
}

func (s *Step04SystemInit) RunClean(state *State) error {
    // Enable command logging
    lib.EnableCommandLogging("/tmp/guix-install.log")

    // CRITICAL: Ensure /mnt is mounted before writing anything
    // Check if /mnt is mounted
    if !lib.IsMounted("/mnt") {
        fmt.Println("/mnt is not mounted - attempting to mount GUIX_ROOT...")
        if err := lib.MountByLabel("GUIX_ROOT", "/mnt"); err != nil {
             return fmt.Errorf("failed to mount /mnt (required to avoid filling RAM): %w", err)
        }
        fmt.Println("[OK] Mounted GUIX_ROOT to /mnt")
    }

	// Set up temporary directory on the target partition (has more space than ISO)
	tmpDir := "/mnt/var/tmp"
	if err := os.MkdirAll(tmpDir, 0777); err != nil {
		return err
	}
	os.Setenv("TMPDIR", tmpDir)

	// Also set XDG_CACHE_HOME to avoid filling up ISO's limited space
	cacheDir := "/mnt/var/cache"
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		return err
	}
	os.Setenv("XDG_CACHE_HOME", cacheDir)

	// Clear substitute cache
	exec.Command("rm", "-rf", "/var/guix/substitute-cache/").Run()

	// Create swap file
	if err := lib.CreateSwapFile(state.SwapSize); err != nil {
		return err
	}

	// guix pull is now a post-install step (run after first boot)
	// The ISO version is good enough to install the system
	// To enable during install: set RUN_GUIX_PULL=1 (not recommended, takes 10-30 min)
	runPull := lib.GetEnv("RUN_GUIX_PULL", "")
	if runPull != "" {
		fmt.Println()
		fmt.Println("=== Guix Pull ===")
		fmt.Println("Updating Guix to latest version (takes 10-30 minutes)...")
		fmt.Println()

		// Set up Git environment variables for slow connections
		os.Setenv("GIT_HTTP_MAX_REQUESTS", "2")
		os.Setenv("GIT_HTTP_LOW_SPEED_LIMIT", "1000")
		os.Setenv("GIT_HTTP_LOW_SPEED_TIME", "60")

		// Determine mirror URL
		guixGitURL := lib.GetEnv("GUIX_GIT_URL", "https://git.savannah.gnu.org/git/guix.git")
		guixVersion := lib.GetEnv("GUIX_VERSION", "v1.4.0")

		fmt.Printf("Pulling Guix from configured mirror: %s\n", guixGitURL)
		if err := lib.RunCommand("guix", "pull", "--url="+guixGitURL, "--commit="+guixVersion); err != nil {
			return fmt.Errorf("guix pull failed: %w", err)
		}
	} else {
		fmt.Println()
		fmt.Println("Skipping guix pull - this is now a post-install step")
		fmt.Println("After first boot, run: guix pull && guix package -u")
		fmt.Println()
	}

	// Verify EFI is properly mounted as vfat (only for UEFI boot mode)
	// For BIOS boot, GRUB is installed to disk MBR, not EFI partition
	configPath := "/mnt/etc/config.scm"
	bootMode := lib.DetectBootModeFromConfig(configPath)
	if bootMode == "uefi" {
	if err := lib.VerifyESP(); err != nil {
		return err
		}
	} else {
		fmt.Println("[OK] BIOS boot mode detected - skipping EFI verification (GRUB will be installed to disk MBR)")
		fmt.Println()
	}

	// Start cow-store to redirect store writes to target disk
	if err := lib.StartCowStore(); err != nil {
		return err
	}

	// Write comprehensive recovery script for post-install completion
	// This works for both time-machine and plain guix system init
	recoveryPath := "/root/recovery-complete-install.sh"
	if err := lib.WriteRecoveryScript(recoveryPath, state.GuixPlatform); err == nil {
		fmt.Printf("Recovery script written: %s\n", recoveryPath)
		fmt.Println("If system init succeeds but post-install steps fail, run:")
		fmt.Printf("  %s\n", recoveryPath)
	} else {
		fmt.Printf("Warning: Failed to write recovery script %s: %v\n", recoveryPath, err)
	}

	// Run guix system init with retry logic (free software only, no nonguix)
	if err := lib.RunGuixSystemInitFreeSoftware(state.GuixPlatform); err != nil {
		return err
	}

	// Install verification script (for use after boot and by recovery script)
	if err := lib.InstallVerificationScript(); err != nil {
		fmt.Printf("Warning: Failed to install verification script: %v\n", err)
	}

	// Set user password (CRITICAL - must always run)
	passwordSet := false
	if err := lib.SetUserPassword(state.UserName); err != nil {
		fmt.Printf("\n[WARN] Failed to set user password: %v\n", err)
		fmt.Println("       Will be set by recovery script if needed")
		fmt.Println()
	} else {
		passwordSet = true
	}

	// Download customization tools to user's home directory
	if err := lib.DownloadCustomizationTools(state.GuixPlatform, state.UserName); err != nil {
		fmt.Printf("Warning: Failed to download customization tools: %v\n", err)
		fmt.Println("  You can manually download them after first boot")
	}

    // Write installation receipt and logs
    if err := lib.WriteInstallReceipt(state.GuixPlatform, state.UserName); err != nil {
        fmt.Printf("Warning: Failed to write installation receipt: %v\n", err)
    }

	// FINAL STEP: Run comprehensive verification before reboot
	// This ensures everything is ready and provides clear guidance if not
	if err := lib.RunComprehensiveVerification(recoveryPath); err != nil {
		// Verification failed - don't reboot, provide clear instructions
		fmt.Println()
		fmt.Println("========================================")
		fmt.Println("  INSTALLATION INCOMPLETE")
		fmt.Println("========================================")
		fmt.Println()
		fmt.Println("The final verification found issues that must be fixed before rebooting.")
		fmt.Println()
		if !passwordSet {
			fmt.Println("Additionally, the user password was not set.")
			fmt.Println()
		}
		fmt.Println("To complete the installation, run:")
		fmt.Printf("  %s\n", recoveryPath)
		fmt.Println()
		fmt.Println("The recovery script will fix all issues automatically.")
		fmt.Println()
		return fmt.Errorf("installation incomplete - run recovery script before rebooting")
	}

	// Verification passed - safe to reboot
	fmt.Println()
	fmt.Println("========================================")
	fmt.Println("  INSTALLATION COMPLETE AND VERIFIED")
	fmt.Println("========================================")
	fmt.Println()
	fmt.Println("All steps completed successfully:")
	fmt.Println("  [OK] System initialized")
	if passwordSet {
		fmt.Println("  [OK] User password set")
	}
	fmt.Println("  [OK] Installation verified")
	fmt.Println()
	fmt.Println("Ready to reboot into your new Guix system!")
	fmt.Println()

    // Sync and unmount
	fmt.Println("Syncing filesystems...")
	lib.RunCommand("sync")

	fmt.Println("Unmounting /mnt...")
	lib.RunCommand("umount", "-R", "/mnt")

	fmt.Println()
	fmt.Println("System will reboot now...")
	fmt.Println()

	lib.RunCommand("reboot")

	return nil
}
