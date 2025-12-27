module infrastructure.errors.codes.recoverability;

/// Recoverability classification for error handling strategies
enum Recoverability
{
    /// Fatal errors - cannot be recovered, must fail the build
    /// Examples: compilation errors, invalid configuration, missing targets
    Fatal,
    
    /// Transient errors - temporary failures that can be retried
    /// Examples: network timeouts, cache unavailable, process timeout
    Transient,
    
    /// User errors - incorrect configuration or usage (fixable by user)
    /// Examples: invalid syntax, missing file, unknown target
    User,
}

/// Check if error should be retried
bool shouldRetry(Recoverability r) pure nothrow @nogc @safe
{
    return r == Recoverability.Transient;
}

/// Get human-readable recoverability description
string recoverabilityDescription(Recoverability r) pure nothrow @safe
{
    final switch (r)
    {
        case Recoverability.Fatal:
            return "Fatal error - cannot be recovered";
        case Recoverability.Transient:
            return "Transient error - may succeed on retry";
        case Recoverability.User:
            return "User error - requires configuration fix";
    }
}

/// Get retry recommendation based on recoverability
string retryRecommendation(Recoverability r) pure nothrow @safe
{
    final switch (r)
    {
        case Recoverability.Fatal:
            return "Do not retry - investigate root cause";
        case Recoverability.Transient:
            return "Retry with exponential backoff";
        case Recoverability.User:
            return "Fix configuration and retry";
    }
}

