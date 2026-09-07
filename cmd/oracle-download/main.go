package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const (
	defaultImageURL = "https://github.com/durantschoon/guix-platform-install/releases/download/oracle-image-20260811/guix-oracle-generic.qcow2"
	defaultSHA256   = "327ae991eebdd333baf00f315d038113b902564bdea257758aa22baf55106592"
	defaultOutput   = "guix-oracle-generic.qcow2"
)

type progressWriter struct {
	totalBytes      int64
	writtenBytes    int64
	lastReportBytes int64
	lastReportTime  time.Time
	startTime       time.Time
}

func (pw *progressWriter) Write(p []byte) (int, error) {
	n := len(p)
	pw.writtenBytes += int64(n)

	now := time.Now()
	// Report every 500ms or on completion
	if now.Sub(pw.lastReportTime) >= 500*time.Millisecond || (pw.totalBytes > 0 && pw.writtenBytes >= pw.totalBytes) {
		pw.report(now)
	}
	return n, nil
}

func (pw *progressWriter) report(now time.Time) {
	duration := now.Sub(pw.startTime).Seconds()
	var speedMBps float64
	if duration > 0 {
		speedMBps = float64(pw.writtenBytes) / (1024 * 1024) / duration
	}

	writtenMB := float64(pw.writtenBytes) / (1024 * 1024)
	if pw.totalBytes > 0 {
		totalMB := float64(pw.totalBytes) / (1024 * 1024)
		percent := float64(pw.writtenBytes) * 100.0 / float64(pw.totalBytes)
		fmt.Printf("\r[INFO]  Downloading: %.1f / %.1f MB (%.1f%%) - %.2f MB/s", writtenMB, totalMB, percent, speedMBps)
	} else {
		fmt.Printf("\r[INFO]  Downloading: %.1f MB - %.2f MB/s", writtenMB, speedMBps)
	}
	os.Stdout.Sync()
	pw.lastReportTime = now
	pw.lastReportBytes = pw.writtenBytes
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

func main() {
	imageURL := flag.String("url", defaultImageURL, "Download URL for the Guix Oracle image")
	expectedHash := flag.String("sha256", defaultSHA256, "Expected SHA-256 checksum of the image")
	outputPath := flag.String("output", defaultOutput, "Output path for the downloaded image")
	force := flag.Bool("force", false, "Force re-download even if matching file exists")
	verifyOnly := flag.Bool("verify-only", false, "Only verify existing file checksum without downloading")

	flag.Parse()

	absOutput, err := filepath.Abs(*outputPath)
	if err != nil {
		absOutput = *outputPath
	}

	// Verify-only mode
	if *verifyOnly {
		if _, err := os.Stat(absOutput); os.IsNotExist(err) {
			fmt.Printf("[ERROR] File does not exist: %s\n", absOutput)
			os.Exit(1)
		}
		fmt.Printf("[INFO]  Verifying existing file: %s\n", absOutput)
		matches, actual, err := verifyFileSHA256(absOutput, *expectedHash)
		if err != nil {
			fmt.Printf("[ERROR] Failed to calculate checksum: %v\n", err)
			os.Exit(1)
		}
		if matches {
			fmt.Printf("[OK]    SHA-256 matches: %s\n", actual)
			os.Exit(0)
		} else {
			fmt.Printf("[ERROR] SHA-256 mismatch!\n")
			fmt.Printf("        Expected: %s\n", *expectedHash)
			fmt.Printf("        Actual:   %s\n", actual)
			os.Exit(1)
		}
	}

	// Check if already exists and valid
	if !*force {
		if _, err := os.Stat(absOutput); err == nil {
			fmt.Printf("[INFO]  Found existing file at %s. Checking SHA-256...\n", absOutput)
			matches, actual, err := verifyFileSHA256(absOutput, *expectedHash)
			if err == nil && matches {
				fmt.Printf("[OK]    File already exists and SHA-256 matches (%s).\n", actual)
				fmt.Printf("[OK]    Ready to upload to OCI Object Storage.\n")
				os.Exit(0)
			}
			if err == nil && !matches {
				fmt.Printf("[WARN]  Existing file checksum (%s) does not match expected (%s).\n", actual, *expectedHash)
				fmt.Printf("[INFO]  Re-downloading image...\n")
			}
		}
	}

	partPath := absOutput + ".part"
	partFile, err := os.OpenFile(partPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		fmt.Printf("[ERROR] Failed to create temporary file %s: %v\n", partPath, err)
		os.Exit(1)
	}

	fmt.Printf("[INFO]  Source: %s\n", *imageURL)
	fmt.Printf("[INFO]  Target: %s\n", absOutput)

	resp, err := http.Get(*imageURL)
	if err != nil {
		partFile.Close()
		os.Remove(partPath)
		fmt.Printf("[ERROR] HTTP request failed: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		partFile.Close()
		os.Remove(partPath)
		fmt.Printf("[ERROR] HTTP request returned status: %s\n", resp.Status)
		os.Exit(1)
	}

	hasher := sha256.New()
	pw := &progressWriter{
		totalBytes:     resp.ContentLength,
		startTime:      time.Now(),
		lastReportTime: time.Now(),
	}

	// Write simultaneously to part file, hasher, and progress tracker
	multiWriter := io.MultiWriter(partFile, hasher, pw)

	_, copyErr := io.Copy(multiWriter, resp.Body)
	partFile.Close()

	fmt.Println() // newline after progress bar

	if copyErr != nil {
		os.Remove(partPath)
		fmt.Printf("[ERROR] Download interrupted: %v\n", copyErr)
		os.Exit(1)
	}

	actualHash := hex.EncodeToString(hasher.Sum(nil))
	if *expectedHash != "" && actualHash != *expectedHash {
		os.Remove(partPath)
		fmt.Printf("[ERROR] SHA-256 mismatch!\n")
		fmt.Printf("        Expected: %s\n", *expectedHash)
		fmt.Printf("        Actual:   %s\n", actualHash)
		os.Exit(1)
	}

	// Move part file to final output path
	if err := os.Rename(partPath, absOutput); err != nil {
		// Attempt fallback copy if cross-device rename
		fmt.Printf("[ERROR] Failed to rename temporary file to %s: %v\n", absOutput, err)
		os.Exit(1)
	}

	fi, statErr := os.Stat(absOutput)
	var sizeBytes int64
	if statErr == nil {
		sizeBytes = fi.Size()
	}

	fmt.Printf("[OK]    Download complete: %s (%d bytes)\n", absOutput, sizeBytes)
	fmt.Printf("[OK]    SHA-256 verified: %s\n", actualHash)
	fmt.Printf("[OK]    Ready to upload to OCI Object Storage bucket.\n")
}
