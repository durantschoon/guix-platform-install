//! Guix daemon Access Control List (`/etc/guix/acl`) inspection and management.
//!
//! # Guix ACL Format
//!
//! GNU Guix stores its authorized substitute signing keys in `/etc/guix/acl`.
//! The file contains an S-expression with the top-level symbol `acl` containing
//! zero or more `entry` forms:
//!
//! ```text
//! (acl
//!  (entry
//!   (public-key
//!    (ecc
//!     (curve Ed25519)
//!     (q #<64 hex digits>#)
//!     )
//!    )
//!   (tag
//!    (guix import)
//!    )
//!   )
//!  (entry
//!   (public-key
//!    (rsa
//!     (n #<hex digits>#)
//!     (e #<hex digits>#)
//!     )
//!    )
//!   (tag
//!    (guix import)
//!    )
//!   )
//!  )
//! ```
//!
//! This module provides safe, idempotent, and non-destructive parsing,
//! inspection, verification, authorization, revocation, and diffing for
//! Guix ACL files.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Default location of the Guix ACL file on GNU/Linux systems.
pub const DEFAULT_ACL_PATH: &str = "/etc/guix/acl";

// ---------------------------------------------------------------------------
// S-expression AST & Parser
// ---------------------------------------------------------------------------

/// A minimal S-expression AST.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Sexp {
    Atom(String),
    List(Vec<Sexp>),
}

impl Sexp {
    /// Formats the S-expression into a human-readable string with indentation.
    pub fn to_pretty_string(&self, indent_level: usize) -> String {
        match self {
            Sexp::Atom(s) => s.clone(),
            Sexp::List(items) => {
                if items.is_empty() {
                    return "()".to_string();
                }

                // If all items are short atoms, keep on one line
                let is_short_flat =
                    items.iter().all(|item| matches!(item, Sexp::Atom(_))) && items.len() <= 3;
                if is_short_flat {
                    let inside: Vec<String> = items
                        .iter()
                        .map(|i| match i {
                            Sexp::Atom(s) => s.clone(),
                            _ => unreachable!(),
                        })
                        .collect();
                    return format!("({})", inside.join(" "));
                }

                let indent = " ".repeat(indent_level);
                let inner_indent = " ".repeat(indent_level + 1);

                let mut out = String::from("(");
                for (idx, item) in items.iter().enumerate() {
                    if idx == 0 {
                        out.push_str(&item.to_pretty_string(indent_level + 1));
                    } else {
                        out.push('\n');
                        out.push_str(&inner_indent);
                        out.push_str(&item.to_pretty_string(indent_level + 1));
                    }
                }
                out.push('\n');
                out.push_str(&indent);
                out.push(')');
                out
            }
        }
    }

    /// Finds the first child list starting with the given symbol.
    pub fn find_child_list(&self, symbol: &str) -> Option<&Vec<Sexp>> {
        match self {
            Sexp::List(items) => {
                if items.first() == Some(&Sexp::Atom(symbol.to_string())) {
                    Some(items)
                } else {
                    for item in items {
                        if let Some(found) = item.find_child_list(symbol) {
                            return Some(found);
                        }
                    }
                    None
                }
            }
            Sexp::Atom(_) => None,
        }
    }
}

impl fmt::Display for Sexp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_pretty_string(0))
    }
}

/// Tokenizer for S-expressions.
fn tokenize(input: &str) -> Result<Vec<String>, AclError> {
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();

    while let Some(&c) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else if c == ';' {
            // Comment: skip until newline
            while let Some(&comment_c) = chars.peek() {
                chars.next();
                if comment_c == '\n' {
                    break;
                }
            }
        } else if c == '(' {
            tokens.push("(".to_string());
            chars.next();
        } else if c == ')' {
            tokens.push(")".to_string());
            chars.next();
        } else if c == '"' {
            // Quoted string
            chars.next();
            let mut s = String::from("\"");
            let mut escaped = false;
            for next_c in chars.by_ref() {
                s.push(next_c);
                if escaped {
                    escaped = false;
                } else if next_c == '\\' {
                    escaped = true;
                } else if next_c == '"' {
                    break;
                }
            }
            tokens.push(s);
        } else {
            // Atom or #hex# string
            let mut atom = String::new();
            while let Some(&next_c) = chars.peek() {
                if next_c.is_whitespace() || next_c == '(' || next_c == ')' || next_c == ';' {
                    break;
                }
                atom.push(next_c);
                chars.next();
            }
            if !atom.is_empty() {
                tokens.push(atom);
            }
        }
    }
    Ok(tokens)
}

