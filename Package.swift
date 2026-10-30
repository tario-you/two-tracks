// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TwoTracks",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
  ],
  targets: [
    .executableTarget(
      name: "TwoTracks",
      dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
      path: "Sources/TwoTracks",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
