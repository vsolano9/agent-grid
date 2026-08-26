import Darwin
import Foundation
import SwiftTerm

private let bytesPerMegabyte = 1_024 * 1_024

private struct Configuration {
    let paneCount: Int
    let cycleCount: Int
    let imageMegabytesPerPane: Int
    let cacheMegabytesPerPane: Int
    let rssLimitMegabytes: Int
    let timeoutSeconds: UInt32

    init(arguments: [String]) throws {
        func integer(after flag: String) throws -> Int {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1),
                  let value = Int(arguments[index + 1]),
                  value > 0 else {
                throw StressError.invalidArgument(flag)
            }
            return value
        }

        let requestedPaneCount = try integer(after: "--panes")
        let requestedCycleCount = try integer(after: "--cycles")
        let requestedImageMegabytes = try integer(after: "--image-mb-per-pane")
        let requestedCacheMegabytes = try integer(after: "--cache-mb-per-pane")
        let requestedRSSLimitMegabytes = try integer(after: "--rss-limit-mb")
        let requestedTimeoutSeconds = try integer(after: "--timeout-seconds")

        guard [1, 4, 12].contains(requestedPaneCount),
              requestedCycleCount <= 4,
              requestedImageMegabytes <= 96,
              requestedCacheMegabytes <= 320,
              requestedRSSLimitMegabytes <= 1_024,
              requestedTimeoutSeconds <= 60 else {
            throw StressError.invalidWorkload
        }
        paneCount = requestedPaneCount
        cycleCount = requestedCycleCount
        imageMegabytesPerPane = requestedImageMegabytes
        cacheMegabytesPerPane = requestedCacheMegabytes
        rssLimitMegabytes = requestedRSSLimitMegabytes
        timeoutSeconds = UInt32(requestedTimeoutSeconds)
    }
}

private enum StressError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidWorkload
    case rssReadFailed
    case rssLimitExceeded(actual: UInt64, limit: UInt64)

    var description: String {
        switch self {
        case let .invalidArgument(flag): "Missing or invalid \(flag)"
        case .invalidWorkload: "Workload exceeds the fixture's pane, cycle, memory, or time ceiling"
        case .rssReadFailed: "Could not read resident memory"
        case let .rssLimitExceeded(actual, limit):
            "RSS ceiling exceeded: \(actual / UInt64(bytesPerMegabyte)) MiB > \(limit / UInt64(bytesPerMegabyte)) MiB"
        }
    }
}

private final class DiscardingTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { throw StressError.rssReadFailed }
    return info.resident_size
}

private func enforceRSSLimit(_ limit: UInt64, peak: inout UInt64) throws {
    let current = try residentBytes()
    peak = max(peak, current)
    guard current <= limit else {
        throw StressError.rssLimitExceeded(actual: current, limit: limit)
    }
}

private func feedTextWorkload(to terminal: Terminal) {
    let prompt = "\u{1b}[36mVictor@AgentGrid\u{1b}[0m $ repair --status 🚀 日本語 e\u{301}\r\n"
    terminal.feed(text: prompt)
    terminal.feed(text: String(repeating: "L", count: 65_536) + "\r\n")
    let realisticOutput = "\u{1b}[32m✓\u{1b}[0m Tool completed in 0.7s — 42 files checked\r\n"
    for index in 0..<2_000 {
        terminal.feed(text: "[\(index)] \(realisticOutput)")
    }
}

private func feedInlineImage(
    to terminal: Terminal,
    imageID: UInt32,
    encodedPayload: [UInt8]
) {
    let chunkSize = 256 * 1_024
    var offset = 0
    var isFirst = true
    while offset < encodedPayload.count {
        let end = min(offset + chunkSize, encodedPayload.count)
        let isFinal = end == encodedPayload.count
        let control: String
        if isFirst {
            control = "\u{1b}_Ga=t,f=32,s=512,v=512,i=\(imageID),m=\(isFinal ? 0 : 1);"
        } else {
            control = "\u{1b}_Gm=\(isFinal ? 0 : 1);"
        }
        var sequence = [UInt8](control.utf8)
        sequence.append(contentsOf: encodedPayload[offset..<end])
        sequence.append(contentsOf: [0x1b, 0x5c])
        terminal.feed(buffer: sequence[...])
        offset = end
        isFirst = false
    }
}

