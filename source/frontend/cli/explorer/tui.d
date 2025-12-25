module frontend.cli.explorer.tui;

import std.algorithm : min, max, filter, map, canFind, sort;
import std.array : array, appender, Appender;
import std.conv : to;
import std.format : format;
import std.string : strip, toLower;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import frontend.cli.explorer.views;
import frontend.cli.explorer.renderer;
import engine.graph.persistence.index;
import engine.graph.persistence.queries;
import engine.graph.core.graph : BuildStatus;

/// View modes for the explorer
enum ExplorerView
{
    Tree,           /// Hierarchical dependency tree
    CriticalPath,   /// Critical path with timing
    Impact,         /// Impact analysis view
    Bottlenecks,    /// Bottleneck detection
    Search,         /// Search results
    Details         /// Node details panel
}

/// Explorer state
struct ExplorerState
{
    ExplorerView currentView = ExplorerView.Tree;
    string selectedNode;
    string[] expandedNodes;
    size_t scrollOffset;
    size_t cursorRow;
    string searchQuery;
    string[] searchResults;
    bool showHelp;
    string focusedTarget;
    
    /// Check if node is expanded
    bool isExpanded(string nodeId) const @safe
        => expandedNodes.canFind(nodeId);
    
    /// Toggle node expansion
    void toggleExpanded(string nodeId) @safe
    {
        if (isExpanded(nodeId))
            expandedNodes = expandedNodes.filter!(n => n != nodeId).array;
        else
            expandedNodes ~= nodeId;
    }
}

/// Interactive TUI for dependency graph exploration
final class DependencyExplorer
{
    private GraphIndex graphIndex;
    private GraphQuery graphQuery;
    private ExplorerState state;
    private Terminal terminal;
    private Formatter formatter;
    private GraphRenderer graphRenderer;
    private ViewManager viewManager;
    private Capabilities caps;
    private bool running;
    private termios originalTermios;
    
    this(string cacheDir = ".builder-cache") @system
    {
        this.caps = Capabilities.detect();
        this.terminal = Terminal(caps);
        this.formatter = Formatter(caps);
        this.graphRenderer = GraphRenderer(caps);
        
        // Initialize graph index
        this.graphIndex = new GraphIndex(cacheDir);
        this.graphQuery = GraphQuery(graphIndex);
        this.viewManager = new ViewManager(graphIndex, caps);
        
        // Set initial selection to first root
        auto roots = graphIndex.getRoots();
        if (roots.length > 0)
            state.selectedNode = roots[0];
    }
    
    /// Launch interactive explorer
    void run(string focusTarget = "") @system
    {
        if (!caps.isInteractive)
        {
            terminal.writeColored("Error: ", Color.Red, Style.Bold);
            terminal.writeln("Interactive mode requires a TTY");
            terminal.flush();
            return;
        }
        
        if (focusTarget.length > 0)
        {
            state.focusedTarget = focusTarget;
            state.selectedNode = focusTarget;
            state.expandedNodes ~= focusTarget;
        }
        
        enableRawMode();
        scope(exit) disableRawMode();
        
        terminal.write(ANSI.cursorHide());
        terminal.write(ANSI.clearScreen());
        terminal.flush();
        
        scope(exit)
        {
            terminal.write(ANSI.cursorShow());
            terminal.write(ANSI.clearScreen());
            terminal.flush();
        }
        
        running = true;
        render();
        
        while (running)
        {
            if (handleInput())
                render();
        }
    }
    
    /// Render current view
    private void render() @system
    {
        terminal.write(ANSI.cursorTo(1, 1));
        terminal.write(ANSI.clearScreen());
        
        renderHeader();
        renderBody();
        renderFooter();
        
        terminal.flush();
    }
    
