module infrastructure.errors.codes.internal;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Internal/unexpected error codes (9000-9999)
/// Covers assertions, bugs, and unexpected conditions
enum Internal : int
{
    /// Generic internal error
    Error = 9000,
    /// Feature not implemented
    NotImplemented = 9001,
    /// Assertion failed
    AssertionFailed = 9002,
    /// Unreachable code executed
    UnreachableCode = 9003,
    /// Initialization failed
    InitializationFailed = 9004,
    /// Component not initialized
    NotInitialized = 9005,
    /// Operation not supported
    NotSupported = 9006,
    /// Invariant violated
    InvariantViolation = 9007,
    /// Precondition failed
    PreconditionFailed = 9008,
    /// Postcondition failed
    PostconditionFailed = 9009,
    /// State machine invalid state
    InvalidState = 9010,
    /// Data corruption detected
    DataCorruption = 9011,
    /// Null pointer/reference
    NullReference = 9012,
    /// Array bounds error
    BoundsError = 9013,
    /// Integer overflow
    IntegerOverflow = 9014,
    /// Division by zero
    DivisionByZero = 9015,
    /// Range error
    RangeError = 9016,
    /// Invalid argument
    InvalidArgument = 9017,
    /// Logic error
    LogicError = 9018,
    /// Unexpected exception
    UnexpectedException = 9019,
}

/// Namespace for internal error utilities
struct InternalErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Internal; }
    
    static Recoverability recoverabilityOf(Internal) pure nothrow @nogc
    {
        return Recoverability.Fatal; // All internal errors are fatal
    }
    
    static string messageOf(Internal code) pure nothrow @safe
    {
        final switch (code)
        {
            case Internal.Error:                return "Internal error";
            case Internal.NotImplemented:       return "Not implemented";
            case Internal.AssertionFailed:      return "Assertion failed";
            case Internal.UnreachableCode:      return "Unreachable code reached";
            case Internal.InitializationFailed: return "Initialization failed";
            case Internal.NotInitialized:       return "Component not initialized";
            case Internal.NotSupported:         return "Operation not supported";
            case Internal.InvariantViolation:   return "Invariant violation";
            case Internal.PreconditionFailed:   return "Precondition failed";
            case Internal.PostconditionFailed:  return "Postcondition failed";
            case Internal.InvalidState:         return "Invalid state";
            case Internal.DataCorruption:       return "Data corruption detected";
            case Internal.NullReference:        return "Null reference";
            case Internal.BoundsError:          return "Array bounds error";
            case Internal.IntegerOverflow:      return "Integer overflow";
            case Internal.DivisionByZero:       return "Division by zero";
            case Internal.RangeError:           return "Range error";
            case Internal.InvalidArgument:      return "Invalid argument";
            case Internal.LogicError:           return "Logic error";
            case Internal.UnexpectedException:  return "Unexpected exception";
        }
    }
}

