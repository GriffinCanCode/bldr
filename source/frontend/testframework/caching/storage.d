module frontend.testframework.caching.storage;

import std.stdio : File;
import std.file : exists, remove;
import frontend.testframework.results : TestResult, TestCase;
import std.datetime : SysTime, Duration;
import infrastructure.errors : Errors, Cache;

/// Test cache entry for serialization
struct TestCacheEntry
{
    string testId;
    string contentHash;
    string envHash;
    TestResult result;
    SysTime timestamp;
    Duration duration;
}

/// Test cache storage utility
struct TestCacheStorage
{
    /// Save cache entries to file
    static void save(string filename, TestCacheEntry[string] entries) @system
    {
        auto file = File(filename, "wb");
        
        // Write version header
        uint version_ = 1;
        file.rawWrite([version_]);
        
        // Write entry count
        size_t count = entries.length;
        file.rawWrite([count]);
        
        // Write each entry
        foreach (key, entry; entries)
        {
            // Write key length and key
            size_t keyLen = key.length;
            file.rawWrite([keyLen]);
            file.rawWrite(cast(const ubyte[])key);
            
            // Write entry fields
            writeString(file, entry.testId);
            writeString(file, entry.contentHash);
            writeString(file, entry.envHash);
            writeTestResult(file, entry.result);
            writeSysTime(file, entry.timestamp);
            writeDuration(file, entry.duration);
        }
        
        file.close();
    }
    
    /// Load cache entries from file
    static TestCacheEntry[string] load(string filename) @system
    {
        if (!exists(filename))
            return null;
        
        TestCacheEntry[string] entries;
        auto file = File(filename, "rb");
        
        // Read version
        uint[1] versionBuf;
        file.rawRead(versionBuf);
        uint version_ = versionBuf[0];
        
        if (version_ != 1)
            throw Errors.cache("Unsupported test cache version", Cache.Corrupted)
                .withSuggestion("Test cache was created by incompatible version")
                .withCommand("Clear cache", "bldr clean --cache").build();
        
        // Read entry count
        size_t[1] countBuf;
        file.rawRead(countBuf);
        size_t count = countBuf[0];
        
        // Read each entry
        for (size_t i = 0; i < count; i++)
        {
            // Read key
            size_t[1] keyLenBuf;
            file.rawRead(keyLenBuf);
            size_t keyLen = keyLenBuf[0];
            
            auto keyBuf = new ubyte[keyLen];
            file.rawRead(keyBuf);
            string key = cast(string)keyBuf;
            
            // Read entry
            TestCacheEntry entry;
            entry.testId = readString(file);
            entry.contentHash = readString(file);
            entry.envHash = readString(file);
            entry.result = readTestResult(file);
            entry.timestamp = readSysTime(file);
            entry.duration = readDuration(file);
            
            entries[key] = entry;
        }
        
        file.close();
        return entries;
    }
    
    private static void writeString(ref File file, string str) @system
    {
        size_t len = str.length;
        file.rawWrite([len]);
        if (len > 0)
            file.rawWrite(cast(const ubyte[])str);
    }
    
    private static string readString(ref File file) @system
    {
        size_t[1] lenBuf;
        file.rawRead(lenBuf);
        size_t len = lenBuf[0];
        
        if (len == 0)
            return "";
        
        auto buf = new ubyte[len];
        file.rawRead(buf);
        return cast(string)buf;
    }
    
    private static void writeTestResult(ref File file, TestResult result) @system
    {
        // Write simple fields
        file.rawWrite([result.passed]);
        // TestResult doesn't have a message field, write empty string
        writeString(file, "");
        file.rawWrite([result.duration.total!"msecs"()]);
    }
    
    private static TestResult readTestResult(ref File file) @system
    {
        import std.datetime : msecs;
        
        TestResult result;
        
        bool[1] passedBuf;
        file.rawRead(passedBuf);
        result.passed = passedBuf[0];
        
        // Read message (but TestResult doesn't have it, so ignore)
        readString(file);
        
        long[1] durationBuf;
        file.rawRead(durationBuf);
        result.duration = msecs(durationBuf[0]);
        
        return result;
    }
    
    private static void writeSysTime(ref File file, SysTime time) @system
    {
        long stdTime = time.stdTime();
        file.rawWrite([stdTime]);
    }
    
    private static SysTime readSysTime(ref File file) @system
    {
        long[1] buf;
        file.rawRead(buf);
        return SysTime(buf[0]);
    }
    
    private static void writeDuration(ref File file, Duration dur) @system
    {
        long hnsecs = dur.total!"hnsecs"();
        file.rawWrite([hnsecs]);
    }
    
    private static Duration readDuration(ref File file) @system
    {
        import std.datetime : hnsecs;
        
        long[1] buf;
        file.rawRead(buf);
        return hnsecs(buf[0]);
    }
}
