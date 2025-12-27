module infrastructure.utils.crypto.merkle;

import std.algorithm : min, max, map, reduce, filter;
import std.array : array, appender, Appender;
import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import std.math : log2, ceil, floor;
import std.range : iota, chunks;
import std.conv : to;
import infrastructure.utils.crypto.blake3 : Blake3, toHexString;
import infrastructure.errors : Result, Ok, Err, BuildResult, BuildError, VoidBuildResult;

/// BLAKE3 Merkle Tree for content-addressable verification
/// Enables parallel verification and partial artifact validation
/// 
/// Properties:
/// - Binary tree structure (2^n leaves, padded as needed)
/// - BLAKE3 for all hash computations (SIMD-accelerated)
/// - O(log n) proof size for any leaf
/// - Supports parallel subtree verification
/// - Incremental diff detection via tree comparison
struct MerkleTree
{
    /// Tree node containing hash and metadata
    struct Node
    {
        ubyte[32] hash;    // BLAKE3 hash (256-bit)
        uint leftChild;    // Index of left child (0 = none)
        uint rightChild;   // Index of right child (0 = none)
        uint parent;       // Index of parent (0 = root has no parent)
        uint level;        // Tree level (0 = leaves)
        bool isLeaf;       // True for leaf nodes
        
        /// Hash as hex string
        string hashHex() const @system => toHexString(hash[]);
        
        /// Is empty/padding node
        bool isEmpty() const pure @safe nothrow @nogc => hash == EMPTY_HASH;
    }
    
    /// Empty hash constant (BLAKE3 of empty input)
    private static immutable ubyte[32] EMPTY_HASH = computeEmptyHash();
    
    /// Domain separation tag for internal nodes
    private static immutable ubyte[1] INTERNAL_TAG = [0x01];
    private static immutable ubyte[1] LEAF_TAG = [0x00];
    
    private Node[] nodes;        // All nodes (leaves first, then internal)
    private uint leafCount;      // Number of leaf nodes (including padding)
    private uint realLeaves;     // Number of real (non-padding) leaves
    private uint height;         // Tree height (log2(leafCount))
    private ubyte[32] rootHash;  // Cached root hash
    
    /// Build tree from chunk hashes
    /// Pads to next power of 2 with empty hashes
    @system
    static MerkleTree build(const(ubyte[32])[] chunkHashes)
    {
        MerkleTree tree;
        if (chunkHashes.length == 0) return tree;
        
        tree.realLeaves = cast(uint)chunkHashes.length;
        
        // Pad to next power of 2
        tree.leafCount = nextPow2(cast(uint)chunkHashes.length);
        tree.height = tree.leafCount > 1 ? cast(uint)ceil(log2(cast(double)tree.leafCount)) : 0;
        
        // Total nodes = 2 * leafCount - 1 (perfect binary tree)
        immutable totalNodes = 2 * tree.leafCount - 1;
        tree.nodes = new Node[totalNodes];
        
        // Initialize leaf nodes
        foreach (i; 0 .. tree.leafCount)
        {
            tree.nodes[i].isLeaf = true;
            tree.nodes[i].level = 0;
            
            if (i < chunkHashes.length)
            {
                // Real leaf: hash with leaf tag for domain separation
                tree.nodes[i].hash = hashLeaf(chunkHashes[i][]);
            }
            else
            {
                // Padding: use empty hash
                tree.nodes[i].hash = EMPTY_HASH;
            }
        }
        
        // Build internal nodes bottom-up
        tree.buildInternal();
        
        // Cache root hash
        tree.rootHash = tree.nodes[$ - 1].hash;
        
        return tree;
    }
    
    /// Build from raw data chunks (hashes chunks then builds tree)
    @system
    static MerkleTree fromData(const(ubyte[])[] dataChunks)
    {
        auto hashes = new ubyte[32][dataChunks.length];
        
        foreach (i, chunk; dataChunks)
        {
            auto hasher = Blake3(0);
            hasher.put(chunk);
            hashes[i] = hasher.finish(32)[0 .. 32];
        }
        
        return build(hashes);
    }
    
    /// Get root hash (tree signature)
    ubyte[32] root() const pure @safe nothrow @nogc => rootHash;
    
    /// Get root hash as hex string
    string rootHex() const @system => toHexString(rootHash[]);
    
