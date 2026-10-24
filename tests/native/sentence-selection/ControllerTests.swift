// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation

@main
struct ControllerTests {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let user = CommandLine.arguments[1]
    let shared = CommandLine.arguments[2]
    let plugin = CommandLine.arguments[3]
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[4])
    precondition(user.contains("/work/"), "only an isolated Rime user directory is allowed")
    precondition(dlopen(plugin, RTLD_NOW | RTLD_GLOBAL) != nil, "load actual librime-lua")
    let api = rime_get_api_stdbool().pointee
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(user, to: \.user_data_dir)
    traits.setCString(shared, to: \.shared_data_dir)
    traits.setCString("rime.sentence-controller-test", to: \.app_name)
    traits.min_log_level = 2
    let moduleDefault = strdup("default")!
    let moduleLua = strdup("lua")!
    let modules = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: 3)
    modules[0] = UnsafePointer(moduleDefault); modules[1] = UnsafePointer(moduleLua); modules[2] = nil
    traits.modules = modules
    api.setup(&traits)
    api.initialize(&traits)

    let translated = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("example-translation.json"))) as! [String: Any]
    let english = translated["translation"] as! String
    let source = translated["source"] as! String
    let code = "jntmxwwuwomfyiqiqutuuugr"
    let client = HarnessClient()
    let controller = SquirrelInputController(server: NSObject(), delegate: nil, client: client)!
    let session = Mirror(reflecting: controller).children.first { $0.label == "session" }!.value as! RimeSessionId
    precondition(api.select_schema(session, "double_pinyin_sogou"))
    api.set_option(session, "traditionalization", true)
    api.set_option(session, "english_gloss", true)
    api.set_option(session, "ascii_mode", false)
    let panel = HarnessDelegate.shared.panel!
    let translator = SquirrelSentenceTranslator.shared
    let french = SquirrelSentenceTranslator.french
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
      precondition(condition(), name)
      assertions += 1
    }
    func event(_ type: NSEvent.EventType = .keyDown, keyCode: UInt16 = 0,
               text: String, ignoring: String? = nil, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: text, charactersIgnoringModifiers: ignoring ?? text, isARepeat: false, keyCode: keyCode)!
    }
    func send(_ event: NSEvent) -> Bool { controller.handle(event, client: client) }
    func type(_ code: String) { for char in code { _ = send(event(text: String(char))) } }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.38)) }
    func rawInput() -> String { api.get_input(session).map { String(cString: $0) } ?? "" }
    func releaseOption() { _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [])) }
    func releaseControl() { _ = send(event(.flagsChanged, keyCode: 59, text: "", modifiers: [])) }
    func escape() {
      _ = send(event(keyCode: 53, text: "\u{1b}"))
      // Rime's Escape can retain an earlier confirmed segment. Test cases use
      // independent compositions, so clear that residual prefix explicitly.
      api.clear_composition(session)
    }
    controller.activateServer(client)

    type(code)
    check(panel.candidates.first == source, "real Rime produces user's traditional sentence")
    settle()
    let first = translator.pending.last!
    let firstFrench = french.batches.last!
    check(firstFrench.texts.contains(source), "French includes the full Chinese sentence")
    check(firstFrench.texts.count <= 9 && Set(firstFrench.texts).count == firstFrench.texts.count,
          "French only translates distinct candidates on the visible page")
    check(firstFrench.texts.contains { $0 != source && $0.count < 6 }, "French also includes short candidate words")
    check(first.text == source, "whole sentence requested")
    let pendingCount = translator.pending.count
    _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [.option]))
    check(!translator.cancelled.contains(first.id), "Option flagsChanged preserves pending translation")
    check(!french.cancelled.contains(firstFrench.id), "Option flagsChanged preserves pending French")
    let beforePending = client.body
    _ = send(event(keyCode: 18, text: "¡", ignoring: "1", modifiers: [.option]))
    check(client.body == beforePending && rawInput() == code, "pending Option+1 does not submit or discard Chinese")
    check(translator.pending.count == pendingCount, "modifier redraw does not start duplicate request")
    first.completion(english)
    let frenchSentence = "Allons ensemble à la bibliothèque cet après-midi."
    firstFrench.completion([source: frenchSentence, "not a candidate": "must not display"])
    check(panel.frenchComments[source] == frenchSentence && panel.frenchComments.count == 1,
          "French sentence displays only at its matching candidate")
    check(panel.comments.first == english, "completed English displayed at matching candidate")
    releaseOption()
    _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [.option]))
    check(panel.comments.first == english, "Option flagsChanged restores the completed preview")
    check(panel.frenchComments[source] == frenchSentence, "modifier redraw restores completed French")
    let beforeSelection = client.operations.count
    let handled = send(event(keyCode: 18, text: "¡", ignoring: "¡", modifiers: [.option]))
    check(handled, "physical Option+1 handled despite Unicode modified characters")
    check(client.body == client.initialBody + english, "existing chat body preserved and full English inserted")
    check(french.cancelled.contains(firstFrench.id), "English commit cancels French work")
    check(client.marked.isEmpty && rawInput().isEmpty, "marked text and Rime composition cleared")
    let edits = Array(client.operations.dropFirst(beforeSelection))
    check(edits.count >= 2 && edits[0].kind == "mark" && edits[0].text.isEmpty &&
          edits[1].kind == "insert" && edits[1].text == english,
          "clear marked range precedes insertion and uses the insertion range")
    var commit = RimeCommit.rimeStructInit()
    check(!api.get_commit(session, &commit), "English was not committed through Rime candidate learning")
    releaseOption()

    // A later callback for a previous composition cannot be selected.
    type(code); settle()
    let stale = translator.pending.last!
    let staleFrench = french.batches.last!
    _ = send(event(text: "a"))
    stale.completion("STALE TRANSLATION")
    staleFrench.completion([source: "STALE FRENCH"])
    let beforeStale = client.body
    _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [.option]))
    _ = send(event(keyCode: 18, text: "¡", ignoring: "1", modifiers: [.option]))
    check(client.body == beforeStale && !rawInput().isEmpty, "stale completed result never inserted")
    check(!panel.comments.contains("STALE TRANSLATION"), "stale completed result never displayed")
    check(!panel.frenchComments.values.contains("STALE FRENCH"), "stale French never displayed")
    releaseOption(); escape()

    type(code); settle()
    french.batches.last!.completion([source: frenchSentence])
    translator.pending.last!.completion(english)
    check(panel.frenchComments[source] == frenchSentence && panel.comments.first == english,
          "English arriving after French preserves both rows")
    escape()

    // The existing Lua word meaning shortcuts must still own these candidates.
    type("nihk")
    settle()
    let wordFrench = french.batches.last!
    check(wordFrench.texts.contains("你好"), "French requests short words with existing English glossary meanings")
    wordFrench.completion(["你好": "bonjour"])
    check(panel.frenchComments["你好"] == "bonjour", "French word annotation displays")
    _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [.option]))
    let beforeWord = client.body
    check(send(event(keyCode: 18, text: "¡", ignoring: "1", modifiers: [.option])), "word Option+1 handled by Lua")
    check(client.body == beforeWord + "hello", "Lua first meaning preserved")
    releaseOption()
    type("nihk")
    _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [.option, .shift]))
    let beforeSecond = client.body
    check(send(event(keyCode: 18, text: "⁄", ignoring: "!", modifiers: [.option, .shift])), "word Shift+Option+1 handled by Lua")
    check(client.body == beforeSecond + "hi", "Lua second meaning preserved")
    releaseOption()

    // Selecting a prefix leaves a partial composition; it must not trigger an
    // English sentence request which would later discard that prefix or suffix.
    let beforePartialRequests = translator.pending.count
    type("nihk" + code)
    _ = send(event(keyCode: 19, text: "2"))
    settle()
    check(translator.pending.count == beforePartialRequests, "confirmed prefix does not request a partial sentence translation")
    let beforePartial = client.body
    let partialInput = rawInput()
    _ = send(event(.flagsChanged, keyCode: 58, text: "", modifiers: [.option]))
    _ = send(event(keyCode: 18, text: "¡", ignoring: "1", modifiers: [.option]))
    check(client.body == beforePartial && rawInput() == partialInput, "partial sentence shortcut does not lose prefix or suffix")
    releaseOption(); escape()

    // French appears from a fast dictionary/cache hit before any asynchronous
    // request; a Ctrl flagsChanged redraw must preserve that exact selection.
    french.cached = ["你好": "bonjour"]
    type("nihk")
    check(panel.frenchComments["你好"] == "bonjour", "cached French displays synchronously")
    _ = send(event(.flagsChanged, keyCode: 59, text: "", modifiers: [.control]))
    let beforeCached = client.body
    check(send(event(keyCode: 18, text: "\u{1}", ignoring: "1", modifiers: [.control])),
          "physical Control+1 handles control-modified characters")
    check(client.body == beforeCached + "bonjour" && rawInput().isEmpty,
          "cached French inserts at the existing body without Chinese substitution")
    releaseControl()
    french.cached = [:]

    let beforeFastBatch = french.batches.count
    type("nihk")
    RunLoop.main.run(until: Date().addingTimeInterval(0.14))
    check(french.batches.count == beforeFastBatch + 1, "uncached French starts within 140 ms instead of old 300 ms delay")
    let highlightFrench = french.batches.last!
    highlightFrench.progress?(["你好": "bonjour"])
    check(api.highlight_candidate_on_current_page(session, 1), "real Rime moves highlight without committing")
    _ = send(event(.flagsChanged, keyCode: 59, text: "", modifiers: [.control]))
    check(!french.cancelled.contains(highlightFrench.id) && panel.frenchComments["你好"] == "bonjour",
          "highlight-only change retains translated French and pending batch")
    let beforeHighlightSelect = client.body
    _ = send(event(keyCode: 18, text: "1", modifiers: [.control]))
    check(client.body == beforeHighlightSelect + "bonjour", "French number selects its row independently of highlight")
    releaseControl(); escape()

    type(code)
    let beforeFrenchPending = client.body
    _ = send(event(.flagsChanged, keyCode: 59, text: "", modifiers: [.control]))
    check(send(event(keyCode: 18, text: "1", modifiers: [.control])), "pending Control+1 is consumed")
    check(client.body == beforeFrenchPending && rawInput() == code, "pending French preserves Chinese composition")
    settle()
    let fullFrench = french.batches.last!
    check(fullFrench.texts.first == source, "highlighted candidate is translated first")
    fullFrench.progress?([source: frenchSentence])
    check(panel.frenchComments[source] == frenchSentence, "partial French progress displays before batch completion")
    let beforeFrenchCommit = client.body
    _ = send(event(keyCode: 18, text: "1", modifiers: [.control]))
    check(client.body == beforeFrenchCommit + frenchSentence && rawInput().isEmpty && client.marked.isEmpty,
          "Control+1 inserts the entire French sentence and clears composition")
    check(french.cancelled.contains(fullFrench.id), "French commit cancels unfinished batch")
    releaseControl()
    let beforeNoMenu = client.body
    check(!send(event(keyCode: 18, text: "1", modifiers: [.control])), "Control+1 without menu passes to host")
    check(client.body == beforeNoMenu, "no-menu Control+1 inserts nothing")

    // All visible positions, including 7/8/9's nonsequential macOS keycodes.
    let physicalDigits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    api.set_option(session, "emoji", false)
    for index in 0..<9 {
      type("nihk"); settle()
      check(panel.candidates.count == 9, "nine French targets available")
      let candidate = panel.candidates[index]
      let expected = "traduction \(index + 1)"
      french.batches.last!.progress?([candidate: expected])
      let before = client.body
      _ = send(event(.flagsChanged, keyCode: 59, text: "", modifiers: [.control]))
      check(send(event(keyCode: physicalDigits[index], text: "?", ignoring: "?", modifiers: [.control])),
            "French physical digit \(index + 1) handled")
      check(client.body == before + expected, "French selected from displayed position \(index + 1)")
      releaseControl(); escape()
    }
    api.set_option(session, "emoji", true)

    // A French word can consume only part of the raw input, and can follow
    // an already-confirmed Chinese prefix. Both use the real Lua boundaries.
    type("nihkbzj;"); settle()
    check(panel.candidates[1] == "你好", "second candidate covers only the first word")
    french.batches.last!.completion(["你好": "bonjour"])
    let beforeFrenchSuffix = client.body
    _ = send(event(keyCode: 19, text: "2", modifiers: [.control]))
    check(client.body == beforeFrenchSuffix + "bonjour" && rawInput() == "bzj;",
          "nonfirst French candidate preserves the exact raw suffix")
    _ = send(event(keyCode: 49, text: " "))
    check(client.body == beforeFrenchSuffix + "bonjour北京", "remaining Chinese suffix remains usable")

    type("nihkbzj;")
    _ = send(event(keyCode: 19, text: "2")); settle()
    check(panel.candidates.first == "北京", "selected Chinese prefix leaves Beijing candidate")
    french.batches.last!.completion(["北京": "Pékin"])
    let beforeFrenchPrefix = client.body
    _ = send(event(keyCode: 18, text: "1", modifiers: [.control]))
    check(client.body == beforeFrenchPrefix + "你好Pékin" && rawInput().isEmpty,
          "French selection preserves previously confirmed Chinese prefix")

    type("nihkbzj;")
    api.set_caret_pos(session, 4)
    _ = send(event(.flagsChanged, keyCode: 59, text: "", modifiers: [.control])); settle()
    french.batches.last!.completion(["你好": "bonjour"])
    let beforeFrenchCaret = client.body
    _ = send(event(keyCode: 18, text: "1", modifiers: [.control]))
    check(client.body == beforeFrenchCaret + "bonjour" && rawInput() == "bzj;" && api.get_caret_pos(session) == 0,
          "French selection at a middle caret preserves raw suffix and caret position")
    releaseControl(); escape()

    type("bzj;")
    _ = controller.page(up: false); settle()
    var pageContext = RimeContext_stdbool.rimeStructInit()
    check(api.get_context(session, &pageContext), "read real page context")
    check(pageContext.menu.page_no == 1 && panel.candidates.first != "北京", "second page is actually displayed")
    _ = api.free_context(&pageContext)
    // Traditionalization adds another variant ahead of 杯; use its real visible
    // position rather than assuming simplified and traditional pages align.
    let cupIndex = panel.candidates.firstIndex(of: "杯")!
    french.batches.last!.completion(["杯": "tasse"])
    let beforeFrenchPage = client.body
    _ = send(event(keyCode: physicalDigits[cupIndex], text: "?", modifiers: [.control]))
    check(client.body == beforeFrenchPage + "tasse" && rawInput() == "j;",
          "French digit selects the current page and preserves partial suffix")
    escape()

    type("nihk"); settle()
    let staleCtrl = french.batches.last!
    _ = send(event(text: "a"))
    staleCtrl.progress?(["你好": "STALE FRENCH"])
    let beforeStaleCtrl = client.body
    let staleInput = rawInput()
    _ = send(event(keyCode: 18, text: "1", modifiers: [.control]))
    check(client.body == beforeStaleCtrl && rawInput() == staleInput,
          "Control+1 rejects stale French without losing new input")
    escape()

    type("nihk"); settle()
    let hiddenFrench = french.batches.last!
    controller.hidePalettes()
    hiddenFrench.completion(["你好": "HIDDEN FRENCH"])
    check(!panel.frenchComments.values.contains("HIDDEN FRENCH"), "hidden input controller rejects late French results")
    escape()

    api.set_option(session, "english_gloss", false)
    let beforeDisabled = french.batches.count
    type("nihk"); settle()
    check(french.batches.count == beforeDisabled, "gloss toggle disables French along with English")
    escape()
    api.set_option(session, "english_gloss", true)

    // Timer work is finished; clearing the controller also clears late callbacks.
    controller.hidePalettes()
    _ = api.destroy_session(session)
    api.finalize()
    let result: [String: Any] = ["status": "passed", "assertions": assertions,
      "source": source, "translation": english, "existing_body_preserved": true,
      "unicode_option_digit_handled": true, "pending_and_stale_rejected": true,
      "lua_first_and_second_meanings_preserved": true,
      "french_control_digits_1_to_9": true, "french_partial_prefix_suffix_preserved": true,
      "french_cached_immediate_and_streamed_updates": true,
      "validation_kind": "Real controller source, NSEvents and librime-lua; host IMK/client/panel/translation completion are test doubles; isolated synthetic input only."]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
    exit(0)
  }
}
