## What changed

<!-- What this does and why. Link the issue if there is one: Fixes #123 -->

## Type

<!-- Matches the conventional-commit prefixes in CONTRIBUTING.md. -->

- [ ] `feat` — new functionality
- [ ] `fix` — bug fix
- [ ] `perf` — performance
- [ ] `refactor` — no behavior change
- [ ] `docs` / `test` / `chore`

## Checklist

- [ ] `make test` passes
- [ ] `make fmt` run on touched files
- [ ] New `@trusted` blocks document why they are safe, per CONTRIBUTING.md
- [ ] Errors returned as `Result` rather than thrown, where the surrounding code does
- [ ] Docs updated if behavior or configuration changed

## Third-party code

<!-- Leave unchecked if this PR is all original work. -->

- [ ] This PR vendors, copies, or adapts code from another project — and NOTICE
      has been updated with its source, copyright holder, and license

## Breaking changes

<!-- Builderfile syntax, CLI flags, cache format, or the LSP protocol.
     Write "none" if there are none. -->
