import Foundation

@main
struct IntelPermissionChecks {
    static func main() async throws {
        let rule = IntelPowerMetricsService.sudoersRule(user: NSUserName())
        let displayedCommand = SudoersPermissionAlert.command(rule: rule)
        precondition(displayedCommand.hasPrefix("sudo sh -c \"\n  echo "))
        precondition(displayedCommand.contains(" \\\n    >> /etc/sudoers.d/stillcore-"))
        precondition(displayedCommand.contains(" &&\n  chmod 440 "))
        precondition(displayedCommand.hasSuffix("\n\""))
        let location = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stillcore-intel-sudoers-\(UUID().uuidString)")
        try Data((rule + "\n").utf8).write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        task.arguments = ["-cf", location.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(task.terminationStatus == 0, output)
        precondition(rule.contains("^--samplers cpu_power --format plist -i [1-9][0-9]*$"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", "-c", SudoersPermissionAlert.script(rule: rule)]
        try shell.run()
        shell.waitUntilExit()
        precondition(shell.terminationStatus == 0)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillcore-sudoers-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkInstallerExecution(in: directory, rule: rule)
        let sudo = directory.appendingPathComponent("sudo")
        try Data("#!/bin/sh\nexec \"$@\"\n".utf8).write(to: sudo)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sudo.path)
        let pmsetRule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -[bc] lowpowermode [01]"
        let otherRule = "# Existing permission"
        for (index, rules) in [[pmsetRule], [otherRule, pmsetRule], []].enumerated() {
            let testDirectory = directory.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
            let destination = SudoersPermissionAlert.destination(directory: testDirectory.path)
            if !rules.isEmpty {
                try Data((rules.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: destination))
            }
            for repetition in 1...2 {
                if repetition > 1 {
                    // The real installer runs as root; allow the unprivileged test to append again.
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination)
                }
                let installer = Process()
                installer.executableURL = URL(fileURLWithPath: "/bin/sh")
                installer.arguments = ["-c", repetition == 1
                    ? SudoersPermissionAlert.command(rule: rule, directory: testDirectory.path)
                    : SudoersPermissionAlert.script(rule: rule, directory: testDirectory.path)]
                installer.environment = ProcessInfo.processInfo.environment.merging([
                    "PATH": "\(directory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                ]) { _, new in new }
                try installer.run()
                installer.waitUntilExit()
                precondition(installer.terminationStatus == 0)

                let installed = try String(contentsOfFile: destination, encoding: .utf8)
                let expected = rules + Array(repeating: rule, count: repetition)
                precondition(installed.split(separator: "\n").map(String.init) == expected)

                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
                check.arguments = ["-cf", destination]
                try check.run()
                check.waitUntilExit()
                precondition(check.terminationStatus == 0)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination)
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/bin/sh")
            pmset.arguments = ["-c", SudoersPermissionAlert.script(rule: pmsetRule, directory: testDirectory.path)]
            try pmset.run()
            pmset.waitUntilExit()
            precondition(pmset.terminationStatus == 0)
            let combined = try String(contentsOfFile: destination, encoding: .utf8)
            precondition(combined.split(separator: "\n").map(String.init) == rules + [rule, rule, pmsetRule])
            let finalCheck = Process()
            finalCheck.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
            finalCheck.arguments = ["-cf", destination]
            try finalCheck.run()
            finalCheck.waitUntilExit()
            precondition(finalCheck.terminationStatus == 0)
        }
        print("PASS: both permission commands append without replacing existing entries")
    }

    private static func checkInstallerExecution(in directory: URL, rule: String) async throws {
        let executable = directory.appendingPathComponent("fake-osascript")
        let arguments = directory.appendingPathComponent("osascript-arguments")
        let scenarios: [(Int, String, SudoersPermissionAlert.InstallResult)] = [
            (0, "", .success),
            (1, "User canceled. (-128)", .cancelled),
            (2, "Installation failed", .failure("Installation failed")),
            (2, "(-128)", .failure("(-128)")),
        ]

        for (exitCode, output, expected) in scenarios {
            let contents = """
            #!/bin/sh
            printf '%s\\n' "$1" "$2" > '\(arguments.path)'
            printf '%s' '\(output)' >&2
            exit \(exitCode)
            """
            try Data(contents.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let result = await SudoersPermissionAlert.install(rule: rule, executableURL: executable)
            precondition(result == expected)
            let passedArguments = try String(contentsOf: arguments, encoding: .utf8)
            precondition(passedArguments.hasPrefix("-e\ndo shell script \""))
            precondition(passedArguments.contains("--samplers cpu_power"))
            precondition(passedArguments.contains("with administrator privileges"))
        }

        let missing = directory.appendingPathComponent("missing-osascript")
        if case .failure(let output) = await SudoersPermissionAlert.install(rule: rule, executableURL: missing) {
            precondition(!output.isEmpty)
        } else {
            preconditionFailure("A missing installer executable must report an error")
        }
        print("PASS: permission installer success, cancellation, failure and launch error")
    }
}