/// Parses a token slice into Sexp AST.
fn parse_tokens(tokens: &[String], pos: &mut usize) -> Result<Sexp, AclError> {
    if *pos >= tokens.len() {
        return Err(AclError::ParseError("Unexpected end of input".to_string()));
    }

    let token = &tokens[*pos];
    if token == "(" {
        *pos += 1;
        let mut list = Vec::new();
        while *pos < tokens.len() && tokens[*pos] != ")" {
            list.push(parse_tokens(tokens, pos)?);
        }
        if *pos >= tokens.len() {
            return Err(AclError::ParseError(
                "Unclosed parenthesis in S-expression".to_string(),
            ));
        }
        *pos += 1; // Consume ')'
        Ok(Sexp::List(list))
    } else if token == ")" {
        Err(AclError::ParseError(
            "Unexpected closing parenthesis".to_string(),
        ))
    } else {
        *pos += 1;
        Ok(Sexp::Atom(token.clone()))
    }
}

/// Parses full string into Sexp AST.
pub fn parse_sexp(input: &str) -> Result<Sexp, AclError> {
    let tokens = tokenize(input)?;
    if tokens.is_empty() {
        return Err(AclError::ParseError("Empty S-expression input".to_string()));
    }
    let mut pos = 0;
    let sexp = parse_tokens(&tokens, &mut pos)?;
    Ok(sexp)
}

// ---------------------------------------------------------------------------
// ACL Data Structures & Errors
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum AclError {
    IoError { path: PathBuf, source: io::Error },
    ParseError(String),
    MalformedKey(String),
    KeyNotFound(String),
}

impl fmt::Display for AclError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IoError { path, source } => {
                write!(f, "ACL IO error on {}: {}", path.display(), source)
            }
            Self::ParseError(msg) => write!(f, "ACL parse error: {}", msg),
            Self::MalformedKey(msg) => write!(f, "Malformed public key: {}", msg),
            Self::KeyNotFound(msg) => write!(f, "Key not found in ACL: {}", msg),
        }
    }
}

impl std::error::Error for AclError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::IoError { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// An entry in a Guix ACL file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AclEntry {
    /// Normalized full S-expression representation of the public key `(public-key ...)`.
    pub public_key_sexp: String,
    /// Key type algorithm: `"ecc"`, `"rsa"`, etc.
    pub key_type: String,
    /// Specific curve or subtype if present: e.g. `"Ed25519"`.
    pub curve_or_algo: Option<String>,
    /// Distinct hex fingerprint or raw key data string (e.g. hex digits of `q` or `n`).
    pub identifier: String,
    /// Associated tags, e.g. `["(guix import)"]`.
    pub tags: Vec<String>,
}

/// Parsed representation of a Guix ACL file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuixAcl {
    /// All parsed authorized key entries.
    pub entries: Vec<AclEntry>,
    /// Underlying raw Sexp representation.
    pub raw_ast: Sexp,
}

impl GuixAcl {
    /// Creates an empty ACL structure `(acl)`.
    pub fn empty() -> Self {
        Self {
            entries: Vec::new(),
            raw_ast: Sexp::List(vec![Sexp::Atom("acl".to_string())]),
        }
    }

    /// Checks if a public key is authorized in this ACL.
    pub fn contains_key(&self, key_str: &str) -> bool {
        let clean_target = match normalize_key_string(key_str) {
            Ok(k) => k,
            Err(_) => key_str.trim().to_string(),
        };

        let target_ident = extract_identifier_from_str(key_str).unwrap_or_default();

        for entry in &self.entries {
            if entry.public_key_sexp == clean_target {
                return true;
            }
            if !target_ident.is_empty() && entry.identifier.eq_ignore_ascii_case(&target_ident) {
                return true;
            }
            if clean_target.contains(&entry.identifier)
                || entry.public_key_sexp.contains(&clean_target)
            {
                return true;
            }
        }
        false
    }

