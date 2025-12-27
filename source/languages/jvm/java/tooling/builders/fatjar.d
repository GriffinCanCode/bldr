module languages.jvm.java.tooling.builders.fatjar;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.zip;
import languages.jvm.java.tooling.builders.base;
import languages.jvm.java.tooling.builders.jar;
import languages.jvm.java.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Fat JAR (uber-jar) builder - includes all dependencies
class FatJARBuilder : JARBuilder
{
    this(ActionCache actionCache = null)
    {
        super(actionCache);
    }
    
    override string name() const
    {
        return "FatJAR";
    }
    
    override bool supportsMode(JavaBuildMode mode)
    {
        return mode == JavaBuildMode.FatJAR;
    }
    
    override JavaBuildResult build(
        in string[] sources,
        in JavaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        JavaBuildResult result;
        
        structuredLog.debug_("building_fat_jar_").field("detail", "Building Fat JAR: " ~ target.name).emit();
        
        // Determine output path
        string outputPath = getOutputPath(target, workspace, config);
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Create atomic temporary directory (prevents TOCTOU attacks)
        import infrastructure.utils.security.tempdir : AtomicTempDir;
        auto atomicTempResult = AtomicTempDir.in_(outputDir, ".java-fatjar-" ~ target.name.split(":")[$ - 1].replace(":", "-"));
        if (atomicTempResult.isErr)
        {
            result.success = false;
            return result;
        }
        auto atomicTemp = atomicTempResult.unwrap();
        string tempDir = atomicTemp.get();
        
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
        
        // Compile sources
        if (!compileSources(sources, tempDir, config, target, workspace, result))
            return result;
        
        // Extract and merge dependencies
        if (!mergeDependencies(tempDir, target, workspace, config, result))
            return result;
        
        // Create fat JAR
        if (!createJAR(tempDir, outputPath, config, target, result))
            return result;
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    private bool mergeDependencies(
        string tempDir,
        const Target target,
        const WorkspaceConfig workspace,
        const JavaConfig config,
        ref JavaBuildResult result
    )
    {
        structuredLog.info("merging_dependencies_into_fat_jar").emit();
        
        foreach (dep; target.deps)
        {
            auto depTarget = workspace.findTarget(dep);
            if (depTarget !is null)
            {
                string depJar = getOutputPath(*depTarget, workspace, config);
                if (exists(depJar) && depJar.endsWith(".jar"))
                {
                    if (!extractJar(depJar, tempDir))
                    {
                        structuredLog.warning("failed_to_extract_dependency_").field("detail", "Failed to extract dependency: " ~ depJar).emit();
                    }
                }
            }
        }
        
        // Also extract from classpath entries
        foreach (cpEntry; config.classpath)
        {
            if (exists(cpEntry) && cpEntry.endsWith(".jar"))
            {
                if (!extractJar(cpEntry, tempDir))
                {
                    structuredLog.warning("failed_to_extract_classpath_entry_").field("detail", "Failed to extract classpath entry: " ~ cpEntry).emit();
                }
            }
        }
        
        return true;
    }
    
    private bool extractJar(string jarPath, string targetDir)
    {
        try
        {
            // Use jar command to extract
            auto result = execute(["jar", "xf", jarPath], null, Config.none, size_t.max, targetDir);
            return result.status == 0;
        }
        catch (Exception e)
        {
            structuredLog.warning("jar_extraction_failed_").field("detail", "JAR extraction failed: " ~ e.msg).emit();
            return false;
        }
    }
}

