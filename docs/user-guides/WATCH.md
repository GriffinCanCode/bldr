# Watch Mode

Watch mode monitors source files and automatically triggers rebuilds when changes are detected.

## Quick Start

```bash
# Watch all targets
bldr build --watch

# Watch specific target
bldr build --watch //src:app

# Standalone watch command
bldr watch

# Custom debounce delay
bldr build --watch --debounce=500
```

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--watch`, `-w` | Enable watch mode | - |
| `--clear` | Clear screen between builds | true |
| `--no-clear` | Don't clear screen | - |
| `--debounce=<ms>` | Debounce delay in milliseconds | 300 |
| `--graph`, `-g` | Show dependency graph on each build | false |
| `--mode=<mode>` | Render mode (auto, interactive, plain) | auto |
| `--verbose`, `-v` | Verbose output | false |

## Platform Support

Builder automatically selects the best available file watcher:

| Platform | Watcher | Requirement |
|----------|---------|-------------|
| macOS | FSEvents | `fswatch` (via Homebrew) |
| Linux | inotify | `inotify-tools` |
| BSD | kqueue | Built-in |
| Other | Polling | None (fallback) |

### Installing Native Watchers

**macOS:**
```bash
brew install fswatch
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt-get install inotify-tools
```

**Linux (RHEL/Fedora):**
```bash
sudo yum install inotify-tools
```

Native watchers provide near-instant change detection with minimal CPU overhead. The polling fallback works everywhere but uses more resources.

## Behavior

Watch mode:

1. Performs an initial build
2. Watches all source files (respecting `.builderignore`)
3. On file change, waits for the debounce delay
4. Re-parses configuration
5. Runs incremental build
6. Displays results
7. Continues until interrupted (Ctrl+C)

### Debouncing

The debounce delay groups rapid file changes into a single rebuild. Adjust based on your workflow:

- **100-200ms**: Fast feedback, may trigger multiple builds during IDE auto-save
- **300-500ms**: Balanced for most workflows
- **1000ms+**: Fewer builds, better for large projects or slow systems

### Caching

Watch mode leverages the build cache:

- Memory-mapped graph persistence for instant startup
- Per-file content hashing
- Only rebuilds affected targets

## Configuration

### .builderignore

Exclude files from watching:

```gitignore
# Build artifacts
bin/
obj/
*.o

# Dependencies
node_modules/
vendor/
.cargo/

# IDE files
.vscode/
.idea/

# Cache
.builder-cache/

# Logs
*.log
```

### Target-Specific Watch

For large projects, watch only relevant targets:

```bash
# Watch frontend only
bldr build --watch //frontend:app

# Watch multiple targets
bldr build --watch //services/auth:api //services/users:api
```

## Integration

### VS Code

Add to `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Watch Build",
      "type": "shell",
      "command": "bldr",
      "args": ["build", "--watch"],
      "isBackground": true,
      "problemMatcher": []
    }
  ]
}
```

### Docker

```dockerfile
FROM dlang/ldc
WORKDIR /app
COPY . .
RUN bldr build
CMD ["bldr", "build", "--watch"]
```

## Troubleshooting

### Changes Not Detected

1. Check `.builderignore` patterns
2. Verify watcher is running (look for "Watching for changes..." message)
3. Increase debounce delay: `--debounce=1000`
4. Check file permissions

### High CPU Usage

Causes:
- Polling watcher active (install native watcher)
- Too many files being watched
- Debounce delay too short

Solutions:
1. Install native watcher (`fswatch` or `inotify-tools`)
2. Add build artifacts to `.builderignore`
3. Watch specific targets only

### Builds Too Slow

1. Use `--no-clear` to preserve logs for debugging
2. Profile with `--verbose`
3. Check cache hit rate (should be >80%)

## Examples

### Frontend Development

```bash
# Watch React app
bldr build --watch //frontend:app
```

### Backend API

```bash
# Watch Go API
bldr build --watch //backend:api
```

### Test-Driven Development

```bash
# Watch and run tests
bldr watch "test --filter unit"
```

## See Also

- `bldr build --help` - Build command options
- `bldr test` - Run tests
