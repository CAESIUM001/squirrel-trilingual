// SPDX-License-Identifier: GPL-3.0-or-later
// Only consumes an explicitly supplied static dictionary selection, never IME input.
import AppKit
import Foundation

@main struct GenerateFrenchGlossary {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { fatalError("Usage: generator input.json output.json") }
    let inputs = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    let output = URL(fileURLWithPath: arguments[2])
    let ready: Bool = await withCheckedContinuation { continuation in
      SquirrelSentenceTranslator.french.checkAvailability { continuation.resume(returning: $0) }
    }
    guard ready else { print("ERROR: Chinese-French models not installed"); exit(3) }
    let timeout = Task {
      try? await Task.sleep(nanoseconds: 900_000_000_000)
      guard !Task.isCancelled else { return }
      print("ERROR: static dictionary generation timed out"); fflush(stdout); exit(2)
    }
    var results = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: output))) ?? [:]
    let missing = inputs.filter { results[$0] == nil }
    let started = Date()
    for start in stride(from: 0, to: missing.count, by: 16) {
      let batch = Array(missing[start..<min(start + 16, missing.count)])
      let translations: [String: String] = await withCheckedContinuation { continuation in
        SquirrelSentenceTranslator.french.requestBatch(batch) { continuation.resume(returning: $0) }
      }
      for (source, translation) in translations { results[source] = translation }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(results).write(to: output, options: .atomic)
      if start % 160 == 0 || start + 16 >= missing.count {
        print("Generated \(results.count)/\(inputs.count) entries in \(String(format: "%.2f", Date().timeIntervalSince(started))) seconds")
        fflush(stdout)
      }
      if translations.count != batch.count { print("WARNING: missing \(batch.count - translations.count) translations") }
    }
    timeout.cancel()
    let elapsed = Date().timeIntervalSince(started)
    print("Completed \(results.count) entries in \(String(format: "%.2f", elapsed)) seconds")
    fflush(stdout)
    exit(results.count == inputs.count ? 0 : 1)
  }
}