private func run(_ configuration: Configuration) throws {
    alarm(configuration.timeoutSeconds)

    let rssLimit = UInt64(configuration.rssLimitMegabytes * bytesPerMegabyte)
    let baseline = try residentBytes()
    var peak = baseline
    let rawImage = Data(repeating: 0x7f, count: bytesPerMegabyte)
    let encodedImage = [UInt8](rawImage.base64EncodedData())
    let imagesPerPane = configuration.imageMegabytesPerPane

    for cycle in 0..<configuration.cycleCount {
        try autoreleasepool {
            var delegates: [DiscardingTerminalDelegate] = []
            var terminals: [Terminal] = []
            for _ in 0..<configuration.paneCount {
                let delegate = DiscardingTerminalDelegate()
                var options = TerminalOptions.default
                options.scrollback = 500
                options.kittyImageCacheLimitBytes = configuration.cacheMegabytesPerPane
                    * bytesPerMegabyte
                options.kittyImageTransferLimitBytes = min(
                    8 * bytesPerMegabyte,
                    configuration.cacheMegabytesPerPane * bytesPerMegabyte
                )
                delegates.append(delegate)
                terminals.append(Terminal(delegate: delegate, options: options))
            }

            for terminal in terminals {
                feedTextWorkload(to: terminal)
            }
            try enforceRSSLimit(rssLimit, peak: &peak)

            for (paneIndex, terminal) in terminals.enumerated() {
                for imageIndex in 0..<imagesPerPane {
                    let imageID = UInt32(cycle * 10_000 + paneIndex * 1_000 + imageIndex + 1)
                    feedInlineImage(
                        to: terminal,
                        imageID: imageID,
                        encodedPayload: encodedImage
                    )
                    try enforceRSSLimit(rssLimit, peak: &peak)
                }
            }
            _ = delegates.count
        }
        try enforceRSSLimit(rssLimit, peak: &peak)
    }

    alarm(0)
    let ending = try residentBytes()
    let output: [String: Any] = [
        "baseline_rss_mib": Double(baseline) / Double(bytesPerMegabyte),
        "cache_mib_per_pane": configuration.cacheMegabytesPerPane,
        "cycles": configuration.cycleCount,
        "ending_rss_mib": Double(ending) / Double(bytesPerMegabyte),
        "image_mib_per_pane": configuration.imageMegabytesPerPane,
        "panes": configuration.paneCount,
        "peak_rss_mib": Double(peak) / Double(bytesPerMegabyte),
        "rss_limit_mib": configuration.rssLimitMegabytes
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func runAdversarialTransfer(arguments: [String]) throws {
    func integer(after flag: String) throws -> Int {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]),
              value > 0 else {
            throw StressError.invalidArgument(flag)
        }
        return value
    }
    let encodedMegabytes = try integer(after: "--adversarial-encoded-mb")
    let transferMegabytes = try integer(after: "--transfer-limit-mb")
    let rssMegabytes = try integer(after: "--rss-limit-mb")
    let timeoutSeconds = try integer(after: "--timeout-seconds")
    guard encodedMegabytes <= 256,
          transferMegabytes <= 32,
          rssMegabytes <= 512,
          timeoutSeconds <= 60 else {
        throw StressError.invalidWorkload
    }
    alarm(UInt32(timeoutSeconds))
    let delegate = DiscardingTerminalDelegate()
    var options = TerminalOptions.default
    options.kittyImageCacheLimitBytes = 32 * bytesPerMegabyte
    options.kittyImageTransferLimitBytes = transferMegabytes * bytesPerMegabyte
    let terminal = Terminal(delegate: delegate, options: options)
    let baseline = try residentBytes()
    var peak = baseline
    let limit = UInt64(rssMegabytes * bytesPerMegabyte)
    terminal.feed(text: "\u{1b}_Ga=q,f=24,s=1,v=1,i=1;")
    let chunk = [UInt8](repeating: UInt8(ascii: "A"), count: 4_096)
    for index in 0..<(encodedMegabytes * bytesPerMegabyte / chunk.count) {
        terminal.feed(buffer: chunk[...])
        if index % 256 == 0 {
            try enforceRSSLimit(limit, peak: &peak)
        }
    }
    terminal.feed(text: "\u{1b}\\")
    try enforceRSSLimit(limit, peak: &peak)
    alarm(0)
    let output: [String: Any] = [
        "adversarial_encoded_mib": encodedMegabytes,
        "baseline_rss_mib": Double(baseline) / Double(bytesPerMegabyte),
        "peak_rss_mib": Double(peak) / Double(bytesPerMegabyte),
        "rss_limit_mib": rssMegabytes,
        "transfer_limit_mib": transferMegabytes
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

do {
    if CommandLine.arguments.contains("--adversarial-encoded-mb") {
        try runAdversarialTransfer(arguments: CommandLine.arguments)
    } else {
        try run(Configuration(arguments: CommandLine.arguments))
    }
} catch {
    fputs("TerminalMemoryStressFixture: \(error)\n", stderr)
    Darwin.exit(1)
}
