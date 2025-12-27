module infrastructure.telemetry.visualization.flamegraph;

import std.datetime : SysTime, Duration, dur;
import std.conv : to;
import std.format : format;
import std.array : appender, Appender;
import std.algorithm : sort, map, sum, maxElement, group, each;
import std.range : array, enumerate, walkLength;
import std.string : strip, split, join;
import core.sync.mutex : Mutex;
import infrastructure.telemetry.collection.collector : BuildSession, TargetMetric;
import infrastructure.errors;

/// Flamegraph generation from build performance data
/// 
/// Features:
/// - Hierarchical performance visualization
/// - Call stack aggregation
/// - SVG generation compatible with flamegraph.pl format
/// - Target dependency tree flamegraph
/// - Time-based performance profiling
/// 
/// Architecture:
/// - FlameNode: Hierarchical node in flamegraph
/// - FlameGraphBuilder: Constructs flamegraph from build data
/// - SVG rendering with interactive features

/// Flamegraph node representing a call stack frame
struct FlameNode
{
    string name;
    Duration duration;
    FlameNode[] children;
    size_t samples;
    
    /// Total duration including children
    @property Duration totalDuration() const pure @system
    {
        Duration total = duration;
        foreach (child; children)
        {
            total = total + child.totalDuration;
        }
        return total;
    }
    
    /// Add or update child node
    void addChild(FlameNode node) @system
    {
        // Check if child with same name exists
        foreach (ref child; children)
        {
            if (child.name == node.name)
            {
                child.duration += node.duration;
                child.samples += node.samples;
                
                // Merge children recursively
                foreach (newGrandchild; node.children)
                {
                    child.addChild(newGrandchild);
                }
                return;
            }
        }
        
        // Add as new child
        children ~= node;
    }
}

/// Flamegraph builder
final class FlameGraphBuilder
{
    private FlameNode root;
    private Mutex builderMutex;
    
    this() @system
    {
        this.builderMutex = new Mutex();
        this.root = FlameNode("root", dur!"msecs"(0));
    }
    
    /// Add build session to flamegraph
    void addSession(BuildSession session) @system
    {
        synchronized (builderMutex)
        {
            // Create root node for this session
            auto sessionNode = FlameNode(
                format("build_%s", session.startTime.toISOExtString()),
                session.totalDuration
            );
            sessionNode.samples = 1;
            
            // Add each target as a child
            foreach (targetId, target; session.targets)
            {
                auto targetNode = FlameNode(
                    targetId,
                    target.duration
                );
                targetNode.samples = 1;
                
                sessionNode.addChild(targetNode);
            }
            
            root.addChild(sessionNode);
        }
    }
    
    /// Build flamegraph from call stack samples
    /// Format: "func1;func2;func3 weight"
    void addStackSample(string stack, Duration weight = dur!"msecs"(1)) @system
    {
        synchronized (builderMutex)
        {
            auto frames = stack.strip().split(";");
            if (frames.length == 0)
                return;
            
            FlameNode* current = &root;
            
            foreach (frame; frames)
            {
                if (frame.length == 0)
                    continue;
                
                // Find or create child with this name
                FlameNode* found = null;
                foreach (ref child; current.children)
                {
                    if (child.name == frame)
                    {
                        found = &child;
                        break;
                    }
                }
                
                if (found is null)
                {
                    // Create new child
                    FlameNode newNode;
                    newNode.name = frame;
                    newNode.duration = weight;
                    newNode.samples = 1;
                    current.children ~= newNode;
                    current = &current.children[$ - 1];
                }
                else
                {
                    // Update existing child
                    found.duration += weight;
                    found.samples += 1;
                    current = found;
                }
            }
        }
    }
    
    /// Generate flamegraph in folded stack format
    /// Compatible with flamegraph.pl
    Result!(string, FlameError) toFoldedStacks() const @system
    {
        synchronized (cast(Mutex)builderMutex)
        {
            try
            {
                auto buffer = appender!string;
                generateFoldedStacks(root, "", buffer);
                return Result!(string, FlameError).ok(buffer.data);
            }
            catch (Exception e)
            {
                return Result!(string, FlameError).err(
                    FlameError.generationFailed(e.msg));
            }
        }
    }
    
