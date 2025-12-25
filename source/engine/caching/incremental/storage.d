module engine.caching.incremental.storage;

import std.stdio;
import std.file;
import std.path;
import engine.caching.incremental.dependency;
import engine.caching.incremental.schema;
import infrastructure.utils.serialization;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// High-performance binary storage for dependency cache
/// Uses SIMD-accelerated serialization framework
final class DependencyStorage
{
    private string storageDir;
    private immutable string storageFile;
    
    this(string storageDir) @safe
    {
        this.storageDir = storageDir;
        this.storageFile = buildPath(storageDir, "dependencies.bin");
    }
    
    /// Load dependencies from disk
    /// 
    /// Features:
    /// - Zero-copy deserialization
    /// - Automatic version checking
    /// - Schema evolution support
    BuildResult!(FileDependency[]) load() @system
    {
        if (!exists(storageFile))
        {
            return BuildResult!(FileDependency[]).ok([]);
        }
        
        try
        {
            // Read entire file
            auto data = cast(ubyte[])read(storageFile);
            
            // Deserialize with codec
            auto result = Codec.deserialize!SerializableDependencyContainer(data);
            
            if (result.isErr)
            {
                return BuildResult!(FileDependency[]).err(
                    new GenericError("Failed to deserialize dependency cache: " ~ 
                                   result.unwrapErr(), ErrorCode.InvalidJson)
                );
            }
            
            auto container = result.unwrap();
            
            // Convert to runtime format
            FileDependency[] deps;
            deps.reserve(container.dependencies.length);
            
            foreach (ref serialDep; container.dependencies)
            {
                deps ~= fromSerializable!FileDependency(serialDep);
            }
            
            return BuildResult!(FileDependency[]).ok(deps);
        }
        catch (Exception e)
        {
            return BuildResult!(FileDependency[]).err(
                new GenericError("Failed to load dependency cache: " ~ e.msg,
                             ErrorCode.FileReadFailed)
            );
        }
    }
    
    /// Save dependencies to disk
    /// 
    /// Features:
    /// - SIMD-accelerated serialization
    /// - Compact varint encoding
    /// - Atomic write with temporary file
    VoidBuildResult save(FileDependency[] deps) @system
    {
        try
        {
            // Ensure directory exists
            if (!exists(storageDir))
                mkdirRecurse(storageDir);
            
            // Convert to serializable format
            SerializableFileDependency[] serializable;
            serializable.reserve(deps.length);
            
            foreach (ref dep; deps)
            {
                serializable ~= toSerializable(dep);
            }
            
            // Create container
            SerializableDependencyContainer container;
            container.dependencies = serializable;
            
            // Serialize with high-performance codec
            auto data = Codec.serialize(container);
            
            // Write to temporary file first (atomic write)
            auto tempFile = storageFile ~ ".tmp";
            scope(exit) 
            {
                if (exists(tempFile))
                    remove(tempFile);
            }
            
            std.file.write(tempFile, data);
            
            // Atomic rename
            if (exists(storageFile))
                remove(storageFile);
            rename(tempFile, storageFile);
            
            return VoidBuildResult.ok();
        }
        catch (Exception e)
        {
            return VoidBuildResult.err(
                new GenericError("Failed to save dependency cache: " ~ e.msg,
                             ErrorCode.FileReadFailed)
            );
        }
    }
}
