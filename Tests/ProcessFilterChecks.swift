import Foundation

@main
struct ProcessFilterChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        let childPID = child.processIdentifier
        let process = ProcessReading(
            id: .init(pid: childPID, start: 1),
            isBackground: false, cpu: nil, gpu: nil, memory: 0, power: nil
        )
        check(process.matches(name: "", pid: nil), "An empty filter must match every process")
        check(process.matches(name: "LEe", pid: nil), "Names must match substrings without case sensitivity")
        check(!process.matches(name: "Other", pid: nil), "Unrelated names must not match")
        check(process.matches(name: String(childPID), pid: childPID), "An exact PID must match")
        let partialPID = String(childPID).dropLast()
        check(!process.matches(name: String(partialPID), pid: pid_t(partialPID)), "Numbers must not match partial PIDs or names")
        let overflowingPID = "999999999999999999999999"
        check(!process.matches(name: overflowingPID, pid: pid_t(overflowingPID) ?? 0), "An overflowing PID must not match")
        check(process.matches(name: "sleep", pid: nil, processIDs: [childPID]), "Text and application filters must match together")
        check(!process.matches(name: "Other", pid: nil, processIDs: [childPID]), "Application membership must not bypass text filtering")
        check(!process.matches(name: "sleep", pid: nil, processIDs: [0]), "Text matches outside the application must be excluded")
        check(process.matches(name: String(childPID), pid: childPID, processIDs: [childPID]), "An exact PID inside the application must match")
        check(!process.matches(name: String(childPID), pid: childPID, processIDs: [0]), "An exact PID must not bypass the application filter")
        check(!process.matches(name: "", pid: nil, processIDs: []), "An empty application tree must match no processes")

        var snapshot = ProcessSnapshot()
        snapshot.addProcess(pid: 500, parentPID: 1, responsiblePID: 400)
        snapshot.addProcess(pid: 400, parentPID: 300, responsiblePID: 400)
        snapshot.addProcess(pid: 300, parentPID: 200, responsiblePID: 300)
        snapshot.addProcess(pid: 200, parentPID: 100, responsiblePID: 200)
        snapshot.addProcess(pid: 100, parentPID: 1, responsiblePID: 100)
        snapshot.addProcess(pid: 600, parentPID: 1, responsiblePID: 100)
        snapshot.addProcess(pid: 700, parentPID: 600, responsiblePID: -1)
        snapshot.addProcess(pid: 800, parentPID: 700, responsiblePID: 0)
        snapshot.addProcess(pid: 900, parentPID: 1, responsiblePID: 900)
        check(snapshot.processIDs(root: 100, applicationPIDs: [100, 400]) == [100, 200, 300, 600, 700, 800],
              "An application must include descendants and XPC services but exclude another application and its services")
        check(snapshot.processIDs(root: 400, applicationPIDs: [100, 400]) == [400, 500],
              "Selecting a nested application must include its own services without ancestors")
        check(snapshot.processIDs(root: 100, applicationPIDs: [100]) == [100, 200, 300, 400, 500, 600, 700, 800],
              "Changing the application list must update filtering using the same process snapshot")
        snapshot.addProcess(pid: childPID, parentPID: 1, responsiblePID: 100)
        check(process.matches(name: "sleep", pid: nil, processIDs: snapshot.processIDs(root: 100, applicationPIDs: [100, 400])),
              "Text filtering must find a process attributed to the selected application through responsibility")
        check(!process.matches(name: "sleep", pid: nil, processIDs: snapshot.processIDs(root: 400, applicationPIDs: [100, 400])),
              "A matching process attributed to another application must be excluded")
        let sampler = ProcessSampler()
        let running = sampler.sample()
        check(running.childrenByPID.values.contains { $0.contains(child.processIdentifier) },
              "The snapshot must record a running child process")
        child.terminate()
        child.waitUntilExit()
        check(!process.matches(name: "sleep", pid: nil), "Name filtering must query the live process instead of retaining its old name")
        check(!sampler.sample().childrenByPID.values.contains { $0.contains(child.processIdentifier) },
              "Refreshing the snapshot must remove exited children")

        let sample = ProcessSampler().sample()
        let current = sample.readings.first { $0.id.pid == getpid() }
        check(current?.name.isEmpty == false, "A sampled process must provide its system name on demand")
        print("PASS: process filters, parent and responsible links, application boundaries, XPC services and live snapshots")
    }
}
