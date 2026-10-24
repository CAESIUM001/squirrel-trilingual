// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main
struct SelectionTests {
  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let events = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("example-context.json"))) as! [[String: Any]]
    let event = events.last!
    let translated = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("example-translation.json"))) as! [String: Any]
    let english = translated["translation"] as! String
    let entries = event["candidates"] as! [[String: String]]
    let client = NSObject()
    let anotherClient = NSObject()
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
      precondition(condition(), label)
      assertions += 1
    }
    func snapshot(session: UInt64 = 1, clientID: ObjectIdentifier? = nil,
                  schema: String = "double_pinyin_sogou", input: String? = nil,
                  inputCaret: Int? = nil, preedit: String? = nil,
                  selectionStart: Int? = nil, selectionEnd: Int? = nil,
                  preeditCaret: Int? = nil, commitPreview: String? = nil,
                  page: Int = 0, candidates: [String]? = nil,
                  comments: [String]? = nil, highlighted: Int = 0) -> SquirrelSentenceSnapshot {
      SquirrelSentenceSnapshot(session: session, client: clientID ?? ObjectIdentifier(client), schema: schema,
        input: input ?? event["input"] as! String, inputCaret: inputCaret ?? event["raw_caret"] as! Int,
        preedit: preedit ?? event["preedit"] as! String,
        selectionStart: selectionStart ?? event["sel_start"] as! Int,
        selectionEnd: selectionEnd ?? event["sel_end"] as! Int,
        preeditCaret: preeditCaret ?? event["cursor"] as! Int,
        commitPreview: commitPreview ?? event["commit_preview"] as! String,
        page: page, candidates: candidates ?? entries.map { $0["text"]! },
        comments: comments ?? entries.map { $0["comment"]! }, highlighted: highlighted)
    }
    let current = snapshot()
    check(current.isWholeCandidate(at: 0), "real Rime whole-sentence snapshot is eligible")
    check(current.input.utf8.count == 24 && current.preedit.utf8.count == 43,
          "raw input and preedit byte ranges differ and are handled separately")
    var state = SquirrelSentenceSelection()
    state.begin(current)
    let request = state.request(at: 0)!
    check(state.translation(forCandidateNumber: 1, in: current) == nil, "pending result never commits")
    check(state.complete(request, translation: english), "real Apple translation accepted")
    check(state.translation(forCandidateNumber: 1, in: current) == english, "complete whole translation selected")
    let generation = state.generation
    state.begin(current)
    check(state.generation == generation, "same-context modifier redraw preserves generation")
    check(state.translation(forCandidateNumber: 1, in: current) == english, "same-context modifier redraw preserves translation")
    check(state.translation(forCandidateNumber: 2, in: current) == nil, "untranslated candidate not substituted")
    check(state.translation(forCandidateNumber: 0, in: current) == nil, "zero is not a candidate shortcut")
    check(state.translation(forCandidateNumber: 10, in: current) == nil, "only nine candidate shortcuts")

    let changes = [snapshot(session: 2), snapshot(clientID: ObjectIdentifier(anotherClient)),
      snapshot(schema: "other"), snapshot(input: current.input + "a"), snapshot(inputCaret: 2),
      snapshot(preedit: current.preedit + " a"), snapshot(selectionStart: 1),
      snapshot(selectionEnd: 2), snapshot(preeditCaret: 2), snapshot(commitPreview: "旧译文"),
      snapshot(page: 1), snapshot(candidates: ["不同的中文候选"]),
      snapshot(comments: ["n. different"]), snapshot(highlighted: 1)]
    for (index, changed) in changes.enumerated() {
      check(state.translation(forCandidateNumber: 1, in: changed) == nil, "stale snapshot rejected field \(index)")
    }
    state.begin(snapshot(input: current.input + "a"))
    check(!state.complete(request, translation: "old result"), "late result after typing rejected")
    state.begin(current)
    check(!state.complete(request, translation: "old ABA result"), "old generation rejected after returning to same text")
    let fresh = state.request(at: 0)!
    check(!state.complete(fresh, translation: " \n"), "empty translation rejected")
    check(!state.complete(fresh, translation: String(repeating: "a", count: 16385)), "oversized translation rejected")
    state.invalidate()
    check(!state.complete(fresh, translation: english), "late result after cancel rejected")

    for partial in [snapshot(selectionStart: 3), snapshot(commitPreview: "已选前缀" + current.commitPreview),
      snapshot(inputCaret: 2), snapshot(commitPreview: current.commitPreview + "weizhuanhuan"),
      snapshot(selectionEnd: 5), snapshot(preeditCaret: 5)] {
      state.begin(partial)
      check(state.request(at: 0) == nil, "partial candidate cannot even start sentence translation")
      check(state.translation(forCandidateNumber: 1, in: partial) == nil, "partial input cannot be discarded")
    }

    let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    for (index, code) in digits.enumerated() {
      check(SquirrelSentenceSelection.candidateNumber(keyCode: code, option: true, shift: false,
        control: false, command: false, isKeyDown: true) == index + 1, "physical digit \(index + 1)")
      check(SquirrelSentenceSelection.frenchCandidateNumber(keyCode: code, option: false, shift: false,
        control: true, command: false, isKeyDown: true) == index + 1, "French physical digit \(index + 1)")
    }
    for flags in [(false, false, false, false, true), (true, false, true, false, true),
                  (false, true, true, false, true), (false, false, true, true, true),
                  (false, false, true, false, false)] {
      check(SquirrelSentenceSelection.frenchCandidateNumber(keyCode: 18, option: flags.0, shift: flags.1,
        control: flags.2, command: flags.3, isKeyDown: flags.4) == nil, "only exclusive Control+keydown selects French")
    }
    check(current.hasSameCandidateContext(as: snapshot(highlighted: 1)), "highlight preserves French context")
    check(current.hasSameCandidateContext(as: snapshot(commitPreview: "another highlighted candidate")),
          "highlight commit preview preserves French context")
    for changed in [snapshot(session: 2), snapshot(clientID: ObjectIdentifier(anotherClient)),
      snapshot(schema: "other"), snapshot(input: current.input + "a"), snapshot(inputCaret: 2),
      snapshot(preedit: current.preedit + " a"), snapshot(selectionStart: 1),
      snapshot(selectionEnd: 2), snapshot(preeditCaret: 2), snapshot(page: 1),
      snapshot(candidates: ["不同的中文候选"])] {
      check(!current.hasSameCandidateContext(as: changed), "changed French candidate context invalidated")
    }
    for flags in [(false, false, false, false, true), (true, true, false, false, true),
                  (true, false, true, false, true), (true, false, false, true, true),
                  (true, false, false, false, false)] {
      check(SquirrelSentenceSelection.candidateNumber(keyCode: 18, option: flags.0, shift: flags.1,
        control: flags.2, command: flags.3, isKeyDown: flags.4) == nil, "nonexclusive Option+keydown falls through")
    }
    check(SquirrelSentenceSelection.candidateNumber(keyCode: 29, option: true, shift: false,
      control: false, command: false, isKeyDown: true) == nil, "physical zero falls through")
    print("{\"status\":\"passed\",\"assertions\":\(assertions),\"fixture\":\"real Rime + real Apple translation\"}")
  }
}
