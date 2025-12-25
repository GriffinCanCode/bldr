module frontend.cli.explorer.renderer;

import std.algorithm : min, max, sort, filter, map;
import std.array : array, appender, Appender;
import std.conv : to;
import std.format : format;
import frontend.cli.control.terminal;
import engine.graph.persistence.index;
import engine.graph.core.graph : BuildStatus;

/// ASCII graph renderer for terminal visualization
struct GraphRenderer
{
    private Capabilities caps;
    private bool useUnicode;
    private bool useColor;
    
    /// Box drawing characters
    private struct BoxChars
    {
        string topLeft, topRight, botLeft, botRight;
        string horizontal, vertical;
        string teeLeft, teeRight, teeUp, teeDown;
        string cross;
        string arrowRight, arrowDown, arrowLeft, arrowUp;
    }
    
    private static immutable BoxChars unicodeBox = BoxChars(
        "╭", "╮", "╰", "╯",
        "─", "│",
        "├", "┤", "┴", "┬",
        "┼",
        "→", "↓", "←", "↑"
    );
    
    private static immutable BoxChars asciiBox = BoxChars(
        "+", "+", "+", "+",
        "-", "|",
        "+", "+", "+", "+",
        "+",
        ">", "v", "<", "^"
    );
    
    private BoxChars box;
    
    this(Capabilities caps)
    {
        this.caps = caps;
        this.useUnicode = caps.supportsUnicode;
        this.useColor = caps.supportsColor;
        this.box = useUnicode ? unicodeBox : asciiBox;
    }
    
    /// Render a dependency tree as ASCII art
    string renderTree(GraphIndex index, string rootId, int maxDepth = 5, 
                      string selectedNode = "") @system
    {
        auto result = appender!string;
        renderTreeNode(index, rootId, 0, maxDepth, true, "", result, selectedNode);
        return result.data;
    }
    
    private void renderTreeNode(GraphIndex index, string nodeId, int depth, int maxDepth,
                                bool isLast, string prefix, 
                                ref Appender!string result, string selected) @system
    {
        if (depth > maxDepth) return;
        
        auto nodeResult = index.getNode(nodeId);
        if (nodeResult.isErr) return;
        
        auto node = nodeResult.unwrap();
        auto deps = index.getDependencies(nodeId);
        auto isSelected = nodeId == selected;
        
        // Build prefix for this node
        result.put(prefix);
        
        if (depth > 0)
        {
            result.put(isLast ? (useUnicode ? "╰── " : "`-- ") : (useUnicode ? "├── " : "|-- "));
        }
        
        // Status indicator
        if (useColor)
        {
            result.put(isSelected ? ANSI.BG[Color.Blue] ~ ANSI.FG[Color.White] : "");
            result.put(statusIcon(node.status, useUnicode));
            result.put(" ");
        }
        
        // Node name
        result.put(node.targetName);
        
        // Type badge
        if (!isSelected && useColor)
        {
            result.put(" ");
            result.put(ANSI.FG[Color.BrightBlack]);
            result.put("[");
            result.put(node.targetType);
            result.put("]");
        }
        
        if (useColor)
            result.put(ANSI.reset());
        
        result.put("\n");
        
        // Child prefix
        string childPrefix = prefix ~ (depth > 0 ? (isLast ? "    " : (useUnicode ? "│   " : "|   ")) : "");
        
        // Render children
        foreach (i, dep; deps)
        {
            renderTreeNode(index, dep, depth + 1, maxDepth, 
                          i == deps.length - 1, childPrefix, result, selected);
        }
    }
    
    /// Render a horizontal flow diagram showing critical path
    string renderCriticalPathFlow(string[] path, GraphIndex index) @system
    {
        if (path.length == 0) return "  (empty path)\n";
        
        auto result = appender!string;
        auto width = caps.width > 20 ? caps.width - 10 : 70;
        
        // Calculate box sizes
        auto boxWidth = min(25, (width - path.length * 3) / path.length);
        if (boxWidth < 8) boxWidth = 8;
        
        // Top line of boxes
        result.put("  ");
        foreach (i, nodeId; path)
        {
            auto nodeResult = index.getNode(nodeId);
            auto name = nodeResult.isOk ? truncateCenter(nodeResult.unwrap().targetName, boxWidth - 2) : nodeId;
            
            if (useUnicode)
            {
                result.put("╭");
                foreach (_; 0 .. boxWidth - 2) result.put("─");
                result.put("╮");
            }
            else
            {
                result.put("+");
                foreach (_; 0 .. boxWidth - 2) result.put("-");
                result.put("+");
            }
            
            if (i < path.length - 1)
                result.put("   ");
        }
        result.put("\n");
        
        // Content line
        result.put("  ");
        foreach (i, nodeId; path)
        {
            auto nodeResult = index.getNode(nodeId);
            auto name = nodeResult.isOk ? truncateCenter(nodeResult.unwrap().targetName, boxWidth - 2) : nodeId;
            
            result.put(useUnicode ? "│" : "|");
            if (useColor)
            {
                result.put(ANSI.FG[Color.Cyan]);
                result.put(ANSI.BOLD);
            }
            result.put(centerPad(name, boxWidth - 2));
            if (useColor)
                result.put(ANSI.reset());
            result.put(useUnicode ? "│" : "|");
            
            if (i < path.length - 1)
            {
                if (useColor)
                    result.put(ANSI.FG[Color.Yellow]);
                result.put(useUnicode ? "─→─" : "-->");
                if (useColor)
                    result.put(ANSI.reset());
            }
        }
        result.put("\n");
        
        // Bottom line with timing
        result.put("  ");
        foreach (i, nodeId; path)
        {
            auto nodeResult = index.getNode(nodeId);
            string timeStr = "";
            if (nodeResult.isOk && nodeResult.unwrap().buildDuration > 0)
            {
                timeStr = formatMs(nodeResult.unwrap().buildDuration);
            }
            
            if (useUnicode)
            {
                result.put("╰");
                auto content = centerPad(timeStr, boxWidth - 2);
                if (useColor && timeStr.length > 0)
                    result.put(ANSI.FG[Color.Yellow]);
                result.put(content);
                if (useColor && timeStr.length > 0)
                    result.put(ANSI.reset());
                result.put("╯");
            }
            else
            {
                result.put("+");
                result.put(centerPad(timeStr, boxWidth - 2));
                result.put("+");
            }
            
            if (i < path.length - 1)
                result.put("   ");
        }
        result.put("\n");
        
        return result.data;
    }
    
