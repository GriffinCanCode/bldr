# Builder Security Plugin

Dependency vulnerability scanner for Builder builds.

## Features

- **Vulnerability Scanning**: Scans dependencies for known CVEs
- **Multi-Language Support**: Python, JavaScript, Rust, Go, and more
- **Severity Classification**: CRITICAL, HIGH, MEDIUM, LOW
- **Actionable Reports**: Specific version recommendations
- **Automated Updates**: Integration with package managers

## Build

```bash
cargo build --release
cp target/release/builder-plugin-security builder-plugin-security
```

## Install

```bash
cp builder-plugin-security /usr/local/bin/
# Or via Homebrew:
brew install builder-plugin-security
```

## Test

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | ./builder-plugin-security
```

## Supported Dependency Files

- **Python**: `requirements.txt`, `Pipfile`, `pyproject.toml`
- **JavaScript**: `package.json`, `package-lock.json`, `yarn.lock`
- **Rust**: `Cargo.toml`, `Cargo.lock`
- **Go**: `go.mod`, `go.sum`
- **Ruby**: `Gemfile`, `Gemfile.lock`

## Vulnerability Sources

The plugin checks against:

- **NVD**: National Vulnerability Database
- **OSV**: Open Source Vulnerabilities
- **GitHub Security Advisories**
- **Language-specific databases** (PyPI, npm, crates.io)

## Report Format

Security reports are saved in `.builder-cache/security-report.json`:

```json
[
  {
    "id": "CVE-2021-1234",
    "severity": "CRITICAL",
    "package": "django",
    "version": "2.2.0",
    "description": "SQL injection vulnerability",
    "fixed_in": "2.2.24"
  }
]
```

## Configuration

Add to your `Builderspace`:

```d
workspace("myproject") {
    plugins: [
        {
            name: "security";
            config: {
                fail_on_critical: true;
                fail_on_high: false;
                ignore_vulnerabilities: ["CVE-2021-1234"];
            };
        }
    ];
}
```

## CI/CD Integration

```bash
# Fail build on critical vulnerabilities
bldr build //app:main --plugin security --strict
```

## License

MIT

