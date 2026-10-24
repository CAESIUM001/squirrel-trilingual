// SPDX-License-Identifier: GPL-3.0-or-later
// Test doubles only for the host-app/IME UI boundary and asynchronous translator.
// The controller under test, NSEvents, and librime/librime-lua are the real code.
import AppKit
import Carbon

typealias IMKServer = NSObject
protocol IMKTextInput: AnyObject {
  func bundleIdentifier() -> String!
  func overrideKeyboard(withKeyboardNamed: String!)
  func insertText(_ string: Any!, replacementRange: NSRange)
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange)
  func attributes(forCharacterIndex: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]!
}
class IMKInputController: NSObject {
  init!(server: IMKServer!, delegate: Any!, client: Any!) { super.init() }
  func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }
  func recognizedEvents(_ sender: Any!) -> Int { 0 }
  func activateServer(_ sender: Any!) {}
  func deactivateServer(_ sender: Any!) {}
  func hidePalettes() {}
  func commitComposition(_ sender: Any!) {}
  func menu() -> NSMenu! { nil }
  func mark(forStyle: Int, at: NSRange) -> Any! { [NSAttributedString.Key: Any]() }
}
final class HarnessClient: NSObject, IMKTextInput {
  let initialBody = "已有聊天正文，不能被删除。\n"
  var body = "已有聊天正文，不能被删除。\n"
  var marked = ""
  var operations: [(kind: String, text: String, replacement: NSRange)] = []
  func bundleIdentifier() -> String! { "org.rime.sentence-selection-test" }
  func overrideKeyboard(withKeyboardNamed: String!) {}
  func insertText(_ string: Any!, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    precondition(replacementRange == .empty, "insertText must use the current insertion/marked range")
    body += text
    marked = ""
    operations.append(("insert", text, replacementRange))
  }
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    precondition(replacementRange == .empty, "marked text must not replace an absolute chat-body range")
    marked = text
    operations.append(("mark", text, replacementRange))
  }
  func attributes(forCharacterIndex: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
    lineHeightRectangle?.pointee = .zero
    return [:]
  }
}
final class HarnessConfig {
  func getString(_ key: String) -> String? { nil }
  func getDouble(_ key: String) -> Double? { nil }
  func getAppOptions(_ key: String) -> [String: Bool]? { nil }
}
final class HarnessPanel {
  var inputController: SquirrelInputController?
  var position = NSRect.zero
  let linear = true
  let vertical = false
  let inlinePreedit = true
  let inlineCandidate = false
  var candidates: [String] = []
  var comments: [String] = []
  var frenchComments: [String: String] = [:]
  func hide() {}
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String],
              labels: [String], highlighted: Int, page: Int, lastPage: Bool, update: Bool) {
    self.candidates = candidates
    self.comments = comments
    frenchComments = [:]
  }
  func setSentenceComment(_ text: String, at index: Int, expectedCandidates: [String]) {
    guard candidates == expectedCandidates, comments.indices.contains(index) else { return }
    comments[index] = text
  }
  func setFrenchComments(_ translations: [String: String], expectedCandidates: [String]) {
    guard candidates == expectedCandidates else { return }
    frenchComments = translations
  }
}
final class HarnessDelegate {
  static let shared = HarnessDelegate()
  let panel: HarnessPanel? = HarnessPanel()
  let config: HarnessConfig? = HarnessConfig()
  func loadSettings(for schema: String) {}
  func deploy() {}
  func syncUserData() {}
  func openLogFolder() {}
  func openRimeFolder() {}
  func checkForUpdates() {}
  func openWiki() {}
}
extension NSApplication {
  var squirrelAppDelegate: HarnessDelegate { HarnessDelegate.shared }
}
@MainActor
final class SquirrelSentenceTranslator {
  struct Pending {
    let id: UUID
    let text: String
    let completion: (String?) -> Void
  }
  static let shared = SquirrelSentenceTranslator()
  static let french = SquirrelSentenceTranslator()
  struct BatchPending {
    let id: UUID
    let texts: [String]
    let progress: (([String: String]) -> Void)?
    let completion: ([String: String]) -> Void
  }
  var pending: [Pending] = []
  var batches: [BatchPending] = []
  var cancelled: Set<UUID> = []
  var cached: [String: String] = [:]
  func cachedTranslations(for texts: [String]) -> [String: String] {
    cached.filter { texts.contains($0.key) }
  }
  func request(_ text: String, completion: @escaping (String?) -> Void) -> UUID {
    let id = UUID()
    pending.append(Pending(id: id, text: text, completion: completion))
    return id
  }
  func cancel(_ identifier: UUID? = nil) {
    if let identifier { cancelled.insert(identifier) }
  }
  func requestBatch(_ texts: [String], progress: (([String: String]) -> Void)? = nil,
                    completion: @escaping ([String: String]) -> Void) -> UUID {
    let id = UUID()
    batches.append(BatchPending(id: id, texts: texts, progress: progress, completion: completion))
    return id
  }
  func prepareLanguages() {}
}
