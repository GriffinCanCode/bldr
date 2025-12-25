module infrastructure.config.scripting.scopemanager;

import std.array;
import std.algorithm;
import infrastructure.config.scripting.types;
import infrastructure.errors;

/// Symbol binding in scope
struct Symbol
{
    string name;
    Value value;
    bool isConst;      // true for const, false for let
    bool isFunction;   // true for function definitions
    size_t scopeLevel; // Scope depth for debugging
}

/// Scope management with lexical scoping
class ScopeManager
{
    private Symbol[][string] symbols;  // Stack of symbols per name
    private size_t scopeLevel;
    private size_t[] scopeMarkers;     // Track scope boundaries
    
    this() pure nothrow @safe
    {
        scopeLevel = 0;
    }
    
    /// Enter new scope (push scope level)
    void enterScope() pure nothrow @safe
    {
        scopeLevel++;
        scopeMarkers ~= scopeLevel;
    }
    
    /// Exit scope (pop scope level and remove bindings)
    void exitScope() @trusted
    {
        if (scopeMarkers.empty)
            return;
        
        // Remove all symbols at current scope level
        string[] toRemove;
        foreach (name, stack; symbols)
        {
            while (!stack.empty && stack[$ - 1].scopeLevel >= scopeLevel)
            {
                stack = stack[0 .. $ - 1];
            }
            
            if (stack.empty)
                toRemove ~= name;
            else
                symbols[name] = stack;
        }
        
        foreach (name; toRemove)
            symbols.remove(name);
        
        scopeMarkers = scopeMarkers[0 .. $ - 1];
        scopeLevel--;
    }
    
    /// Define variable (let or const)
    VoidBuildResult define(string name, Value value, bool isConst) @trusted
    {
        // Check if already defined in current scope
        if (name in symbols)
        {
            auto stack = symbols[name];
            if (!stack.empty && stack[$ - 1].scopeLevel == scopeLevel)
            {
                return VoidBuildResult.err(
                    Errors.parse("", "Variable '" ~ name ~ "' is already defined in this scope")
                        .withSuggestion("Use a different variable name")
                        .withSuggestion("Or use assignment instead of re-declaration")
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
        }
        
        // Add to symbol table
        Symbol sym;
        sym.name = name;
        sym.value = value;
        sym.isConst = isConst;
        sym.isFunction = false;
        sym.scopeLevel = scopeLevel;
        
        if (name !in symbols)
            symbols[name] = [];
        symbols[name] ~= sym;
        
        return VoidBuildResult.ok();
    }
    
    /// Define function
    VoidBuildResult defineFunction(string name, Value fnValue) @trusted
    {
        // Functions can be redefined (last definition wins)
        Symbol sym;
        sym.name = name;
        sym.value = fnValue;
        sym.isConst = true;  // Functions are immutable
        sym.isFunction = true;
        sym.scopeLevel = scopeLevel;
        
        if (name !in symbols)
            symbols[name] = [];
        symbols[name] ~= sym;
        
        return VoidBuildResult.ok();
    }
    
    /// Assign to existing variable
    VoidBuildResult assign(string name, Value value) @trusted
    {
        if (name !in symbols || symbols[name].empty)
        {
            return VoidBuildResult.err(
                Errors.parse("", "Undefined variable '" ~ name ~ "'")
                    .withSuggestion("Define variable with 'let " ~ name ~ " = ...'")
                    .withSuggestion("Check for typos in variable name")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        auto stack = symbols[name];
        auto sym = stack[$ - 1];
        
        if (sym.isConst)
        {
            return VoidBuildResult.err(
                Errors.parse("", "Cannot assign to const variable '" ~ name ~ "'")
                    .withSuggestion("Use 'let' instead of 'const' for mutable variables")
                    .withSuggestion("Create a new variable with a different name")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        // Update value
        sym.value = value;
        symbols[name][$ - 1] = sym;
        
        return VoidBuildResult.ok();
    }
    
    /// Lookup variable
    BuildResult!Value lookup(string name) @trusted
    {
        if (name !in symbols || symbols[name].empty)
        {
            return BuildResult!Value.err(
                Errors.parse("", "Undefined variable '" ~ name ~ "'")
                    .withSuggestion("Define variable with 'let " ~ name ~ " = ...'")
                    .withSuggestion("Check for typos in variable name")
                    .withSuggestion("Ensure variable is defined before use")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        auto stack = symbols[name];
        return BuildResult!Value.ok(stack[$ - 1].value);
    }
    
    /// Check if variable is defined
    bool isDefined(string name) const pure nothrow @trusted
    {
        return name in symbols && !symbols[name].empty;
    }
    
    /// Check if variable is const
    bool isConst(string name) const @trusted
    {
        if (name !in symbols || symbols[name].empty)
            return false;
        return symbols[name][$ - 1].isConst;
    }
    
    /// Get all defined names (for debugging)
    string[] definedNames() const @trusted
    {
        string[] names;
        foreach (name, stack; symbols)
        {
            if (!stack.empty)
                names ~= name;
        }
        return names;
    }
    
    /// Get current scope level
    size_t currentScopeLevel() const pure nothrow @nogc @safe
    {
        return scopeLevel;
    }
    
    /// Clear all symbols (for testing)
    void clear() pure nothrow @trusted
    {
        symbols.clear();
        scopeMarkers.length = 0;
        scopeLevel = 0;
    }
}

/// Scope guard for automatic scope management
struct ScopedBlock
{
    private ScopeManager manager;
    private bool exited;
    
    this(ScopeManager manager) pure nothrow @safe
    {
        this.manager = manager;
        this.exited = false;
        manager.enterScope();
    }
    
    ~this() @trusted
    {
        if (!exited && manager !is null)
        {
            manager.exitScope();
        }
    }
    
    @disable this(this);  // Prevent copying
}

/// Create scoped block helper
ScopedBlock scoped(ScopeManager manager) @safe
{
    return ScopedBlock(manager);
}

