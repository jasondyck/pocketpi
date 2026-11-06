// swift-tools-version: 6.0
// Everything in the app that isn't a view: the JSON pi speaks, the client for
// pocketpi's HTTP API and event stream, and the transcript reducer that turns
// pi's events into the chat on screen. No third-party code, and it builds and
// tests on Linux (ios/test-linux.sh), so most of the app can be worked on
// without a Mac.
import PackageDescription

let package = Package(
    name: "PocketPiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PocketPiKit", targets: ["PocketPiKit"]),
    ],
    targets: [
        .target(name: "PocketPiKit"),
        .testTarget(name: "PocketPiKitTests", dependencies: ["PocketPiKit"]),
    ]
)