    /// Render header bar
    private void renderHeader() @system
    {
        auto width = caps.width > 0 ? caps.width : 80;
        
        // Title bar with gradient-style accent
        terminal.write(ANSI.BG[Color.Blue]);
        terminal.write(ANSI.FG[Color.White]);
        terminal.write(ANSI.BOLD);
        
        string title = " ◈ BLDR Dependency Explorer ";
        string viewName = viewNameString(state.currentView);
        string stats = format("  %d nodes  ", graphIndex.getStats().totalNodes);
        
        auto padding = width - title.length - viewName.length - stats.length;
        terminal.write(title);
        terminal.write(ANSI.FG[Color.BrightCyan]);
        terminal.write(viewName);
        
        if (padding > 0)
        {
            foreach (_; 0 .. padding)
                terminal.write(" ");
        }
        
        terminal.write(ANSI.FG[Color.BrightWhite]);
        terminal.write(stats);
        terminal.write(ANSI.reset());
        terminal.writeln();
        
        // Secondary info bar
        terminal.write(ANSI.BG[Color.BrightBlack]);
        terminal.write(ANSI.FG[Color.White]);
        
        if (state.selectedNode.length > 0)
        {
            terminal.write(" ▸ ");
            terminal.write(state.selectedNode);
        }
        else
        {
            terminal.write(" No selection");
        }
        
        auto remainingWidth = width - state.selectedNode.length - 4;
        if (remainingWidth > 0)
        {
            foreach (_; 0 .. remainingWidth)
                terminal.write(" ");
        }
        
        terminal.write(ANSI.reset());
        terminal.writeln();
        terminal.writeln();
    }
    
    /// Render main body based on current view
    private void renderBody() @system
    {
        final switch (state.currentView)
        {
            case ExplorerView.Tree:
                renderTreeView();
                break;
            case ExplorerView.CriticalPath:
                renderCriticalPathView();
                break;
            case ExplorerView.Impact:
                renderImpactView();
                break;
            case ExplorerView.Bottlenecks:
                renderBottlenecksView();
                break;
            case ExplorerView.Search:
                renderSearchView();
                break;
            case ExplorerView.Details:
                renderDetailsView();
                break;
        }
        
        if (state.showHelp)
            renderHelpOverlay();
    }
    
    /// Render tree view
    private void renderTreeView() @system
    {
        auto roots = graphIndex.getRoots();
        auto height = caps.height > 6 ? caps.height - 6 : 18;
        
        auto lines = appender!(string[]);
        
        foreach (root; roots)
            renderTreeNode(root, 0, lines, state.selectedNode);
        
        // Paginate
        auto totalLines = lines.data.length;
        auto visibleLines = min(height, totalLines - state.scrollOffset);
        
        foreach (i; state.scrollOffset .. state.scrollOffset + visibleLines)
        {
            if (i < totalLines)
                terminal.writeln(lines.data[i]);
        }
        
        // Scroll indicator
        if (totalLines > height)
        {
            terminal.writeln();
            terminal.write(ANSI.FG[Color.BrightBlack]);
            auto scrollPercent = cast(float)state.scrollOffset / (totalLines - height);
            terminal.write(format("  ─── %d/%d (%.0f%%) ───", 
                          state.scrollOffset + 1, totalLines, scrollPercent * 100));
            terminal.write(ANSI.reset());
            terminal.writeln();
        }
    }
    
