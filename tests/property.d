module tests.property;

import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.range;
import std.stdio;
import std.traits;
import std.typecons : Tuple;
import tests.harness;

/// Helper to determine return type
template RetType(T...)
{
    static if (T.length == 1)
        alias RetType = T[0];
    else
        alias RetType = Tuple!T;
}

/// Property-based test configuration
struct PropertyConfig
{
    size_t numTests = 100;        /// Number of random test cases to generate
    uint seed = 42;               /// Random seed for reproducibility
    bool shrink = true;           /// Enable shrinking on failure
    size_t maxShrinkAttempts = 100; /// Maximum shrinking attempts
}

/// Result of a property test
struct PropertyResult
{
    bool passed;
    string message;
    size_t testCase;              /// Which test case failed (0-indexed)
    string counterexample;        /// Counterexample that caused failure
}

/// Property test runner
class PropertyTest(Args...)
{
    private PropertyConfig config;
    private Mt19937 rng;
    
    this(PropertyConfig config = PropertyConfig())
    {
        this.config = config;
        this.rng = Mt19937(config.seed);
    }
    
    /// Run a property test with generated inputs
    PropertyResult forAll(alias property)(Generator!Args generators)
    {
        foreach (i; 0 .. config.numTests)
        {
            // Generate random inputs
            auto args = generators.generate(rng);
            
            try
            {
                // Run property check
                bool holds;
                static if (Args.length == 1)
                    holds = property(args);
                else
                    holds = property(args.expand);
                
                if (!holds)
                {
                    auto counterexample = formatArgs(args);
                    
                    // Attempt to shrink
                    if (config.shrink)
                    {
                        args = shrinkToMinimal!property(generators, args);
                        counterexample = formatArgs(args);
                    }
                    
                    return PropertyResult(
                        false,
                        "Property violated",
                        i,
                        counterexample
                    );
                }
            }
            catch (AssertionError e)
            {
                auto counterexample = formatArgs(args);
                
                // Attempt to shrink
                if (config.shrink)
                {
                    args = shrinkToMinimal!property(generators, args);
                    counterexample = formatArgs(args);
                }
                
                return PropertyResult(
                    false,
                    "Property threw: " ~ e.msg,
                    i,
                    counterexample
                );
            }
            catch (Exception e)
            {
                return PropertyResult(
                    false,
                    "Unexpected exception: " ~ e.msg,
                    i,
                    formatArgs(args)
                );
            }
        }
        
        return PropertyResult(true, "All " ~ config.numTests.to!string ~ " tests passed", 0, "");
    }
    
    private RetType!Args shrinkToMinimal(alias property)(Generator!Args generators, RetType!Args args)
    {
        auto minimal = args;
        size_t attempts = 0;
        
        while (attempts < config.maxShrinkAttempts)
        {
            auto shrunk = generators.shrink(minimal);
            
            // If shrinking didn't change anything, we're done
            if (shrunk == minimal)
                break;
            
            try
            {
                bool result;
                static if (Args.length == 1)
                    result = property(shrunk);
                else
                    result = property(shrunk.expand);

                if (!result)
                {
                    // Shrunk value still fails, use it
                    minimal = shrunk;
                }
                else
                {
                    // Shrunk value passes, stop shrinking
                    break;
                }
            }
            catch (Exception)
            {
                // Shrunk value still fails
                minimal = shrunk;
            }
            
            attempts++;
        }
        
        return minimal;
    }
    
    private string formatArgs(RetType!Args args)
    {
        static if (Args.length == 1)
        {
            return args.to!string;
        }
        else
        {
            string[] parts;
            foreach (i, _; Args)
                parts ~= args[i].to!string;
            return "(" ~ parts.join(", ") ~ ")";
        }
    }
}

/// Base generator interface
interface Generator(T...)
{
    RetType!T generate(ref Mt19937 rng);
    RetType!T shrink(RetType!T value);
}

/// Integer generator
class IntGen : Generator!int
{
    private int min;
    private int max;
    
