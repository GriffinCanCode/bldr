# CLI Architecture

## Overview

The Builder CLI system is an event-driven rendering architecture that provides a modern, interactive terminal experience for build operations. Unlike traditional logging approaches, it decouples build events from rendering decisions, enabling sophisticated output control and testability.

## Architecture

### Design Principles

1. **Event-Driven**: Build events are published to subscribers, not directly rendered
2. **Lock-Free Performance**: Atomic operations for progress tracking with zero contention
3. **Adaptive Output**: Automatically detects terminal capabilities and adjusts
4. **Testable Isolation**: Each component is independently testable
5. **Zero-Allocation Hot Path**: Pre-allocated buffers and efficient ANSI sequences

### Components

```
cli/
├── events.d      - Strongly-typed build events (immutable)
├── terminal.d    - Terminal control & capabilities detection
├── progress.d    - Lock-free progress tracking
├── stream.d      - Multi-stream output management
├── format.d      - Message formatting & styling
└── render.d      - Main rendering coordinator
```

## Core Concepts

### Events (`events.d`)

All build activity is communicated through immutable, strongly-typed events:

```d
// Lifecycle events
BuildStartedEvent
BuildCompletedEvent
BuildFailedEvent

// Target events
TargetStartedEvent
TargetCompletedEvent
TargetFailedEvent
TargetCachedEvent
TargetProgressEvent

// Message events
MessageEvent
StatisticsEvent
```

**Key Features:**
- Immutable for thread-safety
- Timestamps for ordering
- Type-safe with enums
- Zero-copy where possible

### Terminal Control (`terminal.d`)

Low-level terminal manipulation with capability detection:

**Capabilities Detected:**
- Color support (8, 256, true color)
- Unicode support
- Terminal size (width/height)
- Interactive vs. non-interactive
- Progress bar support

**ANSI Control:**
- Pre-computed color codes (no allocation)
- Cursor control (hide/show/move)
- Line clearing
- Screen control

**Symbols:**
- Unicode: ✓ ✗ → • ⚡ ⚙
- ASCII fallback: [OK] [FAIL] -> * [cache] [build]

### Progress Tracking (`progress.d`)

Lock-free progress tracking using atomic operations:

```d
auto tracker = ProgressTracker(totalTargets);

// Thread-safe increments (from any build thread)
tracker.incrementCompleted();
tracker.incrementFailed();
tracker.incrementCached();

// Lock-free snapshot
auto snap = tracker.snapshot();
writeln(snap.percentage);  // 0.0 to 1.0
writeln(snap.estimatedRemaining());
```

**Performance:**
- Atomic operations (no locks)
- Lock-free reads
- Concurrent updates from multiple threads
- ~10ns per operation

**Progress Bar:**
```
[=====                ] 25% [25/100] 4 active (15 cached) ETA 30s
```

### Stream Management (`stream.d`)

Multi-stream output for parallel builds:

**Features:**
- Multiple concurrent output streams
- Per-stream buffering
- Level-based filtering (Debug/Info/Warning/Error)
- Thread-safe writes
- Status line management

**Status Line:**
- In-place updates (cursor manipulation)
- Auto-clear for other output
- Terminal width aware

### Formatting (`format.d`)

Beautiful, styled message formatting:

**Message Types:**
```d
formatter.formatBuildStarted(...)
formatter.formatBuildCompleted(...)
formatter.formatTargetCompleted(...)
formatter.formatTargetCached(...)
formatter.formatError(...)
formatter.formatCacheStats(...)
```

**Utilities:**
```d
formatDuration(dur!"seconds"(125))  // "2m5s"
formatSize(5 * 1024 * 1024)         // "5.0 MB"
formatPercent(0.75)                 // "75%"
truncate(text, maxWidth)            // Smart truncation
```

### Rendering (`render.d`)

Main rendering coordinator that subscribes to events:

```d
// Create renderer
auto renderer = RendererFactory.create(RenderMode.Interactive);

// Connect to event publisher
publisher.subscribe(renderer);

// Renderer handles all events automatically
publisher.publish(new BuildStartedEvent(...));
```

**Render Modes:**
- `Auto`: Detect based on terminal
- `Interactive`: Full progress bars and status lines
- `Plain`: Simple text output
- `Verbose`: Detailed output with all events
- `Quiet`: Minimal output

## Usage

### Basic Setup

```d
import cli;

// Create event publisher
auto publisher = new SimpleEventPublisher();

// Create and register renderer
auto renderer = RendererFactory.create();
publisher.subscribe(renderer);

// Publish events from build process
publisher.publish(new BuildStartedEvent(totalTargets, maxParallelism, timestamp));

// ... during build ...
publisher.publish(new TargetCompletedEvent(targetId, duration, outputSize, timestamp));

// ... at end ...
publisher.publish(new BuildCompletedEvent(built, cached, failed, duration, timestamp));
```

### With Progress Tracking