    /// Render a tree node recursively
    private void renderTreeNode(string nodeId, int depth, 
                                ref Appender!(string[]) lines, 
                                string selected) @system
    {
        auto nodeResult = graphIndex.getNode(nodeId);
        if (nodeResult.isErr) return;
        
        auto node = nodeResult.unwrap();
        auto isSelected = nodeId == selected;
        auto isExpanded = state.isExpanded(nodeId);
        auto deps = graphIndex.getDependencies(nodeId);
        
        // Build line
        auto line = appender!string;
        
        // Indentation with tree lines
        foreach (_; 0 .. depth)
            line.put("  │ ");
        
        // Expand indicator
        if (deps.length > 0)
            line.put(isExpanded ? "  ▼ " : "  ▶ ");
        else
            line.put("    ");
        
        // Selection highlight
        if (isSelected)
        {
            line.put(ANSI.BG[Color.Blue]);
            line.put(ANSI.FG[Color.White]);
            line.put(ANSI.BOLD);
        }
        
        // Status icon
        line.put(statusIcon(node.status));
        line.put(" ");
        
        // Node name
        line.put(node.targetName);
        
        // Type badge
        if (!isSelected)
        {
            line.put("  ");
            line.put(ANSI.FG[Color.BrightBlack]);
            line.put("[");
            line.put(node.targetType);
            line.put("]");
        }
        
        // Build duration if available
        if (node.buildDuration > 0)
        {
            line.put("  ");
            line.put(ANSI.FG[Color.Yellow]);
            line.put(formatDurationMs(node.buildDuration));
        }
        
        line.put(ANSI.reset());
        lines.put(line.data);
        
        // Render children if expanded
        if (isExpanded)
        {
            foreach (dep; deps)
                renderTreeNode(dep, depth + 1, lines, selected);
        }
    }
    
    /// Render critical path view
    private void renderCriticalPathView() @system
    {
        auto criticalPath = graphIndex.getCriticalPath();
        
        terminal.writeColored("  ╔═══════════════════════════════════════════════════════════════╗\n", 
                             Color.Cyan);
        terminal.writeColored("  ║  ", Color.Cyan);
        terminal.writeColored("CRITICAL PATH", Color.Yellow, Style.Bold);
        terminal.writeColored(" ─ Longest dependency chain                    ║\n", Color.Cyan);
        terminal.writeColored("  ╚═══════════════════════════════════════════════════════════════╝\n\n", 
                             Color.Cyan);
        
        if (criticalPath.length == 0)
        {
            terminal.writeColored("    No critical path found (empty graph)\n", Color.BrightBlack);
            return;
        }
        
        long totalTime;
        foreach (i, nodeId; criticalPath)
        {
            auto nodeResult = graphIndex.getNode(nodeId);
            if (nodeResult.isErr) continue;
            
            auto node = nodeResult.unwrap();
            auto isLast = i == criticalPath.length - 1;
            auto isSelected = nodeId == state.selectedNode;
            
            totalTime += node.buildDuration;
            
            // Timeline connector
            terminal.write("    ");
            if (isSelected)
                terminal.writeColored("●", Color.Cyan, Style.Bold);
            else
                terminal.writeColored("○", Color.BrightBlack);
            
            if (!isLast)
            {
                terminal.writeln();
                terminal.writeColored("    │\n", Color.BrightBlack);
                terminal.writeColored("    ▼\n", Color.BrightBlack);
            }
            
            // Node info
            terminal.write("  ");
            if (isSelected)
            {
                terminal.write(ANSI.BG[Color.Blue]);
                terminal.write(ANSI.FG[Color.White]);
            }
            terminal.write(statusIcon(node.status));
            terminal.write(" ");
            terminal.write(node.targetName);
            
            if (node.buildDuration > 0)
            {
                terminal.write("  ");
                terminal.writeColored(formatDurationMs(node.buildDuration), Color.Yellow);
            }
            
            terminal.write(ANSI.reset());
            terminal.writeln();
        }
        
        terminal.writeln();
        terminal.writeColored("    ═══════════════════════════════════════════\n", Color.BrightBlack);
        terminal.write("    Total critical path time: ");
        terminal.writeColored(formatDurationMs(totalTime), Color.Green, Style.Bold);
        terminal.write(format(" (%d steps)\n", criticalPath.length));
    }
    
