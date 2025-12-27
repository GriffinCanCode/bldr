module languages.scripting.elixir.config;

/// Elixir Configuration Modules
/// 
/// Grouped configuration pattern for maintainability.
/// Each module handles one aspect of Elixir configuration.

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

public import languages.scripting.elixir.config.build;
public import languages.scripting.elixir.config.dependency;
public import languages.scripting.elixir.config.quality;
public import languages.scripting.elixir.config.test;

/// Unified Elixir configuration
/// Composes specialized config groups
struct ElixirConfig
{
    ElixirBuildConfig build;
    ElixirDependencyConfig dependencies;
    ElixirQualityConfig quality;
    ElixirTestConfig testing;
    
    // Convenience accessors for common patterns
    ref ElixirProjectType projectType() return { return build.projectType; }
    ref MixEnv env() return { return build.mixEnv; }
    MixEnv env() const { return build.mixEnv; }
    ref string customEnv() return { return build.customEnv; }
    string customEnv() const { return build.customEnv; }
    ref OTPAppType appType() return { return build.appType; }
    ref ElixirVersion elixirVersion() return { return build.elixirVersion; }
    ref MixProjectConfig project() return { return build.mixProject; }
    const(MixProjectConfig) project() const { return build.mixProject; }
    ref PhoenixConfig phoenix() return { return build.phoenix; }
    const(PhoenixConfig) phoenix() const { return build.phoenix; }
    ref ReleaseConfig release() return { return build.release; }
    ref NervesConfig nerves() return { return build.nerves; }
    const(NervesConfig) nerves() const { return build.nerves; }
    
    ref UmbrellaConfig umbrella() return { return dependencies.umbrella; }
    const(UmbrellaConfig) umbrella() const { return dependencies.umbrella; }
    ref HexConfig hex() return { return dependencies.hex; }
    
    ref DialyzerConfig dialyzer() return { return quality.dialyzer; }
    ref CredoConfig credo() return { return quality.credo; }
    ref FormatConfig format() return { return quality.format; }
    const(FormatConfig) format() const { return quality.format; }
    ref DocConfig documentation() return { return quality.documentation; }
    
    ref ExUnitConfig exunit() return { return testing.exunit; }
    ref CoverallsConfig coveralls() return { return testing.coveralls; }
    