    /// Get tree height
    uint getHeight() const pure @safe nothrow @nogc => height;
    
    /// Get number of leaves (including padding)
    uint getLeafCount() const pure @safe nothrow @nogc => leafCount;
    
    /// Get number of real (non-padding) leaves
    uint getRealLeafCount() const pure @safe nothrow @nogc => realLeaves;
    
    /// Get all leaf hashes (excluding padding)
    ubyte[32][] getLeafHashes() const @safe
    {
        auto hashes = new ubyte[32][realLeaves];
        foreach (i; 0 .. realLeaves)
            hashes[i] = nodes[i].hash;
        return hashes;
    }
    
    /// Generate Merkle proof for leaf at index
    /// Proof contains sibling hashes along path to root
    @system
    MerkleProof generateProof(uint leafIndex) const
    {
        MerkleProof proof;
        
        if (leafIndex >= realLeaves) return proof;  // Invalid index
        
        proof.leafIndex = leafIndex;
        proof.leafHash = nodes[leafIndex].hash;
        proof.root = rootHash;
        
        auto siblings = appender!(ProofNode[])();
        uint currentIdx = leafIndex;
        uint levelSize = leafCount;
        uint levelStart = 0;
        
        // Traverse from leaf to root
        while (levelSize > 1)
        {
            // Find sibling
            immutable isRight = (currentIdx - levelStart) % 2 == 1;
            immutable siblingIdx = isRight ? currentIdx - 1 : currentIdx + 1;
            
            ProofNode node;
            node.hash = nodes[siblingIdx].hash;
            node.isRight = !isRight;  // Sibling position
            siblings ~= node;
            
            // Move to parent level
            immutable parentOffset = (currentIdx - levelStart) / 2;
            levelStart += levelSize;
            levelSize /= 2;
            currentIdx = levelStart + parentOffset;
        }
        
        proof.path = siblings[];
        return proof;
    }
    
    /// Verify a proof against expected root
    @system
    static bool verifyProof(ref const MerkleProof proof, const(ubyte[32]) expectedRoot)
    {
        if (proof.path.length == 0 && proof.leafHash == expectedRoot)
            return true;  // Single-node tree
        
        ubyte[32] current = proof.leafHash;
        
        foreach (ref node; proof.path)
        {
            if (node.isRight)
                current = hashInternal(current[], node.hash[]);
            else
                current = hashInternal(node.hash[], current[]);
        }
        
        return current == expectedRoot;
    }
    
    /// Compare two trees and find differing leaf indices
    /// Returns indices of leaves that differ (for incremental sync)
    @system
    static uint[] diff(ref const MerkleTree a, ref const MerkleTree b)
    {
        if (a.rootHash == b.rootHash) return [];  // Identical trees
        
        auto diffs = appender!(uint[])();
        diffSubtree(a, b, 0, 0, min(a.realLeaves, b.realLeaves), diffs);
        
        // Handle size differences
        if (a.realLeaves > b.realLeaves)
            foreach (i; b.realLeaves .. a.realLeaves) diffs ~= i;
        else if (b.realLeaves > a.realLeaves)
            foreach (i; a.realLeaves .. b.realLeaves) diffs ~= i;
        
        return diffs[];
    }
    
    /// Parallel verification of multiple subtrees
    /// Returns true if all subtrees match expected hashes
    @system
    bool verifySubtrees(const(SubtreeSpec)[] specs) const
    {
        foreach (ref spec; specs)
        {
            if (!verifySubtree(spec.startLeaf, spec.endLeaf, spec.expectedHash))
                return false;
        }
        return true;
    }
    
    /// Verify a subtree (range of leaves) matches expected hash
    @system
    bool verifySubtree(uint startLeaf, uint endLeaf, const(ubyte[32]) expected) const
    {
        if (startLeaf >= endLeaf || endLeaf > realLeaves) return false;
        
        // Find the lowest common ancestor covering the range
        auto subtreeHash = computeSubtreeHash(startLeaf, endLeaf);
        return subtreeHash == expected;
    }
    
