// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "RedXAIVortex",
  platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "Vortex", path: "Sources/Vortex"), .testTarget(name: "VortexTests", dependencies: ["Vortex"], resources: [.copy("Fixtures")])]
)
