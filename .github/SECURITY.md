# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report privately through GitHub Security Advisories:

> [Report a vulnerability](https://github.com/GriffinCanCode/bldr/security/advisories/new)

Please include:

- What the vulnerability lets an attacker do
- Steps to reproduce, ideally a minimal `Builderfile` and project tree
- The bldr version (`bldr --version`), OS, and D compiler
- Any mitigation you have already found

You can expect an acknowledgement within a few days and an assessment of
severity and a fix timeline after that.

## Scope

bldr executes compilers and arbitrary build commands by design. A build that
runs code declared in its own `Builderfile` is bldr working correctly, not a
vulnerability.

What is in scope:

- Sandbox escape — a build action reaching outside its declared inputs and
  outputs on Linux, macOS, or Windows
- Cache poisoning — writing an artifact another build will trust, or defeating
  the BLAKE3 integrity check on a cache entry
- Command injection through a path, target name, or any other value that flows
  from a `Builderfile` into a spawned process
- Path traversal in workspace, cache, or artifact handling
- Remote execution and distributed cache protocol flaws — worker impersonation,
  unauthenticated artifact upload, tampering in transit
- Privilege escalation through the LSP server or the VS Code extension

What is out of scope:

- Vulnerabilities in compilers, linkers, or package managers bldr invokes —
  report those upstream
- Vulnerabilities in the example projects under `examples/`, which exist to
  demonstrate language handlers and are not production code
- Anything requiring an attacker to already have write access to the workspace

## Supported versions

Fixes land on `master` and ship in the next release. Earlier releases are not
patched.

## Security architecture

The audit that established bldr's current security posture — the secure
execution framework, cache integrity validation, and path validation — is
documented in [`docs/security/SECURITY.md`](../docs/security/SECURITY.md).
That file is a report on the implementation, not a reporting policy; this file
is the policy.
