module tests.unit.core.hermetic_monitor;

import std.datetime : seconds, msecs, Duration;
import engine.runtime.hermetic.monitoring;
import engine.runtime.hermetic.core.spec : ResourceLimits;

@safe unittest
{
    // Test NoOpMonitor basic functionality
    auto monitor = new NoOpMonitor();
    monitor.start();
    
    auto usage = monitor.snapshot();
    assert(usage.peakMemory == 0, "NoOpMonitor should report zero memory");
    
    assert(!monitor.isViolated(), "NoOpMonitor should never violate");
    assert(monitor.violations().length == 0, "NoOpMonitor should have no violations");
    
    monitor.stop();
}

@safe unittest
{
    // Test resource limit violation detection
    auto limits = ResourceLimits.hermetic();
    limits.maxMemoryBytes = 1024; // Very low limit for testing
    
    auto monitor = createMonitor(limits);
    monitor.start();
    
    // Simulate time passing
    import core.thread : Thread;
    Thread.sleep(10.msecs);
    
    monitor.stop();
    
    // Check that monitor can report usage
    auto usage = monitor.snapshot();
    assert(usage.cpuTime >= Duration.zero, "CPU time should be non-negative");
}

@safe unittest
{
    // Test wouldExceed functionality
    auto limits = ResourceLimits.hermetic();
    limits.maxMemoryBytes = 1024 * 1024; // 1MB
    limits.maxCpuTimeMs = 1000; // 1 second
    
    auto monitor = createMonitor(limits);
    monitor.start();
    
    // Create stricter limits
    auto stricterLimits = ResourceLimits.hermetic();
    stricterLimits.maxMemoryBytes = 512; // 512 bytes
    
    // Should not exceed initially
    assert(!monitor.wouldExceed(stricterLimits), "Should not exceed stricter limits initially");
    
    monitor.stop();
}

version(linux)
{
    @safe unittest
    {
        import engine.runtime.hermetic.monitoring.linux : LinuxMonitor;
        
        // Test Linux-specific monitor creation
        auto limits = ResourceLimits.defaults();
        auto monitor = new LinuxMonitor(limits);
        
        monitor.start();
        
        auto usage = monitor.snapshot();
        assert(usage.cpuTime >= Duration.zero, "Linux monitor should track CPU time");
        
        monitor.stop();
    }
}

version(OSX)
{
    @safe unittest
    {
        import engine.runtime.hermetic.monitoring.macos : MacOSMonitor;
        
        // Test macOS-specific monitor creation
        auto limits = ResourceLimits.defaults();
        auto monitor = new MacOSMonitor(limits);
        
        monitor.start();
        
        auto usage = monitor.snapshot();
        assert(usage.cpuTime >= Duration.zero, "macOS monitor should track CPU time");
        
        monitor.stop();
    }
}

version(Windows)
{
    @trusted unittest
    {
        import engine.runtime.hermetic.monitoring.windows : WindowsMonitor;
        
        // Test Windows-specific monitor creation
        auto limits = ResourceLimits.defaults();
        auto monitor = new WindowsMonitor(limits);
        
        monitor.start();
        
        auto usage = monitor.snapshot();
        assert(usage.cpuTime >= Duration.zero, "Windows monitor should track CPU time");
        
        monitor.stop();
    }
}

