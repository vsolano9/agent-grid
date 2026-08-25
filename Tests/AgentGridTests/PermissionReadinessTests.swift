import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentGrid

@MainActor
@Suite("Permission readiness")
struct PermissionReadinessTests {
    @Test("launch and activation preflight are quiet and never open settings")
    func quietPreflight() {
        let accessibility = FakeAccessibilityPermissionClient(results: [false, false])
        let settings = FakePermissionSettingsOpener()
        let readiness = PermissionReadiness(
            accessibility: accessibility,
            settings: settings
        )

        readiness.preflight()
        readiness.preflight()

        #expect(accessibility.promptValues == [false, false])
        #expect(settings.destinations.isEmpty)
        #expect(readiness.issues == [.accessibility])
    }

    @Test("only the explicit Accessibility action prompts and opens its settings")
    func explicitAccessibilityAction() {
        let accessibility = FakeAccessibilityPermissionClient(results: [false, false])
        let settings = FakePermissionSettingsOpener()
        let readiness = PermissionReadiness(
            accessibility: accessibility,
            settings: settings
        )

        readiness.preflight()
        readiness.requestAccessibility()

        #expect(accessibility.promptValues == [false, true])
        #expect(settings.destinations == [.accessibility])
    }

    @Test("a quiet activation preflight clears a resolved Accessibility warning")
    func trustedStatusClearsOnActivation() {
        let accessibility = FakeAccessibilityPermissionClient(results: [false, true])
        let readiness = PermissionReadiness(
            accessibility: accessibility,
            settings: FakePermissionSettingsOpener()
        )

        readiness.preflight()
        #expect(readiness.issues == [.accessibility])
        readiness.preflight()

        #expect(readiness.issues.isEmpty)
        #expect(readiness.isAccessibilityTrusted)
    }

    @Test(arguments: [Int(EACCES), Int(EPERM)])
    func deniedActualFileOperationBecomesSpecificIssue(code: Int) {
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [true]),
            settings: FakePermissionSettingsOpener()
        )

        readiness.reportFileOperationFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
            resource: "protected agent workspace"
        )

        #expect(readiness.issues == [
            .protectedFileAccess(resource: "protected agent workspace"),
        ])
    }

    @Test("a missing file never claims protected-resource permission is absent")
    func missingFileIsNotPermissionFailure() {
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [true]),
            settings: FakePermissionSettingsOpener()
        )

        readiness.reportFileOperationFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            resource: "optional configuration"
        )

        #expect(readiness.issues.isEmpty)
    }

    @Test("Accessibility limitation describes only the unavailable global-key path")
    func preciseCapabilityState() {
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [false]),
            settings: FakePermissionSettingsOpener()
        )

        readiness.preflight()

        #expect(!readiness.capabilities.globalKeyObservation)
        #expect(readiness.capabilities.localEventObservation)
        #expect(readiness.capabilities.globalMouseObservation)
        #expect(readiness.capabilities.oneShotSwitchCommand)
        #expect(PermissionReadinessPresentation.message(for: .accessibility).contains(
            "global keyboard"
        ))
    }

    @Test("protected-file settings open only from the matching explicit action")
    func explicitProtectedFileSettingsAction() {
        let settings = FakePermissionSettingsOpener()
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [true]),
            settings: settings
        )
        let issue = PermissionReadinessIssue.protectedFileAccess(
            resource: "protected agent workspace"
        )

        readiness.openSettings(for: issue)

        #expect(settings.destinations == [.fullDiskAccess])
    }

    @Test("Claude credential-file denial reports readiness and a successful retry clears it")
    func claudeCredentialReadReportsAndClears() async throws {
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [true]),
            settings: FakePermissionSettingsOpener()
        )
        let fileRead = CredentialReadFixture(
            result: .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        )
        let store = ClaudeAccessTokenStore(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/test-home", isDirectory: true),
            fileDataLoader: fileRead.data,
            fallbackAccessTokenLoader: { "fallback-token" },
            permissionReporter: readiness
        )

        #expect(try await store.loadAccessToken() == "fallback-token")
        #expect(readiness.issues == [
            .protectedFileAccess(resource: "Claude credentials"),
        ])

        fileRead.setResult(.success(claudeCredentialData(token: "file-token")))
        #expect(try await store.loadAccessToken() == "file-token")
        #expect(readiness.issues.isEmpty)
    }

    @Test("Cursor credential-database denial reports readiness and a successful retry clears it")
    func cursorCredentialReadReportsAndClears() async throws {
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [true]),
            settings: FakePermissionSettingsOpener()
        )
        let databaseRead = CredentialReadFixture(
            result: .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
        )
        let store = CursorAccessTokenStore(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/test-home", isDirectory: true),
            databaseAccessTokenLoader: databaseRead.token,
            permissionReporter: readiness
        )

        await #expect(throws: NSError.self) {
            _ = try await store.loadAccessToken()
        }
        #expect(readiness.issues == [
            .protectedFileAccess(resource: "Cursor credentials"),
        ])

        databaseRead.setResult(.success(Data("cursor-token".utf8)))
        #expect(try await store.loadAccessToken() == "cursor-token")
        #expect(readiness.issues.isEmpty)
    }

    @Test("showing a permission warning preserves the terminal first responder")
    func warningPreservesTerminalFirstResponder() throws {
        let readiness = PermissionReadiness(
            accessibility: FakeAccessibilityPermissionClient(results: [false]),
            settings: FakePermissionSettingsOpener()
        )
        let terminal = TestTerminalResponder(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let warning = NSHostingView(rootView: PermissionReadinessView(readiness: readiness))
        warning.frame = NSRect(x: 0, y: 240, width: 600, height: 80)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        content.addSubview(terminal)
        content.addSubview(warning)
        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        #expect(window.makeFirstResponder(terminal))
        #expect(window.firstResponder === terminal)

        readiness.preflight()
        warning.layoutSubtreeIfNeeded()

        #expect(readiness.issues == [.accessibility])
        #expect(window.firstResponder === terminal)
    }
}

@MainActor
private final class FakeAccessibilityPermissionClient: AccessibilityPermissionClient {
    private var results: [Bool]
    private(set) var promptValues: [Bool] = []

    init(results: [Bool]) {
        self.results = results
    }

    func isProcessTrusted(prompt: Bool) -> Bool {
        promptValues.append(prompt)
        return results.isEmpty ? false : results.removeFirst()
    }
}

@MainActor
private final class FakePermissionSettingsOpener: PermissionSettingsOpening {
    private(set) var destinations: [PermissionSettingsDestination] = []

    func open(_ destination: PermissionSettingsDestination) {
        destinations.append(destination)
    }
}

private final class CredentialReadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func setResult(_ result: Result<Data, Error>) {
        lock.withLock { self.result = result }
    }

    func data(at _: URL) throws -> Data {
        try lock.withLock { try result.get() }
    }

    func token(at url: URL) throws -> String {
        String(decoding: try data(at: url), as: UTF8.self)
    }
}

@MainActor
private final class TestTerminalResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private func claudeCredentialData(token: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"\#(token)"}}"#.utf8)
}
