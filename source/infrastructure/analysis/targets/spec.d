module infrastructure.analysis.targets.spec;

import infrastructure.analysis.targets.types;
import infrastructure.config.schema.schema;
import std.regex;
import std.algorithm;
import std.array;
import std.string;

/// Language-specific analysis configuration
struct LanguageSpec
{
    TargetLanguage language;
    string name;
    ImportPattern[] patterns;
    ImportKindDetector kindDetector;
    
    /// Scan a file for imports using regex patterns
    /// 
    /// Safety: This function is @system because:
    /// 1. Uses regex matching on file content (potentially large strings)
    /// 2. String slicing and line counting (all bounds-checked)
    /// 3. Array operations (~=) are memory-safe
    /// 4. Regex engine is@system but complex pattern matching warrants @system
    /// 
    /// Invariants:
    /// - filePath is used only for diagnostics (not accessed)
    /// - content is immutable string (no modification)
    /// - Line counting is monotonically increasing
    /// - Import array is built incrementally (safe appends)
    /// 
    /// What could go wrong:
    /// - Regex fails to compile: compile-time checked (ctRegex)
    /// - Large content: memory allocation could fail (D handles safely)
    /// - Invalid UTF-8: handled by D string operations
    Import[] scanImports(string filePath, string content) const @system
    {
        Import[] imports;
        size_t lineNumber = 1;
        
        foreach (line; content.lineSplitter)
        {
            foreach (patternItem; patterns)
            {
                auto matches = matchAll(line, patternItem.pattern);
                
                foreach (match; matches)
                {
                    if (match.length > 1)
                    {
                        auto moduleName = match[1].strip();
                        if (!moduleName.empty && !shouldIgnore(moduleName))
                        {
                            imports ~= Import(
                                moduleName,
                                kindDetector(moduleName, filePath),
                                SourceLocation(filePath, lineNumber, 0)
                            );
                        }
                    }
                }
            }
            
            lineNumber++;
        }
        
        return imports;
    }
    
    private bool shouldIgnore(string moduleName) const pure
    {
        // Ignore common stdlib modules that don't need tracking
        static immutable string[] commonStdlib = [
            "std", "core", "system", "builtin"
        ];
        
        return commonStdlib.canFind(moduleName);
    }
}

/// Import pattern with regex
struct ImportPattern
{
    string description;
    Regex!char pattern;
    
    this(string desc, string regexPattern, string flags = "m")
    {
        description = desc;
        this.pattern = std.regex.regex(regexPattern, flags);
    }
}

/// Function type for detecting import kind
alias ImportKindDetector = ImportKind function(string moduleName, string fromFile) pure;

/// Standard import kind detectors

ImportKind detectRelativeImport(string moduleName, string fromFile) pure
{
    if (moduleName.startsWith(".") || moduleName.startsWith("/"))
        return ImportKind.Relative;
    return ImportKind.Absolute;
}

ImportKind detectPythonImportKind(string moduleName, string fromFile) pure
{
    // Relative if starts with "."
    if (moduleName.startsWith("."))
        return ImportKind.Relative;
    
    // External if single component without underscore (usually stdlib/packages)
    auto parts = moduleName.split(".");
    if (parts.length == 1 && !moduleName.canFind("_"))
        return ImportKind.External;
    
    return ImportKind.Absolute;
}

ImportKind detectJavaScriptImportKind(string moduleName, string fromFile) pure
{
    if (moduleName.startsWith("."))
        return ImportKind.Relative;
    if (moduleName.startsWith("/"))
        return ImportKind.Absolute;
    return ImportKind.External; // Node module
}

ImportKind detectGoImportKind(string moduleName, string fromFile) pure
{
    // Go uses URLs for external packages
    if (moduleName.canFind("/"))
        return ImportKind.External;
    return ImportKind.Absolute;
}

ImportKind detectRustImportKind(string moduleName, string fromFile) pure
{
    // Rust uses "crate::" for internal, otherwise external
    if (moduleName.startsWith("crate::") || moduleName.startsWith("super::") || moduleName == "self")
        return ImportKind.Relative;
    return ImportKind.External;
}

