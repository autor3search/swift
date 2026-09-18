class Autor3searchSwift < Formula
  desc "Autonomous AI-driven performance optimization for any Swift repository"
  homepage "https://github.com/autor3search/swift"
  url "https://github.com/autor3search/swift/archive/refs/tags/v0.1.0.tar.gz"
  # Computed from the v0.1.0 release tarball, not copied and not invented:
  #   curl -sL https://github.com/autor3search/swift/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
  # Verified against the downloaded archive (361,625 bytes, 126 entries) before
  # being written here. A wrong hash is a download nobody verified, so if this
  # ever stops matching, do not "fix" it by pasting whatever brew reports --
  # find out why the tarball changed.
  sha256 "7b57684bbdad8e81940be84fbcc2ce16e0c180d86ac6f3a8e68bf9ce35b2620b"
  license "MIT"

  # Package.swift declares `swift-tools-version: 6.0`, and Swift 6.0 first shipped
  # in Xcode 16.0. The floor is 16.0 rather than 15.0 for that reason: with Xcode
  # 15 the manifest itself will not parse, so a lower floor would only convert a
  # clear "needs a newer Xcode" into a confusing build failure.
  depends_on xcode: ["16.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/autor3search-swift"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/autor3search-swift version")
  end
end
