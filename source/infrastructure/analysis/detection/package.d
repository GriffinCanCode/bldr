module infrastructure.analysis.detection;

/// Project detection and template generation for `bldr init`
/// 
/// This package provides intelligent project detection capabilities
/// that scan directories to identify languages, frameworks, and project
/// structure. It generates appropriate Builderfile and Builderspace
/// configurations based on detected patterns.
/// 
/// Architecture:
///   detector.d   - Core detection engine
///   templates.d  - Template generation for config files
///   inference.d  - Zero-config target inference
///   enhanced.d   - Enhanced detection with manifest parsing
///   generator.d  - Enhanced template generation with manifest data

public import infrastructure.analysis.detection.detector;
public import infrastructure.analysis.detection.templates;
public import infrastructure.analysis.detection.inference;
public import infrastructure.analysis.detection.enhanced;
public import infrastructure.analysis.detection.generator;