    this(int min = int.min, int max = int.max)
    {
        this.min = min;
        this.max = max;
    }
    
    int generate(ref Mt19937 rng)
    {
        return uniform(min, max, rng);
    }
    
    int shrink(int value)
    {
        if (value > 0)
            return value / 2;
        else if (value < 0)
            return value / 2;
        return 0;
    }
}

/// String generator
class StringGen : Generator!string
{
    private size_t minLen;
    private size_t maxLen;
    private string alphabet;
    
    this(size_t minLen = 0, size_t maxLen = 100, 
         string alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    {
        this.minLen = minLen;
        this.maxLen = maxLen;
        this.alphabet = alphabet;
    }
    
    string generate(ref Mt19937 rng)
    {
        auto len = uniform(minLen, maxLen + 1, rng);
        char[] result;
        
        foreach (i; 0 .. len)
        {
            auto idx = uniform(0, alphabet.length, rng);
            result ~= alphabet[idx];
        }
        
        return result.idup;
    }
    
    string shrink(string value)
    {
        if (value.length > minLen)
            return value[0 .. value.length / 2];
        return value;
    }
}

/// Array generator
class ArrayGen(T) : Generator!(T[])
{
    private Generator!T elementGen;
    private size_t minLen;
    private size_t maxLen;
    
    this(Generator!T elementGen, size_t minLen = 0, size_t maxLen = 100)
    {
        this.elementGen = elementGen;
        this.minLen = minLen;
        this.maxLen = maxLen;
    }
    
    T[] generate(ref Mt19937 rng)
    {
        auto len = uniform(minLen, maxLen + 1, rng);
        T[] result;
        
        foreach (i; 0 .. len)
        {
            result ~= elementGen.generate(rng);
        }
        
        return result;
    }
    
    T[] shrink(T[] value)
    {
        if (value.length > minLen)
            return value[0 .. value.length / 2];
        return value;
    }
}

/// Path generator (for filesystem paths)
class PathGen : Generator!string
{
    private size_t minDepth;
    private size_t maxDepth;
    
    this(size_t minDepth = 1, size_t maxDepth = 5)
    {
        this.minDepth = minDepth;
        this.maxDepth = maxDepth;
    }
    
    string generate(ref Mt19937 rng)
    {
        auto depth = uniform(minDepth, maxDepth + 1, rng);
        string[] components;
        
        foreach (i; 0 .. depth)
        {
            // Generate path component
            auto len = uniform(1, 10, rng);
            char[] component;
            foreach (j; 0 .. len)
            {
                auto c = uniform('a', 'z' + 1, rng);
                component ~= cast(char)c;
            }
            components ~= component.idup;
        }
        
        return "/" ~ components.join("/");
    }
    
    string shrink(string value)
    {
        import std.path : dirName;
        auto parent = dirName(value);
        if (parent != "/" && parent != value)
            return parent;
        return value;
    }
}

/// Graph generator (adjacency list representation)
class GraphGen : Generator!(int[][])
{
    private size_t minNodes;
    private size_t maxNodes;
    private double edgeProbability;
    
    this(size_t minNodes = 2, size_t maxNodes = 20, double edgeProbability = 0.3)
    {
        this.minNodes = minNodes;
        this.maxNodes = maxNodes;
        this.edgeProbability = edgeProbability;
    }
    
    int[][] generate(ref Mt19937 rng)
    {
        auto numNodes = uniform(minNodes, maxNodes + 1, rng);
        int[][] adjacency = new int[][numNodes];
        
        foreach (i; 0 .. numNodes)
        {
            foreach (j; 0 .. numNodes)
            {
                if (i != j && uniform(0.0, 1.0, rng) < edgeProbability)
                {
                    adjacency[i] ~= cast(int)j;
                }
            }
        }
        
        return adjacency;
    }
    
