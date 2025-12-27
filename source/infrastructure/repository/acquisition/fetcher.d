module infrastructure.repository.acquisition.fetcher;

import std.file : write, mkdirRecurse, exists, remove, tempDir;
import std.path : buildPath, dirName, baseName;
import std.process : execute, Config;
import std.string : endsWith, startsWith, format;
import std.datetime : Clock;
import infrastructure.repository.core.types;
import infrastructure.repository.acquisition.verifier;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Repository fetcher - downloads and extracts repositories
final class RepositoryFetcher
{
    private string cacheDir;
    private size_t maxRetries = 3;
    
    this(string cacheDir) @safe
    {
        this.cacheDir = cacheDir;
    }
    
    /// Fetch repository and return local path
    Result!(string, RepositoryError) fetch(ref const RepositoryRule rule) @trusted
    {
        // Validate rule first
        auto validationResult = rule.validate();
        if (validationResult.isErr)
            return Result!(string, RepositoryError).err(validationResult.unwrapErr());
        
        structuredLog.info("fetching_repository_").field("detail", "Fetching repository: " ~ rule.name).emit();
        
        final switch (rule.kind)
        {
            case RepositoryKind.Http:
                return fetchHttp(rule);
            case RepositoryKind.Git:
                return fetchGit(rule);
            case RepositoryKind.Local:
                return fetchLocal(rule);
        }
    }
    
    /// Fetch HTTP archive
    private Result!(string, RepositoryError) fetchHttp(ref const RepositoryRule rule) @trusted
    {
        immutable cacheKey = rule.cacheKey();
        immutable targetDir = buildPath(cacheDir, "repositories", rule.name, cacheKey);
        
        // If already cached, return it
        if (exists(targetDir))
        {
            structuredLog.debug_("repository_already_cached_").field("detail", "Repository already cached: " ~ rule.name).emit();
            return Result!(string, RepositoryError).ok(targetDir);
        }
        
        // Download to temp file
        immutable tempFile = buildPath(tempDir(), "builder-repo-" ~ cacheKey);
        scope(exit) if (exists(tempFile)) remove(tempFile);
        
        auto downloadResult = downloadWithRetry(rule.url, tempFile);
        if (downloadResult.isErr)
            return Result!(string, RepositoryError).err(downloadResult.unwrapErr());
        
        // Verify integrity
        auto verifyResult = IntegrityVerifier.verify(tempFile, rule.integrity);
        if (verifyResult.isErr)
            return Result!(string, RepositoryError).err(verifyResult.unwrapErr());
        
        structuredLog.info("downloaded_and_verified_").field("detail", "Downloaded and verified: " ~ rule.name).emit();
        
        // Extract archive
        mkdirRecurse(targetDir);
        auto extractResult = extractArchive(tempFile, targetDir, rule.format, rule.stripPrefix);
        if (extractResult.isErr)
            return Result!(string, RepositoryError).err(extractResult.unwrapErr());
        
        structuredLog.info("extracted_repository_").field("detail", "Extracted repository: " ~ rule.name).emit();
        
        return Result!(string, RepositoryError).ok(targetDir);
    }
    
    /// Download file with retry logic
    private Result!RepositoryError downloadWithRetry(string url, string outputPath) @trusted
    {
        import std.net.curl : download, HTTP, CurlException;
        import core.thread : Thread;
        import core.time : seconds;
        
        for (size_t attempt = 0; attempt < maxRetries; attempt++)
        {
            try
            {
                structuredLog.info("downloading_").field("detail", "Downloading " ~ url ~ " (attempt " ~ (attempt + 1).to!string ~ ")").emit();
                
                // Use std.net.curl for HTTP downloads
                download(url, outputPath);
                
                if (exists(outputPath))
                    return Ok!RepositoryError();
            }
            catch (CurlException e)
            {
                structuredLog.warning("download_failed_").field("detail", "Download failed: " ~ e.msg).emit();
                if (attempt < maxRetries - 1)
                {
                    Thread.sleep(seconds(2 ^^ attempt)); // Exponential backoff
                    continue;
                }
                return Result!RepositoryError.err(
                    new RepositoryError("Failed to download " ~ url ~ " after " ~ maxRetries.to!string ~ " attempts: " ~ e.msg));
            }
            catch (Exception e)
            {
                return Result!RepositoryError.err(
                    new RepositoryError("Unexpected error downloading " ~ url ~ ": " ~ e.msg));
            }
        }
        
        return Result!RepositoryError.err(
            new RepositoryError("Failed to download " ~ url));
    }
    
