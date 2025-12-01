# Protocol Buffer Example

This example demonstrates how to use Builder to compile Protocol Buffer files and generate code for multiple target languages.

## Project Structure

```
protobuf-project/
├── person.proto          # Person message definition
├── company.proto         # Company message definition (imports person.proto)
├── Builderfile          # Build configuration
├── Builderspace         # Workspace configuration
└── generated/           # Generated code (created during build)
    ├── cpp/
    ├── python/
    ├── java/
    └── go/
```

## Proto Files

### person.proto

Defines basic data structures:
- `Person` - Represents a person with contact information
- `PhoneNumber` - Phone number with type
- `Address` - Address information
- `PhoneType` enum - Types of phone numbers
- `EmploymentStatus` enum - Employment status

### company.proto

Defines company-related structures:
- `Company` - Represents a company with employees
- `Department` - Represents a department within a company

Note: `company.proto` imports `person.proto` to reuse the `Person` and `Address` messages.

## Building

### Prerequisites

Install Protocol Buffer compiler:

**macOS:**
```bash
brew install protobuf
```

**Linux:**
```bash
sudo apt install protobuf-compiler
```

**Windows:**
Download from https://protobuf.dev/downloads/

### Build All Targets

Generate code for all languages:
```bash
bldr build
```

### Build Specific Language

Generate code for a specific language:
```bash
# C++
bldr build protos-cpp

# Python
bldr build protos-python

# Java
bldr build protos-java

# Go
bldr build protos-go
```

## Configuration

Each target in the `Builderfile` specifies:
- `language`: Set to `"protobuf"`
- `sources`: Proto files to compile (supports glob patterns)
- `protobuf.outputLanguage`: Target language for code generation
- `protobuf.outputDir`: Directory for generated code

### Supported Output Languages

- C++ (`cpp`)
- C# (`csharp`)
- Java (`java`)
- Kotlin (`kotlin`)
- Objective-C (`objc`)
- PHP (`php`)
- Python (`python`)
- Ruby (`ruby`)
- Go (`go`)
- Rust (`rust`)
- JavaScript (`javascript`)
- TypeScript (`typescript`)
- Dart (`dart`)
- Swift (`swift`)

## Advanced Configuration

### Using Import Paths

If your proto files import from external directories:

```json
{
  "name": "protos-with-imports",
  "language": "protobuf",
  "sources": ["api/**/*.proto"],
  "protobuf": {
    "outputLanguage": "python",
    "importPaths": [
      "third_party/googleapis",
      "vendor/protos"
    ]
  }
}
```

### Using Plugins

For gRPC or other protoc plugins:

```json
{
  "name": "grpc-protos",
  "language": "protobuf",
  "sources": ["services/**/*.proto"],
  "protobuf": {
    "outputLanguage": "go",
    "plugins": [
      "protoc-gen-go",
      "protoc-gen-go-grpc"
    ],
    "pluginOptions": {
      "go_opt": "paths=source_relative",
      "go-grpc_opt": "paths=source_relative"
    }
  }
}
```

### Generating Descriptor Sets

Descriptor sets are useful for runtime reflection:

```json
{
  "name": "protos-with-descriptor",
  "language": "protobuf",
  "sources": ["**/*.proto"],
  "protobuf": {
    "outputLanguage": "python",
    "generateDescriptor": true,
    "descriptorPath": "proto_descriptor.pb"
  }
}
```

### Using Buf for Linting and Formatting

If you have [Buf](https://buf.build) installed:

```json
{
  "name": "validated-protos",
  "language": "protobuf",
  "sources": ["**/*.proto"],
  "protobuf": {
    "outputLanguage": "java",
    "lint": true,
    "format": true
  }
}
```

## Generated Code

After building, you'll find generated code in the `generated/` directory:

### C++ (generated/cpp/)
- `person.pb.h`, `person.pb.cc`
- `company.pb.h`, `company.pb.cc`

### Python (generated/python/)
- `person_pb2.py`
- `company_pb2.py`

### Java (generated/java/)
- `com/example/proto/Person.java`
- `com/example/proto/Company.java`
- etc.

### Go (generated/go/)
- `person.pb.go`
- `company.pb.go`

## Using Generated Code

### C++
```cpp
#include "person.pb.h"

example::Person person;
person.set_name("John Doe");
person.set_email("john@example.com");
```

### Python
```python
import person_pb2

person = person_pb2.Person()
person.name = "John Doe"
person.email = "john@example.com"
```

### Java
```java
import com.example.proto.Person;

Person person = Person.newBuilder()
    .setName("John Doe")
    .setEmail("john@example.com")
    .build();
```

### Go
```go
import "generated/go/person"

person := &example.Person{
    Name:  "John Doe",
    Email: "john@example.com",
}
```

## Clean

Remove generated files:
```bash
bldr clean
```

## Notes

- Import paths are relative to the workspace root
- Proto files must be valid Protocol Buffer 3 syntax
- Plugin binaries must be in your PATH
- For gRPC support, install the appropriate language plugin
- The Builder build system automatically tracks proto file dependencies

