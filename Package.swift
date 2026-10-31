// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MouseMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MouseMaster", targets: ["MouseMaster"]),
        .executable(name: "mmctl", targets: ["mmctl"]),
    ],
    targets: [
        // HID++ 1.0 / 2.0 over IOKit: transports, request/reply matching, features, receivers.
        .target(
            name: "HIDPP",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Shared by every process: configuration, actions, snapshots, IPC and the pure engines.
        .target(name: "MouseMasterKit"),
        // The background agent: devices, actions, smooth scrolling, menu bar, HUD. It runs
        // as the app's own executable with --agent, so macOS sees a single application.
        .target(
            name: "AgentCore",
            dependencies: ["HIDPP", "MouseMasterKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        // The app: the settings window (SwiftUI), or the agent when started with --agent.
        .executableTarget(
            name: "MouseMaster",
            dependencies: ["AgentCore", "MouseMasterKit"],
            linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("Carbon")]
        ),
        // Command line client and diagnostics.
        .executableTarget(name: "mmctl", dependencies: ["HIDPP", "MouseMasterKit"]),
        .testTarget(name: "HIDPPTests", dependencies: ["HIDPP"]),
        .testTarget(name: "MouseMasterKitTests", dependencies: ["MouseMasterKit"]),
    ]
)
