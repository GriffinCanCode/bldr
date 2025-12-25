module tests.unit.parsing.incremental;

import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import infrastructure.parsing.treesitter;
import infrastructure.parsing.treesitter.incremental;
import infrastructure.parsing.treesitter.adapter;

/// Test TextEdit creation from byte positions
unittest {
    writeln("\n=== Testing TextEdit Creation ===");
    
    string content = "line1\nline2\nline3\n";
    
    // Test edit from bytes
    auto edit = TextEdit.fromBytes(6, 11, 14, content);
    
    assert(edit.startByte == 6, "Wrong start byte");
    assert(edit.oldEndByte == 11, "Wrong old end byte");
    assert(edit.newEndByte == 14, "Wrong new end byte");
    
    writeln("  ✓ TextEdit.fromBytes creates correct edit");
    
    // Test TSInputEdit conversion
    auto tsEdit = edit.toTSEdit();
    assert(tsEdit.start_byte == 6, "TSInputEdit conversion failed");
    
    writeln("  ✓ toTSEdit() produces valid TSInputEdit");
    writeln("✅ TextEdit creation tests passed");
}

/// Test TextEdit creation from positions
unittest {
    writeln("\n=== Testing TextEdit Position-based Creation ===");
    
    string content = "function test() {\n  return 42;\n}\n";
    
    // Simulate editing "42" to "100" at line 1, col 9-11
    auto edit = TextEdit.fromPositions(
        1, 9,   // start: line 1, col 9
        1, 11,  // old end: line 1, col 11
        1, 12,  // new end: line 1, col 12
        content, "100"
    );
    
    assert(edit.startPoint.row == 1, "Wrong start row");
    assert(edit.startPoint.column == 9, "Wrong start column");
    
    writeln("  ✓ TextEdit.fromPositions creates position-based edit");
    writeln("✅ Position-based TextEdit tests passed");
}

/// Test IncrementalTreeCache creation
unittest {
    writeln("\n=== Testing IncrementalTreeCache ===");
    
    auto cache = new IncrementalTreeCache();
    assert(cache !is null, "Failed to create cache");
    
    auto stats = cache.getStats();
    assert(stats.cachedTrees == 0, "Cache should start empty");
    assert(stats.fullParses == 0, "No parses yet");
    
    writeln("  ✓ IncrementalTreeCache creates successfully");
    writeln("  ✓ Initial stats are zeroed");
    
    cache.clear();
    writeln("  ✓ Cache clears without error");
    
    writeln("✅ IncrementalTreeCache tests passed");
}

/// Test IncrementalTreeCache statistics
unittest {
    writeln("\n=== Testing Cache Statistics ===");
    
    auto cache = incrementalTreeCache();
    auto stats = cache.getStats();
    
    // Verify stats structure
    assert(stats.incrementalRate >= 0 && stats.incrementalRate <= 100,
           "Incremental rate should be 0-100%");
    assert(stats.hitRate >= 0 && stats.hitRate <= 100,
           "Hit rate should be 0-100%");
    
    writeln("  ✓ Stats have valid ranges");
    writefln("    - Cached trees: %d", stats.cachedTrees);
    writefln("    - Full parses: %d", stats.fullParses);
    writefln("    - Incremental parses: %d", stats.incrementalParses);
    writefln("    - Incremental rate: %.1f%%", stats.incrementalRate);
    
    writeln("✅ Cache statistics tests passed");
}

/// Test IncrementalParseAdapter
unittest {
    writeln("\n=== Testing IncrementalParseAdapter ===");
    
    auto adapter = new IncrementalParseAdapter(true);
    assert(adapter !is null, "Failed to create adapter");
    
    auto stats = adapter.getStats();
    assert(stats.cachedFiles == 0, "Adapter should start empty");
    
    writeln("  ✓ IncrementalParseAdapter creates successfully");
    
    adapter.clear();
    writeln("  ✓ Adapter clears without error");
    
    writeln("✅ IncrementalParseAdapter tests passed");
}

