# Builder SIMD Library Makefile
# Compiles SIMD-accelerated code for multiple architectures

CC = gcc
CFLAGS = -O3 -Wall -Wextra -std=c11 -fPIC -DNDEBUG
AR = ar
ARFLAGS = rcs

# Detect platform
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Platform-specific settings
ifeq ($(UNAME_S),Darwin)
    LIB_NAME = libsimd.a
    INSTALL_DIR = /usr/local/lib
else ifeq ($(UNAME_S),Linux)
    LIB_NAME = libsimd.a
    INSTALL_DIR = /usr/local/lib
else
    LIB_NAME = simd.lib
    INSTALL_DIR = C:/lib
endif

# Architecture detection
ARCH_X86 = 0
ARCH_ARM = 0

ifeq ($(UNAME_M),x86_64)
    ARCH_X86 = 1
else ifeq ($(UNAME_M),amd64)
    ARCH_X86 = 1
else ifeq ($(UNAME_M),arm64)
    ARCH_ARM = 1
else ifeq ($(UNAME_M),aarch64)
    ARCH_ARM = 1
endif

# Source files
SOURCES = cpu_detect.c blake3_dispatch.c simd_ops.c bloom.c bloom_simd.c strings.c gear_simd.c

# x86/x64 SIMD sources
ifeq ($(ARCH_X86),1)
    SIMD_SOURCES = blake3_sse2.c blake3_sse41.c blake3_avx2.c blake3_avx512.c
    SIMD_FLAGS_SSE2 = -msse2
    SIMD_FLAGS_SSE41 = -msse4.1
    SIMD_FLAGS_AVX2 = -mavx2
    SIMD_FLAGS_AVX512 = -mavx512f -mavx512vl
endif

# ARM SIMD sources
ifeq ($(ARCH_ARM),1)
    SIMD_SOURCES = blake3_neon.c
    SIMD_FLAGS_NEON = -march=armv8-a+simd
    # Also compile x86 SIMD as stubs (for linking compatibility)
    STUB_SOURCES = blake3_sse2.c blake3_sse41.c blake3_avx2.c blake3_avx512.c
endif

# x86 platforms: compile ARM as stub
ifeq ($(ARCH_X86),1)
    STUB_SOURCES = blake3_neon.c
endif

# All sources
ALL_SOURCES = $(SOURCES) $(SIMD_SOURCES)
OBJECTS = $(ALL_SOURCES:.c=.o)

# Stub objects (compiled without intrinsics)
ifeq ($(STUB_SOURCES),)
    STUB_OBJECTS =
else
    STUB_OBJECTS = $(STUB_SOURCES:.c=.o)
endif

ALL_OBJECTS = $(OBJECTS) $(STUB_OBJECTS)

# Build targets
all: $(LIB_NAME)

$(LIB_NAME): $(ALL_OBJECTS)
	$(AR) $(ARFLAGS) $@ $^
	@echo "Built $@ successfully for $(UNAME_S) $(UNAME_M)"

# Generic compilation
cpu_detect.o: cpu_detect.c cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@

blake3_dispatch.o: blake3_dispatch.c blake3_simd.h cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@

simd_ops.o: simd_ops.c simd_ops.h cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@

bloom.o: bloom.c bloom.h bloom_simd.h cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@

# strings.c needs SIMD flags for string comparison
ifeq ($(ARCH_X86),1)
strings.o: strings.c strings.h cpu_detect.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_AVX2) -mavx512f -mavx512bw -msse4.2 -c $< -o $@
else
strings.o: strings.c strings.h cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@
endif

# bloom_simd.c needs SIMD flags for vectorized probing
ifeq ($(ARCH_X86),1)
bloom_simd.o: bloom_simd.c bloom_simd.h bloom.h cpu_detect.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_AVX2) -mavx512f -mavx512vl -c $< -o $@
else
bloom_simd.o: bloom_simd.c bloom_simd.h bloom.h cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@
endif

# gear_simd.c needs SIMD flags for vectorized gear hash
ifeq ($(ARCH_X86),1)
gear_simd.o: gear_simd.c gear_simd.h cpu_detect.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_AVX2) -mavx512f -mavx512vl -c $< -o $@
else
gear_simd.o: gear_simd.c gear_simd.h cpu_detect.h
	$(CC) $(CFLAGS) -c $< -o $@
endif

# x86 SIMD-specific compilation
ifeq ($(ARCH_X86),1)
blake3_sse2.o: blake3_sse2.c blake3_simd.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_SSE2) -c $< -o $@

blake3_sse41.o: blake3_sse41.c blake3_simd.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_SSE41) -c $< -o $@

blake3_avx2.o: blake3_avx2.c blake3_simd.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_AVX2) -c $< -o $@

blake3_avx512.o: blake3_avx512.c blake3_simd.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_AVX512) -c $< -o $@
endif

# ARM SIMD-specific compilation
ifeq ($(ARCH_ARM),1)
blake3_neon.o: blake3_neon.c blake3_simd.h
	$(CC) $(CFLAGS) $(SIMD_FLAGS_NEON) -c $< -o $@

# Compile x86 SIMD files as stubs on ARM (no intrinsics, just portable fallback)
blake3_sse2.o: blake3_sse2.c blake3_simd.h
	@echo "/* Stub for x86 SSE2 on ARM */" > blake3_sse2_stub.c
	@echo "#include \"blake3_simd.h\"" >> blake3_sse2_stub.c
	@echo "void blake3_compress_sse2(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]) {" >> blake3_sse2_stub.c
	@echo "    extern void blake3_compress_portable(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]);" >> blake3_sse2_stub.c
	@echo "    blake3_compress_portable(cv, block, block_len, counter, flags, out);" >> blake3_sse2_stub.c
	@echo "}" >> blake3_sse2_stub.c
	$(CC) $(CFLAGS) -c blake3_sse2_stub.c -o $@

