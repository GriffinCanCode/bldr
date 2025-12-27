module languages.scripting.r.managers.environments;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.info;
import infrastructure.utils.logging;

/// Environment management result
struct EnvResult
{
    bool success;
    string error;
    string envPath;
}

/// Initialize R environment
EnvResult initializeEnvironment(
    REnvManager manager,
    string workDir,
    string rCmd,
    const ref RConfig config
)
{
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    if (manager == REnvManager.None)
    {
        return EnvResult(true, "", "");
    }
    
    structuredLog.info("initializing_r_environment_with_").field("detail", "Initializing R environment with " ~ manager.to!string).emit();
    
    final switch (manager)
    {
        case REnvManager.Auto:
            return EnvResult(false, "Failed to auto-detect environment manager", "");
            
        case REnvManager.Renv:
            return initRenv(workDir, rCmd, config);
            
        case REnvManager.Packrat:
            return initPackrat(workDir, rCmd, config);
            
        case REnvManager.None:
            return EnvResult(true, "", "");
    }
}

/// Initialize renv environment
private EnvResult initRenv(string workDir, string rCmd, const ref RConfig config)
{
    string renvDir = buildPath(workDir, "renv");
    string renvLock = buildPath(workDir, "renv.lock");
    
    // Check if already initialized
    if (exists(renvDir) && isDir(renvDir))
    {
        structuredLog.debug_("renv_environment_already_exists_at_").field("detail", "renv environment already exists at: " ~ renvDir).emit();
        return EnvResult(true, "", renvDir);
    }
    
    // Initialize renv
    string initCode = `renv::init(bare=TRUE, restart=FALSE)`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", initCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to initialize renv: " ~ res.output, "");
    }
    
    structuredLog.info("created_renv_environment_at_").field("detail", "Created renv environment at: " ~ renvDir).emit();
    return EnvResult(true, "", renvDir);
}

/// Initialize packrat environment
private EnvResult initPackrat(string workDir, string rCmd, const ref RConfig config)
{
    string packratDir = buildPath(workDir, "packrat");
    
    // Check if already initialized
    if (exists(packratDir) && isDir(packratDir))
    {
        structuredLog.debug_("packrat_environment_already_exists_at_").field("detail", "packrat environment already exists at: " ~ packratDir).emit();
        return EnvResult(true, "", packratDir);
    }
    
    // Initialize packrat
    string initCode = `packrat::init()`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", initCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to initialize packrat: " ~ res.output, "");
    }
    
    structuredLog.info("created_packrat_environment_at_").field("detail", "Created packrat environment at: " ~ packratDir).emit();
    return EnvResult(true, "", packratDir);
}

/// Restore environment from lockfile
EnvResult restoreEnvironment(
    REnvManager manager,
    string workDir,
    string rCmd,
    const ref RConfig config
)
{
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    if (manager == REnvManager.None)
    {
        return EnvResult(true, "", "");
    }
    
    structuredLog.info("restoring_r_environment_from_lockfile").emit();
    
    final switch (manager)
    {
        case REnvManager.Auto:
            return EnvResult(false, "Failed to auto-detect environment manager", "");
            
        case REnvManager.Renv:
            return restoreRenv(workDir, rCmd, config);
            
        case REnvManager.Packrat:
            return restorePackrat(workDir, rCmd, config);
            
        case REnvManager.None:
            return EnvResult(true, "", "");
    }
}

/// Restore renv environment
private EnvResult restoreRenv(string workDir, string rCmd, const ref RConfig config)
{
    string renvLock = buildPath(workDir, "renv.lock");
    
    if (!exists(renvLock))
    {
        return EnvResult(false, "renv.lock not found", "");
    }
    
    string restoreCode = `renv::restore(prompt=FALSE)`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", restoreCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to restore renv: " ~ res.output, "");
    }
    
    structuredLog.info("restored_renv_environment_from_renvlock").emit();
    return EnvResult(true, "", buildPath(workDir, "renv"));
}

