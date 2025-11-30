module tests.unit.caching.source_storage_test;

import std.stdio;
import std.path;
import std.file;
import std.conv;
import engine.caching.storage;
import infrastructure.errors;
import tests.harness;
import tests.fixtures;

// Test SourceRef creation and validation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRef - Creation from file");
    
    auto tempDir = scoped(new TempDir("source-ref-test"));
    auto testFile = buildPath(tempDir.getPath(), "test.txt");
    std.file.write(testFile, "Hello, Content-Addressed World!");
    
    auto result = SourceRef.fromFile(testFile);
    Assert.isTrue(result.isOk, "SourceRef creation should succeed");
    
    auto ref_ = result.unwrap();
    Assert.isTrue(ref_.isValid(), "SourceRef should be valid");
    Assert.isTrue(ref_.hash.length > 0, "Hash should not be empty");
    Assert.equal(ref_.originalPath, testFile);
    Assert.equal(ref_.size, 31);
    
    writeln("\x1b[32m  ✓ SourceRef creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRef - Equality and hashing");
    
    auto tempDir = scoped(new TempDir("source-ref-eq-test"));
    
    // Create two files with same content
    auto file1 = buildPath(tempDir.getPath(), "file1.txt");
    auto file2 = buildPath(tempDir.getPath(), "file2.txt");
    
    immutable content = "Same content";
    std.file.write(file1, content);
    std.file.write(file2, content);
    
    auto ref1 = SourceRef.fromFile(file1).unwrap();
    auto ref2 = SourceRef.fromFile(file2).unwrap();
    
    // Should have same hash (content-addressed)
    Assert.equal(ref1.hash, ref2.hash);
    Assert.isTrue(ref1 == ref2, "SourceRefs with same content should be equal");
    
    writeln("\x1b[32m  ✓ Content-based equality works\x1b[0m");
}

