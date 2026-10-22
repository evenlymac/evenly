// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Evenly",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Evenly", targets: ["Evenly"])],
    targets: [
        .target(name: "EvenlyDSP"),
        .executableTarget(name: "Evenly", dependencies: ["EvenlyDSP"]),
        .testTarget(name: "EvenlyDSPTests", dependencies: ["EvenlyDSP"]),
    ]
)
