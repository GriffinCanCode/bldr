module tests.unit.core.hermetic_timeout;

import std.datetime : seconds, msecs, Duration;
import engine.runtime.hermetic.security.timeout;
import core.thread : Thread;

@safe unittest
{
    // Test NoOpTimeoutEnforcer basic functionality
    auto enforcer = new NoOpTimeoutEnforcer();
    enforcer.start(1.seconds);
    
    assert(!enforcer.isTimedOut(), "NoOpTimeoutEnforcer should never timeout");
    assert(enforcer.remaining() > Duration.zero, "Should have remaining time");
    
    enforcer.stop();
}

@safe unittest
{
    // Test timeout remaining time calculation
    auto enforcer = new NoOpTimeoutEnforcer();
    immutable timeout = 1.seconds;
    enforcer.start(timeout);
    
    Thread.sleep(100.msecs);
    
    auto remaining = enforcer.remaining();
    assert(remaining < timeout, "Remaining time should decrease");
    assert(remaining > Duration.zero, "Should still have time remaining");
    
    enforcer.stop();
}

@safe unittest
{
    // Test createTimeoutEnforcer factory
    auto enforcer = createTimeoutEnforcer();
    assert(enforcer !is null, "Should create enforcer");
    
    enforcer.start(1.seconds);
    assert(!enforcer.isTimedOut(), "Should not timeout immediately");
    enforcer.stop();
}

// Process timeout enforcer tests require actual process spawning
// and are better suited for integration tests

