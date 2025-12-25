module engine.caching.modules;

/// Module Interface Caching
///
/// Provides caching for compiled module interfaces, primarily targeting
/// C++20 Binary Module Interface (BMI) files.
///
/// ## Supported Formats
/// - GCC: .gcm files
/// - Clang: .pcm files  
/// - MSVC: .ifc files
///
/// ## Invalidation Strategy
/// BMI cache entries are invalidated when:
/// 1. Compiler version changes
/// 2. Relevant compiler flags change (optimization, standard, defines)
/// 3. Module interface source content changes
/// 4. Any dependent module's BMI changes (transitive)
///
/// ## Usage
/// ```d
/// import engine.caching.modules;
///
/// auto bmiCache = new BMICache(".builder-cache/bmi");
///
/// // Create key for module
/// auto key = createBMIKey(
///     "mymodule.core",
///     "src/mymodule.cppm",
///     "/usr/bin/clang++",
///     "17.0.0",
///     ["-std=c++20", "-O2"]
/// );
///
/// if (bmiCache.isCached(key))
/// {
///     auto bmiPath = bmiCache.getBMIPath(key).unwrap();
///     // Use cached BMI
/// }
/// else
/// {
///     // Compile module, then cache
///     bmiCache.store(key, compiledBmiPath, sourcePath, deps);
/// }
/// ```

public import engine.caching.modules.bmi;