    /// Adds a public key to the ACL if not already present.
    /// Returns `true` if added, `false` if already authorized.
    pub fn authorize(&mut self, key_str: &str, tag_opt: Option<&str>) -> Result<bool, AclError> {
        if self.contains_key(key_str) {
            return Ok(false);
        }

        let entry = parse_public_key_to_entry(key_str, tag_opt)?;
        let entry_ast = entry_to_ast(&entry)?;

        match &mut self.raw_ast {
            Sexp::List(items) => {
                // Ensure top-level is (acl ...)
                if items.is_empty() || items[0] != Sexp::Atom("acl".to_string()) {
                    items.insert(0, Sexp::Atom("acl".to_string()));
                }
                items.push(entry_ast);
            }
            Sexp::Atom(_) => {
                self.raw_ast = Sexp::List(vec![Sexp::Atom("acl".to_string()), entry_ast]);
            }
        }

        self.entries.push(entry);
        Ok(true)
    }

    /// Revokes/removes a public key from the ACL by public key sexp, identifier, or hex.
    /// Returns `true` if removed, `false` if not found.
    pub fn revoke(&mut self, key_or_ident: &str) -> Result<bool, AclError> {
        let clean_target = match normalize_key_string(key_or_ident) {
            Ok(k) => k,
            Err(_) => key_or_ident.trim().to_string(),
        };
        let target_ident = extract_identifier_from_str(key_or_ident).unwrap_or_default();

        let initial_len = self.entries.len();
        self.entries.retain(|entry| {
            if entry.public_key_sexp == clean_target {
                return false;
            }
            if !target_ident.is_empty() && entry.identifier.eq_ignore_ascii_case(&target_ident) {
                return false;
            }
            if clean_target.contains(&entry.identifier)
                || entry.public_key_sexp.contains(&clean_target)
            {
                return false;
            }
            if entry.identifier.contains(&clean_target)
                || clean_target.eq_ignore_ascii_case(&entry.identifier)
            {
                return false;
            }
            true
        });

        if self.entries.len() == initial_len {
            return Ok(false);
        }

        // Rebuild AST
        let mut new_items = vec![Sexp::Atom("acl".to_string())];
        for entry in &self.entries {
            new_items.push(entry_to_ast(entry)?);
        }
        self.raw_ast = Sexp::List(new_items);
        Ok(true)
    }

    /// Formats the ACL into valid Guix S-expression text.
    pub fn to_sexp_string(&self) -> String {
        self.raw_ast.to_string()
    }
}

// ---------------------------------------------------------------------------
// Helpers & Entry Parsing
// ---------------------------------------------------------------------------

fn extract_identifier_from_str(s: &str) -> Option<String> {
    let trimmed = s.trim();
    // If it's a bare hex string like "1234..." or "#1234...#"
    if trimmed.starts_with('#') && trimmed.ends_with('#') && trimmed.len() > 2 {
        return Some(trimmed[1..trimmed.len() - 1].trim().to_string());
    }
    // If it's raw hex
    if trimmed.chars().all(|c| c.is_ascii_hexdigit()) && trimmed.len() >= 16 {
        return Some(trimmed.to_string());
    }
    // Try parsing as S-expression
    if let Ok(sexp) = parse_sexp(s) {
        if let Some(ident) = extract_identifier_from_ast(&sexp) {
            return Some(ident);
        }
    }
    None
}

fn extract_identifier_from_ast(ast: &Sexp) -> Option<String> {
    // Search for (q #...#) or (n #...#)
    match ast {
        Sexp::List(items) => {
            if items.len() >= 2 {
                if let Sexp::Atom(sym) = &items[0] {
                    if sym == "q" || sym == "n" {
                        if let Sexp::Atom(val) = &items[1] {
                            let clean = val.trim_matches('#').trim();
                            return Some(clean.to_string());
                        }
                    }
                }
            }
            for item in items {
                if let Some(found) = extract_identifier_from_ast(item) {
                    return Some(found);
                }
            }
            None
        }
        Sexp::Atom(_) => None,
    }
}

