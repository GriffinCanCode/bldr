module languages.jvm.java.tooling.builders.war;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.java.tooling.builders.base;
import languages.jvm.java.tooling.builders.jar;
import languages.jvm.java.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;
import engine.caching.actions.action : ActionCache;

/// WAR (Web Application Archive) builder
class WARBuilder : JARBuilder
{
    this(ActionCache actionCache = null)
    {
        super(actionCache);
    }
    
    override string name() const
    {
        return "WAR";
    }
    
    override bool supportsMode(JavaBuildMode mode)
    {
        return mode == JavaBuildMode.WAR || mode == JavaBuildMode.EAR || mode == JavaBuildMode.RAR;
    }
    
    override JavaBuildResult build(
        in string[] sources,
        in JavaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        JavaBuildResult result;
        
        structuredLog.debug_("building_war_").field("detail", "Building WAR: " ~ target.name).emit();
        
        // Determine output path
        string outputPath = getOutputPath(target, workspace, config);
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Create temporary build directory with WAR structure
        string tempDir = buildPath(outputDir, ".java-war-" ~ target.name.split(":")[$ - 1]);
        if (exists(tempDir))
            rmdirRecurse(tempDir);
        
        // Create WAR directory structure
        string webInfDir = buildPath(tempDir, "WEB-INF");
        string classesDir = buildPath(webInfDir, "classes");
        string libDir = buildPath(webInfDir, "lib");
        
        mkdirRecurse(classesDir);
        mkdirRecurse(libDir);
        
        scope(failure)
        {
            if (exists(tempDir))
            {
                try {
                    rmdirRecurse(tempDir);
                }
                catch (Exception e) {
                    // Ignore cleanup errors
                }
            }
        }
        
        scope(success)
        {
            if (exists(tempDir))
                rmdirRecurse(tempDir);
        }
        
        // Compile sources to WEB-INF/classes
        if (!compileSources(sources, classesDir, config, target, workspace, result))
            return result;
        
        // Copy web resources (if they exist)
        copyWebResources(tempDir, workspace.root);
        
        // Copy dependencies to WEB-INF/lib
        copyDependenciesToLib(libDir, target, workspace, config);
        
        // Create WAR file
        if (!createWAR(tempDir, outputPath, result))
            return result;
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    protected override string getOutputPath(const Target target, const WorkspaceConfig workspace, const JavaConfig config)
    {
        if (!target.outputPath.empty)
            return buildPath(workspace.options.outputDir, target.outputPath);
        
        string name = target.name.split(":")[$ - 1];
        string ext = ".war";
        
        // Determine extension based on mode
        if (config.mode == JavaBuildMode.EAR)
            ext = ".ear";
        else if (config.mode == JavaBuildMode.RAR)
            ext = ".rar";
        
        return buildPath(workspace.options.outputDir, name ~ ext);
    }
    
    private void copyWebResources(string warDir, string projectRoot)
    {
        // Look for standard web resources locations
        string[] webDirs = [
            buildPath(projectRoot, "src", "main", "webapp"),
            buildPath(projectRoot, "webapp"),
            buildPath(projectRoot, "web")
        ];
        
        foreach (webDir; webDirs)
        {
            if (exists(webDir) && isDir(webDir))
            {
                structuredLog.info("copying_web_resources_from_").field("detail", "Copying web resources from: " ~ webDir).emit();
                copyRecursive(webDir, warDir);
                break;
            }
        }
    }
    
    private void copyDependenciesToLib(
        string libDir,
        const Target target,
        const WorkspaceConfig workspace,
        const JavaConfig config
    )
    {
        foreach (dep; target.deps)
        {
            auto depTarget = workspace.findTarget(dep);
            if (depTarget !is null)
            {
                string depJar = super.getOutputPath(*depTarget, workspace, config);
                if (exists(depJar) && depJar.endsWith(".jar"))
                {
                    string destPath = buildPath(libDir, baseName(depJar));
                    copy(depJar, destPath);
                }
            }
        }
    }
    
    private void copyRecursive(string source, string dest)
    {
        import std.file : dirEntries, SpanMode;
        
        foreach (entry; dirEntries(source, SpanMode.depth))
        {
            // Validate entry path is within source directory to prevent traversal attacks
            if (!SecurityValidator.isPathWithinBase(entry.name, source))
                continue;
            
            string relativePath = entry.relativePath(source);
            string destPath = buildPath(dest, relativePath);
            
            // Validate destination path to prevent writing outside dest directory
            if (!SecurityValidator.isPathWithinBase(destPath, dest))
                continue;
            
            if (entry.isDir)
            {
                if (!exists(destPath))
                    mkdirRecurse(destPath);
            }
            else if (entry.isFile)
            {
                string destDir = dirName(destPath);
                if (!exists(destDir))
                    mkdirRecurse(destDir);
                copy(entry, destPath);
            }
        }
    }
    
    private bool createWAR(string warDir, string outputPath, ref JavaBuildResult result)
    {
        structuredLog.info("creating_war_").field("detail", "Creating WAR: " ~ outputPath).emit();
        
        string[] cmd = ["jar", "cf", outputPath, "-C", warDir, "."];
        
        auto jarRes = execute(cmd);
        
        if (jarRes.status != 0)
        {
            result.error = "WAR creation failed:\n" ~ jarRes.output;
            return false;
        }
        
        return true;
    }
}

