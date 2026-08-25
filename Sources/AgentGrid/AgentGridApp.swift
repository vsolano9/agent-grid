import AppKit
import Observation
import SwiftUI

@main
struct AgentGridApp: App {
    @State private var windowState: AgentGridWindowState
    @State private var maintenance: CLIMaintenanceModel
    @State private var usageRuntime: CLIUsageRuntime
    @State private var permissionReadiness: PermissionReadiness
    @State private var focusRuntime: ApplicationFocusRetentionRuntime
    @State private var applicationRuntime: AgentGridApplicationRuntime

    init() {
        let windowState = AgentGridWindowState()
        let maintenance = CLIMaintenanceModel()
        let permissionReadiness = PermissionReadiness()
        let usageRuntime = CLIUsageRuntime(
            model: CLIUsageModel(
                reader: CLIUsageService.live(permissionReporter: permissionReadiness)
            )
        )
        let focusRuntime = ApplicationFocusRetentionRuntime(
            mainWindow: { [weak windowState] in windowState?.mainWindow },
            accessibilityTrusted: { [weak permissionReadiness] in
                permissionReadiness?.isAccessibilityTrusted ?? false
            },
            permissionPreflight: { [weak permissionReadiness] in
                permissionReadiness?.preflight()
            }
        )
        _windowState = State(initialValue: windowState)
        _maintenance = State(initialValue: maintenance)
        _permissionReadiness = State(initialValue: permissionReadiness)
        _usageRuntime = State(initialValue: usageRuntime)
        _focusRuntime = State(initialValue: focusRuntime)
        _applicationRuntime = State(
            initialValue: AgentGridApplicationRuntime(
                shouldRun: { AgentGridRuntimePolicy.shouldRunLiveOperations() },
                maintenance: {
                    await maintenance.start()
                    return maintenance.configuration != nil
                },
                usage: { await usageRuntime.run() },
                focus: { await focusRuntime.run() }
            )
        )
    }

    var body: some Scene {
        Window("AgentGrid", id: "main") {
            Group {
                if let configuration = maintenance.configuration {
                    AgentGridWorkspaceView(
                        configuration: configuration,
                        isWindowPrepared: windowState.isPrepared,
                        maintenanceWarnings: maintenance.warningKinds,
                        usage: usageRuntime.model,
                        refreshUsage: {
                            Task { await usageRuntime.requestManualRefresh() }
                        }
                    )
                } else {
                    CLIMaintenanceView(
                        phase: maintenance.phase,
                        retry: {
                            Task { await maintenance.retry() }
                        }
                    )
                }
            }
                .task { await applicationRuntime.run() }
                .onChange(of: windowState.isPrepared) {
                    focusRuntime.updateMainWindow(
                        isVisibleNormal: windowState.isVisibleNormalWindow
                    )
                }
                .frame(minWidth: 800, minHeight: 520)
                .background(WindowMaximizer(state: windowState))
                .overlay(alignment: .topTrailing) {
                    PermissionReadinessView(readiness: permissionReadiness)
                }
        }
        .defaultSize(width: 1_280, height: 800)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Focus") {
                Button("Allow Next App Switch") {
                    focusRuntime.allowNextAppSwitch()
                }
                .keyboardShortcut("a", modifiers: [.command, .control, .option])
                .disabled(!focusRuntime.isEnabled)

                Button(focusRuntime.isEnabled
                       ? "Disable Focus Retention"
                       : "Enable Focus Retention") {
                    focusRuntime.toggleEnabled()
                }
                .keyboardShortcut("f", modifiers: [.command, .control, .option])
            }
        }
    }
}

enum AgentGridRuntimePolicy {
    static func shouldRunLiveOperations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loadedBundleURLs: [URL] = Bundle.allBundles.map(\.bundleURL),
        fileExists: @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) -> Bool {
        guard let session = environment["XCTestSessionIdentifier"], !session.isEmpty,
              let signaledPath = environment["XCTestBundlePath"], !signaledPath.isEmpty else {
            return true
        }

        let loadedTestBundle = loadedBundleURLs.first { url in
            url.isFileURL
                && url.path.hasPrefix("/")
                && url.pathExtension.lowercased() == "xctest"
                && fileExists(url)
        }
        guard let loadedTestBundle else { return true }

        let signalMatchesLoadedBundle: Bool
        if signaledPath.hasPrefix("/") {
            signalMatchesLoadedBundle = URL(fileURLWithPath: signaledPath).standardizedFileURL
                == loadedTestBundle.standardizedFileURL
        } else {
            signalMatchesLoadedBundle = loadedTestBundle.path.hasSuffix("/\(signaledPath)")
        }
        return !signalMatchesLoadedBundle
    }
}

