import AppKit
import Foundation

struct FocusIntentModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt

    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
}

struct FocusIntentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyDown
        case flagsChanged
        case mouseDown
    }

    let kind: Kind
    let keyCode: UInt16?
    let modifiers: FocusIntentModifiers

    init(
        kind: Kind,
        keyCode: UInt16? = nil,
        modifiers: FocusIntentModifiers = []
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

enum FocusEventScope: Sendable {
    case local
    case global
}

enum FocusIntentClassifier {
    static func isExplicitSwitch(
        _ event: FocusIntentEvent,
        scope: FocusEventScope
    ) -> Bool {
        switch event.kind {
        case .mouseDown:
            return scope == .global
        case .keyDown:
            guard event.modifiers.contains(.command) else { return false }
            return event.keyCode == 48 || event.keyCode == 49
        case .flagsChanged:
            return false
        }
    }
}

@MainActor
protocol FocusEventSource: AnyObject {
    func installLocal(
        handler: @escaping (FocusIntentEvent) -> FocusIntentEvent
    ) -> Int
    func installGlobal(
        includeKeyEvents: Bool,
        handler: @escaping (FocusIntentEvent) -> Void
    ) -> Int
    func remove(_ token: Int)
}

@MainActor
protocol FocusActivationSource: AnyObject {
    func start(handler: @escaping @MainActor @Sendable (pid_t) -> Void)
    func stop()
}

@MainActor
final class FocusIntentMonitor<C: Clock> where C.Duration == Duration {
    private let controller: ApplicationFocusRetentionController<C>
    private let eventSource: FocusEventSource
    private let activationSource: FocusActivationSource
    private let accessibilityTrusted: () -> Bool
    private let permissionPreflight: () -> Void
    private var localToken: Int?
    private var globalToken: Int?
    private var globalIncludesKeys = false
    private var isRunning = false

    init(
        controller: ApplicationFocusRetentionController<C>,
        eventSource: FocusEventSource,
        activationSource: FocusActivationSource,
        accessibilityTrusted: @escaping () -> Bool,
        permissionPreflight: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.eventSource = eventSource
        self.activationSource = activationSource
        self.accessibilityTrusted = accessibilityTrusted
        self.permissionPreflight = permissionPreflight
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        localToken = eventSource.installLocal { [weak controller] event in
            if FocusIntentClassifier.isExplicitSwitch(event, scope: .local) {
                controller?.recordUserSwitchIntent()
            }
            return event
        }
        installGlobalMonitor(includeKeyEvents: accessibilityTrusted())
        activationSource.start { [weak self, weak controller] processIdentifier in
            self?.permissionPreflight()
            self?.refreshAccessibilityTrust()
            controller?.applicationDidActivate(processIdentifier: processIdentifier)
        }
    }

    func refreshAccessibilityTrust() {
        guard isRunning else { return }
        let shouldIncludeKeys = accessibilityTrusted()
        guard shouldIncludeKeys != globalIncludesKeys else { return }
        if let globalToken {
            eventSource.remove(globalToken)
        }
        installGlobalMonitor(includeKeyEvents: shouldIncludeKeys)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let localToken { eventSource.remove(localToken) }
        if let globalToken { eventSource.remove(globalToken) }
        localToken = nil
        globalToken = nil
        activationSource.stop()
        controller.stop()
    }

    private func installGlobalMonitor(includeKeyEvents: Bool) {
        globalIncludesKeys = includeKeyEvents
        globalToken = eventSource.installGlobal(
            includeKeyEvents: includeKeyEvents
        ) { [weak controller] event in
            if FocusIntentClassifier.isExplicitSwitch(event, scope: .global) {
                controller?.recordUserSwitchIntent()
            }
        }
    }
}

@MainActor
final class AppKitFocusEventSource: FocusEventSource {
    private var nextToken = 0
    private var monitors: [Int: Any] = [:]

    func installLocal(
        handler: @escaping (FocusIntentEvent) -> FocusIntentEvent
    ) -> Int {
        let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            Self.handleLocalEvent(event, handler: handler)
        }
        return store(monitor)
    }

    func installGlobal(
        includeKeyEvents: Bool,
        handler: @escaping (FocusIntentEvent) -> Void
    ) -> Int {
        var mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        if includeKeyEvents {
            mask.formUnion([.keyDown, .flagsChanged])
        }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            handler(Self.intentEvent(from: event))
        }
        return store(monitor)
    }

    func remove(_ token: Int) {
        guard let monitor = monitors.removeValue(forKey: token) else { return }
        NSEvent.removeMonitor(monitor)
    }

    private func store(_ monitor: Any?) -> Int {
        let token = nextToken
        nextToken += 1
        if let monitor { monitors[token] = monitor }
        return token
    }

    static func handleLocalEvent(
        _ event: NSEvent,
        handler: (FocusIntentEvent) -> FocusIntentEvent
    ) -> NSEvent {
        _ = handler(intentEvent(from: event))
        return event
    }

    static func intentEvent(from event: NSEvent) -> FocusIntentEvent {
        let kind: FocusIntentEvent.Kind
        let keyCode: UInt16?
        switch event.type {
        case .keyDown:
            kind = .keyDown
            keyCode = event.keyCode
        case .flagsChanged:
            kind = .flagsChanged
            keyCode = nil
        default:
            kind = .mouseDown
            keyCode = nil
        }
        var modifiers: FocusIntentModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return FocusIntentEvent(kind: kind, keyCode: keyCode, modifiers: modifiers)
    }
}

@MainActor
final class AppKitFocusActivationSource: FocusActivationSource {
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func start(handler: @escaping @MainActor @Sendable (pid_t) -> Void) {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                handler(application.processIdentifier)
            }
        }
    }

    func stop() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }
}
