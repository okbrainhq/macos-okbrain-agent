// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "OkBrainMacOSAgent",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "OkBrainMacOSAgent", targets: ["OkBrainMacOSAgent"]),
    .library(name: "OkBrainMacOSAgentCore", targets: ["OkBrainMacOSAgentCore"])
  ],
  targets: [
    .target(
      name: "OkBrainMacOSAgentCore"
    ),
    .executableTarget(
      name: "OkBrainMacOSAgent",
      dependencies: ["OkBrainMacOSAgentCore"]
    ),
    .executableTarget(
      name: "PermissionRuleEngineTests",
      dependencies: ["OkBrainMacOSAgentCore"],
      path: "Tests/PermissionRuleEngineTests"
    ),
    .executableTarget(
      name: "DisplayWakeTests",
      dependencies: ["OkBrainMacOSAgentCore"],
      path: "Tests/DisplayWakeTests"
    ),
    .testTarget(
      name: "OkBrainMacOSAgentCoreTests",
      dependencies: ["OkBrainMacOSAgentCore"],
      path: "Tests/OkBrainMacOSAgentCoreTests"
    )
  ]
)
