# CLI Reference

## Overview

The Builder CLI uses an event-driven rendering architecture for build output. Build events are decoupled from rendering, enabling configurable output modes and clean testability.

## Architecture

### Components

```
frontend/cli/
├── events/events.d      - Build event types (immutable, timestamped)
├── control/terminal.d   - Terminal capabilities & ANSI control
├── output/progress.d    - Lock-free progress tracking (atomics)
├── output/stream.d      - Multi-stream output management
├── display/format.d     - Message formatting & styling
├── display/render.d     - Rendering coordinator
└── input/               - Interactive prompts
```

### Design Principles

1. **Event-Driven** - Build events published to subscribers, not directly rendered
2. **Lock-Free Progress** - Atomic operations for concurrent progress tracking
3. **Adaptive Output** - Detects terminal capabilities and adjusts
4. **Testable** - Each component independently testable via interfaces

## Events

All build activity communicates through immutable event types:

```d
// Lifecycle
BuildStartedEvent     // totalTargets, maxParallelism, timestamp
BuildCompletedEvent   // built, cached, failed, duration, timestamp
BuildFailedEvent      // reason, failedCount, duration, timestamp

// Targets
TargetStartedEvent    // targetId, index, total, timestamp
TargetCompletedEvent  // targetId, duration, outputSize, timestamp
TargetFailedEvent     // targetId, error, duration, timestamp
TargetCachedEvent     // targetId, timestamp
TargetProgressEvent   // targetId, phase, progress (0.0-1.0), timestamp

// Messages
MessageEvent          // message, severity, targetId, timestamp
StatisticsEvent       // cacheStats, buildStats, timestamp
```

Events implement the `BuildEvent` interface with `type` and `timestamp` properties.

## Terminal Control

The `terminal.d` module handles capability detection and ANSI output.

**Detected Capabilities:**
- Color support (8-color, 256-color, true color)
- Unicode support (via `LANG` environment)
- Terminal dimensions (width/height via ioctl or env vars)
- Interactive mode (TTY detection)
- Progress bar support

**Symbols:**
- Unicode mode: ✓ ✗ → • ⚡ ⚙
- ASCII fallback: [OK] [FAIL] -> * [cache] [build]

## Progress Tracking

Lock-free progress via atomic operations in `progress.d`:

```d
auto tracker = ProgressTracker(totalTargets);

// Thread-safe updates (any thread)
tracker.incrementCompleted();
tracker.incrementFailed();
tracker.incrementCached();
tracker.setActive(count);

// Lock-free snapshot
auto snap = tracker.snapshot();
snap.percentage;           // 0.0 to 1.0
snap.estimatedRemaining(); // Duration
snap.targetsPerSecond;     // throughput
```

**Progress Bar Format:**
```
[25/100] 4 active (15 cached) ETA 30s [=====                ]  25%
```

## Stream Management

`stream.d` provides multi-stream output with filtering:

**Stream Levels:**
- `Debug` - Detailed debugging info
- `Info` - Standard messages
- `Warning` - Non-fatal issues
- `Error` - Failures

**Features:**
- Per-stream buffering
- Level-based filtering
- Thread-safe writes (mutex-protected)
- Status line with in-place updates

## Formatting

The `format.d` module provides styled output:

```d
auto formatter = Formatter(caps);

formatter.formatBuildStarted(totalTargets, parallelism);
formatter.formatBuildCompleted(built, cached, duration);
formatter.formatTargetCompleted(targetId, duration);
formatter.formatTargetCached(targetId);
formatter.formatError(message);
formatter.formatCacheStats(stats);
```

**Utilities:**
```d
formatDuration(dur!"seconds"(125));  // "2m5s"
formatSize(5 * 1024 * 1024);         // "5.0 MB"
formatPercent(0.75);                 // " 75%"
truncate(text, maxWidth);            // Smart truncation with "..."
```

## Rendering

The `Renderer` class coordinates output by subscribing to events:

```d
auto publisher = new SimpleEventPublisher();
auto renderer = RendererFactory.create(RenderMode.Interactive);
publisher.subscribe(renderer);

// Events automatically rendered
publisher.publish(new BuildStartedEvent(totalTargets, parallelism, timestamp));
publisher.publish(new TargetCompletedEvent(targetId, duration, size, timestamp));
publisher.publish(new BuildCompletedEvent(built, cached, failed, duration, timestamp));
```

**Render Modes:**

| Mode | Description |
|------|-------------|
| `Auto` | Detect based on terminal (default) |
| `Interactive` | Progress bars and status lines |
| `Plain` | Simple text output |
| `Verbose` | All events including starts/caches |
| `Quiet` | Errors only |

## Usage

### CLI Flags

```bash
bldr build --mode=interactive  # Full progress display
bldr build --mode=plain        # Simple output
bldr build --mode=verbose      # Show all events
bldr build --mode=quiet        # Minimal output
```

### Environment Variables

```bash
NO_COLOR=1 bldr build          # Disable color
COLUMNS=120 bldr build         # Override terminal width
```

### Pipe Detection

When output is piped, Builder automatically switches to plain mode:

```bash
bldr build | tee output.log    # Uses plain mode
```

## Testing

```bash
# Run CLI unit tests
dub test -- tests.unit.cli

# Specific component tests
dub test -- tests.unit.cli.terminal
dub test -- tests.unit.cli.progress
dub test -- tests.unit.cli.format
dub test -- tests.unit.cli.events
```

## Custom Subscribers

Implement `EventSubscriber` to handle events:

```d
class JsonLogger : EventSubscriber
{
    void onEvent(BuildEvent event)
    {
        if (event.type == EventType.TargetCompleted)
        {
            auto e = cast(TargetCompletedEvent)event;
            writeln(`{"target":"`, e.targetId, `","duration":`, e.duration.total!"msecs", `}`);
        }
    }
}

publisher.subscribe(new JsonLogger());
```

## Terminal Compatibility

Tested on:
- iTerm2, Terminal.app (macOS)
- Alacritty, Kitty
- Windows Terminal
- xterm, tmux, screen

**Fallback behavior:**
- No color → Plain text
- No unicode → ASCII symbols
- Non-interactive → Plain mode
- Small terminal → Truncated output
