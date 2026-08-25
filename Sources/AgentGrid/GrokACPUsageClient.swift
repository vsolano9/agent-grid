import Darwin
import Dispatch
import Foundation

enum GrokACPUsageError: Error, Equatable {
    case invalidResponse
    case processEnded
    case timedOut
    case methodNotFound
    case authenticationRequired
    case rpcFailure
}

actor GrokACPUsageClient {
    private let executable: URL
    private let environment: [String: String]
    private let timeout: Duration
    private let reapPoll: @Sendable (pid_t) -> GrokACPReapResult

    init(
        executable: URL,
        environment: [String: String],
        timeout: Duration = GrokUsageReader.defaultTimeout,
        reapPoll: @escaping @Sendable (pid_t) -> GrokACPReapResult = {
            GrokACPReapResult.poll(processID: $0)
        }
    ) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
        self.reapPoll = reapPoll
    }

    func fetchObservation() async throws -> ProviderUsageObservation {
        let process = try GrokACPProcess.spawn(
            executable: executable,
            arguments: ["--no-auto-update", "agent", "stdio"],
            environment: environment,
            reapPoll: reapPoll
        )
        defer { process.closeParentReadPipes() }

        do {
            let observation = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: GrokACPTaskResult.self) { group in
                    group.addTask {
                        do {
                            return .observation(try await Self.exchange(
                                input: process.input,
                                output: process.output
                            ))
                        } catch {
                            process.requestTermination()
                            await process.terminateAndReap()
                            if process.didTimeOut { throw GrokACPUsageError.timedOut }
                            throw error
                        }
                    }
                    group.addTask {
                        try await Self.drainStderr(process.errorFileDescriptor)
                        return .stderrDrained
                    }
                    group.addTask {
                        try await Task.sleep(for: self.timeout)
                        await process.terminateAndReap(didTimeOut: true)
                        throw GrokACPUsageError.timedOut
                    }

                    while let result = try await group.next() {
                        if case .observation(let observation) = result {
                            await process.terminateAndReap()
                            group.cancelAll()
                            return observation
                        }
                    }
                    throw GrokACPUsageError.processEnded
                }
            } onCancel: {
                process.requestTermination()
            }
            await process.terminateAndReap()
            return observation
        } catch {
            process.requestTermination()
            await process.terminateAndReap()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func exchange(
        input: FileHandle,
        output: FileHandle
    ) async throws -> ProviderUsageObservation {
        try write([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": ["name": "agentgrid", "version": appVersion],
            ],
        ], to: input)

        var sentBilling = false
        var sawMalformedLine = false
        for try await line in output.bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (envelope["id"] as? NSNumber)?.intValue else {
                sawMalformedLine = true
                continue
            }
            if let error = envelope["error"] as? [String: Any] {
                throw rpcError(error)
            }
            if id == 1, !sentBilling {
                guard envelope["result"] is [String: Any] else {
                    throw GrokACPUsageError.invalidResponse
                }
                sentBilling = true
                try write([
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "_x.ai/billing",
                    "params": [:],
                ], to: input)
            } else if id == 2 {
                guard let result = envelope["result"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(result) else {
                    throw GrokACPUsageError.invalidResponse
                }
                let data = try JSONSerialization.data(withJSONObject: result)
                return try GrokUsageParser.parseObservation(from: data)
            }
        }
        throw sawMalformedLine
            ? GrokACPUsageError.invalidResponse
            : GrokACPUsageError.processEnded
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw GrokACPUsageError.invalidResponse
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func rpcError(_ error: [String: Any]) -> GrokACPUsageError {
        switch (error["code"] as? NSNumber)?.intValue {
        case -32601: .methodNotFound
        case -32001: .authenticationRequired
        default: .rpcFailure
        }
    }

    nonisolated private static func drainStderr(_ fileDescriptor: Int32) async throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        var retained = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                let retainedCount = min(Int(count), 4_096 - retained.count)
                if retainedCount > 0 {
                    retained.append(contentsOf: buffer.prefix(retainedCount))
                }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum GrokACPTaskResult: Sendable {
    case observation(ProviderUsageObservation)
    case stderrDrained
}

enum GrokACPReapResult: Sendable {
    case running
    case reaped
    case noChild

    static func poll(processID: pid_t) -> Self {
        var waitStatus: Int32 = 0
        let result = waitpid(processID, &waitStatus, WNOHANG)
        if result == processID { return .reaped }
        if result == -1, errno == ECHILD { return .noChild }
        return .running
    }
}

final class GrokACPProcess: @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle
    let errorFileDescriptor: Int32

    private let processID: pid_t
    private let inputFileDescriptor: Int32
    private let outputFileDescriptor: Int32
    private let reapPoll: @Sendable (pid_t) -> GrokACPReapResult
    private let lock = NSLock()
    private var lifecycle = Lifecycle.running
    private var timedOut = false
    private var inputClosed = false
    private var outputClosed = false
    private var errorClosed = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    private init(
        processID: pid_t,
        inputFileDescriptor: Int32,
        outputFileDescriptor: Int32,
        errorFileDescriptor: Int32,
        reapPoll: @escaping @Sendable (pid_t) -> GrokACPReapResult
    ) {
        self.processID = processID
        self.inputFileDescriptor = inputFileDescriptor
        self.outputFileDescriptor = outputFileDescriptor
        self.errorFileDescriptor = errorFileDescriptor
        self.reapPoll = reapPoll
        input = FileHandle(fileDescriptor: inputFileDescriptor, closeOnDealloc: false)
        output = FileHandle(fileDescriptor: outputFileDescriptor, closeOnDealloc: false)
    }

    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        reapPoll: @escaping @Sendable (pid_t) -> GrokACPReapResult = {
            GrokACPReapResult.poll(processID: $0)
        }
    ) throws -> GrokACPProcess {
        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard inputPipe.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0,
              outputPipe.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0,
              errorPipe.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
            for descriptor in inputPipe + outputPipe + errorPipe where descriptor >= 0 {
                Darwin.close(descriptor)
            }
            throw GrokACPSpawnError.posix(String(cString: strerror(errno)))
        }

        var parentOwnsAllPipes = true
        defer {
            if parentOwnsAllPipes {
                for descriptor in inputPipe + outputPipe + errorPipe {
                    Darwin.close(descriptor)
                }
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw GrokACPSpawnError.posix("Could not initialize Grok process attributes")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw GrokACPSpawnError.posix("Could not initialize Grok process attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, inputPipe[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, errorPipe[1], STDERR_FILENO) == 0 else {
            throw GrokACPSpawnError.posix("Could not isolate Grok process streams")
        }
        for descriptor in inputPipe + outputPipe + errorPipe {
            guard posix_spawn_file_actions_addclose(&fileActions, descriptor) == 0 else {
                throw GrokACPSpawnError.posix("Could not isolate Grok process streams")
            }
        }

        let argumentVector = GrokCStringArray([executable.path] + arguments)
        let environmentVector = GrokCStringArray(
            TerminalEnvironment.processVariables(environment)
        )
        defer {
            argumentVector.deallocate()
            environmentVector.deallocate()
        }
        var processID: pid_t = 0
        let result = posix_spawn(
            &processID,
            executable.path,
            &fileActions,
            &attributes,
            argumentVector.pointer,
            environmentVector.pointer
        )
        guard result == 0 else {
            throw GrokACPSpawnError.posix(String(cString: strerror(result)))
        }

        Darwin.close(inputPipe[0])
        Darwin.close(outputPipe[1])
        Darwin.close(errorPipe[1])
        parentOwnsAllPipes = false
        return GrokACPProcess(
            processID: processID,
            inputFileDescriptor: inputPipe[1],
            outputFileDescriptor: outputPipe[0],
            errorFileDescriptor: errorPipe[0],
            reapPoll: reapPoll
        )
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    func requestTermination(didTimeOut: Bool = false) {
        let action = lock.withLock { () -> (Bool, Bool, Bool, Bool) in
            if didTimeOut { timedOut = true }
            let closeInput = !inputClosed
            let closeOutput = !outputClosed
            let closeError = !errorClosed
            inputClosed = true
            outputClosed = true
            errorClosed = true
            return (closeInput, closeOutput, closeError, lifecycle != .terminated)
        }
        if action.0 { Darwin.close(inputFileDescriptor) }
        if action.1 { Darwin.close(outputFileDescriptor) }
        if action.2 { Darwin.close(errorFileDescriptor) }
        if action.3 { _ = Darwin.kill(-processID, SIGTERM) }
    }

    func terminateAndReap(didTimeOut: Bool = false) async {
        requestTermination(didTimeOut: didTimeOut)
        let shouldLead = lock.withLock { () -> Bool? in
            switch lifecycle {
            case .terminated:
                return nil
            case .terminating:
                return false
            case .running:
                lifecycle = .terminating
                return true
            }
        }
        guard let shouldLead else { return }
        guard shouldLead else {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if lifecycle == .terminated { return true }
                    terminationWaiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
            return
        }

        let fullyReaped = await reapWithinBound()
        if !fullyReaped {
            GrokACPBackgroundReaper.shared.adopt(
                processID: processID,
                reapPoll: reapPoll
            )
        }
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            lifecycle = .terminated
            defer { terminationWaiters.removeAll() }
            return terminationWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func closeParentReadPipes() {
        let descriptors = lock.withLock { () -> [Int32] in
            var descriptors: [Int32] = []
            if !outputClosed {
                outputClosed = true
                descriptors.append(outputFileDescriptor)
            }
            if !errorClosed {
                errorClosed = true
                descriptors.append(errorFileDescriptor)
            }
            return descriptors
        }
        for descriptor in descriptors { Darwin.close(descriptor) }
    }

    private var processGroupExists: Bool {
        if Darwin.kill(-processID, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func reapWithinBound() async -> Bool {
        let clock = ContinuousClock()
        let termDeadline = clock.now.advanced(by: .milliseconds(100))
        let hardDeadline = clock.now.advanced(by: .milliseconds(750))
        var rootWasReaped = false

        while clock.now < termDeadline {
            rootWasReaped = rootWasReaped || rootReapFinished
            if rootWasReaped, !processGroupExists { return true }
            await Self.pauseBeforeReapPoll()
        }

        if processGroupExists {
            _ = Darwin.kill(-processID, SIGKILL)
        }
        while clock.now < hardDeadline {
            rootWasReaped = rootWasReaped || rootReapFinished
            if rootWasReaped, !processGroupExists { return true }
            await Self.pauseBeforeReapPoll()
        }

        _ = Darwin.kill(-processID, SIGKILL)
        rootWasReaped = rootWasReaped || rootReapFinished
        return rootWasReaped && !processGroupExists
    }

    private var rootReapFinished: Bool {
        switch reapPoll(processID) {
        case .running: false
        case .reaped, .noChild: true
        }
    }

    private static func pauseBeforeReapPoll() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(10)
            ) {
                continuation.resume()
            }
        }
    }

    private enum Lifecycle {
        case running
        case terminating
        case terminated
    }
}

private final class GrokACPBackgroundReaper: @unchecked Sendable {
    static let shared = GrokACPBackgroundReaper()

    private struct Entry: Sendable {
        let processID: pid_t
        let reapPoll: @Sendable (pid_t) -> GrokACPReapResult
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.thechosenvictor.agentgrid.grok-reaper",
        qos: .utility
    )
    private var entries: [UUID: Entry] = [:]

    func adopt(
        processID: pid_t,
        reapPoll: @escaping @Sendable (pid_t) -> GrokACPReapResult
    ) {
        let identifier = UUID()
        lock.withLock {
            entries[identifier] = Entry(processID: processID, reapPoll: reapPoll)
        }
        queue.async { [weak self] in
            self?.poll(identifier)
        }
    }

    private func poll(_ identifier: UUID) {
        guard let entry = lock.withLock({ entries[identifier] }) else { return }
        _ = Darwin.kill(-entry.processID, SIGKILL)
        let rootFinished: Bool
        switch entry.reapPoll(entry.processID) {
        case .running:
            rootFinished = false
        case .reaped, .noChild:
            rootFinished = true
        }

        if rootFinished, !Self.processGroupExists(entry.processID) {
            _ = lock.withLock { entries.removeValue(forKey: identifier) }
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            self?.poll(identifier)
        }
    }

    private static func processGroupExists(_ processID: pid_t) -> Bool {
        if Darwin.kill(-processID, 0) == 0 { return true }
        return errno != ESRCH
    }
}

private enum GrokACPSpawnError: LocalizedError {
    case posix(String)

    var errorDescription: String? {
        switch self {
        case .posix(let message): message
        }
    }
}

private final class GrokCStringArray {
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
