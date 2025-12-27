module infrastructure.utils.files.ignore;

import std.algorithm;
import std.array;
import std.path;
import std.string;
import std.file;
import std.stdio;
import infrastructure.config.schema.schema : TargetLanguage;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Language-specific dependency and build directories that should be ignored during scanning
/// to avoid performance issues and false positives
struct IgnorePatterns
{
    /// Directory names to ignore (exact match)
    string[] directories;
    
    /// Directory prefixes to ignore (for patterns like cmake-build-*)
    string[] prefixes;
    
    /// File patterns to ignore (for glob-like matching)
    string[] patterns;
}

/// Centralized ignore pattern registry for all supported languages
/// 
/// PROBLEM LANGUAGES (have large dependency directories that cause major issues):
/// - JavaScript/TypeScript: node_modules can have millions of files
/// - Python: venv/virtualenv contain entire Python installations
/// - Ruby: vendor/bundle contains all gems
/// - PHP: vendor contains all Composer packages
/// - Rust: target directory contains all build artifacts
/// - Java/Kotlin/Scala: target/build + .gradle/.m2 caches
/// - C#/F#: bin/obj + packages directories
/// - Elixir: deps + _build
/// - R: renv/packrat package libraries
class IgnoreRegistry
{
    private static immutable IgnorePatterns[TargetLanguage] languageIgnores;
    private static immutable string[] commonIgnores;
    private static immutable string[] vcsIgnores;
    
