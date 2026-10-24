// SPDX-License-Identifier: GPL-3.0-or-later
// Pure state and physical-key routing for completed sentence translations.

import Foundation

struct SquirrelSentenceSnapshot: Equatable {
  let session: UInt64
  let client: ObjectIdentifier
  let schema: String
  let input: String
  let inputCaret: Int
  let preedit: String
  let selectionStart: Int
  let selectionEnd: Int
  let preeditCaret: Int
  let commitPreview: String
  let page: Int
  let candidates: [String]
  let comments: [String]
  let highlighted: Int

  /// French belongs to every candidate on the page. Moving the highlight only
  /// changes commitPreview, so it must not restart the same translation work.
  func hasSameCandidateContext(as other: Self) -> Bool {
    session == other.session && client == other.client && schema == other.schema &&
      input == other.input && inputCaret == other.inputCaret && preedit == other.preedit &&
      selectionStart == other.selectionStart && selectionEnd == other.selectionEnd &&
      preeditCaret == other.preeditCaret && page == other.page && candidates == other.candidates
  }

  /// The C API's commit preview includes an already-selected prefix and any
  /// unconverted suffix. Requiring an exact match prevents dropping either.
  func isWholeCandidate(at index: Int) -> Bool {
    candidates.indices.contains(index) && !input.isEmpty && !preedit.isEmpty &&
      inputCaret == input.utf8.count && selectionStart == 0 &&
      selectionEnd == preedit.utf8.count && preeditCaret == preedit.utf8.count &&
      candidates[index] == commitPreview
  }
}

struct SquirrelSentenceSelection {
  struct Request: Equatable {
    let generation: UInt64
    let snapshot: SquirrelSentenceSnapshot
    let index: Int
    let candidate: String
  }

  private(set) var snapshot: SquirrelSentenceSnapshot?
  private(set) var generation: UInt64 = 0
  private var translations: [Int: String] = [:]

  mutating func invalidate() {
    generation &+= 1
    snapshot = nil
    translations.removeAll(keepingCapacity: true)
  }

  mutating func begin(_ next: SquirrelSentenceSnapshot) {
    guard snapshot != next else { return }
    invalidate()
    snapshot = next
  }

  func request(at index: Int) -> Request? {
    guard let snapshot, snapshot.isWholeCandidate(at: index) else { return nil }
    return Request(generation: generation, snapshot: snapshot, index: index,
                   candidate: snapshot.candidates[index])
  }

  func isCurrent(_ request: Request) -> Bool {
    generation == request.generation && snapshot == request.snapshot &&
      request.snapshot.candidates.indices.contains(request.index) &&
      request.snapshot.candidates[request.index] == request.candidate
  }

  @discardableResult
  mutating func complete(_ request: Request, translation: String) -> Bool {
    guard isCurrent(request), !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          translation.utf8.count <= 16384 else { return false }
    translations[request.index] = translation
    return true
  }

  func translation(forCandidateNumber number: Int, in current: SquirrelSentenceSnapshot) -> String? {
    guard (1...9).contains(number), snapshot == current,
          current.isWholeCandidate(at: number - 1) else { return nil }
    return translations[number - 1]
  }

  /// Use hardware digits rather than Option-modified characters such as ¡/™.
  /// Shift+Option is intentionally left to the existing Lua second-meaning path.
  static func candidateNumber(keyCode: UInt16, option: Bool, shift: Bool,
                              control: Bool, command: Bool, isKeyDown: Bool) -> Int? {
    guard isKeyDown, option, !shift, !control, !command else { return nil }
    return physicalCandidateNumber(keyCode: keyCode)
  }

  static func frenchCandidateNumber(keyCode: UInt16, option: Bool, shift: Bool,
                                    control: Bool, command: Bool, isKeyDown: Bool) -> Int? {
    guard isKeyDown, control, !shift, !option, !command else { return nil }
    return physicalCandidateNumber(keyCode: keyCode)
  }

  private static func physicalCandidateNumber(keyCode: UInt16) -> Int? {
    switch keyCode {
    case 18: return 1
    case 19: return 2
    case 20: return 3
    case 21: return 4
    case 23: return 5
    case 22: return 6
    case 26: return 7
    case 28: return 8
    case 25: return 9
    default: return nil
    }
  }
}
