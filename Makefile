# Builder Makefile

.PHONY: all build build-c build-lsp lsp test tests examples clean install install-lsp help tsan test-tsan extension

all: build

# Build the project
build: build-c
	@echo "Building Builder..."
	@dub build --build=release

# Build C libraries (SIMD, BLAKE3, and Serialization)
build-c:
	@echo "Building C libraries..."
	@mkdir -p bin/obj
	@cd source/infrastructure/utils/simd/c && $(MAKE) clean && $(MAKE)
	@cp source/infrastructure/utils/simd/c/*.o bin/obj/ 2>/dev/null || true
	@cd source/infrastructure/utils/crypto/c && $(MAKE) clean && $(MAKE)
	@cp source/infrastructure/utils/crypto/c/*.o bin/obj/ 2>/dev/null || true
	@cd source/infrastructure/utils/serialization/c && $(MAKE) clean && $(MAKE)
	@cd source/infrastructure/parsing/treesitter/grammars && $(MAKE) clean && $(MAKE) stub
	@mkdir -p bin/obj/treesitter
	@cp bin/obj/treesitter/stub.o bin/obj/ts_loader.o
	@echo "C libraries built"

# Build LSP server
build-lsp: build-c
	@echo "Building Builder LSP server..."
	@dub build --config=lsp --build=release

# Alias for build-lsp
lsp: build-lsp

# Build both builder and LSP server
build-all: build build-lsp

# Build debug version
debug:
	@echo "Building debug version..."
	@dub build --build=debug

# Run tests
test:
	@echo "Running tests..."
	@dub test

# Run tests with coverage
test-coverage:
	@echo "Running tests with coverage..."
	@./tests/run-tests.sh --coverage

# Run tests in parallel
test-parallel:
	@echo "Running tests in parallel..."
	@dub test -- --parallel

# Run full test suite with script
tests:
	@echo "Running full test suite..."
	@./tests/run-tests.sh

# Run all example projects
examples:
	@echo "Testing all example projects..."
	@./examples/run-all-examples.sh

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@dub clean
	@rm -rf bin/
	@rm -rf .builder-cache/
	@rm -f *.lst
	@cd source/infrastructure/utils/simd/c && $(MAKE) clean 2>/dev/null || true
	@cd source/infrastructure/utils/crypto/c && $(MAKE) clean 2>/dev/null || true
	@find . -name "*.o" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Install to system
install: build
	@echo "Installing to /usr/local/bin..."
	@cp bin/builder /usr/local/bin/
	@echo "Installed successfully!"

# Install LSP server
install-lsp: build-lsp
	@echo "Installing Builder LSP to /usr/local/bin..."
	@cp bin/builder-lsp /usr/local/bin/
	@echo "LSP server installed successfully!"

# Install both builder and LSP server
install-all: build-all
	@echo "Installing to /usr/local/bin..."
	@cp bin/builder /usr/local/bin/
	@cp bin/builder-lsp /usr/local/bin/
	@echo "Installed successfully!"

# Uninstall from system
uninstall:
	@echo "Uninstalling..."
	@rm -f /usr/local/bin/builder
	@rm -f /usr/local/bin/builder-lsp
	@echo "Uninstalled successfully!"

# Run benchmarks
bench:
	@echo "Running benchmarks..."
	@dub test -- --filter="bench"

# Build with Thread Sanitizer (requires LDC)
tsan:
	@echo "Building with Thread Sanitizer (TSan)..."
	@echo "Note: Requires LDC compiler (use: dub build --compiler=ldc2 --build=tsan)"
	@dub build --compiler=ldc2 --build=tsan

# Run tests with Thread Sanitizer
test-tsan:
	@echo "Running tests with Thread Sanitizer (TSan)..."
	@echo "Note: This will detect data races and threading issues"
	@./tools/run-tsan-tests.sh

# Format code
fmt:
	@echo "Formatting code..."
	@find source tests -name "*.d" -exec dfmt -i {} \;

# Generate documentation
docs:
	@./tools/generate-docs.sh

# Open documentation in browser
docs-open: docs
	@echo "Opening documentation in browser..."
	@open docs/api/index.html || xdg-open docs/api/index.html || sensible-browser docs/api/index.html

# Serve documentation on local web server
docs-serve:
	@echo "Starting documentation server on http://localhost:8000..."
	@echo "Press Ctrl+C to stop"
	@python3 -m http.server --directory docs/api 8000

# Clean documentation
docs-clean:
	@echo "Cleaning documentation..."
	@rm -rf docs/api
	@echo "Documentation cleaned"

# Package VS Code extension with LSP server
extension: build-lsp
	@echo "Packaging VS Code extension..."
	@mkdir -p tools/vscode/builder-lang/bin
	@cp bin/builder-lsp tools/vscode/builder-lang/bin/
	@cd tools/vscode/builder-lang && npm install && npx vsce package
	@echo "Extension packaged: tools/vscode/builder-lang/builder-lang-*.vsix"

# Install VS Code extension (requires builder to be built)
install-extension: extension
	@echo "Installing VS Code extension..."
	@code --install-extension tools/vscode/builder-lang/builder-lang-*.vsix
	@echo "Extension installed! Reload VS Code to activate."

# Show help
help:
	@echo "Builder Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make build             - Build release version"
	@echo "  make build-lsp         - Build LSP server"
	@echo "  make lsp               - Alias for build-lsp"
	@echo "  make build-all         - Build both builder and LSP server"
	@echo "  make debug             - Build debug version"
	@echo "  make test              - Run tests (basic)"
	@echo "  make tests             - Run full test suite"
	@echo "  make test-coverage     - Run tests with coverage"
	@echo "  make test-parallel     - Run tests in parallel"
	@echo "  make test-tsan         - Run tests with Thread Sanitizer (requires LDC)"
	@echo "  make tsan              - Build with Thread Sanitizer"
	@echo "  make bench             - Run benchmarks"
	@echo "  make examples          - Test all example projects"
	@echo "  make clean             - Clean build artifacts"
	@echo "  make install           - Install builder to /usr/local/bin"
	@echo "  make install-lsp       - Install LSP server to /usr/local/bin"
	@echo "  make install-all       - Install both builder and LSP server"
	@echo "  make uninstall         - Uninstall from system"
	@echo "  make extension         - Package VS Code extension with LSP"
	@echo "  make install-extension - Build and install VS Code extension"
	@echo "  make fmt               - Format code"
	@echo "  make docs              - Generate DDoc documentation"
	@echo "  make docs-open         - Generate and open documentation"
	@echo "  make docs-serve        - Serve documentation on localhost:8000"
	@echo "  make docs-clean        - Clean documentation"
	@echo "  make help              - Show this help"

