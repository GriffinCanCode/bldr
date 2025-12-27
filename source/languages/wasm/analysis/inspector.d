module languages.wasm.analysis.inspector;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.process;
import infrastructure.utils.logging;

/// WASM module section types
enum WasmSectionId : ubyte
{
    Custom = 0,
    Type = 1,
    Import = 2,
    Function = 3,
    Table = 4,
    Memory = 5,
    Global = 6,
    Export = 7,
    Start = 8,
    Element = 9,
    Code = 10,
    Data = 11,
    DataCount = 12
}

/// WASM export type
enum WasmExportKind : ubyte
{
    Function = 0,
    Table = 1,
    Memory = 2,
    Global = 3
}

/// WASM import description
struct WasmImport
{
    string module_;
    string name;
    WasmExportKind kind;
}

/// WASM export description
struct WasmExport
{
    string name;
    WasmExportKind kind;
    uint index;
}

/// WASM function signature
struct WasmFuncType
{
    string[] params;
    string[] results;
}

/// WASM module metadata
struct WasmModuleInfo
{
    /// Module magic number valid
    bool valid;
    
    /// WASM version (typically 1)
    uint version_;
    
    /// Total size in bytes
    size_t sizeBytes;
    
    /// Imports
    WasmImport[] imports;
    
    /// Exports
    WasmExport[] exports;
    
    /// Function count
    uint functionCount;
    
    /// Memory pages (initial, max)
    uint memoryInitial;
    uint memoryMax;
    
    /// Has start function
    bool hasStart;
    uint startFunctionIndex;
    
    /// Custom section names
    string[] customSections;
    
    /// Feature requirements
    string[] requiredFeatures;
}

/// WASM module inspector
/// Parses and analyzes WebAssembly binary modules
class WasmInspector
{
    private ubyte[] data;
    private size_t pos;
    
    /// Inspect a WASM file
    static WasmModuleInfo inspect(string wasmPath)
    {
        WasmModuleInfo info;
        
        if (!exists(wasmPath))
        {
            structuredLog.warning("wasm_file_not_found_").field("path", wasmPath).emit();
            return info;
        }
        
        try
        {
            auto inspector = new WasmInspector(cast(ubyte[]) read(wasmPath));
            info = inspector.parse();
            info.sizeBytes = getSize(wasmPath);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_inspect_wasm_").field("error", e.msg).emit();
        }
        
        return info;
    }
    
    /// Inspect using wasm-objdump if available
    static WasmModuleInfo inspectWithWabt(string wasmPath)
    {
        WasmModuleInfo info;
        
        auto res = execute(["wasm-objdump", "-h", "-x", wasmPath]);
        if (res.status != 0)
            return inspect(wasmPath);  // Fallback to native parser
        
        info.valid = true;
        
        // Parse exports
        foreach (line; res.output.lineSplitter)
        {
            if (line.canFind(" - func["))
            {
                auto name = extractName(line);
                if (!name.empty)
                {
                    WasmExport exp;
                    exp.name = name;
                    exp.kind = WasmExportKind.Function;
                    info.exports ~= exp;
                }
            }
            else if (line.canFind(" - memory["))
            {
                WasmExport exp;
                exp.name = extractName(line);
                exp.kind = WasmExportKind.Memory;
                info.exports ~= exp;
            }
        }
        
        return info;
    }
    
    private this(ubyte[] data)
    {
        this.data = data;
        this.pos = 0;
    }
    
    private WasmModuleInfo parse()
    {
        WasmModuleInfo info;
        
        // Check magic number: \0asm
        if (data.length < 8)
            return info;
        
        if (data[0..4] != [0x00, 0x61, 0x73, 0x6D])
        {
            structuredLog.warning("invalid_wasm_magic_number").emit();
            return info;
        }
        
        info.valid = true;
        
        // Version (little-endian u32)
        info.version_ = (data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24));
        pos = 8;
        
        // Parse sections
        while (pos < data.length)
        {
            ubyte sectionId = data[pos++];
            uint sectionSize = readLEB128();
            size_t sectionEnd = pos + sectionSize;
            
            switch (cast(WasmSectionId) sectionId)
            {
                case WasmSectionId.Import:
                    info.imports = parseImportSection(sectionEnd);
                    break;
                    
                case WasmSectionId.Export:
                    info.exports = parseExportSection(sectionEnd);
                    break;
                    
                case WasmSectionId.Function:
                    info.functionCount = readLEB128();
                    break;
                    
                case WasmSectionId.Memory:
                    parseMemorySection(info);
                    break;
                    
                case WasmSectionId.Start:
                    info.hasStart = true;
                    info.startFunctionIndex = readLEB128();
                    break;
                    
                case WasmSectionId.Custom:
                    string customName = readName();
                    info.customSections ~= customName;
                    break;
                    
                default:
                    break;
            }
            
            pos = sectionEnd;
        }
        
