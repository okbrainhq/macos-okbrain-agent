import Foundation

enum PatchMatchKind: Equatable, Sendable {
  case exact
  case whitespaceNormalized
}

struct PatchMatch: Equatable, Sendable {
  let range: Range<String.Index>
  let line: Int
  let column: Int
  let kind: PatchMatchKind
  let warnings: [String]

  init(
    range: Range<String.Index>,
    line: Int,
    column: Int,
    kind: PatchMatchKind,
    warnings: [String] = []
  ) {
    self.range = range
    self.line = line
    self.column = column
    self.kind = kind
    self.warnings = warnings
  }

  func addingWarning(_ warning: String) -> PatchMatch {
    PatchMatch(range: range, line: line, column: column, kind: kind, warnings: warnings + [warning])
  }
}

struct SourceSpan: Equatable, Sendable {
  let start: String.Index
  let end: String.Index
}

struct NormalizedText: Equatable, Sendable {
  let text: String
  let map: [SourceSpan]
}

struct LineIndex: Sendable {
  private let source: String
  private let lineStarts: [String.Index]

  init(_ source: String) {
    self.source = source

    var starts: [String.Index] = [source.startIndex]
    var index = source.startIndex

    while index < source.endIndex {
      let character = source[index]

      if character == "\n" || character == "\r\n" {
        let next = source.index(after: index)
        starts.append(next)
        index = next
      } else if character == "\r" {
        var next = source.index(after: index)
        if next < source.endIndex, source[next] == "\n" {
          next = source.index(after: next)
        }
        starts.append(next)
        index = next
      } else {
        index = source.index(after: index)
      }
    }

    lineStarts = starts
  }

  func location(at index: String.Index) -> (line: Int, column: Int) {
    var low = 0
    var high = lineStarts.count

    while low < high {
      let middle = (low + high) / 2
      if lineStarts[middle] <= index {
        low = middle + 1
      } else {
        high = middle
      }
    }

    let lineOffset = max(0, low - 1)
    let column = source.distance(from: lineStarts[lineOffset], to: index) + 1
    return (line: lineOffset + 1, column: column)
  }
}

struct TextPatchEngine: Sendable {
  func findMatch(
    oldText: String,
    in source: String,
    startLine: Int?,
    whitespaceNormalizedFallback: Bool
  ) throws -> PatchMatch {
    guard !oldText.isEmpty else {
      throw AgentProtocolError.invalidRequest("Patch oldText must not be empty")
    }

    if let startLine, startLine < 1 {
      throw AgentProtocolError.invalidRequest("Patch startLine must be greater than or equal to 1")
    }

    let lineIndex = LineIndex(source)
    let exactMatches = exactRanges(of: oldText, in: source, lineIndex: lineIndex)
    if !exactMatches.isEmpty {
      return try selectMatch(exactMatches, startLine: startLine)
    }

    if whitespaceNormalizedFallback {
      let normalizedMatches = normalizedWhitespaceRanges(of: oldText, in: source, lineIndex: lineIndex)
      if !normalizedMatches.isEmpty {
        return try selectMatch(normalizedMatches, startLine: startLine)
      }
    }

    throw AgentProtocolError.patchNotFound(patchNotFoundMessage(startLine: startLine))
  }

  private func exactRanges(of needle: String, in source: String, lineIndex: LineIndex) -> [PatchMatch] {
    var matches: [PatchMatch] = []
    var searchRange = source.startIndex..<source.endIndex

    while let range = source.range(of: needle, options: [], range: searchRange) {
      let location = lineIndex.location(at: range.lowerBound)
      matches.append(PatchMatch(range: range, line: location.line, column: location.column, kind: .exact))

      guard range.upperBound < source.endIndex else {
        break
      }
      searchRange = range.upperBound..<source.endIndex
    }

    return matches
  }

  private func normalizedWhitespaceRanges(of needle: String, in source: String, lineIndex: LineIndex) -> [PatchMatch] {
    let normalizedSource = normalizeWithMap(source)
    let normalizedNeedle = normalizeWithMap(needle).text
    guard !normalizedNeedle.isEmpty else {
      return []
    }

    var matches: [PatchMatch] = []
    var searchRange = normalizedSource.text.startIndex..<normalizedSource.text.endIndex

    while let range = normalizedSource.text.range(of: normalizedNeedle, options: [], range: searchRange) {
      let lowerOffset = normalizedSource.text.distance(from: normalizedSource.text.startIndex, to: range.lowerBound)
      let upperOffset = normalizedSource.text.distance(from: normalizedSource.text.startIndex, to: range.upperBound)

      guard lowerOffset < normalizedSource.map.count,
            upperOffset > lowerOffset,
            upperOffset <= normalizedSource.map.count else {
        break
      }

      let firstSpan = normalizedSource.map[lowerOffset]
      let lastSpan = normalizedSource.map[upperOffset - 1]
      let end = extendThroughIgnoredFinalWhitespace(from: lastSpan.end, in: source)
      let location = lineIndex.location(at: firstSpan.start)
      matches.append(PatchMatch(
        range: firstSpan.start..<end,
        line: location.line,
        column: location.column,
        kind: .whitespaceNormalized
      ))

      guard range.upperBound < normalizedSource.text.endIndex else {
        break
      }
      searchRange = range.upperBound..<normalizedSource.text.endIndex
    }

    return matches
  }

