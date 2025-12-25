# Builder Explain - Usage Guide for AI Assistants

## Purpose

`bldr explain` provides **instant, structured documentation** optimized for AI assistants. Unlike human-oriented markdown docs, this system gives you machine-readable, queryable information via simple CLI commands.

## Why This Exists

AI assistants can only execute commands, not:
- Browse documentation websites
- Click links
- Navigate interactive docs
- Read long-form documentation efficiently

`bldr explain` solves this by providing:
- **Single-command answers** - No navigation needed
- **Structured output** - Easy to parse and understand
- **Concise information** - Only what matters
- **Copy-paste examples** - Working code ready to use
- **Related topics** - Easy discovery of connected concepts

## Command Reference

### 1. Get Topic Definition
```bash
bldr explain <topic>
```

**Use when:** You need to understand a specific concept

**Example:**
```bash
bldr explain blake3
bldr explain caching
bldr explain java-support
```

**Output structure:**
- Summary (one line)
- Definition (detailed explanation)
- Key points (bullet list)
- Usage examples (code)
- Related topics (links)
- Next steps (what to read next)

### 2. List All Topics
```bash
bldr explain list
```

**Use when:** You want to see what documentation is available

**Output:** All available topics with one-line summaries

### 3. Search Topics
```bash
bldr explain search "<query>"
```

**Use when:** You're not sure of the exact topic name or want to find related topics

**Example:**
```bash
bldr explain search "fast builds"
bldr explain search "cache"
bldr explain search "maven"
bldr explain search "python"
```

**Searches in:**
- Topic names
- Summaries
- Keywords

### 4. Get Examples
```bash
bldr explain example <topic>
```

**Use when:** You need working code or command examples

**Example:**
```bash
bldr explain example caching
bldr explain example java-support
bldr explain example watch
```

**Output:** Numbered examples with descriptions and copy-paste ready code

## Available Topics

### Core Concepts
- **blake3** - Fast cryptographic hashing (3-5x faster than SHA-256)
- **caching** - Multi-tier caching system (target, action, remote)
- **determinism** - Bit-for-bit reproducible builds
- **incremental** - Smart rebuilds (only affected files)
- **action-cache** - Fine-grained caching per compile/link/test
- **remote-cache** - Shared cache for teams/CI
- **hermetic** - Isolated build execution
- **workspace** - Project configuration (Builderspace)
- **targets** - Build targets and dependencies

### Reference
- **cli** - All CLI commands (build, test, watch, query, verify, etc.)
- **watch** - Auto-rebuild on file changes with debouncing
- **plugins** - RPC-based plugin system (any language)
- **wizard** - Interactive project setup (init, infer commands)
- **bldrquery** - Query language for build graph

### Languages (25+ supported)
- **languages** - Overview of all 25+ supported languages
- **java-support** - Maven, Gradle, JUnit, JAR/WAR/native-image
- **dynamic-languages** - Python, Ruby, PHP, Perl, Lua, R, Go, Elixir, Gleam
- **cpp-support** - C/C++ with CMake, Make, Ninja, etc.
- **rust-support** - Rust with Cargo
- **go-support** - Go modules
- **python-support** - Python with pip, poetry, uv

### Aliases
These shortcuts map to main topics:
- `hash` → blake3
- `cache` → caching
- `reproducible` → determinism
- `sandbox` → hermetic
- `builderspace` → workspace
- `target` → targets
- `init` → wizard
- `maven`, `gradle`, `jvm` → java-support
- `ruby`, `php`, `lua`, `elixir` → dynamic-languages

## Typical Workflows

### Workflow 1: Understanding a New Concept
```bash
# Start with the topic
bldr explain caching

# Explore related concepts
bldr explain blake3
bldr explain action-cache
bldr explain remote-cache

# Get examples
bldr explain example caching
```

### Workflow 2: Setting Up a Project
```bash
# Learn about project setup
bldr explain wizard

# Check language-specific info
bldr explain java-support
# or
bldr explain languages

# Initialize project
bldr init
```

### Workflow 3: Exploring CLI Commands
```bash
# Get full CLI reference
bldr explain cli

# Learn about specific features
bldr explain watch
bldr explain query

# Get examples
bldr explain example cli
```

### Workflow 4: Solving a Problem
```bash
# Search for relevant topics
bldr explain search "slow builds"

# Read about performance topics
bldr explain incremental
bldr explain caching

# Get working examples
bldr explain example incremental
```

## Best Practices

### DO:
- ✅ Use single-word topic names: `bldr explain blake3`
- ✅ Search when unsure: `bldr explain search "cache"`
- ✅ Follow related links: Check the "related" field
- ✅ Get examples: `bldr explain example <topic>`
- ✅ Use aliases: `hash` instead of `blake3` is fine

### DON'T:
- ❌ Use full phrases: `bldr explain "BLAKE3 hashing"` (just use `blake3`)
- ❌ Guess syntax: Use `list` to see exact names
- ❌ Read everything: Follow related topics for discovery

## Output Format

All outputs follow this structure:

```
TOPIC NAME
────────────────

SUMMARY:
  One-line description

DEFINITION:
  Detailed explanation
  Multiple paragraphs as needed

KEY POINTS:
  • Point 1
  • Point 2
  • Point 3

USAGE:
  Example 1: Description
    code here
  
  Example 2: Description
    code here

RELATED:
  topic1, topic2, topic3

NEXT STEPS:
  What to read or do next
```

## Full CLI Commands Reference

For quick reference, here are all Builder commands:

```bash
# Build commands
bldr build [target]           # Build targets
bldr build --watch            # Build with watch mode
bldr test [target]            # Run tests
bldr clean                    # Remove build artifacts

# Analysis commands
bldr graph [target]           # Visualize dependency graph
bldr query '<expr>'           # Query build graph
bldr verify                   # Verify build determinism

# Setup commands
bldr init                     # Initialize workspace
bldr wizard                   # Interactive setup
bldr infer                    # Auto-detect project structure
bldr migrate                  # Migrate from other build systems

# Watch and development
bldr watch [target]           # Watch and rebuild on changes

# Remote and distributed
bldr cache-server             # Run remote cache server
bldr coordinator              # Run build coordinator
bldr worker                   # Run build worker

# Utilities
bldr explain <topic>          # AI documentation
bldr plugin <cmd>             # Manage plugins
bldr telemetry <cmd>          # View build stats
bldr resume                   # Resume from checkpoint
bldr install-extension        # Install VS Code extension
bldr help [command]           # Get help
bldr version                  # Show version
```

## Performance

All operations are fast:
- **List**: < 50ms
- **Show topic**: < 100ms
- **Search**: < 150ms
- **Examples**: < 100ms

No database or network calls - all file-based.

## Troubleshooting

### Topic not found
```bash
bldr explain nonexistent
# Error: Topic not found: nonexistent
# Available topics:
#   bldr explain list
```

**Solution:** Use `bldr explain list` to see available topics

### Unclear which topic to use
```bash
bldr explain search "keyword"
```

**Solution:** Search for related terms

### Need more detail than explain provides
**Solution:** Check the "references" or "next_steps" field in the topic for links to full docs

## Summary

`bldr explain` is your **instant documentation assistant**. Use it to:
1. Quickly understand concepts
2. Find working examples
3. Discover related features
4. Get command syntax

It's designed specifically for AI assistants to get the information they need in a single command.
