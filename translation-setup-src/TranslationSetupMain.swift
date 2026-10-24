// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone host for the same public Apple Translation setup UI used by Squirrel.
// No Rime configuration, input source registration, or real input is accessed.

import AppKit
import Foundation

@MainActor
private final class TranslationSetupDelegate: NSObject, NSApplicationDelegate {
  private let probe: Bool
  private let language: String
  private let batch: Bool
  private let isolation: Bool

  init(probe: Bool, language: String, batch: Bool, isolation: Bool) {
    self.probe = probe
    self.language = language
    self.batch = batch
    self.isolation = isolation
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if probe {
      Task {
        if isolation { await runIsolationProbe() }
        else { await runProbe() }
      }
    } else {
      SquirrelSentenceTranslator.shared.prepareLanguages()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  private func runProbe() async {
    let translator = language == "fr" ? SquirrelSentenceTranslator.french : .shared
    let started = Date()
    let timeout = Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled else { return }
      emit(["status": "timeout", "sample": Self.sample, "translation": NSNull()])
      exit(2)
    }
    let ready = await withCheckedContinuation { continuation in
      translator.checkAvailability {
        continuation.resume(returning: $0)
      }
    }
    guard ready else {
      timeout.cancel()
      emit(["status": "model_not_installed", "models_installed": false,
            "target_language": language, "sample": Self.sample, "translation": NSNull()])
      exit(3)
    }
    if batch {
      let samples = ["你好", "学习", "今天下午我們一起去圖書館"]
      let results: [String: String] = await withCheckedContinuation { continuation in
        translator.requestBatch(samples + [samples[0], ""]) {
          continuation.resume(returning: $0)
        }
      }
      timeout.cancel()
      let passed = results.count == samples.count && samples.allSatisfy { results[$0]?.isEmpty == false }
      emit(["status": passed ? "translated" : "translation_failed", "target_language": language,
            "models_installed": true, "translations": results,
            "elapsed_ms": (Date().timeIntervalSince(started) * 1000).rounded()])
      exit(passed ? 0 : 1)
    }
    let translation: String? = await withCheckedContinuation { continuation in
      translator.request(Self.sample) {
        continuation.resume(returning: $0)
      }
    }
    timeout.cancel()
    emit(["status": translation == nil ? "translation_failed" : "translated",
          "models_installed": true, "target_language": language, "sample": Self.sample,
          "translation": translation as Any? ?? NSNull(),
          "elapsed_ms": (Date().timeIntervalSince(started) * 1000).rounded()])
    exit(translation == nil ? 1 : 0)
  }

  private func runIsolationProbe() async {
    let timeout = Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled else { return }
      emit(["status": "timeout", "check": "independent English and French requests"])
      exit(2)
    }
    let results: (String?, [String: String]) = await withCheckedContinuation { continuation in
      var english: String?
      var french: [String: String] = [:]
      var englishDone = false
      var frenchDone = false
      SquirrelSentenceTranslator.shared.request(Self.sample) { result in
        english = result
        englishDone = true
        if frenchDone { continuation.resume(returning: (english, french)) }
      }
      SquirrelSentenceTranslator.french.requestBatch(["你好", Self.sample]) { result in
        french = result
        frenchDone = true
        if englishDone { continuation.resume(returning: (english, french)) }
      }
    }
    timeout.cancel()
    let passed = results.0?.isEmpty == false
    emit(["status": passed ? "passed" : "failed", "english": results.0 as Any? ?? NSNull(),
          "french": results.1, "check": "French request did not cancel English request"])
    exit(passed ? 0 : 1)
  }

  private static let sample = "明天下午我们一起去图书馆学习。"

  private func emit(_ values: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
       let output = String(data: data, encoding: .utf8) {
      print(output)
      fflush(stdout)
    }
  }
}

@main
private struct TranslationSetupMain {
  @MainActor static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let arguments = CommandLine.arguments
    let batch = arguments.contains("--probe-batch")
    let isolation = arguments.contains("--probe-isolation")
    var language = "en"
    if let index = arguments.firstIndex(of: "--language") {
      guard index + 1 < arguments.count, ["en", "fr"].contains(arguments[index + 1]) else {
        print("--language must be en or fr")
        exit(2)
      }
      language = arguments[index + 1]
    }
    let delegate = TranslationSetupDelegate(probe: arguments.contains("--probe") || batch || isolation,
                                             language: language, batch: batch, isolation: isolation)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
