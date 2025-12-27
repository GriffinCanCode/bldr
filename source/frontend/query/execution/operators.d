module frontend.query.execution.operators;

import std.algorithm;
import std.array;
import engine.graph;

/// Set operations on BuildNode collections
/// 
/// Uses index-based sets (bool[uint]) for O(1) membership testing
/// with better memory locality than pointer-based sets.

/// Union: A ∪ B (all elements in A or B)
/// 
/// Complexity: O(|A| + |B|)
BuildNode[] union_(BuildNode[] a, BuildNode[] b) @system
{
    bool[uint] seen;
    BuildNode[] result;
    result.reserve(a.length + b.length);
    
    foreach (node; a)
    {
        if (node !is null && node._nodeIndex !in seen)
        {
            seen[node._nodeIndex] = true;
            result ~= node;
        }
    }
    
    foreach (node; b)
    {
        if (node !is null && node._nodeIndex !in seen)
        {
            seen[node._nodeIndex] = true;
            result ~= node;
        }
    }
    
    return result;
}

/// Intersection: A ∩ B (elements in both A and B)
/// 
/// Complexity: O(|A| + |B|)
BuildNode[] intersect(BuildNode[] a, BuildNode[] b) @system
{
    // Build set from smaller array
    if (b.length < a.length)
    {
        auto temp = a;
        a = b;
        b = temp;
    }
    
    bool[uint] setA;
    foreach (node; a)
        if (node !is null)
            setA[node._nodeIndex] = true;
    
    BuildNode[] result;
    bool[uint] seen;
    
    foreach (node; b)
    {
        if (node !is null && node._nodeIndex in setA && node._nodeIndex !in seen)
        {
            result ~= node;
            seen[node._nodeIndex] = true;
        }
    }
    
    return result;
}

/// Difference: A \ B (elements in A but not in B)
/// 
/// Complexity: O(|A| + |B|)
BuildNode[] except(BuildNode[] a, BuildNode[] b) @system
{
    bool[uint] setB;
    foreach (node; b)
        if (node !is null)
            setB[node._nodeIndex] = true;
    
    BuildNode[] result;
    foreach (node; a)
        if (node !is null && node._nodeIndex !in setB)
            result ~= node;
    
    return result;
}

/// Symmetric difference: A △ B (elements in A or B but not both)
/// 
/// Complexity: O(|A| + |B|)
BuildNode[] symmetricDifference(BuildNode[] a, BuildNode[] b) @system
{
    bool[uint] setA, setB;
    
    foreach (node; a)
        if (node !is null)
            setA[node._nodeIndex] = true;
    
    foreach (node; b)
        if (node !is null)
            setB[node._nodeIndex] = true;
    
    BuildNode[] result;
    
    foreach (node; a)
        if (node !is null && node._nodeIndex !in setB)
            result ~= node;
    
    foreach (node; b)
        if (node !is null && node._nodeIndex !in setA)
            result ~= node;
    
    return result;
}

/// Remove duplicates from array
/// 
/// Complexity: O(n)
BuildNode[] unique(BuildNode[] nodes) @system
{
    bool[uint] seen;
    BuildNode[] result;
    result.reserve(nodes.length);
    
    foreach (node; nodes)
    {
        if (node !is null && node._nodeIndex !in seen)
        {
            result ~= node;
            seen[node._nodeIndex] = true;
        }
    }
    
    return result;
}

/// Check if two sets are equal
/// 
/// Complexity: O(|A| + |B|)
bool setEqual(BuildNode[] a, BuildNode[] b) @system
{
    if (a.length != b.length)
        return false;
    
    bool[uint] setA;
    foreach (node; a)
        if (node !is null)
            setA[node._nodeIndex] = true;
    
    foreach (node; b)
        if (node is null || node._nodeIndex !in setA)
            return false;
    
    return true;
}

/// Check if A is a subset of B (A ⊆ B)
/// 
/// Complexity: O(|A| + |B|)
bool isSubset(BuildNode[] a, BuildNode[] b) @system
{
    bool[uint] setB;
    foreach (node; b)
        if (node !is null)
            setB[node._nodeIndex] = true;
    
    foreach (node; a)
        if (node is null || node._nodeIndex !in setB)
            return false;
    
    return true;
}

/// Check if A is a superset of B (A ⊇ B)
bool isSuperset(BuildNode[] a, BuildNode[] b) @system => isSubset(b, a);

/// Check if two sets are disjoint (A ∩ B = ∅)
/// 
/// Complexity: O(|A| + |B|)
bool isDisjoint(BuildNode[] a, BuildNode[] b) @system
{
    // Build set from smaller array
    if (b.length < a.length)
    {
        auto temp = a;
        a = b;
        b = temp;
    }
    
    bool[uint] setA;
    foreach (node; a)
        if (node !is null)
            setA[node._nodeIndex] = true;
    
    foreach (node; b)
        if (node !is null && node._nodeIndex in setA)
            return false;
    
    return true;
}

/// Cardinality (size) of set
/// 
/// Complexity: O(n)
size_t cardinality(BuildNode[] nodes) @system
{
    bool[uint] set;
    foreach (node; nodes)
        if (node !is null)
            set[node._nodeIndex] = true;
    return set.length;
}
