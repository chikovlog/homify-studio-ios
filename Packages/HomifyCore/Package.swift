// swift-tools-version:5.9
import PackageDescription

// HomifyCore is the platform-independent heart of Homify Studio:
// project model, timeline editing, keyframes, audio envelopes, render planning
// and persistence. It only depends on Foundation so it can be unit-tested on
// any machine (including Linux CI) and stays fast to compile.
let package = Package(
    name: "HomifyCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "HomifyCore", targets: ["HomifyCore"])
    ],
    targets: [
        .target(name: "HomifyCore"),
        .testTarget(name: "HomifyCoreTests", dependencies: ["HomifyCore"])
    ]
)
