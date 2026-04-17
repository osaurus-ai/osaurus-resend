// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-resend",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-resend", type: .dynamic, targets: ["osaurus_resend"])
    ],
    targets: [
        .target(
            name: "osaurus_resend",
            path: "Sources/osaurus_resend"
        ),
        .testTarget(
            name: "osaurus_resend_tests",
            dependencies: ["osaurus_resend"],
            path: "Tests/osaurus_resend_tests"
        )
    ]
)