    /// Extract archive to directory
    private Result!RepositoryError extractArchive(
        string archivePath,
        string targetDir,
        ArchiveFormat format,
        string stripPrefix
    ) @trusted
    {
        // Detect format from file extension if Auto
        auto actualFormat = format;
        if (format == ArchiveFormat.Auto)
        {
            actualFormat = detectFormat(archivePath);
        }
        
        // Build extraction command
        string[] cmd;
        final switch (actualFormat)
        {
            case ArchiveFormat.Auto:
                return Result!RepositoryError.err(
                    new RepositoryError("Could not detect archive format"));
            
            case ArchiveFormat.TarGz:
                cmd = ["tar", "-xzf", archivePath, "-C", targetDir];
                if (stripPrefix.length > 0)
                    cmd ~= ["--strip-components=1"];
                break;
            
            case ArchiveFormat.Tar:
                cmd = ["tar", "-xf", archivePath, "-C", targetDir];
                if (stripPrefix.length > 0)
                    cmd ~= ["--strip-components=1"];
                break;
            
            case ArchiveFormat.Zip:
                cmd = ["unzip", "-q", archivePath, "-d", targetDir];
                break;
            
            case ArchiveFormat.TarXz:
                cmd = ["tar", "-xJf", archivePath, "-C", targetDir];
                if (stripPrefix.length > 0)
                    cmd ~= ["--strip-components=1"];
                break;
            
            case ArchiveFormat.TarBz2:
                cmd = ["tar", "-xjf", archivePath, "-C", targetDir];
                if (stripPrefix.length > 0)
                    cmd ~= ["--strip-components=1"];
                break;
        }
        
        // Execute extraction
        auto result = execute(cmd);
        if (result.status != 0)
        {
            return Result!RepositoryError.err(
                new RepositoryError("Failed to extract archive: " ~ result.output));
        }
        
        return Ok!RepositoryError();
    }
    
    /// Detect archive format from file extension
    private ArchiveFormat detectFormat(string path) pure @safe nothrow
    {
        if (path.endsWith(".tar.gz") || path.endsWith(".tgz"))
            return ArchiveFormat.TarGz;
        else if (path.endsWith(".tar.xz"))
            return ArchiveFormat.TarXz;
        else if (path.endsWith(".tar.bz2"))
            return ArchiveFormat.TarBz2;
        else if (path.endsWith(".tar"))
            return ArchiveFormat.Tar;
        else if (path.endsWith(".zip"))
            return ArchiveFormat.Zip;
        else
            return ArchiveFormat.Auto;
    }
    
    /// Fetch Git repository
    private Result!(string, RepositoryError) fetchGit(ref const RepositoryRule rule) @trusted
    {
        immutable cacheKey = rule.cacheKey();
        immutable targetDir = buildPath(cacheDir, "repositories", rule.name, cacheKey);
        
        // If already cached, return it
        if (exists(targetDir))
        {
            structuredLog.debug_("repository_already_cached_").field("detail", "Repository already cached: " ~ rule.name).emit();
            return Result!(string, RepositoryError).ok(targetDir);
        }
        
        mkdirRecurse(dirName(targetDir));
        
        // Clone repository
        structuredLog.info("cloning_git_repository_").field("detail", "Cloning Git repository: " ~ rule.url).emit();
        
        string[] cloneCmd = ["git", "clone"];
        
        // Use specific commit or tag
        if (rule.gitCommit.length > 0)
        {
            cloneCmd ~= ["--depth", "1", "--branch", rule.gitCommit];
        }
        else if (rule.gitTag.length > 0)
        {
            cloneCmd ~= ["--depth", "1", "--branch", rule.gitTag];
        }
        
        cloneCmd ~= [rule.url, targetDir];
        
        auto result = execute(cloneCmd);
        if (result.status != 0)
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("Failed to clone Git repository: " ~ result.output));
        }
        
        structuredLog.info("cloned_git_repository_").field("detail", "Cloned Git repository: " ~ rule.name).emit();
        
        return Result!(string, RepositoryError).ok(targetDir);
    }
    
    /// Fetch local repository (just validate path exists)
    private Result!(string, RepositoryError) fetchLocal(ref const RepositoryRule rule) @trusted
    {
        import std.file : isDir;
        
        if (!exists(rule.url))
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("Local repository path does not exist: " ~ rule.url));
        }
        
        if (!isDir(rule.url))
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("Local repository path is not a directory: " ~ rule.url));
        }
        
        structuredLog.debug_("using_local_repository_").field("detail", "Using local repository: " ~ rule.name ~ " at " ~ rule.url).emit();
        
        return Result!(string, RepositoryError).ok(rule.url);
    }
}

private import std.conv : to;

