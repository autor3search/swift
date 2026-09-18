class Autor3searchSwift < Formula
  desc "Autonomous AI-driven performance optimization for any Swift repository"
  homepage "https://github.com/autor3search/swift"
  url "https://github.com/autor3search/swift/archive/refs/tags/v0.1.0.tar.gz"
  # PLACEHOLDER -- NOT A REAL HASH, AND THIS FORMULA CANNOT INSTALL UNTIL IT IS ONE.
  #
  # There is no v0.1.0 tag and no release tarball yet, so this value cannot be
  # computed. It is the one number in this repository that does not correspond to
  # a measurement, and it is spelled so that it cannot be mistaken for one: a real
  # sha256 is 64 lowercase hex characters, and this is not.
  #
  # At tag time, replace it with the output of:
  #   curl -sL https://github.com/autor3search/swift/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
  # Do not invent it, and do not copy one from another formula to "make brew stop
  # complaining" -- a wrong hash is a download nobody verified.
  sha256 "REPLACE_WITH_REAL_SHA256_OF_THE_RELEASE_TARBALL"
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
