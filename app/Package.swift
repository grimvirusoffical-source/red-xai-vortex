// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Dolphino",
  platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "Dolphino", path: "Sources/Dolphino")]
)
