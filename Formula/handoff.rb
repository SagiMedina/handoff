class Handoff < Formula
  desc "Continue your Mac terminal sessions on your phone"
  homepage "https://github.com/SagiMedina/handoff"
  url "https://github.com/SagiMedina/handoff/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on "tmux"
  depends_on "tailscale"
  depends_on "qrencode"

  def install
    bin.install "bin/handoff"
    (lib/"handoff").install "lib/handoff-common.sh"
  end

  test do
    assert_match "handoff", shell_output("#{bin}/handoff version")
  end
end
