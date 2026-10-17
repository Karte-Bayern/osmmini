// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OSMmini",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OSMmini", targets: ["OSMmini"]),
        .executable(name: "OSMminiDemoCLI", targets: ["OSMminiDemoCLI"]),
    ],
    targets: [
        .binaryTarget(name: "COSMmini", path: "apple/COSMmini.xcframework"),
        .target(name: "OSMmini", dependencies: ["COSMmini"], path: "apple/Sources/OSMmini", linkerSettings: [
            .linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedLibrary("resolv"),
        ]),
        .executableTarget(name: "OSMminiDemoCLI", dependencies: ["OSMmini"], path: "apple/Demo", exclude: ["OSMminiDemo.xcodeproj", "Info.plist"]),
        .testTarget(name: "OSMminiTests", dependencies: ["OSMmini"], path: "apple/Tests/OSMminiTests", resources: [.copy("Fixtures")]),
    ], swiftLanguageModes: [.v6]
)
