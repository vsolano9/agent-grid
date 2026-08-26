import AppKit
import Darwin
import Foundation
@preconcurrency import SwiftTerm

private let mebibyte = 1_024 * 1_024

private enum FixtureError: Error, CustomStringConvertible {
    case invalidArguments
    case memoryReadFailed
    case processRSSExceeded(UInt64, UInt64)
    case descendantRSSExceeded(UInt64, UInt64)
    case processesDidNotExit(Int)

    var description: String {
        switch self {
        case .invalidArguments: "invalid or unsafe arguments"
        case .memoryReadFailed: "could not read process memory"
        case let .processRSSExceeded(actual, limit):
            "fixture RSS exceeded: \(actual / UInt64(mebibyte)) MiB > \(limit / UInt64(mebibyte)) MiB"
        case let .descendantRSSExceeded(actual, limit):
            "descendant RSS exceeded: \(actual / UInt64(mebibyte)) MiB > \(limit / UInt64(mebibyte)) MiB"
        case let .processesDidNotExit(count): "\(count) PTY leaders did not exit before the deadline"
        }
    }
}

private struct Configuration {
    let panes: Int
    let cycles: Int
    let processRSSLimit: UInt64
    let descendantRSSLimit: UInt64
    let timeout: UInt32

    init(_ arguments: [String]) throws {
        func value(_ flag: String) throws -> Int {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1),
                  let result = Int(arguments[index + 1]) else {
                throw FixtureError.invalidArguments
            }
            return result
        }
        panes = try value("--panes")
        cycles = try value("--cycles")
        processRSSLimit = UInt64(try value("--process-rss-limit-mb") * mebibyte)
        descendantRSSLimit = UInt64(try value("--descendant-rss-limit-mb") * mebibyte)
        timeout = UInt32(try value("--timeout-seconds"))
        guard [1, 4, 12, 24].contains(panes),
              (1...3).contains(cycles),
              processRSSLimit <= UInt64(2_048 * mebibyte),
              descendantRSSLimit <= UInt64(1_024 * mebibyte),
              (1...60).contains(Int(timeout)) else {
            throw FixtureError.invalidArguments
        }
    }
}

@MainActor
private final class ProcessTracker: NSObject, @MainActor LocalProcessTerminalViewDelegate {
    var terminated = 0

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { terminated += 1 }
}

private func writeProducerOutput() {
    let output = FileHandle.standardOutput
    let prompt = "\u{1b}[36mVictor@AgentGrid\u{1b}[0m $ repair --status 🚀 日本語 e\u{301}\r\n"
    let realistic = "\u{1b}[32m✓\u{1b}[0m Tool completed — 42 files checked\r\n"
    output.write(Data(prompt.utf8))
    output.write(Data((String(repeating: "L", count: 65_536) + "\r\n").utf8))
    for index in 0..<4_000 {
        output.write(Data("[\(index)] \(realistic)".utf8))
    }

    let rawImage = Data(repeating: 0x7f, count: 256 * 256 * 4)
    let encoded = [UInt8](rawImage.base64EncodedData())
    for imageID in 1...8 {
        var offset = 0
        var first = true
        while offset < encoded.count {
            let end = min(offset + 4_096, encoded.count)
            let final = end == encoded.count
            let control = first
                ? "\u{1b}_Ga=T,f=32,s=256,v=256,i=\(imageID),m=\(final ? 0 : 1);"
                : "\u{1b}_Gm=\(final ? 0 : 1);"
            var sequence = Data(control.utf8)
            sequence.append(contentsOf: encoded[offset..<end])
            sequence.append(contentsOf: [0x1b, 0x5c])
            output.write(sequence)
            first = false
            offset = end
        }
    }
    sleep(5)
}

private func processRSS() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw FixtureError.memoryReadFailed }
    return info.resident_size
}

private func descendantRSS(_ pids: [pid_t]) -> UInt64 {
    pids.reduce(0) { total, pid in
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expected) == expected else {
            return total
        }
        return total + info.pti_resident_size
    }
}

