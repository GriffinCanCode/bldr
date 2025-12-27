module frontend.cli.control.terminal;

import std.stdio : stdout, stderr;
import std.string : format;
import std.process : environment;
import std.algorithm : canFind;
import std.conv : to;
import infrastructure.utils.logging : Logger, structuredLog;

/// Terminal capabilities and control
/// Provides low-level ANSI escape sequence management and capability detection

/// ANSI color codes (optimized for common terminals)
enum Color : ubyte
{
    Black = 0,
    Red = 1,
    Green = 2,
    Yellow = 3,
    Blue = 4,
    Magenta = 5,
    Cyan = 6,
    White = 7,
    BrightBlack = 8,
    BrightRed = 9,
    BrightGreen = 10,
    BrightYellow = 11,
    BrightBlue = 12,
    BrightMagenta = 13,
    BrightCyan = 14,
    BrightWhite = 15
}

/// ANSI text styles
enum Style : ubyte
{
    None = 0,
    Bold = 1,
    Dim = 2,
    Italic = 3,
    Underline = 4,
    Blink = 5,
    Reverse = 7,
    Hidden = 8,
    Strikethrough = 9
}

/// Terminal capabilities (detected at runtime)
struct Capabilities
{
    /// Default terminal dimensions
    private enum ushort DEFAULT_WIDTH = 80;   // Standard terminal width
    private enum ushort DEFAULT_HEIGHT = 24;  // Standard terminal height
    
    bool supportsColor;
    bool supportsUnicode;
    bool supports256Color;
    bool supportsTrueColor;
    bool supportsProgressBar;
    ushort width;
    ushort height;
    bool isInteractive;
    
    /// Detect terminal capabilities from environment
    static Capabilities detect()
    {
        Capabilities caps;
        
        // Check if we're in a TTY
        version(Posix)
        {
            import core.sys.posix.unistd : isatty, STDOUT_FILENO;
            caps.isInteractive = isatty(STDOUT_FILENO) != 0;
        }
        else
        {
            caps.isInteractive = true; // Assume interactive on Windows
        }
        
        // Check TERM environment variable
        auto term = environment.get("TERM", "");
        auto colorTerm = environment.get("COLORTERM", "");
        
        // Color support detection
        caps.supportsColor = caps.isInteractive && (
            term.canFind("color") ||
            term.canFind("xterm") ||
            term.canFind("screen") ||
            term.canFind("tmux") ||
            colorTerm.length > 0
        );
        
        // 256 color support
        caps.supports256Color = 
            term.canFind("256color") ||
            term.canFind("kitty") ||
            term.canFind("alacritty");
        
        // True color (24-bit) support
        caps.supportsTrueColor = 
            colorTerm == "truecolor" ||
            colorTerm == "24bit" ||
            term.canFind("kitty") ||
            term.canFind("alacritty");
        
        // Unicode support
        auto lang = environment.get("LANG", "");
        caps.supportsUnicode = 
            lang.canFind("UTF-8") ||
            lang.canFind("utf8") ||
            caps.isInteractive;
        
        // Progress bar support (requires interactive terminal)
        caps.supportsProgressBar = caps.isInteractive && caps.supportsColor;
        
        // Terminal size detection
        caps.width = detectWidth();
        caps.height = detectHeight();
        
        return caps;
    }
    
    /// Detect terminal width using ioctl or environment variable
    /// 
    /// Safety: This function is @system because:
    /// 1. ioctl() is system call (inherently @system)
    /// 2. Takes pointer to stack-allocated winsize struct (safe)
    /// 3. TIOCGWINSZ is read-only query (no side effects)
    /// 4. winsize struct is properly initialized before ioctl call
    /// 5. Fallback to environment variable is safe
    /// 
    /// Invariants:
    /// - winsize struct is stack-allocated (automatic cleanup)
    /// - ioctl return value is checked before accessing ws.ws_col
    /// - Environment variable parsing is exception-safe
    /// - Returns sensible default (80) if detection fails
    /// 
    /// What could go wrong:
    /// - ioctl fails: returns -1, we use fallback (safe)
    /// - Not a terminal: ioctl fails, we use fallback
    /// - Invalid COLUMNS env var: caught by exception, uses default
    private static ushort detectWidth() @system
    {
        version(Posix)
        {
            import core.sys.posix.sys.ioctl : ioctl, TIOCGWINSZ, winsize;
            import core.sys.posix.unistd : STDOUT_FILENO;
            
            winsize ws;
            if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0)
                return ws.ws_col;
        }
        