/// Restore packrat environment
private EnvResult restorePackrat(string workDir, string rCmd, const ref RConfig config)
{
    string packratLock = buildPath(workDir, "packrat", "packrat.lock");
    
    if (!exists(packratLock))
    {
        return EnvResult(false, "packrat.lock not found", "");
    }
    
    string restoreCode = `packrat::restore(prompt=FALSE)`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", restoreCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to restore packrat: " ~ res.output, "");
    }
    
    structuredLog.info("restored_packrat_environment_from_packra").emit();
    return EnvResult(true, "", buildPath(workDir, "packrat"));
}

/// Snapshot environment to lockfile
EnvResult snapshotEnvironment(
    REnvManager manager,
    string workDir,
    string rCmd,
    const ref RConfig config
)
{
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    if (manager == REnvManager.None)
    {
        return EnvResult(true, "", "");
    }
    
    structuredLog.info("creating_environment_snapshot").emit();
    
    final switch (manager)
    {
        case REnvManager.Auto:
            return EnvResult(false, "Failed to auto-detect environment manager", "");
            
        case REnvManager.Renv:
            return snapshotRenv(workDir, rCmd, config);
            
        case REnvManager.Packrat:
            return snapshotPackrat(workDir, rCmd, config);
            
        case REnvManager.None:
            return EnvResult(true, "", "");
    }
}

/// Snapshot renv environment
private EnvResult snapshotRenv(string workDir, string rCmd, const ref RConfig config)
{
    string snapshotCode = `renv::snapshot(prompt=FALSE)`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", snapshotCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to snapshot renv: " ~ res.output, "");
    }
    
    string lockPath = buildPath(workDir, "renv.lock");
    structuredLog.info("created_renv_snapshot_").field("detail", "Created renv snapshot: " ~ lockPath).emit();
    return EnvResult(true, "", lockPath);
}

/// Snapshot packrat environment
private EnvResult snapshotPackrat(string workDir, string rCmd, const ref RConfig config)
{
    string snapshotCode = `packrat::snapshot()`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", snapshotCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to snapshot packrat: " ~ res.output, "");
    }
    
    string lockPath = buildPath(workDir, "packrat", "packrat.lock");
    structuredLog.info("created_packrat_snapshot_").field("detail", "Created packrat snapshot: " ~ lockPath).emit();
    return EnvResult(true, "", lockPath);
}

/// Clean environment (remove cached packages)
EnvResult cleanEnvironment(
    REnvManager manager,
    string workDir,
    string rCmd,
    const ref RConfig config
)
{
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    if (manager == REnvManager.None)
    {
        return EnvResult(true, "", "");
    }
    
    structuredLog.info("cleaning_r_environment").emit();
    
    final switch (manager)
    {
        case REnvManager.Auto:
            return EnvResult(false, "Failed to auto-detect environment manager", "");
            
        case REnvManager.Renv:
            return cleanRenv(workDir, rCmd, config);
            
        case REnvManager.Packrat:
            return cleanPackrat(workDir, rCmd, config);
            
        case REnvManager.None:
            return EnvResult(true, "", "");
    }
}

/// Clean renv environment
private EnvResult cleanRenv(string workDir, string rCmd, const ref RConfig config)
{
    string cleanCode = `renv::clean()`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", cleanCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to clean renv: " ~ res.output, "");
    }
    
    structuredLog.info("cleaned_renv_environment").emit();
    return EnvResult(true, "", "");
}

/// Clean packrat environment
private EnvResult cleanPackrat(string workDir, string rCmd, const ref RConfig config)
{
    string cleanCode = `packrat::clean()`;
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", cleanCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        return EnvResult(false, "Failed to clean packrat: " ~ res.output, "");
    }
    
    structuredLog.info("cleaned_packrat_environment").emit();
    return EnvResult(true, "", "");
}

/// Get environment status
struct EnvStatus
{
    bool exists;
    bool hasLockfile;
    string lockfilePath;
    int packageCount;
    string[] outdatedPackages;
}

