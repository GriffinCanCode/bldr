/*
 * Tree-sitter Grammar Loader & Stub
 *
 * Unified implementation supporting:
 * 1. Static linking (via weak symbols) - Zero overhead, optimized
 * 2. Dynamic loading (via dlopen) - Flexible system integration
 *
 * Designed for elegance, performance, and extensibility.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Dynamic loader helper
static void *load_dynamic(const char *lang, const char *symbol) {
    char path[256];
    void *handle = NULL;
    void *func = NULL;

    const char *paths[] = {
#ifdef __APPLE__
        "/opt/homebrew/lib/libtree-sitter-%s.dylib",
        "/usr/local/lib/libtree-sitter-%s.dylib",
        "libtree-sitter-%s.dylib",
#else
        "/usr/lib/libtree-sitter-%s.so",
        "/usr/local/lib/libtree-sitter-%s.so",
        "libtree-sitter-%s.so",
#endif
        NULL
    };

    for (int i = 0; paths[i]; i++) {
        snprintf(path, sizeof(path), paths[i], lang);
        handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            func = dlsym(handle, symbol);
            if (func) return ((void *(*)(void))func)();
            dlclose(handle);
        }
    }
    return NULL;
}

// Platform-specific constants
#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *) -2)
#endif

// Macro for standard grammars
// Uses dlsym for both static (global) and dynamic lookup to avoid linker dependency
#define DEFINE_LOADER(lang) \
    void *ts_load_##lang(void) { \
        static void *cached = NULL; \
        if (cached) return cached; \
        /* Try global symbol first (statically linked) */ \
        void *func = dlsym(RTLD_DEFAULT, "tree_sitter_" #lang); \
        if (func) { \
            cached = ((void *(*)(void))func)(); \
            return cached; \
        } \
        /* Try dynamic loading */ \
        cached = load_dynamic(#lang, "tree_sitter_" #lang); \
        return cached; \
    }

// Macro for grammars with non-standard symbol names
#define DEFINE_LOADER_NAMED(lang, name) \
    void *ts_load_##lang(void) { \
        static void *cached = NULL; \
        if (cached) return cached; \
        /* Try global symbol first (statically linked) */ \
        void *func = dlsym(RTLD_DEFAULT, "tree_sitter_" #name); \
        if (func) { \
            cached = ((void *(*)(void))func)(); \
            return cached; \
        } \
        /* Try dynamic loading */ \
        cached = load_dynamic(#lang, "tree_sitter_" #name); \
        return cached; \
    }

// Language Definitions
DEFINE_LOADER(c)
DEFINE_LOADER(cpp)
DEFINE_LOADER(python)
DEFINE_LOADER(java)
DEFINE_LOADER(javascript)
DEFINE_LOADER(typescript)
DEFINE_LOADER(go)
DEFINE_LOADER(rust)
DEFINE_LOADER_NAMED(csharp, c_sharp)
DEFINE_LOADER(ruby)
DEFINE_LOADER(php)
DEFINE_LOADER(swift)
DEFINE_LOADER(kotlin)
DEFINE_LOADER(scala)
DEFINE_LOADER(elixir)
DEFINE_LOADER(lua)
DEFINE_LOADER(perl)
DEFINE_LOADER(r)
DEFINE_LOADER(haskell)
DEFINE_LOADER(ocaml)
DEFINE_LOADER(nim)
DEFINE_LOADER(zig)
DEFINE_LOADER(d)
DEFINE_LOADER(elm)
DEFINE_LOADER_NAMED(fsharp, f_sharp)
DEFINE_LOADER(css)
DEFINE_LOADER(protobuf)
