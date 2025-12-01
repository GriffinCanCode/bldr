class BuilderPluginExample < Formula
  desc "Example plugin for Builder build system"
  homepage "https://github.com/GriffinCanCode/bldr"
  url "https://github.com/GriffinCanCode/bldr/archive/v2.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/GriffinCanCode/bldr.git", branch: "master"

  depends_on "bldr"
  
  # For Python plugins
  # depends_on "python@3.11"
  
  # For Go plugins
  # depends_on "go" => :build
  
  # For Rust plugins
  # depends_on "rust" => :build
  
  # For D plugins
  # depends_on "ldc" => :build
  # depends_on "dub" => :build

  def install
    # For Python plugins (executable script)
    bin.install "builder-plugin-example"
    
    # For compiled plugins
    # D
    # system "dub", "build", "--build=release", "--compiler=ldc2"
    # bin.install "bin/builder-plugin-example"
    
    # Go
    # system "go", "build", "-o", "builder-plugin-example"
    # bin.install "builder-plugin-example"
    
    # Rust
    # system "cargo", "build", "--release"
    # bin.install "target/release/builder-plugin-example"
  end

  test do
    # Test that plugin responds to info request
    output = pipe_output("#{bin}/builder-plugin-example", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    
    # Verify response contains expected fields
    assert_match "example", output
    assert_match "version", output
    assert_match "capabilities", output
  end
end

