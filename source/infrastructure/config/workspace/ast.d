module infrastructure.config.workspace.ast;

import std.conv;
import std.algorithm;
import std.array;
import infrastructure.errors;

/// UNIFIED AST - Single Source of Truth for all Builder DSL nodes
/// Replaces old AST with clean, type-safe design

// ============================================================================
// LOCATION TRACKING
// ============================================================================

struct Location
{
    string file;
    size_t line;
    size_t column;
    
    this(string file, size_t line, size_t column) pure nothrow @nogc @safe
    {
        this.file = file;
        this.line = line;
        this.column = column;
    }
    
    string toString() const pure @safe
    {
        return file ~ ":" ~ line.to!string ~ ":" ~ column.to!string;
    }
}

// ============================================================================
// BASE NODES
// ============================================================================

interface Node
{
    Location location() const pure nothrow @safe;
    string nodeType() const pure nothrow @safe;
}

interface Expr : Node { }
interface Stmt : Node { }

// ============================================================================
// LITERAL VALUES
// ============================================================================

enum LiteralKind { Null, Bool, Number, String, Array, Map }

struct Literal
{
    LiteralKind kind;
    
    private union Storage
    {
        bool boolValue;
        long numberValue;
        string stringValue;
        Literal[]* arrayValue;
        Literal[string]* mapValue;
    }
    
    private Storage storage;
    
    // Factories
    static Literal makeNull() pure nothrow @nogc @safe
    {
        Literal lit;
        lit.kind = LiteralKind.Null;
        return lit;
    }
    
    static Literal makeBool(bool value) pure nothrow @nogc @trusted
    {
        Literal lit;
        lit.kind = LiteralKind.Bool;
        lit.storage.boolValue = value;
        return lit;
    }
    
    static Literal makeNumber(long value) pure nothrow @nogc @safe
    {
        Literal lit;
        lit.kind = LiteralKind.Number;
        lit.storage.numberValue = value;
        return lit;
    }
    
    static Literal makeString(string value) pure @trusted
    {
        Literal lit;
        lit.kind = LiteralKind.String;
        lit.storage.stringValue = value;
        return lit;
    }
    
    static Literal makeArray(Literal[] elements) @trusted
    {
        import core.memory : GC;
        Literal lit;
        lit.kind = LiteralKind.Array;
        auto arr = elements.dup;
        lit.storage.arrayValue = cast(Literal[]*) GC.malloc((Literal[]).sizeof);
        *lit.storage.arrayValue = arr;
        return lit;
    }
    
    static Literal makeMap(Literal[string] pairs) @trusted
    {
        import core.memory : GC;
        Literal lit;
        lit.kind = LiteralKind.Map;
        auto map = pairs.dup;
        lit.storage.mapValue = cast(Literal[string]*) GC.malloc((Literal[string]).sizeof);
        *lit.storage.mapValue = map;
        return lit;
    }
    
    // Accessors
    bool asBool() const pure @trusted
    in (kind == LiteralKind.Bool)
    {
        return storage.boolValue;
    }
    
    long asNumber() const pure nothrow @nogc @safe
    in (kind == LiteralKind.Number)
    {
        return storage.numberValue;
    }
    
    string asString() const pure @trusted
    in (kind == LiteralKind.String)
    {
        return storage.stringValue;
    }
    
    const(Literal[]) asArray() const pure nothrow @nogc @trusted
    in (kind == LiteralKind.Array)
    {
        return *storage.arrayValue;
    }
    
    const(Literal[string]) asMap() const pure nothrow @nogc @trusted
    in (kind == LiteralKind.Map)
    {
        return *storage.mapValue;
    }
    
