package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/durantschoon/guix-platform-install/internal/sshwait"
)

const (
	defaultImageURL = "https://github.com/durantschoon/guix-platform-install/releases/download/oracle-image-20260811/guix-oracle-generic.qcow2"
	defaultSHA256   = "327ae991eebdd333baf00f315d038113b902564bdea257758aa22baf55106592"
	defaultOutput   = "guix-oracle-generic.qcow2"
)

var inputScanner *bufio.Scanner

func initScanner() {
	inputScanner = bufio.NewScanner(os.Stdin)
}

func promptLine(prompt string, defaultValue string) string {
	if defaultValue != "" {
		fmt.Printf("%s [%s]: ", prompt, defaultValue)
	} else {
		fmt.Printf("%s: ", prompt)
	}
	os.Stdout.Sync()
	if inputScanner.Scan() {
		text := strings.TrimSpace(inputScanner.Text())
		if text == "" {
			return defaultValue
		}
		return text
	}
	if defaultValue != "" {
		return defaultValue
	}
	fmt.Println("\n[INFO] Exiting.")
	os.Exit(0)
	return ""
}

func promptConfirm(prompt string, defaultYes bool) bool {
	choices := "[y/N]"
	if defaultYes {
		choices = "[Y/n]"
	}
	fmt.Printf("%s %s: ", prompt, choices)
	os.Stdout.Sync()
	if inputScanner.Scan() {
		text := strings.ToLower(strings.TrimSpace(inputScanner.Text()))
		if text == "" {
			return defaultYes
		}
		return text == "y" || text == "yes"
	}
	return defaultYes
}

func pauseForEnter(message string) {
	if message == "" {
		message = "Press [Enter] to continue..."
	}
	fmt.Printf("\n--> %s ", message)
	os.Stdout.Sync()
	if !inputScanner.Scan() {
		return
	}
	fmt.Println()
}

const dedicatedSSHKeyName = "id_ed25519_guix_oracle"

func getDedicatedKeyPaths() (privPath string, pubPath string) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", ""
	}
	priv := filepath.Join(home, ".ssh", dedicatedSSHKeyName)
	pub := priv + ".pub"
	return priv, pub
}

func generateDedicatedKey(privPath, pubPath string) (string, error) {
	sshDir := filepath.Dir(privPath)
	if err := os.MkdirAll(sshDir, 0700); err != nil {
		return "", err
	}

	keygen, err := exec.LookPath("ssh-keygen")
	if err != nil {
		return "", fmt.Errorf("ssh-keygen not found in PATH: %w", err)
	}

	cmd := exec.Command(keygen, "-t", "ed25519", "-f", privPath, "-N", "", "-C", "guix@oracle")
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("ssh-keygen failed: %s (%w)", string(out), err)
	}

	data, err := os.ReadFile(pubPath)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func findExistingSSHKey() (pubPath string, pubContent string) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", ""
	}

	candidates := []string{
		filepath.Join(home, ".ssh", dedicatedSSHKeyName+".pub"),
		filepath.Join(home, ".ssh", "id_ed25519.pub"),
		filepath.Join(home, ".ssh", "id_rsa.pub"),
		filepath.Join(home, ".ssh", "id_ecdsa.pub"),
	}

	for _, cand := range candidates {
		if data, err := os.ReadFile(cand); err == nil {
			content := strings.TrimSpace(string(data))
			if strings.HasPrefix(content, "ssh-") {
				return cand, content
			}
		}
	}
	return "", ""
}

func verifyFileSHA256(path, expectedHash string) (bool, string, error) {
	file, err := os.Open(path)
	if err != nil {
		return false, "", err
	}
	defer file.Close()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return false, "", err
	}
	actualHash := hex.EncodeToString(hasher.Sum(nil))
	return actualHash == expectedHash, actualHash, nil
}

