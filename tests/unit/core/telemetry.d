module tests.unit.core.telemetry;

import std.stdio;
import std.datetime : Clock, dur;
import std.algorithm : all, canFind;
import std.string : indexOf;
import infrastructure.telemetry;
import frontend.cli.events.events;
import infrastructure.errors;

/// Test TelemetryCollector event handling
unittest
{
    writeln("Testing TelemetryCollector...");
    
    auto collector = new TelemetryCollector();
    immutable timestamp = dur!"msecs"(0);
    
    // Test initial state - no active session
    auto sessionResult = collector.getSession();
    assert(sessionResult.isErr, "Should have no active session initially");
    
    // Simulate build started event
    auto startEvent = new BuildStartedEvent(10, 4, timestamp);
    collector.onEvent(startEvent);
    
    // Now should have active session
    sessionResult = collector.getSession();
    assert(sessionResult.isOk, "Should have active session after BuildStarted");
    
    auto session = sessionResult.unwrap();
    assert(session.totalTargets == 10);
    assert(session.maxParallelism == 4);
    
    // Simulate target events
    auto targetStarted = new TargetStartedEvent("//app:main", 1, 10, timestamp);
    collector.onEvent(targetStarted);
    
    auto targetCompleted = new TargetCompletedEvent("//app:main", dur!"msecs"(100), 1024, timestamp);
    collector.onEvent(targetCompleted);
    
    sessionResult = collector.getSession();
    assert(sessionResult.isOk);
    session = sessionResult.unwrap();
    assert(session.targets.length == 1);
    assert("//app:main" in session.targets);
    
    auto targetMetric = session.targets["//app:main"];
    assert(targetMetric.duration == dur!"msecs"(100));
    assert(targetMetric.outputSize == 1024);
    assert(targetMetric.status == TargetStatus.Completed);
    
    // Simulate build completed
    auto completedEvent = new BuildCompletedEvent(8, 2, 0, dur!"msecs"(500), timestamp);
    collector.onEvent(completedEvent);
    
    sessionResult = collector.getSession();
    assert(sessionResult.isOk);
    session = sessionResult.unwrap();
    assert(session.built == 8);
    assert(session.cached == 2);
    assert(session.failed == 0);
    assert(session.succeeded);
    assert(session.totalDuration == dur!"msecs"(500));
    
    writeln("  ✓ TelemetryCollector tests passed");
}

/// Test TelemetryStorage persistence
unittest
{
    writeln("Testing TelemetryStorage...");
    
    import std.file : exists, remove;
    
    immutable testDir = ".test-telemetry";
    immutable testFile = testDir ~ "/telemetry.bin";
    
    // Clean up from previous runs
    if (exists(testFile))
        remove(testFile);
    
    auto config = TelemetryConfig();
    config.maxSessions = 100;
    config.retentionDays = 30;
    
    auto storage = new TelemetryStorage(testDir, config);
    
    // Create test session
    BuildSession session;
    session.startTime = Clock.currTime();
    session.endTime = Clock.currTime();
    session.totalDuration = dur!"msecs"(1500);
    session.totalTargets = 5;
    session.built = 4;
    session.cached = 1;
    session.failed = 0;
    session.succeeded = true;
    session.cacheHitRate = 75.0;
    
    // Append session
    auto appendResult = storage.append(session);
    assert(appendResult.isOk, "Should successfully append session");
    
    // Retrieve sessions
    auto sessionsResult = storage.getSessions();
    assert(sessionsResult.isOk);
    auto sessions = sessionsResult.unwrap();
    assert(sessions.length == 1);
    assert(sessions[0].totalTargets == 5);
    assert(sessions[0].built == 4);
    assert(sessions[0].cached == 1);
    
    // Test recent retrieval
    auto recentResult = storage.getRecent(10);
    assert(recentResult.isOk);
    assert(recentResult.unwrap().length == 1);
    
    // Add more sessions
    foreach (i; 0 .. 5)
    {
        BuildSession s = session;
        s.totalDuration = dur!"msecs"(1000 + i * 100);
        storage.append(s);
    }
    
    recentResult = storage.getRecent(3);
    assert(recentResult.isOk);
    assert(recentResult.unwrap().length == 3, "Should return 3 most recent");
    
    // Test clear
    auto clearResult = storage.clear();
    assert(clearResult.isOk);
    
    sessionsResult = storage.getSessions();
    assert(sessionsResult.isOk);
    assert(sessionsResult.unwrap().length == 0, "Should be empty after clear");
    
    // Clean up
    if (exists(testFile))
        remove(testFile);
    
    writeln("  ✓ TelemetryStorage tests passed");
}