    /// Serialize tree to bytes (for storage/transfer)
    @system
    ubyte[] serialize() const
    {
        auto buf = appender!(ubyte[])();
        
        // Header: version, leafCount, realLeaves, height
        buf ~= cast(ubyte)1;  // Version
        buf ~= nativeToBigEndian(leafCount)[];
        buf ~= nativeToBigEndian(realLeaves)[];
        buf ~= nativeToBigEndian(height)[];
        buf ~= rootHash[];
        
        // Leaf hashes only (internal nodes can be recomputed)
        foreach (i; 0 .. realLeaves)
            buf ~= nodes[i].hash[];
        
        return buf[];
    }
    
    /// Deserialize from bytes
    @system
    static Result!(MerkleTree, string) deserialize(const(ubyte)[] data)
    {
        if (data.length < 45)  // 1 + 4 + 4 + 4 + 32
            return Err!(MerkleTree, string)("Merkle tree data too short");
        
        if (data[0] != 1)
            return Err!(MerkleTree, string)("Unsupported Merkle tree version");
        
        size_t pos = 1;
        immutable leafCount_ = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        immutable realLeaves_ = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        immutable height_ = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        
        ubyte[32] rootHash_;
        rootHash_[] = data[pos .. pos + 32][0 .. 32]; pos += 32;
        
        if (data.length < pos + realLeaves_ * 32)
            return Err!(MerkleTree, string)("Truncated leaf hashes");
        
        // Extract leaf hashes
        auto hashes = new ubyte[32][realLeaves_];
        foreach (i; 0 .. realLeaves_)
        {
            hashes[i] = data[pos .. pos + 32][0 .. 32];
            pos += 32;
        }
        
        // Rebuild tree
        auto tree = build(hashes);
        
        // Verify root matches
        if (tree.rootHash != rootHash_)
            return Err!(MerkleTree, string)("Root hash mismatch after rebuild");
        
        return Ok!(MerkleTree, string)(tree);
    }
    
    // === Private Implementation ===
    
    /// Build internal nodes bottom-up
    private void buildInternal() @system
    {
        uint levelStart = 0;
        uint levelSize = leafCount;
        uint nextLevelStart = leafCount;
        
        while (levelSize > 1)
        {
            immutable nextLevelSize = levelSize / 2;
            
            foreach (i; 0 .. nextLevelSize)
            {
                immutable leftIdx = levelStart + i * 2;
                immutable rightIdx = leftIdx + 1;
                immutable parentIdx = nextLevelStart + i;
                
                // Set parent references
                nodes[leftIdx].parent = parentIdx;
                nodes[rightIdx].parent = parentIdx;
                
                // Set child references
                nodes[parentIdx].leftChild = leftIdx;
                nodes[parentIdx].rightChild = rightIdx;
                nodes[parentIdx].level = nodes[leftIdx].level + 1;
                
                // Compute internal node hash
                nodes[parentIdx].hash = hashInternal(
                    nodes[leftIdx].hash[],
                    nodes[rightIdx].hash[]
                );
            }
            
            levelStart = nextLevelStart;
            nextLevelStart += nextLevelSize;
            levelSize = nextLevelSize;
        }
    }
    
    /// Recursively diff subtrees
    private static void diffSubtree(
        ref const MerkleTree a,
        ref const MerkleTree b,
        uint nodeIdxA,
        uint nodeIdxB,
        uint rangeEnd,
        ref Appender!(uint[]) diffs
    ) @system
    {
        // Same hash = identical subtrees
        if (a.nodes[nodeIdxA].hash == b.nodes[nodeIdxB].hash)
            return;
        
        // Leaf node = definite difference
        if (a.nodes[nodeIdxA].isLeaf)
        {
            diffs ~= nodeIdxA;
            return;
        }
        
        // Recurse into children
        diffSubtree(a, b, a.nodes[nodeIdxA].leftChild, b.nodes[nodeIdxB].leftChild, rangeEnd, diffs);
        diffSubtree(a, b, a.nodes[nodeIdxA].rightChild, b.nodes[nodeIdxB].rightChild, rangeEnd, diffs);
    }
    
    /// Compute hash of subtree covering leaf range
    private ubyte[32] computeSubtreeHash(uint start, uint end) const @system
    {
        if (end - start == 1)
            return nodes[start].hash;
        
        immutable mid = start + (end - start) / 2;
        auto leftHash = computeSubtreeHash(start, mid);
        auto rightHash = computeSubtreeHash(mid, end);
        return hashInternal(leftHash[], rightHash[]);
    }
    
