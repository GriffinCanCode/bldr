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
                        args = shrinkToMinimal(property, generators, args);
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
                    args = shrinkToMinimal(property, generators, args);
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