    /// Render a bar chart for bottleneck analysis
    string renderBottleneckBars(BottleneckInfo[] bottlenecks, size_t maxBars = 10) @system
    {
        if (bottlenecks.length == 0) return "  No bottlenecks detected\n";
        
        auto result = appender!string;
        auto barWidth = 30;
        auto maxImpact = bottlenecks[0].impact;
        
        foreach (i, b; bottlenecks)
        {
            if (i >= maxBars) break;
            
            auto normalized = maxImpact > 0 ? cast(double)b.impact / maxImpact : 0;
            auto filledWidth = cast(int)(normalized * barWidth);
            
            result.put("  ");
            
            // Bar
            if (useColor)
            {
                auto color = normalized > 0.7 ? Color.Red : 
                            (normalized > 0.4 ? Color.Yellow : Color.Green);
                result.put(ANSI.FG[color]);
            }
            
            foreach (_; 0 .. filledWidth)
                result.put(useUnicode ? "█" : "#");
            
            if (useColor)
                result.put(ANSI.FG[Color.BrightBlack]);
            
            foreach (_; filledWidth .. barWidth)
                result.put(useUnicode ? "░" : ".");
            
            if (useColor)
                result.put(ANSI.reset());
            
            // Label
            result.put("  ");
            result.put(truncate(b.nodeId, 30));
            result.put(format(" (%d deps", b.dependentCount));
            if (b.buildDuration > 0)
                result.put(format(", %s", formatMs(b.buildDuration)));
            result.put(")\n");
        }
        
        return result.data;
    }
    
    /// Render depth histogram as ASCII sparkline
    string renderDepthSparkline(size_t[] countsByDepth) @system
    {
        if (countsByDepth.length == 0) return "";
        
        auto result = appender!string;
        auto maxCount = countsByDepth[0];
        foreach (c; countsByDepth)
            maxCount = max(maxCount, c);
        
        // Sparkline characters (ascending height)
        immutable sparkChars = useUnicode ? " ▁▂▃▄▅▆▇█" : " .:-=+#@";
        
        result.put("  Depth: [");
        foreach (i, count; countsByDepth)
        {
            auto normalized = maxCount > 0 ? cast(double)count / maxCount : 0;
            auto charIndex = cast(size_t)(normalized * (sparkChars.length - 1));
            result.put(sparkChars[charIndex .. charIndex + 1]);
        }
        result.put("]");
        result.put(format(" (max parallelism: %d at depth %d)\n", maxCount, maxParallelismDepth(countsByDepth)));
        
        return result.data;
    }
    
    /// Render a mini status legend
    string renderStatusLegend() @system
    {
        auto result = appender!string;
        
        result.put("  ");
        
        void addStatus(BuildStatus status, string label)
        {
            if (useColor)
                result.put(ANSI.FG[statusColor(status)]);
            result.put(statusIcon(status, useUnicode));
            if (useColor)
                result.put(ANSI.reset());
            result.put(" ");
            result.put(label);
            result.put("  ");
        }
        
        addStatus(BuildStatus.Pending, "Pending");
        addStatus(BuildStatus.Building, "Building");
        addStatus(BuildStatus.Success, "Success");
        addStatus(BuildStatus.Failed, "Failed");
        addStatus(BuildStatus.Cached, "Cached");
        
        result.put("\n");
        return result.data;
    }
    
