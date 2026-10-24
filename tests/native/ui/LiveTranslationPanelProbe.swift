import AppKit
import Foundation

@main struct LiveTranslationPanelProbe {
  @MainActor static func main() async {
    _ = NSApplication.shared
    let deadline = Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled else { return }
      print("FAIL: translation/UI test timed out")
      exit(2)
    }
    let source = ProcessInfo.processInfo.environment["SQUIRREL_TEST_SENTENCE"] ?? "明天下午我们一起去图书馆学习。"
    let withFrench = ProcessInfo.processInfo.environment["SQUIRREL_TEST_FRENCH"] == "1"
    let candidates = [source, "明天", "下午", "我们", "一起", "图书馆", "学习", "去", "一起去"]
    let comments = ["", "tomorrow", "afternoon", "we", "together", "library", "study", "go", "go together"]
    let panel = SquirrelPanel(position: NSRect(x: 50, y: 300, width: 1, height: 20))
    let config = SquirrelConfig()
    panel.load(config: config, forDarkMode: false)
    panel.load(config: config, forDarkMode: true)
    panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
                 labels: [], highlighted: 0, page: 0, lastPage: false, update: true)
    let content = panel.contentView!
    let view = content.subviews.compactMap { $0 as? SquirrelView }.first!
    var checks = 0
    func check(_ ok: Bool, _ message: String) {
      precondition(ok, message)
      checks += 1
    }
    let installed = await withCheckedContinuation { continuation in
      SquirrelSentenceTranslator.shared.checkAvailability { ready in continuation.resume(returning: ready) }
    }
    check(installed, "Apple Chinese-English models installed")
    if withFrench {
      let frenchInstalled = await withCheckedContinuation { continuation in
        SquirrelSentenceTranslator.french.checkAvailability { continuation.resume(returning: $0) }
      }
      check(frenchInstalled, "Apple Chinese-French models installed")
    }
    let start = Date()
    let translated: (String?, [String: String]) = await withCheckedContinuation { continuation in
      var english: String?
      var french: [String: String] = [:]
      var completed = 0
      func finish() {
        completed += 1
        if completed == (withFrench ? 2 : 1) { continuation.resume(returning: (english, french)) }
      }
      SquirrelSentenceTranslator.shared.request(source) { result in
        english = result
        finish()
      }
      if withFrench {
        SquirrelSentenceTranslator.french.requestBatch(candidates) { result in
          french = result
          finish()
        }
      }
    }
    let translation = translated.0
    let frenchTranslations = translated.1
    let translationMilliseconds = Date().timeIntervalSince(start) * 1000
    check(translation != nil && !translation!.isEmpty, "real translation returned")
    let result = translation!
    panel.setSentenceComment(result, at: 0, expectedCandidates: candidates)
    if withFrench {
      check(frenchTranslations.count == 9, "real French returned for all nine words and sentence candidates")
      panel.setFrenchComments(frenchTranslations, expectedCandidates: candidates)
    }
    check(view.candidateRanges.count == 9, "nine candidates retained")
    check(view.hilightedIndex == 0, "highlight still belongs to translated candidate")
    let first = view.candidateRanges[0]
    let attachment = view.textContentStorage.attributedString!.attribute(.attachment, at: first.location, effectiveRange: nil) as! NSTextAttachment
    let description = attachment.image!.accessibilityDescription!
    check(description.contains(source) && description.contains(result), "Chinese candidate and complete translation share the same cell")
    if withFrench {
      check(description.contains(frenchTranslations[source]!), "Chinese English and full French share the same cell")
      for (index, candidate) in candidates.enumerated() {
        let range = view.candidateRanges[index]
        let item = view.textContentStorage.attributedString!.attribute(.attachment, at: range.location, effectiveRange: nil) as! NSTextAttachment
        check(item.image!.accessibilityDescription!.contains("\(index + 1). " + frenchTranslations[candidate]!), "matching French row carries candidate number")
      }
    }
    let box = view.contentRect(range: view.convert(range: first)!)
    check(box.width <= 220, "translation cell width bounded to 220 points")
    check(box.height > 60, "long Chinese and English render over multiple lines")
    let beforeStale = view.textContentStorage.attributedString!
    panel.setSentenceComment("STALE TEST RESULT", at: 0, expectedCandidates: ["另一个已过期的候选"])
    check(beforeStale.isEqual(to: view.textContentStorage.attributedString!), "stale result rejected")
    if withFrench {
      panel.setFrenchComments([source: "STALE FRENCH"], expectedCandidates: ["过期候选"])
      check(beforeStale.isEqual(to: view.textContentStorage.attributedString!), "stale French result rejected")
    }
    content.layoutSubtreeIfNeeded()
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let directory = URL(fileURLWithPath: "preview", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let basename = withFrench ? "trilingual-live-offscreen" : "sentence-live-offscreen"
    let screenshot = directory.appendingPathComponent(basename + ".png")
    try! bitmap.representation(using: .png, properties: [:])!.write(to: screenshot)
    let point = NSPoint(x: box.midX + view.textView.textContainerInset.width + view.currentTheme.pagingOffset,
                        y: box.maxY - 4 + view.textView.textContainerInset.height)
    check(view.click(at: point).0 == 0, "English area belongs to the matching Chinese candidate")
    let record: [String: Any] = [
      "status": "passed", "assertions": checks,
      "validation_kind": "Real Apple on-device translation and actual Squirrel Panel/View/Theme offscreen rendering; synthetic candidate input, not an actual host application input session.",
      "source": source, "translation": result, "translation_ms": translationMilliseconds,
      "french_translations": frenchTranslations, "french_enabled": withFrench,
      "models_installed": installed, "candidate_count": view.candidateRanges.count,
      "translated_candidate_index": 0, "cell_width_points": box.width, "cell_height_points": box.height,
      "full_translation_in_matching_cell": description.contains(result), "stale_result_rejected": true,
      "screenshot": screenshot.lastPathComponent,
      "tested_at": ISO8601DateFormatter().string(from: Date())
    ]
    let json = try! JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: directory.appendingPathComponent(basename + ".json"))
    print(String(data: json, encoding: .utf8)!)
    deadline.cancel()
    SquirrelSentenceTranslator.shared.cancel()
    SquirrelSentenceTranslator.french.cancel()
    exit(0)
  }
}
