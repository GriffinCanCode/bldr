module languages.scripting.r.tooling.checkers;

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

/// Lint result
struct LintResult
{
    bool success;
    string error;
    LintIssue[] issues;
    int warningCount;
    int errorCount;
}

/// Individual lint issue
struct LintIssue
{
    string file;
    int line;
    int column;
    string severity; // "warning", "error", "style"
    string message;
    string linter;
}

/// Format result
struct FormatResult
{
    bool success;
    string error;
    string[] formattedFiles;
    int changedFiles;
}

/// Run linter on R files
LintResult lintFiles(
    const string[] files,
    RLintConfig config,
    string rCmd,
    const string workDir
)
{
    if (files.empty)
    {
        return LintResult(true, "", [], 0, 0);
    }
    
    // Auto-detect if needed
    if (config.linter == RLinter.Auto)
    {
        config.linter = detectBestLinter(rCmd);
    }
    
    if (config.linter == RLinter.None)
    {
        structuredLog.debug_("linting_disabled").emit();
        return LintResult(true, "", [], 0, 0);
    }
    
    structuredLog.info("linting_").field("detail", "Linting " ~ files.length.to!string ~ " R file(s) with " ~ config.linter.to!string).emit();
    
    final switch (config.linter)
    {
        case RLinter.Auto:
            return LintResult(false, "Failed to auto-detect linter", [], 0, 0);
            
        case RLinter.Lintr:
            return lintWithLintr(files, config, rCmd, workDir);
            
        case RLinter.Goodpractice:
            return lintWithGoodpractice(files, config, rCmd, workDir);
            
        case RLinter.None:
            return LintResult(true, "", [], 0, 0);
    }
}

