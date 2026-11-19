// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Speech runs on the Mac through two prebuilt engines that scripts/fetch-engine.sh puts in Vendor/: whisper.cpp (names the
// language) and sherpa-onnx (Parakeet, Parakeet v3 and X-ASR write the words).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
  name: "WisprFree",
  platforms: [.macOS(.v15)],
  targets: [
    .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
    .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    .executableTarget(
      name: "WisprFree",
      dependencies: ["CSherpaOnnx", "whisper"],
      path: "Sources/WisprFree",
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .unsafeFlags([
          "-L\(root)/Vendor/sherpa/lib",
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
          "-Xlinker", "-rpath", "-Xlinker", "\(root)/Vendor/sherpa/lib",
        ]),
      ]
    ),
  ]
)
