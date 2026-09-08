// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Steno",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "StenoCore", targets: ["StenoCore"]),
        .executable(name: "Steno", targets: ["StenoApp"])
    ],
    targets: [
        .target(
            name: "StenoCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("Speech"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "StenoApp",
            dependencies: ["StenoCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ArbitrationStateMachineChecks",
            dependencies: ["StenoCore"],
            path: "Tests/ArbitrationStateMachineChecks"
        )
    ]
)
