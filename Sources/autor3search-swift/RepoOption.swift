import ArgumentParser
import Foundation

/// Every command takes -C. We resolve paths against it rather than calling chdir,
/// which is safer under concurrent invocations and testable.
struct RepoOption: ParsableArguments {
    @Option(name: .customShort("C"), help: "Run against this repository instead of the current directory.")
    var directory: String = FileManager.default.currentDirectoryPath

    var repoURL: URL { URL(fileURLWithPath: directory).standardizedFileURL }
}
