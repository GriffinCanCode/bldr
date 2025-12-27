module infrastructure.parsing.treesitter.deps;

import std.process;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.conv;
import std.string;
import infrastructure.utils.logging;

/// Tree-sitter dependency checker
/// Verifies that tree-sitter is properly installed and linked
struct TreeSitterDeps {
    
    /// Check if tree-sitter library is available
    static bool isInstalled() @system {
        // Try pkg-config first
        if (checkPkgConfig())
            return true;
        
        // Check common installation paths
        version(OSX) {
            return checkMacOSPaths();
        } else version(linux) {
            return checkLinuxPaths();
        } else {
            return false;
        }
    }
    
    /// Get installation info for diagnostics
    static string getInstallInfo() @system {
        auto result = appender!string;
        
        result ~= "Tree-sitter Installation Info:\n";
        result ~= "==============================\n\n";
        
        // Check pkg-config
        if (checkPkgConfig()) {
            result ~= "✓ Found via pkg-config\n";
            auto versionResult = execute(["pkg-config", "--modversion", "tree-sitter"]);
            if (versionResult.status == 0) {
                result ~= "  Version: " ~ versionResult.output.strip ~ "\n";
            }
            auto cflagsResult = execute(["pkg-config", "--cflags", "tree-sitter"]);
            if (cflagsResult.status == 0) {
                result ~= "  CFLAGS: " ~ cflagsResult.output.strip ~ "\n";
            }
            auto libsResult = execute(["pkg-config", "--libs", "tree-sitter"]);
            if (libsResult.status == 0) {
                result ~= "  LIBS: " ~ libsResult.output.strip ~ "\n";
            }
        } else {
            result ~= "✗ Not found via pkg-config\n";
        }
        
        result ~= "\nLibrary Search:\n";
        
        // Check library paths
        version(OSX) {
            result ~= checkPath("/opt/homebrew/lib/libtree-sitter.dylib", "Homebrew (Apple Silicon)");
            result ~= checkPath("/opt/homebrew/lib/libtree-sitter.a", "Homebrew static (Apple Silicon)");
            result ~= checkPath("/usr/local/lib/libtree-sitter.dylib", "Homebrew (Intel)");
            result ~= checkPath("/usr/local/lib/libtree-sitter.a", "Homebrew static (Intel)");
        } else version(linux) {
            result ~= checkPath("/usr/lib/libtree-sitter.so", "System library");
            result ~= checkPath("/usr/local/lib/libtree-sitter.so", "Local installation");
            result ~= checkPath("/usr/lib/x86_64-linux-gnu/libtree-sitter.so", "Debian/Ubuntu");
        }
        
        // Check headers
        result ~= "\nHeader Search:\n";
        version(OSX) {
            result ~= checkPath("/opt/homebrew/include/tree_sitter/api.h", "Homebrew headers (Apple Silicon)");
            result ~= checkPath("/usr/local/include/tree_sitter/api.h", "Homebrew headers (Intel)");
        } else version(linux) {
            result ~= checkPath("/usr/include/tree_sitter/api.h", "System headers");
            result ~= checkPath("/usr/local/include/tree_sitter/api.h", "Local headers");
        }
        
        return result.data;
    }
    
    /// Print installation instructions
    static void printInstallInstructions() @system {
        structuredLog.info("treesitter_not_found_to_install").emit();
        structuredLog.info("log_event").emit();
        version(OSX) {
            structuredLog.info("__macos").emit();
            structuredLog.info("____brew_install_treesitter").emit();
        } else version(linux) {
            structuredLog.info("__ubuntudebian").emit();
            structuredLog.info("____sudo_aptget_install_libtreesitterdev").emit();
            structuredLog.info("log_event").emit();
            structuredLog.info("__fedorarhel").emit();
            structuredLog.info("____sudo_yum_install_treesitter").emit();
        }
        structuredLog.info("log_event").emit();
        structuredLog.info("__from_source").emit();
        structuredLog.info("____git_clone_httpsgithubcomtreesittertr").emit();
        structuredLog.info("____cd_treesitter__make__sudo_make_insta").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("or_run_sourceinfrastructureparsingtreesi").emit();
    }
    
    private static bool checkPkgConfig() @system {
        try {
            auto result = execute(["pkg-config", "--exists", "tree-sitter"]);
            return result.status == 0;
        } catch (Exception) {
            return false;
        }
    }
    
    private static bool checkMacOSPaths() @system {
        // Check Homebrew paths (both Apple Silicon and Intel)
        return exists("/opt/homebrew/lib/libtree-sitter.dylib") ||
               exists("/opt/homebrew/lib/libtree-sitter.a") ||
               exists("/usr/local/lib/libtree-sitter.dylib") ||
               exists("/usr/local/lib/libtree-sitter.a");
    }
    
    private static bool checkLinuxPaths() @system {
        return exists("/usr/lib/libtree-sitter.so") ||
               exists("/usr/local/lib/libtree-sitter.so") ||
               exists("/usr/lib/x86_64-linux-gnu/libtree-sitter.so");
    }
    
    private static string checkPath(string path, string description) @system {
        if (exists(path)) {
            auto size = getSize(path);
            return "  ✓ " ~ description ~ "\n    " ~ path ~ " (" ~ formatSize(size) ~ ")\n";
        }
        return "  ✗ " ~ description ~ "\n    " ~ path ~ " (not found)\n";
    }
    
    private static string formatSize(ulong bytes) @safe {
        if (bytes < 1024)
            return bytes.to!string ~ " B";
        if (bytes < 1024 * 1024)
            return (bytes / 1024).to!string ~ " KB";
        return (bytes / (1024 * 1024)).to!string ~ " MB";
    }
}

/// Verify tree-sitter installation and log diagnostics
void verifyTreeSitterInstallation() @system {
    if (TreeSitterDeps.isInstalled()) {
        structuredLog.info("treesitter_library_found").emit();
        structuredLog.debug_("log_event").field("message", TreeSitterDeps.getInstallInfo()).emit();
    } else {
        structuredLog.warning("treesitter_library_not_found__falling_ba").emit();
        structuredLog.debug_("log_event").field("message", TreeSitterDeps.getInstallInfo()).emit();
        TreeSitterDeps.printInstallInstructions();
    }
}