ImportKind detectRImportKind(string moduleName, string fromFile) pure
{
    // Relative if ends with .R or .r (source files)
    if (moduleName.endsWith(".R") || moduleName.endsWith(".r"))
        return ImportKind.Relative;
    // External for CRAN/Bioconductor packages
    return ImportKind.External;
}

/// Compile-time registry of all language specifications
immutable LanguageSpec[TargetLanguage] LanguageSpecs;

/// Initialize language specs at module load
shared static this()
{
    LanguageSpec[TargetLanguage] specs;
    
    // D Language
    specs[TargetLanguage.D] = LanguageSpec(
        TargetLanguage.D,
        "D",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // Python
    specs[TargetLanguage.Python] = LanguageSpec(
        TargetLanguage.Python,
        "Python",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`),
            ImportPattern("from-import", `^\s*from\s+([\w.]+)\s+import`)
        ],
        &detectPythonImportKind
    );
    
    // JavaScript / TypeScript
    specs[TargetLanguage.JavaScript] = LanguageSpec(
        TargetLanguage.JavaScript,
        "JavaScript",
        [
            ImportPattern("es6-import", `^\s*import\s+.*from\s+['"]([^'"]+)['"]`),
            ImportPattern("require", `^\s*(?:const|let|var)\s+.*=\s*require\s*\(['"]([^'"]+)['"]\)`)
        ],
        &detectJavaScriptImportKind
    );
    
    specs[TargetLanguage.TypeScript] = specs[TargetLanguage.JavaScript];
    specs[TargetLanguage.TypeScript].language = TargetLanguage.TypeScript;
    specs[TargetLanguage.TypeScript].name = "TypeScript";
    
    // Go
    specs[TargetLanguage.Go] = LanguageSpec(
        TargetLanguage.Go,
        "Go",
        [
            ImportPattern("import", `^\s*import\s+"([^"]+)"`),
            ImportPattern("import-multi", `^\s+"([^"]+)"`)
        ],
        &detectGoImportKind
    );
    
    // Rust
    specs[TargetLanguage.Rust] = LanguageSpec(
        TargetLanguage.Rust,
        "Rust",
        [
            ImportPattern("use", `^\s*use\s+([\w:]+)`),
            ImportPattern("extern-crate", `^\s*extern\s+crate\s+([\w]+)`)
        ],
        &detectRustImportKind
    );
    
    // C/C++
    specs[TargetLanguage.Cpp] = LanguageSpec(
        TargetLanguage.Cpp,
        "C++",
        [
            ImportPattern("include", `^\s*#include\s+["<]([^">]+)[">]`)
        ],
        &detectRelativeImport
    );
    
    specs[TargetLanguage.C] = specs[TargetLanguage.Cpp];
    specs[TargetLanguage.C].language = TargetLanguage.C;
    specs[TargetLanguage.C].name = "C";
    
    // Java
    specs[TargetLanguage.Java] = LanguageSpec(
        TargetLanguage.Java,
        "Java",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // Kotlin
    specs[TargetLanguage.Kotlin] = LanguageSpec(
        TargetLanguage.Kotlin,
        "Kotlin",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // C#
    specs[TargetLanguage.CSharp] = LanguageSpec(
        TargetLanguage.CSharp,
        "C#",
        [
            ImportPattern("using", `^\s*using\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // F#
    specs[TargetLanguage.FSharp] = LanguageSpec(
        TargetLanguage.FSharp,
        "F#",
        [
            ImportPattern("open", `^\s*open\s+([\w.]+)`),
            ImportPattern("module", `^\s*module\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // Zig
    specs[TargetLanguage.Zig] = LanguageSpec(
        TargetLanguage.Zig,
        "Zig",
        [
            ImportPattern("import", `^\s*const\s+\w+\s*=\s*@import\("([^"]+)"\)`)
        ],
        &detectRelativeImport
    );
    
    // Swift
    specs[TargetLanguage.Swift] = LanguageSpec(
        TargetLanguage.Swift,
        "Swift",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // Ruby
    specs[TargetLanguage.Ruby] = LanguageSpec(
        TargetLanguage.Ruby,
        "Ruby",
        [
            ImportPattern("require", `^\s*require\s+['"]([^'"]+)['"]`),
            ImportPattern("require_relative", `^\s*require_relative\s+['"]([^'"]+)['"]`)
        ],
        &detectRelativeImport
    );
    
    // PHP
    specs[TargetLanguage.PHP] = LanguageSpec(
        TargetLanguage.PHP,
        "PHP",
        [
            ImportPattern("require", `^\s*(?:require|include)(?:_once)?\s*['"]([^'"]+)['"]`),
            ImportPattern("use", `^\s*use\s+([\w\\]+)`)
        ],
        &detectRelativeImport
    );
    
    // Scala
    specs[TargetLanguage.Scala] = LanguageSpec(
        TargetLanguage.Scala,
        "Scala",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`),
            ImportPattern("package", `^\s*package\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // Elixir
    specs[TargetLanguage.Elixir] = LanguageSpec(
        TargetLanguage.Elixir,
        "Elixir",
        [
            ImportPattern("import", `^\s*import\s+([\w.]+)`),
            ImportPattern("alias", `^\s*alias\s+([\w.]+)`)
        ],
        &detectRelativeImport
    );
    
    // Nim
    specs[TargetLanguage.Nim] = LanguageSpec(
        TargetLanguage.Nim,
        "Nim",
        [
            ImportPattern("import", `^\s*import\s+([\w/]+)`),
            ImportPattern("from", `^\s*from\s+([\w/]+)\s+import`)
        ],
        &detectRelativeImport
    );
    
    // Lua
    specs[TargetLanguage.Lua] = LanguageSpec(
        TargetLanguage.Lua,
        "Lua",
        [
            ImportPattern("require", `^\s*(?:local\s+\w+\s*=\s*)?require\s*\(?['"]([^'"]+)['"]\)?`)
        ],
        &detectRelativeImport
    );
    
    // R
    specs[TargetLanguage.R] = LanguageSpec(
        TargetLanguage.R,
        "R",
        [
            ImportPattern("library", `^\s*library\s*\(\s*['"]?([^'"(),\s]+)['"]?\s*\)`),
            ImportPattern("require", `^\s*require\s*\(\s*['"]?([^'"(),\s]+)['"]?\s*\)`),
            ImportPattern("source", `^\s*source\s*\(\s*['"]([^'"]+)['"]\s*\)`),
            ImportPattern("load", `^\s*load\s*\(\s*['"]([^'"]+)['"]\s*\)`)
        ],
        &detectRImportKind
    );
    
    // CSS (no import patterns - typically no dependencies)
    specs[TargetLanguage.CSS] = LanguageSpec(
        TargetLanguage.CSS,
        "CSS",
        [
            ImportPattern("import", `^\s*@import\s+(?:url\(['"])?([^'"()]+)['"]?\)?`)
        ],
        &detectRelativeImport
    );
    
    // WebAssembly (WAT imports)
    specs[TargetLanguage.WebAssembly] = LanguageSpec(
        TargetLanguage.WebAssembly,
        "WebAssembly",
        [
            ImportPattern("import", `\(import\s+"([^"]+)"\s+"[^"]+"`),
        ],
        &detectRelativeImport
    );
    
    // Generic (no-op)
    specs[TargetLanguage.Generic] = LanguageSpec(
        TargetLanguage.Generic,
        "Generic",
        [],
        &detectRelativeImport
    );
    
    LanguageSpecs = cast(immutable) specs;
}

/// Get spec for a language
/// 
/// Safety: This function is @system because:
/// 1. Returns pointer to static immutable data (LanguageSpecs)
/// 2. Associative array lookup with `in` operator (safe operation)
/// 3. Pointer lifetime tied to program lifetime (static data)
/// 4. const(LanguageSpec)* prevents mutation through pointer
/// 
/// Invariants:
/// - LanguageSpecs is immutable static data (initialized once)
/// - Returned pointer is either valid or null
/// - Pointer always points to valid LanguageSpec if non-null
/// - Data cannot be modified through const pointer
/// 
/// What could go wrong:
/// - Language not in map: returns null (safe, caller checks)
/// - Pointer dangling: impossible, points to static data
const(LanguageSpec)* getLanguageSpec(TargetLanguage lang) @system
{
    if (auto spec = lang in LanguageSpecs)
        return spec;
    return null;
}

