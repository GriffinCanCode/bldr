module languages.jvm.scala.tooling.checkers.scapegoat;

import std.stdio;
import languages.jvm.scala.tooling.checkers.base;
import languages.jvm.scala.core.config;
import infrastructure.utils.logging;

/// Scapegoat checker - static analysis tool
class ScapegoatChecker : Checker
{
    override CheckResult check(const string[] sources, LinterConfig config, string workingDir)
    {
        CheckResult result;
        
        // Scapegoat is typically integrated as a compiler plugin
        // Not a standalone tool - needs to be configured in build.sbt
        structuredLog.warning("scapegoat_requires_sbt_compiler_plugin_c").emit();
        
        result.success = true;
        return result;
    }
    
    override bool isAvailable()
    {
        // Always false since it's not a standalone tool
        return false;
    }
    
    override string name() const
    {
        return "Scapegoat";
    }
}