  private func normalizeWithMap(_ source: String) -> NormalizedText {
    var normalized = ""
    var map: [SourceSpan] = []
    var lineStart = source.startIndex

    while lineStart < source.endIndex {
      var lineEnd = lineStart
      var lineEndingEnd: String.Index?

      while lineEnd < source.endIndex {
        let character = source[lineEnd]
        if character == "\n" || character == "\r\n" {
          lineEndingEnd = source.index(after: lineEnd)
          break
        }
        if character == "\r" {
          var next = source.index(after: lineEnd)
          if next < source.endIndex, source[next] == "\n" {
            next = source.index(after: next)
          }
          lineEndingEnd = next
          break
        }
        lineEnd = source.index(after: lineEnd)
      }

      var trimEnd = lineEnd
      while trimEnd > lineStart {
        let previous = source.index(before: trimEnd)
        if source[previous] == " " || source[previous] == "\t" {
          trimEnd = previous
        } else {
          break
        }
      }

      var index = lineStart
      while index < trimEnd {
        let next = source.index(after: index)
        normalized.append(source[index])
        map.append(SourceSpan(start: index, end: next))
        index = next
      }

      if let lineEndingEnd {
        normalized.append("\n")
        map.append(SourceSpan(start: trimEnd, end: lineEndingEnd))
        lineStart = lineEndingEnd
      } else {
        lineStart = source.endIndex
      }
    }

    while normalized.last == "\n" {
      normalized.removeLast()
      map.removeLast()
    }

    return NormalizedText(text: normalized, map: map)
  }

  private func extendThroughIgnoredFinalWhitespace(from rawEnd: String.Index, in source: String) -> String.Index {
    var cursor = rawEnd
    var consumedWhitespace = false

    while cursor < source.endIndex, (source[cursor] == " " || source[cursor] == "\t") {
      consumedWhitespace = true
      cursor = source.index(after: cursor)
    }

    guard consumedWhitespace else {
      return rawEnd
    }

    if cursor == source.endIndex || source[cursor] == "\n" || source[cursor] == "\r" || source[cursor] == "\r\n" {
      return cursor
    }
    return rawEnd
  }

  private func selectMatch(_ matches: [PatchMatch], startLine: Int?) throws -> PatchMatch {
    if let startLine {
      let selectedMatches = matches.filter { $0.line == startLine }

      if selectedMatches.isEmpty {
        guard matches.count == 1 else {
          throw AgentProtocolError.ambiguousPatch(startLineMissedAmbiguousPatchMessage(matches: matches, startLine: startLine))
        }

        let match = matches[0]
        return match.addingWarning(startLineFallbackWarning(startLine: startLine, match: match))
      }

      guard selectedMatches.count == 1 else {
        throw AgentProtocolError.ambiguousPatch(ambiguousPatchMessage(matches: selectedMatches, startLine: startLine))
      }

      return selectedMatches[0]
    }

    guard !matches.isEmpty else {
      throw AgentProtocolError.patchNotFound(patchNotFoundMessage(startLine: startLine))
    }

    guard matches.count == 1 else {
      throw AgentProtocolError.ambiguousPatch(ambiguousPatchMessage(matches: matches, startLine: startLine))
    }

    return matches[0]
  }

  private func patchNotFoundMessage(startLine: Int?) -> String {
    if let startLine {
      return "Patch oldText was not found at startLine \(startLine)"
    }
    return "Patch oldText was not found"
  }

  private func startLineFallbackWarning(startLine: Int, match: PatchMatch) -> String {
    "Patch oldText was not found at startLine \(startLine); applied the unique match at \(match.line):\(match.column) instead"
  }

  private func startLineMissedAmbiguousPatchMessage(matches: [PatchMatch], startLine: Int) -> String {
    let locations = matches
      .prefix(10)
      .map { "\($0.line):\($0.column)" }
      .joined(separator: ", ")
    let suffix = matches.count > 10 ? ", …" : ""
    return "Patch oldText was not found at startLine \(startLine), but matched multiple other locations: \(locations)\(suffix); provide the correct startLine or a more specific oldText"
  }

  private func ambiguousPatchMessage(matches: [PatchMatch], startLine: Int?) -> String {
    let locations = matches
      .prefix(10)
      .map { "\($0.line):\($0.column)" }
      .joined(separator: ", ")
    let suffix = matches.count > 10 ? ", …" : ""

    if let startLine {
      return "Patch oldText matched multiple locations at startLine \(startLine): \(locations)\(suffix); provide a more specific oldText"
    }
    return "Patch oldText matched multiple locations: \(locations)\(suffix); provide startLine or a more specific oldText"
  }
}
