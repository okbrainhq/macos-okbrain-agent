@testable import OkBrainMacOSAgentCore

// The Command Line Tools SDK on the build host does not ship XCTest or Swift
// Testing. Runtime coverage remains in the executable verifier targets; this
// target keeps `swift test --disable-sandbox` buildable on that SDK.