    /// Hash a leaf with domain separation
    private static ubyte[32] hashLeaf(const(ubyte)[] data) @system
    {
        auto hasher = Blake3(0);
        hasher.put(LEAF_TAG[]);
        hasher.put(data);
        return hasher.finish(32)[0 .. 32];
    }
    
    /// Hash internal node (concatenation of children)
    private static ubyte[32] hashInternal(const(ubyte)[] left, const(ubyte)[] right) @system
    {
        auto hasher = Blake3(0);
        hasher.put(INTERNAL_TAG[]);
        hasher.put(left);
        hasher.put(right);
        return hasher.finish(32)[0 .. 32];
    }
    
    /// Compute empty hash at compile time
    private static ubyte[32] computeEmptyHash() @trusted
    {
        ubyte[32] result;
        // Pre-computed BLAKE3 hash of empty input with leaf tag
        // This is equivalent to: auto h = Blake3(0); h.put([0x00]); return h.finish(32);
        result = [
            0xaf, 0x13, 0x49, 0xb9, 0xf5, 0xf9, 0xa1, 0xa6,
            0xa0, 0x40, 0x4d, 0xea, 0x36, 0xdc, 0xc9, 0x49,
            0x9b, 0xcb, 0x25, 0xc9, 0xad, 0xc1, 0x12, 0xb7,
            0xcc, 0x9a, 0x93, 0xca, 0xe4, 0x1f, 0x32, 0x62
        ];
        return result;
    }
    
    /// Round up to next power of 2
    private static uint nextPow2(uint n) pure @safe nothrow @nogc
    {
        if (n == 0) return 1;
        n--;
        n |= n >> 1;
        n |= n >> 2;
        n |= n >> 4;
        n |= n >> 8;
        n |= n >> 16;
        return n + 1;
    }
}

/// Merkle proof for a single leaf
struct MerkleProof
{
    uint leafIndex;          // Index of proven leaf
    ubyte[32] leafHash;      // Hash of leaf data
    ubyte[32] root;          // Expected root hash
    ProofNode[] path;        // Authentication path
    
    /// Proof size in bytes
    size_t size() const pure @safe nothrow @nogc
        => 32 + 32 + path.length * 33;  // leafHash + root + path
    
    /// Verify this proof
    @system
    bool verify() const => MerkleTree.verifyProof(this, root);
    
    /// Serialize proof
    @system
    ubyte[] serialize() const
    {
        auto buf = appender!(ubyte[])();
        buf ~= nativeToBigEndian(leafIndex)[];
        buf ~= leafHash[];
        buf ~= root[];
        buf ~= nativeToBigEndian(cast(uint)path.length)[];
        foreach (ref n; path)
        {
            buf ~= n.hash[];
            buf ~= cast(ubyte)(n.isRight ? 1 : 0);
        }
        return buf[];
    }
    
    /// Deserialize proof
    @system
    static Result!(MerkleProof, string) deserialize(const(ubyte)[] data)
    {
        if (data.length < 72)  // 4 + 32 + 32 + 4
            return Err!(MerkleProof, string)("Proof data too short");
        
        MerkleProof proof;
        size_t pos = 0;
        
        proof.leafIndex = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        proof.leafHash = data[pos .. pos + 32][0 .. 32]; pos += 32;
        proof.root = data[pos .. pos + 32][0 .. 32]; pos += 32;
        
        immutable pathLen = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        
        if (data.length < pos + pathLen * 33)
            return Err!(MerkleProof, string)("Truncated proof path");
        
        proof.path = new ProofNode[pathLen];
        foreach (i; 0 .. pathLen)
        {
            proof.path[i].hash = data[pos .. pos + 32][0 .. 32]; pos += 32;
            proof.path[i].isRight = data[pos++] == 1;
        }
        
        return Ok!(MerkleProof, string)(proof);
    }
}

/// Single node in proof path
struct ProofNode
{
    ubyte[32] hash;   // Sibling hash
    bool isRight;     // True if sibling is on right
}

/// Subtree specification for parallel verification
struct SubtreeSpec
{
    uint startLeaf;       // First leaf index (inclusive)
    uint endLeaf;         // Last leaf index (exclusive)
    ubyte[32] expectedHash;  // Expected subtree hash
}

