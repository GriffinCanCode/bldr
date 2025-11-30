module infrastructure.utils.files.directories;

import std.file : exists, mkdirRecurse, write;
import std.path : buildPath;

/// Ensure a directory exists and contains a .gitignore file that ignores all content
/// 
/// Params:
///     dirPath = Path to the directory
///     ignoreContent = Content for .gitignore (default: "*")
/// 
/// Safety: @system (file I/O)
void ensureDirectoryWithGitignore(string dirPath, string ignoreContent = "*\n") @system
{
    if (!exists(dirPath))
        mkdirRecurse(dirPath);
    
    const gitignorePath = buildPath(dirPath, ".gitignore");
    if (!exists(gitignorePath))
        write(gitignorePath, ignoreContent);
}