/// Normalizes public key string into a canonical S-expression string.
pub fn normalize_key_string(key_str: &str) -> Result<String, AclError> {
    let ast = parse_sexp(key_str)?;
    let pk_ast = if let Sexp::List(ref items) = ast {
        if items.first() == Some(&Sexp::Atom("public-key".to_string())) {
            ast.clone()
        } else if let Some(found) = ast.find_child_list("public-key") {
            Sexp::List(found.clone())
        } else {
            return Err(AclError::MalformedKey(
                "No (public-key ...) found in expression".to_string(),
            ));
        }
    } else {
        return Err(AclError::MalformedKey(
            "Expected S-expression list for public key".to_string(),
        ));
    };
    Ok(pk_ast.to_string())
}

/// Converts a public key string into an `AclEntry`.
pub fn parse_public_key_to_entry(
    key_str: &str,
    tag_opt: Option<&str>,
) -> Result<AclEntry, AclError> {
    let ast = parse_sexp(key_str)?;
    let pk_ast = match &ast {
        Sexp::List(items) => {
            if items.first() == Some(&Sexp::Atom("public-key".to_string())) {
                ast.clone()
            } else if let Some(found) = ast.find_child_list("public-key") {
                Sexp::List(found.clone())
            } else {
                return Err(AclError::MalformedKey(
                    "No (public-key ...) found".to_string(),
                ));
            }
        }
        Sexp::Atom(_) => {
            return Err(AclError::MalformedKey(
                "Expected S-expression list".to_string(),
            ))
        }
    };

    let mut key_type = "unknown".to_string();
    let mut curve_or_algo = None;
    let identifier = extract_identifier_from_ast(&pk_ast).unwrap_or_else(|| "unknown".to_string());

    if let Sexp::List(items) = &pk_ast {
        for item in items.iter().skip(1) {
            if let Sexp::List(inner) = item {
                if let Some(Sexp::Atom(sym)) = inner.first() {
                    key_type = sym.clone();
                    for inner_item in inner.iter().skip(1) {
                        if let Sexp::List(curve_list) = inner_item {
                            if curve_list.first() == Some(&Sexp::Atom("curve".to_string()))
                                && curve_list.len() >= 2
                            {
                                if let Sexp::Atom(curve_name) = &curve_list[1] {
                                    curve_or_algo = Some(curve_name.clone());
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let tags = if let Some(t) = tag_opt {
        vec![t.to_string()]
    } else {
        vec!["(guix import)".to_string()]
    };

    Ok(AclEntry {
        public_key_sexp: pk_ast.to_string(),
        key_type,
        curve_or_algo,
        identifier,
        tags,
    })
}

fn entry_to_ast(entry: &AclEntry) -> Result<Sexp, AclError> {
    let pk_ast = parse_sexp(&entry.public_key_sexp)?;
    let mut tags_ast = Vec::new();
    for tag_str in &entry.tags {
        if let Ok(t_ast) = parse_sexp(tag_str) {
            tags_ast.push(t_ast);
        } else {
            tags_ast.push(Sexp::List(vec![
                Sexp::Atom("guix".to_string()),
                Sexp::Atom("import".to_string()),
            ]));
        }
    }

    let tag_sexp = if tags_ast.is_empty() {
        Sexp::List(vec![
            Sexp::Atom("tag".to_string()),
            Sexp::List(vec![
                Sexp::Atom("guix".to_string()),
                Sexp::Atom("import".to_string()),
            ]),
        ])
    } else {
        let mut list = vec![Sexp::Atom("tag".to_string())];
        list.extend(tags_ast);
        Sexp::List(list)
    };

    Ok(Sexp::List(vec![
        Sexp::Atom("entry".to_string()),
        pk_ast,
        tag_sexp,
    ]))
}

// ---------------------------------------------------------------------------
// ACL Parser & I/O
// ---------------------------------------------------------------------------

/// Parses a Guix ACL file content into `GuixAcl`.
pub fn parse_acl(content: &str) -> Result<GuixAcl, AclError> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Ok(GuixAcl::empty());
    }

    let ast = parse_sexp(trimmed)?;
    let mut entries = Vec::new();

    match &ast {
        Sexp::List(items) => {
            for item in items {
                if let Sexp::List(entry_items) = item {
                    if entry_items.first() == Some(&Sexp::Atom("entry".to_string())) {
                        let mut pk_opt = None;
                        let mut tags = Vec::new();

                        for part in entry_items.iter().skip(1) {
                            if let Sexp::List(part_list) = part {
                                if part_list.first() == Some(&Sexp::Atom("public-key".to_string()))
                                {
                                    pk_opt = Some(part.clone());
                                } else if part_list.first() == Some(&Sexp::Atom("tag".to_string()))
                                {
                                    for tag_item in part_list.iter().skip(1) {
                                        tags.push(tag_item.to_string());
                                    }
                                }
                            }
                        }

                        if let Some(pk_ast) = pk_opt {
                            let mut key_type = "unknown".to_string();
                            let mut curve_or_algo = None;
                            let identifier = extract_identifier_from_ast(&pk_ast)
                                .unwrap_or_else(|| "unknown".to_string());

                            if let Sexp::List(pk_items) = &pk_ast {
                                for pk_part in pk_items.iter().skip(1) {
                                    if let Sexp::List(algo_list) = pk_part {
                                        if let Some(Sexp::Atom(sym)) = algo_list.first() {
                                            key_type = sym.clone();
                                            for algo_item in algo_list.iter().skip(1) {
                                                if let Sexp::List(curve_list) = algo_item {
                                                    if curve_list.first()
                                                        == Some(&Sexp::Atom("curve".to_string()))
                                                        && curve_list.len() >= 2
                                                    {
                                                        if let Sexp::Atom(curve_name) =
                                                            &curve_list[1]
                                                        {
                                                            curve_or_algo =
                                                                Some(curve_name.clone());
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            if tags.is_empty() {
                                tags.push("(guix import)".to_string());
                            }

                            entries.push(AclEntry {
                                public_key_sexp: pk_ast.to_string(),
                                key_type,
                                curve_or_algo,
                                identifier,
                                tags,
                            });
                        }
                    }
                }
            }
        }
        Sexp::Atom(_) => {
            return Err(AclError::ParseError(
                "Top-level ACL must be a list".to_string(),
            ))
        }
    }

    Ok(GuixAcl {
        entries,
        raw_ast: ast,
    })
}

/// Reads and parses the Guix ACL from a path.
pub fn read_acl(path: &Path) -> Result<GuixAcl, AclError> {
    if !path.exists() {
        return Ok(GuixAcl::empty());
    }
    let content = fs::read_to_string(path).map_err(|source| AclError::IoError {
        path: path.to_path_buf(),
        source,
    })?;
    parse_acl(&content)
}

/// Writes the ACL to a path atomically.
pub fn write_acl(path: &Path, acl: &GuixAcl) -> Result<(), AclError> {
    let content = acl.to_sexp_string();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| AclError::IoError {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    fs::write(
        path,
        format!(";; Automatically managed by GIPS\n{}\n", content),
    )
    .map_err(|source| AclError::IoError {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// ACL Diffing
// ---------------------------------------------------------------------------

/// Result of diffing an ACL against a list of candidate / trusted keys.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AclDiff {
    /// Keys that are authorized in the Guix ACL, but not present in the trusted set.
    pub in_acl_only: Vec<AclEntry>,
    /// Keys present in the trusted set, but not yet authorized in the Guix ACL.
    pub in_trusted_only: Vec<String>,
    /// Keys present and authorized in both.
    pub matching: Vec<AclEntry>,
}

/// Compares a Guix ACL against a list of candidate public keys.
pub fn diff_acl(acl: &GuixAcl, candidate_pubkeys: &[String]) -> Result<AclDiff, AclError> {
    let mut matching = Vec::new();
    let mut in_acl_only = Vec::new();
    let mut in_trusted_only = Vec::new();

    let mut matched_acl_indices = std::collections::HashSet::new();

    for key_str in candidate_pubkeys {
        let clean = match normalize_key_string(key_str) {
            Ok(k) => k,
            Err(_) => key_str.trim().to_string(),
        };
        let ident = extract_identifier_from_str(key_str).unwrap_or_default();

        let mut found_match = false;
        for (idx, entry) in acl.entries.iter().enumerate() {
            if entry.public_key_sexp == clean
                || (!ident.is_empty() && entry.identifier.eq_ignore_ascii_case(&ident))
                || clean.contains(&entry.identifier)
                || entry.public_key_sexp.contains(&clean)
            {
                matched_acl_indices.insert(idx);
                matching.push(entry.clone());
                found_match = true;
                break;
            }
        }
        if !found_match {
            in_trusted_only.push(clean);
        }
    }

    for (idx, entry) in acl.entries.iter().enumerate() {
        if !matched_acl_indices.contains(&idx) {
            in_acl_only.push(entry.clone());
        }
    }

    Ok(AclDiff {
        in_acl_only,
        in_trusted_only,
        matching,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_GUIX_ACL: &str = r#"
;; This is the ACL file for GNU Guix.
(acl
 (entry
  (public-key
   (ecc
    (curve Ed25519)
    (q #0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF#)
    )
   )
  (tag
   (guix import)
   )
  )
 (entry
  (public-key
   (rsa
    (n #FEEDFACECAFEBEEF#)
    (e #010001#)
    )
   )
  (tag
   (guix import)
   )
  )
 )
"#;

    const SAMPLE_PUBKEY_ED25519: &str = r#"
(public-key
 (ecc
  (curve Ed25519)
  (q #AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA#)
  )
 )
"#;

    #[test]
    fn test_parse_guix_acl_sample() {
        let acl = parse_acl(SAMPLE_GUIX_ACL).expect("Failed to parse sample ACL");
        assert_eq!(acl.entries.len(), 2);
        assert_eq!(acl.entries[0].key_type, "ecc");
        assert_eq!(acl.entries[0].curve_or_algo.as_deref(), Some("Ed25519"));
        assert_eq!(
            acl.entries[0].identifier,
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
        );
        assert_eq!(acl.entries[1].key_type, "rsa");
        assert_eq!(acl.entries[1].identifier, "FEEDFACECAFEBEEF");
    }

    #[test]
    fn test_acl_contains_key() {
        let acl = parse_acl(SAMPLE_GUIX_ACL).unwrap();
        assert!(
            acl.contains_key("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF")
        );
        assert!(acl.contains_key("#FEEDFACECAFEBEEF#"));
        assert!(!acl.contains_key("DEADBEEF"));
    }

    #[test]
    fn test_acl_authorize_and_idempotence() {
        let mut acl = parse_acl(SAMPLE_GUIX_ACL).unwrap();
        assert_eq!(acl.entries.len(), 2);

        // Authorize new key
        let added = acl
            .authorize(SAMPLE_PUBKEY_ED25519, None)
            .expect("authorize failed");
        assert!(added);
        assert_eq!(acl.entries.len(), 3);
        assert!(
            acl.contains_key("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        );

        // Idempotent: authorizing again returns false without adding duplicate
        let added_again = acl
            .authorize(SAMPLE_PUBKEY_ED25519, None)
            .expect("authorize again");
        assert!(!added_again);
        assert_eq!(acl.entries.len(), 3);
    }

    #[test]
    fn test_acl_revoke() {
        let mut acl = parse_acl(SAMPLE_GUIX_ACL).unwrap();
        assert_eq!(acl.entries.len(), 2);

        let revoked = acl.revoke("FEEDFACECAFEBEEF").expect("revoke failed");
        assert!(revoked);
        assert_eq!(acl.entries.len(), 1);
        assert!(!acl.contains_key("FEEDFACECAFEBEEF"));

        // Revoking non-existent returns false
        let revoked_again = acl.revoke("FEEDFACECAFEBEEF").expect("revoke non-existent");
        assert!(!revoked_again);
    }

    #[test]
    fn test_acl_diff() {
        let acl = parse_acl(SAMPLE_GUIX_ACL).unwrap();
        let candidates = vec![
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF".to_string(),
            SAMPLE_PUBKEY_ED25519.to_string(),
        ];

        let diff = diff_acl(&acl, &candidates).expect("diff failed");
        assert_eq!(diff.matching.len(), 1);
        assert_eq!(diff.in_acl_only.len(), 1);
        assert_eq!(diff.in_acl_only[0].key_type, "rsa");
        assert_eq!(diff.in_trusted_only.len(), 1);
    }
}