    // Conversions
    BuildResult!(string[]) toStringArray() const @trusted
    {
        if (kind != LiteralKind.Array)
            return Err!(string[], BuildError)(
                Errors.parse("", "Expected array", Parse.InvalidFieldValue)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        
        string[] result;
        foreach (elem; asArray())
        {
            if (elem.kind != LiteralKind.String)
                return Err!(string[], BuildError)(
                    Errors.parse("", "Array must contain strings", Parse.InvalidFieldValue)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            result ~= elem.asString();
        }
        return Ok!(string[], BuildError)(result);
    }
    
    BuildResult!(string[string]) toStringMap() const @trusted
    {
        if (kind != LiteralKind.Map)
            return Err!(string[string], BuildError)(
                Errors.parse("", "Expected map", Parse.InvalidFieldValue)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        
        string[string] result;
        foreach (key, value; asMap())
        {
            if (value.kind != LiteralKind.String)
                return Err!(string[string], BuildError)(
                    Errors.parse("", "Map values must be strings", Parse.InvalidFieldValue)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            result[key] = value.asString();
        }
        return Ok!(string[string], BuildError)(result);
    }
    
    string toString() const @safe
    {
        final switch (kind)
        {
            case LiteralKind.Null: return "null";
            case LiteralKind.Bool: return asBool() ? "true" : "false";
            case LiteralKind.Number: return asNumber().to!string;
            case LiteralKind.String: return `"` ~ asString() ~ `"`;
            case LiteralKind.Array: return "[" ~ asArray().map!(e => e.toString()).join(", ") ~ "]";
            case LiteralKind.Map:
                string[] pairs;
                foreach (k, v; asMap())
                    pairs ~= k ~ ": " ~ v.toString();
                return "{" ~ pairs.join(", ") ~ "}";
        }
    }
}

// ============================================================================
// EXPRESSIONS
// ============================================================================

class LiteralExpr : Expr
{
    Literal value;
    Location loc;
    
    this(Literal value, Location loc) pure nothrow @safe
    {
        this.value = value;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "LiteralExpr"; }
}

class IdentExpr : Expr
{
    string name;
    Location loc;
    
    this(string name, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "IdentExpr"; }
}

class BinaryExpr : Expr
{
    Expr left;
    string op;
    Expr right;
    Location loc;
    
    this(Expr left, string op, Expr right, Location loc) pure nothrow @safe
    {
        this.left = left;
        this.op = op;
        this.right = right;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "BinaryExpr"; }
}

class UnaryExpr : Expr
{
    string op;
    Expr operand;
    Location loc;
    
    this(string op, Expr operand, Location loc) pure nothrow @safe
    {
        this.op = op;
        this.operand = operand;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "UnaryExpr"; }
}

class CallExpr : Expr
{
    string callee;
    Expr[] args;
    Location loc;
    
    this(string callee, Expr[] args, Location loc) pure nothrow @safe
    {
        this.callee = callee;
        this.args = args;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "CallExpr"; }
}

class IndexExpr : Expr
{
    Expr object;
    Expr index;
    Location loc;
    
    this(Expr object, Expr index, Location loc) pure nothrow @safe
    {
        this.object = object;
        this.index = index;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "IndexExpr"; }
}

class SliceExpr : Expr
{
    Expr object;
    Expr start;
    Expr end;
    Location loc;
    
    this(Expr object, Expr start, Expr end, Location loc) pure nothrow @safe
    {
        this.object = object;
        this.start = start;
        this.end = end;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "SliceExpr"; }
}

class MemberExpr : Expr
{
    Expr object;
    string member;
    Location loc;
    
    this(Expr object, string member, Location loc) pure nothrow @safe
    {
        this.object = object;
        this.member = member;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "MemberExpr"; }
}

class TernaryExpr : Expr
{
    Expr condition;
    Expr trueExpr;
    Expr falseExpr;
    Location loc;
    
    this(Expr condition, Expr trueExpr, Expr falseExpr, Location loc) pure nothrow @safe
    {
        this.condition = condition;
        this.trueExpr = trueExpr;
        this.falseExpr = falseExpr;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "TernaryExpr"; }
}

class LambdaExpr : Expr
{
    string[] params;
    Expr body;
    Location loc;
    
    this(string[] params, Expr body, Location loc) pure nothrow @safe
    {
        this.params = params;
        this.body = body;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "LambdaExpr"; }
}

// ============================================================================
// STATEMENTS
// ============================================================================

class VarDeclStmt : Stmt
{
    string name;
    Expr initializer;
    bool isConst;
    Location loc;
    
    this(string name, Expr initializer, bool isConst, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.initializer = initializer;
        this.isConst = isConst;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return isConst ? "ConstDecl" : "LetDecl"; }
}

struct Parameter
{
    string name;
    Expr defaultValue;
    
    bool hasDefault() const pure nothrow @nogc @safe { return defaultValue !is null; }
}

class FunctionDeclStmt : Stmt
{
    string name;
    Parameter[] params;
    Stmt[] body;
    Location loc;
    
    this(string name, Parameter[] params, Stmt[] body, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.params = params;
        this.body = body;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "FunctionDecl"; }
}

class MacroDeclStmt : Stmt
{
    string name;
    string[] params;
    Stmt[] body;
    Location loc;
    
    this(string name, string[] params, Stmt[] body, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.params = params;
        this.body = body;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "MacroDecl"; }
}

class IfStmt : Stmt
{
    Expr condition;
    Stmt[] thenBranch;
    Stmt[] elseBranch;
    Location loc;
    
    this(Expr condition, Stmt[] thenBranch, Stmt[] elseBranch, Location loc) pure nothrow @safe
    {
        this.condition = condition;
        this.thenBranch = thenBranch;
        this.elseBranch = elseBranch;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "IfStmt"; }
}

class ForStmt : Stmt
{
    string variable;
    Expr iterable;
    Stmt[] body;
    Location loc;
    
    this(string variable, Expr iterable, Stmt[] body, Location loc) pure nothrow @safe
    {
        this.variable = variable;
        this.iterable = iterable;
        this.body = body;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "ForStmt"; }
}

class ReturnStmt : Stmt
{
    Expr value;
    Location loc;
    
    this(Expr value, Location loc) pure nothrow @safe
    {
        this.value = value;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "ReturnStmt"; }
}

class ImportStmt : Stmt
{
    string modulePath;
    Location loc;
    
    this(string modulePath, Location loc) pure nothrow @safe
    {
        this.modulePath = modulePath;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "ImportStmt"; }
}

class ExprStmt : Stmt
{
    Expr expr;
    Location loc;
    
    this(Expr expr, Location loc) pure nothrow @safe
    {
        this.expr = expr;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "ExprStmt"; }
}

class BlockStmt : Stmt
{
    Stmt[] stmts;
    Location loc;
    
    this(Stmt[] stmts, Location loc) pure nothrow @safe
    {
        this.stmts = stmts;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "BlockStmt"; }
}

// ============================================================================
// DECLARATIONS
// ============================================================================

struct Field
{
    string name;
    Expr value;
    Location loc;
    
    this(string name, Expr value, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.value = value;
        this.loc = loc;
    }
    
    /// Get the literal value if this field contains a literal expression
    const(Literal)* getLiteral() const pure nothrow @trusted
    {
        if (auto litExpr = cast(LiteralExpr)value)
            return &litExpr.value;
        return null;
    }
}

class TargetDeclStmt : Stmt
{
    string name;
    Field[] fields;
    Location loc;
    
    this(string name, Field[] fields, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.fields = fields;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "TargetDecl"; }
    
    const(Field)* getField(string name) const pure nothrow @trusted
    {
        foreach (i, ref field; fields)
            if (field.name == name)
                return &fields[i];
        return null;
    }
}

class RepositoryDeclStmt : Stmt
{
    string name;
    Field[] fields;
    Location loc;
    
    this(string name, Field[] fields, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.fields = fields;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "RepositoryDecl"; }
    
    const(Field)* getField(string name) const pure nothrow @trusted
    {
        foreach (i, ref field; fields)
            if (field.name == name)
                return &fields[i];
        return null;
    }
}

class WorkspaceDeclStmt : Stmt
{
    string name;
    Field[] fields;
    Location loc;
    
    this(string name, Field[] fields, Location loc) pure nothrow @safe
    {
        this.name = name;
        this.fields = fields;
        this.loc = loc;
    }
    
    override Location location() const pure nothrow @safe { return loc; }
    override string nodeType() const pure nothrow @safe { return "WorkspaceDecl"; }
    
    const(Field)* getField(string name) const pure nothrow @trusted
    {
        foreach (i, ref field; fields)
            if (field.name == name)
                return &fields[i];
        return null;
    }
}

// ============================================================================
// ROOT
// ============================================================================

struct BuildFile
{
    Stmt[] statements;
    string filePath;
    
    auto targets() const pure nothrow @safe
    {
        import std.algorithm : filter, map;
        return statements
            .filter!(s => cast(TargetDeclStmt)s !is null)
            .map!(s => cast(TargetDeclStmt)s);
    }
    
    auto repositories() const pure nothrow @safe
    {
        import std.algorithm : filter, map;
        return statements
            .filter!(s => cast(RepositoryDeclStmt)s !is null)
            .map!(s => cast(RepositoryDeclStmt)s);
    }
    
    WorkspaceDeclStmt getWorkspace() const pure nothrow @trusted
    {
        foreach (stmt; statements)
            if (auto ws = cast(WorkspaceDeclStmt)stmt)
                return ws;
        return null;
    }
}

// ============================================================================
// VISITORS
// ============================================================================

interface ExprVisitor(T)
{
    T visitLiteralExpr(LiteralExpr expr);
    T visitIdentExpr(IdentExpr expr);
    T visitBinaryExpr(BinaryExpr expr);
    T visitUnaryExpr(UnaryExpr expr);
    T visitCallExpr(CallExpr expr);
    T visitIndexExpr(IndexExpr expr);
    T visitSliceExpr(SliceExpr expr);
    T visitMemberExpr(MemberExpr expr);
    T visitTernaryExpr(TernaryExpr expr);
    T visitLambdaExpr(LambdaExpr expr);
}

interface StmtVisitor(T)
{
    T visitVarDeclStmt(VarDeclStmt stmt);
    T visitFunctionDeclStmt(FunctionDeclStmt stmt);
    T visitMacroDeclStmt(MacroDeclStmt stmt);
    T visitIfStmt(IfStmt stmt);
    T visitForStmt(ForStmt stmt);
    T visitReturnStmt(ReturnStmt stmt);
    T visitImportStmt(ImportStmt stmt);
    T visitExprStmt(ExprStmt stmt);
    T visitBlockStmt(BlockStmt stmt);
    T visitTargetDeclStmt(TargetDeclStmt stmt);
    T visitRepositoryDeclStmt(RepositoryDeclStmt stmt);
    T visitWorkspaceDeclStmt(WorkspaceDeclStmt stmt);
}

T accept(T)(Expr expr, ExprVisitor!T visitor)
{
    if (auto e = cast(LiteralExpr)expr) return visitor.visitLiteralExpr(e);
    if (auto e = cast(IdentExpr)expr) return visitor.visitIdentExpr(e);
    if (auto e = cast(BinaryExpr)expr) return visitor.visitBinaryExpr(e);
    if (auto e = cast(UnaryExpr)expr) return visitor.visitUnaryExpr(e);
    if (auto e = cast(CallExpr)expr) return visitor.visitCallExpr(e);
    if (auto e = cast(IndexExpr)expr) return visitor.visitIndexExpr(e);
    if (auto e = cast(SliceExpr)expr) return visitor.visitSliceExpr(e);
    if (auto e = cast(MemberExpr)expr) return visitor.visitMemberExpr(e);
    if (auto e = cast(TernaryExpr)expr) return visitor.visitTernaryExpr(e);
    if (auto e = cast(LambdaExpr)expr) return visitor.visitLambdaExpr(e);
    assert(false, "Unknown expression type");
}

T accept(T)(Stmt stmt, StmtVisitor!T visitor)
{
    if (auto s = cast(VarDeclStmt)stmt) return visitor.visitVarDeclStmt(s);
    if (auto s = cast(FunctionDeclStmt)stmt) return visitor.visitFunctionDeclStmt(s);
    if (auto s = cast(MacroDeclStmt)stmt) return visitor.visitMacroDeclStmt(s);
    if (auto s = cast(IfStmt)stmt) return visitor.visitIfStmt(s);
    if (auto s = cast(ForStmt)stmt) return visitor.visitForStmt(s);
    if (auto s = cast(ReturnStmt)stmt) return visitor.visitReturnStmt(s);
    if (auto s = cast(ImportStmt)stmt) return visitor.visitImportStmt(s);
    if (auto s = cast(ExprStmt)stmt) return visitor.visitExprStmt(s);
    if (auto s = cast(BlockStmt)stmt) return visitor.visitBlockStmt(s);
    if (auto s = cast(TargetDeclStmt)stmt) return visitor.visitTargetDeclStmt(s);
    if (auto s = cast(RepositoryDeclStmt)stmt) return visitor.visitRepositoryDeclStmt(s);
    if (auto s = cast(WorkspaceDeclStmt)stmt) return visitor.visitWorkspaceDeclStmt(s);
    assert(false, "Unknown statement type");
}
