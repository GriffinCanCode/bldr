# Tree-sitter Integration Tests

Comprehensive test suite for the tree-sitter AST parsing integration.

## Test Modules

### treesitter_integration.d
Integration tests for the complete tree-sitter system:
- Configuration loading
- Registry initialization  
- Parser registration
- Dependency checking
- Grammar loading (if available)
- Graceful fallback behavior

### config_validation.d
Validation tests for language configurations:
- JSON format validation
- Required field checking
- Extension mapping
- Symbol type mappings
- Configuration completeness
- Performance benchmarks

## Running Tests

```bash
# Run all tests
dub test

# Run specific test file
dub test -- --filter=treesitter_integration

# Run with verbose output
dub test -- --verbose
```

## Test Expectations

### With Tree-sitter Installed
If tree-sitter is installed on the system, tests will:
- ✅ Load all 28 language configurations
- ✅ Attempt to load available grammars
- ✅ Register parsers for languages with grammars
- ✅ Log which languages have full AST support

### Without Tree-sitter
If tree-sitter is not installed, tests will:
- ✅ Load all configurations (grammars not required)
- ✅ Gracefully fall back to file-level tracking
- ⚠️  Log that grammars are unavailable
- ✅ All tests still pass (no failures)

## Expected Behavior

The tree-sitter integration is designed to be **fully optional**:

1. **No Breaking Changes**: System works without any grammars
2. **Graceful Degradation**: Falls back to file-level if grammar fails
3. **Progressive Enhancement**: Adds AST features when available
4. **Zero Runtime Errors**: Missing grammars log warnings, don't crash

## Installation for Full Functionality

To enable full AST-level parsing:

```bash
# Install tree-sitter
brew install tree-sitter  # macOS
sudo apt-get install libtree-sitter-dev  # Ubuntu

# Build grammars
cd source/infrastructure/parsing/treesitter/grammars
./build-grammars.sh

# Rebuild Builder
dub build
```

## Troubleshooting

### "Tree-sitter library not found"
**Not an error** - System falls back to file-level tracking. To enable AST parsing, install tree-sitter (see above).

### "No grammars loaded"
**Expected** if grammar libraries aren't built. Run `build-grammars.sh` to download and build them.

### Tests fail with linking errors
Ensure tree-sitter is installed and dub.json has correct library paths:
- macOS: `/opt/homebrew/lib` and `/usr/local/lib`
- Linux: `/usr/lib` and `/usr/local/lib`

## Test Coverage

- ✅ 28 language configurations
- ✅ JSON format validation
- ✅ Extension mapping
- ✅ Symbol type mappings
- ✅ Registry initialization
- ✅ Parser creation
- ✅ Dependency checking
- ✅ Graceful fallback
- ✅ Integration testing
- ✅ Performance benchmarks

## Adding New Language Tests

To add tests for a new language:

1. Add config validation to `config_validation.d`
2. Add extension tests to extension mapping
3. Add symbol type tests for language-specific nodes
4. Update expected language count

## See Also

- [Tree-sitter Integration Guide](../../../docs/features/TREESITTER_PHASE2.md)
- [Language Configurations](../../../source/infrastructure/parsing/configs/)
- [Grammar Build System](../../../source/infrastructure/parsing/treesitter/grammars/)

