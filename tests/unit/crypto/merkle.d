module tests.unit.crypto.merkle;

import std.algorithm : map, equal;
import std.array : array;
import std.conv : to;
import std.range : iota;
import infrastructure.utils.crypto.merkle;
import infrastructure.utils.crypto.blake3 : Blake3, toHexString;

/// Test basic Merkle tree construction
unittest
{
    // Create 8 test hashes
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    
    // Verify tree properties
    assert(tree.getLeafCount() == 8, "Expected 8 leaves");
    assert(tree.getRealLeafCount() == 8, "Expected 8 real leaves");
    assert(tree.getHeight() == 3, "Expected height 3 for 8 leaves");
    
    // Root should be deterministic
    auto tree2 = MerkleTree.build(hashes);
    assert(tree.root == tree2.root, "Same input should produce same root");
}

/// Test non-power-of-2 leaf count (padding)
unittest
{
    // Create 5 test hashes (not power of 2)
    ubyte[32][] hashes;
    foreach (i; 0 .. 5)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    
    // Should pad to 8 leaves
    assert(tree.getLeafCount() == 8, "Expected padding to 8 leaves");
    assert(tree.getRealLeafCount() == 5, "Expected 5 real leaves");
    assert(tree.getHeight() == 3, "Expected height 3");
}

/// Test single leaf tree
unittest
{
    ubyte[32] h;
    auto hasher = Blake3(0);
    hasher.put(cast(ubyte[])"single");
    h = hasher.finish(32)[0 .. 32];
    
    auto tree = MerkleTree.build([h]);
    
    assert(tree.getLeafCount() == 1, "Expected 1 leaf");
    assert(tree.getRealLeafCount() == 1, "Expected 1 real leaf");
    assert(tree.getHeight() == 0, "Expected height 0 for single leaf");
}

/// Test proof generation and verification
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 16)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    
    // Generate and verify proofs for each leaf
    foreach (i; 0 .. 16)
    {
        auto proof = tree.generateProof(cast(uint)i);
        assert(MerkleTree.verifyProof(proof, tree.root),
            "Proof verification failed for leaf " ~ i.to!string);
    }
    
    // Verify proof has correct path length (log2(16) = 4)
    auto proof = tree.generateProof(0);
    assert(proof.path.length == 4, "Expected 4 nodes in proof path");
}

/// Test proof serialization round-trip
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    auto proof = tree.generateProof(3);
    
    // Serialize
    auto bytes = proof.serialize();
    
    // Deserialize
    auto result = MerkleProof.deserialize(bytes);
    assert(result.isOk, "Proof deserialization failed");
    
    auto proof2 = result.unwrap();
    
    // Verify deserialized proof
    assert(proof2.leafIndex == proof.leafIndex, "Leaf index mismatch");
    assert(proof2.leafHash == proof.leafHash, "Leaf hash mismatch");
    assert(proof2.root == proof.root, "Root hash mismatch");
    assert(proof2.path.length == proof.path.length, "Path length mismatch");
    assert(proof2.verify(), "Deserialized proof verification failed");
}

/// Test tree serialization round-trip
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    
    // Serialize
    auto bytes = tree.serialize();
    
    // Deserialize
    auto result = MerkleTree.deserialize(bytes);
    assert(result.isOk, "Tree deserialization failed");
    
    auto tree2 = result.unwrap();
    
    // Verify properties match
    assert(tree2.root == tree.root, "Root hash mismatch after deserialization");
    assert(tree2.getLeafCount() == tree.getLeafCount(), "Leaf count mismatch");
    assert(tree2.getRealLeafCount() == tree.getRealLeafCount(), "Real leaf count mismatch");
}

/// Test tree diff - identical trees
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree1 = MerkleTree.build(hashes);
    auto tree2 = MerkleTree.build(hashes);
    
    auto diffs = MerkleTree.diff(tree1, tree2);
    assert(diffs.length == 0, "Identical trees should have no diffs");
}

/// Test tree diff - single change
unittest
{
    ubyte[32][] hashes1;
    ubyte[32][] hashes2;
    
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes1 ~= h;
        hashes2 ~= h;
    }
    
    // Modify one hash
    hashes2[3][0] = 0xFF;
    
    auto tree1 = MerkleTree.build(hashes1);
    auto tree2 = MerkleTree.build(hashes2);
    
    auto diffs = MerkleTree.diff(tree1, tree2);
    assert(diffs.length == 1, "Expected single diff");
    assert(diffs[0] == 3, "Expected diff at index 3");
}

/// Test tree diff - multiple changes
unittest
{
    ubyte[32][] hashes1;
    ubyte[32][] hashes2;
    
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes1 ~= h;
        hashes2 ~= h;
    }
    
    // Modify multiple hashes
    hashes2[1][0] = 0xFF;
    hashes2[5][0] = 0xFF;
    hashes2[7][0] = 0xFF;
    
    auto tree1 = MerkleTree.build(hashes1);
    auto tree2 = MerkleTree.build(hashes2);
    
    auto diffs = MerkleTree.diff(tree1, tree2);
    assert(diffs.length == 3, "Expected 3 diffs, got " ~ diffs.length.to!string);
}