    /// Static constructor: Initialize immutable ignore patterns
    /// 
    /// Safety: This static constructor is @system because:
    /// 1. Initializes immutable static data once at program start
    /// 2. Array literal initialization is memory-safe
    /// 3. Associative array initialization with enum keys is type-safe
    /// 4. No unsafe operations, just data initialization
    /// 
    /// Invariants:
    /// - Static data is immutable after initialization
    /// - Executed once before any other code runs
    /// 
    /// What could go wrong:
    /// - Nothing: pure data initialization with no side effects
    @system
    shared static this()
    {
        // Version control system directories - ALWAYS ignore
        vcsIgnores = [".git", ".svn", ".hg", ".bzr"];
        
        // Common ignore patterns across all projects
        commonIgnores = [
            ".builder-cache",  // Builder's own cache
            ".cache",          // Generic cache directory
            "tmp",             // Temporary files
            "temp",
            ".tmp",
            ".DS_Store",       // macOS metadata
            "Thumbs.db",       // Windows thumbnails
        ];
        
        // Language-specific ignore patterns
        languageIgnores = [
            // JavaScript/TypeScript - MAJOR PROBLEM
            TargetLanguage.JavaScript: IgnorePatterns(
                ["node_modules", "bower_components", ".npm", ".yarn", 
                 ".pnp", ".pnp.js", "jspm_packages", "dist", "build", 
                 ".next", ".nuxt", ".vuepress/dist", "out", ".cache"],
                ["npm-debug", "yarn-debug", "yarn-error"],
                []
            ),
            TargetLanguage.TypeScript: IgnorePatterns(
                ["node_modules", "bower_components", ".npm", ".yarn",
                 ".pnp", ".pnp.js", "jspm_packages", "dist", "build",
                 ".next", ".nuxt", ".vuepress/dist", "out", ".tsbuildinfo"],
                ["npm-debug", "yarn-debug", "yarn-error"],
                []
            ),
            
            // Python - MAJOR PROBLEM
            TargetLanguage.Python: IgnorePatterns(
                ["venv", ".venv", "env", ".env", "ENV", "env.bak", "venv.bak",
                 "__pycache__", ".pytest_cache", ".tox", ".coverage", 
                 ".hypothesis", ".eggs", "*.egg-info", "dist", "build",
                 "site-packages", ".mypy_cache", ".pytype", ".ruff_cache",
                 "htmlcov", ".nox", ".Python"],
                ["pip-log"],
                ["*.pyc", "*.pyo", "*.pyd", ".Python"]
            ),
            
            // Ruby - PROBLEM
            TargetLanguage.Ruby: IgnorePatterns(
                ["vendor/bundle", ".bundle", "tmp", "log", "coverage",
                 ".yardoc", "doc", "pkg"],
                [],
                ["*.gem", "*.rbc"]
            ),
            
            // PHP - PROBLEM
            TargetLanguage.PHP: IgnorePatterns(
                ["vendor", "node_modules"],
                [],
                []
            ),
            
            // Rust - MAJOR PROBLEM
            TargetLanguage.Rust: IgnorePatterns(
                ["target", "Cargo.lock"],
                [],
                []
            ),
            
            // Go - MODERATE PROBLEM
            TargetLanguage.Go: IgnorePatterns(
                ["vendor", "bin", "pkg"],
                [],
                []
            ),
            
            // Java - MAJOR PROBLEM
            TargetLanguage.Java: IgnorePatterns(
                ["target", "build", ".gradle", ".mvn", ".m2",
                 "bin", "out", ".idea", ".settings", ".classpath",
                 ".project"],
                [],
                ["*.class", "*.jar", "*.war", "*.ear"]
            ),
            
            // Kotlin - MAJOR PROBLEM (uses same tools as Java)
            TargetLanguage.Kotlin: IgnorePatterns(
                ["target", "build", ".gradle", ".mvn", ".m2",
                 "bin", "out", ".idea", ".kotlin"],
                [],
                ["*.class"]
            ),
            
            // Scala - MAJOR PROBLEM
            TargetLanguage.Scala: IgnorePatterns(
                ["target", "build", "project/target", "project/project",
                 ".bloop", ".metals", ".bsp", ".idea"],
                [],
                ["*.class"]
            ),
            
            // C# - MAJOR PROBLEM
            TargetLanguage.CSharp: IgnorePatterns(
                ["bin", "obj", "packages", ".vs", ".vscode",
                 "*.user", "*.suo", "TestResults", "artifacts",
                 ".nuget"],
                [],
                ["*.dll", "*.pdb", "*.exe"]
            ),
            
            // F# - MAJOR PROBLEM
            TargetLanguage.FSharp: IgnorePatterns(
                ["bin", "obj", "packages", ".vs", ".vscode",
                 "*.user", "*.suo", "TestResults", "artifacts",
                 ".nuget", "paket-files", ".paket", ".fake"],
                [],
                ["*.dll", "*.pdb", "*.exe"]
            ),
            
            // Elixir - PROBLEM
            TargetLanguage.Elixir: IgnorePatterns(
                ["deps", "_build", ".elixir_ls", ".hex",
                 "doc", "cover", "erl_crash.dump"],
                [],
                ["*.ez", "*.beam"]
            ),
            
            // Nim - MODERATE PROBLEM
            TargetLanguage.Nim: IgnorePatterns(
                ["nimcache", "nimblecache", ".nimble"],
                [],
                []
            ),
            
            // D - MODERATE PROBLEM
            TargetLanguage.D: IgnorePatterns(
                [".dub", "dub.selections.json", "docs.json", "__dummy.html",
                 "docs", "*.so", "*.dylib", "*.dll", "*.a", "*.lib", "*.exe"],
                ["*.exe."],
                ["*.o", "*.obj", "*.lst"]
            ),
            
            // Swift - MODERATE PROBLEM
            TargetLanguage.Swift: IgnorePatterns(
                [".build", ".swiftpm", "Packages", "xcuserdata",
                 ".DS_Store", "DerivedData"],
                [],
                []
            ),
            
            // R - PROBLEM
            TargetLanguage.R: IgnorePatterns(
                ["renv", "packrat", ".Rproj.user", ".Rhistory",
                 ".RData", ".Ruserdata"],
                [],
                ["*.Rproj"]
            ),
            
            // Lua - MINIMAL PROBLEM
            TargetLanguage.Lua: IgnorePatterns(
                ["lua_modules", "luarocks"],
                [],
                []
            ),
            
            // C/C++ - MODERATE PROBLEM
            TargetLanguage.C: IgnorePatterns(
                ["build", ".cmake", "CMakeFiles", "Debug", "Release",
                 "x64", "x86"],
                ["cmake-build-"],
                ["*.o", "*.obj", "*.a", "*.lib", "*.so", "*.dylib", "*.dll"]
            ),
            TargetLanguage.Cpp: IgnorePatterns(
                ["build", ".cmake", "CMakeFiles", "Debug", "Release",
                 "x64", "x86", ".ccls-cache", ".clangd"],
                ["cmake-build-"],
                ["*.o", "*.obj", "*.a", "*.lib", "*.so", "*.dylib", "*.dll"]
            ),
            
            // Zig - MINIMAL PROBLEM (uses global cache)
            TargetLanguage.Zig: IgnorePatterns(
                ["zig-cache", "zig-out"],
                [],
                []
            ),
            
            // CSS - NO PROBLEM
            TargetLanguage.CSS: IgnorePatterns(
                ["node_modules", ".sass-cache"],
                [],
                []
            ),
        ];
    }
    
