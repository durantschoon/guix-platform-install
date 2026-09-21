//! Bakes build provenance into the crate: which commit, when it was committed,
//! and whether the tree was clean.
//!
//! The release version is ChronVer by COMMIT date, not build date (decision
//! 2026-09-21): two builds of the same source must report the same version,
//! which is what Guix's reproducibility expects. A build date would make every
//! rebuild a "new version" of identical code.
//!
//! Everything here is best-effort and must never fail the build: a tarball or
//! a Guix sandbox has no `.git`, and then `version.rs` falls back to the
//! crate's own version (kept in step with the date at release time).

use std::path::PathBuf;
use std::process::Command;

/// Runs git inside the workspace root, scoped to that directory with `-- .`.
///
/// The scoping matters: this workspace is sometimes vendored as a
/// subdirectory of another repository, and then "the last commit" must mean
/// the last commit that touched GIPS, not the host repository's HEAD.
fn git(root: &PathBuf, args: &[&str]) -> Option<String> {
    let output = Command::new("git").arg("-C").arg(root).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    Some(text.trim().to_string())
}

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    // bases/gips-config -> workspace root
    let root = manifest_dir.join("..").join("..");

    // Packagers without a git checkout can supply these explicitly.
    println!("cargo:rerun-if-env-changed=GIPS_COMMIT_EPOCH");
    println!("cargo:rerun-if-env-changed=GIPS_COMMIT");
    println!("cargo:rerun-if-changed=build.rs");

    let epoch = std::env::var("GIPS_COMMIT_EPOCH")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| git(&root, &["log", "-1", "--format=%ct", "--", "."]))
        .filter(|value| value.parse::<i64>().is_ok())
        .unwrap_or_default();

    let from_env = std::env::var("GIPS_COMMIT").ok().filter(|value| !value.is_empty());
    let commit = from_env
        .clone()
        .or_else(|| git(&root, &["log", "-1", "--format=%h", "--", "."]))
        .unwrap_or_default();

    // "clean" | "dirty" | "" (unknown). An explicitly supplied commit says
    // nothing about the tree, so it stays unknown rather than claiming clean.
    let tree = if from_env.is_some() || commit.is_empty() {
        ""
    } else {
        match git(&root, &["status", "--porcelain", "--", "."]) {
            Some(changes) if changes.is_empty() => "clean",
            Some(_) => "dirty",
            None => "",
        }
    };

    println!("cargo:rustc-env=GIPS_BUILD_COMMIT_EPOCH={epoch}");
    println!("cargo:rustc-env=GIPS_BUILD_COMMIT={commit}");
    println!("cargo:rustc-env=GIPS_BUILD_TREE={tree}");

    // Rebuild when HEAD or the index moves, so the baked values do not go
    // stale across commits. Absent git, there is nothing to watch.
    if let Some(git_dir) = git(&root, &["rev-parse", "--absolute-git-dir"]) {
        println!("cargo:rerun-if-changed={git_dir}/HEAD");
        println!("cargo:rerun-if-changed={git_dir}/index");
    }
}
