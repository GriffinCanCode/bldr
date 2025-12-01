class Bldr < Formula
  desc "High-performance build system for mixed-language monorepos"
  homepage "https://github.com/GriffinCanCode/bldr"
  url "https://github.com/GriffinCanCode/bldr/archive/refs/tags/v2.0.3.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"
  head "https://github.com/GriffinCanCode/bldr.git", branch: "master"

  depends_on "ldc" => :build
  depends_on "dub" => :build

  def install
    # Build using Makefile which handles C dependencies
    system "make", "build"

    # Install binaries
    bin.install "bin/bldr"
    
    # Optionally install LSP server if built
    bin.install "bin/bldr-lsp" if File.exist?("bin/bldr-lsp")
  end

  test do
    # Test that the binary runs and shows correct version
    assert_match "bldr version 2.0.3", shell_output("#{bin}/bldr --version")
    
    # Test help command
    system "#{bin}/bldr", "--help"
  end
end

