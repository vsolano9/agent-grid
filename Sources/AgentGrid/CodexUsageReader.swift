import Foundation

actor CodexUsageReader: ProviderQuotaReading {
    let executable: URL
    let environment: [String: String]

    init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    func fetchRemainingPercent() async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { try await self.readFromAppServer() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw CLIUsageError.timedOut
            }

            guard let result = try await group.next() else {
                throw CLIUsageError.processEnded
            }
            group.cancelAll()
            return result
        }
    }

    private func readFromAppServer() async throws -> Int {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        try write(
            """
            {"id":1,"method":"initialize","params":{"clientInfo":{"name":"agentgrid","title":"AgentGrid","version":"\(version)"}}}
            """,
            to: input.fileHandleForWriting
        )

        var requestedRateLimits = false
        for try await line in output.fileHandleForReading.bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(CodexProtocolEnvelope.self, from: data) else {
                continue
            }

            if envelope.id == 1, !requestedRateLimits {
                requestedRateLimits = true
                try write(#"{"method":"initialized"}"#, to: input.fileHandleForWriting)
                try write(
                    #"{"id":2,"method":"account/rateLimits/read"}"#,
                    to: input.fileHandleForWriting
                )
            } else if envelope.id == 2 {
                return try CodexUsageResponseParser.parse(line)
            }
        }

        throw CLIUsageError.processEnded
    }

    private func write(_ line: String, to handle: FileHandle) throws {
        guard let data = "\(line)\n".data(using: .utf8) else {
            throw CLIUsageError.invalidResponse
        }
        try handle.write(contentsOf: data)
    }
}

private struct CodexProtocolEnvelope: Decodable {
    let id: Int?
}
