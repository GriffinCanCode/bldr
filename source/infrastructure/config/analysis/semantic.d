module infrastructure.config.analysis.semantic;

import std.algorithm;
import std.array;
import std.string;
import std.conv;
import std.path;
import infrastructure.config.workspace.ast;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import languages.registry;
import infrastructure.utils.files.glob;
import infrastructure.utils.security.validation;

/// Semantic Analyzer - Converts AST to semantic objects (Targets, Repositories)
/// 
/// Responsibilities:
/// - Type checking and validation
/// - Glob expansion
/// - Path normalization
/// - Language inference
/// - Default value application

struct SemanticAnalyzer
{
    private string workspaceRoot;
    private string filePath;
    
    this(string workspaceRoot, string filePath)
    {
        this.workspaceRoot = workspaceRoot;
        this.filePath = filePath;
    }
    
    /// Analyze build file and extract targets
    BuildResult!(Target[]) analyzeTargets(BuildFile ast) @system
    {
        Target[] targets;
        
        foreach (stmt; ast.statements)
        {
            if (auto targetDecl = cast(TargetDeclStmt)stmt)
            {
                auto targetResult = analyzeTarget(targetDecl);
                if (targetResult.isErr)
                    return Err!(Target[], BuildError)(targetResult.unwrapErr());
                targets ~= targetResult.unwrap();
            }
        }
        
        return Ok!(Target[], BuildError)(targets);
    }
    
    /// Analyze single target declaration
    private BuildResult!Target analyzeTarget(TargetDeclStmt decl) @system
    {
        Target target;
        target.name = decl.name;
        
        // Parse required fields
        if (auto typeField = decl.getField("type"))
        {
            auto typeResult = extractType(typeField.value);
            if (typeResult.isErr)
                return Err!(Target, BuildError)(typeResult.unwrapErr());
            target.type = typeResult.unwrap();
        }
        else
        {
            return error!Target("Target must have 'type' field", decl.location());
        }
        
        // Parse optional fields
        if (auto langField = decl.getField("language"))
        {
            auto langResult = extractLanguage(langField.value);
            if (langResult.isErr)
                return Err!(Target, BuildError)(langResult.unwrapErr());
            target.language = langResult.unwrap();
        }
        
        if (auto srcField = decl.getField("sources"))
        {
            auto srcResult = extractStringArray(srcField.value);
            if (srcResult.isErr)
                return Err!(Target, BuildError)(srcResult.unwrapErr());
            target.sources = expandGlobs(srcResult.unwrap(), dirName(filePath));
            
            // Validate paths
            foreach (source; target.sources)
            {
                if (!SecurityValidator.isPathWithinBase(source, workspaceRoot))
                {
                    return error!Target(
                        "Source file outside workspace: " ~ source,
                        srcField.loc);
                }
            }
            
            // Infer language if not specified
            if (target.language == TargetLanguage.Generic && !target.sources.empty)
            {
                target.language = inferLanguageFromExtension(extension(target.sources[0]));
            }
        }
        
        if (auto depsField = decl.getField("deps"))
        {
            auto depsResult = extractStringArray(depsField.value);
            if (depsResult.isErr)
                return Err!(Target, BuildError)(depsResult.unwrapErr());
            target.deps = depsResult.unwrap();
        }
        
        if (auto flagsField = decl.getField("flags"))
        {
            auto flagsResult = extractStringArray(flagsField.value);
            if (flagsResult.isErr)
                return Err!(Target, BuildError)(flagsResult.unwrapErr());
            target.flags = flagsResult.unwrap();
        }
        
        if (auto envField = decl.getField("env"))
        {
            auto envResult = extractStringMap(envField.value);
            if (envResult.isErr)
                return Err!(Target, BuildError)(envResult.unwrapErr());
            target.env = envResult.unwrap();
        }
        
        if (auto outField = decl.getField("output"))
        {
            auto outResult = extractString(outField.value);
            if (outResult.isErr)
                return Err!(Target, BuildError)(outResult.unwrapErr());
            target.outputPath = outResult.unwrap();
        }
        
        if (auto incField = decl.getField("includes"))
        {
            auto incResult = extractStringArray(incField.value);
            if (incResult.isErr)
                return Err!(Target, BuildError)(incResult.unwrapErr());
            target.includes = incResult.unwrap();
        }
        
        // Cross-compilation fields
        if (auto platformField = decl.getField("platform"))
        {
            auto platResult = extractString(platformField.value);
            if (platResult.isErr)
                return Err!(Target, BuildError)(platResult.unwrapErr());
            target.platform = platResult.unwrap();
        }
        
        if (auto toolchainField = decl.getField("toolchain"))
        {
            auto toolResult = extractString(toolchainField.value);
            if (toolResult.isErr)
                return Err!(Target, BuildError)(toolResult.unwrapErr());
            target.toolchain = toolResult.unwrap();
        }
        
        // Shell target fields
        if (auto cmdField = decl.getField("command"))
        {
            auto cmdResult = extractString(cmdField.value);
            if (cmdResult.isErr)
                return Err!(Target, BuildError)(cmdResult.unwrapErr());
            target.command = cmdResult.unwrap();
        }
        
        if (auto workdirField = decl.getField("workdir"))
        {
            auto workdirResult = extractString(workdirField.value);
            if (workdirResult.isErr)
                return Err!(Target, BuildError)(workdirResult.unwrapErr());
            target.workdir = workdirResult.unwrap();
        }
        
        // Root directory for language toolchains (e.g., where build.zig is located)
        if (auto rootField = decl.getField("root"))
        {
            auto rootResult = extractString(rootField.value);
            if (rootResult.isErr)
                return Err!(Target, BuildError)(rootResult.unwrapErr());
            target.root = rootResult.unwrap();
        }
        
        // Parse language-specific config blocks (e.g., javascript:, go:, python:, etc.)
        // These are stored in target.langConfig as JSON strings
        foreach (field; decl.fields)
        {
            string fieldName = field.name.toLower();
            
            // Check if field name is a recognized language or language config
            // Use the language registry to determine if this is a language-specific config
            import languages.registry : parseLanguageName;
            auto parsedLang = parseLanguageName(fieldName);
            
            // If it's a recognized language (not Generic), treat it as a config block
            // Also handle common patterns like "jsConfig", "goConfig", etc.
            bool isLangConfig = parsedLang != TargetLanguage.Generic || 
                               fieldName.endsWith("config");
            
            if (isLangConfig)
            {
                // Convert the field value to JSON string
                auto jsonResult = extractMapAsJSON(field.value);
                if (jsonResult.isOk)
                {
                    target.langConfig[fieldName] = jsonResult.unwrap();
                }
            }
        }
        
        // Generate full target name
        string relativeDir = relativePath(dirName(filePath), workspaceRoot);
        target.name = "//" ~ relativeDir ~ ":" ~ target.name;
        
        return Ok!(Target, BuildError)(target);
    }
    
