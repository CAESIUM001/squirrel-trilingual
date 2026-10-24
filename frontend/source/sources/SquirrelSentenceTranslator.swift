// Copyright (c) 2026 rime-english-gloss contributors
// SPDX-License-Identifier: GPL-3.0-or-later
// Uses only Apple's public, on-device Translation API. No input is logged or saved.

import AppKit
import Foundation
import SwiftUI
import Translation

/// All entry points and completion handlers run on the main actor.
/// Only the most recent request may finish; callers should still match their
/// own composition generation before displaying a result.
@MainActor
final class SquirrelSentenceTranslator {
  static let shared = SquirrelSentenceTranslator(targetLanguage: "en")
  static let french = SquirrelSentenceTranslator(targetLanguage: "fr")
  private static var settingsWindow: NSWindow?

  private let targetLanguage: String
  private var pendingID: UUID?
  private var availabilityTask: Task<Void, Never>?
  private var worker: AnyObject?
  private var workerPanel: NSPanel?
  private var cache: [String: String] = [:]
  private var cacheOrder: [String] = []
  private let cacheLimit = 1024
  private let cacheByteLimit = 2 * 1024 * 1024
  private var cacheBytes = 0
  private lazy var glossary: [String: String] = {
    guard targetLanguage == "fr", let url = Bundle.main.url(forResource: "glossary-fr", withExtension: "tsv"),
          let data = try? Data(contentsOf: url), data.count <= 32 * 1024 * 1024,
          let contents = String(data: data, encoding: .utf8) else { return [:] }
    var entries: [String: String] = [:]
    for line in contents.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
      let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty,
            fields[0].utf8.count <= 8192, fields[1].utf8.count <= 16384 else { continue }
      entries[String(fields[0])] = String(fields[1])
    }
    return entries
  }()

  private init(targetLanguage: String) { self.targetLanguage = targetLanguage }

  /// A missing language model returns nil without asking to download anything.
  @discardableResult
  func request(_ text: String, completion: @escaping (String?) -> Void) -> UUID {
    requestBatch([text]) { completion($0[text]) }
  }

  /// Synchronous exact glossary and memory-cache lookup. Common French words
  /// can be displayed in the same update as Chinese and English; no model starts.
  func cachedTranslations(for texts: [String]) -> [String: String] {
    var results: [String: String] = [:]
    for text in texts.prefix(128) where !text.isEmpty && text.utf8.count <= 8192 {
      if let value = cache[text] {
        results[text] = value
        touchCache(text)
        continue
      }
      var value = glossary[text]
      if value == nil, !glossary.isEmpty, text.count <= 128,
         let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false),
         simplified != text {
        value = glossary[simplified]
      }
      if let value {
        results[text] = value
        remember(value, for: text)
      }
    }
    return results
  }

  /// At most 16 distinct, bounded inputs per request. Cached results arrive
  /// immediately; missing results are published cumulatively as each finishes.
  /// The caller's first missing item is translated before the remaining batch.
  /// Each fixed-language instance has independent cancellation and cache state.
  @discardableResult
  func requestBatch(_ texts: [String], progress: (([String: String]) -> Void)? = nil,
                    completion: @escaping ([String: String]) -> Void) -> UUID {
    cancel(nil)
    let identifier = UUID()
    pendingID = identifier
    var seen: Set<String> = []
    var requested: [String] = []
    var totalBytes = 0
    for text in texts.prefix(128) {
      let size = text.utf8.count
      guard requested.count < 16, size <= 8192, totalBytes + size <= 32768,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            seen.insert(text).inserted else { continue }
      requested.append(text)
      totalBytes += size
    }
    let cached = cachedTranslations(for: requested)
    if !cached.isEmpty { progress?(cached) }
    // A synchronous progress callback may have started another composition.
    guard pendingID == identifier else { return identifier }
    let missing = requested.filter { cached[$0] == nil }
    guard !missing.isEmpty else {
      complete(identifier, requested: requested, results: cached, completion: completion)
      return identifier
    }
    guard #available(macOS 15.0, *) else {
      complete(identifier, requested: requested, results: cached, completion: completion)
      return identifier
    }
    let target = targetLanguage
    availabilityTask = Task { [weak self] in
      // Check installed models once immediately before submitting a job. The
      // automatic path never calls prepareTranslation or saves input to disk.
      let status = await LanguageAvailability().status(
        from: Locale.Language(identifier: "zh-Hans"),
        to: Locale.Language(identifier: target))
      guard let self, !Task.isCancelled, self.pendingID == identifier else { return }
      guard status == .installed else {
        self.complete(identifier, requested: requested, results: cached, completion: completion)
        return
      }
      let worker = self.ensureWorker()
      worker.submit(identifier: identifier, texts: missing, progress: { [weak self] results in
        guard let self, self.pendingID == identifier else { return }
        let accepted = self.accept(requested: requested,
                                   results: cached.merging(results) { _, fresh in fresh })
        progress?(accepted)
      }) { [weak self] results in
        self?.complete(identifier, requested: requested,
                       results: cached.merging(results) { _, fresh in fresh }, completion: completion)
      }
    }
    return identifier
  }

  /// nil cancels the current request. A stale identifier cannot cancel a newer one.
  func cancel(_ identifier: UUID? = nil) {
    if let identifier, identifier != pendingID { return }
    pendingID = nil
    availabilityTask?.cancel()
    availabilityTask = nil
    if #available(macOS 15.0, *) {
      (worker as? SquirrelTranslationWorker)?.cancel()
    }
  }

  func checkAvailability(completion: @escaping (Bool) -> Void) {
    guard #available(macOS 15.0, *) else { completion(false); return }
    Task {
      let status = await LanguageAvailability().status(
        from: Locale.Language(identifier: "zh-Hans"),
        to: Locale.Language(identifier: targetLanguage))
      completion(status == .installed)
    }
  }

  /// Explicit user action only. Merely opening this window does not download.
  func prepareLanguages() {
    guard #available(macOS 15.0, *) else {
      let alert = NSAlert()
      alert.messageText = "本机英文和法语翻译需要 macOS 15 或更新版本"
      alert.informativeText = "当前的离线词语释义仍可继续使用。"
      alert.runModal()
      return
    }
    if let settingsWindow = Self.settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "鼠须管 · 英文与法语"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SquirrelTranslationSetupView())
    window.center()
    Self.settingsWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func touchCache(_ text: String) {
    if let index = cacheOrder.firstIndex(of: text) { cacheOrder.remove(at: index) }
    cacheOrder.append(text)
  }

  private func remember(_ value: String, for text: String) {
    if let old = cache[text] { cacheBytes -= text.utf8.count + old.utf8.count }
    cache[text] = value
    cacheBytes += text.utf8.count + value.utf8.count
    touchCache(text)
    while cacheOrder.count > cacheLimit || cacheBytes > cacheByteLimit {
      let expired = cacheOrder.removeFirst()
      if let value = cache.removeValue(forKey: expired) {
        cacheBytes -= expired.utf8.count + value.utf8.count
      }
    }
  }

  private func accept(requested: [String], results: [String: String]) -> [String: String] {
    var accepted: [String: String] = [:]
    for text in requested {
      guard let result = results[text], result.utf8.count <= 16384,
            !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      remember(result, for: text)
      accepted[text] = result
    }
    return accepted
  }

  private func complete(_ identifier: UUID, requested: [String], results: [String: String],
                        completion: ([String: String]) -> Void) {
    guard pendingID == identifier else { return }
    pendingID = nil
    completion(accept(requested: requested, results: results))
  }

  @available(macOS 15.0, *)
  private func ensureWorker() -> SquirrelTranslationWorker {
    if let worker = worker as? SquirrelTranslationWorker { return worker }
    let model = SquirrelTranslationWorker(targetLanguage: targetLanguage)
    // macOS 15 exposes sessions through a mounted SwiftUI translationTask.
    // The tiny transparent nonactivating panel never takes keyboard focus.
    let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.alphaValue = 0
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.contentView = NSHostingView(rootView: SquirrelTranslationWorkerView(model: model))
    panel.orderFront(nil)
    worker = model
    workerPanel = panel
    return model
  }
}