@MainActor
final class AgentGridApplicationRuntime {
    typealias Operation = @MainActor @Sendable () async -> Void
    typealias MaintenanceOperation = @MainActor @Sendable () async -> Bool

    private let shouldRun: @MainActor @Sendable () -> Bool
    private let usage: Operation
    private let focus: Operation
    private let maintenance: MaintenanceOperation
    private var isRunning = false

    init(
        shouldRun: @escaping @MainActor @Sendable () -> Bool = { true },
        maintenance: @escaping MaintenanceOperation,
        usage: @escaping Operation,
        focus: @escaping Operation
    ) {
        self.shouldRun = shouldRun
        self.maintenance = maintenance
        self.usage = usage
        self.focus = focus
    }

    func run() async {
        guard !isRunning, shouldRun() else { return }
        isRunning = true
        defer { isRunning = false }

        async let focusRun: Void = focus()
        _ = await maintenance()
        if !Task.isCancelled {
            await usage()
        }
        _ = await focusRun
    }
}

@MainActor
@Observable
final class ApplicationFocusRetentionRuntime {
    private let controller: ApplicationFocusRetentionController<ContinuousClock>
    private let monitor: FocusIntentMonitor<ContinuousClock>
    private let permissionPreflight: () -> Void
    private(set) var isEnabled = true

    init(
        mainWindow: @escaping () -> NSWindow?,
        accessibilityTrusted: @escaping () -> Bool,
        permissionPreflight: @escaping () -> Void
    ) {
        let controller = ApplicationFocusRetentionController(
            clock: ContinuousClock(),
            activationClient: AppKitFocusActivationClient(mainWindow: mainWindow)
        )
        self.controller = controller
        self.permissionPreflight = permissionPreflight
        monitor = FocusIntentMonitor(
            controller: controller,
            eventSource: AppKitFocusEventSource(),
            activationSource: AppKitFocusActivationSource(),
            accessibilityTrusted: accessibilityTrusted,
            permissionPreflight: permissionPreflight
        )
    }

    func run() async {
        permissionPreflight()
        monitor.start()
        if NSApp.isActive {
            controller.applicationDidActivate(
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        }
        defer { monitor.stop() }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                break
            }
        }
    }

    func updateMainWindow(isVisibleNormal: Bool) {
        controller.updateMainWindow(isVisibleNormal: isVisibleNormal)
    }

    func allowNextAppSwitch() {
        controller.allowNextAppSwitch()
    }

    func toggleEnabled() {
        isEnabled.toggle()
        controller.setEnabled(isEnabled)
    }

    func refreshAccessibilityTrust() {
        monitor.refreshAccessibilityTrust()
    }
}

@MainActor
private final class CLIUsageRuntime {
    let model: CLIUsageModel

    private let lifecycleMonitor: UsageLifecycleMonitor
    private let coordinator: CLIUsageRefreshCoordinator<ContinuousClock>

    init(
        model: CLIUsageModel = CLIUsageModel(),
        lifecycleMonitor: UsageLifecycleMonitor = UsageLifecycleMonitor()
    ) {
        self.model = model
        self.lifecycleMonitor = lifecycleMonitor
        coordinator = CLIUsageRefreshCoordinator(
            clock: ContinuousClock(),
            jitter: { interval in
                let percent = Int64.random(in: 0...10)
                return interval + (interval / 100) * percent
            },
            refresh: { [model] providers in
                do {
                    return try await model.refresh(providers: providers)
                } catch {
                    return ProviderRefreshOutcome(succeeded: [], failed: providers)
                }
            }
        )
    }

    func run() async {
        await coordinator.run(
            isActive: NSApplication.shared.isActive,
            lifecycleEvents: lifecycleMonitor.events()
        )
    }

    func requestManualRefresh() async {
        await coordinator.requestManualRefresh()
    }
}
