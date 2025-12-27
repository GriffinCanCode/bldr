module infrastructure.errors.codes.graph;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Dependency graph error codes (6000-6999)
/// Covers graph operations, topology, and traversal
enum Graph : int
{
    /// Cycle detected in dependency graph
    Cycle = 6000,
    /// Invalid graph structure
    Invalid = 6001,
    /// Node not found in graph
    NodeNotFound = 6002,
    /// Invalid edge in graph
    EdgeInvalid = 6003,
    /// Graph has multiple roots
    MultipleRoots = 6004,
    /// Graph is disconnected
    Disconnected = 6005,
    /// Topological sort failed
    TopologicalSortFailed = 6006,
    /// Maximum depth exceeded
    MaxDepthExceeded = 6007,
    /// Node already exists
    DuplicateNode = 6008,
    /// Edge already exists
    DuplicateEdge = 6009,
    /// Self-referential edge
    SelfReference = 6010,
    /// Graph modification during traversal
    ConcurrentModification = 6011,
    /// Invalid graph query
    InvalidQuery = 6012,
    /// Graph serialization failed
    SerializationFailed = 6013,
}

/// Namespace for graph error utilities
struct GraphErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Graph; }
    
    static Recoverability recoverabilityOf(Graph code) pure nothrow @nogc
    {
        switch (code)
        {
            case Graph.ConcurrentModification:
                return Recoverability.Transient;
            case Graph.Cycle:
            case Graph.DuplicateNode:
            case Graph.SelfReference:
            case Graph.InvalidQuery:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Graph code) pure nothrow @safe
    {
        final switch (code)
        {
            case Graph.Cycle:                  return "Dependency cycle detected";
            case Graph.Invalid:                return "Invalid dependency graph";
            case Graph.NodeNotFound:           return "Graph node not found";
            case Graph.EdgeInvalid:            return "Invalid graph edge";
            case Graph.MultipleRoots:          return "Graph has multiple roots";
            case Graph.Disconnected:           return "Graph is disconnected";
            case Graph.TopologicalSortFailed:  return "Topological sort failed";
            case Graph.MaxDepthExceeded:       return "Maximum depth exceeded";
            case Graph.DuplicateNode:          return "Duplicate node in graph";
            case Graph.DuplicateEdge:          return "Duplicate edge in graph";
            case Graph.SelfReference:          return "Self-referential dependency";
            case Graph.ConcurrentModification: return "Graph modified during traversal";
            case Graph.InvalidQuery:           return "Invalid graph query";
            case Graph.SerializationFailed:    return "Graph serialization failed";
        }
    }
}

