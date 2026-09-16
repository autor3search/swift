import ArgumentParser
import AutoR3SearchKit

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version")
    func run() throws { print(BuildInfo.describe(gitDescribe: nil, dirty: false)) }
}
