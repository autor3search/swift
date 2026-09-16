import ArgumentParser

@main
struct AutoR3Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autor3search-swift",
        abstract: "Autonomous AI-driven performance optimization for any Swift repository.",
        subcommands: [VersionCommand.self, InitCommand.self, BaselineCommand.self]
    )
}
