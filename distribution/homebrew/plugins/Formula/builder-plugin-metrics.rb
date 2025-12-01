class BuilderPluginMetrics < Formula
  desc "Advanced build metrics and analytics for Builder"
  homepage "https://github.com/GriffinCanCode/bldr"
  url "https://github.com/GriffinCanCode/bldr/archive/v2.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/GriffinCanCode/bldr.git", branch: "master"

  depends_on "bldr"
  depends_on "go" => :build

  def install
    cd "examples/plugins/builder-plugin-metrics" do
      # Build the Go plugin
      system "go", "build", "-o", "builder-plugin-metrics", 
             "-ldflags", "-s -w", 
             "-trimpath"
      
      # Install binary
      bin.install "builder-plugin-metrics"
    end
  end

  test do
    # Test that plugin responds to info request
    output = pipe_output("#{bin}/builder-plugin-metrics", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    
    assert_match "metrics", output
    assert_match "version", output
    assert_match "build metrics", output
  end
end

