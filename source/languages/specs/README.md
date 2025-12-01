# Language Specifications

This directory contains declarative language specifications that enable zero-code language support in Builder.

## Philosophy

Instead of writing 150+ lines of D code per language handler, we define languages via lightweight JSON specs. This approach:

- ✅ **Zero Recompilation**: Add languages without rebuilding Builder
- ✅ **User Extensible**: Non-developers can add language support
- ✅ **Portable**: Share specs across projects and teams
- ✅ **Community Driven**: Accept language specs as simple JSON PRs
- ✅ **Type Safe**: Validated at runtime with clear error messages

## Spec Format

```json
{
  "language": {
    "name": "mylang",              // Unique identifier
    "display": "MyLang",           // Display name
    "category": "compiled",        // compiled/scripting/jvm/dotnet/web
    "extensions": [".ml"],         // File extensions
    "aliases": ["ml", "mylang"]    // Command-line aliases
  },
  "detection": {
    "shebang": ["#!/usr/bin/env mylang"],
    "files": ["mylang.toml"],      // Project manifest files
    "version_cmd": "mylang --version"
  },
  "build": {
    "compiler": "mylang",
    "compile_cmd": "mylang build {{sources}} -o {{output}} {{flags}}",
    "test_cmd": "mylang test {{sources}}",
    "format_cmd": "mylang fmt {{sources}}",
    "lint_cmd": "mylang lint {{sources}}",
    "check_cmd": "mylang check {{sources}}",
    "env": {
      "MYLANG_PATH": "{{workspace}}/lib"
    },
    "incremental": false,
    "caching": true
  },
  "dependencies": {
    "pattern": "import\\s+\"([^\"]+)\"",
    "resolver": "module_path",
    "manifest": "mylang.toml",
    "install_cmd": "mylang deps install"
  }
}
```

## Template Variables

Command templates support variable substitution:

- `{{sources}}` - Space-separated list of source files
- `{{output}}` - Output file path
- `{{flags}}` - User-provided compiler flags
- `{{workspace}}` - Workspace root directory
- `{{manifest}}` - Path to dependency manifest file

## Current Languages

### Compiled Languages
- **Crystal** (`crystal.json`) - Modern Ruby-like syntax, compiled to native
- **Dart** (`dart.json`) - Google's language for Flutter and web
- **V** (`v.json`) - Fast, safe, compiled language

## Adding a New Language

1. Create `mylang.json` in this directory
2. Fill in language metadata and commands
3. Test with: `bldr build //path/to:target`
4. No recompilation needed!

## Integration

Specs are automatically discovered and loaded by `SpecRegistry`:

```d
import languages.dynamic;

auto registry = new SpecRegistry();
registry.loadAll();  // Loads all *.json specs

if (auto spec = registry.get("crystal")) {
    auto handler = new SpecBasedHandler(*spec);
    // Use like any LanguageHandler
}
```

## Best Practices

1. **Keep it Simple**: Only specify what's needed for basic functionality
2. **Use Patterns**: Leverage existing command patterns where possible
3. **Document Detection**: Help users understand how languages are identified
4. **Test Locally**: Create a small project and test your spec before sharing
5. **Environment Variables**: Use sparingly, prefer command-line flags

## Limitations

Declarative specs work great for straightforward languages. For complex cases requiring:
- Custom dependency resolution logic
- Multi-stage compilation pipelines
- Complex caching strategies
- Deep IDE integration

Consider writing a full D handler in `source/languages/` instead.

## Contributing

To contribute a language spec:

1. Create the JSON file
2. Test with a real project
3. Submit a PR with just the JSON file
4. Include example Builderfile in PR description

That's it! No D knowledge required.