    int[][] shrink(int[][] value)
    {
        // Remove last node if possible
        if (value.length > minNodes)
            return value[0 .. $ - 1];
        
        // Remove an edge from last node
        if (value.length > 0 && value[$ - 1].length > 0)
        {
            auto copy = value.dup;
            copy[$ - 1] = copy[$ - 1][0 .. $ - 1];
            return copy;
        }
        
        return value;
    }
}

/// Convenience function to create property tests
auto property(Args...)(PropertyConfig config = PropertyConfig())
{
    return new PropertyTest!Args(config);
}

/// Helper to check and report property test results
void checkProperty(PropertyResult result, string propertyName = "property",
                   string file = __FILE__, size_t line = __LINE__)
{
    if (!result.passed)
    {
        auto msg = "Property '" ~ propertyName ~ "' failed:\n" ~
                   "  Test case: " ~ result.testCase.to!string ~ "\n" ~
                   "  Counterexample: " ~ result.counterexample ~ "\n" ~
                   "  " ~ result.message;
        throw new AssertionError(msg, file, line);
    }
}

// =============================================================================
// ADDITIONAL GENERATORS FOR COMPREHENSIVE PROPERTY TESTING
// =============================================================================

/// Boolean generator
class BoolGen : Generator!bool
{
    bool generate(ref Mt19937 rng)
    {
        return uniform(0, 2, rng) == 1;
    }
    
    bool shrink(bool value)
    {
        return false;  // Shrink to false
    }
}

/// Long integer generator
class LongGen : Generator!long
{
    private long min;
    private long max;
    
    this(long min = long.min / 2, long max = long.max / 2)
    {
        this.min = min;
        this.max = max;
    }
    
    long generate(ref Mt19937 rng)
    {
        // Use two 32-bit values to create 64-bit
        uint high = uniform!uint(rng);
        uint low = uniform!uint(rng);
        long result = (cast(long)high << 32) | low;
        
        // Clamp to range
        if (result < min) result = min;
        if (result > max) result = max;
        return result;
    }
    
    long shrink(long value)
    {
        if (value > 0)
            return value / 2;
        else if (value < 0)
            return value / 2;
        return 0;
    }
}

/// Unsigned long generator
class ULongGen : Generator!ulong
{
    private ulong min;
    private ulong max;
    
    this(ulong min = 0, ulong max = ulong.max / 2)
    {
        this.min = min;
        this.max = max;
    }
    
    ulong generate(ref Mt19937 rng)
    {
        uint high = uniform!uint(rng);
        uint low = uniform!uint(rng);
        ulong result = (cast(ulong)high << 32) | low;
        
        if (result < min) result = min;
        if (result > max) result = max;
        return result;
    }
    
    ulong shrink(ulong value)
    {
        if (value > 0)
            return value / 2;
        return 0;
    }
}

/// Unsigned int generator
class UIntGen : Generator!uint
{
    private uint min;
    private uint max;
    
    this(uint min = 0, uint max = uint.max)
    {
        this.min = min;
        this.max = max;
    }
    
    uint generate(ref Mt19937 rng)
    {
        return uniform(min, max, rng);
    }
    
    uint shrink(uint value)
    {
        if (value > 0)
            return value / 2;
        return 0;
    }
}

/// Byte array generator (for binary data)
class ByteArrayGen : Generator!(ubyte[])
{
    private size_t minLen;
    private size_t maxLen;
    
    this(size_t minLen = 0, size_t maxLen = 1000)
    {
        this.minLen = minLen;
        this.maxLen = maxLen;
    }
    
    ubyte[] generate(ref Mt19937 rng)
    {
        auto len = uniform(minLen, maxLen + 1, rng);
        ubyte[] result = new ubyte[len];
        
        foreach (i; 0 .. len)
            result[i] = cast(ubyte)uniform(0, 256, rng);
        
        return result;
    }
    
    ubyte[] shrink(ubyte[] value)
    {
        if (value.length > minLen)
            return value[0 .. value.length / 2];
        return value;
    }
}

/// Identifier generator (valid programming identifiers)
class IdentifierGen : Generator!string
{
    private size_t minLen;
    private size_t maxLen;
    
