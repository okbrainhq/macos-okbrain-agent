import AppKit
import CoreGraphics
import Foundation

struct CWebPEncoder: Sendable {
  let quality: Int
  let method: Int

  init(quality: Int = 80, method: Int = 4) throws {
    guard (1...100).contains(quality) else {
      throw AgentProtocolError.invalidRequest("WebP quality must be between 1 and 100")
    }
    guard (0...6).contains(method) else {
      throw AgentProtocolError.invalidRequest("WebP method must be between 0 and 6")
    }
    self.quality = quality
    self.method = method
  }

  func encode(_ image: CGImage) throws -> Data {
    guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw AgentProtocolError.captureFailed("Unable to prepare screenshot for WebP encoding")
    }

    let executablePath = try resolveExecutablePath()
    let fileManager = FileManager.default
    let workingDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("okbrain-webp-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workingDirectory) }

    let inputURL = workingDirectory.appendingPathComponent("input.png")
    let outputURL = workingDirectory.appendingPathComponent("output.webp")
    try pngData.write(to: inputURL, options: .atomic)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = [
      "-q", "\(quality)",
      "-m", "\(method)",
      "-quiet",
      inputURL.path,
      "-o", outputURL.path
    ]

    let standardError = Pipe()
    process.standardError = standardError
    process.standardOutput = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw AgentProtocolError.captureFailed("Unable to run cwebp: \(error.localizedDescription)")
    }

    guard process.terminationStatus == 0 else {
      let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
      let errorText = String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = errorText?.isEmpty == false ? ": \(errorText!)" : ""
      throw AgentProtocolError.captureFailed("cwebp failed with exit code \(process.terminationStatus)\(suffix)")
    }

    return try Data(contentsOf: outputURL)
  }

  private func resolveExecutablePath() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [String] = []

    if let configuredPath = environment["MACOS_AGENT_CWEBP_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !configuredPath.isEmpty {
      candidates.append(configuredPath)
    }

    if let bundledPath = Bundle.main.url(forResource: "cwebp", withExtension: nil)?.path {
      candidates.append(bundledPath)
    }

    #if arch(arm64)
    let vendoredArch = "mac-arm64"
    #elseif arch(x86_64)
    let vendoredArch = "mac-x86-64"
    #else
    let vendoredArch = ""
    #endif

    if !vendoredArch.isEmpty {
      candidates.append(
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .appendingPathComponent("vendor/libwebp/1.5.0/\(vendoredArch)/bin/cwebp")
          .path
      )
    }

    let fileManager = FileManager.default
    if let pathValue = environment["PATH"] {
      candidates.append(contentsOf: pathValue
        .split(separator: ":")
        .map { String($0) }
        .filter { !$0.isEmpty }
        .map { URL(fileURLWithPath: $0).appendingPathComponent("cwebp").path })
    }

    for candidate in candidates {
      guard fileManager.isExecutableFile(atPath: candidate) else {
        continue
      }
      return candidate
    }

    throw AgentProtocolError.captureFailed(
      "cwebp was not found. Bundle the vendored libwebp cwebp binary or set MACOS_AGENT_CWEBP_PATH."
    )
  }
}
