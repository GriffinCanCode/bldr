module frontend.cli.commands.execution.infer;

import std.stdio;
import std.path;
import std.conv;
import std.range;
import std.algorithm;
import std.string : format;
import infrastructure.analysis.detection.inference;
import infrastructure.analysis.detection.templates;
import infrastructure.analysis.detection.detector;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;

/// Infer command - shows what targets would be auto-detected
struct InferCommand
{
    private static Terminal terminal;
    private static Formatter formatter;
    
    /// Initialize terminal and formatter
    private static void init()
    {
        auto caps = Capabilities.detect();
        terminal = Terminal(caps);
        formatter = Formatter(caps);
    }
    
    /// Execute the infer command
    static void execute(string projectDir = ".")
    {
        init();
        
        terminal.writeln();
        terminal.writeColored("🔮 ", Color.BrightMagenta);
        terminal.writeColored("Zero-Config Target Inference", Color.Magenta, Style.Bold);
        terminal.writeln();
        terminal.writeln();
        
        terminal.writeColored("🔍 ", Color.BrightCyan);
        terminal.writeColored("Analyzing project structure", Color.Cyan);
        terminal.write("...");
        terminal.writeln();
        terminal.flush();
        
        // Run inference
        auto inference = new TargetInference(projectDir);
        auto targets = inference.inferTargets();
        
        terminal.writeln();
        
        if (targets.empty)
        {
            terminal.writeColored("⚠️  ", Color.Yellow);
            terminal.writeColored("No Targets Detected", Color.Yellow, Style.Bold);
            terminal.writeln();
            terminal.writeln();
            terminal.write("  No targets could be inferred from project structure");
            terminal.writeln();
            terminal.write("  Consider running ");
            terminal.writeColored("bldr init", Color.Green, Style.Bold);
            terminal.write(" to create a Builderfile manually");
            terminal.writeln();
            terminal.writeln();
            terminal.flush();
            return;
        }
        
        terminal.writeColored("✨ ", Color.Green);
        terminal.writeColored("Inferred Targets", Color.Green, Style.Bold);
        terminal.write(" ");
        terminal.writeColored(format("(%d found)", targets.length), Color.BrightBlack);
        terminal.writeln();
        terminal.writeln();
        
        // Display each inferred target
        foreach (i, target; targets)
        {
            // Target header with icon
            terminal.write("  ");
            terminal.writeColored("╭─", Color.BrightBlue);
            terminal.write(" ");
            terminal.writeColored("🎯", Color.BrightYellow);
            terminal.write(" ");
            terminal.writeColored(target.name, Color.BrightWhite, Style.Bold);
            terminal.writeln();
            
            // Type
            terminal.write("  ");
            terminal.writeColored("│", Color.BrightBlue);
            terminal.write("  ");
            terminal.writeColored("Type:", Color.BrightBlack);
            terminal.write("     ");
            terminal.writeColored(format("%s", target.type), Color.Cyan);
            terminal.writeln();
            
            // Language
            terminal.write("  ");
            terminal.writeColored("│", Color.BrightBlue);
            terminal.write("  ");
            terminal.writeColored("Language:", Color.BrightBlack);
            terminal.write(" ");
            terminal.writeColored(format("%s", target.language), Color.Magenta);
            terminal.writeln();
            
            // Sources
            terminal.write("  ");
            terminal.writeColored("│", Color.BrightBlue);
            terminal.write("  ");
            terminal.writeColored("Sources:", Color.BrightBlack);
            terminal.write("  ");
            terminal.writeColored(format("%d file(s)", target.sources.length), Color.BrightCyan);
            terminal.writeln();
            
            if (target.sources.length <= 5)
            {
                foreach (source; target.sources)
                {
                    terminal.write("  ");
                    terminal.writeColored("│", Color.BrightBlue);
                    terminal.write("    ");
                    terminal.writeColored("▸", Color.Green);
                    terminal.write(" ");
                    terminal.write(baseName(source));
                    terminal.writeln();
                }
            }
            else
            {
                foreach (source; target.sources[0..3])
                {
                    terminal.write("  ");
                    terminal.writeColored("│", Color.BrightBlue);
                    terminal.write("    ");
                    terminal.writeColored("▸", Color.Green);
                    terminal.write(" ");
                    terminal.write(baseName(source));
                    terminal.writeln();
                }
                terminal.write("  ");
                terminal.writeColored("│", Color.BrightBlue);
                terminal.write("    ");
                terminal.writeColored("▸", Color.BrightBlack);
                terminal.write(" ");
                terminal.writeColored(format("... and %d more", target.sources.length - 3), Color.BrightBlack);
                terminal.writeln();
            }
            
            if (!target.langConfig.empty)
            {
                terminal.write("  ");
                terminal.writeColored("│", Color.BrightBlue);
                terminal.write("  ");
                terminal.writeColored("Config:", Color.BrightBlack);
                terminal.writeln();
                
                foreach (key, value; target.langConfig)
                {
                    terminal.write("  ");
                    terminal.writeColored("│", Color.BrightBlue);
                    terminal.write("    ");
                    terminal.writeColored(key, Color.Yellow);
                    terminal.write(": ");
                    terminal.write(value);
                    terminal.writeln();
                }
            }
            
            terminal.write("  ");
            terminal.writeColored("╰─", Color.BrightBlue);
            terminal.writeln();
            
            if (i < targets.length - 1)
                terminal.writeln();
        }
        
        terminal.writeln();
        
        // Next steps box
        string[] nextSteps = [
            "Use zero-config mode to build without a Builderfile,",
            "or create a Builderfile to customize your build."
        ];
        terminal.writeln(formatter.formatBox("💡 Next Steps", nextSteps));
        terminal.writeln();
        
        terminal.writeColored("📦 Zero-Config Build:", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr build", Color.Green, Style.Bold);
        terminal.write("    ");
        terminal.writeColored("# Automatically infers and builds targets", Color.BrightBlack);
        terminal.writeln();
        terminal.writeln();
        
        terminal.writeColored("📝 Generate Builderfile:", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr init", Color.Green, Style.Bold);
        terminal.write("     ");
        terminal.writeColored("# Creates Builderfile with detected configuration", Color.BrightBlack);
        terminal.writeln();
        terminal.writeln();
        
        terminal.flush();
    }
}

