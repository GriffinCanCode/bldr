module infrastructure.parsing.treesitter.bindings;

/// Tree-sitter C API bindings
/// Minimal surface area - only what we need for AST extraction
/// See: https://tree-sitter.github.io/tree-sitter/using-parsers

// Core opaque types
extern(C) struct TSParser;
extern(C) struct TSTree;
extern(C) struct TSLanguage;

// Node represents a syntax tree node
extern(C) struct TSNode {
    uint[4] context;
    const(void)* id;
    const(TSTree)* tree;
}

// Point represents a position in a document
extern(C) struct TSPoint {
    uint row;
    uint column;
}

// Range of text in source
extern(C) struct TSRange {
    TSPoint start_point;
    TSPoint end_point;
    uint start_byte;
    uint end_byte;
}

// Input for incremental parsing
extern(C) struct TSInput {
    void* payload;
    extern(C) const(char)* function(void* payload, uint byte_offset, TSPoint position, uint* bytes_read) read;
    TSInputEncoding encoding;
}

// Symbol represents a node type
alias TSSymbol = ushort;
alias TSFieldId = ushort;

enum TSInputEncoding : int {
    TSInputEncodingUTF8,
    TSInputEncodingUTF16
}

enum TSSymbolType : int {
    TSSymbolTypeRegular,
    TSSymbolTypeAnonymous,
    TSSymbolTypeAuxiliary
}

// C API functions
extern(C) @system nothrow @nogc:

// Parser lifecycle
TSParser* ts_parser_new();
void ts_parser_delete(TSParser* parser);
bool ts_parser_set_language(TSParser* parser, const(TSLanguage)* language);
const(TSLanguage)* ts_parser_language(const(TSParser)* parser);

// Parsing
TSTree* ts_parser_parse(TSParser* parser, const(TSTree)* old_tree, TSInput input);
TSTree* ts_parser_parse_string(TSParser* parser, const(TSTree)* old_tree, 
                                const(char)* string_, uint length);

// Tree lifecycle
TSTree* ts_tree_copy(const(TSTree)* tree);
void ts_tree_delete(TSTree* tree);
TSNode ts_tree_root_node(const(TSTree)* tree);

// Editing for incremental parsing
extern(C) struct TSInputEdit {
    uint start_byte;
    uint old_end_byte;
    uint new_end_byte;
    TSPoint start_point;
    TSPoint old_end_point;
    TSPoint new_end_point;
}

void ts_tree_edit(TSTree* tree, const(TSInputEdit)* edit);

// Node operations
TSSymbol ts_node_symbol(TSNode node);
const(char)* ts_node_type(TSNode node);
const(char)* ts_node_string(TSNode node);
bool ts_node_is_null(TSNode node);
bool ts_node_is_named(TSNode node);
bool ts_node_is_missing(TSNode node);
bool ts_node_is_extra(TSNode node);
bool ts_node_has_error(TSNode node);

uint ts_node_start_byte(TSNode node);
uint ts_node_end_byte(TSNode node);
TSPoint ts_node_start_point(TSNode node);
TSPoint ts_node_end_point(TSNode node);

uint ts_node_child_count(TSNode node);
TSNode ts_node_child(TSNode node, uint index);
TSNode ts_node_named_child(TSNode node, uint index);
uint ts_node_named_child_count(TSNode node);
TSNode ts_node_child_by_field_id(TSNode node, TSFieldId field_id);
TSNode ts_node_child_by_field_name(TSNode node, const(char)* name, uint name_length);

TSNode ts_node_next_sibling(TSNode node);
TSNode ts_node_prev_sibling(TSNode node);
TSNode ts_node_next_named_sibling(TSNode node);
TSNode ts_node_prev_named_sibling(TSNode node);
TSNode ts_node_parent(TSNode node);

// Language info
uint ts_language_symbol_count(const(TSLanguage)* language);
const(char)* ts_language_symbol_name(const(TSLanguage)* language, TSSymbol symbol);
TSSymbol ts_language_symbol_for_name(const(TSLanguage)* language, const(char)* name, 
                                      uint length, bool is_named);
TSSymbolType ts_language_symbol_type(const(TSLanguage)* language, TSSymbol symbol);
uint ts_language_version(const(TSLanguage)* language);
TSFieldId ts_language_field_id_for_name(const(TSLanguage)* language, const(char)* name, uint length);
const(char)* ts_language_field_name_for_id(const(TSLanguage)* language, TSFieldId id);

// Cursor for tree traversal (more efficient than recursive)
extern(C) struct TSTreeCursor {
    const(void)* tree;
    const(void)* id;
    uint[2] context;
}

TSTreeCursor ts_tree_cursor_new(TSNode node);
void ts_tree_cursor_delete(TSTreeCursor* cursor);
void ts_tree_cursor_reset(TSTreeCursor* cursor, TSNode node);
TSNode ts_tree_cursor_current_node(const(TSTreeCursor)* cursor);
const(char)* ts_tree_cursor_current_field_name(const(TSTreeCursor)* cursor);
TSFieldId ts_tree_cursor_current_field_id(const(TSTreeCursor)* cursor);
bool ts_tree_cursor_goto_parent(TSTreeCursor* cursor);
bool ts_tree_cursor_goto_next_sibling(TSTreeCursor* cursor);
bool ts_tree_cursor_goto_first_child(TSTreeCursor* cursor);
long ts_tree_cursor_goto_first_child_for_byte(TSTreeCursor* cursor, uint byte_offset);

// Query system (for pattern matching - optional, can add later if needed)
extern(C) struct TSQuery;
extern(C) struct TSQueryCursor;

// D-friendly RAII wrappers
struct Parser {
    private TSParser* ptr;
    
    @disable this(this);
    
    this(const(TSLanguage)* language) @system nothrow {
        ptr = ts_parser_new();
        if (ptr && language)
            ts_parser_set_language(ptr, language);
    }
    
    ~this() @system nothrow @nogc {
        if (ptr)
            ts_parser_delete(ptr);
    }
    
    TSParser* handle() @system nothrow @nogc { return ptr; }
}

struct Tree {
    private TSTree* ptr;
    
    @disable this(this);
    
    this(TSTree* tree) @system nothrow @nogc {
        ptr = tree;
    }
    
    ~this() @system nothrow @nogc {
        if (ptr)
            ts_tree_delete(ptr);
    }
    
    TSNode root() @system nothrow @nogc {
        return ptr ? ts_tree_root_node(ptr) : TSNode.init;
    }
    
    TSTree* handle() @system nothrow @nogc { return ptr; }
    TSTree* release() @system nothrow @nogc {
        auto temp = ptr;
        ptr = null;
        return temp;
    }
    
    /// Apply edit for incremental parsing
    void edit(ref const TSInputEdit inputEdit) @system nothrow @nogc {
        if (ptr) ts_tree_edit(ptr, &inputEdit);
    }
    
    /// Create a copy of this tree
    Tree copy() @system nothrow @nogc {
        return Tree(ptr ? ts_tree_copy(ptr) : null);
    }
}

struct Cursor {
    private TSTreeCursor cursor;
    private bool initialized;
    
    @disable this(this);
    
    this(TSNode node) @system nothrow @nogc {
        cursor = ts_tree_cursor_new(node);
        initialized = true;
    }
    
    ~this() @system nothrow @nogc {
        if (initialized)
            ts_tree_cursor_delete(&cursor);
    }
    
    TSTreeCursor* handle() @system nothrow @nogc { return &cursor; }
}