    /// Render impact analysis view
    private void renderImpactView() @system
    {
        terminal.writeColored("  ╔═══════════════════════════════════════════════════════════════╗\n", 
                             Color.Magenta);
        terminal.writeColored("  ║  ", Color.Magenta);
        terminal.writeColored("IMPACT ANALYSIS", Color.Yellow, Style.Bold);
        terminal.writeColored(" ─ What rebuilds if '", Color.Magenta);
        terminal.writeColored(truncate(state.selectedNode, 20), Color.Cyan);
        terminal.writeColored("' changes    ║\n", Color.Magenta);
        terminal.writeColored("  ╚═══════════════════════════════════════════════════════════════╝\n\n", 
                             Color.Magenta);
        
        if (state.selectedNode.length == 0)
        {
            terminal.writeColored("    Select a node to see impact analysis\n", Color.BrightBlack);
            return;
        }
        
        auto impacted = graphQuery.getImpact(state.selectedNode);
        
        if (impacted.length == 0)
        {
            terminal.writeColored("    ✓ ", Color.Green);
            terminal.writeln("No other targets depend on this node");
            return;
        }
        
        terminal.write("    ");
        terminal.writeColored(format("%d", impacted.length), Color.Red, Style.Bold);
        terminal.writeln(" targets would need to rebuild:\n");
        
        auto height = caps.height > 12 ? caps.height - 12 : 10;
        auto shown = min(height, impacted.length);
        
        foreach (i; 0 .. shown)
        {
            auto nodeId = impacted[i];
            auto nodeResult = graphIndex.getNode(nodeId);
            
            terminal.write("      ");
            terminal.writeColored("→ ", Color.Red);
            terminal.write(nodeId);
            
            if (nodeResult.isOk)
            {
                auto node = nodeResult.unwrap();
                terminal.write("  ");
                terminal.writeColored("[" ~ node.targetType ~ "]", Color.BrightBlack);
            }
            terminal.writeln();
        }
        
        if (impacted.length > shown)
        {
            terminal.writeln();
            terminal.write("      ");
            terminal.writeColored(format("... and %d more", impacted.length - shown), Color.BrightBlack);
            terminal.writeln();
        }
    }
    
    /// Render bottlenecks view
    private void renderBottlenecksView() @system
    {
        terminal.writeColored("  ╔═══════════════════════════════════════════════════════════════╗\n", 
                             Color.Yellow);
        terminal.writeColored("  ║  ", Color.Yellow);
        terminal.writeColored("BOTTLENECK ANALYSIS", Color.Red, Style.Bold);
        terminal.writeColored(" ─ Nodes blocking parallelism              ║\n", Color.Yellow);
        terminal.writeColored("  ╚═══════════════════════════════════════════════════════════════╝\n\n", 
                             Color.Yellow);
        
        auto bottlenecks = graphQuery.findBottlenecks(15);
        
        if (bottlenecks.length == 0)
        {
            terminal.writeColored("    No bottlenecks detected\n", Color.Green);
            return;
        }
        
        // Header
        terminal.write("    ");
        terminal.writeColored("IMPACT", Color.BrightBlack);
        terminal.write("     ");
        terminal.writeColored("DEPS", Color.BrightBlack);
        terminal.write("      ");
        terminal.writeColored("TIME", Color.BrightBlack);
        terminal.write("        ");
        terminal.writeColored("TARGET", Color.BrightBlack);
        terminal.writeln();
        terminal.writeColored("    ─────────────────────────────────────────────────────────\n", 
                             Color.BrightBlack);
        
        foreach (i, b; bottlenecks)
        {
            auto isSelected = b.nodeId == state.selectedNode;
            
            // Impact bar
            auto maxImpact = bottlenecks[0].impact;
            auto barWidth = maxImpact > 0 ? cast(int)(b.impact * 8 / maxImpact) : 0;
            
            terminal.write("    ");
            if (isSelected)
            {
                terminal.write(ANSI.BG[Color.Blue]);
                terminal.write(ANSI.FG[Color.White]);
            }
            
            // Visual bar
            terminal.writeColored("█".replicate(barWidth), 
                                 barWidth > 6 ? Color.Red : (barWidth > 3 ? Color.Yellow : Color.Green));
            foreach (_; barWidth .. 8) terminal.write(" ");
            
            // Dependents count
            terminal.write(format("  %4d", b.dependentCount));
            
            // Build time
            terminal.write("    ");
            terminal.writeColored(format("%8s", formatDurationMs(b.buildDuration)), Color.Yellow);
            
            // Node name
            terminal.write("    ");
            terminal.write(truncate(b.nodeId, 35));
            
            terminal.write(ANSI.reset());
            terminal.writeln();
        }
    }
    