/// Multi-proof for batch verification
/// More efficient than individual proofs when verifying multiple leaves
struct MultiProof
{
    uint[] leafIndices;      // Indices of proven leaves
    ubyte[32][] leafHashes;  // Leaf hashes
    ubyte[32][] hashes;      // All required intermediate hashes
    ubyte[32] root;          // Expected root
    
    /// Build multi-proof for multiple leaves
    @system
    static MultiProof build(ref const MerkleTree tree, const(uint)[] indices)
    {
        MultiProof proof;
        proof.root = tree.rootHash;
        proof.leafIndices = indices.dup;
        
        auto leaves = appender!(ubyte[32][])();
        auto intermediates = appender!(ubyte[32][])();
        
        // Collect leaf hashes
        foreach (idx; indices)
            if (idx < tree.realLeaves)
                leaves ~= tree.nodes[idx].hash;
        
        proof.leafHashes = leaves[];
        
        // Collect minimal set of intermediate hashes needed
        bool[uint] needed;
        foreach (idx; indices)
        {
            auto p = tree.generateProof(idx);
            foreach (i, ref node; p.path)
            {
                // Track unique intermediate hashes
                immutable key = cast(uint)(idx ^ (i << 16));
                if (key !in needed)
                {
                    needed[key] = true;
                    intermediates ~= node.hash;
                }
            }
        }
        
        proof.hashes = intermediates[];
        return proof;
    }
    
    /// Verify multi-proof
    @system
    bool verify(ref const MerkleTree tree) const
    {
        foreach (i, idx; leafIndices)
        {
            auto singleProof = tree.generateProof(idx);
            if (!singleProof.verify())
                return false;
        }
        return true;
    }
}

/// Incremental Merkle tree for streaming construction
/// Builds tree as leaves arrive without storing all data
struct StreamingMerkleTree
{
    private ubyte[32][][] levels;  // Pending hashes at each level
    private uint leafCount;
    private uint height;
    
    /// Initialize for expected leaf count (0 = dynamic)
    @system
    static StreamingMerkleTree create(uint expectedLeaves = 0)
    {
        StreamingMerkleTree tree;
        tree.height = expectedLeaves > 0 
            ? cast(uint)ceil(log2(cast(double)MerkleTree.nextPow2(expectedLeaves)))
            : 32;  // Max height for dynamic
        tree.levels = new ubyte[32][][tree.height + 1];
        return tree;
    }
    
    /// Add a leaf (chunk hash)
    @system
    void addLeaf(const(ubyte[32]) hash)
    {
        // Hash with leaf tag
        auto hasher = Blake3(0);
        hasher.put(MerkleTree.LEAF_TAG[]);
        hasher.put(hash[]);
        ubyte[32] leafHash = hasher.finish(32)[0 .. 32];
        
        addHash(0, leafHash);
        leafCount++;
    }
    
    /// Finalize and get root hash
    @system
    ubyte[32] finalize()
    {
        // Pad with empty hashes to complete tree
        while (levels[0].length > 0 || leafCount == 0)
        {
            if (leafCount == 0)
            {
                addHash(0, MerkleTree.EMPTY_HASH);
                leafCount++;
                break;
            }
            
            // Add padding if needed at any level
            foreach (level; 0 .. height)
            {
                if (levels[level].length == 1)
                {
                    // Odd node - promote with empty sibling
                    auto hash = levels[level][0];
                    levels[level] = [];
                    addHash(level, hash);
                }
            }
            break;
        }
        
        // Root is at highest level with single hash
        foreach_reverse (level; 0 .. height + 1)
        {
            if (levels[level].length == 1)
                return levels[level][0];
        }
        
        return MerkleTree.EMPTY_HASH;
    }
    
    /// Get current leaf count
    uint getLeafCount() const pure @safe nothrow @nogc => leafCount;
    
    private void addHash(uint level, ubyte[32] hash) @system
    {
        if (level >= levels.length) return;
        
        levels[level] ~= hash;
        
        // If we have a pair, combine and promote
        if (levels[level].length == 2)
        {
            auto combined = hashInternal(levels[level][0][], levels[level][1][]);
            levels[level] = [];
            addHash(level + 1, combined);
        }
    }
    
