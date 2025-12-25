module frontend.cli.explorer;

/// Interactive Dependency Explorer TUI
/// 
/// A terminal user interface for exploring build graphs, visualizing the critical 
/// path, and understanding why targets rebuild.
/// 
/// ## Features
/// - Tree view navigation with vim-style keybindings
/// - Critical path visualization with timing analysis  
/// - Impact analysis (what rebuilds if X changes)
/// - Rebuild reason explanations
/// - Status visualization (pending, building, success, failed, cached)
/// - Search/filter capabilities
/// - Bottleneck detection
/// 
/// ## Usage
/// ```
/// bldr explore              # Launch interactive explorer
/// bldr explore //target     # Focus on specific target
/// bldr explore --critical   # Start with critical path view
/// ```

public import frontend.cli.explorer.tui;
public import frontend.cli.explorer.views;
public import frontend.cli.explorer.renderer;