    // ========================================================================
    // FIELD EXTRACTION
    // ========================================================================
    
    private BuildResult!string extractString(const Expr expr) @system
    {
        if (auto litExpr = cast(const LiteralExpr)expr)
        {
            if (litExpr.value.kind == LiteralKind.String)
                return Ok!(string, BuildError)(litExpr.value.asString());
            return Err!(string, BuildError)(
                new ParseError("Expected string", null));
        }
        
        if (auto identExpr = cast(const IdentExpr)expr)
        {
            // Variable reference - would need evaluator
            return Ok!(string, BuildError)(identExpr.name);
        }
        
        return Err!(string, BuildError)(
            new ParseError("Expected string literal", null));
    }
    
    private BuildResult!(string[]) extractStringArray(const Expr expr) @system
    {
        if (auto litExpr = cast(const LiteralExpr)expr)
        {
            return litExpr.value.toStringArray();
        }
        
        return Err!(string[], BuildError)(
            new ParseError("Expected array of strings", null));
    }
    
    private BuildResult!(string[string]) extractStringMap(const Expr expr) @system
    {
        if (auto litExpr = cast(const LiteralExpr)expr)
        {
            return litExpr.value.toStringMap();
        }
        
        return Err!(string[string], BuildError)(
            new ParseError("Expected map of strings", null));
    }
    
    private BuildResult!TargetType extractType(const Expr expr) @system
    {
        auto strResult = extractString(expr);
        if (strResult.isErr)
            return Err!(TargetType, BuildError)(strResult.unwrapErr());
        
        string typeStr = strResult.unwrap().toLower;
        switch (typeStr)
        {
            case "executable": return Ok!(TargetType, BuildError)(TargetType.Executable);
            case "library": return Ok!(TargetType, BuildError)(TargetType.Library);
            case "test": return Ok!(TargetType, BuildError)(TargetType.Test);
            case "custom": return Ok!(TargetType, BuildError)(TargetType.Custom);
            case "shell", "genrule": return Ok!(TargetType, BuildError)(TargetType.Shell);
            default:
            {
                import infrastructure.errors.types.types : unknownFieldError;
                const string[] validTypes = ["executable", "library", "test", "custom", "shell", "genrule"];
                auto err = unknownFieldError(filePath, typeStr, validTypes);
                return Err!(TargetType, BuildError)(err);
            }
        }
    }
    
    private BuildResult!TargetLanguage extractLanguage(const Expr expr) @system
    {
        auto strResult = extractString(expr);
        if (strResult.isErr)
            return Err!(TargetLanguage, BuildError)(strResult.unwrapErr());
        
        return Ok!(TargetLanguage, BuildError)(
            parseLanguageName(strResult.unwrap()));
    }
    
