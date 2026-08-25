import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let mode = environment["FAKE_GROK_MODE"] ?? "success"
let transcriptPath = environment["FAKE_GROK_TRANSCRIPT"]
let pidPath = environment["FAKE_GROK_PID"]
if mode == "ignore_term_timeout" {
    signal(SIGTERM, SIG_IGN)
}

func appendTranscript(_ value: Any) {
    guard let transcriptPath,
          let data = try? JSONSerialization.data(withJSONObject: value),
          let line = "\(String(decoding: data, as: UTF8.self))\n".data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: transcriptPath) {
        FileManager.default.createFile(atPath: transcriptPath, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: transcriptPath)) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line)
}

if let pidPath {
    try? String(ProcessInfo.processInfo.processIdentifier).write(
        toFile: pidPath,
        atomically: true,
        encoding: .utf8
    )
}
appendTranscript(["arguments": arguments])
guard arguments == ["--no-auto-update", "agent", "stdio"] else { exit(64) }

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = request["method"] as? String else { continue }
    appendTranscript(request)
    let id = request["id"] as? Int ?? 0

    if method == "initialize" {
        switch mode {
        case "early_eof": exit(0)
        case "malformed":
            print("not-json")
            fflush(stdout)
            exit(0)
        case "timeout", "ignore_term_timeout":
            Thread.sleep(forTimeInterval: 3)
            exit(0)
        default:
            print(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#)
            fflush(stdout)
        }
    } else if method == "_x.ai/billing" {
        if mode == "inherited_stderr" {
            var childPID: pid_t = 0
            var childArguments: [UnsafeMutablePointer<CChar>?] = [
                strdup("/bin/sh"),
                strdup("-c"),
                strdup("trap '' TERM; sleep 3"),
                nil,
            ]
            defer {
                for argument in childArguments.compactMap({ $0 }) { free(argument) }
            }
            let spawnResult = childArguments.withUnsafeMutableBufferPointer { arguments in
                posix_spawn(
                    &childPID,
                    "/bin/sh",
                    nil,
                    nil,
                    arguments.baseAddress!,
                    environ
                )
            }
            if spawnResult == 0,
               let childPIDPath = environment["FAKE_GROK_CHILD_PID"] {
                try? String(childPID).write(
                    toFile: childPIDPath,
                    atomically: true,
                    encoding: .utf8
                )
                for _ in 0..<50 where !FileManager.default.fileExists(atPath: childPIDPath) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        switch mode {
        case "method_error":
            print(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"missing"}}"#)
        case "auth_error":
            print(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"private auth detail"}}"#)
        case "stderr_error":
            FileHandle.standardError.write(Data(repeating: 88, count: 10_000))
            print(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"private backend detail"}}"#)
        case "deprecated":
            print(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"monthlyLimit":{"val":200},"used":{"val":50},"billingPeriodEnd":"2026-09-01T00:00:00Z"},"onDemandEnabled":false}}"#)
        case "no_on_demand":
            print(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-01T00:00:00Z"},"onDemandCap":{"val":0},"onDemandUsed":{"val":9}},"onDemandEnabled":false}}"#)
        case "fractional_offset":
            print(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-08-25T07:07:27.291497+00:00"}},"onDemandEnabled":false}}"#)
        case "fractional_z":
            print(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-08-25T07:07:27.291497Z"}},"onDemandEnabled":false}}"#)
        default:
            print(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-01T00:00:00Z"},"onDemandCap":{"val":80},"onDemandUsed":{"val":20}},"onDemandEnabled":true}}"#)
        }
        fflush(stdout)
        if mode == "success_persistent" {
            Thread.sleep(forTimeInterval: 5)
        }
        exit(0)
    } else {
        print("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"error\":{\"code\":-32601,\"message\":\"unexpected\"}}")
        fflush(stdout)
        exit(0)
    }
}