    /// Get ignore patterns for a specific language
    static IgnorePatterns getPatternsForLanguage(TargetLanguage lang)
    {
        if (lang in languageIgnores)
        {
            // Cast from immutable to mutable for return
            auto patterns = languageIgnores[lang];
            return IgnorePatterns(
                patterns.directories.dup,
                patterns.prefixes.dup,
                patterns.patterns.dup
            );
        }
        return IgnorePatterns([], [], []);
    }
    
    /// Check if a directory/file should be ignored
    /// SIMD-accelerated string comparisons for faster scanning
    static bool shouldIgnore(string name, TargetLanguage lang = TargetLanguage.Generic) @trusted
    {
        immutable baseName = name.baseName;
        
        // Always ignore VCS directories (SIMD linear search)
        foreach (vcs; vcsIgnores)
            if (SIMDStrings.equal(baseName, vcs))
                return true;
        
        // Check common ignores
        foreach (common; commonIgnores)
            if (SIMDStrings.equal(baseName, common))
                return true;
        
        // Check language-specific ignores
        if (lang in languageIgnores)
        {
            auto patterns = languageIgnores[lang];
            
            // First check if the full name/path matches (for patterns like "vendor/bundle")
            foreach (dir; patterns.directories)
                if (SIMDStrings.equal(name, dir))
                    return true;
            
            // Then check basename for simple patterns
            foreach (dir; patterns.directories)
                if (SIMDStrings.equal(baseName, dir))
                    return true;
            
            // Check prefixes (SIMD prefix matching)
            foreach (prefix; patterns.prefixes)
                if (SIMDStrings.startsWith(baseName, prefix))
                    return true;
        }
        
        return false;
    }
    
    /// Check if a path should be ignored
    static bool shouldIgnorePath(string path, TargetLanguage lang = TargetLanguage.Generic)
    {
        // Check each component of the path
        import std.path : pathSplitter;
        foreach (component; path.pathSplitter)
        {
            if (shouldIgnore(component, lang))
                return true;
        }
        return false;
    }
    
    /// Check if a directory should be ignored (exact match)
    /// SIMD-accelerated for faster directory filtering
    static bool shouldIgnoreDirectory(string dirName, TargetLanguage lang = TargetLanguage.Generic) @trusted
    {
        immutable baseName = dirName.baseName;
        
        // Always ignore VCS directories
        foreach (vcs; vcsIgnores)
            if (SIMDStrings.equal(baseName, vcs))
                return true;
        
        // Check common ignores
        foreach (common; commonIgnores)
            if (SIMDStrings.equal(baseName, common))
                return true;
        
        // Check language-specific ignores
        if (lang != TargetLanguage.Generic && lang in languageIgnores)
        {
            auto patterns = languageIgnores[lang];
            
            // Exact directory match
            foreach (dir; patterns.directories)
                if (SIMDStrings.equal(baseName, dir))
                    return true;
            
            // Prefix match
            foreach (prefix; patterns.prefixes)
                if (SIMDStrings.startsWith(baseName, prefix))
                    return true;
        }
        
        return false;
    }
    
