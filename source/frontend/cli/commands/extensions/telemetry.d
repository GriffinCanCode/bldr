module frontend.cli.commands.extensions.telemetry;

import std.stdio;
import std.conv : to;
import std.algorithm : min;
import infrastructure.telemetry;
import infrastructure.utils.logging.logger;
import infrastructure.errors.formatting.format : formatError = format;

/// Telemetry command - display build analytics and insights
struct TelemetryCommand
{
    /// Execute the telemetry command
    static void execute(string subcommand = "summary", size_t count = 10)
    {
        auto config = TelemetryConfig.fromEnvironment();
        auto storage = new TelemetryStorage(".builder-cache/telemetry", config);
        
        switch (subcommand)
        {
            case "summary":
                showSummary(storage);
                break;
            case "recent":
                showRecent(storage, count);
                break;
            case "export":
                exportData(storage, "json");
                break;
            case "clear":
                clearData(storage);
                break;
            default:
                Logger.error("Unknown telemetry subcommand: " ~ subcommand);
                printUsage();
        }
    }
    
    private static void showSummary(TelemetryStorage storage)
    {
        auto sessionsResult = storage.getSessions();
        if (sessionsResult.isErr)
        {
            Logger.error("Failed to load telemetry data: " ~ sessionsResult.unwrapErr().toString());
            return;
        }
        
        auto sessions = sessionsResult.unwrap();
        if (sessions.length == 0)
        {
            Logger.info("No telemetry data available yet. Run a build first!");
            return;
        }
        
        auto analyzer = TelemetryAnalyzer(sessions);
        auto reportResult = analyzer.analyze();
        
        if (reportResult.isErr)
        {
            Logger.error("Failed to analyze telemetry");
            Logger.error(reportResult.unwrapErr().message);
            return;
        }
        
        auto report = reportResult.unwrap();
        auto summaryResult = TelemetryExporter.toSummary(report);
        
        if (summaryResult.isErr)
        {
            Logger.error("Failed to generate summary");
            Logger.error(summaryResult.unwrapErr().message);
            return;
        }
        
        writeln(summaryResult.unwrap());
        
        // Check for regressions
        auto regressionsResult = analyzer.detectRegressions(1.5);
        if (regressionsResult.isOk)
        {
            auto regressions = regressionsResult.unwrap();
            if (regressions.length > 0)
            {
                writeln("⚠️  Performance Regressions Detected:");
                foreach (reg; regressions)
                {
                    writeln(format("  • %s: %.1fx slower than average (expected %dms, got %dms)",
                        reg.sessionTime.toSimpleString(),
                        reg.slowdownRatio,
                        reg.expectedDuration.total!"msecs",
                        reg.actualDuration.total!"msecs"));
                }
                writeln();
            }
        }
    }
    
    private static void showRecent(TelemetryStorage storage, size_t count)
    {
        auto recentResult = storage.getRecent(count);
        if (recentResult.isErr)
        {
            Logger.error("Failed to load recent builds");
            Logger.error(recentResult.unwrapErr().message);
            return;
        }
        
        auto sessions = recentResult.unwrap();
        if (sessions.length == 0)
        {
            Logger.info("No telemetry data available yet. Run a build first!");
            return;
        }
        
        writeln(format("Recent %d Builds:\n", sessions.length));
        
        foreach (i, ref session; sessions)
        {
            immutable status = session.succeeded ? "✓" : "✗";
            immutable duration = session.totalDuration.total!"msecs";
            immutable cacheRate = session.cacheHitRate;
            
            writeln(format("%d. [%s] %s - %dms (cache: %.1f%%)",
                i + 1,
                status,
                session.startTime.toISOExtString()[0..19],
                duration,
                cacheRate));
            
            if (session.targets.length > 0)
            {
                auto slowest = session.slowest(3);
                writeln("   Top bottlenecks:");
                foreach (target; slowest)
                {
                    writeln(format("     • %s: %dms",
                        target.targetId,
                        target.duration.total!"msecs"));
                }
            }
            
            if (!session.succeeded)
            {
                writeln(format("   Error: %s", session.failureReason));
            }
            
            writeln();
        }
    }
    
    private static void exportData(TelemetryStorage storage, string format)
    {
        auto sessionsResult = storage.getSessions();
        if (sessionsResult.isErr)
        {
            Logger.error("Failed to load telemetry data: " ~ sessionsResult.unwrapErr().toString());
            return;
        }
        
        auto sessions = sessionsResult.unwrap();
        if (sessions.length == 0)
        {
            Logger.info("No telemetry data to export");
            return;
        }
        
        if (format == "json")
        {
            auto jsonResult = TelemetryExporter.toJson(sessions);
            if (jsonResult.isOk)
            {
                writeln(jsonResult.unwrap());
            }
            else
            {
                Logger.error("Failed to export JSON");
                Logger.error(jsonResult.unwrapErr().message);
            }
        }
        else if (format == "csv")
        {
            auto csvResult = TelemetryExporter.toCsv(sessions);
            if (csvResult.isOk)
            {
                writeln(csvResult.unwrap());
            }
            else
            {
                Logger.error("Failed to export CSV");
                Logger.error(csvResult.unwrapErr().message);
            }
        }
        else
        {
            Logger.error("Unknown export format: " ~ format);
        }
    }
    
    private static void clearData(TelemetryStorage storage)
    {
        Logger.info("Clearing telemetry data...");
        
        auto result = storage.clear();
        if (result.isErr)
        {
            Logger.error("Failed to clear telemetry");
            Logger.error(result.unwrapErr().message);
            return;
        }
        
        Logger.success("Telemetry data cleared successfully!");
    }
    
    private static void printUsage()
    {
        writeln("Usage: bldr telemetry <subcommand> [options]\n");
        writeln("Subcommands:");
        writeln("  summary       Show comprehensive analytics (default)");
        writeln("  recent [n]    Show recent n builds (default: 10)");
        writeln("  export        Export telemetry data as JSON");
        writeln("  clear         Clear all telemetry data");
    }
}

private string format(Args...)(string fmt, Args args)
{
    import std.format : format;
    return format(fmt, args);
}