        // Fallback to COLUMNS env var or default
        auto cols = environment.get("COLUMNS", "");
        if (cols.length > 0)
        {
            try { return cols.to!ushort; }
            catch (Exception e)
            {
                // Invalid number format - will use default below
                import infrastructure.utils.logging.logger : Logger;
                structuredLog.debug_("invalid_columns_environment_variable_").field("detail", "Invalid COLUMNS environment variable: " ~ e.msg).emit();
            }
        }
        
        return DEFAULT_WIDTH;
    }
    
    /// Detect terminal height using ioctl or environment variable
    /// 
    /// Safety: This function is @system because:
    /// 1. ioctl() is system call (inherently @system)
    /// 2. Takes pointer to stack-allocated winsize struct (safe)
    /// 3. TIOCGWINSZ is read-only query (no side effects)
    /// 4. winsize struct is properly initialized before ioctl call
    /// 5. Fallback to environment variable is safe
    /// 
    /// Invariants:
    /// - winsize struct is stack-allocated (automatic cleanup)
    /// - ioctl return value is checked before accessing ws.ws_row
    /// - Environment variable parsing is exception-safe
    /// - Returns sensible default (24) if detection fails
    /// 
    /// What could go wrong:
    /// - ioctl fails: returns -1, we use fallback (safe)
    /// - Not a terminal: ioctl fails, we use fallback
    /// - Invalid LINES env var: caught by exception, uses default
    private static ushort detectHeight() @system
    {
        version(Posix)
        {
            import core.sys.posix.sys.ioctl : ioctl, TIOCGWINSZ, winsize;
            import core.sys.posix.unistd : STDOUT_FILENO;
            
            winsize ws;
            if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0)
                return ws.ws_row;
        }
        
        // Fallback to LINES env var or default
        auto lines = environment.get("LINES", "");
        if (lines.length > 0)
        {
            try { return lines.to!ushort; }
            catch (Exception e)
            {
                // Invalid number format - will use default below
                import infrastructure.utils.logging.logger : Logger;
                structuredLog.debug_("invalid_lines_environment_variable_").field("detail", "Invalid LINES environment variable: " ~ e.msg).emit();
            }
        }
        
        return DEFAULT_HEIGHT;
    }
}

/// ANSI escape sequence builder (zero-allocation after initialization)
struct ANSI
{
    private static immutable string ESC = "\x1b[";
    private static immutable string RESET = "\x1b[0m";
    
    /// Color codes (precomputed for performance)
    static immutable string[16] FG = [
        "\x1b[30m", "\x1b[31m", "\x1b[32m", "\x1b[33m",
        "\x1b[34m", "\x1b[35m", "\x1b[36m", "\x1b[37m",
        "\x1b[90m", "\x1b[91m", "\x1b[92m", "\x1b[93m",
        "\x1b[94m", "\x1b[95m", "\x1b[96m", "\x1b[97m"
    ];
    
    static immutable string[16] BG = [
        "\x1b[40m", "\x1b[41m", "\x1b[42m", "\x1b[43m",
        "\x1b[44m", "\x1b[45m", "\x1b[46m", "\x1b[47m",
        "\x1b[100m", "\x1b[101m", "\x1b[102m", "\x1b[103m",
        "\x1b[104m", "\x1b[105m", "\x1b[106m", "\x1b[107m"
    ];
    
    /// Style codes
    static immutable string BOLD = "\x1b[1m";
    static immutable string DIM = "\x1b[2m";
    static immutable string ITALIC = "\x1b[3m";
    static immutable string UNDERLINE = "\x1b[4m";
    