func downloadImage(targetPath string) error {
	partPath := targetPath + ".part"
	partFile, err := os.OpenFile(partPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return fmt.Errorf("cannot create %s: %w", partPath, err)
	}

	fmt.Printf("[INFO]  Downloading %s...\n", defaultImageURL)
	resp, err := http.Get(defaultImageURL)
	if err != nil {
		partFile.Close()
		os.Remove(partPath)
		return fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		partFile.Close()
		os.Remove(partPath)
		return fmt.Errorf("HTTP status %s", resp.Status)
	}

	hasher := sha256.New()
	startTime := time.Now()
	lastReport := time.Now()
	var writtenBytes int64

	writer := io.MultiWriter(partFile, hasher)
	buf := make([]byte, 64*1024)

	for {
		nr, er := resp.Body.Read(buf)
		if nr > 0 {
			nw, ew := writer.Write(buf[0:nr])
			if ew != nil {
				partFile.Close()
				os.Remove(partPath)
				return ew
			}
			writtenBytes += int64(nw)

			now := time.Now()
			if now.Sub(lastReport) >= 500*time.Millisecond {
				duration := now.Sub(startTime).Seconds()
				var speed float64
				if duration > 0 {
					speed = float64(writtenBytes) / (1024 * 1024) / duration
				}
				writtenMB := float64(writtenBytes) / (1024 * 1024)
				totalMB := float64(resp.ContentLength) / (1024 * 1024)
				percent := float64(writtenBytes) * 100.0 / float64(resp.ContentLength)
				fmt.Printf("\r[INFO]  Downloaded: %.1f / %.1f MB (%.1f%%) - %.2f MB/s", writtenMB, totalMB, percent, speed)
				os.Stdout.Sync()
				lastReport = now
			}
		}
		if er != nil {
			if er != io.EOF {
				partFile.Close()
				os.Remove(partPath)
				return er
			}
			break
		}
	}
	partFile.Close()
	fmt.Println()

	actualHash := hex.EncodeToString(hasher.Sum(nil))
	if actualHash != defaultSHA256 {
		os.Remove(partPath)
		return fmt.Errorf("checksum mismatch: expected %s, got %s", defaultSHA256, actualHash)
	}

	if err := os.Rename(partPath, targetPath); err != nil {
		return fmt.Errorf("failed to save image to %s: %w", targetPath, err)
	}
	return nil
}


