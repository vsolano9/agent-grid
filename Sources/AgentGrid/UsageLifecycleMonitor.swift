import AppKit
import Foundation
import Network

@MainActor
final class UsageLifecycleMonitor {
    func events() -> AsyncStream<UsageLifecycleEvent> {
        AsyncStream { continuation in
            let notificationCenter = NotificationCenter.default
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            var observers: [(NotificationCenter, NSObjectProtocol)] = []

            observers.append((notificationCenter, notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.becameActive)
            }))
            observers.append((notificationCenter, notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.becameInactive)
            }))
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.workspaceWake)
            }))
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.screenWake)
            }))

            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { path in
                continuation.yield(
                    path.status == .satisfied ? .networkSatisfied : .networkUnsatisfied
                )
            }
            pathMonitor.start(queue: DispatchQueue(label: "AgentGrid.UsageLifecycle.Network"))

            let owner = UsageLifecycleOwner(
                observers: observers,
                pathMonitor: pathMonitor
            )
            continuation.onTermination = { _ in owner.cancel() }
        }
    }
}

private final class UsageLifecycleOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [(NotificationCenter, NSObjectProtocol)]
    private var pathMonitor: NWPathMonitor?

    init(
        observers: [(NotificationCenter, NSObjectProtocol)],
        pathMonitor: NWPathMonitor
    ) {
        self.observers = observers
        self.pathMonitor = pathMonitor
    }

    func cancel() {
        let resources = lock.withLock { () -> (
            [(NotificationCenter, NSObjectProtocol)], NWPathMonitor?
        ) in
            let resources = (observers, pathMonitor)
            observers = []
            pathMonitor = nil
            return resources
        }
        resources.0.forEach { center, observer in
            center.removeObserver(observer)
        }
        resources.1?.cancel()
    }

    deinit {
        cancel()
    }
}
