// swift-tools-version:5.7
import PackageDescription

// Pure measurement logic for the stage UI.
//
// It sits outside InstrumentCore (the protocol layer) so the maths can be tested
// without touching the protocol package:
//
//     swift test --package-path app/ios/StageLogic
//
// The InstrumentIOS app target compiles the exact same source file directly, so
// there is only one implementation.
let package = Package(
    name: "StageLogic",
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    products: [.library(name: "StageLogic", targets: ["StageLogic"])],
    targets: [
        .target(name: "StageLogic"),
        .testTarget(name: "StageLogicTests", dependencies: ["StageLogic"])
    ]
)