    /// Render a node info card
    string renderNodeCard(GraphNodeEntry node, string[] deps, string[] dependents) @system
    {
        auto result = appender!string;
        auto cardWidth = min(60, caps.width - 4);
        
        // Top border
        result.put("  ");
        result.put(box.topLeft);
        foreach (_; 0 .. cardWidth - 2) result.put(box.horizontal);
        result.put(box.topRight);
        result.put("\n");
        
        // Title
        result.put("  ");
        result.put(box.vertical);
        result.put(" ");
        if (useColor)
        {
            result.put(ANSI.FG[Color.Cyan]);
            result.put(ANSI.BOLD);
        }
        result.put(truncate(node.targetName, cardWidth - 4));
        if (useColor)
            result.put(ANSI.reset());
        result.put(padRight("", cardWidth - 3 - min(cardWidth - 4, node.targetName.length)));
        result.put(box.vertical);
        result.put("\n");
        
        // Separator
        result.put("  ");
        result.put(box.teeLeft);
        foreach (_; 0 .. cardWidth - 2) result.put(box.horizontal);
        result.put(box.teeRight);
        result.put("\n");
        
        // Properties
        void addProperty(string label, string value, Color valueColor = Color.White)
        {
            result.put("  ");
            result.put(box.vertical);
            result.put(" ");
            if (useColor)
                result.put(ANSI.FG[Color.BrightBlack]);
            result.put(padRight(label ~ ":", 12));
            if (useColor)
            {
                result.put(ANSI.reset());
                result.put(ANSI.FG[valueColor]);
            }
            result.put(truncate(value, cardWidth - 16));
            if (useColor)
                result.put(ANSI.reset());
            result.put(padRight("", cardWidth - 15 - min(cardWidth - 16, value.length)));
            result.put(box.vertical);
            result.put("\n");
        }
        
        addProperty("Type", node.targetType);
        addProperty("Status", statusStr(node.status), statusColor(node.status));
        addProperty("Depth", node.depth.to!string);
        if (node.buildDuration > 0)
            addProperty("Duration", formatMs(node.buildDuration), Color.Yellow);
        addProperty("Deps", deps.length.to!string, Color.Green);
        addProperty("Dependents", dependents.length.to!string, Color.Magenta);
        
        // Bottom border
        result.put("  ");
        result.put(box.botLeft);
        foreach (_; 0 .. cardWidth - 2) result.put(box.horizontal);
        result.put(box.botRight);
        result.put("\n");
        
        return result.data;
    }
}

// Import bottleneck info struct
import engine.graph.persistence.queries : BottleneckInfo;

// Helper functions
private string statusIcon(BuildStatus status, bool unicode) @system
{
    if (unicode)
    {
        final switch (status)
        {
            case BuildStatus.Pending: return "○";
            case BuildStatus.Building: return "◐";
            case BuildStatus.Success: return "●";
            case BuildStatus.Failed: return "✗";
            case BuildStatus.Cached: return "◉";
        }
    }
    else
    {
        final switch (status)
        {
            case BuildStatus.Pending: return "o";
            case BuildStatus.Building: return "*";
            case BuildStatus.Success: return "+";
            case BuildStatus.Failed: return "x";
            case BuildStatus.Cached: return "@";
        }
    }
}

private Color statusColor(BuildStatus status) pure @safe
{
    final switch (status)
    {
        case BuildStatus.Pending: return Color.BrightBlack;
        case BuildStatus.Building: return Color.Cyan;
        case BuildStatus.Success: return Color.Green;
        case BuildStatus.Failed: return Color.Red;
        case BuildStatus.Cached: return Color.Yellow;
    }
}

private string statusStr(BuildStatus status) pure @safe
{
    final switch (status)
    {
        case BuildStatus.Pending: return "Pending";
        case BuildStatus.Building: return "Building";
        case BuildStatus.Success: return "Success";
        case BuildStatus.Failed: return "Failed";
        case BuildStatus.Cached: return "Cached";
    }
}

private string formatMs(long ms) pure @safe
{
    if (ms < 1000) return format("%dms", ms);
    if (ms < 60_000) return format("%.1fs", ms / 1000.0);
    return format("%dm%ds", ms / 60_000, (ms % 60_000) / 1000);
}

private string truncate(string s, size_t maxLen) pure @safe
{
    if (s.length <= maxLen) return s;
    return s[0 .. maxLen > 3 ? maxLen - 3 : maxLen] ~ "...";
}

private string truncateCenter(string s, size_t maxLen) pure @safe
{
    if (s.length <= maxLen) return s;
    auto half = (maxLen - 3) / 2;
    return s[0 .. half] ~ "..." ~ s[$ - half .. $];
}

private string centerPad(string s, size_t width) pure @safe
{
    if (s.length >= width) return s[0 .. width];
    auto leftPad = (width - s.length) / 2;
    auto rightPad = width - s.length - leftPad;
    char[] result = new char[width];
    result[] = ' ';
    result[leftPad .. leftPad + s.length] = s;
    return result.idup;
}

private string padRight(string s, size_t width) pure @safe
{
    if (s.length >= width) return s;
    char[] result = new char[width];
    result[] = ' ';
    result[0 .. s.length] = s;
    return result.idup;
}

private size_t maxParallelismDepth(size_t[] counts) pure @safe
{
    size_t maxIdx = 0;
    size_t maxVal = 0;
    foreach (i, c; counts)
    {
        if (c > maxVal)
        {
            maxVal = c;
            maxIdx = i;
        }
    }
    return maxIdx;
}