/// Get environment status
EnvStatus getEnvironmentStatus(
    REnvManager manager,
    string workDir,
    string rCmd
)
{
    EnvStatus status;
    
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    final switch (manager)
    {
        case REnvManager.Auto:
        case REnvManager.None:
            return status;
            
        case REnvManager.Renv:
            string renvDir = buildPath(workDir, "renv");
            string renvLock = buildPath(workDir, "renv.lock");
            
            status.exists = exists(renvDir) && isDir(renvDir);
            status.hasLockfile = exists(renvLock);
            if (status.hasLockfile)
                status.lockfilePath = renvLock;
            
            if (status.exists)
            {
                // Get package count
                string countCode = `cat(length(.packages(all.available=TRUE)))`;
                auto res = execute([rCmd, "-e", countCode]);
                if (res.status == 0)
                {
                    import std.conv : to;
                    try {
                        status.packageCount = res.output.strip().to!int;
                    } catch (Exception e) {}
                }
            }
            return status;
            
        case REnvManager.Packrat:
            string packratDir = buildPath(workDir, "packrat");
            string packratLock = buildPath(workDir, "packrat", "packrat.lock");
            
            status.exists = exists(packratDir) && isDir(packratDir);
            status.hasLockfile = exists(packratLock);
            if (status.hasLockfile)
                status.lockfilePath = packratLock;
            
            if (status.exists)
            {
                // Get package count
                string countCode = `cat(nrow(packrat:::lockInfo()$packages))`;
                auto res = execute([rCmd, "-e", countCode]);
                if (res.status == 0)
                {
                    import std.conv : to;
                    try {
                        status.packageCount = res.output.strip().to!int;
                    } catch (Exception e) {}
                }
            }
            return status;
    }
}

/// Activate environment for execution
string[] getEnvironmentActivationCommands(
    REnvManager manager,
    string workDir,
    const ref RConfig config
)
{
    string[] commands;
    
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(config.rExecutable);
    }
    
    final switch (manager)
    {
        case REnvManager.Auto:
        case REnvManager.None:
            return commands;
            
        case REnvManager.Renv:
            // renv activates automatically via .Rprofile
            // But we can ensure it's activated
            commands ~= `renv::activate()`;
            return commands;
            
        case REnvManager.Packrat:
            // packrat also activates via .Rprofile
            commands ~= `packrat::on()`;
            return commands;
    }
}

/// Prepare environment variables for R execution with environment isolation
private string[string] prepareEnvironment(const ref RConfig config)
{
    import std.process : environment;
    
    string[string] env;
    
    // Copy system environment
    foreach (key, value; environment.toAA())
        env[key] = value;
    
    // Add custom R environment variables
    foreach (key, value; config.rEnv)
        env[key] = value;
    
    // Add library paths
    if (!config.libPaths.empty)
    {
        env["R_LIBS_USER"] = config.libPaths.join(":");
    }
    
    return env;
}

/// Check if environment is in sync with lockfile
bool isEnvironmentInSync(
    REnvManager manager,
    string workDir,
    string rCmd,
    const ref RConfig config
)
{
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    final switch (manager)
    {
        case REnvManager.Auto:
        case REnvManager.None:
            return true;
            
        case REnvManager.Renv:
            string statusCode = `cat(renv::status()$synchronized)`;
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", statusCode], env, Config.none, size_t.max, workDir);
            if (res.status == 0)
            {
                return res.output.strip().toLower() == "true";
            }
            return false;
            
        case REnvManager.Packrat:
            // packrat doesn't have a simple sync check
            // Return true if lockfile exists
            return exists(buildPath(workDir, "packrat", "packrat.lock"));
    }
}

/// Update environment packages
EnvResult updateEnvironment(
    REnvManager manager,
    string workDir,
    string rCmd,
    const ref RConfig config
)
{
    if (manager == REnvManager.Auto)
    {
        manager = detectBestEnvManager(rCmd);
    }
    
    if (manager == REnvManager.None)
    {
        return EnvResult(true, "", "");
    }
    
    structuredLog.info("updating_r_environment_packages").emit();
    
    final switch (manager)
    {
        case REnvManager.Auto:
            return EnvResult(false, "Failed to auto-detect environment manager", "");
            
        case REnvManager.Renv:
            string updateCode = `renv::update()`;
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", updateCode], env, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                return EnvResult(false, "Failed to update renv: " ~ res.output, "");
            }
            
            structuredLog.info("updated_renv_environment").emit();
            return EnvResult(true, "", buildPath(workDir, "renv"));
            
        case REnvManager.Packrat:
            // packrat doesn't have a simple update command
            return EnvResult(false, "Update not supported for packrat", "");
            
        case REnvManager.None:
            return EnvResult(true, "", "");
    }
}

