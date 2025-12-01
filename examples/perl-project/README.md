# Perl Project Example

This example demonstrates Builder's Perl language support with a simple greeting application.

## Project Structure

```
perl-project/
├── Builderfile           # Build configuration
├── Builderspace          # Workspace configuration
├── main.pl               # Main executable script
├── lib/
│   └── Greeter.pm       # Perl module with POD documentation
└── t/
    ├── 00-load.t        # Load test
    └── 01-basic.t       # Basic functionality tests
```

## Features Demonstrated

- **Executable scripts** - `main.pl` demonstrates script building
- **Modules** - `lib/Greeter.pm` shows module structure with POD documentation
- **Testing** - `t/` directory contains Test::More tests
- **Documentation** - POD documentation in the module
- **Build configuration** - Multiple targets with dependencies

## Building

### Build Everything

```bash
cd examples/perl-project
bldr build
```

### Build Specific Target

```bash
bldr build :perl_app      # Build executable
bldr build :greeter_lib   # Validate library
bldr build :tests         # Run tests
```

### Run Tests

```bash
bldr build :tests
```

Or directly with prove:

```bash
prove -lv t/
```

## Running

After building:

```bash
./bin/perl-app
```

Or directly:

```bash
perl main.pl
```

## Configuration Options

The Builderfile demonstrates various Perl configuration options:

### Basic Executable

```
target perl_app {
    type = "executable"
    language = "perl"
    sources = ["main.pl"]
}
```

### Library with Documentation

```
target greeter_lib {
    type = "library"
    language = "perl"
    sources = ["lib/Greeter.pm"]
    
    langConfig = {
        "perl": {
            "mode": "module",
            "strict": true,
            "warnings": true,
            "documentation": {
                "generator": "pod2html",
                "outputDir": "doc"
            }
        }
    }
}
```

### Tests with prove

```
target tests {
    type = "test"
    language = "perl"
    sources = ["t/*.t"]
    
    langConfig = {
        "perl": {
            "test": {
                "framework": "prove",
                "testPaths": ["t/"],
                "prove": {
                    "verbose": true,
                    "lib": true,
                    "recurse": true,
                    "color": true
                }
            },
            "includeDirs": ["lib"]
        }
    }
}
```

## Advanced Features

The `advanced` target demonstrates:
- CPAN dependency management
- Code formatting with perltidy
- Multiple source files
- Include directories

To enable dependency installation, set `installDeps` to `true` and ensure cpanm is installed:

```bash
curl -L https://cpanmin.us | perl - App::cpanminus
```

## Testing

### Run All Tests

```bash
prove -lv t/
```

### Run with Coverage

```bash
cover -delete
HARNESS_PERL_SWITCHES=-MDevel::Cover prove -l t/
cover
```

### Run Specific Test

```bash
perl -Ilib t/01-basic.t
```

## Code Quality

### Syntax Check

```bash
perl -c main.pl
perl -c lib/Greeter.pm
```

### Format with perltidy

```bash
perltidy -b main.pl lib/Greeter.pm
```

### Lint with Perl::Critic

```bash
perlcritic --severity 3 main.pl lib/
```

## Documentation

### Generate HTML Documentation

```bash
pod2html --infile=lib/Greeter.pm --outfile=doc/Greeter.html
```

### View POD

```bash
perldoc lib/Greeter.pm
```

## Dependencies

This example uses only core Perl modules:
- `strict` - Enforce good programming practices
- `warnings` - Enable warnings
- `v5.10` - Require Perl 5.10+ (for `say`)
- `FindBin` - Locate directory of original script
- `lib` - Manipulate @INC
- `Test::More` - Testing framework (core since 5.6.2)

No CPAN modules are required to run this example.

## Requirements

- Perl 5.10 or higher
- Builder build system

Optional (for advanced features):
- cpanm - For CPAN dependency management
- perltidy - For code formatting
- Perl::Critic - For code linting
- Devel::Cover - For coverage reports

## Further Reading

- [Perl Documentation](https://perldoc.perl.org/)
- [Modern Perl](http://modernperlbooks.com/)
- [CPAN](https://metacpan.org/)
- [Perl Best Practices](https://www.oreilly.com/library/view/perl-best-practices/0596001738/)

## License

This example is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

