# Coding Models & Guidelines

## Language Usage

- **Major Systems Code**: The core systems and daemons in this repository should be written in **Rust**.
- **Scripting & Glue Code**: Wherever possible, all glue code, setup scripts, and automation should be written in **Guile Scheme** (instead of Bash or other scripting languages). This ensures closer integration with Guix and maintains a consistent, lispy environment.