    /// Cursor control
    static string cursorUp(ushort n = 1) { return format("%s%dA", ESC, n); }
    static string cursorDown(ushort n = 1) { return format("%s%dB", ESC, n); }
    static string cursorForward(ushort n = 1) { return format("%s%dC", ESC, n); }
    static string cursorBack(ushort n = 1) { return format("%s%dD", ESC, n); }
    static string cursorTo(ushort row, ushort col) { return format("%s%d;%dH", ESC, row, col); }
    static string cursorSave() { return ESC ~ "s"; }
    static string cursorRestore() { return ESC ~ "u"; }
    static string cursorHide() { return ESC ~ "?25l"; }
    static string cursorShow() { return ESC ~ "?25h"; }
    
    /// Line control
    static string clearLine() { return ESC ~ "2K"; }
    static string clearToEOL() { return ESC ~ "K"; }
    static string clearScreen() { return ESC ~ "2J"; }
    static string clearToBottom() { return ESC ~ "J"; }
    
    /// Get reset sequence
    static string reset() @system { return RESET; }
}

/// Terminal writer with buffering for performance
struct Terminal
{
    /// Buffer configuration
    private enum size_t DEFAULT_BUFFER_SIZE = 4_096;  // 4 KB default buffer
    
    private Capabilities caps;
    private char[] buffer;
    private size_t bufferPos;
    
    this(Capabilities caps, size_t bufferSize = DEFAULT_BUFFER_SIZE)
    {
        this.caps = caps;
        this.buffer = new char[bufferSize];
        this.bufferPos = 0;
    }
    
    /// Get terminal capabilities
    @property Capabilities capabilities() const pure nothrow
    {
        return caps;
    }
    
    /// Write colored text
    void writeColored(string text, Color fg, Style style = Style.None)
    {
        if (!caps.supportsColor)
        {
            write(text);
            return;
        }
        
        // Apply style
        if (style == Style.Bold)
            write(ANSI.BOLD);
        else if (style == Style.Dim)
            write(ANSI.DIM);
        
        // Apply color
        write(ANSI.FG[fg]);
        write(text);
        write(ANSI.reset());
    }
    
    /// Write with background color
    void writeWithBg(string text, Color fg, Color bg)
    {
        if (!caps.supportsColor)
        {
            write(text);
            return;
        }
        
        write(ANSI.FG[fg]);
        write(ANSI.BG[bg]);
        write(text);
        write(ANSI.reset());
    }
    
    /// Write raw text to buffer
    void write(string text)
    {
        foreach (c; text)
        {
            if (bufferPos >= buffer.length)
                flush();
            buffer[bufferPos++] = c;
        }
    }
    
    /// Write line
    void writeln(string text = "")
    {
        write(text);
        write("\n");
    }
    
    /// Flush buffer to stdout
    void flush()
    {
        if (bufferPos > 0)
        {
            stdout.write(buffer[0 .. bufferPos]);
            stdout.flush();
            bufferPos = 0;
        }
    }
    
    /// Get capabilities
    ref const(Capabilities) getCapabilities() const
    {
        return caps;
    }
}

/// Unicode symbols for status display
struct Symbols
{
    string checkmark;
    string cross;
    string arrow;
    string bullet;
    string ellipsis;
    string cached;
    string building;
    
    static Symbols unicode()
    {
        return Symbols(
            "✓",  // checkmark
            "✗",  // cross
            "→",  // arrow
            "•",  // bullet
            "…",  // ellipsis
            "⚡", // cached
            "⚙"   // building
        );
    }
    
    static Symbols ascii()
    {
        return Symbols(
            "[OK]",    // checkmark
            "[FAIL]",  // cross
            "->",      // arrow
            "*",       // bullet
            "...",     // ellipsis
            "[cache]", // cached
            "[build]"  // building
        );
    }
    
    static Symbols detect(Capabilities caps)
    {
        return caps.supportsUnicode ? unicode() : ascii();
    }
}

