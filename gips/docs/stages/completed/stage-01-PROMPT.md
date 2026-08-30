# Stage 01: Scheme Configuration API

**Motivation**: According to `docs/TODO.md` (Plan A), we need to define a stable Scheme config API (procedures, records) mirroring the Rust config fields so that users can define their config natively in Guile.

**The Change**:

1. Create a Scheme module `(gips config)` that defines a `gipsd-configuration` record type.
2. Provide default values matching the Rust `GipsdConfig` defaults.
3. Write a procedure to serialize this record to a TOML string so the Rust daemon can read it.

**Allowed Files Whitelist**:

- `scheme/gips/config.scm` (NEW)
- `scheme/README.md`

**Enumerated Tests**:

1. Loading the module in a Guile REPL succeeds.
2. Instantiating `(gipsd-configuration (listen "127.0.0.1:9090"))` succeeds.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass (to ensure no Rust breakage).
- Scheme code successfully evaluates.

**Commit Message**: `[stage-01] feat(scheme): define Scheme config API`

**Report Requirements**: State any deviations from the prompt. Provide the Guile REPL output demonstrating the record instantiation.