/// Test TelemetryAnalyzer analytics
unittest
{
    writeln("Testing TelemetryAnalyzer...");
    
    // Create test sessions
    BuildSession[] sessions;
    
    foreach (i; 0 .. 20)
    {
        BuildSession session;
        session.startTime = Clock.currTime();
        session.endTime = Clock.currTime();
        session.totalDuration = dur!"msecs"(1000 + i * 50);
        session.totalTargets = 10;
        session.built = 8;
        session.cached = 2;
        session.failed = (i % 10 == 0) ? 1 : 0;  // 10% failure rate
        session.succeeded = session.failed == 0;
        session.cacheHitRate = 70.0 + i * 1.0;
        session.maxParallelism = 4;
        
        // Add target metrics
        TargetMetric metric;
        metric.targetId = "//app:main";
        metric.duration = dur!"msecs"(500 + i * 20);
        metric.status = TargetStatus.Completed;
        session.targets["//app:main"] = metric;
        
        sessions ~= session;
    }
    
    auto analyzer = TelemetryAnalyzer(sessions);
    
    // Test analytics report
    auto reportResult = analyzer.analyze();
    assert(reportResult.isOk, "Analysis should succeed");
    
    auto report = reportResult.unwrap();
    assert(report.totalBuilds == 20);
    assert(report.successfulBuilds == 18, "Should have 18 successful builds");
    assert(report.failedBuilds == 2);
    assert(report.successRate > 0.0 && report.successRate <= 100.0);
    
    // Check that fastest < average < slowest
    assert(report.fastestBuild < report.avgBuildTime);
    assert(report.avgBuildTime < report.slowestBuild);
    
    // Test target-specific analytics
    auto targetResult = analyzer.analyzeTarget("//app:main");
    assert(targetResult.isOk);
    
    auto targetAnalytics = targetResult.unwrap();
    assert(targetAnalytics.totalBuilds == 20);
    assert(targetAnalytics.successCount > 0);
    assert(targetAnalytics.avgDuration.total!"msecs" > 0);
    assert(targetAnalytics.minDuration < targetAnalytics.avgDuration);
    assert(targetAnalytics.avgDuration < targetAnalytics.maxDuration);
    
    // Test regression detection
    auto regressionsResult = analyzer.detectRegressions(1.5);
    assert(regressionsResult.isOk, "Regression detection should succeed");
    // Note: May or may not find regressions depending on data
    
    writeln("  ✓ TelemetryAnalyzer tests passed");
}