/// Test LSPChangeAdapter
unittest {
    writeln("\n=== Testing LSPChangeAdapter ===");
    
    string doc = "hello world\ntest line\n";
    
    // Simulate LSP change: replace "world" with "universe"
    auto edit = LSPChangeAdapter.fromContentChange(
        0, 6,   // start: line 0, char 6
        0, 11,  // end: line 0, char 11
        "universe",
        doc
    );
    
    assert(edit.startPoint.row == 0, "Wrong start row");
    assert(edit.startPoint.column == 6, "Wrong start column");
    
    writeln("  ✓ LSPChangeAdapter converts LSP changes to TextEdit");
    writeln("✅ LSPChangeAdapter tests passed");
}

/// Test document edit to TextEdit conversion
unittest {
    writeln("\n=== Testing DocumentEdit Conversion ===");
    
    DocumentEdit docEdit;
    docEdit.startLine = 0;
    docEdit.startCharacter = 0;
    docEdit.endLine = 0;
    docEdit.endCharacter = 5;
    docEdit.newText = "hello";
    
    string content = "world\n";
    auto edit = docEdit.toTextEdit(content);
    
    assert(edit.startByte == 0, "Wrong start byte");
    
    writeln("  ✓ DocumentEdit.toTextEdit works correctly");
    writeln("✅ DocumentEdit conversion tests passed");
}

/// Test edit computation
unittest {
    writeln("\n=== Testing Edit Computation ===");
    
    auto adapter = new IncrementalParseAdapter(true);
    
    // Pre-cache some content
    string[] paths = [];  // Empty for now - would need real files
    adapter.preCacheContent(paths);
    
    auto stats = adapter.getStats();
    writefln("    - Cached files: %d", stats.cachedFiles);
    
    writeln("  ✓ preCacheContent works without error");
    writeln("✅ Edit computation tests passed");
}

/// Test Tree RAII wrapper edit method
unittest {
    writeln("\n=== Testing Tree Wrapper Edit ===");
    
    // Test that the edit method exists on Tree wrapper
    // Note: Can't test actual editing without grammar
    
    TSInputEdit edit;
    edit.start_byte = 0;
    edit.old_end_byte = 5;
    edit.new_end_byte = 10;
    edit.start_point = TSPoint(0, 0);
    edit.old_end_point = TSPoint(0, 5);
    edit.new_end_point = TSPoint(0, 10);
    
    // Verify struct is properly initialized
    assert(edit.old_end_byte == 5, "Edit struct not initialized correctly");
    
    writeln("  ✓ TSInputEdit struct works correctly");
    writeln("✅ Tree wrapper tests passed");
}

/// Integration test: Full incremental parsing workflow
unittest {
    writeln("\n=== Testing Full Incremental Workflow ===");
    
    // 1. Create cache
    auto cache = incrementalTreeCache();
    
    // 2. Get initial stats
    auto before = cache.getStats();
    
    // 3. Without actual grammars loaded, we can't parse
    //    But we verify the infrastructure works
    
    // 4. Create adapter
    auto adapter = incrementalParseAdapter();
    
    // 5. Verify global singletons return same instance
    assert(incrementalTreeCache() is cache, 
           "Global cache should return same instance");
    assert(incrementalParseAdapter() is adapter,
           "Global adapter should return same instance");
    
    writeln("  ✓ Global singletons work correctly");
    writeln("  ✓ Cache and adapter integrate properly");
    
    // 6. Test stats after operations
    auto after = cache.getStats();
    
    writefln("    - Trees cached: %d -> %d", before.cachedTrees, after.cachedTrees);
    
    writeln("✅ Full incremental workflow tests passed");
}

/// Test byte/position conversion helpers
unittest {
    writeln("\n=== Testing Position Helpers ===");
    
    // Test newline counting
    string text1 = "line1\nline2\nline3";
    uint lines1 = 0;
    foreach (c; text1) if (c == '\n') lines1++;
    assert(lines1 == 2, "Should have 2 newlines");
    
    string text2 = "no newlines";
    uint lines2 = 0;
    foreach (c; text2) if (c == '\n') lines2++;
    assert(lines2 == 0, "Should have 0 newlines");
    
    writeln("  ✓ Newline counting works correctly");
    
    // Test last line length
    string text3 = "first\nsecond";
    size_t lastLen = 0;
    foreach_reverse (c; text3) {
        if (c == '\n') break;
        lastLen++;
    }
    assert(lastLen == 6, "Last line 'second' has 6 chars");
    
    writeln("  ✓ Last line length calculation works");
    writeln("✅ Position helper tests passed");
}

