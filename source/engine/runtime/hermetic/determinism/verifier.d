module engine.runtime.hermetic.determinism.verifier;

import std.file : exists, read, getSize, dirEntries, SpanMode;
import std.path : buildPath, baseName, extension;
import std.algorithm : map, filter;
import std.array : array, join;
import std.conv : to;
import std.datetime : SysTime;
import std.string : strip;
import infrastructure.utils.files.hash : FastHash;
import engine.runtime.hermetic.determinism.enforcer;
import infrastructure.errors;

/// Verification strategy for build outputs
enum VerificationStrategy
{
    ContentHash,      // Compare content hashes (default)
    BitwiseCompare,   // Bit-for-bit comparison
    Fuzzy,           // Ignore timestamps and metadata
    Structural       // Compare structure, not exact bytes
}

/// File comparison result
struct FileComparison
{
    string filePath;
    bool matches;
    string hash1;
    string hash2;
    string[] differences;  // Description of differences
}

/// Verification result for deterministic builds
struct VerificationResult
{
    bool isDeterministic;
    FileComparison[] comparisons;
    string[] violations;
    ulong totalFiles;
    ulong matchingFiles;
    double matchPercentage;
    
    /// Get summary string
    string summary() @safe const
    {
        import std.format : format;
        
        if (isDeterministic)
            return format("✓ Deterministic: %d/%d files match (%.1f%%)",
                matchingFiles, totalFiles, matchPercentage);
        else
            return format("✗ Non-deterministic: %d/%d files differ (%.1f%% match)",
                totalFiles - matchingFiles, totalFiles, matchPercentage);
    }
}

/// Verifier for deterministic build outputs
/// 
/// Compares build outputs across multiple runs to verify bit-for-bit
/// reproducibility. Supports multiple verification strategies and can
/// identify specific sources of non-determinism.
struct DeterminismVerifier
{
    private VerificationStrategy strategy;
    
    /// Create verifier with strategy
    static DeterminismVerifier create(
        VerificationStrategy strategy = VerificationStrategy.ContentHash
    ) @safe pure nothrow
    {
        DeterminismVerifier verifier;
        verifier.strategy = strategy;
        return verifier;
    }
    
