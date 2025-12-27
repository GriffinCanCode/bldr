module engine.caching.incremental.ast_storage;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.stdio : File;
import std.conv : to;
import std.datetime : SysTime;
import engine.caching.incremental.ast_dependency;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Binary storage for AST cache
/// Uses efficient binary format for fast load/save
final class ASTStorage
{
    private string cacheDir;
    private static immutable string CACHE_FILE = "ast_cache.bin";
    private static immutable uint MAGIC = 0x41535443; // "ASTC"
    private static immutable ushort VERSION = 1;
    
    this(string cacheDir) @safe
    {
        this.cacheDir = cacheDir;
    }
    
    /// Load AST cache from disk
    BuildResult!(FileAST[]) load() @system
    {
        string cachePath = buildPath(cacheDir, CACHE_FILE);
        
        if (!exists(cachePath))
            return BuildResult!(FileAST[]).ok([]);
        
        try
        {
            auto file = File(cachePath, "rb");
            scope(exit) file.close();
            
            // Read header
            uint magic;
            file.rawRead((&magic)[0..1]);
            if (magic != MAGIC)
            {
                return BuildResult!(FileAST[]).err(
                    Errors.generic("Invalid AST cache format", Cache.Corrupted)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            ushort ver;
            file.rawRead((&ver)[0..1]);
            if (ver != VERSION)
            {
                return BuildResult!(FileAST[]).err(
                    Errors.generic("Unsupported AST cache version: " ~ ver.to!string, Cache.Corrupted)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            // Read entries
            uint entryCount;
            file.rawRead((&entryCount)[0..1]);
            
            FileAST[] asts;
            asts.reserve(entryCount);
            
            foreach (_; 0..entryCount)
            {
                FileAST ast;
                
                ast.filePath = readString(file);
                ast.fileHash = readString(file);
                
                long timestamp;
                file.rawRead((&timestamp)[0..1]);
                ast.timestamp = SysTime(timestamp);
                
                uint includeCount;
                file.rawRead((&includeCount)[0..1]);
                foreach (__; 0..includeCount)
                    ast.includes ~= readString(file);
                
                uint symbolCount;
                file.rawRead((&symbolCount)[0..1]);
                foreach (__; 0..symbolCount)
                {
                    ASTSymbol symbol;
                    
                    symbol.name = readString(file);
                    
                    ubyte symbolType;
                    file.rawRead((&symbolType)[0..1]);
                    symbol.type = cast(SymbolType)symbolType;
                    
                    file.rawRead((&symbol.startLine)[0..1]);
                    file.rawRead((&symbol.endLine)[0..1]);
                    
                    symbol.signature = readString(file);
                    symbol.contentHash = readString(file);
                    
                    uint depCount;
                    file.rawRead((&depCount)[0..1]);
                    foreach (___; 0..depCount)
                        symbol.dependencies ~= readString(file);
                    
                    uint typeCount;
                    file.rawRead((&typeCount)[0..1]);
                    foreach (___; 0..typeCount)
                        symbol.usedTypes ~= readString(file);
                    
                    ubyte isPublic;
                    file.rawRead((&isPublic)[0..1]);
                    symbol.isPublic = (isPublic != 0);
                    
                    ast.symbols ~= symbol;
                }
                
                asts ~= ast;
            }
            
            return BuildResult!(FileAST[]).ok(asts);
        }
        catch (Exception e)
        {
            return BuildResult!(FileAST[]).err(
                Errors.generic("Failed to load AST cache: " ~ e.msg, Cache.LoadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Save AST cache to disk
    BuildResult!bool save(FileAST[] asts) @system
    {
        string cachePath = buildPath(cacheDir, CACHE_FILE);
        
        try
        {
            auto file = File(cachePath, "wb");
            scope(exit) file.close();
            
            // Write header
            uint magic = MAGIC;
            file.rawWrite((&magic)[0..1]);
            
            ushort ver = VERSION;
            file.rawWrite((&ver)[0..1]);
            
            // Write entries
            uint entryCount = cast(uint)asts.length;
            file.rawWrite((&entryCount)[0..1]);
            
            foreach (ref ast; asts)
            {
                writeString(file, ast.filePath);
                writeString(file, ast.fileHash);
                
                long timestamp = ast.timestamp.stdTime;
                file.rawWrite((&timestamp)[0..1]);
                
                uint includeCount = cast(uint)ast.includes.length;
                file.rawWrite((&includeCount)[0..1]);
                foreach (include; ast.includes)
                    writeString(file, include);
                
                uint symbolCount = cast(uint)ast.symbols.length;
                file.rawWrite((&symbolCount)[0..1]);
                
                foreach (ref symbol; ast.symbols)
                {
                    writeString(file, symbol.name);
                    
                    ubyte symbolType = cast(ubyte)symbol.type;
                    file.rawWrite((&symbolType)[0..1]);
                    
                    file.rawWrite((&symbol.startLine)[0..1]);
                    file.rawWrite((&symbol.endLine)[0..1]);
                    
                    writeString(file, symbol.signature);
                    writeString(file, symbol.contentHash);
                    
                    uint depCount = cast(uint)symbol.dependencies.length;
                    file.rawWrite((&depCount)[0..1]);
                    foreach (dep; symbol.dependencies)
                        writeString(file, dep);
                    
                    uint typeCount = cast(uint)symbol.usedTypes.length;
                    file.rawWrite((&typeCount)[0..1]);
                    foreach (type; symbol.usedTypes)
                        writeString(file, type);
                    
                    ubyte isPublic = symbol.isPublic ? 1 : 0;
                    file.rawWrite((&isPublic)[0..1]);
                }
            }
            
            return Ok!(bool, BuildError)(true);
        }
        catch (Exception e)
        {
            return Err!(bool, BuildError)(
                Errors.generic("Failed to save AST cache: " ~ e.msg, Cache.SaveFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    private static string readString(File file) @system
    {
        uint length;
        file.rawRead((&length)[0..1]);
        
        if (length == 0)
            return "";
        
        auto buffer = new char[length];
        file.rawRead(buffer);
        return buffer.idup;
    }
    
    private static void writeString(File file, string str) @system
    {
        uint length = cast(uint)str.length;
        file.rawWrite((&length)[0..1]);
        
        if (length > 0)
            file.rawWrite(str);
    }
}

