import Darwin
import Foundation

actor CLICommandRunner: CLICommandRunning {
    private let environment: [String: String]
    private let pollInterval: Duration
    private let clock = ContinuousClock()

    init(
        environment: [String: String],
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.environment = environment
        self.pollInterval = pollInterval
    }

    func run(_ command: CLICommand) async -> CLICommandOutcome {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe: Pipe? = command.capturesOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = pipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failedToStart(error.localizedDescription)
        }

        let deadline = clock.now.advanced(by: command.timeout)
        while process.isRunning {
            if Task.isCancelled {
                stop(process)
                return .cancelled
            }

            if clock.now >= deadline {
                stop(process)
                return .timedOut
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch is CancellationError {
                stop(process)
                return .cancelled
            } catch {
                stop(process)
                return .failedToStart(error.localizedDescription)
            }
        }

        let output = pipe.map { boundedOutput(from: $0) } ?? ""
        return .exited(status: process.terminationStatus, output: output)
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let graceDeadline = clock.now.advanced(by: .milliseconds(250))
        while process.isRunning && clock.now < graceDeadline {
            usleep(10_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func boundedOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(4_096)
        return String(decoding: data, as: UTF8.self)
    }
}
