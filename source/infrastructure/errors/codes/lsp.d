module infrastructure.errors.codes.lsp;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// LSP (Language Server Protocol) error codes (14000-14999)
/// Covers LSP server operations, document handling, and protocol
enum LSP : int
{
    /// Generic LSP error
    Error = 14000,
    /// LSP initialization failed
    InitializationFailed = 14001,
    /// Invalid LSP request
    InvalidRequest = 14002,
    /// LSP method not found
    MethodNotFound = 14003,
    /// Invalid LSP parameters
    InvalidParams = 14004,
    /// Document not found
    DocumentNotFound = 14005,
    /// LSP parse error
    ParseError = 14006,
    /// LSP server crashed
    ServerCrashed = 14007,
    /// LSP operation timed out
    Timeout = 14008,
    /// Invalid position in document
    InvalidPosition = 14009,
    /// Workspace not initialized
    WorkspaceNotInitialized = 14010,
    /// Document already open
    DocumentAlreadyOpen = 14011,
    /// Document not open
    DocumentNotOpen = 14012,
    /// Invalid URI format
    InvalidUri = 14013,
    /// Content changed during operation
    ContentChanged = 14014,
    /// Request cancelled
    RequestCancelled = 14015,
    /// Server not ready
    ServerNotReady = 14016,
    /// Server shutting down
    ServerShuttingDown = 14017,
    /// Capability not supported
    CapabilityNotSupported = 14018,
    /// Invalid range
    InvalidRange = 14019,
    /// Symbol not found
    SymbolNotFound = 14020,
    /// Rename failed
    RenameFailed = 14021,
    /// Code action failed
    CodeActionFailed = 14022,
    /// Completion failed
    CompletionFailed = 14023,
    /// Hover info unavailable
    HoverUnavailable = 14024,
    /// Diagnostics failed
    DiagnosticsFailed = 14025,
}

/// Namespace for LSP error utilities
struct LSPErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.LSP; }
    
    static Recoverability recoverabilityOf(LSP code) pure nothrow @nogc
    {
        switch (code)
        {
            case LSP.Timeout:
            case LSP.ServerCrashed:
            case LSP.ContentChanged:
            case LSP.ServerNotReady:
            case LSP.RequestCancelled:
                return Recoverability.Transient;
            case LSP.InvalidRequest:
            case LSP.InvalidParams:
            case LSP.DocumentNotFound:
            case LSP.InvalidPosition:
            case LSP.WorkspaceNotInitialized:
            case LSP.InvalidUri:
            case LSP.InvalidRange:
            case LSP.CapabilityNotSupported:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(LSP code) pure nothrow @safe
    {
        final switch (code)
        {
            case LSP.Error:                   return "LSP error";
            case LSP.InitializationFailed:    return "LSP initialization failed";
            case LSP.InvalidRequest:          return "Invalid LSP request";
            case LSP.MethodNotFound:          return "LSP method not found";
            case LSP.InvalidParams:           return "Invalid LSP parameters";
            case LSP.DocumentNotFound:        return "Document not found";
            case LSP.ParseError:              return "LSP parse error";
            case LSP.ServerCrashed:           return "LSP server crashed";
            case LSP.Timeout:                 return "LSP operation timed out";
            case LSP.InvalidPosition:         return "Invalid position";
            case LSP.WorkspaceNotInitialized: return "Workspace not initialized";
            case LSP.DocumentAlreadyOpen:     return "Document already open";
            case LSP.DocumentNotOpen:         return "Document not open";
            case LSP.InvalidUri:              return "Invalid URI format";
            case LSP.ContentChanged:          return "Content changed during operation";
            case LSP.RequestCancelled:        return "Request cancelled";
            case LSP.ServerNotReady:          return "Server not ready";
            case LSP.ServerShuttingDown:      return "Server shutting down";
            case LSP.CapabilityNotSupported:  return "Capability not supported";
            case LSP.InvalidRange:            return "Invalid range";
            case LSP.SymbolNotFound:          return "Symbol not found";
            case LSP.RenameFailed:            return "Rename failed";
            case LSP.CodeActionFailed:        return "Code action failed";
            case LSP.CompletionFailed:        return "Completion failed";
            case LSP.HoverUnavailable:        return "Hover info unavailable";
            case LSP.DiagnosticsFailed:       return "Diagnostics failed";
        }
    }
}

