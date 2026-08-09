// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KidReminder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KidReminder",
            path: "Sources/KidReminder"
        )
    ]
)