    /// Render search view
    private void renderSearchView() @system
    {
        terminal.writeColored("  ╔═══════════════════════════════════════════════════════════════╗\n", 
                             Color.Green);
        terminal.writeColored("  ║  ", Color.Green);
        terminal.writeColored("SEARCH", Color.Yellow, Style.Bold);
        terminal.writeColored("                                                         ║\n", Color.Green);
        terminal.writeColored("  ╚═══════════════════════════════════════════════════════════════╝\n\n", 
                             Color.Green);
        
        terminal.write("    ");
        terminal.writeColored("Query: ", Color.Cyan);
        terminal.write(state.searchQuery);
        terminal.writeColored("▌\n\n", Color.Cyan);
        
        if (state.searchResults.length > 0)
        {
            terminal.write("    ");
            terminal.writeColored(format("%d results:\n\n", state.searchResults.length), Color.BrightBlack);
            
            auto height = caps.height > 10 ? caps.height - 10 : 10;
            auto shown = min(height, state.searchResults.length);
            
            foreach (i; 0 .. shown)
            {
                auto nodeId = state.searchResults[i];
                auto isSelected = nodeId == state.selectedNode;
                
                terminal.write("      ");
                if (isSelected)
                {
                    terminal.write(ANSI.BG[Color.Blue]);
                    terminal.write(ANSI.FG[Color.White]);
                    terminal.write(" ▸ ");
                }
                else
                {
                    terminal.write("   ");
                }
                
                terminal.write(nodeId);
                terminal.write(ANSI.reset());
                terminal.writeln();
            }
        }
        else if (state.searchQuery.length > 0)
        {
            terminal.writeColored("    No results found\n", Color.BrightBlack);
        }
        else
        {
            terminal.writeColored("    Type to search...\n", Color.BrightBlack);
        }
    }
    
    /// Render node details view
    private void renderDetailsView() @system
    {
        if (state.selectedNode.length == 0)
        {
            terminal.writeColored("    No node selected\n", Color.BrightBlack);
            return;
        }
        
        auto nodeResult = graphIndex.getNode(state.selectedNode);
        if (nodeResult.isErr)
        {
            terminal.writeColored("    Node not found\n", Color.Red);
            return;
        }
        
        auto node = nodeResult.unwrap();
        auto deps = graphIndex.getDependencies(state.selectedNode);
        auto dependents = graphIndex.getDependents(state.selectedNode);
        
        // Header box
        terminal.writeColored("  ╔═══════════════════════════════════════════════════════════════╗\n", 
                             Color.Cyan);
        terminal.writeColored("  ║  ", Color.Cyan);
        terminal.writeColored(truncate(node.targetName, 55), Color.White, Style.Bold);
        auto padLen = 58 - min(55, node.targetName.length);
        foreach (_; 0 .. padLen) terminal.write(" ");
        terminal.writeColored("║\n", Color.Cyan);
        terminal.writeColored("  ╚═══════════════════════════════════════════════════════════════╝\n\n", 
                             Color.Cyan);
        
        // Properties
        renderDetailRow("Type", node.targetType);
        renderDetailRow("Status", statusString(node.status), statusColor(node.status));
        renderDetailRow("Depth", node.depth.to!string);
        renderDetailRow("Output", truncate(node.outputPath, 45));
        
        if (node.buildDuration > 0)
            renderDetailRow("Build Time", formatDurationMs(node.buildDuration));
        
        if (node.hash.length > 0)
            renderDetailRow("Hash", truncate(node.hash, 45));
        
        terminal.writeln();
        
        // Dependencies section
        terminal.writeColored("    ┌─ Dependencies (" ~ deps.length.to!string ~ ")\n", Color.Yellow);
        foreach (i, dep; deps)
        {
            if (i >= 5) 
            {
                terminal.writeColored("    │  ... and " ~ (deps.length - 5).to!string ~ " more\n", 
                                     Color.BrightBlack);
                break;
            }
            terminal.write("    │  ");
            terminal.writeColored("→ ", Color.Green);
            terminal.writeln(dep);
        }
        
        terminal.writeln();
        
        // Dependents section
        terminal.writeColored("    ┌─ Dependents (" ~ dependents.length.to!string ~ ")\n", Color.Magenta);
        foreach (i, dep; dependents)
        {
            if (i >= 5)
            {
                terminal.writeColored("    │  ... and " ~ (dependents.length - 5).to!string ~ " more\n", 
                                     Color.BrightBlack);
                break;
            }
            terminal.write("    │  ");
            terminal.writeColored("← ", Color.Red);
            terminal.writeln(dep);
        }
    }
    
