# Build Telemetry & Analytics

Builder includes a sophisticated telemetry system that collects, analyzes, and visualizes build performance data to help you optimize your build pipeline.

## Quick Start

### Enable Telemetry

Telemetry is **enabled by default**. To disable:

```bash
export BUILDER_TELEMETRY_ENABLED=0
```

### View Build Analytics

```bash
# Show comprehensive summary
bldr telemetry

# Show recent builds
bldr telemetry recent 10

# Export data
bldr telemetry export > telemetry.json
```

## Features

### 📊 **Comprehensive Metrics**

- **Build Performance**: Total time, targets/second, parallelism utilization
- **Cache Efficiency**: Hit rate, hits vs misses, trends over time
- **Target Analysis**: Individual target build times, bottleneck identification
- **Success Rates**: Build success/failure statistics
- **Trends**: Automatic detection of performance regressions

### 🎯 **Bottleneck Identification**

Builder automatically identifies the slowest targets in your build:

```
Top Bottlenecks:
  1. //backend:api-server (avg: 2.3s)
  2. //frontend:bundle (avg: 1.8s)
  3. //shared:proto (avg: 0.9s)
```

### 📈 **Regression Detection**

Automatically detects when builds are significantly slower than historical average:

```
⚠️  Performance Regressions Detected:
  • 2025-10-27T14:23:15: 2.1x slower than average (expected 1.2s, got 2.5s)
```

### 💾 **Efficient Storage**

- **Binary format**: 4-5x faster than JSON, 30% smaller
- **Automatic retention**: Configurable cleanup of old data
- **Thread-safe**: Safe for concurrent builds

## Configuration

Configure telemetry via environment variables:

```bash
# Enable/disable telemetry
export BUILDER_TELEMETRY_ENABLED=1

# Maximum number of sessions to keep
export BUILDER_TELEMETRY_MAX_SESSIONS=1000

# How long to keep telemetry data (days)
export BUILDER_TELEMETRY_RETENTION_DAYS=90
```

## Commands

### Summary

Display comprehensive analytics:

```bash
bldr telemetry
# or
bldr telemetry summary
```

**Output Example:**
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

View recent build history:

```bash
bldr telemetry recent [count]
```

**Output Example:**
```
Recent 5 Builds:

1. [✓] 2025-10-27T14:23:15 - 2341ms (cache: 78.3%)
   Top bottlenecks:
     • //backend:api-server: 1205ms
     • //frontend:bundle: 892ms
     • //shared:proto: 445ms

2. [✓] 2025-10-27T13:15:42 - 2189ms (cache: 81.2%)
   ...

3. [✗] 2025-10-27T12:45:23 - 1523ms (cache: 75.1%)
   Error: Compilation failed for //backend:api-server
```

### Export Data

Export telemetry in various formats:

```bash
# JSON (structured data)
bldr telemetry export > telemetry.json

# CSV (for spreadsheet analysis)
bldr telemetry export --format csv > telemetry.csv
```

**JSON Format:**
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

### Clear Data

Remove all telemetry data:

```bash
bldr telemetry clear
```

## Use Cases

### 1. **Optimize Build Performance**

Identify bottlenecks and focus optimization efforts:

```bash
bldr telemetry summary | grep "Bottlenecks"
```

### 2. **Monitor CI/CD Performance**

Track build performance over time in continuous integration:

```bash
# In CI pipeline
bldr build
bldr telemetry export > artifacts/telemetry-${BUILD_ID}.json

# Fail build on regression
if bldr telemetry summary | grep -q "Performance Regressions"; then
    echo "⚠️ Build regression detected!"
    exit 1
fi
```

### 3. **A/B Testing Build Configurations**

Compare different build configurations:

```bash
# Baseline
BUILDER_PARALLEL=4 bldr build
bldr telemetry recent 1 > baseline.txt

# Experiment
BUILDER_PARALLEL=8 bldr build
bldr telemetry recent 1 > experiment.txt

diff baseline.txt experiment.txt
```

### 4. **Team Analytics**

Export and aggregate telemetry across the team:

```bash
# Each developer exports their data
bldr telemetry export > ~/telemetry-$(whoami).json

# Aggregate in data warehouse
cat ~/telemetry-*.json | jq -s '.' | upload-to-analytics
```

### 5. **Build Time SLA Monitoring**

Alert when builds exceed SLA:

```bash
# Check if last build exceeded 5 minutes
LAST_BUILD_MS=$(bldr telemetry recent 1 | grep -oP '\d+(?=ms)' | head -1)
if [ "$LAST_BUILD_MS" -gt 300000 ]; then
    notify-slack "Build exceeded 5min SLA: ${LAST_BUILD_MS}ms"
fi
```

