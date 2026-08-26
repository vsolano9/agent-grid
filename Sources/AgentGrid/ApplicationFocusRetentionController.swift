import AppKit
import Foundation

enum FocusRetentionState: Equatable, Sendable {
    case disarmed
    case armed
    case switchLease
    case recovering(processIdentifier: pid_t)
}

@MainActor
protocol FocusActivationClient: AnyObject {
    var processIdentifier: pid_t { get }
    var isApplicationActive: Bool { get }
    var isMainWindowVisibleNormal: Bool { get }
    func activate()
    func rekeyMainWindow()
}

@MainActor
final class ApplicationFocusRetentionController<C: Clock> where C.Duration == Duration {
    private static var leaseDuration: Duration { .milliseconds(1_500) }
    private static var decisionDelay: Duration { .milliseconds(120) }
    private static var retryDelay: Duration { .milliseconds(250) }
    private static var maximumRecoveryDuration: Duration { .seconds(5) }

    private let clock: C
    private let activationClient: FocusActivationClient
    private let beforeRekey: @MainActor @Sendable () async -> Void
    private var appIsActive = false
    private var hasVisibleNormalWindow = false
    private var leaseExpiresAt: C.Instant?
    private var decisionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rekeyTask: Task<Void, Never>?
    private var recoveryDeadline: C.Instant?

    private(set) var state: FocusRetentionState = .disarmed
    private(set) var isEnabled = true

    init(
        clock: C,
        activationClient: FocusActivationClient,
        beforeRekey: @escaping @MainActor @Sendable () async -> Void = {
            await Task.yield()
        }
    ) {
        self.clock = clock
        self.activationClient = activationClient
        self.beforeRekey = beforeRekey
    }

    func updateMainWindow(isVisibleNormal: Bool) {
        hasVisibleNormalWindow = isVisibleNormal
        guard isVisibleNormal else {
            cancelRecovery()
            state = .disarmed
            return
        }
        if state == .disarmed {
            armIfEligible()
        }
    }

    func applicationDidActivate(processIdentifier: pid_t) {
        updateMainWindow(isVisibleNormal: activationClient.isMainWindowVisibleNormal)
        if processIdentifier == activationClient.processIdentifier {
            appIsActive = true
            leaseExpiresAt = nil
            cancelRecovery()
            armIfEligible()
            return
        }

        guard isEnabled,
              hasVisibleNormalWindow,
              state == .armed || state == .switchLease else {
            return
        }
        appIsActive = false
        guard decisionTask == nil else { return }

        let clock = self.clock
        decisionTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.decisionDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.decideActivation(processIdentifier: processIdentifier)
        }
    }

    func recordUserSwitchIntent() {
        guard isEnabled, hasVisibleNormalWindow else {
            return
        }

        if case .recovering = state {
            retryTask?.cancel()
            retryTask = nil
            rekeyTask?.cancel()
            rekeyTask = nil
            leaseExpiresAt = clock.now.advanced(by: Self.leaseDuration)
            state = .switchLease
            return
        }

        guard state == .armed || decisionTask != nil else { return }
        leaseExpiresAt = clock.now.advanced(by: Self.leaseDuration)
        state = .switchLease
    }

    func allowNextAppSwitch() {
        recordUserSwitchIntent()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            armIfEligible()
        } else {
            leaseExpiresAt = nil
            cancelRecovery()
            state = .disarmed
        }
    }

    func stop() {
        appIsActive = false
        leaseExpiresAt = nil
        cancelRecovery()
        state = .disarmed
    }

    private func armIfEligible() {
        guard isEnabled, appIsActive, hasVisibleNormalWindow else {
            state = .disarmed
            return
        }
        state = .armed
    }

    private func decideActivation(processIdentifier: pid_t) {
        decisionTask = nil
        if state == .switchLease,
           let leaseExpiresAt,
           clock.now <= leaseExpiresAt {
            self.leaseExpiresAt = nil
            state = .disarmed
            return
        }

        leaseExpiresAt = nil
        state = .recovering(processIdentifier: processIdentifier)
        recoveryDeadline = clock.now.advanced(by: Self.maximumRecoveryDuration)
        requestActivation(processIdentifier: processIdentifier)
        continueRecoveryIfNeeded(processIdentifier: processIdentifier)
    }

    private func requestActivation(processIdentifier: pid_t) {
        activationClient.activate()
        rekeyTask?.cancel()
        let beforeRekey = self.beforeRekey
        rekeyTask = Task { @MainActor [weak self] in
            await beforeRekey()
            guard !Task.isCancelled,
                  let self,
                  self.state == .recovering(processIdentifier: processIdentifier) else {
                return
            }
            self.activationClient.rekeyMainWindow()
        }
    }

    private func scheduleRetry(processIdentifier: pid_t) {
        retryTask?.cancel()
        let clock = self.clock
        retryTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.retryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard self.state == .recovering(processIdentifier: processIdentifier),
                  !self.activationClient.isApplicationActive else {
                return
            }
            guard let recoveryDeadline = self.recoveryDeadline,
                  self.clock.now < recoveryDeadline else {
                self.recoveryDeadline = nil
                self.state = .disarmed
                return
            }
            self.requestActivation(processIdentifier: processIdentifier)
            self.continueRecoveryIfNeeded(processIdentifier: processIdentifier)
        }
    }

    private func continueRecoveryIfNeeded(processIdentifier: pid_t) {
        guard state == .recovering(processIdentifier: processIdentifier),
              !activationClient.isApplicationActive else {
            return
        }
        scheduleRetry(processIdentifier: processIdentifier)
    }

    private func cancelRecovery() {
        decisionTask?.cancel()
        decisionTask = nil
        retryTask?.cancel()
        retryTask = nil
        rekeyTask?.cancel()
        rekeyTask = nil
        recoveryDeadline = nil
    }
}

@MainActor
final class AppKitFocusActivationClient: FocusActivationClient {
    private let mainWindow: () -> NSWindow?

    init(mainWindow: @escaping () -> NSWindow?) {
        self.mainWindow = mainWindow
    }

    var processIdentifier: pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    var isApplicationActive: Bool { NSApp.isActive }

    var isMainWindowVisibleNormal: Bool {
        guard let window = mainWindow() else { return false }
        return window.isVisible
            && !window.isMiniaturized
            && window.styleMask.contains(.titled)
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func rekeyMainWindow() {
        guard let window = mainWindow(), window.isVisible, !window.isMiniaturized else { return }
        window.makeKeyAndOrderFront(nil)
    }
}
