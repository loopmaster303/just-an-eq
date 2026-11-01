// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustAnEQ",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JustAnEQRT", path: "src/JustAnEQRT"),
        .target(name: "JustAnEQCore", path: "src/JustAnEQCore"),
        .executableTarget(name: "JustAnEQ", dependencies: ["JustAnEQCore", "JustAnEQRT"], path: "src/JustAnEQ"),
        // This Mac has CLT rather than Xcode; expose its bundled Swift Testing runtime.
        .testTarget(
            name: "JustAnEQCoreTests", dependencies: ["JustAnEQCore", "JustAnEQRT", "JustAnEQ"], path: "tests/JustAnEQCoreTests",
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags([
                "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
            ])]
        )
    ]
)
