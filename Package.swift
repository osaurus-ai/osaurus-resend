// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-resend",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-resend", type: .dynamic, targets: ["osaurus_resend"])
    ],
    dependencies: [
        // Pinned EXACTLY: the SDK mirrors the host's frozen ABI layout and
        // must move in lockstep with the reviewed host version.
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "osaurus_resend",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/osaurus_resend"
        ),
        .testTarget(
            name: "osaurus_resend_tests",
            dependencies: [
                "osaurus_resend",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_resend_tests"
        )
    ]
)