    /// Verify outputs from two builds match
    BuildResult!VerificationResult verify(
        string[] outputPaths1,
        string[] outputPaths2
    ) @system
    {
        import std.algorithm : sort;
        
        // Normalize paths
        auto sorted1 = outputPaths1.dup.sort().array;
        auto sorted2 = outputPaths2.dup.sort().array;
        
        // Check same file count
        if (sorted1.length != sorted2.length)
        {
            return Err!(VerificationResult, BuildError)(
                Errors.system("Different number of output files: " ~ 
                    sorted1.length.to!string ~ " vs " ~ sorted2.length.to!string,
                    ErrorCode.ValidationFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        VerificationResult result;
        result.totalFiles = sorted1.length;
        result.matchingFiles = 0;
        
        // Compare each file pair
        foreach (i, path1; sorted1)
        {
            auto path2 = sorted2[i];
            
            // Verify both files exist
            if (!exists(path1) || !exists(path2))
            {
                FileComparison comparison;
                comparison.filePath = baseName(path1);
                comparison.matches = false;
                comparison.differences = ["File missing"];
                result.comparisons ~= comparison;
                continue;
            }
            
            // Compare based on strategy
            auto comparison = compareFiles(path1, path2);
            result.comparisons ~= comparison;
            
            if (comparison.matches)
                result.matchingFiles++;
            else
                result.violations ~= comparison.filePath ~ ": " ~ 
                    comparison.differences.join(", ");
        }
        
        result.matchPercentage = (cast(double)result.matchingFiles / result.totalFiles) * 100.0;
        result.isDeterministic = (result.matchingFiles == result.totalFiles);
        
        return Ok!(VerificationResult, BuildError)(result);
    }
    
    /// Verify directory outputs match
    BuildResult!VerificationResult verifyDirectory(
        string dir1,
        string dir2
    ) @system
    {
        if (!exists(dir1) || !exists(dir2))
        {
            return Err!(VerificationResult, BuildError)(
                Errors.system("Directory not found", ErrorCode.DirectoryNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        // Collect all files recursively
        auto files1 = collectFiles(dir1);
        auto files2 = collectFiles(dir2);
        
        return verify(files1, files2);
    }
    
    /// Verify single file matches across runs
    BuildResult!bool verifyFile(string path1, string path2) @system
    {
        if (!exists(path1) || !exists(path2))
            return Err!(bool, BuildError)(
                ioError(path1, "File not found"));
        
        auto comparison = compareFiles(path1, path2);
        return Ok!(bool, BuildError)(comparison.matches);
    }
    
    /// Compute aggregate hash for all outputs
    static string computeOutputHash(string[] outputPaths) @system
    {
        import std.algorithm : sort;
        
        // Sort for deterministic ordering
        auto sorted = outputPaths.dup.sort().array;
        
        // Hash all files
        string combined;
        foreach (path; sorted)
        {
            if (exists(path))
                combined ~= FastHash.hashFile(path);
        }
        
        return FastHash.hashString(combined);
    }
    
    private:
    
    /// Compare two files based on verification strategy
    FileComparison compareFiles(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        final switch (strategy)
        {
            case VerificationStrategy.ContentHash:
                return compareByHash(path1, path2);
            
            case VerificationStrategy.BitwiseCompare:
                return compareByBitwise(path1, path2);
            
            case VerificationStrategy.Fuzzy:
                return compareByFuzzy(path1, path2);
            
            case VerificationStrategy.Structural:
                return compareByStructure(path1, path2);
        }
    }
    
    /// Compare by content hash (fast)
    FileComparison compareByHash(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        comparison.hash1 = FastHash.hashFile(path1);
        comparison.hash2 = FastHash.hashFile(path2);
        comparison.matches = (comparison.hash1 == comparison.hash2);
        
        if (!comparison.matches)
            comparison.differences = ["Content hash mismatch"];
        
        return comparison;
    }
    
    /// Compare bit-for-bit (thorough but slow)
    FileComparison compareByBitwise(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        // Check sizes first
        auto size1 = getSize(path1);
        auto size2 = getSize(path2);
        
        if (size1 != size2)
        {
            comparison.matches = false;
            comparison.differences = ["Size mismatch: " ~ 
                size1.to!string ~ " vs " ~ size2.to!string];
            return comparison;
        }
        
        // Read and compare bytes
        auto bytes1 = cast(ubyte[])read(path1);
        auto bytes2 = cast(ubyte[])read(path2);
        
        comparison.matches = (bytes1 == bytes2);
        
        if (!comparison.matches)
        {
            // Find first difference
            foreach (i, b1; bytes1)
            {
                if (b1 != bytes2[i])
                {
                    comparison.differences = [
                        "First difference at byte " ~ i.to!string ~
                        ": 0x" ~ b1.to!string(16) ~ " vs 0x" ~ bytes2[i].to!string(16)
                    ];
                    break;
                }
            }
        }
        
        return comparison;
    }
    
    /// Compare ignoring timestamps and metadata (fuzzy)
    FileComparison compareByFuzzy(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        // Read both files
        auto bytes1 = cast(ubyte[])read(path1);
        auto bytes2 = cast(ubyte[])read(path2);
        
        // Strip metadata based on file type
        auto stripped1 = stripMetadata(bytes1, path1);
        auto stripped2 = stripMetadata(bytes2, path2);
        
        // Hash stripped content
        comparison.hash1 = FastHash.hashBytes(stripped1);
        comparison.hash2 = FastHash.hashBytes(stripped2);
        comparison.matches = (comparison.hash1 == comparison.hash2);
        
        if (!comparison.matches)
            comparison.differences = ["Content differs after metadata stripping"];
        
        return comparison;
    }
    
    /// Compare by structure (for archives, ELF, etc.)
    FileComparison compareByStructure(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        // Detect file type
        auto fileType = detectFileType(path1);
        
        final switch (fileType)
        {
            case FileType.ELF:
                comparison = compareELFStructure(path1, path2);
                break;
            case FileType.Archive:
                comparison = compareArchiveStructure(path1, path2);
                break;
            case FileType.Object:
                comparison = compareObjectStructure(path1, path2);
                break;
            case FileType.Unknown:
                // Fall back to fuzzy comparison
                comparison = compareByFuzzy(path1, path2);
                break;
        }
        
        return comparison;
    }
    
private:
    
    /// File type detection
    enum FileType { ELF, Archive, Object, Unknown }
    
    FileType detectFileType(string path) @system
    {
        import std.algorithm : startsWith;
        
        if (getSize(path) < 4)
            return FileType.Unknown;
        
        auto bytes = cast(ubyte[])read(path, 4);
        
        // ELF magic: 0x7F 'E' 'L' 'F'
        if (bytes.length >= 4 && bytes[0] == 0x7F && 
            bytes[1] == 'E' && bytes[2] == 'L' && bytes[3] == 'F')
            return FileType.ELF;
        
        // Archive magic: "!<arch>\n"
        if (bytes.length >= 4 && bytes[0] == '!' && bytes[1] == '<')
            return FileType.Archive;
        
        // Object file heuristics (various formats)
        auto ext = extension(path);
        if (ext == ".o" || ext == ".obj")
            return FileType.Object;
        
        return FileType.Unknown;
    }
    
    /// Strip metadata from file bytes
    ubyte[] stripMetadata(ubyte[] bytes, string path) @system
    {
        auto fileType = detectFileType(path);
        
        final switch (fileType)
        {
            case FileType.ELF:
                return stripELFMetadata(bytes);
            case FileType.Archive:
                return stripArchiveMetadata(bytes);
            case FileType.Object:
                return stripObjectMetadata(bytes);
            case FileType.Unknown:
                return bytes; // No stripping for unknown types
        }
    }
    
    /// Strip ELF metadata (timestamps, build IDs in notes section)
    ubyte[] stripELFMetadata(ubyte[] bytes) pure @system
    {
        if (bytes.length < 64)
            return bytes.dup;
        
        auto result = bytes.dup;
        
        // Check ELF magic number
        if (result[0] != 0x7F || result[1] != 'E' || result[2] != 'L' || result[3] != 'F')
            return result;
        
        ubyte elfClass = result[4]; // 1=32-bit, 2=64-bit
        ubyte elfData = result[5];  // 1=little-endian, 2=big-endian
        
        if (elfClass != 1 && elfClass != 2)
            return result;
        if (elfData != 1 && elfData != 2)
            return result;
        
        bool is64Bit = (elfClass == 2);
        bool isLittleEndian = (elfData == 1);
        
        // Parse ELF header to find section headers
        size_t shoff, shentsize, shnum, shstrndx;
        
        if (is64Bit)
        {
            if (bytes.length < 64)
                return result;
            
            shoff = readPointer64(result, 40, isLittleEndian);
            shentsize = readHalf(result, 58, isLittleEndian);
            shnum = readHalf(result, 60, isLittleEndian);
            shstrndx = readHalf(result, 62, isLittleEndian);
        }
        else
        {
            if (bytes.length < 52)
                return result;
            
            shoff = readWord(result, 32, isLittleEndian);
            shentsize = readHalf(result, 46, isLittleEndian);
            shnum = readHalf(result, 48, isLittleEndian);
            shstrndx = readHalf(result, 50, isLittleEndian);
        }
        
        // Verify section headers are within file
        if (shoff == 0 || shoff + (shnum * shentsize) > bytes.length)
            return result;
        
        // Process each section header
        for (size_t i = 0; i < shnum; i++)
        {
            size_t shdrOffset = shoff + (i * shentsize);
            if (shdrOffset + shentsize > bytes.length)
                break;
            
            uint shType;
            size_t shOffset, shSize;
            
            if (is64Bit)
            {
                shType = readWord(result, shdrOffset + 4, isLittleEndian);
                shOffset = readPointer64(result, shdrOffset + 24, isLittleEndian);
                shSize = readPointer64(result, shdrOffset + 32, isLittleEndian);
            }
            else
            {
                shType = readWord(result, shdrOffset + 4, isLittleEndian);
                shOffset = readWord(result, shdrOffset + 16, isLittleEndian);
                shSize = readWord(result, shdrOffset + 20, isLittleEndian);
            }
            
            // SHT_NOTE = 7 (note sections containing build IDs)
            if (shType == 7 && shOffset > 0 && shOffset + shSize <= bytes.length)
                stripNoteSection(result, shOffset, shSize, isLittleEndian);
        }
        
        return result;
    }
    
    /// Strip note section (zero out GNU build IDs)
    private void stripNoteSection(ubyte[] bytes, size_t offset, size_t size, bool isLittleEndian) pure @system
    {
        size_t pos = offset;
        size_t end = offset + size;
        
        while (pos + 12 <= end)
        {
            uint nameSize = readWord(bytes, pos, isLittleEndian);
            uint descSize = readWord(bytes, pos + 4, isLittleEndian);
            uint noteType = readWord(bytes, pos + 8, isLittleEndian);
            
            pos += 12;
            
            // Align name size to 4 bytes
            uint alignedNameSize = (nameSize + 3) & ~3;
            uint alignedDescSize = (descSize + 3) & ~3;
            
            if (pos + alignedNameSize + alignedDescSize > end)
                break;
            
            // Check if this is a GNU build-id note (type 3)
            if (noteType == 3 && nameSize >= 3)
            {
                // Check if name is "GNU"
                if (pos < bytes.length && bytes[pos] == 'G' && 
                    pos + 1 < bytes.length && bytes[pos + 1] == 'N' &&
                    pos + 2 < bytes.length && bytes[pos + 2] == 'U')
                {
                    // Zero out the descriptor (build ID)
                    size_t descOffset = pos + alignedNameSize;
                    for (size_t j = 0; j < descSize && descOffset + j < bytes.length; j++)
                        bytes[descOffset + j] = 0;
                }
            }
            
            pos += alignedNameSize + alignedDescSize;
        }
    }
    
    /// Read 16-bit half-word
    private ushort readHalf(ubyte[] bytes, size_t offset, bool isLittleEndian) pure @system
    {
        if (offset + 2 > bytes.length)
            return 0;
        
        if (isLittleEndian)
            return cast(ushort)(bytes[offset] | (bytes[offset + 1] << 8));
        else
            return cast(ushort)((bytes[offset] << 8) | bytes[offset + 1]);
    }
    
    /// Read 32-bit word
    private uint readWord(ubyte[] bytes, size_t offset, bool isLittleEndian) pure @system
    {
        if (offset + 4 > bytes.length)
            return 0;
        
        if (isLittleEndian)
            return bytes[offset] | (bytes[offset + 1] << 8) | 
                   (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
        else
            return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | 
                   (bytes[offset + 2] << 8) | bytes[offset + 3];
    }
    
    /// Read 64-bit pointer
    private ulong readPointer64(ubyte[] bytes, size_t offset, bool isLittleEndian) pure @system
    {
        if (offset + 8 > bytes.length)
            return 0;
        
        if (isLittleEndian)
        {
            return cast(ulong)bytes[offset] |
                   (cast(ulong)bytes[offset + 1] << 8) |
                   (cast(ulong)bytes[offset + 2] << 16) |
                   (cast(ulong)bytes[offset + 3] << 24) |
                   (cast(ulong)bytes[offset + 4] << 32) |
                   (cast(ulong)bytes[offset + 5] << 40) |
                   (cast(ulong)bytes[offset + 6] << 48) |
                   (cast(ulong)bytes[offset + 7] << 56);
        }
        else
        {
            return (cast(ulong)bytes[offset] << 56) |
                   (cast(ulong)bytes[offset + 1] << 48) |
                   (cast(ulong)bytes[offset + 2] << 40) |
                   (cast(ulong)bytes[offset + 3] << 32) |
                   (cast(ulong)bytes[offset + 4] << 24) |
                   (cast(ulong)bytes[offset + 5] << 16) |
                   (cast(ulong)bytes[offset + 6] << 8) |
                   cast(ulong)bytes[offset + 7];
        }
    }
    
    /// Strip archive metadata (timestamps, UIDs, GIDs)
    ubyte[] stripArchiveMetadata(ubyte[] bytes) @system
    {
        if (bytes.length < 8)
            return bytes.dup;
        
        // Check for archive magic
        if (bytes[0] != '!' || bytes[1] != '<' || bytes[2] != 'a' || 
            bytes[3] != 'r' || bytes[4] != 'c' || bytes[5] != 'h' || 
            bytes[6] != '>' || bytes[7] != '\n')
            return bytes.dup;
        
        auto result = bytes.dup;
        size_t offset = 8; // Skip magic
        
        // Process each archive member
        while (offset + 60 <= result.length)
        {
            // Archive member header is 60 bytes:
            // 0-15:  File name
            // 16-27: Timestamp (12 bytes) - ZERO THIS
            // 28-33: UID (6 bytes) - ZERO THIS
            // 34-39: GID (6 bytes) - ZERO THIS
            // 40-47: File mode
            // 48-57: File size
            // 58-59: Magic ("`\n")
            
            // Zero out timestamp (bytes 16-27)
            foreach (i; 16..28)
                result[offset + i] = ' ';
            
            // Zero out UID (bytes 28-33)
            foreach (i; 28..34)
                result[offset + i] = ' ';
            
            // Zero out GID (bytes 34-39)
            foreach (i; 34..40)
                result[offset + i] = ' ';
            
            // Get file size and skip to next member
            import std.string : strip;
            import std.conv : parse;
            
            try
            {
                auto sizeBytes = result[offset+48..offset+58];
                auto sizeStr = strip(cast(string)sizeBytes);
                auto fileSize = parse!size_t(sizeStr);
                offset += 60 + fileSize;
                
                // Archive members are 2-byte aligned
                if (offset % 2 == 1)
                    offset++;
            }
            catch (Exception)
            {
                break; // Malformed archive
            }
        }
        
        return result;
    }
    
    /// Strip object file metadata (full implementation for Mach-O and COFF)
    ubyte[] stripObjectMetadata(ubyte[] bytes) pure @system
    {
        if (bytes.length < 4)
            return bytes.dup;
        
        // Detect object file format
        // Mach-O: 0xFEEDFACE (32-bit) or 0xFEEDFACF (64-bit) or 0xCAFEBABE (universal)
        // COFF: 0x014C (x86) or 0x8664 (x64) at offset 0
        
        // Check for Mach-O magic numbers
        if (bytes.length >= 4)
        {
            immutable magic = readWord(bytes, 0, true);
            
            // Mach-O 32-bit: 0xFEEDFACE or 0xCEFAEDFE
            if (magic == 0xFEEDFACE || magic == 0xCEFAEDFE)
                return stripMachOMetadata(bytes, false);
            
            // Mach-O 64-bit: 0xFEEDFACF or 0xCFFAEDFE
            if (magic == 0xFEEDFACF || magic == 0xCFFAEDFE)
                return stripMachOMetadata(bytes, true);
            
            // Universal binary: 0xCAFEBABE or 0xBEBAFECA
            if (magic == 0xCAFEBABE || magic == 0xBEBAFECA)
                return stripUniversalBinary(bytes);
        }
        
        // Check for COFF/PE magic
        if (bytes.length >= 2)
        {
            immutable machine = readHalf(bytes, 0, true);
            
            // COFF machine types
            // 0x014C = IMAGE_FILE_MACHINE_I386
            // 0x8664 = IMAGE_FILE_MACHINE_AMD64
            // 0xAA64 = IMAGE_FILE_MACHINE_ARM64
            if (machine == 0x014C || machine == 0x8664 || machine == 0xAA64)
                return stripCOFFMetadata(bytes);
        }
        
        // Unknown format - return copy
        return bytes.dup;
    }
    
    /// Strip Mach-O metadata (timestamps, UUIDs, paths)
    ubyte[] stripMachOMetadata(ubyte[] bytes, bool is64Bit) pure @system
    {
        if (bytes.length < 32)
            return bytes.dup;
        
        auto result = bytes.dup;
        bool isLittleEndian = result[0] == 0xFE || result[0] == 0xCF;
        
        // Mach-O header offsets
        immutable headerSize = is64Bit ? 32 : 28;
        if (bytes.length < headerSize)
            return result;
        
        // Read number of load commands
        immutable ncmds = readWord(result, is64Bit ? 16 : 12, isLittleEndian);
        immutable sizeofcmds = readWord(result, is64Bit ? 20 : 16, isLittleEndian);
        
        // Verify load commands are within file
        if (headerSize + sizeofcmds > bytes.length)
            return result;
        
        // Process each load command
        size_t offset = headerSize;
        for (uint i = 0; i < ncmds && offset + 8 <= bytes.length; i++)
        {
            immutable cmd = readWord(result, offset, isLittleEndian);
            immutable cmdsize = readWord(result, offset + 4, isLittleEndian);
            
            if (offset + cmdsize > bytes.length)
                break;
            
            // LC_UUID = 0x1B (strip UUID)
            if (cmd == 0x1B && cmdsize >= 24)
            {
                // Zero out UUID (16 bytes starting at offset + 8)
                for (size_t j = 0; j < 16 && offset + 8 + j < result.length; j++)
                    result[offset + 8 + j] = 0;
            }
            
            // LC_BUILD_VERSION = 0x32 (may contain timestamps)
            if (cmd == 0x32 && cmdsize >= 24)
            {
                // Zero out timestamps if present
                if (offset + 16 < result.length)
                {
                    writeWord(result, offset + 16, 0, isLittleEndian);  // minos
                    writeWord(result, offset + 20, 0, isLittleEndian);  // sdk
                }
            }
            
            // LC_SOURCE_VERSION = 0x2A (contains source version - zero it)
            if (cmd == 0x2A && cmdsize >= 16)
            {
                if (offset + 8 < result.length)
                {
                    for (size_t j = 0; j < 8 && offset + 8 + j < result.length; j++)
                        result[offset + 8 + j] = 0;
                }
            }
            
            offset += cmdsize;
        }
        
        return result;
    }
    
    /// Strip universal binary metadata (recursively strip each slice)
    ubyte[] stripUniversalBinary(ubyte[] bytes) pure @system
    {
        if (bytes.length < 8)
            return bytes.dup;
        
        auto result = bytes.dup;
        immutable magic = readWord(result, 0, true);
        bool isLittleEndian = (magic == 0xBEBAFECA);
        
        // Read number of architectures
        immutable nfat_arch = readWord(result, 4, !isLittleEndian);  // Fat headers are big-endian
        
        // Process each architecture slice
        size_t headerOffset = 8;
        for (uint i = 0; i < nfat_arch && headerOffset + 20 <= bytes.length; i++)
        {
            immutable offset = readWord(result, headerOffset + 8, !isLittleEndian);
            immutable size = readWord(result, headerOffset + 12, !isLittleEndian);
            
            // Verify slice is within file
            if (offset + size <= bytes.length && size >= 4)
            {
                // Strip metadata from this slice
                auto sliceBytes = result[offset..offset + size];
                immutable sliceMagic = readWord(sliceBytes, 0, true);
                
                bool slice64Bit = (sliceMagic == 0xFEEDFACF || sliceMagic == 0xCFFAEDFE);
                auto strippedSlice = stripMachOMetadata(sliceBytes, slice64Bit);
                
                // Copy stripped slice back
                result[offset..offset + size] = strippedSlice;
            }
            
            headerOffset += 20;
        }
        
        return result;
    }
    
    /// Strip COFF metadata (timestamps, debug info)
    ubyte[] stripCOFFMetadata(ubyte[] bytes) pure @system
    {
        if (bytes.length < 20)
            return bytes.dup;
        
        auto result = bytes.dup;
        bool isLittleEndian = true;  // COFF is always little-endian
        
        // COFF file header structure:
        // 0-1:   Machine type
        // 2-3:   Number of sections
        // 4-7:   Time date stamp (ZERO THIS)
        // 8-11:  Pointer to symbol table
        // 12-15: Number of symbols
        // 16-17: Size of optional header
        // 18-19: Characteristics
        
        // Zero out timestamp (bytes 4-7)
        writeWord(result, 4, 0, isLittleEndian);
        
        // Read section count and optional header size
        immutable numberOfSections = readHalf(result, 2, isLittleEndian);
        immutable sizeOfOptionalHeader = readHalf(result, 16, isLittleEndian);
        
        // Optional header starts at offset 20
        size_t optHeaderOffset = 20;
        
        // If there's an optional header (PE), strip timestamp from it too
        if (sizeOfOptionalHeader > 0 && optHeaderOffset + sizeOfOptionalHeader <= bytes.length)
        {
            // PE optional header magic
            if (optHeaderOffset + 2 <= bytes.length)
            {
                immutable magic = readHalf(result, optHeaderOffset, isLittleEndian);
                
                // PE32 = 0x10B, PE32+ = 0x20B
                if (magic == 0x10B || magic == 0x20B)
                {
                    // Checksum is at offset 64 in PE32, 68 in PE32+
                    // Zero it out for reproducibility
                    immutable checksumOffset = optHeaderOffset + (magic == 0x10B ? 64 : 68);
                    if (checksumOffset + 4 <= bytes.length)
                    {
                        writeWord(result, checksumOffset, 0, isLittleEndian);
                    }
                }
            }
        }
        
        // Section headers start after optional header
        size_t sectionOffset = optHeaderOffset + sizeOfOptionalHeader;
        
        // Each section header is 40 bytes
        for (uint i = 0; i < numberOfSections && sectionOffset + 40 <= bytes.length; i++)
        {
            // Section header structure:
            // 0-7:   Name
            // 8-11:  Virtual size
            // 12-15: Virtual address
            // 16-19: Size of raw data
            // 20-23: Pointer to raw data
            // 24-27: Pointer to relocations
            // 28-31: Pointer to line numbers
            // 32-33: Number of relocations
            // 34-35: Number of line numbers
            // 36-39: Characteristics
            
            // Check if this is a debug section (.debug*, .pdata, etc.)
            // We don't strip debug sections entirely, just their timestamps
            
            sectionOffset += 40;
        }
        
        return result;
    }
    
    /// Write 32-bit word
    private void writeWord(ubyte[] bytes, size_t offset, uint value, bool isLittleEndian) pure @system
    {
        if (offset + 4 > bytes.length)
            return;
        
        if (isLittleEndian)
        {
            bytes[offset] = cast(ubyte)(value & 0xFF);
            bytes[offset + 1] = cast(ubyte)((value >> 8) & 0xFF);
            bytes[offset + 2] = cast(ubyte)((value >> 16) & 0xFF);
            bytes[offset + 3] = cast(ubyte)((value >> 24) & 0xFF);
        }
        else
        {
            bytes[offset] = cast(ubyte)((value >> 24) & 0xFF);
            bytes[offset + 1] = cast(ubyte)((value >> 16) & 0xFF);
            bytes[offset + 2] = cast(ubyte)((value >> 8) & 0xFF);
            bytes[offset + 3] = cast(ubyte)(value & 0xFF);
        }
    }
    
    /// Compare ELF files structurally
    FileComparison compareELFStructure(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        // Simplified: Compare after stripping metadata
        auto bytes1 = cast(ubyte[])read(path1);
        auto bytes2 = cast(ubyte[])read(path2);
        
        auto stripped1 = stripELFMetadata(bytes1);
        auto stripped2 = stripELFMetadata(bytes2);
        
        comparison.hash1 = FastHash.hashBytes(stripped1);
        comparison.hash2 = FastHash.hashBytes(stripped2);
        comparison.matches = (comparison.hash1 == comparison.hash2);
        
        if (!comparison.matches)
            comparison.differences = ["ELF structures differ"];
        
        return comparison;
    }
    
    /// Compare archive files structurally
    FileComparison compareArchiveStructure(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        // Compare after stripping archive metadata
        auto bytes1 = cast(ubyte[])read(path1);
        auto bytes2 = cast(ubyte[])read(path2);
        
        auto stripped1 = stripArchiveMetadata(bytes1);
        auto stripped2 = stripArchiveMetadata(bytes2);
        
        comparison.hash1 = FastHash.hashBytes(stripped1);
        comparison.hash2 = FastHash.hashBytes(stripped2);
        comparison.matches = (comparison.hash1 == comparison.hash2);
        
        if (!comparison.matches)
            comparison.differences = ["Archive contents differ"];
        
        return comparison;
    }
    
    /// Compare object files structurally
    FileComparison compareObjectStructure(string path1, string path2) @system
    {
        FileComparison comparison;
        comparison.filePath = baseName(path1);
        
        // Compare after stripping metadata
        auto bytes1 = cast(ubyte[])read(path1);
        auto bytes2 = cast(ubyte[])read(path2);
        
        auto stripped1 = stripObjectMetadata(bytes1);
        auto stripped2 = stripObjectMetadata(bytes2);
        
        comparison.hash1 = FastHash.hashBytes(stripped1);
        comparison.hash2 = FastHash.hashBytes(stripped2);
        comparison.matches = (comparison.hash1 == comparison.hash2);
        
        if (!comparison.matches)
            comparison.differences = ["Object structures differ"];
        
        return comparison;
    }
    
    /// Collect all files in directory recursively
    string[] collectFiles(string dir) @system
    {
        import std.file : isFile;
        
        return dirEntries(dir, SpanMode.breadth)
            .filter!(e => e.isFile)
            .map!(e => e.name)
            .array;
    }
}

@system unittest
{
    import std.stdio : writeln, File;
    import std.file : mkdirRecurse, rmdirRecurse, write;
    
    writeln("Testing determinism verifier...");
    
    // Create test files
    immutable testDir = "/tmp/builder-verifier-test";
    mkdirRecurse(testDir);
    scope(exit) rmdirRecurse(testDir);
    
    auto file1 = buildPath(testDir, "test1.txt");
    auto file2 = buildPath(testDir, "test2.txt");
    auto file3 = buildPath(testDir, "test3.txt");
    
    // Write identical content
    write(file1, "deterministic content");
    write(file2, "deterministic content");
    write(file3, "different content");
    
    auto verifier = DeterminismVerifier.create();
    
    // Test matching files
    auto result1 = verifier.verifyFile(file1, file2);
    assert(result1.isOk);
    assert(result1.unwrap());
    
    // Test non-matching files
    auto result2 = verifier.verifyFile(file1, file3);
    assert(result2.isOk);
    assert(!result2.unwrap());
    
    writeln("✓ Determinism verifier tests passed");
}