    /// Parse from JSON (required by ConfigParsingMixin)
    static ElixirConfig fromJSON(JSONValue json) @system
    {
        ElixirConfig config;
        
        // Project type
        if (auto projectType = "projectType" in json)
        {
            immutable typeStr = projectType.str.toLower;
            switch (typeStr)
            {
                case "script": config.build.projectType = ElixirProjectType.Script; break;
                case "mix", "mixproject": config.build.projectType = ElixirProjectType.MixProject; break;
                case "phoenix": config.build.projectType = ElixirProjectType.Phoenix; break;
                case "phoenix-liveview", "liveview": 
                    config.build.projectType = ElixirProjectType.PhoenixLiveView; break;
                case "umbrella": config.build.projectType = ElixirProjectType.Umbrella; break;
                case "library": config.build.projectType = ElixirProjectType.Library; break;
                case "nerves": config.build.projectType = ElixirProjectType.Nerves; break;
                case "escript": config.build.projectType = ElixirProjectType.Escript; break;
                default: config.build.projectType = ElixirProjectType.MixProject; break;
            }
        }
        
        // Mix environment
        if (auto env = "env" in json)
        {
            immutable envStr = env.str.toLower;
            switch (envStr)
            {
                case "dev": config.build.mixEnv = MixEnv.Dev; break;
                case "test": config.build.mixEnv = MixEnv.Test; break;
                case "prod": config.build.mixEnv = MixEnv.Prod; break;
                case "custom": 
                    config.build.mixEnv = MixEnv.Custom;
                    if (auto customEnv = "customEnv" in json)
                        config.build.customEnv = customEnv.str;
                    break;
                default: config.build.mixEnv = MixEnv.Dev; break;
            }
        }
        
        // App type
        if (auto appType = "appType" in json)
        {
            immutable appStr = appType.str.toLower;
            switch (appStr)
            {
                case "application": config.build.appType = OTPAppType.Application; break;
                case "library": config.build.appType = OTPAppType.Library; break;
                case "umbrella": config.build.appType = OTPAppType.Umbrella; break;
                case "task": config.build.appType = OTPAppType.Task; break;
                default: config.build.appType = OTPAppType.Application; break;
            }
        }
        
        // Elixir version
        if (auto elixirVersion = "elixirVersion" in json)
        {
            if (elixirVersion.type == JSONType.string)
            {
                immutable parts = elixirVersion.str.split(".");
                if (parts.length >= 1) config.build.elixirVersion.major = parts[0].to!int;
                if (parts.length >= 2) config.build.elixirVersion.minor = parts[1].to!int;
                if (parts.length >= 3) config.build.elixirVersion.patch = parts[2].to!int;
            }
            else if (elixirVersion.type == JSONType.object)
            {
                if (auto major = "major" in *elixirVersion) 
                    config.build.elixirVersion.major = cast(int)major.integer;
                if (auto minor = "minor" in *elixirVersion) 
                    config.build.elixirVersion.minor = cast(int)minor.integer;
                if (auto patch = "patch" in *elixirVersion) 
                    config.build.elixirVersion.patch = cast(int)patch.integer;
                if (auto otpVersion = "otpVersion" in *elixirVersion) 
                    config.build.elixirVersion.otpVersion = otpVersion.str;
                if (auto elixirPath = "elixirPath" in *elixirVersion) 
                    config.build.elixirVersion.elixirPath = elixirPath.str;
                if (auto useAsdf = "useAsdf" in *elixirVersion) 
                    config.build.elixirVersion.useAsdf = useAsdf.type == JSONType.true_;
            }
        }
        
        // Project configuration
        if (auto project = "project" in json)
        {
            if (auto name = "name" in *project) config.build.mixProject.name = name.str;
            if (auto app = "app" in *project) config.build.mixProject.app = app.str;
            if (auto version_ = "version" in *project) config.build.mixProject.version_ = version_.str;
            if (auto elixirVersion = "elixirVersion" in *project) config.build.mixProject.elixirVersion = elixirVersion.str;
            if (auto buildEmbedded = "buildEmbedded" in *project) 
                config.build.mixProject.buildEmbedded = buildEmbedded.type == JSONType.true_;
            if (auto startPermanent = "startPermanent" in *project) 
                config.build.mixProject.startPermanent = startPermanent.type == JSONType.true_;
            if (auto preferredCliEnv = "preferredCliEnv" in *project) 
                config.build.mixProject.preferredCliEnv = preferredCliEnv.str;
            if (auto consolidateProtocols = "consolidateProtocols" in *project) 
                config.build.mixProject.consolidateProtocols = consolidateProtocols.type == JSONType.true_;
            if (auto buildPath = "buildPath" in *project) config.build.mixProject.buildPath = buildPath.str;
            if (auto depsPath = "depsPath" in *project) config.build.mixProject.depsPath = depsPath.str;
            if (auto mixExsPath = "mixExsPath" in *project) config.build.mixProject.mixExsPath = mixExsPath.str;
        }
        
        // Phoenix configuration
        if ("phoenix" in json)
        {
            auto ph = json["phoenix"];
            if ("enabled" in ph) config.build.phoenix.enabled = ph["enabled"].type == JSONType.true_;
            if ("version" in ph) config.build.phoenix.version_ = ph["version"].str;
            if ("liveView" in ph) config.build.phoenix.liveView = ph["liveView"].type == JSONType.true_;
            if ("liveViewVersion" in ph) config.build.phoenix.liveViewVersion = ph["liveViewVersion"].str;
            if ("ecto" in ph) config.build.phoenix.ecto = ph["ecto"].type == JSONType.true_;
            if ("database" in ph) config.build.phoenix.database = ph["database"].str;
            if ("compileAssets" in ph) config.build.phoenix.compileAssets = ph["compileAssets"].type == JSONType.true_;
            if ("assetTool" in ph) config.build.phoenix.assetTool = ph["assetTool"].str;
            if ("runMigrations" in ph) config.build.phoenix.runMigrations = ph["runMigrations"].type == JSONType.true_;
            if ("digestAssets" in ph) config.build.phoenix.digestAssets = ph["digestAssets"].type == JSONType.true_;
            if ("endpoint" in ph) config.build.phoenix.endpoint = ph["endpoint"].str;
            if ("webModule" in ph) config.build.phoenix.webModule = ph["webModule"].str;
            if ("port" in ph) config.build.phoenix.port = cast(int)ph["port"].integer;
            if ("pubSub" in ph) config.build.phoenix.pubSub = ph["pubSub"].type == JSONType.true_;
        }
        
        // Release configuration
        if ("release" in json)
        {
            auto rel = json["release"];
            if ("name" in rel) config.build.release.name = rel["name"].str;
            if ("version" in rel) config.build.release.version_ = rel["version"].str;
            if ("type" in rel)
            {
                immutable typeStr = rel["type"].str.toLower;
                switch (typeStr)
                {
                    case "none": config.build.release.type = ReleaseType.None; break;
                    case "mix", "mixrelease": config.build.release.type = ReleaseType.MixRelease; break;
                    case "distillery": config.build.release.type = ReleaseType.Distillery; break;
                    case "burrito": config.build.release.type = ReleaseType.Burrito; break;
                    case "bakeware": config.build.release.type = ReleaseType.Bakeware; break;
                    default: config.build.release.type = ReleaseType.None; break;
                }
            }
            if ("applications" in rel) config.build.release.applications = rel["applications"].array.map!(e => e.str).array;
            if ("includeErts" in rel) config.build.release.includeErts = rel["includeErts"].type == JSONType.true_;
            if ("includeExecutables" in rel) config.build.release.includeExecutables = rel["includeExecutables"].type == JSONType.true_;
            if ("stripBeams" in rel) config.build.release.stripBeams = rel["stripBeams"].type == JSONType.true_;
            if ("cookie" in rel) config.build.release.cookie = rel["cookie"].str;
            if ("steps" in rel) config.build.release.steps = rel["steps"].array.map!(e => e.str).array;
            if ("path" in rel) config.build.release.path = rel["path"].str;
            if ("quiet" in rel) config.build.release.quiet = rel["quiet"].type == JSONType.true_;
            if ("overwrite" in rel) config.build.release.overwrite = rel["overwrite"].type == JSONType.true_;
        }
        
        // Boolean build flags
        if ("warningsAsErrors" in json) config.build.warningsAsErrors = json["warningsAsErrors"].type == JSONType.true_;
        if ("debugInfo" in json) config.build.debugInfo = json["debugInfo"].type == JSONType.true_;
        if ("verbose" in json) config.build.verbose = json["verbose"].type == JSONType.true_;
        if ("force" in json) config.build.force = json["force"].type == JSONType.true_;
        if ("allWarnings" in json) config.build.allWarnings = json["allWarnings"].type == JSONType.true_;
        if ("noDepsCheck" in json) config.build.noDepsCheck = json["noDepsCheck"].type == JSONType.true_;
        if ("noArchivesCheck" in json) config.build.noArchivesCheck = json["noArchivesCheck"].type == JSONType.true_;
        if ("noOptionalDeps" in json) config.build.noOptionalDeps = json["noOptionalDeps"].type == JSONType.true_;
        
        // Umbrella configuration
        if ("umbrella" in json)
        {
            auto umb = json["umbrella"];
            if ("appsDir" in umb) config.dependencies.umbrella.appsDir = umb["appsDir"].str;
            if ("apps" in umb) config.dependencies.umbrella.apps = umb["apps"].array.map!(e => e.str).array;
            if ("sharedDeps" in umb) config.dependencies.umbrella.sharedDeps = umb["sharedDeps"].type == JSONType.true_;
            if ("buildAll" in umb) config.dependencies.umbrella.buildAll = umb["buildAll"].type == JSONType.true_;
            if ("excludeApps" in umb) config.dependencies.umbrella.excludeApps = umb["excludeApps"].array.map!(e => e.str).array;
        }
        
        // Hex configuration
        if ("hex" in json)
        {
            auto hex = json["hex"];
            if ("packageName" in hex) config.dependencies.hex.packageName = hex["packageName"].str;
            if ("organization" in hex) config.dependencies.hex.organization = hex["organization"].str;
            if ("description" in hex) config.dependencies.hex.description = hex["description"].str;
            if ("files" in hex) config.dependencies.hex.files = hex["files"].array.map!(e => e.str).array;
            if ("licenses" in hex) config.dependencies.hex.licenses = hex["licenses"].array.map!(e => e.str).array;
            if ("maintainers" in hex) config.dependencies.hex.maintainers = hex["maintainers"].array.map!(e => e.str).array;
            if ("apiKeyPath" in hex) config.dependencies.hex.apiKeyPath = hex["apiKeyPath"].str;
            if ("publish" in hex) config.dependencies.hex.publish = hex["publish"].type == JSONType.true_;
            if ("buildDocs" in hex) config.dependencies.hex.buildDocs = hex["buildDocs"].type == JSONType.true_;
            if ("links" in hex)
            {
                foreach (string key, ref value; hex["links"].object)
                    config.dependencies.hex.links[key] = value.str;
            }
        }
        
        // Dialyzer configuration
        if ("dialyzer" in json)
        {
            auto dia = json["dialyzer"];
            if ("enabled" in dia) config.quality.dialyzer.enabled = dia["enabled"].type == JSONType.true_;
            if ("pltFile" in dia) config.quality.dialyzer.pltFile = dia["pltFile"].str;
            if ("pltApps" in dia) config.quality.dialyzer.pltApps = dia["pltApps"].array.map!(e => e.str).array;
            if ("flags" in dia) config.quality.dialyzer.flags = dia["flags"].array.map!(e => e.str).array;
            if ("warnings" in dia) config.quality.dialyzer.warnings = dia["warnings"].array.map!(e => e.str).array;
            if ("paths" in dia) config.quality.dialyzer.paths = dia["paths"].array.map!(e => e.str).array;
            if ("removeDefaults" in dia) config.quality.dialyzer.removeDefaults = dia["removeDefaults"].type == JSONType.true_;
            if ("listUnusedFilters" in dia) config.quality.dialyzer.listUnusedFilters = dia["listUnusedFilters"].type == JSONType.true_;
            if ("ignoreWarnings" in dia) config.quality.dialyzer.ignoreWarnings = dia["ignoreWarnings"].str;
            if ("format" in dia) config.quality.dialyzer.format = dia["format"].str;
        }
        
        // Credo configuration
        if ("credo" in json)
        {
            auto credo = json["credo"];
            if ("enabled" in credo) config.quality.credo.enabled = credo["enabled"].type == JSONType.true_;
            if ("strict" in credo) config.quality.credo.strict = credo["strict"].type == JSONType.true_;
            if ("all" in credo) config.quality.credo.all = credo["all"].type == JSONType.true_;
            if ("configFile" in credo) config.quality.credo.configFile = credo["configFile"].str;
            if ("checks" in credo) config.quality.credo.checks = credo["checks"].array.map!(e => e.str).array;
            if ("files" in credo) config.quality.credo.files = credo["files"].array.map!(e => e.str).array;
            if ("minPriority" in credo) config.quality.credo.minPriority = credo["minPriority"].str;
            if ("format" in credo) config.quality.credo.format = credo["format"].str;
            if ("enableExplanations" in credo) config.quality.credo.enableExplanations = credo["enableExplanations"].type == JSONType.true_;
        }
        
        // Format configuration
        if ("format" in json)
        {
            auto fmt = json["format"];
            if ("enabled" in fmt) config.quality.format.enabled = fmt["enabled"].type == JSONType.true_;
            if ("inputs" in fmt) config.quality.format.inputs = fmt["inputs"].array.map!(e => e.str).array;
            if ("checkFormatted" in fmt) config.quality.format.checkFormatted = fmt["checkFormatted"].type == JSONType.true_;
            if ("plugins" in fmt) config.quality.format.plugins = fmt["plugins"].array.map!(e => e.str).array;
            if ("importDeps" in fmt) config.quality.format.importDeps = fmt["importDeps"].type == JSONType.true_;
            if ("exportLocalsWithoutParens" in fmt) config.quality.format.exportLocalsWithoutParens = fmt["exportLocalsWithoutParens"].type == JSONType.true_;
            if ("dotFormatterPath" in fmt) config.quality.format.dotFormatterPath = fmt["dotFormatterPath"].str;
        }
        
        // Documentation configuration
        if ("documentation" in json)
        {
            auto doc = json["documentation"];
            if ("enabled" in doc) config.quality.documentation.enabled = doc["enabled"].type == JSONType.true_;
            if ("main" in doc) config.quality.documentation.main = doc["main"].str;
            if ("sourceUrl" in doc) config.quality.documentation.sourceUrl = doc["sourceUrl"].str;
            if ("homepageUrl" in doc) config.quality.documentation.homepageUrl = doc["homepageUrl"].str;
            if ("logo" in doc) config.quality.documentation.logo = doc["logo"].str;
            if ("formatters" in doc) config.quality.documentation.formatters = doc["formatters"].array.map!(e => e.str).array;
            if ("output" in doc) config.quality.documentation.output = doc["output"].str;
            if ("extras" in doc) config.quality.documentation.extras = doc["extras"].array.map!(e => e.str).array;
            if ("api" in doc) config.quality.documentation.api = doc["api"].type == JSONType.true_;
            if ("canonical" in doc) config.quality.documentation.canonical = doc["canonical"].str;
            if ("language" in doc) config.quality.documentation.language = doc["language"].str;
            if ("groups" in doc)
            {
                foreach (string key, ref value; doc["groups"].object)
                    config.quality.documentation.groups[key] = value.str;
            }
        }
        
        // ExUnit configuration
        if ("exunit" in json)
        {
            auto ex = json["exunit"];
            if ("testPaths" in ex) config.testing.exunit.testPaths = ex["testPaths"].array.map!(e => e.str).array;
            if ("testPattern" in ex) config.testing.exunit.testPattern = ex["testPattern"].str;
            if ("coverageTool" in ex) config.testing.exunit.coverageTool = ex["coverageTool"].str;
            if ("trace" in ex) config.testing.exunit.trace = ex["trace"].type == JSONType.true_;
            if ("maxCases" in ex) config.testing.exunit.maxCases = cast(int)ex["maxCases"].integer;
            if ("exclude" in ex) config.testing.exunit.exclude = ex["exclude"].array.map!(e => e.str).array;
            if ("include" in ex) config.testing.exunit.include = ex["include"].array.map!(e => e.str).array;
            if ("only" in ex) config.testing.exunit.only = ex["only"].array.map!(e => e.str).array;
            if ("seed" in ex) config.testing.exunit.seed = cast(int)ex["seed"].integer;
            if ("timeout" in ex) config.testing.exunit.timeout = cast(int)ex["timeout"].integer;
            if ("slowTestThreshold" in ex) config.testing.exunit.slowTestThreshold = cast(int)ex["slowTestThreshold"].integer;
            if ("captureLog" in ex) config.testing.exunit.captureLog = ex["captureLog"].type == JSONType.true_;
            if ("colors" in ex) config.testing.exunit.colors = ex["colors"].type == JSONType.true_;
            if ("formatters" in ex) config.testing.exunit.formatters = ex["formatters"].array.map!(e => e.str).array;
        }
        
        // Coveralls configuration
        if ("coveralls" in json)
        {
            auto cov = json["coveralls"];
            if ("enabled" in cov) config.testing.coveralls.enabled = cov["enabled"].type == JSONType.true_;
            if ("service" in cov) config.testing.coveralls.service = cov["service"].str;
            if ("treatNoRelevantLinesAsSuccess" in cov) 
                config.testing.coveralls.treatNoRelevantLinesAsSuccess = cov["treatNoRelevantLinesAsSuccess"].type == JSONType.true_;
            if ("outputDir" in cov) config.testing.coveralls.outputDir = cov["outputDir"].str;
            if ("coverageOptions" in cov) config.testing.coveralls.coverageOptions = cov["coverageOptions"].str;
            if ("post" in cov) config.testing.coveralls.post = cov["post"].type == JSONType.true_;
            if ("ignoreModules" in cov) config.testing.coveralls.ignoreModules = cov["ignoreModules"].array.map!(e => e.str).array;
            if ("stopWords" in cov) config.testing.coveralls.stopWords = cov["stopWords"].array.map!(e => e.str).array;
            if ("minCoverage" in cov) config.testing.coveralls.minCoverage = cast(float)cov["minCoverage"].floating;
        }
        
        // Environment variables
        if ("env" in json && json["env"].type == JSONType.object)
        {
            foreach (string key, ref value; json["env"].object)
                config.build.env[key] = value.str;
        }
        
        return config;
    }
}

