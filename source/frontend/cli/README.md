# CLI Package

Event-driven rendering system for beautiful terminal output and comprehensive command-line interface for Builder.

## Architecture

```
frontend/cli/
├── events/              # Build event system
│   └── events.d         # Strongly-typed build events
├── control/             # Terminal control
│   └── terminal.d       # Terminal capabilities detection
├── display/             # Output rendering
│   ├── format.d         # Message formatting and styling
│   └── render.d         # Main rendering coordinator
├── output/              # Output management
│   ├── progress.d       # Lock-free progress tracking
│   └── stream.d         # Multi-stream output management
├── input/               # User input
│   └── prompt.d         # Interactive prompts (menus, confirmations)
├── watch/               # Watch mode
│   └── discovery.d      # File change discovery
└── commands/            # CLI commands
    ├── project/         # Project management
    │   ├── init.d       # Initialize Builderfile
    │   ├── wizard.d     # Interactive setup wizard
    │   └── migrate.d    # Build system migration
    ├── execution/       # Build execution
    │   ├── discover.d   # Target discovery
    │   ├── infer.d      # Target inference (dry-run)
    │   ├── query.d      # Query targets and deps
    │   ├── test.d       # Test execution
    │   └── verify.d     # Build verification
    ├── extensions/      # Extension commands
    │   ├── plugin.d     # Plugin management
    │   ├── telemetry.d  # Build analytics
    │   └── watch.d      # Watch mode command
    ├── infrastructure/  # Infrastructure commands
    │   ├── cacheserver.d # Cache server management
    │   ├── coordinator.d # Distributed coordinator
    │   └── worker.d     # Worker management
    └── help/            # Help system
        ├── help.d       # Help command
        └── explain.d    # Detailed explanations
```

## Modules

### Event-Driven Rendering
- **events/events.d** - Strongly-typed build events
- **control/terminal.d** - Terminal control and capabilities detection
- **output/progress.d** - Lock-free progress tracking
- **output/stream.d** - Multi-stream output management
- **display/format.d** - Message formatting and styling
- **display/render.d** - Main rendering coordinator

### Interactive Input
- **input/prompt.d** - Interactive prompts with arrow key navigation
  - Select menus
  - Confirmation prompts
  - Text input
  - Multi-select with checkboxes

### Commands

**Project Management:**
- **commands/project/wizard.d** - Interactive project setup wizard
- **commands/project/init.d** - Initialize Builderfile with auto-detection
- **commands/project/migrate.d** - Migrate from other build systems

**Build Execution:**
- **commands/execution/infer.d** - Preview auto-detected targets (dry-run)
- **commands/execution/query.d** - Query targets and dependencies
- **commands/execution/discover.d** - Target discovery
- **commands/execution/test.d** - Test execution
- **commands/execution/verify.d** - Build verification

**Extensions:**
- **commands/extensions/telemetry.d** - Build analytics and performance insights
- **commands/extensions/plugin.d** - Plugin management
- **commands/extensions/watch.d** - Watch mode

**Infrastructure:**
- **commands/infrastructure/cacheserver.d** - Cache server management
- **commands/infrastructure/coordinator.d** - Distributed build coordinator
- **commands/infrastructure/worker.d** - Worker management

**Help:**
- **commands/help/help.d** - Comprehensive help system
- **commands/help/explain.d** - Detailed command explanations

## Usage

```d
import frontend.cli;

auto renderer = RendererFactory.create();
auto publisher = new SimpleEventPublisher();
publisher.subscribe(renderer);
publisher.publish(new BuildStartedEvent(...));
```

## Key Features

### Rendering System
- Event-driven architecture for responsive UI
- Lock-free progress updates
- Multi-stream output (stdout, stderr, logs)
- ANSI color and formatting support
- Terminal capability detection
- Clean and informative build output

### Command System
- Comprehensive help documentation for all commands
- Auto-detection and inference capabilities
- Build analytics and telemetry
- Project initialization with smart detection
- Modular command structure for easy extension