    /// Check if a directory should be ignored for any common language
    /// Use this when language is unknown or for general scanning
    /// SIMD-accelerated for high-throughput file scanning
    static bool shouldIgnoreDirectoryAny(string dirName) @trusted
    {
        immutable baseName = dirName.baseName;
        
        // Always ignore VCS and common
        foreach (vcs; vcsIgnores)
            if (SIMDStrings.equal(baseName, vcs))
                return true;
        foreach (common; commonIgnores)
            if (SIMDStrings.equal(baseName, common))
                return true;
        
        // Check against all language patterns
        foreach (patterns; languageIgnores)
        {
            // Check full path for patterns like "vendor/bundle"
            foreach (dir; patterns.directories)
                if (SIMDStrings.equal(dirName, dir))
                    return true;
            
            // Check basename
            foreach (dir; patterns.directories)
                if (SIMDStrings.equal(baseName, dir))
                    return true;
            
            foreach (prefix; patterns.prefixes)
                if (SIMDStrings.startsWith(baseName, prefix))
                    return true;
        }
        
        return false;
    }
    
    /// Check if a path should be ignored (checks all languages)
    /// Use this when language is unknown or for general scanning
    static bool shouldIgnorePathAny(string path)
    {
        // Check each component of the path
        import std.path : pathSplitter;
        foreach (component; path.pathSplitter)
        {
            if (shouldIgnoreDirectoryAny(component))
                return true;
        }
        return false;
    }
    
    /// Get all ignore directory names for a language
    static string[] getIgnoreDirectories(TargetLanguage lang)
    {
        string[] result = vcsIgnores.dup ~ commonIgnores.dup;
        
        if (lang in languageIgnores)
        {
            result ~= languageIgnores[lang].directories;
        }
        
        return result;
    }
    
    /// Get all ignore patterns for multiple languages
    /// Useful when a project uses multiple languages
    static string[] getIgnoreDirectoriesForLanguages(TargetLanguage[] langs)
    {
        bool[string] uniqueDirs;
        
        // Add VCS and common
        foreach (dir; vcsIgnores ~ commonIgnores)
            uniqueDirs[dir] = true;
        
        // Add language-specific
        foreach (lang; langs)
        {
            if (lang in languageIgnores)
            {
                foreach (dir; languageIgnores[lang].directories)
                    uniqueDirs[dir] = true;
            }
        }
        
        return uniqueDirs.keys;
    }
    
    /// Check if a file should be ignored based on pattern matching
    static bool shouldIgnoreFile(string filePath, TargetLanguage lang = TargetLanguage.Generic)
    {
        if (lang == TargetLanguage.Generic || lang !in languageIgnores)
            return false;
        
        immutable fileName = filePath.baseName;
        auto patterns = languageIgnores[lang];
        
        // Simple pattern matching (supports * wildcard)
        foreach (pattern; patterns.patterns)
        {
            if (simplePatternMatch(fileName, pattern))
                return true;
        }
        
        return false;
    }
    
    /// Simple wildcard pattern matching (* only)
    /// SIMD-accelerated prefix/suffix checks
    private static bool simplePatternMatch(string text, string pattern) @trusted
    {
        if (SIMDStrings.equal(pattern, "*"))
            return true;
        
        if (!pattern.canFind("*"))
            return SIMDStrings.equal(text, pattern);
        
        // Split on * and check each part
        auto parts = pattern.split("*");
        
        if (parts.length == 1)
            return SIMDStrings.equal(text, pattern);
        
        // Check prefix (SIMD accelerated)
        if (!parts[0].empty && !SIMDStrings.startsWith(text, parts[0]))
            return false;
        
        // Check suffix (SIMD accelerated)
        if (parts.length > 1 && !parts[$-1].empty && !SIMDStrings.endsWith(text, parts[$-1]))
            return false;
        
        return true;
    }
}

/// Summary of problem severity by language
enum IgnoreSeverity
{
    None,      // No dependency directories
    Low,       // Small directories, minimal impact
    Moderate,  // Can cause slowdowns
    High,      // Major performance issues
    Critical   // Can cause system hangs
}