blake3_sse41.o: blake3_sse41.c blake3_simd.h
	@echo "/* Stub for x86 SSE4.1 on ARM */" > blake3_sse41_stub.c
	@echo "#include \"blake3_simd.h\"" >> blake3_sse41_stub.c
	@echo "void blake3_compress_sse41(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]) {" >> blake3_sse41_stub.c
	@echo "    extern void blake3_compress_portable(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]);" >> blake3_sse41_stub.c
	@echo "    blake3_compress_portable(cv, block, block_len, counter, flags, out);" >> blake3_sse41_stub.c
	@echo "}" >> blake3_sse41_stub.c
	$(CC) $(CFLAGS) -c blake3_sse41_stub.c -o $@

blake3_avx2.o: blake3_avx2.c blake3_simd.h
	@echo "/* Stub for x86 AVX2 on ARM */" > blake3_avx2_stub.c
	@echo "#include \"blake3_simd.h\"" >> blake3_avx2_stub.c
	@echo "#include <stdbool.h>" >> blake3_avx2_stub.c
	@echo "void blake3_compress_avx2(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]) {" >> blake3_avx2_stub.c
	@echo "    extern void blake3_compress_portable(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]);" >> blake3_avx2_stub.c
	@echo "    blake3_compress_portable(cv, block, block_len, counter, flags, out);" >> blake3_avx2_stub.c
	@echo "}" >> blake3_avx2_stub.c
	@echo "void blake3_hash_many_avx2(const uint8_t* const* inputs, size_t num_inputs, size_t blocks, const uint32_t key[8], uint64_t counter, bool increment_counter, uint8_t flags, uint8_t flags_start, uint8_t flags_end, uint8_t* out) {" >> blake3_avx2_stub.c
	@echo "    extern void blake3_hash_many_portable(const uint8_t* const* inputs, size_t num_inputs, size_t blocks, const uint32_t key[8], uint64_t counter, bool increment_counter, uint8_t flags, uint8_t flags_start, uint8_t flags_end, uint8_t* out);" >> blake3_avx2_stub.c
	@echo "    blake3_hash_many_portable(inputs, num_inputs, blocks, key, counter, increment_counter, flags, flags_start, flags_end, out);" >> blake3_avx2_stub.c
	@echo "}" >> blake3_avx2_stub.c
	$(CC) $(CFLAGS) -c blake3_avx2_stub.c -o $@

blake3_avx512.o: blake3_avx512.c blake3_simd.h
	@echo "/* Stub for x86 AVX512 on ARM */" > blake3_avx512_stub.c
	@echo "#include \"blake3_simd.h\"" >> blake3_avx512_stub.c
	@echo "#include <stdbool.h>" >> blake3_avx512_stub.c
	@echo "void blake3_compress_avx512(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]) {" >> blake3_avx512_stub.c
	@echo "    extern void blake3_compress_portable(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]);" >> blake3_avx512_stub.c
	@echo "    blake3_compress_portable(cv, block, block_len, counter, flags, out);" >> blake3_avx512_stub.c
	@echo "}" >> blake3_avx512_stub.c
	@echo "void blake3_hash_many_avx512(const uint8_t* const* inputs, size_t num_inputs, size_t blocks, const uint32_t key[8], uint64_t counter, bool increment_counter, uint8_t flags, uint8_t flags_start, uint8_t flags_end, uint8_t* out) {" >> blake3_avx512_stub.c
	@echo "    extern void blake3_hash_many_portable(const uint8_t* const* inputs, size_t num_inputs, size_t blocks, const uint32_t key[8], uint64_t counter, bool increment_counter, uint8_t flags, uint8_t flags_start, uint8_t flags_end, uint8_t* out);" >> blake3_avx512_stub.c
	@echo "    blake3_hash_many_portable(inputs, num_inputs, blocks, key, counter, increment_counter, flags, flags_start, flags_end, out);" >> blake3_avx512_stub.c
	@echo "}" >> blake3_avx512_stub.c
	$(CC) $(CFLAGS) -c blake3_avx512_stub.c -o $@
endif

# Optimized build with -march=native
optimized:
	$(MAKE) clean
	$(MAKE) CFLAGS="$(CFLAGS) -march=native -mtune=native" all

# Debug build
debug:
	$(MAKE) clean
	$(MAKE) CFLAGS="-g -O0 -Wall -Wextra -std=c11 -fPIC" all

# Clean
clean:
	rm -f $(ALL_OBJECTS) $(LIB_NAME) *_stub.c
	@echo "Cleaned build artifacts"

# Install
install: $(LIB_NAME)
	mkdir -p $(INSTALL_DIR)
	mkdir -p $(INSTALL_DIR)/../include/builder
	cp $(LIB_NAME) $(INSTALL_DIR)/
	cp *.h $(INSTALL_DIR)/../include/builder/
	@echo "Installed $(LIB_NAME) to $(INSTALL_DIR)"

# Uninstall
uninstall:
	rm -f $(INSTALL_DIR)/$(LIB_NAME)
	rm -rf $(INSTALL_DIR)/../include/builder
	@echo "Uninstalled SIMD library"

# Test compilation
test:
	@echo "Architecture: $(UNAME_M)"
	@echo "X86: $(ARCH_X86)"
	@echo "ARM: $(ARCH_ARM)"
	@echo "SIMD Sources: $(SIMD_SOURCES)"

.PHONY: all optimized debug clean install uninstall test

