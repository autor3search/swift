import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: every judgement and the report format live in `DoctorChecks`.
/// `doctor` is INFORMATIONAL and ALWAYS EXITS 0 -- `run()` never throws, so a
/// `.warn` Finding is printed, never escalated into a command failure.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report whether this machine can measure reliably. Always exits 0."
    )

    @OptionGroup var repoOption: RepoOption

    func run() {
        let findings = DoctorChecks.all(repo: repoOption.repoURL)
        print(DoctorChecks.report(findings: findings, repo: repoOption.repoURL))
    }
}