    /// Generate SVG flamegraph
    Result!(string, FlameError) toSVG(uint width = 1200, uint height = 800) const @system
    {
        synchronized (cast(Mutex)builderMutex)
        {
            try
            {
                auto generator = new SVGFlameGraphGenerator(width, height);
                return generator.generate(root);
            }
            catch (Exception e)
            {
                return Result!(string, FlameError).err(
                    FlameError.generationFailed(e.msg));
            }
        }
    }
    
    /// Get statistics
    struct Stats
    {
        size_t totalSamples;
        Duration totalDuration;
        size_t uniqueFrames;
        size_t maxDepth;
    }
    
    /// Get flamegraph statistics
    Stats getStats() const @system
    {
        synchronized (cast(Mutex)builderMutex)
        {
            Stats stats;
            stats.totalDuration = root.totalDuration;
            collectStats(root, 0, stats);
            return stats;
        }
    }
    
    private void generateFoldedStacks(in FlameNode node, string prefix, ref Appender!string buffer) const @system
    {
        if (node.children.length == 0)
        {
            // Leaf node - output stack
            if (prefix.length > 0 && node.duration.total!"msecs" > 0)
            {
                buffer ~= format("%s;%s %d\n", prefix, node.name, node.duration.total!"msecs");
            }
            return;
        }
        
        // Internal node - recurse to children
        immutable newPrefix = prefix.length > 0 ? format("%s;%s", prefix, node.name) : node.name;
        
        foreach (child; node.children)
        {
            generateFoldedStacks(child, newPrefix, buffer);
        }
    }
    
    private void collectStats(in FlameNode node, size_t depth, ref Stats stats) const pure @system
    {
        stats.totalSamples += node.samples;
        stats.uniqueFrames += 1;
        
        if (depth > stats.maxDepth)
            stats.maxDepth = depth;
        
        foreach (child; node.children)
        {
            collectStats(child, depth + 1, stats);
        }
    }
}

/// SVG flamegraph generator
private final class SVGFlameGraphGenerator
{
    private uint width;
    private uint height;
    private enum uint FRAME_HEIGHT = 16;
    private enum uint PADDING = 10;
    private enum uint TEXT_SIZE = 12;
    
    this(uint width, uint height) pure @system
    {
        this.width = width;
        this.height = height;
    }
    
    Result!(string, FlameError) generate(in FlameNode root) const @system
    {
        try
        {
            auto buffer = appender!string;
            
            // SVG header
            buffer ~= format(`<?xml version="1.0" standalone="no"?>` ~ "\n");
            buffer ~= format(`<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">` ~ "\n");
            buffer ~= format(`<svg version="1.1" width="%d" height="%d" xmlns="http://www.w3.org/2000/svg">` ~ "\n", width, height);
            
            // Title
            buffer ~= format(`<text x="%d" y="%d" font-family="Verdana" font-size="17" fill="rgb(0,0,0)">Builder Flamegraph</text>` ~ "\n",
                PADDING, 25);
            
            // Draw flame
            immutable totalDuration = root.totalDuration;
            if (totalDuration.total!"msecs" > 0)
            {
                drawFlame(root, 0, PADDING + 30, width - 2 * PADDING, totalDuration, buffer);
            }
            
            // SVG footer
            buffer ~= "</svg>\n";
            
            return Result!(string, FlameError).ok(buffer.data);
        }
        catch (Exception e)
        {
            return Result!(string, FlameError).err(
                FlameError.generationFailed(e.msg));
        }
    }
    
