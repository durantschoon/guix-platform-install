# Polylith-style Rust in GIPS

<!-- markdownlint-disable MD013 -->

This document introduces our Polylith-inspired crate layout and records learnings and gotchas when applying that structure with Cargo workspaces.

We do **not** use the [Polylith](https://polylith.gitbook.io/polylith) tool itself; we adopt the structural idea: **bases** (shared foundations with no internal deps), **components** (reusable libraries), and **apps** (thin executables that wire components together). The goal is clear boundaries, testability, and reuse without a single giant crate.

## Layout

- **`bases/`** – Shared foundations. No dependency on any other workspace crate. Only external crates (e.g. `serde`, `toml`).
  - Example: `gips-config` (config types, TOML loading, defaults).
- **`components/`** – Reusable libraries. They may depend on bases and on other components. No cycles.
  - Examples: `gips-db`, `gips-ipfs`, `gips-gns`, `gips-http`, `gips-scheme-config`, `gips-trust`.
- **Top-level apps** – Binaries that depend on bases and/or components. Kept thin; orchestration and CLI live here.
  - `gipsd` – daemon: loads config, connects DB, builds router, serves HTTP.
  - `gips` – CLI: no workspace crate deps; talks to `gipsd` over HTTP.

The dependency graph is documented with a diagram in [architecture.md](architecture.md).

## Dependency rules

| Crate type | May depend on                        |
| ---------- | ------------------------------------ |
| Base       | External crates only                 |
| Component  | Bases + other components (no cycles) |
| App        | Bases + components (as needed)       |

`gips` is a special case: it stays a thin HTTP client that never pulls in IPFS, GNS, or DB code. It does depend on `gips-config` (to locate the config directory and auth token) and `gips-trust` (for local key management — `gips key generate-guix`/`export-guix`), but all daemon behavior is reached over HTTP.

## Path dependencies

We use **path** dependencies for **internal** workspace crates (shared **external** crates like `tokio`/`serde` are declared once in the root `[workspace.dependencies]` and referenced with `workspace = true`). Each crate’s `Cargo.toml` points at the other internal crate’s path relative to that crate:

- From **`gipsd`** or **`gips`**: `../bases/gips-config`, `../components/gips-db`, etc.
- From a **component** (e.g. `components/gips-http`): `../../bases/gips-config`, `../gips-db`, etc.
- From a **base**: no workspace path deps.

So path depth differs by location: one level up from an app (`../`), two levels up from a component (`../../`) when pointing at `bases/`.

## Workspace configuration

Root `Cargo.toml` declares `[workspace] members = [ ... ]`, `resolver = "2"`, and a `[workspace.dependencies]` table pinning shared **external** crates (tokio, serde, axum, sqlx, …) to one version across the workspace. All crates use `edition = "2021"`. Internal crates are never in `[workspace.dependencies]`; each internal dependency is a path.

## Adding a new base or component

1. Create the directory: `bases/<name>/` or `components/<name>/`.
2. Add `Cargo.toml` and `src/lib.rs` (or the desired module layout).
3. Add the crate to the root `Cargo.toml` under `[workspace] members`.
4. From other crates, add a path dependency using the correct relative path (see above).

## Build and test

From the repository root:

- `cargo build` – build all workspace members.
- `just daemon` (or `cargo run -p gipsd`) – build and run the daemon.
- `just status` / `just subscribe` (or `cargo run -p gips -- ...`) – build and run the CLI.
- `cargo test` – run tests for all crates.

## Learnings and gotchas

1. **Path depth** – It’s easy to get `../` wrong when adding a dependency from a component to a base. From `components/foo`, the base is `../../bases/gips-config`; from `gipsd`, it’s `../bases/gips-config`. Double-check when adding new deps.

2. **Bases stay minimal** – Keeping bases free of workspace deps keeps the dependency DAG acyclic and makes it obvious what the “foundation” is. If a base needs something that another workspace crate provides, that’s a sign to either move the dependency to an external crate or to turn the new code into a component that depends on the existing base.

3. **Components can depend on components** – We allow this (e.g. `gips-http` depends on `gips-db`, `gips-ipfs`, `gips-gns`). Avoid circular dependencies; the graph should stay a DAG.

4. **No workspace versioning for internal crates** – We don’t publish these crates to crates.io. Version fields in each `Cargo.toml` exist for consistency but are not used for coordination; path deps are always “current repo.”

5. **Thin apps** – Keeping `gipsd` and `gips` thin makes it clear where “application” logic lives (HTTP routing, config loading, CLI parsing) versus reusable logic (DB, IPFS, GNS, config types). New features that are reusable should go into components; app code should mostly wire and call.

6. **Tests** – Unit tests live in each crate (`#[cfg(test)]` or `tests/`). Integration-style tests that need the full daemon or multiple components can live in the app crates (e.g. `gipsd/tests/`) or in a dedicated integration test layout if we add one later.
