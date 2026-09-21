//! What this build is: release version, exact commit, and wire protocols.
//!
//! Three identifiers, because they answer three different questions and no
//! single number can answer all of them:
//!
//! * **release** -- *when*. ChronVer by commit date, `YYYY.MM.DD`.
//! * **commit + tree** -- *exactly which code*. Two builds on one day share a
//!   release; a benchmark result has to name the build that was measured.
//! * **protocols** -- *can two peers talk*. Neither a date nor a SemVer number
//!   tells a node whether another node's messages are readable, so each wire
//!   format carries its own integer, bumped only when compatibility breaks.
//!
//! Cargo only accepts SemVer-shaped versions and SemVer forbids leading
//! zeros, so `Cargo.toml` carries the unpadded form (`2026.9.21`) and this
//! module prints the padded one (`2026.09.21`).

/// Version of the pubsub gossip wire format. The topic names in `gips-http`
/// (`gips.vouch.v1`, `gips.fraud.v1`) embed the same number; a test there
/// keeps the two from drifting.
pub const GOSSIP_PROTOCOL: u32 = 1;

const COMMIT_EPOCH: &str = env!("GIPS_BUILD_COMMIT_EPOCH");
const COMMIT: &str = env!("GIPS_BUILD_COMMIT");
const TREE: &str = env!("GIPS_BUILD_TREE");
const CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Converts days since 1970-01-01 to a proleptic Gregorian (year, month, day).
///
/// Howard Hinnant's `civil_from_days`. Hand-rolled because pulling a date
/// crate into the base of the dependency graph, to format one date at
/// startup, is a poor trade.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_index + 2) / 5 + 1) as u32;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// `YYYY.MM.DD` (UTC) for a Unix timestamp.
pub fn chronver_from_epoch(epoch_seconds: i64) -> String {
    let (year, month, day) = civil_from_days(epoch_seconds.div_euclid(86_400));
    format!("{year:04}.{month:02}.{day:02}")
}

/// Pads a Cargo-shaped `2026.9.21` to `2026.09.21`. Anything that is not three
/// dot-separated numbers is returned unchanged rather than guessed at.
pub fn pad_cargo_version(version: &str) -> String {
    let parts: Vec<&str> = version.split('.').collect();
    match parts.as_slice() {
        [year, month, day]
            if parts.iter().all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit())) =>
        {
            format!("{year:0>4}.{month:0>2}.{day:0>2}")
        }
        _ => version.to_string(),
    }
}

/// The release version: the commit date when the build knew it, otherwise the
/// crate version (a gitless build, e.g. a tarball or the Guix sandbox).
pub fn release() -> String {
    match COMMIT_EPOCH.parse::<i64>() {
        Ok(epoch) => chronver_from_epoch(epoch),
        Err(_) => pad_cargo_version(CRATE_VERSION),
    }
}

/// Short commit hash, or `None` when the build had no git and none was given.
pub fn commit() -> Option<&'static str> {
    if COMMIT.is_empty() { None } else { Some(COMMIT) }
}

/// `Some(true)` dirty, `Some(false)` clean, `None` unknown. Unknown is its own
/// answer: a build that could not look must not report "clean".
pub fn dirty() -> Option<bool> {
    match TREE {
        "dirty" => Some(true),
        "clean" => Some(false),
        _ => None,
    }
}

/// One line for `--version`, e.g.
/// `gipsd 2026.09.21 (abdd395, clean) gossip=v1`.
pub fn long_version(program: &str) -> String {
    let provenance = match (commit(), dirty()) {
        (Some(hash), Some(true)) => format!("{hash}, dirty"),
        (Some(hash), Some(false)) => format!("{hash}, clean"),
        (Some(hash), None) => hash.to_string(),
        (None, _) => "commit unknown".to_string(),
    };
    format!("{program} {} ({provenance}) gossip=v{GOSSIP_PROTOCOL}", release())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chronver_from_epoch_known_dates() {
        assert_eq!(chronver_from_epoch(0), "1970.01.01");
        assert_eq!(chronver_from_epoch(86_399), "1970.01.01");
        assert_eq!(chronver_from_epoch(86_400), "1970.01.02");
        // Leap day, and the day after a leap day.
        assert_eq!(chronver_from_epoch(1_709_164_800), "2024.02.29");
        assert_eq!(chronver_from_epoch(1_709_251_200), "2024.03.01");
        // End of year rollover.
        assert_eq!(chronver_from_epoch(1_767_225_599), "2025.12.31");
        assert_eq!(chronver_from_epoch(1_767_225_600), "2026.01.01");
        assert_eq!(chronver_from_epoch(1_790_035_200), "2026.09.22");
    }

    #[test]
    fn chronver_is_utc_not_local() {
        // 23:59:59 UTC must not roll to the next day whatever TZ the test
        // machine is in; the function takes no timezone input at all.
        assert_eq!(chronver_from_epoch(1_790_035_199), "2026.09.21");
    }

    #[test]
    fn pad_cargo_version_pads_and_leaves_other_shapes_alone() {
        assert_eq!(pad_cargo_version("2026.9.21"), "2026.09.21");
        assert_eq!(pad_cargo_version("2026.10.5"), "2026.10.05");
        assert_eq!(pad_cargo_version("2026.09.21"), "2026.09.21");
        assert_eq!(pad_cargo_version("0.1.0-rc1"), "0.1.0-rc1");
        assert_eq!(pad_cargo_version("1.2"), "1.2");
        assert_eq!(pad_cargo_version(""), "");
    }

    #[test]
    fn release_is_always_a_padded_date() {
        let version = release();
        let parts: Vec<&str> = version.split('.').collect();
        assert_eq!(parts.len(), 3, "{version}");
        assert_eq!((parts[0].len(), parts[1].len(), parts[2].len()), (4, 2, 2), "{version}");
    }

    #[test]
    fn long_version_names_program_release_and_protocol() {
        let line = long_version("gipsd");
        assert!(line.starts_with("gipsd "), "{line}");
        assert!(line.contains(&release()), "{line}");
        assert!(line.ends_with("gossip=v1"), "{line}");
        assert!(!line.contains('\n'));
    }

    #[test]
    fn unknown_tree_is_never_reported_as_clean() {
        if dirty().is_none() {
            assert!(!long_version("x").contains("clean"));
        }
    }
}