## Architecture

The telemetry system uses an event-driven architecture:

```
┌─────────────────┐
│  Build Executor │
└────────┬────────┘
         │
         │ publishes events
         ▼
┌─────────────────────┐
│  TelemetryCollector │ ◄── Subscribes to BuildEvents
└────────┬────────────┘
         │
         │ aggregates
         ▼
┌─────────────────────┐
│  TelemetryStorage   │ ◄── Binary persistence
└────────┬────────────┘
         │
         │ analyzes
         ▼
┌─────────────────────┐
│  TelemetryAnalyzer  │ ◄── Trends, regressions, insights
└────────┬────────────┘
         │
         │ exports
         ▼
┌─────────────────────┐
│  TelemetryExporter  │ ◄── JSON, CSV, summary formats
└─────────────────────┘
```

### Components

1. **TelemetryCollector**: Real-time event aggregation during builds
2. **TelemetryStorage**: Efficient binary persistence with retention policies
3. **TelemetryAnalyzer**: Statistical analysis, trend detection, regression identification
4. **TelemetryExporter**: Multi-format data export (JSON, CSV, human-readable)

## Performance Impact

Telemetry has minimal performance impact:

- **Collection Overhead**: < 0.1ms per event
- **Memory Overhead**: ~500 bytes per target
- **Total Build Impact**: < 0.5% of total build time

For performance-critical builds, you can disable telemetry:

```bash
BUILDER_TELEMETRY_ENABLED=0 bldr build
```

## Data Privacy

- **Local Storage**: All data stored locally in `.builder-cache/telemetry/`
- **No Cloud Upload**: No automatic transmission to external services
- **No PII**: Only build metadata, no source code or secrets
- **Full Control**: Complete ownership and control over your data

## Integration with Tools

### Grafana Dashboard

```bash
# Export to Prometheus format
bldr telemetry export | jq '.sessions[] | 
  "builder_duration_ms \(.durationMs) \(.startTime)\n
   builder_cache_hit_rate \(.cacheHitRate) \(.startTime)\n
   builder_targets_per_second \(.targetsPerSecond) \(.startTime)"'
```

### Custom Analytics

```d
import core.telemetry;

// Load telemetry data
auto storage = new TelemetryStorage();
auto sessionsResult = storage.getSessions();

if (sessionsResult.isOk)
{
    auto sessions = sessionsResult.unwrap();
    auto analyzer = TelemetryAnalyzer(sessions);
    
    // Custom analysis
    auto reportResult = analyzer.analyze();
    if (reportResult.isOk)
    {
        auto report = reportResult.unwrap();
        // Process report data...
    }
}
```

## Troubleshooting

### Telemetry Not Collecting

**Problem**: No telemetry data appears after builds.

**Solution**:
```bash
# Check if enabled
echo $BUILDER_TELEMETRY_ENABLED

# Enable explicitly
export BUILDER_TELEMETRY_ENABLED=1
bldr build
```

### Storage Issues

**Problem**: Errors reading/writing telemetry.

**Solution**:
```bash
# Check permissions
ls -la .builder-cache/telemetry/

# Clear corrupted data
bldr telemetry clear
```

### Disk Space

**Problem**: Telemetry taking too much space.

**Solution**:
```bash
# Reduce retention period
export BUILDER_TELEMETRY_RETENTION_DAYS=30

# Reduce max sessions
export BUILDER_TELEMETRY_MAX_SESSIONS=500

# Clear old data
bldr telemetry clear
```

## Best Practices

### 1. **Regular Monitoring**

Set up daily/weekly reviews of telemetry:

```bash
# Add to cron
0 9 * * 1 bldr telemetry summary | mail -s "Weekly Build Report" team@example.com
```

### 2. **Baseline Establishment**

Establish performance baselines:

```bash
# After optimizations
bldr telemetry summary > baseline-2025-10.txt
```

### 3. **Regression Prevention**

Add telemetry checks to CI/CD:

```yaml
# .github/workflows/build.yml
- name: Build and check performance
  run: |
    bldr build
    bldr telemetry summary
    # Fail if regression detected
    ! bldr telemetry summary | grep -q "Performance Regressions"
```

### 4. **Data Export for Analysis**

Regularly export data for long-term analysis:

```bash
# Monthly export
bldr telemetry export > telemetry-$(date +%Y-%m).json
```

## See Also

- [PERFORMANCE.md](PERFORMANCE.md) - Performance optimization guide
- [CLI.md](CLI.md) - Command-line interface reference
- [CACHING.md](CONCURRENCY.md) - Build caching strategies
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture

