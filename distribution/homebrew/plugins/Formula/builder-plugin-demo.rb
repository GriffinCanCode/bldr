class BuilderPluginDemo < Formula
  desc "Demo plugin for Builder build system"
  homepage "https://github.com/GriffinCanCode/bldr"
  url "https://github.com/GriffinCanCode/bldr/archive/v2.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/GriffinCanCode/bldr.git", branch: "master"

  depends_on "bldr"
  depends_on "python@3.11"

  def install
    # Install the plugin
    bin.install "examples/plugins/builder-plugin-demo"
  end

  test do
    # Test that plugin responds to info request
    output = pipe_output("#{bin}/builder-plugin-demo", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    
    # Verify response contains expected fields
    assert_match "demo", output
    assert_match "version", output
    assert_match "capabilities", output
    assert_match "build.pre_hook", output
    assert_match "build.post_hook", output
  end
end

