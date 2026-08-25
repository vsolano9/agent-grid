import AppKit
@preconcurrency import ApplicationServices
import Foundation
import Observation

enum PermissionSettingsDestination: Equatable, Sendable {
    case accessibility
    case fullDiskAccess
}

enum PermissionReadinessIssue: Equatable, Hashable, Identifiable, Sendable {
    case accessibility
    case protectedFileAccess(resource: String)

    var id: String {
        switch self {
        case .accessibility:
            "accessibility"
        case let .protectedFileAccess(resource):
            "protected-file:\(resource)"
        }
    }
}

struct PermissionCapabilityAvailability: Equatable, Sendable {
    let globalKeyObservation: Bool
    let localEventObservation: Bool
    let globalMouseObservation: Bool
    let oneShotSwitchCommand: Bool
}

protocol ProtectedFileAccessReporting: Sendable {
    func fileOperationFailed(_ error: any Error, resource: String) async
    func fileOperationSucceeded(resource: String) async
}

@MainActor
protocol AccessibilityPermissionClient: AnyObject {
    func isProcessTrusted(prompt: Bool) -> Bool
}

@MainActor
protocol PermissionSettingsOpening: AnyObject {
    func open(_ destination: PermissionSettingsDestination)
}

@MainActor
final class SystemAccessibilityPermissionClient: AccessibilityPermissionClient {
    func isProcessTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
    }
}

@MainActor
final class SystemPermissionSettingsOpener: PermissionSettingsOpening {
    func open(_ destination: PermissionSettingsDestination) {
        let anchor: String
        switch destination {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .fullDiskAccess:
            anchor = "Privacy_AllFiles"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
@Observable
final class PermissionReadiness: ProtectedFileAccessReporting {
    private let accessibility: AccessibilityPermissionClient
    private let settings: PermissionSettingsOpening
    private var hasPreflightedAccessibility = false
    private var protectedFileResources: Set<String> = []

    private(set) var isAccessibilityTrusted = false

    init(
        accessibility: AccessibilityPermissionClient = SystemAccessibilityPermissionClient(),
        settings: PermissionSettingsOpening = SystemPermissionSettingsOpener()
    ) {
        self.accessibility = accessibility
        self.settings = settings
    }

    var issues: [PermissionReadinessIssue] {
        var result: [PermissionReadinessIssue] = []
        if hasPreflightedAccessibility, !isAccessibilityTrusted {
            result.append(.accessibility)
        }
        result.append(contentsOf: protectedFileResources.sorted().map {
            .protectedFileAccess(resource: $0)
        })
        return result
    }

    var capabilities: PermissionCapabilityAvailability {
        PermissionCapabilityAvailability(
            globalKeyObservation: isAccessibilityTrusted,
            localEventObservation: true,
            globalMouseObservation: true,
            oneShotSwitchCommand: true
        )
    }

    func preflight() {
        hasPreflightedAccessibility = true
        isAccessibilityTrusted = accessibility.isProcessTrusted(prompt: false)
    }

    func requestAccessibility() {
        hasPreflightedAccessibility = true
        isAccessibilityTrusted = accessibility.isProcessTrusted(prompt: true)
        if !isAccessibilityTrusted {
            settings.open(.accessibility)
        }
    }

    func reportFileOperationFailure(_ error: Error, resource: String) {
        guard Self.isPermissionDenied(error) else { return }
        protectedFileResources.insert(resource)
    }

    func clearFileAccessIssue(resource: String) {
        protectedFileResources.remove(resource)
    }

    func fileOperationFailed(_ error: any Error, resource: String) async {
        reportFileOperationFailure(error, resource: resource)
    }

    func fileOperationSucceeded(resource: String) async {
        clearFileAccessIssue(resource: resource)
    }

    func openSettings(for issue: PermissionReadinessIssue) {
        switch issue {
        case .accessibility:
            requestAccessibility()
        case .protectedFileAccess:
            settings.open(.fullDiskAccess)
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let examined = current else { return false }
            if examined.domain == NSPOSIXErrorDomain,
               examined.code == Int(EACCES) || examined.code == Int(EPERM) {
                return true
            }
            if examined.domain == NSCocoaErrorDomain,
               examined.code == NSFileReadNoPermissionError
                || examined.code == NSFileWriteNoPermissionError {
                return true
            }
            current = examined.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

enum PermissionReadinessPresentation {
    static func message(for issue: PermissionReadinessIssue) -> String {
        switch issue {
        case .accessibility:
            "Accessibility is off, so AgentGrid cannot observe global keyboard switch intent. Local AgentGrid shortcuts, outside mouse intent, and Allow Next App Switch remain available."
        case let .protectedFileAccess(resource):
            "macOS denied AgentGrid access to \(resource). Review Full Disk Access or Files & Folders for the fixed AgentGrid app."
        }
    }

    static func actionTitle(for issue: PermissionReadinessIssue) -> String {
        switch issue {
        case .accessibility:
            "Review Accessibility"
        case .protectedFileAccess:
            "Open Privacy Settings"
        }
    }
}