/// Lint with lintr package
private LintResult lintWithLintr(
    const string[] files,
    RLintConfig config,
    string rCmd,
    string workDir
)
{
    LintResult result;
    
    // Ensure lintr is installed
    if (!isRPackageInstalled("lintr", rCmd))
    {
        result.error = "lintr package not installed";
        return result;
    }
    
    // Build linter configuration
    string linterConfig = "NULL";
    if (!config.configFile.empty && exists(config.configFile))
    {
        linterConfig = `"` ~ config.configFile ~ `"`;
    }
    else if (!config.enabledLinters.empty || !config.disabledLinters.empty)
    {
        // Custom linter configuration
        string[] linterSpecs;
        if (!config.enabledLinters.empty)
        {
            foreach (linter; config.enabledLinters)
            {
                linterSpecs ~= linter ~ " = lintr::" ~ linter ~ "()";
            }
        }
        
        if (linterSpecs.empty)
        {
            linterConfig = "lintr::linters_with_defaults()";
        }
        else
        {
            linterConfig = "lintr::linters_with_defaults(" ~ linterSpecs.join(", ") ~ ")";
        }
    }
    
    // Create R script to lint and output JSON
    string lintScript = `
library(lintr)
files <- c(` ~ files.map!(f => `"` ~ f ~ `"`).join(",") ~ `)
all_results <- list()

for (file in files) {
    results <- lint(file, linters = ` ~ linterConfig ~ `)
    if (length(results) > 0) {
        for (result in results) {
            all_results[[length(all_results) + 1]] <- list(
                file = as.character(result$filename),
                line = as.integer(result$line_number),
                column = as.integer(result$column_number),
                severity = as.character(result$type),
                message = as.character(result$message),
                linter = as.character(result$linter)
            )
        }
    }
}

cat(jsonlite::toJSON(all_results, auto_unbox = TRUE))
`;
    
    // Write script to temp file
    import std.file : tempDir;
    import std.uuid : randomUUID;
    string scriptPath = buildPath(tempDir(), "lintr_" ~ randomUUID().toString() ~ ".R");
    std.file.write(scriptPath, lintScript);
    scope(exit) if (exists(scriptPath)) remove(scriptPath);
    
    auto res = execute([rCmd, scriptPath], null, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        result.error = "lintr execution failed: " ~ res.output;
        return result;
    }
    
    // Parse JSON output
    try
    {
        if (!res.output.strip().empty)
        {
            auto json = parseJSON(res.output);
            if (json.type == JSONType.array)
            {
                foreach (item; json.array)
                {
                    LintIssue issue;
                    issue.file = item["file"].str;
                    issue.line = cast(int)item["line"].integer;
                    issue.column = cast(int)item["column"].integer;
                    issue.severity = item["severity"].str;
                    issue.message = item["message"].str;
                    issue.linter = item["linter"].str;
                    
                    result.issues ~= issue;
                    
                    if (issue.severity == "error")
                        result.errorCount++;
                    else if (issue.severity == "warning")
                        result.warningCount++;
                }
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_parse_lintr_output_").field("detail", "Failed to parse lintr output: " ~ e.msg).emit();
    }
    
    // Report results
    if (result.issues.empty)
    {
        structuredLog.info("no_linting_issues_found").emit();
    }
    else
    {
        structuredLog.warning("found_").field("detail", "Found " ~ result.issues.length.to!string ~ " linting issue(s)").emit();
        foreach (issue; result.issues)
        {
            string location = issue.file ~ ":" ~ issue.line.to!string ~ ":" ~ issue.column.to!string;
            structuredLog.warning("__").field("detail", "  [" ~ issue.severity ~ "] " ~ location ~ " - " ~ issue.message).emit();
        }
    }
    
    result.success = result.errorCount == 0 && (!config.failOnWarnings || result.warningCount == 0);
    return result;
}

/// Lint with goodpractice package
private LintResult lintWithGoodpractice(
    const string[] files,
    RLintConfig config,
    string rCmd,
    string workDir
)
{
    LintResult result;
    
    // Ensure goodpractice is installed
    if (!isRPackageInstalled("goodpractice", rCmd))
    {
        result.error = "goodpractice package not installed";
        return result;
    }
    
    // goodpractice works on package level, not individual files
    // Find package root (directory with DESCRIPTION)
    string pkgDir = workDir;
    while (pkgDir != "/" && !exists(buildPath(pkgDir, "DESCRIPTION")))
    {
        pkgDir = dirName(pkgDir);
    }
    
    if (!exists(buildPath(pkgDir, "DESCRIPTION")))
    {
        result.error = "goodpractice requires a package with DESCRIPTION file";
        return result;
    }
    
    string checkScript = `
library(goodpractice)
gp <- gp("` ~ pkgDir ~ `")
results <- gp$results

all_issues <- list()
for (check_name in names(results)) {
    check_result <- results[[check_name]]
    if (!is.null(check_result) && length(check_result) > 0) {
        for (issue in check_result) {
            all_issues[[length(all_issues) + 1]] <- list(
                file = if(!is.null(issue$filename)) as.character(issue$filename) else "",
                line = if(!is.null(issue$line)) as.integer(issue$line) else 0,
                column = if(!is.null(issue$column)) as.integer(issue$column) else 0,
                severity = "warning",
                message = as.character(issue$message),
                linter = check_name
            )
        }
    }
}

cat(jsonlite::toJSON(all_issues, auto_unbox = TRUE))
`;
    
    // Write script to temp file
    import std.file : tempDir;
    import std.uuid : randomUUID;
    string scriptPath = buildPath(tempDir(), "goodpractice_" ~ randomUUID().toString() ~ ".R");
    std.file.write(scriptPath, checkScript);
    scope(exit) if (exists(scriptPath)) remove(scriptPath);
    
    auto res = execute([rCmd, scriptPath], null, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        result.error = "goodpractice execution failed: " ~ res.output;
        return result;
    }
    
    // Parse JSON output (similar to lintr)
    try
    {
        if (!res.output.strip().empty)
        {
            auto json = parseJSON(res.output);
            if (json.type == JSONType.array)
            {
                foreach (item; json.array)
                {
                    LintIssue issue;
                    issue.file = item["file"].str;
                    issue.line = cast(int)item["line"].integer;
                    issue.column = cast(int)item["column"].integer;
                    issue.severity = item["severity"].str;
                    issue.message = item["message"].str;
                    issue.linter = item["linter"].str;
                    
                    result.issues ~= issue;
                    result.warningCount++;
                }
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_parse_goodpractice_output_").field("detail", "Failed to parse goodpractice output: " ~ e.msg).emit();
    }
    
    result.success = !config.failOnWarnings || result.warningCount == 0;
    return result;
}

/// Format R files
FormatResult formatFiles(
    const string[] files,
    RFormatConfig config,
    string rCmd,
    const string workDir
)
{
    if (files.empty)
    {
        return FormatResult(true, "", [], 0);
    }
    
    // Auto-detect if needed
    if (config.formatter == RFormatter.Auto)
    {
        config.formatter = detectBestFormatter(rCmd);
    }
    
    if (config.formatter == RFormatter.None)
    {
        structuredLog.debug_("formatting_disabled").emit();
        return FormatResult(true, "", [], 0);
    }
    
    structuredLog.info("formatting_").field("detail", "Formatting " ~ files.length.to!string ~ " R file(s) with " ~ config.formatter.to!string).emit();
    
    final switch (config.formatter)
    {
        case RFormatter.Auto:
            return FormatResult(false, "Failed to auto-detect formatter", [], 0);
            
        case RFormatter.Styler:
            return formatWithStyler(files, config, rCmd, workDir);
            
        case RFormatter.FormatR:
            return formatWithFormatR(files, config, rCmd, workDir);
            
        case RFormatter.None:
            return FormatResult(true, "", [], 0);
    }
}

/// Format with styler package
private FormatResult formatWithStyler(
    const string[] files,
    RFormatConfig config,
    string rCmd,
    string workDir
)
{
    FormatResult result;
    
    // Ensure styler is installed
    if (!isRPackageInstalled("styler", rCmd))
    {
        result.error = "styler package not installed";
        return result;
    }
    
    // Build styler options
    string stylerOptions = "";
    if (config.indentWidth != 2)
    {
        stylerOptions ~= `indent_by = ` ~ config.indentWidth.to!string;
    }
    
    // Create R script to format files
    string formatScript = `
library(styler)
files <- c(` ~ files.map!(f => `"` ~ f ~ `"`).join(",") ~ `)

changed_files <- character()
for (file in files) {
    # Get original content
    original <- readLines(file, warn = FALSE)
    
    # Format file
    styler::style_file(file, scope = "` ~ config.stylerScope ~ `"` ~
        (stylerOptions.empty ? "" : ", " ~ stylerOptions) ~ `)
    
    # Check if changed
    formatted <- readLines(file, warn = FALSE)
    if (!identical(original, formatted)) {
        changed_files <- c(changed_files, file)
    }
}

cat(jsonlite::toJSON(changed_files))
`;
    
    // Write script to temp file
    import std.file : tempDir;
    import std.uuid : randomUUID;
    string scriptPath = buildPath(tempDir(), "styler_" ~ randomUUID().toString() ~ ".R");
    std.file.write(scriptPath, formatScript);
    scope(exit) if (exists(scriptPath)) remove(scriptPath);
    
    auto res = execute([rCmd, scriptPath], null, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        result.error = "styler execution failed: " ~ res.output;
        return result;
    }
    
    // Parse JSON output
    try
    {
        if (!res.output.strip().empty)
        {
            auto json = parseJSON(res.output);
            if (json.type == JSONType.array)
            {
                foreach (file; json.array)
                {
                    result.formattedFiles ~= file.str;
                }
                result.changedFiles = cast(int)result.formattedFiles.length;
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_parse_styler_output_").field("detail", "Failed to parse styler output: " ~ e.msg).emit();
    }
    
    if (result.changedFiles > 0)
    {
        structuredLog.info("formatted_").field("detail", "Formatted " ~ result.changedFiles.to!string ~ " file(s)").emit();
    }
    else
    {
        structuredLog.info("all_files_already_formatted").emit();
    }
    
    result.success = true;
    return result;
}

/// Format with formatR package
private FormatResult formatWithFormatR(
    const string[] files,
    RFormatConfig config,
    string rCmd,
    string workDir
)
{
    FormatResult result;
    
    // Ensure formatR is installed
    if (!isRPackageInstalled("formatR", rCmd))
    {
        result.error = "formatR package not installed";
        return result;
    }
    
    // Create R script to format files
    string formatScript = `
library(formatR)
files <- c(` ~ files.map!(f => `"` ~ f ~ `"`).join(",") ~ `)

changed_files <- character()
for (file in files) {
    # Get original content
    original <- readLines(file, warn = FALSE)
    
    # Format file
    formatR::tidy_source(
        source = file,
        file = file,
        width.cutoff = ` ~ config.maxLineLength.to!string ~ `,
        indent = ` ~ config.indentWidth.to!string ~ `
    )
    
    # Check if changed
    formatted <- readLines(file, warn = FALSE)
    if (!identical(original, formatted)) {
        changed_files <- c(changed_files, file)
    }
}

cat(jsonlite::toJSON(changed_files))
`;
    
    // Write script to temp file
    import std.file : tempDir;
    import std.uuid : randomUUID;
    string scriptPath = buildPath(tempDir(), "formatr_" ~ randomUUID().toString() ~ ".R");
    std.file.write(scriptPath, formatScript);
    scope(exit) if (exists(scriptPath)) remove(scriptPath);
    
    auto res = execute([rCmd, scriptPath], null, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        result.error = "formatR execution failed: " ~ res.output;
        return result;
    }
    
    // Parse JSON output
    try
    {
        if (!res.output.strip().empty)
        {
            auto json = parseJSON(res.output);
            if (json.type == JSONType.array)
            {
                foreach (file; json.array)
                {
                    result.formattedFiles ~= file.str;
                }
                result.changedFiles = cast(int)result.formattedFiles.length;
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_parse_formatr_output_").field("detail", "Failed to parse formatR output: " ~ e.msg).emit();
    }
    
    if (result.changedFiles > 0)
    {
        structuredLog.info("formatted_").field("detail", "Formatted " ~ result.changedFiles.to!string ~ " file(s)").emit();
    }
    else
    {
        structuredLog.info("all_files_already_formatted").emit();
    }
    
    result.success = true;
    return result;
}

/// Validate R syntax without executing
bool validateSyntax(const string[] files, string rCmd, string workDir)
{
    if (files.empty)
        return true;
    
    structuredLog.debug_("validating_syntax_for_").field("detail", "Validating syntax for " ~ files.length.to!string ~ " R file(s)").emit();
    
    // Create R script to validate all files
    string validateScript = `
files <- c(` ~ files.map!(f => `"` ~ f ~ `"`).join(",") ~ `)
errors <- character()

for (file in files) {
    result <- tryCatch({
        parse(file)
        NULL
    }, error = function(e) {
        paste0(file, ": ", e$message)
    })
    
    if (!is.null(result)) {
        errors <- c(errors, result)
    }
}

if (length(errors) > 0) {
    cat(errors, sep = "\n")
    quit(status = 1)
} else {
    quit(status = 0)
}
`;
    
    // Write script to temp file
    import std.file : tempDir;
    import std.uuid : randomUUID;
    string scriptPath = buildPath(tempDir(), "validate_" ~ randomUUID().toString() ~ ".R");
    std.file.write(scriptPath, validateScript);
    scope(exit) if (exists(scriptPath)) remove(scriptPath);
    
    auto res = execute([rCmd, scriptPath], null, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        structuredLog.error("syntax_validation_failed").emit();
        structuredLog.error("log_event").field("message", res.output).emit();
        return false;
    }
    
    structuredLog.debug_("syntax_validation_passed").emit();
    return true;
}