func main() {
	initScanner()

	fmt.Println()
	fmt.Println("================================================================")
	fmt.Println("       Guix System on Oracle Cloud Infrastructure Wizard        ")
	fmt.Println("================================================================")
	fmt.Println("This wizard walks you through setting up an Always-Free Guix VM.")
	fmt.Println()

	// Step 1: Account
	fmt.Println("--- Step 1: Oracle Cloud Account ---")
	hasAccount := promptConfirm("Do you already have an active Oracle Cloud (OCI) account?", true)
	if !hasAccount {
		fmt.Println("\n[INFO]  Please sign up for an Oracle Cloud Always Free account first:")
		fmt.Println("        https://cloud.oracle.com/free")
		fmt.Println("        (Registration requires credit card identity verification).")
		pauseForEnter("Press [Enter] once your Oracle Cloud account is active...")
	}
	fmt.Println("[OK]    Account ready.")
	fmt.Println()

	// Step 2: SSH Key
	fmt.Println("--- Step 2: SSH Key Setup ---")
	privKeyPath, pubKeyPath := getDedicatedKeyPaths()
	var pubKeyContent string

	if data, err := os.ReadFile(pubKeyPath); err == nil && strings.HasPrefix(strings.TrimSpace(string(data)), "ssh-") {
		pubKeyContent = strings.TrimSpace(string(data))
		fmt.Printf("[OK]    Found existing dedicated Guix Oracle key:\n        %s\n", pubKeyPath)
	} else {
		fmt.Println("[INFO]  To ensure your existing personal keys (e.g. ~/.ssh/id_ed25519) are not overwritten,")
		fmt.Printf("        we use a dedicated key pair: ~/.ssh/%s\n", dedicatedSSHKeyName)
		gen := promptConfirm(fmt.Sprintf("Generate dedicated key pair (~/.ssh/%s)?", dedicatedSSHKeyName), true)
		if gen {
			var err error
			pubKeyContent, err = generateDedicatedKey(privKeyPath, pubKeyPath)
			if err != nil {
				fmt.Printf("[ERROR] Failed to generate dedicated key: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("[OK]    Generated dedicated key pair at:\n        %s\n", pubKeyPath)
		} else {
			existingPub, existingContent := findExistingSSHKey()
			if existingContent != "" {
				useExisting := promptConfirm(fmt.Sprintf("Use existing key (%s)?", existingPub), true)
				if useExisting {
					pubKeyPath = existingPub
					pubKeyContent = existingContent
					privKeyPath = strings.TrimSuffix(existingPub, ".pub")
				}
			}
			if pubKeyContent == "" {
				pubKeyContent = promptLine("Paste your SSH public key string", "")
				if pubKeyContent == "" {
					fmt.Println("[ERROR] An SSH public key is required to access the instance.")
					os.Exit(1)
				}
				privKeyPath = ""
			}
		}
	}

	fmt.Println("\nYour public SSH key is:")
	fmt.Printf("----------------------------------------------------------------\n")
	fmt.Println(pubKeyContent)
	fmt.Printf("----------------------------------------------------------------\n")
	fmt.Println("Keep this key ready; you will paste it when creating the instance.")
	pauseForEnter("Press [Enter] to continue to image preparation...")

	// Step 3: Image Download
	fmt.Println("--- Step 3: Generic Image Download ---")
	targetPath, _ := filepath.Abs(defaultOutput)
	imageReady := false

	if _, err := os.Stat(targetPath); err == nil {
		fmt.Printf("[INFO]  Checking existing %s...\n", targetPath)
		matches, actual, err := verifyFileSHA256(targetPath, defaultSHA256)
		if err == nil && matches {
			fmt.Printf("[OK]    Image is already downloaded and verified (SHA-256 matches).\n")
			imageReady = true
		} else {
			fmt.Printf("[WARN]  Local image checksum mismatch (found %s). Needs re-download.\n", actual)
		}
	}

	if !imageReady {
		downloadNow := promptConfirm("Download published generic image (585 MB) now?", true)
		if !downloadNow {
			fmt.Println("[WARN]  Skipping download. You can download later using 'make download'.")
		} else {
			if err := downloadImage(targetPath); err != nil {
				fmt.Printf("[ERROR] Download failed: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("[OK]    Download complete and SHA-256 verified.")
		}
	}
	pauseForEnter("Press [Enter] to continue to OCI Console deployment...")

	// Step 4: Guided Console Deployment
	fmt.Println("--- Step 4: Deploying on Oracle Cloud (Web Console) ---")
	fmt.Println()
	fmt.Println("[1/4] Upload image to Object Storage:")
	fmt.Println("  1. In browser, log into: https://cloud.oracle.com")
	fmt.Println("  2. Open Navigation Menu (top left) -> Storage -> Buckets.")
	fmt.Println("  3. Click 'Create Bucket' -> name it 'guix-images' -> Create.")
	fmt.Println("  4. Click into 'guix-images', click 'Upload', and choose file:")
	fmt.Printf("     %s\n", targetPath)
	pauseForEnter("Press [Enter] once the upload finishes...")

	fmt.Println("[2/4] Import Custom Image:")
	fmt.Println("  1. Navigation Menu -> Compute -> Custom Images.")
	fmt.Println("  2. Click 'Import Image' and fill in:")
	fmt.Println("     - Name: guix-oracle")
	fmt.Println("     - Source: Object Storage Bucket")
	fmt.Println("     - Bucket: guix-images")
	fmt.Println("     - Object: guix-oracle-generic.qcow2")
	fmt.Println("     - Image Type: QCOW2                         <-- CRITICAL")
	fmt.Println("     - Launch Mode: PARAVIRTUALIZED              <-- CRITICAL")
	fmt.Println("  3. Click 'Import Image'.")
	fmt.Println("     (It takes a few minutes to reach 'Available' state).")
	pauseForEnter("Press [Enter] once the Custom Image reaches 'Available'...")

	fmt.Println("[3/4] Virtual Cloud Network (VCN):")
	fmt.Println("  1. Navigation Menu -> Networking -> Virtual Cloud Networks.")
	fmt.Println("  2. Click 'Start VCN Wizard' -> 'Create VCN with Internet Connectivity'.")
	fmt.Println("  3. Click 'Start VCN Wizard', keep defaults, and click 'Create'.")
	pauseForEnter("Press [Enter] once your VCN is ready...")

	fmt.Println("[4/4] Launch Instance:")
	fmt.Println("  1. Navigation Menu -> Compute -> Instances -> 'Create Instance'.")
	fmt.Println("  2. Configure the following fields:")
	fmt.Println("     - Name: guix-oracle")
	fmt.Println("     - Shape: VM.Standard.E2.1.Micro (Always Free)")
	fmt.Println("     - Image: Click 'Change Image' -> 'Custom Images' -> select 'guix-oracle'")
	fmt.Println("     - Networking: Select the public subnet created above")
	fmt.Println("     - Add SSH keys: Select 'Paste public keys' and paste:")
	fmt.Println()
	fmt.Printf("       %s\n\n", pubKeyContent)
	fmt.Println("  3. Click 'Create'.")
	fmt.Println("  4. Wait ~1 minute until the instance state icon turns green ('RUNNING').")
	fmt.Println()

	// Step 5: IP Resolution & Verification
	var publicIP string
	for {
		publicIP = promptLine("Enter your instance Public IP address", "")
		if publicIP == "" {
			fmt.Println("[WARN] Please enter a valid public IP address.")
			continue
		}
		break
	}

	fmt.Printf("\n[INFO]  Checking instance readiness on %s:22...\n", publicIP)
	cfg := sshwait.WaitConfig{
		User:    "guix",
		Host:    publicIP,
		Port:    "22",
		KeyPath: privKeyPath,
		Timeout: 5 * time.Minute,
	}
	waitErr := sshwait.WaitForSSH(cfg)
	if waitErr != nil {
		if errors.Is(waitErr, sshwait.ErrInterrupted) {
			fmt.Println("\n[INFO]  Readiness check interrupted by user.")
		} else {
			fmt.Println("\n[WARN]  Instance did not complete SSH readiness within 5 minutes.")
			fmt.Println("        Check OCI Console:")
			fmt.Println("          - More actions -> Boot diagnostics -> Capture screenshot")
			fmt.Println("          - More actions -> Create console connection -> Launch Cloud Shell")
		}
	}

	// Step 6: Connect
	connectNow := promptConfirm(fmt.Sprintf("Would you like to SSH into your Guix instance now (guix@%s)?", publicIP), true)
	if connectNow {
		sshPath, err := exec.LookPath("ssh")
		if err != nil {
			fmt.Printf("[ERROR] ssh not found: %v\n", err)
		} else {
			sshArgs := []string{
				"-o", "StrictHostKeyChecking=accept-new",
				"-o", "ConnectTimeout=15",
				"-o", "ServerAliveInterval=30",
				"-o", "ServerAliveCountMax=3",
			}
			if privKeyPath != "" {
				if _, err := os.Stat(privKeyPath); err == nil {
					sshArgs = append(sshArgs, "-i", privKeyPath)
				}
			}
			sshArgs = append(sshArgs, fmt.Sprintf("guix@%s", publicIP))
			cmd := exec.Command(sshPath, sshArgs...)
			cmd.Stdin = os.Stdin
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			_ = cmd.Run()
		}
	}

	fmt.Println()
	fmt.Println("================================================================")
	fmt.Println("                     Next Steps on First Boot                   ")
	fmt.Println("================================================================")
	fmt.Println("Whenever you want to reconnect, run:")
	fmt.Printf("  make ssh IP=%s\n", publicIP)
	if privKeyPath != "" && strings.HasSuffix(privKeyPath, dedicatedSSHKeyName) {
		fmt.Printf("  (dedicated key ~/.ssh/%s is used automatically)\n\n", dedicatedSSHKeyName)
	} else if privKeyPath != "" {
		fmt.Printf("  (or: make ssh IP=%s KEY=%s)\n\n", publicIP, privKeyPath)
	} else {
		fmt.Println()
	}
	fmt.Println("To configure your personal shell, editor, and preferences, run")
	fmt.Println("this one-liner inside your Guix machine:")
	fmt.Println("  wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \\")
	fmt.Println("    | guile --no-auto-compile -s /dev/stdin")
	fmt.Println()
	fmt.Println("[OK] Wizard completed.")
}
