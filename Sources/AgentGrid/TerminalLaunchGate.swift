import CoreGraphics
import Darwin
import Foundation
import SwiftTerm

struct TerminalLaunchGate {
    private var hasLaunched = false

    mutating func beginIfReady(
        isWindowPrepared: Bool,
        isAttached: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        guard !hasLaunched,
              isWindowPrepared,
              isAttached,
              width > 0,
              height > 0 else {
            return false
        }

        hasLaunched = true
        return true
    }
}

struct TerminalActivationGate {
    private var wasActive = false

    mutating func shouldClaimFocus(
        isActive: Bool,
        prefersFocus: Bool
    ) -> Bool {
        defer { wasActive = isActive }
        return isActive && !wasActive && prefersFocus
    }
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let userID: uid_t
    let parentPID: pid_t
    let processGroupID: pid_t
}

struct ProcessTreeTerminationResult: Sendable {
    let leader: LocalProcessTerminationResult
    let descendantsObserved: Int
    let survivors: [ProcessIdentity]
    let escalatedToKill: Bool

    var completed: Bool {
        survivors.isEmpty && {
            switch leader {
            case .reaped, .reapedByAnotherOwner, .notRunning: true
            case .waitFailed: false
            }
        }()
    }
}

struct ProcessTreeTerminator: Sendable {
    typealias LeaderTermination = (
        @escaping @Sendable (LocalProcessTerminationResult) -> Void
    ) -> Void

    static let live = ProcessTreeTerminator()

    private static let terminationGraceMicroseconds: useconds_t = 500_000
    private static let forceKillWaitMicroseconds: useconds_t = 1_000_000
    fileprivate static let pollMicroseconds: useconds_t = 10_000

    func beginTermination(
        rootPID: pid_t,
        terminateLeader: LeaderTermination
    ) -> Task<ProcessTreeTerminationResult, Never> {
        let leaderCompletion = LockedLeaderCompletion()
        guard let root = Self.identity(for: rootPID) else {
            terminateLeader { leaderCompletion.complete(with: $0) }
            return Task.detached(priority: .utility) {
                ProcessTreeTerminationResult(
                    leader: leaderCompletion.wait(
                        timeoutMicroseconds: Self.forceKillWaitMicroseconds
                    ) ?? .notRunning,
                    descendantsObserved: 0,
                    survivors: [],
                    escalatedToKill: false
                )
            }
        }

        let initialDescendants = Self.descendants(of: root)
        Self.signal(initialDescendants.reversed(), signal: SIGTERM)
        if Self.identity(for: root.pid) == root {
            _ = Darwin.kill(-root.pid, SIGTERM)
        }
        terminateLeader { leaderCompletion.complete(with: $0) }

        return Task.detached(priority: .utility) {
            Self.finishTermination(
                root: root,
                initialDescendants: initialDescendants,
                leaderCompletion: leaderCompletion
            )
        }
    }

    private static func finishTermination(
        root: ProcessIdentity,
        initialDescendants: [ProcessIdentity],
        leaderCompletion: LockedLeaderCompletion
    ) -> ProcessTreeTerminationResult {
        var observed = Set(initialDescendants)
        if waitForExit(
            root: root,
            observed: &observed,
            leaderCompletion: leaderCompletion,
            timeoutMicroseconds: terminationGraceMicroseconds
        ) {
            return result(
                observed: observed,
                leaderCompletion: leaderCompletion,
                escalated: false
            )
        }

        let liveDescendants = observed.filter { identity(for: $0.pid) == $0 }
        signal(liveDescendants.reversed(), signal: SIGKILL)
        if identity(for: root.pid) == root {
            _ = Darwin.kill(-root.pid, SIGKILL)
            _ = Darwin.kill(root.pid, SIGKILL)
        }
        _ = waitForExit(
            root: root,
            observed: &observed,
            leaderCompletion: leaderCompletion,
            timeoutMicroseconds: forceKillWaitMicroseconds
        )
        return result(
            observed: observed,
            leaderCompletion: leaderCompletion,
            escalated: true
        )
    }