    /// Render a detail row
    private void renderDetailRow(string label, string value, Color valueColor = Color.White) @system
    {
        terminal.write("    ");
        terminal.writeColored(format("%-12s", label ~ ":"), Color.BrightBlack);
        terminal.writeColored(value, valueColor);
        terminal.writeln();
    }
    
    /// Render help overlay
    private void renderHelpOverlay() @system
    {
        auto width = caps.width > 60 ? 56 : caps.width - 4;
        auto startCol = (caps.width - width) / 2;
        auto startRow = 5;
        
        // Draw overlay background
        terminal.write(ANSI.cursorTo(cast(ushort)startRow, cast(ushort)startCol));
        terminal.write(ANSI.BG[Color.Black]);
        terminal.writeColored("╔════════════════════════════════════════════════════════╗\n", Color.Cyan);
        
        void overlayLine(string text)
        {
            terminal.write(ANSI.cursorForward(cast(ushort)(startCol - 1)));
            terminal.write(ANSI.BG[Color.Black]);
            terminal.writeColored("║ ", Color.Cyan);
            terminal.write(text);
            auto pad = width - 3 - text.length;
            foreach (_; 0 .. pad) terminal.write(" ");
            terminal.writeColored("║\n", Color.Cyan);
        }
        
        overlayLine("  KEYBOARD SHORTCUTS");
        overlayLine("  ══════════════════════════════════════════════════");
        overlayLine("");
        overlayLine("  Navigation:");
        overlayLine("    ↑/k, ↓/j      Move selection up/down");
        overlayLine("    ←/h, →/l      Collapse/expand node");
        overlayLine("    Enter         Select / toggle expand");
        overlayLine("    g             Jump to top");
        overlayLine("    G             Jump to bottom");
        overlayLine("");
        overlayLine("  Views:");
        overlayLine("    1             Tree view");
        overlayLine("    2             Critical path");
        overlayLine("    3             Impact analysis");
        overlayLine("    4             Bottlenecks");
        overlayLine("    d             Node details");
        overlayLine("    /             Search");
        overlayLine("");
        overlayLine("  Actions:");
        overlayLine("    r             Refresh graph");
        overlayLine("    ?             Toggle this help");
        overlayLine("    q, Esc        Quit");
        overlayLine("");
        
        terminal.write(ANSI.cursorForward(cast(ushort)(startCol - 1)));
        terminal.write(ANSI.BG[Color.Black]);
        terminal.writeColored("╚════════════════════════════════════════════════════════╝", Color.Cyan);
        terminal.write(ANSI.reset());
    }
    
    /// Render footer with key hints
    private void renderFooter() @system
    {
        auto width = caps.width > 0 ? caps.width : 80;
        
        // Position at bottom
        terminal.write(ANSI.cursorTo(cast(ushort)(caps.height - 1), 1));
        
        terminal.write(ANSI.BG[Color.BrightBlack]);
        terminal.write(ANSI.FG[Color.White]);
        
        auto hints = " [1]Tree [2]Critical [3]Impact [4]Bottleneck [/]Search [d]Details [?]Help [q]Quit ";
        terminal.write(hints);
        
        auto pad = width - hints.length;
        foreach (_; 0 .. pad)
            terminal.write(" ");
        
        terminal.write(ANSI.reset());
    }
    
