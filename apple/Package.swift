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
        .binaryTarget(name: "COSMmini", path: "COSMmini.xcframework"),
        .target(name: "OSMmini", dependencies: ["COSMmini"], linkerSettings: [
            .linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedLibrary("resolv"),
        ]),
        .executableTarget(name: "OSMminiDemoCLI", dependencies: ["OSMmini"], path: "Demo", exclude: ["OSMminiDemo.xcodeproj", "Info.plist"]),
        .testTarget(name: "OSMminiTests", dependencies: ["OSMmini"], resources: [.copy("Fixtures")]),
    ], swiftLanguageModes: [.v6]
)