    private static func waitForExit(
        root: ProcessIdentity,
        observed: inout Set<ProcessIdentity>,
        leaderCompletion: LockedLeaderCompletion,
        timeoutMicroseconds: useconds_t
    ) -> Bool {
        var elapsed: useconds_t = 0
        while elapsed < timeoutMicroseconds {
            if identity(for: root.pid) == root {
                observed.formUnion(descendants(of: root))
            }
            let survivors = observed.contains { identity(for: $0.pid) == $0 }
            if !survivors, leaderCompletion.result != nil {
                return true
            }
            usleep(pollMicroseconds)
            elapsed += pollMicroseconds
        }
        return false
    }

    private static func result(
        observed: Set<ProcessIdentity>,
        leaderCompletion: LockedLeaderCompletion,
        escalated: Bool
    ) -> ProcessTreeTerminationResult {
        ProcessTreeTerminationResult(
            leader: leaderCompletion.result ?? .waitFailed(errno: ETIMEDOUT),
            descendantsObserved: observed.count,
            survivors: observed.filter { identity(for: $0.pid) == $0 }.sorted {
                $0.pid < $1.pid
            },
            escalatedToKill: escalated
        )
    }

    private static func signal<C: Collection>(
        _ identities: C,
        signal: Int32
    ) where C.Element == ProcessIdentity {
        for process in identities {
            _ = signalIfIdentityMatches(
                process,
                signal: signal,
                currentIdentity: identity(for:),
                sendSignal: { Darwin.kill($0, $1) }
            )
        }
    }

    @discardableResult
    static func signalIfIdentityMatches(
        _ recorded: ProcessIdentity,
        signal: Int32,
        currentIdentity: (pid_t) -> ProcessIdentity?,
        sendSignal: (pid_t, Int32) -> Int32
    ) -> Bool {
        guard currentIdentity(recorded.pid) == recorded else { return false }
        return sendSignal(recorded.pid, signal) == 0
    }

    private static func descendants(of root: ProcessIdentity) -> [ProcessIdentity] {
        var result: [ProcessIdentity] = []
        var pending = [root]
        var visited = Set([root.pid])
        while let parent = pending.popLast() {
            for childPID in childPIDs(of: parent.pid) where visited.insert(childPID).inserted {
                guard let child = identity(for: childPID), child.parentPID == parent.pid else {
                    continue
                }
                result.append(child)
                pending.append(child)
            }
        }
        return result
    }

    private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let byteCount = proc_listchildpids(parentPID, nil, 0)
        guard byteCount > 0 else { return [] }
        var values = [pid_t](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<pid_t>.size + 8
        )
        let populatedBytes = proc_listchildpids(
            parentPID,
            &values,
            Int32(values.count * MemoryLayout<pid_t>.size)
        )
        guard populatedBytes > 0 else { return [] }
        return Array(values.prefix(Int(populatedBytes))).filter {
            $0 > 0
        }
    }

    private static func identity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected else {
            return nil
        }
        return ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            userID: info.pbi_uid,
            parentPID: pid_t(bitPattern: info.pbi_ppid),
            processGroupID: pid_t(bitPattern: info.pbi_pgid)
        )
    }
}

private final class LockedLeaderCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: LocalProcessTerminationResult?

    var result: LocalProcessTerminationResult? {
        lock.withLock { storedResult }
    }

    func complete(with result: LocalProcessTerminationResult) {
        lock.withLock {
            if storedResult == nil {
                storedResult = result
            }
        }
    }

    func wait(timeoutMicroseconds: useconds_t) -> LocalProcessTerminationResult? {
        var elapsed: useconds_t = 0
        while elapsed < timeoutMicroseconds {
            if let result { return result }
            usleep(ProcessTreeTerminator.pollMicroseconds)
            elapsed += ProcessTreeTerminator.pollMicroseconds
        }
        return result
    }
}
