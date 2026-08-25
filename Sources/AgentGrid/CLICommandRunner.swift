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
        let spawned: SpawnedCommand
        do {
            spawned = try spawn(command)
        } catch {
            return .failedToStart(error.localizedDescription)
        }

        let deadline = clock.now.advanced(by: command.timeout)
        var waitStatus: Int32 = 0
        while true {
            let waitResult = waitpid(spawned.processID, &waitStatus, WNOHANG)
            if waitResult == spawned.processID {
                let output = spawned.outputFileDescriptor.map(boundedOutput) ?? ""
                return .exited(status: exitStatus(waitStatus), output: output)
            }
            if waitResult == -1 && errno != EINTR {
                if let outputFileDescriptor = spawned.outputFileDescriptor {
                    Darwin.close(outputFileDescriptor)
                }
                return .failedToStart(String(cString: strerror(errno)))
            }

            if Task.isCancelled {
                terminateProcessGroup(spawned)
                return .cancelled
            }
            if clock.now >= deadline {
                terminateProcessGroup(spawned)
                return .timedOut
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch is CancellationError {
                terminateProcessGroup(spawned)
                return .cancelled
            } catch {
                terminateProcessGroup(spawned)
                return .failedToStart(error.localizedDescription)
            }
        }
    }

    private func spawn(_ command: CLICommand) throws -> SpawnedCommand {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw RunnerError.posix("Could not initialize process attributes")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw RunnerError.posix("Could not isolate updater process group")
        }

        let nullFileDescriptor = Darwin.open("/dev/null", O_RDWR)
        guard nullFileDescriptor >= 0 else {
            throw RunnerError.posix(String(cString: strerror(errno)))
        }
        defer { Darwin.close(nullFileDescriptor) }

        var pipeFileDescriptors: [Int32] = [-1, -1]
        if command.capturesOutput {
            let result = pipeFileDescriptors.withUnsafeMutableBufferPointer {
                Darwin.pipe($0.baseAddress!)
            }
            guard result == 0 else {
                throw RunnerError.posix(String(cString: strerror(errno)))
            }
        }

        let readFileDescriptor = command.capturesOutput ? pipeFileDescriptors[0] : nil
        let writeFileDescriptor = command.capturesOutput
            ? pipeFileDescriptors[1]
            : nullFileDescriptor
        var parentMustClosePipe = command.capturesOutput
        defer {
            if parentMustClosePipe {
                Darwin.close(pipeFileDescriptors[0])
                Darwin.close(pipeFileDescriptors[1])
            }
        }

        guard posix_spawn_file_actions_adddup2(
            &fileActions,
            nullFileDescriptor,
            STDIN_FILENO
        ) == 0,
            posix_spawn_file_actions_adddup2(
                &fileActions,
                writeFileDescriptor,
                STDOUT_FILENO
            ) == 0,
            posix_spawn_file_actions_adddup2(
                &fileActions,
                writeFileDescriptor,
                STDERR_FILENO
            ) == 0 else {
            throw RunnerError.posix("Could not configure updater process streams")
        }
        if command.capturesOutput {
            guard posix_spawn_file_actions_addclose(
                &fileActions,
                pipeFileDescriptors[0]
            ) == 0,
                posix_spawn_file_actions_addclose(
                    &fileActions,
                    pipeFileDescriptors[1]
                ) == 0 else {
                throw RunnerError.posix("Could not configure updater output capture")
            }
        }

        var processID: pid_t = 0
        let arguments = [command.executable.path] + command.arguments
        let environmentVariables = TerminalEnvironment.processVariables(environment)
        let argumentVector = CStringArray(arguments)
        let environmentVector = CStringArray(environmentVariables)
        defer {
            argumentVector.deallocate()
            environmentVector.deallocate()
        }
        let spawnResult = posix_spawn(
            &processID,
            command.executable.path,
            &fileActions,
            &attributes,
            argumentVector.pointer,
            environmentVector.pointer
        )
        guard spawnResult == 0 else {
            throw RunnerError.posix(String(cString: strerror(spawnResult)))
        }

        if command.capturesOutput {
            Darwin.close(pipeFileDescriptors[1])
            parentMustClosePipe = false
        }
        return SpawnedCommand(
            processID: processID,
            outputFileDescriptor: readFileDescriptor
        )
    }

    private func terminateProcessGroup(_ command: SpawnedCommand) {
        _ = Darwin.kill(-command.processID, SIGTERM)

        let graceDeadline = clock.now.advanced(by: .milliseconds(25))
        var waitStatus: Int32 = 0
        var rootWasReaped = false
        while clock.now < graceDeadline {
            let waitResult = waitpid(command.processID, &waitStatus, WNOHANG)
            if waitResult == command.processID {
                rootWasReaped = true
                break
            }
            if Darwin.kill(-command.processID, 0) == -1 && errno == ESRCH {
                break
            }
            usleep(10_000)
        }

        if Darwin.kill(-command.processID, 0) == 0 || errno != ESRCH {
            _ = Darwin.kill(-command.processID, SIGKILL)
        }
        if !rootWasReaped {
            while waitpid(command.processID, &waitStatus, 0) == -1 && errno == EINTR {}
        }
        if let outputFileDescriptor = command.outputFileDescriptor {
            Darwin.close(outputFileDescriptor)
        }
    }

    private func boundedOutput(from fileDescriptor: Int32) -> String {
        defer { Darwin.close(fileDescriptor) }
        _ = fcntl(fileDescriptor, F_SETFL, O_NONBLOCK)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count < 4_096 {
            let remaining = min(buffer.count, 4_096 - data.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, remaining)
            }
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno != EINTR {
                break
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func exitStatus(_ waitStatus: Int32) -> Int32 {
        if waitStatus & 0x7f == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + (waitStatus & 0x7f)
    }

}

private struct SpawnedCommand {
    let processID: pid_t
    let outputFileDescriptor: Int32?
}

private enum RunnerError: LocalizedError {
    case posix(String)

    var errorDescription: String? {
        switch self {
        case let .posix(message): message
        }
    }
}

private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[strings.count] = nil
    }

    func deallocate() {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
