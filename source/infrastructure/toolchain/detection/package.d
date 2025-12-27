module infrastructure.toolchain.detection;

/// Toolchain Detection System
/// 
/// This module provides automatic detection of installed toolchains
/// on the host system. It includes base detector infrastructure and
/// specialized detectors for various languages and build systems.
/// 
/// ## Modules
/// 
/// - `detector` - Base detector interface and common detectors (GCC, Clang, Rust)
/// - `language_detectors` - Additional language-specific detectors (Go, Python, Node, Java, Zig, D, CMake)
/// 
/// ## Usage
/// 
/// ```d
/// auto detector = new AutoDetector();
/// auto toolchains = detector.detectAll();
/// 
/// foreach (tc; toolchains)
/// {
///     writeln("Found: ", tc.id);
/// }
/// ```

public import infrastructure.toolchain.detection.detector;
public import infrastructure.toolchain.detection.language_detectors;
public import infrastructure.toolchain.detection.gpu_detectors;

