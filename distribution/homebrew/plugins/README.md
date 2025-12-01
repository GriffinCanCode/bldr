# Builder Plugins - Homebrew Tap

Official Homebrew tap for Builder plugins.

## Usage

### Add the tap

```bash
brew tap builder/plugins
```

### Install plugins

```bash
# Install Docker plugin
brew install bldr-plugin-docker

# Install multiple plugins
brew install bldr-plugin-docker builder-plugin-sonar builder-plugin-notify
```

### List available plugins

```bash
brew search builder-plugin-
```

### Update plugins

```bash
brew upgrade builder-plugin-docker

# Or update all plugins
brew upgrade $(brew list | grep '^builder-plugin-')
```

### Uninstall plugins

```bash
brew uninstall builder-plugin-docker
```

## Available Plugins

| Plugin | Description | Formula |
|--------|-------------|---------|
| docker | Docker integration for Builder | `builder-plugin-docker` |
| sonar | SonarQube code quality analysis | `builder-plugin-sonar` |
| notify | Build notifications (Slack/Discord) | `builder-plugin-notify` |
| s3 | Upload artifacts to S3 | `builder-plugin-s3` |
| grafana | Send metrics to Grafana | `builder-plugin-grafana` |

## Plugin Development

### Create a new plugin

```bash
builder plugin create myplugin --language=python
cd builder-plugin-myplugin
# Implement your plugin
# Create Homebrew formula (see below)
```

### Create Homebrew Formula

Create a file `Formula/builder-plugin-myplugin.rb`:

```ruby
class BuilderPluginMyplugin < Formula
  desc "My plugin for Builder"
  homepage "https://github.com/GriffinCanCode/builder-plugin-myplugin"
  url "https://github.com/GriffinCanCode/builder-plugin-myplugin/archive/v2.0.0.tar.gz"
  sha256 "YOUR_SHA256_HERE"
  license "MIT"

  depends_on "bldr"

  def install
    # For Python plugins
    bin.install "builder-plugin-myplugin"
    
    # For compiled plugins (D, Go, Rust)
    # system "make", "build"
    # bin.install "bin/builder-plugin-myplugin"
  end

  test do
    output = pipe_output("#{bin}/builder-plugin-myplugin", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    assert_match "myplugin", output
  end
end
```

### Submit a Plugin

1. Fork this repository
2. Add your formula to `Formula/`
3. Test your formula:
   ```bash
   brew install --build-from-source ./Formula/builder-plugin-myplugin.rb
   brew test builder-plugin-myplugin
   ```
4. Create a pull request

## Formula Guidelines

- **Naming**: Formul must be named `builder-plugin-<name>.rb`
- **Class name**: Must be `BuilderPlugin<Name>` (CamelCase)
- **Dependencies**: Always depend on `builder`
- **Testing**: Include a test that verifies the plugin responds to `plugin.info`
- **License**: Specify the plugin's license
- **Homepage**: Link to the plugin's repository or documentation

## Versioning

- Use semantic versioning (MAJOR.MINOR.PATCH)
- Tag releases in your plugin repository
- Update the formula URL and SHA256 for each release

## Support

- [bldr Documentation](https://github.com/GriffinCanCode/bldr/tree/master/docs)
- [Plugin Architecture](https://github.com/GriffinCanCode/bldr/blob/master/docs/architecture/PLUGINS.md)
- [Issues](https://github.com/GriffinCanCode/bldr/issues)

## License

This tap is licensed under the MIT License. Individual plugins may have their own licenses.