@MainActor
private func drainRunLoop(for duration: TimeInterval, sample: () throws -> Void) rethrows {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        try sample()
    }
}

@MainActor
private func runFixture(_ configuration: Configuration) throws {
    alarm(configuration.timeout)
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let baseline = try processRSS()
    var peakProcess = baseline
    var peakDescendants: UInt64 = 0
    var ending: UInt64 = baseline
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

    func sample(_ views: [LocalProcessTerminalView]) throws {
        let process = try processRSS()
        let descendants = descendantRSS(views.map(\.process.shellPid).filter { $0 > 0 })
        peakProcess = max(peakProcess, process)
        peakDescendants = max(peakDescendants, descendants)
        guard process <= configuration.processRSSLimit else {
            throw FixtureError.processRSSExceeded(process, configuration.processRSSLimit)
        }
        guard descendants <= configuration.descendantRSSLimit else {
            throw FixtureError.descendantRSSExceeded(descendants, configuration.descendantRSSLimit)
        }
    }

    for _ in 0..<configuration.cycles {
        let tracker = ProcessTracker()
        var views: [LocalProcessTerminalView] = []
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 1_000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content
        let columns = configuration.panes <= 4 ? 2 : 4
        let rows = Int(ceil(Double(configuration.panes) / Double(columns)))
        let width = content.bounds.width / CGFloat(columns)
        let height = content.bounds.height / CGFloat(rows)

        for index in 0..<configuration.panes {
            var options = TerminalOptions.default
            options.scrollback = 500
            options.kittyImageCacheLimitBytes = 32 * mebibyte
            options.kittyImageTransferLimitBytes = 8 * mebibyte
            let view = LocalProcessTerminalView(
                frame: NSRect(
                    x: CGFloat(index % columns) * width,
                    y: CGFloat(index / columns) * height,
                    width: width,
                    height: height
                ),
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                options: options
            )
            view.processDelegate = tracker
            content.addSubview(view)
            views.append(view)
        }
        window.orderFront(nil)
        window.displayIfNeeded()
        for view in views {
            view.startProcess(executable: executable, args: ["--producer"])
        }

        try drainRunLoop(for: 1.5) { try sample(views) }
        for (index, view) in views.enumerated() {
            view.isHidden = index >= 4
        }
        try drainRunLoop(for: 0.25) { try sample(views) }
        for view in views { view.terminate() }
        try drainRunLoop(for: 2.0) { try sample(views) }
        guard tracker.terminated == configuration.panes else {
            throw FixtureError.processesDidNotExit(configuration.panes - tracker.terminated)
        }

        for view in views { view.removeFromSuperview() }
        views.removeAll()
        window.orderOut(nil)
        window.close()
        try drainRunLoop(for: 0.5) {
            ending = try processRSS()
            peakProcess = max(peakProcess, ending)
        }
    }

    alarm(0)
    let result: [String: Any] = [
        "baseline_process_rss_mib": Double(baseline) / Double(mebibyte),
        "cycles": configuration.cycles,
        "ending_process_rss_mib": Double(ending) / Double(mebibyte),
        "panes": configuration.panes,
        "peak_descendant_rss_mib": Double(peakDescendants) / Double(mebibyte),
        "peak_process_rss_mib": Double(peakProcess) / Double(mebibyte),
        "process_rss_limit_mib": Double(configuration.processRSSLimit) / Double(mebibyte),
        "descendant_rss_limit_mib": Double(configuration.descendantRSSLimit) / Double(mebibyte)
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

if CommandLine.arguments.contains("--producer") {
    writeProducerOutput()
    Darwin.exit(0)
}

do {
    let configuration = try Configuration(CommandLine.arguments)
    try MainActor.assumeIsolated { try runFixture(configuration) }
} catch {
    fputs("TerminalViewMemoryStressFixture: \(error)\n", stderr)
    Darwin.exit(1)
}