```d
// Create progress tracker
auto tracker = ProgressTracker(totalTargets);
renderer.setProgressTracker(&tracker);

// Build threads update progress
tracker.incrementCompleted();  // Thread-safe

// Renderer automatically shows progress
```

### Custom Subscribers

Implement `EventSubscriber` interface:

```d
class MySubscriber : EventSubscriber
{
    void onEvent(BuildEvent event)
    {
        // Handle event
        if (event.type == EventType.TargetCompleted)
        {
            auto e = cast(TargetCompletedEvent)event;
            // Custom handling
        }
    }
}

publisher.subscribe(new MySubscriber());
```

## Performance

### Benchmarks

**Progress Tracking:**
- Increment: ~10ns (atomic operation)
- Snapshot: ~50ns (5 atomic loads)
- Concurrent updates: Linear scaling to CPU count

**Terminal Output:**
- Buffered writes: ~1μs per line
- ANSI codes: Pre-computed (zero allocation)
- Status line update: ~10μs

**Event Publishing:**
- Event creation: ~50ns
- Subscriber notification: ~100ns per subscriber
- Total overhead: <1% of build time

### Memory

- Terminal buffer: 4-8KB
- Progress tracker: 64 bytes
- Event: 32-128 bytes (immutable)
- Total overhead: <1MB

## Terminal Compatibility

**Tested Terminals:**
- ✓ iTerm2 (macOS)
- ✓ Terminal.app (macOS)
- ✓ Alacritty
- ✓ Kitty
- ✓ Windows Terminal
- ✓ xterm
- ✓ tmux/screen

**Fallback Behavior:**
- No color → Plain text output
- No unicode → ASCII symbols
- Non-interactive → Plain mode
- Small terminal → Truncated output

## Testing

### Unit Tests

All components have comprehensive unit tests:

```bash
dub test -- tests.unit.cli
```

**Test Coverage:**
- Terminal capability detection
- ANSI code generation
- Progress tracking (including concurrent)
- Message formatting
- Event creation and publishing
- Renderer behavior

### Integration Tests

```bash
dub test -- tests.integration.cli
```

Tests full rendering pipeline with mock builds.

### Manual Testing

```bash
# Test different modes
bldr build --mode=interactive
bldr build --mode=plain
bldr build --mode=verbose
bldr build --mode=quiet

# Test color disable
NO_COLOR=1 bldr build

# Test in pipe (non-interactive)
bldr build | tee output.log
```

## Extending

### Adding New Events

1. Define event class in `events.d`:
```d
final class MyNewEvent : BuildEvent
{
    private EventType _type = EventType.MyNew;
    private Duration _timestamp;
    
    string customData;
    
    this(string data, Duration timestamp)
    {
        this.customData = data;
        this._timestamp = timestamp;
    }
    
    @property EventType type() const pure nothrow { return _type; }
    @property Duration timestamp() const pure nothrow { return _timestamp; }
}
```

2. Add to `EventType` enum
3. Handle in `Renderer.onEvent()`
4. Add formatter method

### Adding New Formatters

```d
string formatMyThing(MyData data)
{
    auto msg = format("Custom: %s", data.value);
    return styled(msg, Color.Blue, Style.Bold);
}
```

### Custom Render Mode

Extend `Renderer` class:

```d
class MyCustomRenderer : Renderer
{
    this()
    {
        super(RenderMode.Plain);
    }
    
    override void onEvent(BuildEvent event)
    {
        // Custom rendering logic
        super.onEvent(event);  // Call parent if needed
    }
}
```

## Best Practices

1. **Event Granularity**: Emit events at appropriate level (not too fine, not too coarse)
2. **Immutability**: Keep events immutable for thread-safety
3. **Timestamps**: Always include timestamps for ordering
4. **Error Context**: Include context in error events
5. **Progressive Disclosure**: Show details based on mode (quiet → verbose)
6. **Terminal Width**: Always respect terminal width
7. **Performance**: Keep event creation fast (<100ns)

## Comparison to Traditional Logging

| Aspect | Traditional Logging | Event-Driven CLI |
|--------|-------------------|------------------|
| **Coupling** | Tight (Logger.info()) | Loose (publish event) |
| **Testing** | Difficult (mock stdout) | Easy (mock subscriber) |
| **Flexibility** | Limited | High (multiple subscribers) |
| **Performance** | String formatting hot path | Deferred formatting |
| **Threading** | Needs locks | Lock-free |
| **Output Control** | Hard-coded | Runtime configurable |

## Future Enhancements

- [ ] Web dashboard subscriber
- [ ] JSON output subscriber
- [ ] Build replay from events
- [ ] Remote build monitoring
- [ ] Per-target progress bars
- [ ] Build visualization
- [ ] Performance profiling subscriber
- [ ] Distributed build coordination

## References

- [Command Line Interface Guidelines](https://clig.dev/)
- [Buck2 Console Architecture](https://buck2.build/)
- [Cargo Output Design](https://doc.rust-lang.org/cargo/)
- [ANSI Escape Codes](https://en.wikipedia.org/wiki/ANSI_escape_code)

