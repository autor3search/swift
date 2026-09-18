import Testing
@testable import AutoR3SearchKit

@Test func describeMarksDirtyCheckouts() {
    #expect(BuildInfo.describe(gitDescribe: "a1b2c3d", dirty: true) == "a1b2c3d (dirty)")
    #expect(BuildInfo.describe(gitDescribe: "a1b2c3d", dirty: false) == "a1b2c3d")
}

@Test func describeFallsBackToVersionWhenNotAGitCheckout() {
    #expect(BuildInfo.describe(gitDescribe: nil, dirty: false) == BuildInfo.version)
}