// Test SourceRepository storage and retrieval
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRepository - Store and fetch");
    
    auto tempDir = scoped(new TempDir("source-repo-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    auto sourceFile = buildPath(tempDir.getPath(), "source.d");
    
    std.file.write(sourceFile, "module test; void main() {}");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    
    // Store source
    auto storeResult = repo.store(sourceFile);
    Assert.isTrue(storeResult.isOk, "Store should succeed");
    
    auto ref_ = storeResult.unwrap();
    Assert.isTrue(ref_.isValid(), "Stored ref should be valid");
    
    // Fetch source
    auto fetchResult = repo.fetch(ref_.hash);
    Assert.isTrue(fetchResult.isOk, "Fetch should succeed");
    
    auto content = cast(string)fetchResult.unwrap();
    Assert.equal(content, "module test; void main() {}");
    
    writeln("\x1b[32m  ✓ Store and fetch work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRepository - Deduplication");
    
    auto tempDir = scoped(new TempDir("source-dedup-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    
    // Create multiple files with same content
    immutable content = "Duplicate source code";
    auto file1 = buildPath(tempDir.getPath(), "dup1.d");
    auto file2 = buildPath(tempDir.getPath(), "dup2.d");
    auto file3 = buildPath(tempDir.getPath(), "dup3.d");
    
    std.file.write(file1, content);
    std.file.write(file2, content);
    std.file.write(file3, content);
    
    // Store all three
    auto ref1 = repo.store(file1).unwrap();
    auto ref2 = repo.store(file2).unwrap();
    auto ref3 = repo.store(file3).unwrap();
    
    // All should have same hash
    Assert.equal(ref1.hash, ref2.hash);
    Assert.equal(ref2.hash, ref3.hash);
    
    // Check deduplication stats
    auto stats = repo.getStats();
    Assert.equal(stats.deduplicationHits, 2, "Should have 2 deduplication hits");
    Assert.isTrue(stats.bytesSaved > 0, "Should have saved bytes from deduplication");
    
    writeln("\x1b[32m  ✓ Deduplication works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRepository - Batch operations");
    
    auto tempDir = scoped(new TempDir("source-batch-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    
    // Create multiple source files
    string[] sources;
    foreach (i; 0 .. 10)
    {
        auto file = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(file, "module file" ~ i.to!string ~ ";");
        sources ~= file;
    }
    
    // Store batch
    auto result = repo.storeBatch(sources);
    Assert.isTrue(result.isOk, "Batch store should succeed");
    
    auto refSet = result.unwrap();
    Assert.equal(refSet.length, 10, "Should have 10 refs");
    Assert.isFalse(refSet.empty, "RefSet should not be empty");
    
    // Verify all sources stored
    foreach (i; 0 .. 10)
    {
        auto ref_ = refSet.getByPath(sources[i]);
        Assert.isTrue(ref_ !is null, "Should find ref by path");
    }
    
    writeln("\x1b[32m  ✓ Batch operations work\x1b[0m");
}

// Test materialization
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Materialization - Basic restore");
    
    auto tempDir = scoped(new TempDir("materialize-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    auto sourceDir = buildPath(tempDir.getPath(), "source");
    auto targetDir = buildPath(tempDir.getPath(), "target");
    
    mkdirRecurse(sourceDir);
    mkdirRecurse(targetDir);
    
    // Create and store source
    auto sourceFile = buildPath(sourceDir, "code.d");
    std.file.write(sourceFile, "module code; int answer() { return 42; }");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    
    auto ref_ = repo.store(sourceFile).unwrap();
    
    // Materialize to different location
    auto targetFile = buildPath(targetDir, "code.d");
    auto matResult = repo.materialize(ref_.hash, targetFile);
    
    Assert.isTrue(matResult.isOk, "Materialization should succeed");
    Assert.isTrue(exists(targetFile), "Target file should exist");
    
    auto content = readText(targetFile);
    Assert.equal(content, "module code; int answer() { return 42; }");
    
    writeln("\x1b[32m  ✓ Basic materialization works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m WorkspaceMaterializer - Full workspace restore");
    
    auto tempDir = scoped(new TempDir("workspace-mat-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    auto sourceDir = buildPath(tempDir.getPath(), "source");
    auto workspaceDir = buildPath(tempDir.getPath(), "workspace");
    
    mkdirRecurse(sourceDir);
    
    // Create source files
    string[] sources = [
        buildPath(sourceDir, "main.d"),
        buildPath(sourceDir, "utils.d"),
        buildPath(sourceDir, "config.d")
    ];
    
    std.file.write(sources[0], "module main;");
    std.file.write(sources[1], "module utils;");
    std.file.write(sources[2], "module config;");
    
    // Store all sources
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    auto refSet = repo.storeBatch(sources).unwrap();
    
    // Create materializer
    auto materializer = new WorkspaceMaterializer(repo);
    
    // Materialize to workspace
    auto result = materializer.materialize(refSet, workspaceDir);
    Assert.isTrue(result.isOk, "Workspace materialization should succeed");
    
    auto matResult = result.unwrap();
    Assert.isTrue(matResult.success, "Should be successful");
    Assert.equal(matResult.filesProcessed, 3, "Should process 3 files");
    
    // Verify files exist
    foreach (source; sources)
    {
        auto targetPath = buildPath(workspaceDir, source);
        Assert.isTrue(exists(targetPath), "File should exist: " ~ targetPath);
    }
    
    writeln("\x1b[32m  ✓ Workspace materialization works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m WorkspaceMaterializer - Incremental update");
    
    auto tempDir = scoped(new TempDir("workspace-update-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    auto workspaceDir = buildPath(tempDir.getPath(), "workspace");
    
    mkdirRecurse(workspaceDir);
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    auto materializer = new WorkspaceMaterializer(repo);
    
    // Create initial source set
    auto file1 = buildPath(workspaceDir, "file1.d");
    auto file2 = buildPath(workspaceDir, "file2.d");
    
    std.file.write(file1, "version 1");
    std.file.write(file2, "unchanged");
    
    auto oldRefs = repo.storeBatch([file1, file2]).unwrap();
    
    // Modify file1
    std.file.write(file1, "version 2");
    auto newRefs = repo.storeBatch([file1, file2]).unwrap();
    
    // Update workspace (incremental)
    auto updateResult = materializer.update(oldRefs, newRefs, workspaceDir);
    Assert.isTrue(updateResult.isOk, "Incremental update should succeed");
    
    auto result = updateResult.unwrap();
    Assert.isTrue(result.success, "Update should be successful");
    // Only file1 should be updated
    Assert.equal(result.filesProcessed, 1, "Should only process changed file");
    
    writeln("\x1b[32m  ✓ Incremental update works\x1b[0m");
}

// Test SourceTracker integration
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceTracker - Change detection");
    
    auto tempDir = scoped(new TempDir("tracker-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    auto testFile = buildPath(tempDir.getPath(), "tracked.d");
    
    std.file.write(testFile, "initial content");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    auto tracker = new SourceTracker(repo);
    
    // Track file
    auto trackResult = tracker.track(testFile);
    Assert.isTrue(trackResult.isOk, "Tracking should succeed");
    
    auto initialRef = trackResult.unwrap();
    
    // Modify file
    import core.thread : Thread;
    import std.datetime : dur;
    Thread.sleep(dur!"msecs"(10));  // Ensure timestamp changes
    
    std.file.write(testFile, "modified content");
    
    // Detect changes
    auto changesResult = tracker.detectChanges([testFile]);
    Assert.isTrue(changesResult.isOk, "Change detection should succeed");
    
    auto changes = changesResult.unwrap();
    Assert.equal(changes.length, 1, "Should detect 1 change");
    Assert.equal(changes[0].path, testFile);
    Assert.notEqual(changes[0].newHash, changes[0].oldHash, "Hash should be different");
    
    writeln("\x1b[32m  ✓ Change detection works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRepository - Verification");
    
    auto tempDir = scoped(new TempDir("verify-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    auto testFile = buildPath(tempDir.getPath(), "verify.d");
    
    std.file.write(testFile, "original");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    
    // Store file
    repo.store(testFile);
    
    // Verify (should match)
    auto verifyResult1 = repo.verify(testFile);
    Assert.isTrue(verifyResult1.isOk && verifyResult1.unwrap(), "Should verify successfully");
    
    // Modify file
    std.file.write(testFile, "modified");
    
    // Verify (should not match)
    auto verifyResult2 = repo.verify(testFile);
    Assert.isTrue(verifyResult2.isOk && !verifyResult2.unwrap(), "Should detect modification");
    
    writeln("\x1b[32m  ✓ Verification works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRefSet - Operations");
    
    auto tempDir = scoped(new TempDir("refset-test"));
    
    SourceRefSet refSet;
    
    // Add refs
    auto file1 = buildPath(tempDir.getPath(), "file1.d");
    auto file2 = buildPath(tempDir.getPath(), "file2.d");
    
    std.file.write(file1, "content1");
    std.file.write(file2, "content2");
    
    auto ref1 = SourceRef.fromFile(file1).unwrap();
    auto ref2 = SourceRef.fromFile(file2).unwrap();
    
    refSet.add(ref1);
    refSet.add(ref2);
    
    Assert.equal(refSet.length, 2);
    Assert.isFalse(refSet.empty);
    
    // Lookup by path
    auto foundRef = refSet.getByPath(file1);
    Assert.isTrue(foundRef !is null, "Should find by path");
    Assert.equal(foundRef.hash, ref1.hash);
    
    // Lookup by hash
    auto foundByHash = refSet.getByHash(ref2.hash);
    Assert.isTrue(foundByHash !is null, "Should find by hash");
    Assert.equal(foundByHash.originalPath, file2);
    
    writeln("\x1b[32m  ✓ SourceRefSet operations work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m SourceRepository - Statistics");
    
    auto tempDir = scoped(new TempDir("stats-test"));
    auto storageDir = buildPath(tempDir.getPath(), "storage");
    
    auto cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
    auto repo = new SourceRepository(cas, storageDir);
    
    // Store multiple files, some duplicates
    auto file1 = buildPath(tempDir.getPath(), "file1.d");
    auto file2 = buildPath(tempDir.getPath(), "file2.d");
    auto file3 = buildPath(tempDir.getPath(), "file3.d");
    
    std.file.write(file1, "unique1");
    std.file.write(file2, "unique2");
    std.file.write(file3, "unique1");  // Duplicate of file1
    
    repo.store(file1);
    repo.store(file2);
    repo.store(file3);
    
    auto stats = repo.getStats();
    
    Assert.equal(stats.sourcesStored, 3, "Should track 3 stores");
    Assert.equal(stats.deduplicationHits, 1, "Should have 1 dedup hit");
    Assert.isTrue(stats.bytesSaved > 0, "Should save bytes");
    Assert.isTrue(stats.deduplicationRatio > 0, "Should have dedup ratio");
    
    writeln("\x1b[32m  ✓ Statistics tracking works\x1b[0m");
}

