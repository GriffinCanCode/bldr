module languages.scripting.lua.tooling.detection;

import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.regex;
import languages.scripting.lua.core.config;
import infrastructure.utils.process : isCommandAvailable;
import infrastructure.utils.logging : structuredLog;

/// Detect the best available Lua runtime
LuaRuntime detectRuntime()
{
    // Try LuaJIT first (fastest)
    if (isAvailable("luajit"))
    {
        return LuaRuntime.LuaJIT;
    }
    
    // Try Lua 5.4
    if (isAvailable("lua5.4") || isAvailable("lua54"))
    {
        return LuaRuntime.Lua54;
    }
    
    // Try Lua 5.3
    if (isAvailable("lua5.3") || isAvailable("lua53"))
    {
        return LuaRuntime.Lua53;
    }
    
    // Try Lua 5.2
    if (isAvailable("lua5.2") || isAvailable("lua52"))
    {
        return LuaRuntime.Lua52;
    }
    
    // Try Lua 5.1
    if (isAvailable("lua5.1") || isAvailable("lua51"))
    {
        return LuaRuntime.Lua51;
    }
    
    // Fallback to system lua
    if (isAvailable("lua"))
    {
        return LuaRuntime.System;
    }
    
    // Default to System if nothing found (will fail later with clear error)
    return LuaRuntime.System;
}

/// Get the interpreter command for a given runtime
string getRuntimeCommand(LuaRuntime runtime)
{
    final switch (runtime)
    {
        case LuaRuntime.Auto:
            return getRuntimeCommand(detectRuntime());
        case LuaRuntime.Lua51:
            if (isAvailable("lua5.1")) return "lua5.1";
            if (isAvailable("lua51")) return "lua51";
            return "lua";
        case LuaRuntime.Lua52:
            if (isAvailable("lua5.2")) return "lua5.2";
            if (isAvailable("lua52")) return "lua52";
            return "lua";
        case LuaRuntime.Lua53:
            if (isAvailable("lua5.3")) return "lua5.3";
            if (isAvailable("lua53")) return "lua53";
            return "lua";
        case LuaRuntime.Lua54:
            if (isAvailable("lua5.4")) return "lua5.4";
            if (isAvailable("lua54")) return "lua54";
            return "lua";
        case LuaRuntime.LuaJIT:
            return "luajit";
        case LuaRuntime.System:
            return "lua";
    }
}

/// Get the compiler command for a given runtime
string getCompilerCommand(LuaRuntime runtime)
{
    final switch (runtime)
    {
        case LuaRuntime.Auto:
            return getCompilerCommand(detectRuntime());
        case LuaRuntime.Lua51:
            if (isAvailable("luac5.1")) return "luac5.1";
            if (isAvailable("luac51")) return "luac51";
            return "luac";
        case LuaRuntime.Lua52:
            if (isAvailable("luac5.2")) return "luac5.2";
            if (isAvailable("luac52")) return "luac52";
            return "luac";
        case LuaRuntime.Lua53:
            if (isAvailable("luac5.3")) return "luac5.3";
            if (isAvailable("luac53")) return "luac53";
            return "luac";
        case LuaRuntime.Lua54:
            if (isAvailable("luac5.4")) return "luac5.4";
            if (isAvailable("luac54")) return "luac54";
            return "luac";
        case LuaRuntime.LuaJIT:
            return "luajit";
        case LuaRuntime.System:
            return "luac";
    }
}

/// Detect Lua version from interpreter
struct LuaVersionInfo
{
    int major;
    int minor;
    int patch;
    string full;
    bool isLuaJIT;
}

