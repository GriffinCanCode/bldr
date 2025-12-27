module frontend.cli.commands.extensions.telemetry;

import std.stdio;
import std.conv : to;
import std.algorithm : min;
import infrastructure.telemetry;
import infrastructure.utils.logging;
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
                structuredLog.error("unknown_telemetry_subcommand_").field("detail", "Unknown telemetry subcommand: " ~ subcommand).emit();
                printUsage();
        }
    }
    
    private static void showSummary(TelemetryStorage storage)
    {
        auto sessionsResult = storage.getSessions();
        if (sessionsResult.isErr)
        {
            structuredLog.error("failed_to_load_telemetry_data_").field("detail", "Failed to load telemetry data: " ~ sessionsResult.unwrapErr().toString()).emit();
            return;
        }
        
        auto sessions = sessionsResult.unwrap();
        if (sessions.length == 0)
        {
            structuredLog.info("no_telemetry_data_available_yet_run_a_bu").emit();
            return;
        }
        
        auto analyzer = TelemetryAnalyzer(sessions);
        auto reportResult = analyzer.analyze();
        
        if (reportResult.isErr)
        {
            structuredLog.error("failed_to_analyze_telemetry").emit();
            structuredLog.error("log_event").field("message", reportResult.unwrapErr().message).emit();
            return;
        }
        
        auto report = reportResult.unwrap();
        auto summaryResult = TelemetryExporter.toSummary(report);
        
        if (summaryResult.isErr)
        {
            structuredLog.error("failed_to_generate_summary").emit();
            structuredLog.error("log_event").field("message", summaryResult.unwrapErr().message).emit();
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
            structuredLog.error("failed_to_load_recent_builds").emit();
            structuredLog.error("log_event").field("message", recentResult.unwrapErr().message).emit();
            return;
        }
        
        auto sessions = recentResult.unwrap();
        if (sessions.length == 0)
        {
            structuredLog.info("no_telemetry_data_available_yet_run_a_bu").emit();
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
            structuredLog.error("failed_to_load_telemetry_data_").field("detail", "Failed to load telemetry data: " ~ sessionsResult.unwrapErr().toString()).emit();
            return;
        }
        
        auto sessions = sessionsResult.unwrap();
        if (sessions.length == 0)
        {
            structuredLog.info("no_telemetry_data_to_export").emit();
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
                structuredLog.error("failed_to_export_json").emit();
                structuredLog.error("log_event").field("message", jsonResult.unwrapErr().message).emit();
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
                structuredLog.error("failed_to_export_csv").emit();
                structuredLog.error("log_event").field("message", csvResult.unwrapErr().message).emit();
            }
        }
        else
        {
            structuredLog.error("unknown_export_format_").field("detail", "Unknown export format: " ~ format).emit();
        }
    }
    
    private static void clearData(TelemetryStorage storage)
    {
        structuredLog.info("clearing_telemetry_data").emit();
        
        auto result = storage.clear();
        if (result.isErr)
        {
            structuredLog.error("failed_to_clear_telemetry").emit();
            structuredLog.error("log_event").field("message", result.unwrapErr().message).emit();
            return;
        }
        
        structuredLog.info("telemetry_data_cleared_successfully").emit();
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

