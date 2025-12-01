class BuilderPluginCache < Formula
  desc "Intelligent cache warming plugin for Builder"
  homepage "https://github.com/GriffinCanCode/bldr"
  url "https://github.com/GriffinCanCode/bldr/archive/v2.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/GriffinCanCode/bldr.git", branch: "master"

  depends_on "bldr"
  depends_on "ldc" => :build
  depends_on "dub" => :build

  def install
    cd "examples/plugins/builder-plugin-cache" do
      # Build the D plugin
      system "dub", "build", "--build=release", "--compiler=ldc2"
      
      # Install binary
      bin.install "builder-plugin-cache"
    end
  end

  test do
    # Test that plugin responds to info request
    output = pipe_output("#{bin}/builder-plugin-cache", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    
    assert_match "cache", output
    assert_match "version", output
    assert_match "Intelligent cache warming", output
  end
end

