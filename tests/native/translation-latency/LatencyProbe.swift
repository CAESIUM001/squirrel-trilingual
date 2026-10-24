import AppKit
import Foundation

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await run() }
  }
  private func run() async {
    let deadline = Task {
      try? await Task.sleep(nanoseconds: 45_000_000_000)
      guard !Task.isCancelled else { return }
      print("{\"error\":\"timeout\"}"); fflush(stdout); exit(2)
    }
    let words = ["你好", "下午", "我们", "一起", "图书馆", "学习", "去", "朋友", "工作"]
    let mixed = ["今天下午我們一起去圖書館"] + Array(words.prefix(8))
    var reports: [[String: Any]] = []
    for (name, inputs) in [("words_cold", words), ("mixed_new_sentence", mixed), ("mixed_repeat", mixed)] {
      let start = Date()
      var first: Double?
      var progressCount = 0
      var cachedCount = 0
      #if OPTIMIZED
      let cached = SquirrelSentenceTranslator.french.cachedTranslations(for: inputs)
      cachedCount = cached.count
      if !cached.isEmpty { first = Date().timeIntervalSince(start) * 1000 }
      #endif
      let result: [String: String] = await withCheckedContinuation { continuation in
        #if OPTIMIZED
        SquirrelSentenceTranslator.french.requestBatch(inputs, progress: { result in
          if !result.isEmpty && first == nil { first = Date().timeIntervalSince(start) * 1000 }
          progressCount += 1
        }) { continuation.resume(returning: $0) }
        #else
        SquirrelSentenceTranslator.french.requestBatch(inputs) { continuation.resume(returning: $0) }
        #endif
      }
      let elapsed = Date().timeIntervalSince(start) * 1000
      precondition(result.count == inputs.count, "all inputs translated")
      reports.append(["scenario": name, "first_result_ms": first ?? elapsed,
                      "all_results_ms": elapsed, "cached_count": cachedCount,
                      "result_count": result.count, "progress_callbacks": progressCount])
    }
    let data = try! JSONSerialization.data(withJSONObject: ["status":"passed", "cases":reports], options: [.prettyPrinted, .sortedKeys])
    print(String(data:data,encoding:.utf8)!); fflush(stdout)
    deadline.cancel(); exit(0)
  }
}
@main private struct LatencyProbe {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Delegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