@available(macOS 15.0, *)
@MainActor
private final class SquirrelTranslationWorker: ObservableObject {
  struct Job {
    let identifier: UUID
    let texts: [String]
    let progress: ([String: String]) -> Void
    let completion: ([String: String]) -> Void
  }
  @Published var configuration: TranslationSession.Configuration?
  private var job: Job?
  private let targetLanguage: String

  init(targetLanguage: String) { self.targetLanguage = targetLanguage }

  func submit(identifier: UUID, texts: [String], progress: @escaping ([String: String]) -> Void,
              completion: @escaping ([String: String]) -> Void) {
    job = Job(identifier: identifier, texts: texts, progress: progress, completion: completion)
    if configuration == nil {
      configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "zh-Hans"),
        target: Locale.Language(identifier: targetLanguage))
    } else {
      configuration?.invalidate()
    }
  }

  func cancel() {
    job = nil
    // Keep the version monotonically increasing: a nil->same configuration
    // change within one display frame can otherwise be coalesced by SwiftUI,
    // leaving the replacement request without a new translation task.
    configuration?.invalidate()
  }

  func run(_ session: TranslationSession) async {
    guard let active = job, let first = active.texts.first else { return }
    var results: [String: String] = [:]
    do {
      // Finish the selected/first candidate before submitting the rest. A slow
      // last candidate must not hold the useful first result behind a full batch.
      let firstResponse = try await session.translate(first)
      guard job?.identifier == active.identifier, !Task.isCancelled else { return }
      if firstResponse.sourceText == first {
        results[first] = firstResponse.targetText
        active.progress(results)
      }
      guard job?.identifier == active.identifier, !Task.isCancelled else { return }
      let remaining = Array(active.texts.dropFirst())
      if !remaining.isEmpty {
        let requests = remaining.enumerated().map { index, text in
          TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        // Apple's public asynchronous sequence yields individual completions.
        // translations(from:) waits for the entire array and delays every row.
        for try await response in session.translate(batch: requests) {
          guard job?.identifier == active.identifier, !Task.isCancelled else { return }
          guard let identifier = response.clientIdentifier, let index = Int(identifier),
                remaining.indices.contains(index), response.sourceText == remaining[index] else { continue }
          results[remaining[index]] = response.targetText
          active.progress(results)
        }
      }
      guard !Task.isCancelled else { return }
      finish(active, results: results)
    } catch {
      guard !Task.isCancelled else { return }
      // Successfully completed rows survive a later model error.
      finish(active, results: results)
    }
  }

  private func finish(_ active: Job, results: [String: String]) {
    guard job?.identifier == active.identifier else { return }
    job = nil
    active.completion(results)
  }
}