/// Test TelemetryExporter formats
unittest
{
    writeln("Testing TelemetryExporter...");
    
    // Create test session
    BuildSession session;
    session.startTime = Clock.currTime();
    session.endTime = Clock.currTime();
    session.totalDuration = dur!"msecs"(1500);
    session.totalTargets = 5;
    session.built = 4;
    session.cached = 1;
    session.failed = 0;
    session.succeeded = true;
    session.cacheHitRate = 75.0;
    session.targetsPerSecond = 3.33;
    
    BuildSession[] sessions = [session];
    
    // Test JSON export
    auto jsonResult = TelemetryExporter.toJson(sessions);
    assert(jsonResult.isOk, "JSON export should succeed");
    
    auto json = jsonResult.unwrap();
    assert(json.length > 0);
    assert(json.indexOf("sessions") > 0, "Should contain 'sessions' field");
    assert(json.indexOf("totalTargets") > 0);
    
    // Test CSV export
    auto csvResult = TelemetryExporter.toCsv(sessions);
    assert(csvResult.isOk, "CSV export should succeed");
    
    auto csv = csvResult.unwrap();
    assert(csv.length > 0);
    assert(csv.indexOf("StartTime") >= 0, "Should have CSV header");
    assert(csv.indexOf("Duration") >= 0);
    
    // Test summary export with report
    auto analyzer = TelemetryAnalyzer(sessions);
    auto reportResult = analyzer.analyze();
    assert(reportResult.isOk);
    
    auto report = reportResult.unwrap();
    auto summaryResult = TelemetryExporter.toSummary(report);
    assert(summaryResult.isOk, "Summary export should succeed");
    
    auto summary = summaryResult.unwrap();
    assert(summary.length > 0);
    assert(summary.indexOf("Build Telemetry Summary") >= 0);
    assert(summary.indexOf("Total Builds") >= 0);
    
    writeln("  ✓ TelemetryExporter tests passed");
}

/// Test BuildSession computed properties
unittest
{
    writeln("Testing BuildSession computed properties...");
    
    BuildSession session;
    session.totalDuration = dur!"msecs"(1000);
    session.maxParallelism = 4;
    
    // Add target metrics
    TargetMetric m1;
    m1.targetId = "target1";
    m1.duration = dur!"msecs"(500);
    session.targets["target1"] = m1;
    
    TargetMetric m2;
    m2.targetId = "target2";
    m2.duration = dur!"msecs"(300);
    session.targets["target2"] = m2;
    
    TargetMetric m3;
    m3.targetId = "target3";
    m3.duration = dur!"msecs"(200);
    session.targets["target3"] = m3;
    
    // Test parallelism utilization
    auto utilization = session.parallelismUtilization;
    assert(utilization >= 0.0 && utilization <= 100.0);
    
    // Test slowest targets
    auto slowest = session.slowest(2);
    assert(slowest.length == 2);
    assert(slowest[0].targetId == "target1", "First should be slowest");
    assert(slowest[1].targetId == "target2");
    
    // Test average target time
    auto avgTime = session.averageTargetTime;
    assert(avgTime == dur!"msecs"((500 + 300 + 200) / 3));
    
    writeln("  ✓ BuildSession computed properties tests passed");
}

/// Test TelemetryConfig environment loading
unittest
{
    writeln("Testing TelemetryConfig...");
    
    auto config = TelemetryConfig();
    assert(config.maxSessions == 1000, "Default max sessions");
    assert(config.retentionDays == 90, "Default retention days");
    assert(config.enabled == true, "Default enabled");
    
    // Test environment loading (values should come from environment)
    auto envConfig = TelemetryConfig.fromEnvironment();
    assert(envConfig.maxSessions > 0);
    assert(envConfig.retentionDays > 0);
    
    writeln("  ✓ TelemetryConfig tests passed");
}

/// Test error handling
unittest
{
    writeln("Testing telemetry error handling...");
    
    // Test TelemetryError creation
    auto err1 = TelemetryError.noActiveSession();
    assert(err1.message.length > 0);
    assert(err1.code == ErrorCode.TelemetryNoSession);
    
    auto err2 = TelemetryError.storageError("test error");
    assert(err2.message.indexOf("test error") >= 0);
    assert(err2.code == ErrorCode.TelemetryStorage);
    
    auto err3 = TelemetryError.invalidData("bad data");
    assert(err3.message.indexOf("bad data") >= 0);
    assert(err3.code == ErrorCode.TelemetryInvalid);
    
    // Test Result error propagation
    auto collector = new TelemetryCollector();
    auto sessionResult = collector.getSession();
    assert(sessionResult.isErr);
    assert(sessionResult.unwrapErr().code == ErrorCode.TelemetryNoSession);
    
    writeln("  ✓ Error handling tests passed");
}