    private void drawFlame(in FlameNode node, uint x, uint y, uint width, Duration totalDuration, ref Appender!string buffer) const @system
    {
        if (node.children.length == 0)
            return;
        
        uint currentX = x;
        
        foreach (child; node.children)
        {
            immutable childDuration = child.totalDuration;
            if (childDuration.total!"msecs" == 0)
                continue;
            
            // Calculate width proportional to duration
            immutable childWidth = cast(uint)(
                (childDuration.total!"msecs" * width) / totalDuration.total!"msecs"
            );
            
            if (childWidth < 1)
                continue;
            
            // Choose color based on depth/name hash
            immutable color = hashColor(child.name);
            
            // Draw rectangle
            buffer ~= format(`<rect x="%d" y="%d" width="%d" height="%d" fill="rgb(%s)" stroke="white"/>` ~ "\n",
                currentX, y, childWidth, FRAME_HEIGHT, color);
            
            // Draw text if wide enough
            if (childWidth > 20)
            {
                immutable textX = currentX + 3;
                immutable textY = y + TEXT_SIZE;
                
                // Truncate text if too long
                string text = child.name;
                if (text.length > childWidth / 6)
                {
                    text = text[0 .. childWidth / 6] ~ "..";
                }
                
                buffer ~= format(`<text x="%d" y="%d" font-family="Verdana" font-size="%d" fill="rgb(0,0,0)">%s</text>` ~ "\n",
                    textX, textY, TEXT_SIZE - 2, text);
            }
            
            // Recurse to children
            drawFlame(child, currentX, y + FRAME_HEIGHT + 1, childWidth, totalDuration, buffer);
            
            currentX += childWidth;
        }
    }
    
    private string hashColor(string name) const pure @system
    {
        // Simple hash to RGB color
        uint hash = 0;
        foreach (c; name)
        {
            hash = hash * 31 + c;
        }
        
        // Generate warm colors (red/orange/yellow spectrum)
        immutable r = 200 + (hash % 56);
        immutable g = 100 + ((hash >> 8) % 156);
        immutable b = (hash >> 16) % 100;
        
        return format("%d,%d,%d", r, g, b);
    }
}

/// Flamegraph-specific errors
struct FlameError
{
    string message;
    ErrorCode code;
    
    static FlameError generationFailed(string details) pure @system
    {
        return FlameError("Flamegraph generation failed: " ~ details, Internal.Error);
    }
    
    static FlameError invalidData(string details) pure @system
    {
        return FlameError("Invalid data: " ~ details, Telemetry.Invalid);
    }
    
    string toString() const pure nothrow @system
    {
        return message;
    }
}

/// Build flamegraph from build sessions
Result!(FlameGraphBuilder, FlameError) buildFromSessions(BuildSession[] sessions) @system
{
    try
    {
        auto builder = new FlameGraphBuilder();
        
        foreach (session; sessions)
        {
            builder.addSession(session);
        }
        
        return Result!(FlameGraphBuilder, FlameError).ok(builder);
    }
    catch (Exception e)
    {
        return Result!(FlameGraphBuilder, FlameError).err(
            FlameError.generationFailed(e.msg));
    }
}

/// Build dependency flamegraph from single session
Result!(FlameGraphBuilder, FlameError) buildDependencyFlame(BuildSession session) @system
{
    try
    {
        auto builder = new FlameGraphBuilder();
        
        // Create hierarchical view based on build order
        // In a real implementation, you'd want to track actual dependencies
        // For now, we'll use a flat structure
        
        foreach (targetId, target; session.targets)
        {
            immutable stack = format("build;%s", targetId);
            builder.addStackSample(stack, target.duration);
        }
        
        return Result!(FlameGraphBuilder, FlameError).ok(builder);
    }
    catch (Exception e)
    {
        return Result!(FlameGraphBuilder, FlameError).err(
            FlameError.generationFailed(e.msg));
    }
}

/// Save flamegraph to file
Result!FlameError saveFlamegraphSVG(FlameGraphBuilder builder, string filepath) @system
{
    import std.file : write;
    
    auto svgResult = builder.toSVG();
    if (svgResult.isErr)
        return Result!FlameError.err(svgResult.unwrapErr());
    
    try
    {
        write(filepath, svgResult.unwrap());
        return Result!FlameError.ok();
    }
    catch (Exception e)
    {
        return Result!FlameError.err(
            FlameError.generationFailed("Failed to write file: " ~ e.msg));
    }
}

/// Save folded stacks to file (for use with flamegraph.pl)
Result!FlameError saveFoldedStacks(FlameGraphBuilder builder, string filepath) @system
{
    import std.file : write;
    
    auto stacksResult = builder.toFoldedStacks();
    if (stacksResult.isErr)
        return Result!FlameError.err(stacksResult.unwrapErr());
    
    try
    {
        write(filepath, stacksResult.unwrap());
        return Result!FlameError.ok();
    }
    catch (Exception e)
    {
        return Result!FlameError.err(
            FlameError.generationFailed("Failed to write file: " ~ e.msg));
    }
}