/// Get the severity of ignore problems for a language
IgnoreSeverity getIgnoreSeverity(TargetLanguage lang)
{
    switch (lang)
    {
        // CRITICAL - millions of files possible
        case TargetLanguage.JavaScript:
        case TargetLanguage.TypeScript:
            return IgnoreSeverity.Critical;
        
        // HIGH - large directories
        case TargetLanguage.Python:
        case TargetLanguage.Rust:
        case TargetLanguage.Java:
        case TargetLanguage.Kotlin:
        case TargetLanguage.Scala:
        case TargetLanguage.CSharp:
        case TargetLanguage.FSharp:
            return IgnoreSeverity.High;
        
        // MODERATE - noticeable impact
        case TargetLanguage.Ruby:
        case TargetLanguage.PHP:
        case TargetLanguage.Go:
        case TargetLanguage.Elixir:
        case TargetLanguage.R:
        case TargetLanguage.Nim:
        case TargetLanguage.D:
        case TargetLanguage.Swift:
        case TargetLanguage.C:
        case TargetLanguage.Cpp:
            return IgnoreSeverity.Moderate;
        
        // LOW - minimal impact
        case TargetLanguage.Lua:
        case TargetLanguage.Zig:
            return IgnoreSeverity.Low;
        
        // NONE - GPU languages have their own build caches
        case TargetLanguage.CSS:
        case TargetLanguage.WebAssembly:
        case TargetLanguage.CUDA:
        case TargetLanguage.ROCm:
        case TargetLanguage.Metal:
        case TargetLanguage.Generic:
        default:
            return IgnoreSeverity.None;
    }
}

unittest
{
    import std.stdio : writeln;
    
    writeln("Testing ignore patterns...");
    
    // Test VCS ignores
    assert(IgnoreRegistry.shouldIgnoreDirectoryAny(".git"));
    assert(IgnoreRegistry.shouldIgnoreDirectoryAny(".svn"));
    
    // Test language-specific ignores
    assert(IgnoreRegistry.shouldIgnoreDirectory("node_modules", TargetLanguage.JavaScript));
    assert(IgnoreRegistry.shouldIgnoreDirectory("venv", TargetLanguage.Python));
    assert(IgnoreRegistry.shouldIgnoreDirectory("target", TargetLanguage.Rust));
    assert(IgnoreRegistry.shouldIgnoreDirectory("vendor", TargetLanguage.PHP));
    
    // Test prefix matching
    assert(IgnoreRegistry.shouldIgnoreDirectory("cmake-build-debug", TargetLanguage.Cpp));
    assert(IgnoreRegistry.shouldIgnoreDirectory("cmake-build-release", TargetLanguage.C));
    
    // Test file patterns
    assert(IgnoreRegistry.shouldIgnoreFile("test.pyc", TargetLanguage.Python));
    assert(IgnoreRegistry.shouldIgnoreFile("Main.class", TargetLanguage.Java));
    
    // Test severity
    assert(getIgnoreSeverity(TargetLanguage.JavaScript) == IgnoreSeverity.Critical);
    assert(getIgnoreSeverity(TargetLanguage.Python) == IgnoreSeverity.High);
    assert(getIgnoreSeverity(TargetLanguage.Lua) == IgnoreSeverity.Low);
    
    writeln("Ignore pattern tests passed!");
}

/// User-defined ignore patterns from .builderignore and .gitignore files
class UserIgnorePatterns
{
    private string[] directories;
    private string[] patterns;
    private string[] negatedDirectories;  // Negation patterns for directories
    private string[] negatedPatterns;     // Negation patterns for files
    private string baseDir;
    
    /// Constructor: Load ignore patterns from files
    /// 
    /// Safety: This constructor is @system because:
    /// 1. Delegates to loadIgnoreFiles() which performs validated file I/O
    /// 2. baseDir is stored as-is (no pointer manipulation)
    /// 3. Array initialization is safe
    /// 
    /// Invariants:
    /// - baseDir is valid string (caller's responsibility)
    /// - Patterns are loaded but may be empty if no ignore files exist
    /// 
    /// What could go wrong:
    /// - File I/O could fail: handled gracefully in loadIgnoreFiles()
    /// - Invalid baseDir: will fail when trying to read files (safe failure)
    @system
    this(string baseDir)
    {
        this.baseDir = baseDir;
        loadIgnoreFiles();
    }
    