LuaVersionInfo detectLuaVersion(string interpreter = "lua")
{
    LuaVersionInfo info;
    
    try
    {
        auto res = execute([interpreter, "-v"]);
        if (res.status == 0)
        {
            auto output = res.output.strip;
            
            // Check if LuaJIT
            if (output.canFind("LuaJIT"))
            {
                info.isLuaJIT = true;
                // LuaJIT version format: LuaJIT 2.1.0-beta3 -- Copyright ...
                auto match = matchFirst(output, regex(`LuaJIT\s+(\d+)\.(\d+)\.(\d+)`));
                if (!match.empty)
                {
                    info.major = match[1].to!int;
                    info.minor = match[2].to!int;
                    info.patch = match[3].to!int;
                    info.full = match[0];
                }
            }
            else
            {
                // Standard Lua version format: Lua 5.4.4 Copyright ...
                auto match = matchFirst(output, regex(`Lua\s+(\d+)\.(\d+)\.(\d+)`));
                if (!match.empty)
                {
                    info.major = match[1].to!int;
                    info.minor = match[2].to!int;
                    info.patch = match[3].to!int;
                    info.full = match[0];
                }
                else
                {
                    // Try simpler pattern
                    auto match2 = matchFirst(output, regex(`Lua\s+(\d+)\.(\d+)`));
                    if (!match2.empty)
                    {
                        info.major = match2[1].to!int;
                        info.minor = match2[2].to!int;
                        info.patch = 0;
                        info.full = match2[0];
                    }
                }
            }
        }
    }
    catch (Exception e)
    {
        // Failed to detect version
    }
    
    return info;
}

/// Check if a command is available on the system
bool isAvailable(string command)
{
    return isCommandAvailable(command);
}

/// Check if LuaRocks is available
bool isLuaRocksAvailable()
{
    return isAvailable("luarocks");
}

/// Get LuaRocks version
string getLuaRocksVersion()
{
    if (!isAvailable("luarocks"))
        return "";
    
    try
    {
        auto res = execute(["luarocks", "--version"]);
        if (res.status == 0)
        {
            auto output = res.output.strip;
            auto match = matchFirst(output, regex(`(\d+\.\d+\.\d+)`));
            if (!match.empty)
            {
                return match[1];
            }
        }
    }
    catch (Exception e)
    {
        import infrastructure.utils.logging : Logger;
        structuredLog.debug_("failed_to_detect_lua_info_").field("detail", "Failed to detect Lua info: " ~ e.msg).emit();
    }
    
    return "";
}

/// Check if StyLua formatter is available
bool isStyLuaAvailable()
{
    return isAvailable("stylua");
}

/// Check if lua-format is available
bool isLuaFormatAvailable()
{
    return isAvailable("lua-format");
}

/// Check if Luacheck linter is available
bool isLuacheckAvailable()
{
    return isAvailable("luacheck");
}

/// Check if Selene linter is available
bool isSeleneAvailable()
{
    return isAvailable("selene");
}

/// Check if Busted test framework is available
bool isBustedAvailable()
{
    return isAvailable("busted");
}

/// Detect all available Lua tools
struct LuaToolchain
{
    LuaRuntime runtime;
    LuaVersionInfo version_;
    bool hasLuaRocks;
    string luaRocksVersion;
    bool hasStyLua;
    bool hasLuaFormat;
    bool hasLuacheck;
    bool hasSelene;
    bool hasBusted;
    string luaCommand;
    string luacCommand;
}

LuaToolchain detectToolchain()
{
    LuaToolchain toolchain;
    
    toolchain.runtime = detectRuntime();
    toolchain.luaCommand = getRuntimeCommand(toolchain.runtime);
    toolchain.luacCommand = getCompilerCommand(toolchain.runtime);
    toolchain.version_ = detectLuaVersion(toolchain.luaCommand);
    
    toolchain.hasLuaRocks = isLuaRocksAvailable();
    if (toolchain.hasLuaRocks)
    {
        toolchain.luaRocksVersion = getLuaRocksVersion();
    }
    
    toolchain.hasStyLua = isStyLuaAvailable();
    toolchain.hasLuaFormat = isLuaFormatAvailable();
    toolchain.hasLuacheck = isLuacheckAvailable();
    toolchain.hasSelene = isSeleneAvailable();
    toolchain.hasBusted = isBustedAvailable();
    
    return toolchain;
}

/// Get recommended formatter
LuaFormatter detectBestFormatter()
{
    if (isStyLuaAvailable())
        return LuaFormatter.StyLua;
    
    if (isLuaFormatAvailable())
        return LuaFormatter.LuaFormat;
    
    return LuaFormatter.None;
}

/// Get recommended linter
LuaLinter detectBestLinter()
{
    if (isLuacheckAvailable())
        return LuaLinter.Luacheck;
    
    if (isSeleneAvailable())
        return LuaLinter.Selene;
    
    return LuaLinter.None;
}

/// Get recommended test framework
LuaTestFramework detectBestTester()
{
    if (isBustedAvailable())
        return LuaTestFramework.Busted;
    
    // LuaUnit doesn't need to be globally installed (can be require'd)
    return LuaTestFramework.LuaUnit;
}

