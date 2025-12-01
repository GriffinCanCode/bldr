class BuilderPluginSecurity < Formula
  desc "Dependency vulnerability scanner for Builder"
  homepage "https://github.com/GriffinCanCode/bldr"
  url "https://github.com/GriffinCanCode/bldr/archive/v2.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/GriffinCanCode/bldr.git", branch: "master"

  depends_on "bldr"
  depends_on "rust" => :build

  def install
    cd "examples/plugins/builder-plugin-security" do
      # Build the Rust plugin
      system "cargo", "build", "--release"
      
      # Install binary
      bin.install "target/release/builder-plugin-security"
    end
  end

  test do
    # Test that plugin responds to info request
    output = pipe_output("#{bin}/builder-plugin-security", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    
    assert_match "security", output
    assert_match "version", output
    assert_match "vulnerability", output
  end
end