    private BuildResult!string extractMapAsJSON(const Expr expr) @system
    {
        import std.json : JSONValue;
        
        if (auto litExpr = cast(const LiteralExpr)expr)
        {
            if (litExpr.value.kind == LiteralKind.Map)
            {
                // Convert map to JSON
                JSONValue[string] jsonObj;
                
                auto map = litExpr.value.asMap();
                foreach (key, value; map)
                {
                    // Handle different value types
                    if (value.kind == LiteralKind.String)
                        jsonObj[key] = JSONValue(value.asString());
                    else if (value.kind == LiteralKind.Bool)
                        jsonObj[key] = JSONValue(value.asBool());
                    else if (value.kind == LiteralKind.Number)
                        jsonObj[key] = JSONValue(value.asNumber());
                    else if (value.kind == LiteralKind.Array)
                    {
                        auto arr = value.asArray();
                        JSONValue[] jsonArr;
                        foreach (item; arr)
                        {
                            if (item.kind == LiteralKind.String)
                                jsonArr ~= JSONValue(item.asString());
                        }
                        jsonObj[key] = JSONValue(jsonArr);
                    }
                }
                
                return Ok!(string, BuildError)(JSONValue(jsonObj).toString());
            }
        }
        
        return Err!(string, BuildError)(
            new ParseError("Expected map for language config", null));
    }
    
    // ========================================================================
    // HELPERS
    // ========================================================================
    
    private string[] expandGlobs(string[] patterns, string baseDir) @system
    {
        return glob(patterns, baseDir);
    }
    
    private BuildResult!T error(T)(string message, Location loc) @system
    {
        auto err = new ParseError(loc.file, message, ErrorCode.InvalidFieldValue);
        err.line = loc.line;
        err.column = loc.column;
        return Err!(T, BuildError)(err);
    }
}

/// Parse result with targets and repositories
struct ParseResult
{
    Target[] targets;
    
    import infrastructure.repository.core.types : RepositoryRule;
    RepositoryRule[] repositories;
}

/// High-level API - Parse DSL source into targets and repositories
BuildResult!ParseResult parseDSL(
    string source,
    string filePath,
    string workspaceRoot) @system
{
    import infrastructure.config.parsing.unified : parse;
    import infrastructure.config.scripting.interpreter : Interpreter;
    
    // Parse to AST
    auto astResult = parse(source, filePath, workspaceRoot, null);
    if (astResult.isErr)
        return Err!(ParseResult, BuildError)(astResult.unwrapErr());
    
    auto ast = astResult.unwrap();
    
    // Execute interpreter to process variables, loops, conditionals
    // This expands for loops, evaluates if conditions, resolves variables
    auto interpreter = new Interpreter();
    auto execResult = interpreter.execute(ast.statements);
    if (execResult.isErr)
        return Err!(ParseResult, BuildError)(execResult.unwrapErr());
    
    auto generatedTargets = execResult.unwrap();
    
    // Create a new BuildFile with the expanded/generated targets
    BuildFile expandedAst;
    expandedAst.filePath = ast.filePath;
    foreach (target; generatedTargets)
        expandedAst.statements ~= target;
    
    // Also preserve repository declarations from original AST
    foreach (stmt; ast.statements)
        if (auto repoDecl = cast(RepositoryDeclStmt)stmt)
            expandedAst.statements ~= repoDecl;
    
    // Analyze targets from expanded AST
    auto analyzer = SemanticAnalyzer(workspaceRoot, filePath);
    auto targetsResult = analyzer.analyzeTargets(expandedAst);
    if (targetsResult.isErr)
        return Err!(ParseResult, BuildError)(targetsResult.unwrapErr());
    
    // Convert repositories
    import infrastructure.repository.core.types : RepositoryRule, RepositoryKind, ArchiveFormat;
    RepositoryRule[] repositories;
    
    foreach (stmt; ast.statements)
    {
        if (auto repoDecl = cast(RepositoryDeclStmt)stmt)
        {
            RepositoryRule rule;
            rule.name = repoDecl.name;
            
            if (auto urlField = repoDecl.getField("url"))
            {
                if (auto litExpr = cast(LiteralExpr)urlField.value)
                {
                    if (litExpr.value.kind == LiteralKind.String)
                        rule.url = litExpr.value.asString();
                }
            }
            
            if (auto intField = repoDecl.getField("integrity"))
            {
                if (auto litExpr = cast(LiteralExpr)intField.value)
                {
                    if (litExpr.value.kind == LiteralKind.String)
                        rule.integrity = litExpr.value.asString();
                }
            }
            
            if (auto kindField = repoDecl.getField("kind"))
            {
                if (auto litExpr = cast(LiteralExpr)kindField.value)
                {
                    if (litExpr.value.kind == LiteralKind.String)
                    {
                        string kindStr = litExpr.value.asString().toLower;
                        if (kindStr == "archive" || kindStr == "http") rule.kind = RepositoryKind.Http;
                        else if (kindStr == "git") rule.kind = RepositoryKind.Git;
                        else if (kindStr == "local") rule.kind = RepositoryKind.Local;
                    }
                }
            }
            
            repositories ~= rule;
        }
    }
    
    ParseResult result;
    result.targets = targetsResult.unwrap();
    result.repositories = repositories;
    
    return Ok!(ParseResult, BuildError)(result);
}

