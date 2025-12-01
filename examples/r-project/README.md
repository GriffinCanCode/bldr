# R Project Example

This example demonstrates R language support in Builder.

## Project Structure

```
r-project/
├── main.R           # Main R script with data analysis
├── utils.R          # Utility functions
├── test_utils.R     # Unit tests
├── Builderfile      # Build configuration
├── Builderspace     # Workspace configuration
└── README.md        # This file
```

## Features Demonstrated

- R script execution
- Dependency detection (library calls)
- Source file imports
- Testing support
- Executable wrapper generation

## Building

Build the R application:

```bash
bldr build r-app
```

## Running

Run the built application:

```bash
./bin/r-app
```

## Testing

Run the tests:

```bash
bldr test
```

## Configuration

The `Builderfile` shows:
- Basic R script configuration
- Test target setup
- Dependency management

## Notes

- This example uses only base R (no external packages)
- The main script sources utility functions automatically
- Tests validate utility functions
- Builder detects `library()` and `source()` calls automatically

## Next Steps

- See `examples/r-package/` for R package development
- See `examples/r-shiny/` for Shiny app examples
- See `examples/r-markdown/` for RMarkdown document examples

