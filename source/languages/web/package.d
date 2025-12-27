module languages.web;

/// Web Languages Package
/// 
/// Unified support for web development languages:
///   - JavaScript (Node.js, bundling, npm/yarn/pnpm/bun)
///   - TypeScript (type-first, multiple compilers, declarations)
///   - CSS (SCSS, PostCSS, Tailwind, minification)
///   - Elm (functional, compiles to JavaScript)
///
/// Common infrastructure:
///   - Package managers (npm, yarn, pnpm, bun)
///   - Module resolution
///   - Build orchestration
///   - Framework detection

public import languages.web.base;
public import languages.web.javascript;
public import languages.web.typescript;
public import languages.web.css;
public import languages.web.elm;
public import languages.web.shared_;