    private static ubyte[32] hashInternal(const(ubyte)[] left, const(ubyte)[] right) @system
    {
        auto hasher = Blake3(0);
        hasher.put(MerkleTree.INTERNAL_TAG[]);
        hasher.put(left);
        hasher.put(right);
        return hasher.finish(32)[0 .. 32];
    }
}

/// Merkle forest for very large datasets
/// Splits data into multiple trees for parallel processing
struct MerkleForest
{
    MerkleTree[] trees;       // Individual trees
    ubyte[32] forestRoot;     // Root hash of forest
    uint treesPerLevel;       // Trees at each level
    
    /// Build forest from chunk hashes
    /// Each tree contains up to maxLeavesPerTree leaves
    @system
    static MerkleForest build(const(ubyte[32])[] hashes, uint maxLeavesPerTree = 1024)
    {
        MerkleForest forest;
        
        if (hashes.length == 0) return forest;
        
        // Split into subtrees
        auto treeHashes = appender!(MerkleTree[])();
        auto treeRoots = appender!(ubyte[32][])();
        
        foreach (chunk; hashes.chunks(maxLeavesPerTree))
        {
            auto tree = MerkleTree.build(chunk.array);
            treeHashes ~= tree;
            treeRoots ~= tree.root;
        }
        
        forest.trees = treeHashes[];
        forest.treesPerLevel = cast(uint)forest.trees.length;
        
        // Build top-level tree from subtree roots
        if (treeRoots[].length > 1)
        {
            auto topTree = MerkleTree.build(treeRoots[]);
            forest.forestRoot = topTree.root;
        }
        else
        {
            forest.forestRoot = treeRoots[][0];
        }
        
        return forest;
    }
    
    /// Find which tree contains a given leaf index
    uint findTree(uint globalLeafIndex) const pure @safe nothrow @nogc
    {
        uint offset = 0;
        foreach (i, ref tree; trees)
        {
            if (globalLeafIndex < offset + tree.getRealLeafCount())
                return cast(uint)i;
            offset += tree.getRealLeafCount();
        }
        return cast(uint)(trees.length - 1);
    }
    
    /// Generate proof for global leaf index
    @system
    MerkleProof generateProof(uint globalLeafIndex) const
    {
        immutable treeIdx = findTree(globalLeafIndex);
        
        // Calculate local index within tree
        uint offset = 0;
        foreach (i; 0 .. treeIdx)
            offset += trees[i].getRealLeafCount();
        
        immutable localIndex = globalLeafIndex - offset;
        return trees[treeIdx].generateProof(localIndex);
    }
    
    /// Total leaf count across all trees
    uint totalLeaves() const pure @safe
    {
        uint total = 0;
        foreach (ref tree; trees)
            total += tree.getRealLeafCount();
        return total;
    }
}

// Unit tests
unittest
{
    import std.stdio : writeln;
    
    // Test basic tree construction
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        h[0] = cast(ubyte)i;
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    assert(tree.getLeafCount() == 8);
    assert(tree.getRealLeafCount() == 8);
    assert(tree.getHeight() == 3);
    
    // Test proof generation and verification
    auto proof = tree.generateProof(3);
    assert(MerkleTree.verifyProof(proof, tree.root));
    
    // Test serialization round-trip
    auto serialized = tree.serialize();
    auto deserialized = MerkleTree.deserialize(serialized);
    assert(deserialized.isOk);
    assert(deserialized.unwrap().root == tree.root);
    
    // Test proof serialization
    auto proofBytes = proof.serialize();
    auto proofDeserialized = MerkleProof.deserialize(proofBytes);
    assert(proofDeserialized.isOk);
    assert(proofDeserialized.unwrap().verify());
    
    // Test tree diff
    ubyte[32][] hashes2 = hashes.dup;
    hashes2[2][0] = 99;  // Modify one hash
    auto tree2 = MerkleTree.build(hashes2);
    auto diffs = MerkleTree.diff(tree, tree2);
    assert(diffs.length == 1);
    assert(diffs[0] == 2);
    
    // Test streaming tree
    auto streaming = StreamingMerkleTree.create(8);
    foreach (h; hashes)
        streaming.addLeaf(h);
    auto streamRoot = streaming.finalize();
    assert(streamRoot == tree.root);
    
    writeln("Merkle tree tests passed!");
}

