# AI-Optimized Documentation

This directory contains structured, machine-readable documentation optimized for AI assistants and LLMs. Unlike the human-oriented docs in `docs/`, this documentation is designed for **instant, queryable access via CLI**.

## Purpose

AI assistants can only execute commands, not browse docs or click links. This system provides:

- **Instant definitions** - Quick concept explanations
- **Working examples** - Copy-paste ready code
- **Step-by-step workflows** - Concrete action sequences
- **Troubleshooting guides** - Problem → Solution mapping
- **Command references** - CLI usage with all flags

## Structure

```
ai/
├── concepts/          # Core concept definitions
├── workflows/         # Step-by-step task guides
├── examples/          # Working code examples
├── commands/          # CLI command references
├── troubleshooting/   # Problem-solution mappings
└── index.yaml         # Search index
```

## Usage

```bash
# Get a concept definition
bldr explain blake3

# Get working examples
bldr explain example caching

# Get step-by-step workflow
bldr explain workflow setup-remote-cache

# Search all topics
bldr explain search "incremental builds"

# List all available topics
bldr explain list
```

## Format

Each document is YAML-formatted for machine readability:

```yaml
topic: concept-name
category: concepts
summary: "One-line description"
definition: "Detailed explanation..."
key_points:
  - "Point 1"
  - "Point 2"
related: [topic1, topic2]
examples:
  - "Code or command example"
next_steps: "What to read/do next"
```

## vs Human Docs

| Aspect | Human Docs (`docs/`) | AI Docs (`docs/ai/`) |
|--------|---------------------|---------------------|
| Format | Markdown prose | Structured YAML |
| Style | Narrative | Factual, concise |
| Length | Comprehensive | Essential only |
| Examples | Illustrative | Copy-paste ready |
| Organization | By feature | By query type |
| Access | Browser/editor | CLI only |

## Contributing

When adding AI docs:
1. Use YAML format (see templates/)
2. Be concise and factual
3. Include working examples
4. Link related topics
5. Update index.yaml

