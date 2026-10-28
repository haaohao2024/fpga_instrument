// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "InstrumentCore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "InstrumentCore", targets: ["InstrumentCore"])],
    targets: [
        .target(name: "InstrumentCore"),
        .testTarget(name: "InstrumentCoreTests", dependencies: ["InstrumentCore"], resources: [.copy("Fixtures")])
    ]
)
