# Build Telemetry

## Overview

Builder includes a telemetry system that collects build performance data for analysis and optimization.

**Module**: `infrastructure.telemetry`

## Quick Start

### Enable/Disable Telemetry

Telemetry is enabled by default. To disable:

```bash
export BUILDER_TELEMETRY_ENABLED=0
```

### View Analytics

```bash
# Show summary
bldr telemetry

# Show recent builds
bldr telemetry recent 10

# Export data as JSON
bldr telemetry export > telemetry.json

# Clear data
bldr telemetry clear
```

## Features

### Metrics Collected

- **Build Performance**: Total time, targets/second, parallelism utilization
- **Cache Efficiency**: Hit rate, cache hits vs misses
- **Target Analysis**: Individual target build times
- **Success Rates**: Build success/failure statistics

### Bottleneck Identification

Builder identifies the slowest targets in your build:

```
Top Bottlenecks:
  1. //backend:api-server (avg: 2.3s)
  2. //frontend:bundle (avg: 1.8s)
  3. //shared:proto (avg: 0.9s)
```

### Regression Detection

Automatic detection of builds significantly slower than historical average:

```
⚠️  Performance Regressions Detected:
  • 2025-10-27T14:23:15: 2.1x slower than average (expected 1200ms, got 2500ms)
```

## Commands

### Summary

```bash
bldr telemetry
# or
bldr telemetry summary
```

Example output:

```
=== Build Telemetry Summary ===

Total Builds: 147
Successful: 142 (96.6%)
Failed: 5

Performance Metrics:
  Average Build Time: 2341 ms
  Fastest Build: 1205 ms
  Slowest Build: 8934 ms

Cache Efficiency:
  Average Hit Rate: 78.3%
  Trend: Increasing

Parallelism:
  Average Utilization: 82.1%
  Targets/Second: 12.45

Top Bottlenecks:
  1. //backend:api-server
  2. //frontend:bundle
  3. //shared:proto

Build Time Trend: Stable
```

### Recent Builds

```bash
bldr telemetry recent [count]
```

Example output:

```
Recent 5 Builds:

1. [✓] 2025-10-27T14:23:15 - 2341ms (cache: 78.3%)
   Top bottlenecks:
     • //backend:api-server: 1205ms
     • //frontend:bundle: 892ms
     • //shared:proto: 445ms

2. [✗] 2025-10-27T12:45:23 - 1523ms (cache: 75.1%)
   Error: Compilation failed for //backend:api-server
```

### Export

```bash
bldr telemetry export > telemetry.json
```

JSON format:

```json
{
  "sessions": [
    {
      "startTime": "2025-10-27T14:23:15",
      "durationMs": 2341,
      "totalTargets": 25,
      "built": 18,
      "cached": 7,
      "failed": 0,
      "cacheHitRate": 78.30,
      "parallelismUtilization": 82.10,
      "targetsPerSecond": 12.45,
      "succeeded": true
    }
  ]
}
```

### Clear

```bash
bldr telemetry clear
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILDER_TELEMETRY_ENABLED` | `1` | Enable/disable telemetry (`0` or `1`) |
| `BUILDER_TELEMETRY_MAX_SESSIONS` | `100` | Maximum sessions to keep |
| `BUILDER_TELEMETRY_MAX_AGE_DAYS` | `30` | Maximum age of sessions in days |
| `BUILDER_TELEMETRY_AUTO_CLEANUP` | `1` | Auto-cleanup old sessions |

## Architecture

```
┌─────────────────┐
│  Build Executor │
└────────┬────────┘
         │ publishes events
         ▼
┌─────────────────────┐
│  TelemetryCollector │ ← Subscribes to BuildEvents
└────────┬────────────┘
         │ aggregates
         ▼
┌─────────────────────┐
│  TelemetryStorage   │ ← Binary persistence
└────────┬────────────┘
         │ analyzes
         ▼
┌─────────────────────┐
│  TelemetryAnalyzer  │ ← Trends, regressions
└────────┬────────────┘
         │ exports
         ▼
┌─────────────────────┐
│  TelemetryExporter  │ ← JSON, CSV, summary
└─────────────────────┘
```

### Components

Located in `source/infrastructure/telemetry/`:

| Submodule | Purpose |
|-----------|---------|
| `collection/` | `TelemetryCollector`, `BuildSession`, `BuildEnvironment` |
| `persistence/` | `TelemetryStorage`, `TelemetryConfig` |
| `analytics/` | `TelemetryAnalyzer`, `AnalyticsReport`, regression detection |
| `export/` | `TelemetryExporter` (JSON, CSV, summary) |

## Programmatic Usage

```d
import infrastructure.telemetry;

// Load telemetry data
auto storage = new TelemetryStorage();
auto sessionsResult = storage.getSessions();

if (sessionsResult.isOk)
{
    auto sessions = sessionsResult.unwrap();
    auto analyzer = TelemetryAnalyzer(sessions);
    
    auto reportResult = analyzer.analyze();
    if (reportResult.isOk)
    {
        auto report = reportResult.unwrap();
        auto summaryResult = TelemetryExporter.toSummary(report);
        if (summaryResult.isOk)
            writeln(summaryResult.unwrap());
    }
}
```

## Data Storage

- **Location**: `.builder-cache/telemetry/telemetry.bin`
- **Format**: Binary (serialized via `Codec`)
- **Privacy**: All data stored locally, no cloud upload

## Use Cases

### CI/CD Integration

```bash
# In CI pipeline
bldr build
bldr telemetry export > artifacts/telemetry-${BUILD_ID}.json

# Check for regressions
if bldr telemetry summary | grep -q "Performance Regressions"; then
    echo "Build regression detected"
    exit 1
fi
```

### Monitoring Build Time SLA

```bash
LAST_BUILD_MS=$(bldr telemetry recent 1 | grep -oP '\d+(?=ms)' | head -1)
if [ "$LAST_BUILD_MS" -gt 300000 ]; then
    notify-slack "Build exceeded 5min SLA: ${LAST_BUILD_MS}ms"
fi
```

## Troubleshooting

### No Data Appearing

```bash
# Check if enabled
echo $BUILDER_TELEMETRY_ENABLED

# Enable explicitly
export BUILDER_TELEMETRY_ENABLED=1
bldr build
```

### Storage Issues

```bash
# Check permissions
ls -la .builder-cache/telemetry/

# Clear corrupted data
bldr telemetry clear
```

### Disk Space

```bash
# Reduce retention
export BUILDER_TELEMETRY_MAX_SESSIONS=50
export BUILDER_TELEMETRY_MAX_AGE_DAYS=14

# Clear old data
bldr telemetry clear
```

## See Also

- [Performance](./performance.md) - Performance optimization guide
- [CLI](../user-guides/CLI.md) - Command-line reference
- [Caching](./caching.md) - Build caching strategies
