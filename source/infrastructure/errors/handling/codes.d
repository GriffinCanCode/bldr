module infrastructure.errors.handling.codes;

/// Backward compatibility module - re-exports from hierarchical error codes package
/// 
/// For new code, prefer importing directly:
///   import infrastructure.errors.codes;
/// 
/// This module re-exports all symbols for existing code compatibility.

public import infrastructure.errors.codes :
    // Core types
    ErrorCategory,
    Recoverability,
    
    // Flat error code enum (backward compatible)
    ErrorCode,
    
    // Utility functions
    categoryOf,
    recoverabilityOf,
    isRecoverable,
    messageTemplate,
    
    // Registry
    ErrorRegistryEntry,
    errorRegistry,
    lookupError,
    
    // Category utilities
    categoryName,
    categoryDocsUrl,
    
    // Recoverability utilities
    shouldRetry,
    recoverabilityDescription,
    retryRecommendation;
