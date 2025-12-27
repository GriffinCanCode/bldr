# Scripting Languages

First-class support for scripting language builds with runtime detection, environment management, formatting, linting, type checking, and caching.

## Architecture

All scripting handlers extend `BaseScriptingHandler` from `languages/scripting/base.d`:

```
languages/scripting/
├── base.d          ← BaseScriptingHandler (shared workflow)
├── python/core/    ← PythonHandler extends BaseScriptingHandler
├── ruby/core/      ← RubyHandler extends BaseScriptingHandler
├── go/core/        ← GoHandler extends BaseScriptingHandler
├── php/core/       ← PHPHandler extends BaseScriptingHandler
├── lua/core/       ← LuaHandler extends BaseScriptingHandler
├── r/core/         ← RHandler extends BaseScriptingHandler
├── elixir/core/    ← ElixirHandler extends BaseScriptingHandler
├── gleam/core/     ← GleamHandler extends BaseScriptingHandler
├── perl/core/      ← PerlHandler extends BaseScriptingHandler
└── package.d
```

The base class provides a unified build workflow:
1. **parseConfig()** → Parse language-specific configuration
2. **setupEnvironment()** → Detect runtime and configure environment
3. **preBuildSteps()** → Dependency installation, formatting, linting, type checking
4. **validateSyntax()** → Language syntax validation
5. **buildTarget()** → Execute build with action-level caching
6. **postBuildSteps()** → Cleanup, packaging, verification

Individual handlers implement:
- Runtime/interpreter detection and version queries
- Config parsing from target langConfig
- Environment setup (virtualenvs, version managers)
- Formatter/linter/type checker integration
- Build command generation

## Base Class Features

`BaseScriptingHandler` provides common result types and hook methods:

**Result Types:**
- `ScriptingStepResult` – Generic step outcome
- `EnvironmentSetupResult` – Runtime detection result with path/version
- `SyntaxValidationResult` – Syntax validation with error collection
- `FormatStepResult` – Formatter execution result
- `LintStepResult` – Linter execution with warning/error counts
- `TypeCheckStepResult` – Type checker execution result
- `DependencyInstallResult` – Package installation outcome

**Hook Methods (override as needed):**
- `languageId()` – Return language identifier (e.g., "python")
- `configKeys()` – Config section names (e.g., ["python", "pyConfig"])
- `setupEnvironment()` – Set up runtime environment
- `validateSyntax()` – Validate source file syntax
- `installDependencies()` – Install packages
- `runFormatter()` – Execute code formatter
- `runLinter()` – Execute linter
- `runTypeChecker()` – Execute type checker
- `buildExecutableImpl()` – Build executable target
- `buildLibraryImpl()` – Build library target
- `runTestsImpl()` – Execute test suite

## Supported Languages

### Python

**File Extensions:** `.py`, `.pyw`, `.pyi`

**Features:**
- Virtual environment management (venv, virtualenv, conda, poetry)
- Package managers: uv, pip, poetry, PDM, hatch, conda, pipenv
- Type checking: mypy, pyright, pytype, pyre
- Formatters: ruff, black, blue, yapf, autopep8
- Linters: ruff, pylint, flake8, bandit
- Test runners: pytest, unittest, nose2, tox
- Bytecode compilation support

### Ruby

**File Extensions:** `.rb`, `.rake`, `.gemspec`

**Features:**
- Version managers: rbenv, rvm, chruby, asdf
- Package managers: bundler, rubygems
- Formatters: rubocop, standard
- Test frameworks: rspec, minitest, cucumber, test-unit
- Gem building and packaging
- Rails integration

### Go

**File Extensions:** `.go`

**Features:**
- Go modules support
- Cross-compilation built-in
- CGO detection and configuration
- go fmt formatting
- go vet linting
- Plugin build mode
- Test coverage reporting

### PHP

**File Extensions:** `.php`, `.phtml`, `.php3`, `.php4`, `.php5`, `.php7`, `.phps`

**Features:**
- Composer package management
- PHAR packaging
- FrankenPHP support
- Formatters: php-cs-fixer, phpcs
- Static analysis: PHPStan, Psalm, Phan
- Test frameworks: PHPUnit, Pest, Codeception

### Lua

**File Extensions:** `.lua`

**Features:**
- Multiple interpreters: Lua 5.x, LuaJIT, LuaU
- LuaRocks package manager
- StyLua formatter
- Luacheck linter
- Bytecode compilation
- Test frameworks: Busted, LuaUnit

### R

**File Extensions:** `.R`, `.r`, `.Rmd`

**Features:**
- Environment managers: renv, packrat
- Formatters: styler
- Linters: lintr
- R Markdown rendering
- Shiny application support
- Package building
- Test frameworks: testthat, tinytest, RUnit

### Elixir

**File Extensions:** `.ex`, `.exs`

**Features:**
- Mix build tool integration
- Hex package manager
- mix format formatting
- Credo linting
- Dialyzer type checking
- Phoenix framework support
- Umbrella project support
- Escript generation
- Test with ExUnit

### Gleam

**File Extensions:** `.gleam`

**Features:**
- gleam build integration
- gleam.toml configuration
- gleam format formatting
- JavaScript target compilation
- Documentation generation
- Hex package integration

### Perl

**File Extensions:** `.pl`, `.pm`, `.pod`, `.t`

**Features:**
- CPAN/cpanm package management
- Perl::Tidy formatting
- Perl::Critic linting
- POD documentation generation
- Module installation
- Test::More integration

## Configuration Example

```d
target("app") {
    type: executable;
    language: python;
    sources: ["src/**/*.py"];
    python: {
        pythonVersion: "3.11";
        venv: { enabled: true; autoCreate: true };
        packageManager: "uv";
        installDeps: true;
        typeCheck: { enabled: true; checker: "pyright" };
        formatter: "ruff";
        linter: "ruff";
        test: { runner: "pytest"; coverage: true };
    }
}
```

## Action-Level Caching

All scripting language handlers use Builder's action cache:
- Source file content hashing
- Dependency tracking
- Output artifact caching
- Incremental rebuilds

## Runtime Detection

Builder auto-detects installed runtimes:

```bash
bldr info toolchains
```

Shows detected interpreters with versions for all supported languages.

## Design Principles

1. **Zero-config sensible defaults** – Auto-detect project structure and tools
2. **Speed first** – Prefer fastest tools (uv, ruff, pyright)
3. **Comprehensive coverage** – Support all major package managers and tools
4. **Modular architecture** – Each handler focuses on language-specific logic
5. **Type safety** – Strong typing with enums and validated configs