    /// Handle input and return true if redraw needed
    private bool handleInput() @system
    {
        char[6] buf;
        auto bytesRead = readInput(buf);
        
        if (bytesRead <= 0) return false;
        
        // Handle escape sequences
        if (bytesRead >= 3 && buf[0] == '\x1b' && buf[1] == '[')
        {
            switch (buf[2])
            {
                case 'A': return moveUp();      // Up arrow
                case 'B': return moveDown();    // Down arrow
                case 'C': return expandNode();  // Right arrow
                case 'D': return collapseNode();// Left arrow
                default: break;
            }
        }
        else if (bytesRead == 1)
        {
            switch (buf[0])
            {
                case 'q': case '\x1b': running = false; return false;
                case 'k': return moveUp();
                case 'j': return moveDown();
                case 'h': return collapseNode();
                case 'l': return expandNode();
                case '\n': case '\r': return toggleExpand();
                case '1': state.currentView = ExplorerView.Tree; return true;
                case '2': state.currentView = ExplorerView.CriticalPath; return true;
                case '3': state.currentView = ExplorerView.Impact; return true;
                case '4': state.currentView = ExplorerView.Bottlenecks; return true;
                case 'd': state.currentView = ExplorerView.Details; return true;
                case '/': state.currentView = ExplorerView.Search; return true;
                case '?': state.showHelp = !state.showHelp; return true;
                case 'g': return jumpToTop();
                case 'G': return jumpToBottom();
                case 'r': return refreshGraph();
                default: 
                    if (state.currentView == ExplorerView.Search)
                        return handleSearchInput(buf[0]);
                    break;
            }
        }
        
        return false;
    }
    
    // Navigation helpers
    private bool moveUp() @system
    {
        auto nodes = getVisibleNodes();
        if (nodes.length == 0) return false;
        
        auto idx = nodes.countUntil(state.selectedNode);
        if (idx > 0)
        {
            state.selectedNode = nodes[idx - 1];
            if (state.scrollOffset > 0 && idx <= state.scrollOffset)
                state.scrollOffset--;
        }
        return true;
    }
    
    private bool moveDown() @system
    {
        auto nodes = getVisibleNodes();
        if (nodes.length == 0) return false;
        
        auto idx = nodes.countUntil(state.selectedNode);
        if (idx < nodes.length - 1)
        {
            state.selectedNode = nodes[idx + 1];
            auto visibleHeight = caps.height > 8 ? caps.height - 8 : 12;
            if (idx >= state.scrollOffset + visibleHeight - 1)
                state.scrollOffset++;
        }
        return true;
    }
    
    private bool expandNode() @system
    {
        if (!state.isExpanded(state.selectedNode))
        {
            state.expandedNodes ~= state.selectedNode;
            return true;
        }
        return false;
    }
    
    private bool collapseNode() @system
    {
        if (state.isExpanded(state.selectedNode))
        {
            state.expandedNodes = state.expandedNodes.filter!(n => n != state.selectedNode).array;
            return true;
        }
        return false;
    }
    
    private bool toggleExpand() @system
    {
        state.toggleExpanded(state.selectedNode);
        return true;
    }
    
    private bool jumpToTop() @system
    {
        auto nodes = getVisibleNodes();
        if (nodes.length > 0)
        {
            state.selectedNode = nodes[0];
            state.scrollOffset = 0;
        }
        return true;
    }
    
    private bool jumpToBottom() @system
    {
        auto nodes = getVisibleNodes();
        if (nodes.length > 0)
        {
            state.selectedNode = nodes[$ - 1];
            auto visibleHeight = caps.height > 8 ? caps.height - 8 : 12;
            state.scrollOffset = nodes.length > visibleHeight ? nodes.length - visibleHeight : 0;
        }
        return true;
    }
    
