# Metal GPU Shader Example

Example Metal compute shaders that can be compiled on macOS.

## Prerequisites

- macOS with Xcode Command Line Tools
- Verify with: `xcrun -sdk macosx metal --version`

## Build

```bash
cd examples/gpu-metal
bldr build compute_shaders
```

## Output

Creates `bin/compute_shaders.metallib` containing compiled GPU kernels.

## Shaders Included

### vector_add.metal
- `vector_add` - Element-wise addition of two vectors
- `vector_scale` - Scale a vector by a scalar
- `dot_product_partial` - Partial reduction for dot product

### matrix_ops.metal
- `matrix_multiply` - Matrix multiplication (C = A * B)
- `matrix_transpose` - Transpose a matrix
- `relu` - ReLU activation function
- `softmax_row` - Row-wise softmax

## Using the Metallib

```swift
import Metal

let device = MTLCreateSystemDefaultDevice()!
let library = try! device.makeLibrary(filepath: "bin/compute_shaders.metallib")
let function = library.makeFunction(name: "vector_add")!
let pipeline = try! device.makeComputePipelineState(function: function)
```