/// Test streaming Merkle tree
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    // Build with regular method
    auto tree = MerkleTree.build(hashes);
    
    // Build with streaming method
    auto streaming = StreamingMerkleTree.create(8);
    foreach (h; hashes)
        streaming.addLeaf(h);
    auto streamRoot = streaming.finalize();
    
    // Roots should match
    assert(streamRoot == tree.root, "Streaming tree root should match regular tree root");
}

/// Test Merkle forest for large datasets
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 100)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)(i % 256)]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    // Build forest with max 32 leaves per tree
    auto forest = MerkleForest.build(hashes, 32);
    
    // Should have 4 trees (100 / 32 = 3.125, rounded up)
    assert(forest.trees.length == 4, "Expected 4 trees in forest");
    assert(forest.totalLeaves() == 100, "Expected 100 total leaves");
    
    // Test findTree
    assert(forest.findTree(0) == 0, "Leaf 0 should be in tree 0");
    assert(forest.findTree(31) == 0, "Leaf 31 should be in tree 0");
    assert(forest.findTree(32) == 1, "Leaf 32 should be in tree 1");
    assert(forest.findTree(99) == 3, "Leaf 99 should be in tree 3");
}

/// Test tamper detection - modified proof should fail
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    auto proof = tree.generateProof(3);
    
    // Original proof should verify
    assert(proof.verify(), "Original proof should verify");
    
    // Tamper with a sibling hash
    MerkleProof tamperedProof = proof;
    if (tamperedProof.path.length > 0)
        tamperedProof.path[0].hash[0] ^= 0xFF;
    
    assert(!MerkleTree.verifyProof(tamperedProof, tree.root),
        "Tampered proof should not verify");
}

/// Test wrong root detection
unittest
{
    ubyte[32][] hashes1;
    ubyte[32][] hashes2;
    
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes1 ~= h;
    }
    
    foreach (i; 0 .. 8)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)(i + 100)]);
        h = hasher.finish(32)[0 .. 32];
        hashes2 ~= h;
    }
    
    auto tree1 = MerkleTree.build(hashes1);
    auto tree2 = MerkleTree.build(hashes2);
    
    auto proof = tree1.generateProof(3);
    
    // Proof should verify against correct root
    assert(MerkleTree.verifyProof(proof, tree1.root), "Proof should verify against tree1 root");
    
    // Proof should NOT verify against wrong root
    assert(!MerkleTree.verifyProof(proof, tree2.root), "Proof should not verify against tree2 root");
}

/// Test edge case - empty input
unittest
{
    ubyte[32][] empty;
    auto tree = MerkleTree.build(empty);
    
    assert(tree.getLeafCount() == 0, "Empty tree should have 0 leaves");
    assert(tree.getRealLeafCount() == 0, "Empty tree should have 0 real leaves");
}

/// Test proof size efficiency
unittest
{
    // For a tree with 1 million leaves (2^20), proof should only be ~20 * 33 bytes
    ubyte[32][] hashes;
    foreach (i; 0 .. 1024)  // Use smaller test set
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)(i % 256)]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    auto proof = tree.generateProof(500);
    
    // log2(1024) = 10, so proof path should have 10 nodes
    assert(proof.path.length == 10, "Expected 10 nodes in proof path");
    
    // Proof size should be ~394 bytes (32 + 32 + 10 * 33)
    assert(proof.size() < 500, "Proof size should be efficient");
}

/// Test multi-proof
unittest
{
    ubyte[32][] hashes;
    foreach (i; 0 .. 16)
    {
        ubyte[32] h;
        auto hasher = Blake3(0);
        hasher.put(cast(ubyte[])[cast(ubyte)i]);
        h = hasher.finish(32)[0 .. 32];
        hashes ~= h;
    }
    
    auto tree = MerkleTree.build(hashes);
    
    // Build multi-proof for several leaves
    auto multiProof = MultiProof.build(tree, [0, 5, 10, 15]);
    
    assert(multiProof.leafIndices.length == 4, "Expected 4 leaf indices");
    assert(multiProof.leafHashes.length == 4, "Expected 4 leaf hashes");
    assert(multiProof.verify(tree), "Multi-proof verification failed");
}

/// Integration test - full workflow
unittest
{
    import infrastructure.utils.files.cdc : FastCDC;
    
    // Create test data
    ubyte[] testData = new ubyte[100_000];
    foreach (i, ref b; testData)
        b = cast(ubyte)(i % 256);
    
    // Chunk with Merkle tree
    auto cdc = FastCDC(FastCDC.Config.small());
    auto result = cdc.chunkData(testData, true);
    
    assert(result.chunks.length > 0, "Should have chunks");
    assert(result.merkleTree !is null, "Should have Merkle tree");
    
    // Generate proof for first chunk
    auto proof = result.generateProof(0);
    assert(proof.path.length > 0 || result.chunks.length == 1, "Should have proof path");
    
    // Verify proof
    assert(FastCDC.ChunkResult.verifyChunk(result.chunks[0].hash, proof),
        "Chunk proof verification failed");
}

