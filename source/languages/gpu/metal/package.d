module languages.gpu.metal;

/// Apple Metal Language Support
/// 
/// Provides compilation support for Apple Metal GPU shaders.
/// 
/// Features:
///   - metal compiler integration
///   - metallib generation
///   - iOS/macOS/tvOS target support
///   - Dependency tracking
///
/// Usage in Builderfile:
///   target("metal_shaders") {
///       type: library;
///       language: metal;
///       sources: ["shaders/*.metal"];
///       metal: {
///           platform: "macos";
///           version: "3.0";
///       }
///   }

public import languages.gpu.metal.core;
