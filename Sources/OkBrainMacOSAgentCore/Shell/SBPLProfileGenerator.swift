import Foundation

/// Pure generator that turns the live file-permission rules plus the immutable
/// Block base into a Seatbelt (SBPL) sandbox profile string. It performs no I/O
/// and is regenerated on every execution so rule edits are never cached.
///
/// Posture (protocol/08 §4, v1 hybrid):
/// - `(allow default)` is the base so normal shells/builds run reliably. A fully
///   `(deny default)` profile aborts `bash` during process init on current
///   macOS, so v1 starts open and carves out the dangerous directions.
/// - File WRITES are default-deny: `(deny file-write* (subpath "/"))` followed by
///   re-allows for read-write rules and build temp dirs. Read-only rules can
///   therefore be read (default) but not written. No rule → no write (kernel
///   enforced), matching §4.2 for the dangerous direction.
/// - File READS and process EXEC stay open at the kernel level in v1; exec
///   scoping is enforced agent-side by `ShellCommandClassifier` (pre-flight) and
///   read scoping tightens in a later phase. Network is fully open by design
///   (§4.3) and documented in `sh.status`.
/// - The immutable Block list (§4.6) is emitted last as specific `deny` rules so
///   it overrides any broader allow; no rule can relax it.
public struct SBPLProfileGenerator: Sendable {
  /// Executable prefixes that run silently (Allow tier, §4.5). Used by the
  /// pre-flight classifier and reported by `sh.status`; children inherit the
  /// sandbox, so compilers/builds can spawn freely under these.
  public static let trustedExecPrefixes: [String] = [
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/Library/Developer/CommandLineTools/usr/bin",
    "/Applications/Xcode.app/Contents/Developer/usr/bin"
  ]

  /// Immutable Block: never writable, regardless of any file rule (§4.6).
  public static let blockWritePrefixes: [String] = [
    "/System",
    "/private/etc",
    "/private/var/db",
    "/usr/libexec",
    "/usr/share",
    "/Library/Keychains"
  ]

  /// Immutable Block: TCC / system-policy databases must never be read or
  /// written (prevents permission self-granting).
  public static let blockReadWritePrefixes: [String] = [
    "/Library/Application Support/com.apple.TCC",
    "/private/var/db/SystemPolicy"
  ]

  /// Privileged Mach services that are always denied (§4.6).
  public static let blockedMachServices: [String] = [
    "com.apple.authd",
    "com.apple.opendirectoryd",
    "com.apple.securityd",
    "com.apple.syspolicyd"
  ]

  /// Device nodes that normal tools (git, clang, curl, shells) must be able to
  /// write to even though writes are otherwise default-deny.
  public static let writableDeviceNodes: [String] = [
    "/dev/null",
    "/dev/zero",
    "/dev/random",
    "/dev/urandom",
    "/dev/tty",
    "/dev/stdout",
    "/dev/stderr",
    "/dev/fd",
    "/dev/dtracehelper"
  ]

  public init() {}

  /// Builds the SBPL profile text.
  /// - Parameters:
  ///   - fileRules: live file-permission rules (realpath-normalized by the
  ///     caller through `FilePermissionRuleEngine`).
  ///   - tempWritePrefixes: extra writable prefixes for compiler/build temp
  ///     output (e.g. the process `TMPDIR`, realpath-normalized). Documented
  ///     exposure; the Block list still overrides these.
  ///   - userHome: the current user's home directory, used to deny access to
  ///     `~/.ssh`, `~/Library/Keychains`, and the per-user TCC database.
  public func profile(
    fileRules: [FileEditingAllowedRoot],
    tempWritePrefixes: [String] = [],
    userHome: String? = nil
  ) -> String {
    var lines: [String] = []
    lines.append("(version 1)")
    lines.append("(allow default)")

    // ----- File-write scoping: default-deny writes, re-allow rules + temp -----
    lines.append("; file writes are default-deny outside rules/temp (protocol/08 §4.2)")
    lines.append("(deny file-write* (subpath \"/\"))")

    let readWritePrefixes = fileRules.filter { $0.mode.canWrite }.map { $0.path }
    if !readWritePrefixes.isEmpty {
      lines.append("; file rules: read-write")
      lines.append("(allow file-write* \(subpathArgs(readWritePrefixes)))")
    }
    let normalizedTemp = tempWritePrefixes.filter { !$0.isEmpty }
    if !normalizedTemp.isEmpty {
      lines.append("; temp/build output (documented exposure)")
      lines.append("(allow file-write* \(subpathArgs(normalizedTemp)))")
    }
    lines.append("; device nodes tools need to write")
    lines.append("(allow file-write* \(literalArgs(Self.writableDeviceNodes)))")

    // ===== Immutable Block base (emitted last; specific denies override) =====
    lines.append("; ===== immutable block base (protocol/08 §4.6) =====")
    lines.append("(deny file-write* \(subpathArgs(Self.blockWritePrefixes)))")
    lines.append("(deny file-read* file-write* \(subpathArgs(Self.blockReadWritePrefixes)))")
    if let userHome, !userHome.isEmpty {
      let secretPaths = [userHome + "/.ssh", userHome + "/Library/Keychains"]
      lines.append("(deny file-read* file-write* \(subpathArgs(secretPaths)))")
      lines.append("(deny file-read* file-write* \(subpathArgs([userHome + "/Library/Application Support/com.apple.TCC"])))")
    }
    lines.append("(deny authorization-right-obtain)")
    lines.append("(deny nvram*)")
    lines.append("(deny sysctl-write)")
    lines.append("(deny file-write-mount)")
    lines.append("(deny file-write-unmount)")
    lines.append("(deny file-write-setugid)")
    if !Self.blockedMachServices.isEmpty {
      let machArgs = Self.blockedMachServices.map { "(global-name \(sbplString($0)))" }.joined(separator: " ")
      lines.append("(deny mach-lookup \(machArgs))")
    }

    return lines.joined(separator: "\n") + "\n"
  }

  private func subpathArgs(_ paths: [String]) -> String {
    paths.map { "(subpath \(sbplString($0)))" }.joined(separator: " ")
  }

  private func literalArgs(_ paths: [String]) -> String {
    paths.map { "(literal \(sbplString($0)))" }.joined(separator: " ")
  }

  /// Escapes a path for use as an SBPL string literal.
  func sbplString(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