@available(macOS 15.0, *)
private struct SquirrelTranslationWorkerView: View {
  @ObservedObject var model: SquirrelTranslationWorker
  var body: some View {
    Color.clear.frame(width: 1, height: 1)
      .translationTask(model.configuration) { session in
        await model.run(session)
      }
  }
}

@available(macOS 15.0, *)
private struct SquirrelTranslationSetupView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("在中文下方显示英文和法语").font(.title2.weight(.semibold))
      Text("使用 Apple 离线翻译。首次需下载对应语言包；词语和句子均在这台 Mac 上处理。")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      SquirrelTranslationLanguageSetupRow(target: "en", name: "英文", pair: "中英")
      SquirrelTranslationLanguageSetupRow(target: "fr", name: "法语", pair: "中法")
      Text("未下载某种语言时，该语言暂不显示；已下载的语言仍可正常使用。")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(24).frame(width: 540, height: 540, alignment: .topLeading)
  }
}

@available(macOS 15.0, *)
private struct SquirrelTranslationLanguageSetupRow: View {
  let target: String
  let name: String
  let pair: String
  @State private var configuration: TranslationSession.Configuration?
  @State private var installed = false
  @State private var busy = false
  @State private var status = "正在检查语言包…"
  @State private var example = ""
  private let sample = "明天下午我们一起去图书馆学习。"
  private var translator: SquirrelSentenceTranslator {
    target == "fr" ? .french : .shared
  }

  var body: some View {
    GroupBox(label: Text(name).font(.headline)) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
            .foregroundStyle(installed ? Color.green : Color.secondary)
          Text(status)
        }
        HStack {
          Button("下载" + pair + "语言包") { beginPreparation() }
            .disabled(installed || busy)
          Button("示例试译") {
            busy = true
            example = "正在翻译示例…"
            translator.request(sample) { result in
              example = result ?? "示例翻译未完成，请重试。"
              busy = false
            }
          }.disabled(!installed || busy)
          Button("刷新") { Task { await refreshStatus() } }.disabled(busy)
          if busy { ProgressView().controlSize(.small) }
        }
        Text(example.isEmpty ? sample : example)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(8).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
    }
    .task { await refreshStatus() }
    .translationTask(configuration) { session in
      do {
        try await session.prepareTranslation()
        await refreshStatus()
      } catch {
        status = "下载尚未完成，可再次点击下载。"
      }
      busy = false
    }
  }

  private func beginPreparation() {
    busy = true
    status = "请在系统提示中确认下载…"
    if configuration == nil {
      configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "zh-Hans"),
        target: Locale.Language(identifier: target))
    } else { configuration?.invalidate() }
  }

  private func refreshStatus() async {
    let availability = await LanguageAvailability().status(
      from: Locale.Language(identifier: "zh-Hans"),
      to: Locale.Language(identifier: target))
    installed = availability == .installed
    switch availability {
    case .installed: status = pair + "语言包已就绪"
    case .supported: status = pair + "语言包尚未下载"
    case .unsupported: status = "系统目前不支持这个语言组合"
    @unknown default: status = "暂时无法确认语言包状态"
    }
  }
}
