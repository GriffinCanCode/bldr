module tests.fixtures;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import infrastructure.config.schema.schema;

/// Base fixture interface
interface Fixture
{
    void setup();
    void teardown();
}

/// Temporary directory fixture
class TempDir : Fixture
{
    private string path;
    
    this(string prefix = "builder-test")
    {
        import std.random : uniform;
        auto suffix = uniform(10000, 99999);
        path = buildPath(tempDir(), prefix ~ "-" ~ suffix.to!string);
    }
    
    void setup()
    {
        if (!exists(path))
            mkdirRecurse(path);
    }
    
    void teardown()
    {
        if (exists(path))
            rmdirRecurse(path);
    }
    
    string getPath() const
    {
        return path;
    }
    
    /// Create a file in the temp directory
    void createFile(string relativePath, string content = "")
    {
        auto fullPath = buildPath(path, relativePath);
        auto dir = dirName(fullPath);
        if (!exists(dir))
            mkdirRecurse(dir);
        std.file.write(fullPath, content);
    }
    
    /// Create a directory in the temp directory
    void createDir(string relativePath)
    {
        auto fullPath = buildPath(path, relativePath);
        if (!exists(fullPath))
            mkdirRecurse(fullPath);
    }
    
    /// Check if file exists
    bool hasFile(string relativePath) const
    {
        return exists(buildPath(path, relativePath));
    }
    
    /// Read file content
    string readFile(string relativePath) const
    {
        return cast(string)read(buildPath(path, relativePath));
    }
}

/// Mock workspace configuration
class MockWorkspace : Fixture
{
    private TempDir tempDir;
    private string workspacePath;
    
    this()
    {
        tempDir = new TempDir("mock-workspace");
    }
    
    void setup()
    {
        tempDir.setup();
        workspacePath = tempDir.getPath();
    }
    
    void teardown()
    {
        tempDir.teardown();
    }
    
    string getPath() const
    {
        return workspacePath;
    }
    
    /// Create a mock target with Builderfile
    void createTarget(string name, TargetType type, string[] sources, string[] deps = [])
    {
        import std.array : join;
        
        auto targetPath = buildPath(workspacePath, name);
        if (!exists(targetPath))
            mkdirRecurse(targetPath);
        
        // Create Builderfile in DSL format
        string builderfileContent = "// Auto-generated Builderfile\n\n";
        builderfileContent ~= "target(\"" ~ name ~ "\") {\n";
        builderfileContent ~= "    type: " ~ type.to!string.toLower ~ ";\n";
        
        // Add sources
        builderfileContent ~= "    sources: [";
        foreach (i, src; sources)
        {
            builderfileContent ~= "\"" ~ src ~ "\"";
            if (i < sources.length - 1)
                builderfileContent ~= ", ";
        }
        builderfileContent ~= "];\n";
        
        // Add deps if any
        if (deps.length > 0)
        {
            builderfileContent ~= "    deps: [";
            foreach (i, dep; deps)
            {
                builderfileContent ~= "\"" ~ dep ~ "\"";
                if (i < deps.length - 1)
                    builderfileContent ~= ", ";
            }
            builderfileContent ~= "];\n";
        }
        
        builderfileContent ~= "}\n";
        
        auto buildFile = buildPath(targetPath, "Builderfile");
        std.file.write(buildFile, builderfileContent);
        
        // Create source files
        foreach (src; sources)
        {
            auto srcPath = buildPath(targetPath, src);
            auto dir = dirName(srcPath);
            if (!exists(dir))
                mkdirRecurse(dir);
            
            // Create minimal valid source file
            string content = getMinimalSourceContent(src);
            std.file.write(srcPath, content);
        }
    }
    
    /// Get minimal valid source content for a file
    private string getMinimalSourceContent(string filename)
    {
        auto ext = extension(filename);
        
        switch (ext)
        {
            case ".py":
                return "# Python source\npass\n";
            case ".js":
                return "// JavaScript source\n";
            case ".ts":
                return "// TypeScript source\n";
            case ".go":
                return "package main\n\nfunc main() {}\n";
            case ".rs":
                return "fn main() {}\n";
            case ".d":
                return "void main() {}\n";
            default:
                return "// Source file\n";
        }
    }
}

/// Test data builder for complex objects
struct TargetBuilder
{
    private Target target;
    
    static TargetBuilder create(string name)
    {
        TargetBuilder builder;
        builder.target.name = name;
        builder.target.type = TargetType.Executable;
        return builder;
    }
    
    TargetBuilder withType(TargetType type)
    {
        target.type = type;
        return this;
    }
    
    TargetBuilder withSources(string[] sources)
    {
        target.sources = sources;
        return this;
    }
    
    TargetBuilder withDeps(string[] deps)
    {
        target.deps = deps;
        return this;
    }
    
    TargetBuilder withOutputs(string[] outputs)
    {
        if (outputs.length > 0)
            target.outputPath = outputs[0];
        return this;
    }

    TargetBuilder withCommand(string cmd)
    {
        target.langConfig["command"] = cmd;
        return this;
    }
    
    TargetBuilder withLanguage(string lang)
    {
        target.language = lang.to!TargetLanguage;
        return this;
    }
    
    Target build()
    {
        return target;
    }
}

/// Fixture manager for automatic setup/teardown
class FixtureManager
{
    private Fixture[] fixtures;
    
    /// Register a fixture
    void register(Fixture fixture)
    {
        fixtures ~= fixture;
    }
    
    /// Setup all fixtures
    void setupAll()
    {
        foreach (fixture; fixtures)
            fixture.setup();
    }
    
    /// Teardown all fixtures in reverse order
    void teardownAll()
    {
        foreach_reverse (fixture; fixtures)
            fixture.teardown();
    }
}

/// RAII fixture wrapper
struct ScopedFixture(F : Fixture)
{
    private F fixture;
    
    this(F f)
    {
        fixture = f;
        fixture.setup();
    }
    
    ~this()
    {
        fixture.teardown();
    }
    
    F get()
    {
        return fixture;
    }
    
    alias get this;
}

/// Helper to create scoped fixtures
auto scoped(F : Fixture)(F fixture)
{
    return ScopedFixture!F(fixture);
}

