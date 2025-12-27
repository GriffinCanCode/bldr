module infrastructure.errors.helpers.manifests;

import std.path : baseName, dirName, buildPath;
import std.string : format;
import std.file : exists;
import infrastructure.errors.types.types;
import infrastructure.errors.types.context;
import infrastructure.errors.codes;
import infrastructure.errors.helpers.builders : createParseError, createFileReadError;

/// Manifest-specific error helpers for ecosystem integration
/// 
/// These helpers create errors with manifest-specific context and actionable suggestions

/// Create error for manifest file not found
auto manifestNotFoundError(string manifestPath, string manifestType, string file = __FILE__, size_t line = __LINE__) @system
{
    string fileName = baseName(manifestPath);
    string dir = dirName(manifestPath);
    
    auto error = createFileReadError(
        manifestPath,
        format("No %s manifest found", manifestType),
        file,
        line
    );
    
    // Override with more specific suggestions based on manifest type
    // Note: Clear default suggestions and set manifest-specific ones
    
    if (manifestType == "npm" || fileName == "package.json")
    {
        error.addSuggestion(ErrorSuggestion.command("Initialize npm project", "npm init"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if package.json exists", manifestPath));
        error.addSuggestion(ErrorSuggestion.docs("See npm project setup", "docs/features/ecosystem-integration.md"));
    }
    else if (manifestType == "cargo" || fileName == "Cargo.toml")
    {
        error.addSuggestion(ErrorSuggestion.command("Initialize Cargo project", "cargo init"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if Cargo.toml exists", manifestPath));
        error.addSuggestion(ErrorSuggestion.docs("See Cargo documentation", "https://doc.rust-lang.org/cargo/"));
    }
    else if (manifestType == "go" || fileName == "go.mod")
    {
        error.addSuggestion(ErrorSuggestion.command("Initialize Go module", "go mod init <module-name>"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if go.mod exists", manifestPath));
    }
    else if (manifestType == "python" || fileName == "pyproject.toml" || fileName == "setup.py")
    {
        error.addSuggestion(ErrorSuggestion.command("Create pyproject.toml", "touch pyproject.toml"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check for Python project files", dir));
        error.addSuggestion(ErrorSuggestion.docs("See Python packaging guide", "https://packaging.python.org/"));
    }
    else if (manifestType == "composer" || fileName == "composer.json")
    {
        error.addSuggestion(ErrorSuggestion.command("Initialize Composer project", "composer init"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if composer.json exists", manifestPath));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Verify manifest file exists", manifestPath));
        error.addSuggestion(ErrorSuggestion("Use Builder's zero-config mode if no manifest exists"));
    }
    
    return error;
}

/// Create error for invalid manifest JSON/TOML
auto manifestParseError(
    string manifestPath,
    string manifestType,
    string parseErrorMsg,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string fileName = baseName(manifestPath);
    string fullMessage = format("Failed to parse %s manifest: %s", manifestType, parseErrorMsg);
    
    auto error = createParseError(
        manifestPath,
        fullMessage,
        Parse.Failed,
        file,
        line
    );
    
    // Note: createParseError already adds file-type specific suggestions based on filename
    // Add any additional manifest-specific context
    error.addContext(ErrorContext(
        format("parsing %s manifest", manifestType),
        parseErrorMsg
    ));
    
    return error;
}

/// Create error for missing required field in manifest
auto manifestMissingFieldError(
    string manifestPath,
    string manifestType,
    string fieldName,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string fileName = baseName(manifestPath);
    string message = format("Missing required field '%s' in %s", fieldName, fileName);
    
    auto error = createParseError(
        manifestPath,
        message,
        Parse.MissingField,
        file,
        line
    );
    
    // Add field-specific suggestions
    if (fieldName == "name")
    {
        error.addSuggestion(ErrorSuggestion.config(
            "Add 'name' field to your manifest",
            format(`name = "%s"`, baseName(dirName(manifestPath)))
        ));
    }
    else if (fieldName == "version")
    {
        error.addSuggestion(ErrorSuggestion.config(
            "Add 'version' field to your manifest",
            `version = "0.1.0"`
        ));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.config(
            format("Add required field '%s' to %s", fieldName, fileName)
        ));
    }
    
    // Add manifest-type specific documentation
    if (manifestType == "npm")
        error.addSuggestion(ErrorSuggestion.docs("See package.json spec", "https://docs.npmjs.com/cli/v8/configuring-npm/package-json"));
    else if (manifestType == "cargo")
        error.addSuggestion(ErrorSuggestion.docs("See Cargo.toml reference", "https://doc.rust-lang.org/cargo/reference/manifest.html"));
    else if (manifestType == "python")
        error.addSuggestion(ErrorSuggestion.docs("See pyproject.toml spec", "https://packaging.python.org/specifications/declaring-project-metadata/"));
    
    return error;
}

/// Create error for invalid field value in manifest
auto manifestInvalidFieldError(
    string manifestPath,
    string manifestType,
    string fieldName,
    string fieldValue,
    string expectedFormat,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string fileName = baseName(manifestPath);
    string message = format(
        "Invalid value for '%s' in %s: '%s' (expected: %s)",
        fieldName,
        fileName,
        fieldValue,
        expectedFormat
    );
    
    auto error = createParseError(
        manifestPath,
        message,
        Parse.InvalidFieldValue,
        file,
        line
    );
    
    error.addSuggestion(ErrorSuggestion.config(
        format("Fix '%s' field value to match expected format: %s", fieldName, expectedFormat)
    ));
    
    // Add field-specific suggestions
    if (fieldName == "version")
    {
        error.addSuggestion(ErrorSuggestion("Use semantic versioning format: MAJOR.MINOR.PATCH"));
        error.addSuggestion(ErrorSuggestion.docs("See semver spec", "https://semver.org/"));
    }
    else if (fieldName == "dependencies" || fieldName == "devDependencies")
    {
        error.addSuggestion(ErrorSuggestion("Verify dependency format: \"package-name\": \"^version\""));
    }
    
    return error;
}

/// Create error for dependency resolution failure in manifest
auto manifestDependencyError(
    string manifestPath,
    string manifestType,
    string dependencyName,
    string errorReason,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string message = format(
        "Failed to resolve dependency '%s' in %s: %s",
        dependencyName,
        baseName(manifestPath),
        errorReason
    );
    
    auto error = createParseError(
        manifestPath,
        message,
        Analysis.MissingDependency,
        file,
        line
    );
    
    error.addContext(ErrorContext(
        "resolving manifest dependencies",
        format("dependency: %s", dependencyName)
    ));
    
    // Add manifest-type specific suggestions
    if (manifestType == "npm")
    {
        error.addSuggestion(ErrorSuggestion.command("Install dependencies", "npm install"));
        error.addSuggestion(ErrorSuggestion.command("Update dependencies", "npm update"));
        error.addSuggestion(ErrorSuggestion.command("Check for typos", format("npm search %s", dependencyName)));
    }
    else if (manifestType == "cargo")
    {
        error.addSuggestion(ErrorSuggestion.command("Fetch dependencies", "cargo fetch"));
        error.addSuggestion(ErrorSuggestion.command("Update Cargo.lock", "cargo update"));
        error.addSuggestion(ErrorSuggestion.command("Search crates.io", format("cargo search %s", dependencyName)));
    }
    else if (manifestType == "go")
    {
        error.addSuggestion(ErrorSuggestion.command("Download dependencies", "go mod download"));
        error.addSuggestion(ErrorSuggestion.command("Tidy module", "go mod tidy"));
    }
    else if (manifestType == "python")
    {
        error.addSuggestion(ErrorSuggestion.command("Install dependencies", "pip install -r requirements.txt"));
        error.addSuggestion(ErrorSuggestion.command("Search PyPI", format("pip search %s", dependencyName)));
    }
    else if (manifestType == "composer")
    {
        error.addSuggestion(ErrorSuggestion.command("Install dependencies", "composer install"));
        error.addSuggestion(ErrorSuggestion.command("Update dependencies", "composer update"));
    }
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify dependency name and version are correct"));
    error.addSuggestion(ErrorSuggestion("Check network connectivity if dependency is remote"));
    
    return error;
}

/// Create error for unsupported manifest version/format
auto manifestVersionError(
    string manifestPath,
    string manifestType,
    string currentVersion,
    string supportedVersions,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string message = format(
        "Unsupported %s manifest version %s (supported: %s)",
        manifestType,
        currentVersion,
        supportedVersions
    );
    
    auto error = createParseError(
        manifestPath,
        message,
        Parse.InvalidConfiguration,
        file,
        line
    );
    
    error.addSuggestion(ErrorSuggestion.config(
        format("Update manifest to supported version: %s", supportedVersions)
    ));
    
    error.addSuggestion(ErrorSuggestion("Consider upgrading your project to use a newer format"));
    error.addSuggestion(ErrorSuggestion.docs("See migration guide", "docs/user-guides/migration.md"));
    
    return error;
}

/// Create error for ecosystem tool not installed
auto ecosystemToolMissingError(
    string tool,
    string manifestType,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string message = format(
        "Required tool '%s' not found for %s ecosystem",
        tool,
        manifestType
    );
    
    auto error = new LanguageError(manifestType, message, Language.MissingCompiler);
    
    error.addContext(ErrorContext(
        "checking ecosystem tool availability",
        tool,
        format("%s:%d", baseName(file), line)
    ));
    
    // Add tool-specific installation suggestions
    if (tool == "npm" || tool == "node")
    {
        error.addSuggestion(ErrorSuggestion.command("Install Node.js and npm", "# See https://nodejs.org/"));
        error.addSuggestion(ErrorSuggestion.command("Check installation", "npm --version"));
    }
    else if (tool == "cargo" || tool == "rustc")
    {
        error.addSuggestion(ErrorSuggestion.command("Install Rust toolchain", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"));
        error.addSuggestion(ErrorSuggestion.command("Check installation", "cargo --version"));
    }
    else if (tool == "go")
    {
        error.addSuggestion(ErrorSuggestion.command("Install Go", "# See https://go.dev/doc/install"));
        error.addSuggestion(ErrorSuggestion.command("Check installation", "go version"));
    }
    else if (tool == "python" || tool == "python3" || tool == "pip")
    {
        error.addSuggestion(ErrorSuggestion.command("Install Python 3", "# See https://www.python.org/downloads/"));
        error.addSuggestion(ErrorSuggestion.command("Check installation", "python3 --version"));
    }
    else if (tool == "composer" || tool == "php")
    {
        error.addSuggestion(ErrorSuggestion.command("Install PHP and Composer", "# See https://getcomposer.org/"));
        error.addSuggestion(ErrorSuggestion.command("Check installation", "composer --version"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.command("Install " ~ tool, format("# Install %s for your system", tool)));
        error.addSuggestion(ErrorSuggestion.command("Check if tool is in PATH", "which " ~ tool));
    }
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify tool is installed and in PATH"));
    error.addSuggestion(ErrorSuggestion.docs("See toolchain setup guide", "docs/user-guides/examples.md"));
    
    return error;
}