        return info;
    }
    
    private WasmImport[] parseImportSection(size_t sectionEnd)
    {
        WasmImport[] imports;
        uint count = readLEB128();
        
        for (uint i = 0; i < count && pos < sectionEnd; i++)
        {
            WasmImport imp;
            imp.module_ = readName();
            imp.name = readName();
            
            ubyte kind = data[pos++];
            imp.kind = cast(WasmExportKind) kind;
            
            // Skip the type/index based on kind
            switch (imp.kind)
            {
                case WasmExportKind.Function:
                    readLEB128();  // type index
                    break;
                case WasmExportKind.Table:
                    pos++;  // element type
                    parseLimits();
                    break;
                case WasmExportKind.Memory:
                    parseLimits();
                    break;
                case WasmExportKind.Global:
                    pos++;  // value type
                    pos++;  // mutability
                    break;
                default:
                    break;
            }
            
            imports ~= imp;
        }
        
        return imports;
    }
    
    private WasmExport[] parseExportSection(size_t sectionEnd)
    {
        WasmExport[] exports;
        uint count = readLEB128();
        
        for (uint i = 0; i < count && pos < sectionEnd; i++)
        {
            WasmExport exp;
            exp.name = readName();
            exp.kind = cast(WasmExportKind) data[pos++];
            exp.index = readLEB128();
            exports ~= exp;
        }
        
        return exports;
    }
    
    private void parseMemorySection(ref WasmModuleInfo info)
    {
        uint count = readLEB128();
        if (count > 0)
        {
            auto limits = parseLimits();
            info.memoryInitial = limits[0];
            info.memoryMax = limits[1];
        }
    }
    
    private uint[2] parseLimits()
    {
        ubyte flags = data[pos++];
        uint initial = readLEB128();
        uint max = (flags & 1) ? readLEB128() : uint.max;
        return [initial, max];
    }
    
    private string readName()
    {
        uint len = readLEB128();
        if (pos + len > data.length)
            return "";
        
        string name = cast(string) data[pos .. pos + len].idup;
        pos += len;
        return name;
    }
    
    private uint readLEB128()
    {
        uint result = 0;
        uint shift = 0;
        
        while (pos < data.length)
        {
            ubyte b = data[pos++];
            result |= (b & 0x7F) << shift;
            if ((b & 0x80) == 0)
                break;
            shift += 7;
        }
        
        return result;
    }
    
    private static string extractName(string line)
    {
        // Extract name from wasm-objdump output like " - func[0] <name>"
        auto ltIdx = line.indexOf('<');
        auto gtIdx = line.indexOf('>');
        if (ltIdx >= 0 && gtIdx > ltIdx)
            return line[ltIdx + 1 .. gtIdx];
        return "";
    }
}

/// Validate WASM module
struct WasmValidator
{
    /// Validate using wasm-validate (wabt)
    static bool validate(string wasmPath, out string error)
    {
        auto res = execute(["wasm-validate", wasmPath]);
        if (res.status != 0)
        {
            error = res.output;
            return false;
        }
        return true;
    }
    
    /// Quick validation (check magic + version)
    static bool quickValidate(string wasmPath)
    {
        if (!exists(wasmPath))
            return false;
        
        auto data = cast(ubyte[]) read(wasmPath);
        if (data.length < 8)
            return false;
        
        // Check magic: \0asm
        return data[0..4] == [0x00, 0x61, 0x73, 0x6D];
    }
}

/// Convert WAT (text) to WASM (binary)
struct WatConverter
{
    /// Convert WAT to WASM
    static bool wat2wasm(string watPath, string wasmPath, out string error)
    {
        auto res = execute(["wat2wasm", watPath, "-o", wasmPath]);
        if (res.status != 0)
        {
            error = res.output;
            return false;
        }
        return true;
    }
    
    /// Convert WASM to WAT (for debugging)
    static bool wasm2wat(string wasmPath, string watPath, out string error)
    {
        auto res = execute(["wasm2wat", wasmPath, "-o", watPath]);
        if (res.status != 0)
        {
            error = res.output;
            return false;
        }
        return true;
    }
}