    /// Load ignore patterns from .builderignore and .gitignore
    /// 
    /// Safety: This function is @system because:
    /// 1. buildPath() is safe string concatenation
    /// 2. exists() is file system query (read-only)
    /// 3. parseIgnoreFile() is called with valid paths
    /// 4. Exception handling prevents crashes
    /// 
    /// Invariants:
    /// - baseDir is valid (set in constructor)
    /// - Files may not exist (handled gracefully)
    /// 
    /// What could go wrong:
    /// - File doesn't exist: checked with exists() before reading
    /// - Permission errors: caught and ignored (safe default)
    @system
    private void loadIgnoreFiles()
    {
        // Load .builderignore first (takes precedence)
        string builderignorePath = buildPath(baseDir, ".builderignore");
        if (exists(builderignorePath))
        {
            parseIgnoreFile(builderignorePath);
        }
        
        // Also load .gitignore for convenience
        string gitignorePath = buildPath(baseDir, ".gitignore");
        if (exists(gitignorePath))
        {
            parseIgnoreFile(gitignorePath);
        }
    }
    
    /// Parse a .gitignore/.builderignore format file
    /// Supports:
    /// - Comments (lines starting with #)
    /// - Directory patterns (ending with /)
    /// - Glob patterns (*, ?, **)
    /// - Negation patterns (starting with !)
    /// 
    /// Safety: This function is @system because:
    /// 1. readText() performs file I/O (inherently unsafe)
    /// 2. String operations (strip, startsWith, endsWith) are memory-safe
    /// 3. Array appending (~=) is memory-safe
    /// 4. Exception handling ensures no crashes
    /// 
    /// Invariants:
    /// - filePath must be valid and readable (caller's responsibility)
    /// - Empty or malformed lines are skipped (robust parsing)
    /// 
    /// What could go wrong:
    /// - File not readable: caught by exception handler (safe failure)
    /// - Malformed patterns: skipped or handled gracefully
    /// - Large files: memory allocation could fail (exception propagates)
    @system
    private void parseIgnoreFile(string filePath)
    {
        try
        {
            auto lines = readText(filePath).splitLines();
            
            foreach (line; lines)
            {
                // Strip whitespace
                line = line.strip();
                
                // Skip empty lines and comments
                if (line.empty || line.startsWith("#"))
                    continue;
                
                // Handle negation patterns (!)
                bool isNegated = false;
                if (line.startsWith("!"))
                {
                    isNegated = true;
                    line = line[1 .. $].strip();  // Remove ! and re-strip
                    
                    if (line.empty)
                        continue;
                }
                
                // Directory pattern (ends with /)
                if (line.endsWith("/"))
                {
                    string dirName = line[0 .. $-1];
                    // Remove leading slash if present
                    if (dirName.startsWith("/"))
                        dirName = dirName[1 .. $];
                    
                    if (!dirName.empty)
                    {
                        if (isNegated)
                        {
                            if (!negatedDirectories.canFind(dirName))
                                negatedDirectories ~= dirName;
                        }
                        else if (!directories.canFind(dirName))
                        {
                            directories ~= dirName;
                        }
                    }
                }
                else
                {
                    // File or glob pattern
                    // Remove leading slash if present
                    if (line.startsWith("/"))
                        line = line[1 .. $];
                    
                    if (!line.empty)
                    {
                        if (isNegated)
                        {
                            if (!negatedPatterns.canFind(line))
                                negatedPatterns ~= line;
                        }
                        else if (!patterns.canFind(line))
                        {
                            patterns ~= line;
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
            // Ignore file errors should be visible to users as they can cause
            // unexpected behavior (files not being ignored, performance issues, etc.)
            import infrastructure.utils.logging : structuredLog;
            structuredLog.warning("ignore_file_read_failed")
                .field("path", filePath)
                .field("error", e.msg)
                .emit();
        }
    }
    
    /// Check if a directory should be ignored
    bool shouldIgnoreDirectory(string dirPath)
    {
        immutable dirName = baseName(dirPath);
        
        // First check if it's negated (negation takes precedence)
        if (negatedDirectories.canFind(dirName))
            return false;
        
        // Check negated glob patterns (for directories)
        foreach (pattern; negatedDirectories)
        {
            if (matchesGlobPattern(dirName, pattern))
                return false;
        }
        
        // Check negated glob patterns (for files, but may match directories)
        foreach (pattern; negatedPatterns)
        {
            if (matchesGlobPattern(dirName, pattern))
                return false;
        }
        
        // Check directory patterns (exact match or glob)
        foreach (pattern; directories)
        {
            if (pattern == dirName || matchesGlobPattern(dirName, pattern))
                return true;
        }
        
        // Check glob patterns against directory name
        foreach (pattern; patterns)
        {
            if (matchesGlobPattern(dirName, pattern))
                return true;
        }
        
        return false;
    }
    
    /// Check if a file should be ignored
    bool shouldIgnoreFile(string filePath)
    {
        immutable fileName = baseName(filePath);
        
        // First check if it's negated (negation takes precedence)
        foreach (pattern; negatedPatterns)
        {
            if (matchesGlobPattern(fileName, pattern))
                return false;
        }
        
        // Check glob patterns
        foreach (pattern; patterns)
        {
            if (matchesGlobPattern(fileName, pattern))
                return true;
        }
        
        return false;
    }
    
    /// Simple glob pattern matching for ignore files
    /// Supports: *, ?, **
    private bool matchesGlobPattern(string text, string pattern)
    {
        // Handle ** (matches any number of directories)
        if (pattern.canFind("**"))
        {
            // For simplicity, ** matches everything
            auto parts = pattern.split("**");
            if (parts.length >= 2)
            {
                // Check prefix and suffix
                if (!parts[0].empty && !text.startsWith(parts[0].stripRight("/")))
                    return false;
                if (parts.length > 1 && !parts[$-1].empty && !text.endsWith(parts[$-1].stripLeft("/")))
                    return false;
                return true;
            }
        }
        
        // Simple pattern matching with * and ?
        return simpleGlobMatch(text, pattern);
    }
    
    /// Simple glob matching (* and ? only)
    private bool simpleGlobMatch(string text, string pattern)
    {
        size_t ti = 0;  // text index
        size_t pi = 0;  // pattern index
        size_t starIdx = size_t.max;
        size_t matchIdx = 0;
        
        while (ti < text.length)
        {
            if (pi < pattern.length)
            {
                if (pattern[pi] == '*')
                {
                    starIdx = pi;
                    matchIdx = ti;
                    pi++;
                    continue;
                }
                else if (pattern[pi] == '?' || pattern[pi] == text[ti])
                {
                    pi++;
                    ti++;
                    continue;
                }
            }
            
            if (starIdx != size_t.max)
            {
                pi = starIdx + 1;
                matchIdx++;
                ti = matchIdx;
                continue;
            }
            
            return false;
        }
        
        // Handle remaining pattern
        while (pi < pattern.length && pattern[pi] == '*')
            pi++;
        
        return pi == pattern.length;
    }
    
    /// Get all ignored directory names
    string[] getIgnoredDirectories() const
    {
        return directories.dup;
    }
    
    /// Get all ignore patterns
    string[] getIgnorePatterns() const
    {
        return patterns.dup;
    }
}

/// Combined ignore checker that uses both built-in and user-defined patterns
class CombinedIgnoreChecker
{
    private UserIgnorePatterns userPatterns;
    private TargetLanguage language;
    private string baseDir;
    
    /// Constructor: Create ignore filter with user patterns
    /// 
    /// Safety: This constructor is @system because:
    /// 1. Creates UserIgnorePatterns which performs file I/O
    /// 2. All parameters are stored by value (no pointer issues)
    /// 3. Object creation is memory-safe
    /// 
    /// Invariants:
    /// - baseDir and language are stored correctly
    /// - UserIgnorePatterns is properly initialized
    /// 
    /// What could go wrong:
    /// - UserIgnorePatterns constructor could fail: exception propagates
    /// - Invalid baseDir: handled by UserIgnorePatterns (safe failure)
    @system
    this(string baseDir, TargetLanguage language = TargetLanguage.Generic)
    {
        this.baseDir = baseDir;
        this.language = language;
        this.userPatterns = new UserIgnorePatterns(baseDir);
    }
    
    /// Check if a directory should be ignored
    /// Combines built-in patterns, language-specific patterns, and user patterns
    bool shouldIgnoreDirectory(string dirPath)
    {
        // Check built-in patterns first (VCS, common, language-specific)
        if (IgnoreRegistry.shouldIgnoreDirectoryAny(dirPath))
            return true;
        
        // Check user-defined patterns
        if (userPatterns.shouldIgnoreDirectory(dirPath))
            return true;
        
        return false;
    }
    
    /// Check if a file should be ignored
    bool shouldIgnoreFile(string filePath)
    {
        // Check language-specific file patterns
        if (IgnoreRegistry.shouldIgnoreFile(filePath, language))
            return true;
        
        // Check user-defined patterns
        if (userPatterns.shouldIgnoreFile(filePath))
            return true;
        
        return false;
    }
    
    /// Get summary of what's being ignored
    string getSummary()
    {
        string summary = "Ignore patterns active:\n";
        summary ~= "  Built-in: VCS, common, and language-specific patterns\n";
        
        auto userDirs = userPatterns.getIgnoredDirectories();
        auto userPats = userPatterns.getIgnorePatterns();
        
        if (!userDirs.empty || !userPats.empty)
        {
            summary ~= "  User-defined:\n";
            if (!userDirs.empty)
                summary ~= "    Directories: " ~ userDirs.join(", ") ~ "\n";
            if (!userPats.empty)
                summary ~= "    Patterns: " ~ userPats.join(", ") ~ "\n";
        }
        
        return summary;
    }
}

unittest
{
    import std.stdio : writeln;
    import std.file : tempDir, write, remove;
    
    writeln("Testing user ignore patterns...");
    
    // Create temporary .builderignore file
    string testDir = tempDir();
    string testIgnorePath = buildPath(testDir, ".builderignore");
    
    write(testIgnorePath, "# Test ignore file\ntest_dir/\n*.tmp\nnode_modules\n");
    
    auto userIgnore = new UserIgnorePatterns(testDir);
    
    assert(userIgnore.shouldIgnoreDirectory("test_dir"));
    assert(userIgnore.shouldIgnoreDirectory("node_modules"));
    assert(userIgnore.shouldIgnoreFile("test.tmp"));
    assert(!userIgnore.shouldIgnoreFile("test.py"));
    
    // Clean up
    if (exists(testIgnorePath))
        remove(testIgnorePath);
    
    writeln("User ignore pattern tests passed!");
}

unittest
{
    import std.stdio : writeln;
    import std.file : tempDir, write, remove;
    
    writeln("Testing negation patterns...");
    
    // Create temporary .builderignore file with negation patterns
    string testDir = tempDir();
    string testIgnorePath = buildPath(testDir, ".builderignore");
    
    // Ignore all .log files but not important.log
    // Ignore all build directories but not build_prod/
    write(testIgnorePath, "*.log\n!important.log\nbuild*/\n!build_prod/\n");
    
    auto userIgnore = new UserIgnorePatterns(testDir);
    
    // Regular .log files should be ignored
    assert(userIgnore.shouldIgnoreFile("debug.log"));
    assert(userIgnore.shouldIgnoreFile("error.log"));
    
    // important.log should NOT be ignored (negated)
    assert(!userIgnore.shouldIgnoreFile("important.log"));
    
    // build directories should be ignored
    assert(userIgnore.shouldIgnoreDirectory("build_debug"));
    assert(userIgnore.shouldIgnoreDirectory("build_test"));
    
    // build_prod should NOT be ignored (negated)
    assert(!userIgnore.shouldIgnoreDirectory("build_prod"));
    
    // Clean up
    if (exists(testIgnorePath))
        remove(testIgnorePath);
    
    writeln("Negation pattern tests passed!");
}