    this(size_t minLen = 1, size_t maxLen = 30)
    {
        this.minLen = minLen;
        this.maxLen = maxLen;
    }
    
    string generate(ref Mt19937 rng)
    {
        auto len = uniform(minLen, maxLen + 1, rng);
        char[] result;
        
        // First character must be letter or underscore
        auto firstChoice = uniform(0, 53, rng);
        if (firstChoice < 26)
            result ~= cast(char)('a' + firstChoice);
        else if (firstChoice < 52)
            result ~= cast(char)('A' + firstChoice - 26);
        else
            result ~= '_';
        
        // Rest can include digits
        foreach (i; 1 .. len)
        {
            auto choice = uniform(0, 63, rng);
            if (choice < 26)
                result ~= cast(char)('a' + choice);
            else if (choice < 52)
                result ~= cast(char)('A' + choice - 26);
            else if (choice < 62)
                result ~= cast(char)('0' + choice - 52);
            else
                result ~= '_';
        }
        
        return result.idup;
    }
    
    string shrink(string value)
    {
        if (value.length > minLen)
            return value[0 .. value.length / 2 + 1];  // Keep at least one char
        return value;
    }
}

/// DSL source string generator (generates valid-ish DSL snippets)
class DSLGen : Generator!string
{
    string generate(ref Mt19937 rng)
    {
        auto choice = uniform(0, 5, rng);
        
        switch (choice)
        {
            case 0:
                // Target declaration
                auto nameLen = uniform(3, 15, rng);
                char[] name;
                foreach (i; 0 .. nameLen)
                    name ~= cast(char)uniform('a', 'z' + 1, rng);
                return `target("` ~ name.idup ~ `") { type: executable; }`;
            
            case 1:
                // Variable declaration
                auto varLen = uniform(1, 10, rng);
                char[] varName;
                foreach (i; 0 .. varLen)
                    varName ~= cast(char)uniform('a', 'z' + 1, rng);
                auto val = uniform(-1000, 1000, rng);
                return "let " ~ varName.idup ~ " = " ~ val.to!string ~ ";";
            
            case 2:
                // String literal
                auto strLen = uniform(0, 50, rng);
                char[] str;
                foreach (i; 0 .. strLen)
                    str ~= cast(char)uniform('a', 'z' + 1, rng);
                return `"` ~ str.idup ~ `"`;
            
            case 3:
                // Number
                return uniform(-10000, 10000, rng).to!string;
            
            default:
                // Array literal
                auto arrLen = uniform(0, 5, rng);
                string[] elements;
                foreach (i; 0 .. arrLen)
                    elements ~= `"elem` ~ i.to!string ~ `"`;
                return "[" ~ elements.join(", ") ~ "]";
        }
    }
    
    string shrink(string value)
    {
        if (value.length > 10)
            return value[0 .. value.length / 2];
        return value;
    }
}

/// One-of generator (picks from a set of values)
class OneOfGen(T) : Generator!T
{
    private T[] choices;
    
    this(T[] choices)
    {
        this.choices = choices;
    }
    
    T generate(ref Mt19937 rng)
    {
        if (choices.length == 0)
            return T.init;
        return choices[uniform(0, choices.length, rng)];
    }
    
    T shrink(T value)
    {
        // Shrink to first choice
        if (choices.length > 0 && value != choices[0])
            return choices[0];
        return value;
    }
}

/// Nullable generator (occasionally returns null/empty)
class NullableGen(T) : Generator!T
{
    private Generator!T inner;
    private double nullProbability;
    
    this(Generator!T inner, double nullProbability = 0.1)
    {
        this.inner = inner;
        this.nullProbability = nullProbability;
    }
    
    T generate(ref Mt19937 rng)
    {
        if (uniform(0.0, 1.0, rng) < nullProbability)
            return T.init;
        return inner.generate(rng);
    }
    
    T shrink(T value)
    {
        return inner.shrink(value);
    }
}