    private bool refreshGraph() @system
    {
        // Graph index will re-read from SQLite on next query
        return true;
    }
    
    private bool handleSearchInput(char c) @system
    {
        if (c == '\x7f' || c == '\b') // Backspace
        {
            if (state.searchQuery.length > 0)
                state.searchQuery = state.searchQuery[0 .. $ - 1];
        }
        else if (c >= 32 && c < 127) // Printable
        {
            state.searchQuery ~= c;
        }
        
        // Update search results
        if (state.searchQuery.length > 0)
        {
            auto query = state.searchQuery.toLower;
            state.searchResults = graphIndex.listNodes()
                .filter!(n => n.toLower.canFind(query))
                .array;
            
            if (state.searchResults.length > 0)
                state.selectedNode = state.searchResults[0];
        }
        else
        {
            state.searchResults = [];
        }
        
        return true;
    }
    
    /// Get list of currently visible nodes based on expansion state
    private string[] getVisibleNodes() @system
    {
        string[] nodes;
        
        void addNode(string nodeId, int depth)
        {
            nodes ~= nodeId;
            if (state.isExpanded(nodeId))
            {
                foreach (dep; graphIndex.getDependencies(nodeId))
                    addNode(dep, depth + 1);
            }
        }
        
        foreach (root; graphIndex.getRoots())
            addNode(root, 0);
        
        return nodes;
    }
    
    // Terminal mode helpers
    private void enableRawMode() @system
    {
        version(Posix)
        {
            import core.sys.posix.termios;
            import core.sys.posix.unistd : STDIN_FILENO;
            
            tcgetattr(STDIN_FILENO, &originalTermios);
            
            termios raw = originalTermios;
            raw.c_lflag &= ~(ICANON | ECHO | ISIG);
            raw.c_cc[VMIN] = 0;
            raw.c_cc[VTIME] = 1;
            
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
        }
    }
    
    private void disableRawMode() @system
    {
        version(Posix)
        {
            import core.sys.posix.termios;
            import core.sys.posix.unistd : STDIN_FILENO;
            
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios);
        }
    }
    
    private ptrdiff_t readInput(char[] buf) @system
    {
        version(Posix)
        {
            import core.sys.posix.unistd : read;
            return read(0, buf.ptr, buf.length);
        }
        else
        {
            return 0;
        }
    }
}

// Helper functions
private string viewNameString(ExplorerView view) pure @safe
{
    final switch (view)
    {
        case ExplorerView.Tree: return "Tree View";
        case ExplorerView.CriticalPath: return "Critical Path";
        case ExplorerView.Impact: return "Impact Analysis";
        case ExplorerView.Bottlenecks: return "Bottlenecks";
        case ExplorerView.Search: return "Search";
        case ExplorerView.Details: return "Details";
    }
}

private string statusIcon(BuildStatus status) @system
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

private string statusString(BuildStatus status) pure @safe
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

private string formatDurationMs(long ms) pure @safe
{
    if (ms < 1000) return format("%dms", ms);
    if (ms < 60_000) return format("%.1fs", ms / 1000.0);
    return format("%dm%ds", ms / 60_000, (ms % 60_000) / 1000);
}

private string truncate(string s, size_t maxLen) pure @safe
{
    return s.length <= maxLen ? s : s[0 .. maxLen - 3] ~ "...";
}

private string replicate(string s, size_t n) pure @safe
{
    if (n == 0) return "";
    char[] result = new char[s.length * n];
    foreach (i; 0 .. n)
        result[i * s.length .. (i + 1) * s.length] = s;
    return result.idup;
}

private ptrdiff_t countUntil(T)(T[] arr, T needle)
{
    foreach (i, e; arr)
        if (e == needle) return i;
    return -1;
}

// Import termios for raw mode
version(Posix)
{
    import core.sys.posix.termios;
}
else
{
    struct termios { }
}

