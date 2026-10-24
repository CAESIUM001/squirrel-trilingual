//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  // Sentence translations are local, asynchronous, and scoped to this composition.
  private var sentenceWork: DispatchWorkItem?
  private var sentenceRequestID: UUID?
  private var sentenceSelection = SquirrelSentenceSelection()
  private var frenchWork: DispatchWorkItem?
  private var frenchRequestID: UUID?
  private var frenchSnapshot: SquirrelSentenceSnapshot?
  private var frenchGeneration: UInt64 = 0
  private var frenchTranslations: [String: String] = [:]

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15
      // (#715)
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: event.keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      if commitFrenchTranslation(for: event) || commitSentenceTranslation(for: event) {
        handled = true
        rimeUpdate()
        break
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    cancelSentencePreview()
    cancelFrenchPreview()
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
  }

  override func deactivateServer(_ sender: Any!) {
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    cancelSentencePreview()
    cancelFrenchPreview()
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    //  commit raw input
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let translation = NSMenuItem(title: "英文与法语翻译…", action: #selector(prepareSentenceTranslation), keyEquivalent: "")
    translation.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(translation)
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func prepareSentenceTranslation() {
    MainActor.assumeIsolated { SquirrelSentenceTranslator.shared.prepareLanguages() }
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage,
                sentenceSnapshot: makeSentenceSnapshot(from: ctx))
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }
    // print("[DEBUG] commitString: \(string)")
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool, sentenceSnapshot: SquirrelSentenceSnapshot?) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
      requestSentencePreview(snapshot: sentenceSnapshot)
      requestFrenchPreview(snapshot: sentenceSnapshot)
    }
  }

  func cancelSentencePreview() {
    sentenceSelection.invalidate()
    sentenceWork?.cancel()
    sentenceWork = nil
    if let requestID = sentenceRequestID {
      MainActor.assumeIsolated { SquirrelSentenceTranslator.shared.cancel(requestID) }
    }
    sentenceRequestID = nil
  }

  func requestSentencePreview(snapshot: SquirrelSentenceSnapshot?) {
    guard rimeAPI.get_option(session, "english_gloss"), !rimeAPI.get_option(session, "ascii_mode"),
          let snapshot else { cancelSentencePreview(); return }
    // Modifier changes redraw the panel without changing composition. Preserve
    // completed translations and pending work across Option-down / digit-down.
    if sentenceSelection.snapshot == snapshot {
      if let translation = sentenceSelection.translation(forCandidateNumber: snapshot.highlighted + 1, in: snapshot) {
        NSApp.squirrelAppDelegate.panel?.setSentenceComment(translation, at: snapshot.highlighted,
                                                           expectedCandidates: snapshot.candidates)
      }
      return
    }
    cancelSentencePreview()
    sentenceSelection.begin(snapshot)
    let highlighted = snapshot.highlighted
    guard snapshot.candidates.indices.contains(highlighted), snapshot.comments.indices.contains(highlighted),
          snapshot.comments[highlighted].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let request = sentenceSelection.request(at: highlighted) else { return }
    let candidate = request.candidate
    let hanCount = candidate.unicodeScalars.filter {
      (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
    }.count
    guard hanCount >= 6, candidate.count <= 300 else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.sentenceSelection.isCurrent(request),
            let panel = NSApp.squirrelAppDelegate.panel, panel.inputController === self else { return }
      MainActor.assumeIsolated {
        self.sentenceRequestID = SquirrelSentenceTranslator.shared.request(candidate) { [weak self] translation in
          guard let self, self.sentenceSelection.isCurrent(request),
                let translation, !translation.isEmpty,
                let panel = NSApp.squirrelAppDelegate.panel, panel.inputController === self else { return }
          guard self.sentenceSelection.complete(request, translation: translation) else { return }
          panel.setSentenceComment(translation, at: highlighted, expectedCandidates: snapshot.candidates)
        }
      }
    }
    sentenceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  func cancelFrenchPreview() {
    frenchGeneration &+= 1
    frenchSnapshot = nil
    frenchTranslations.removeAll()
    frenchWork?.cancel()
    frenchWork = nil
    if let requestID = frenchRequestID {
      MainActor.assumeIsolated { SquirrelSentenceTranslator.french.cancel(requestID) }
    }
    frenchRequestID = nil
  }

  func requestFrenchPreview(snapshot: SquirrelSentenceSnapshot?) {
    guard rimeAPI.get_option(session, "english_gloss"), !rimeAPI.get_option(session, "ascii_mode"),
          let snapshot else { cancelFrenchPreview(); return }
    // A modifier-only redraw must retain both completed and pending French rows.
    if frenchSnapshot?.hasSameCandidateContext(as: snapshot) == true {
      frenchSnapshot = snapshot
      if !frenchTranslations.isEmpty {
        NSApp.squirrelAppDelegate.panel?.setFrenchComments(frenchTranslations,
                                                          expectedCandidates: snapshot.candidates)
      }
      return
    }
    cancelFrenchPreview()
    frenchSnapshot = snapshot
    let generation = frenchGeneration
    // French annotates each visible Chinese candidate, including short words.
    // It never changes the candidate text or the existing English shortcuts.
    var seen = Set<String>()
    let visible = Array(snapshot.candidates.prefix(9))
    let prioritized = visible.indices.contains(snapshot.highlighted)
      ? [visible[snapshot.highlighted]] + visible : visible
    let texts = prioritized.filter { candidate in
      candidate.count <= 300 && candidate.unicodeScalars.contains {
        (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
      } && seen.insert(candidate).inserted
    }
    guard !texts.isEmpty else { return }
    // Dictionary and memory-cache hits appear in the same redraw as Chinese;
    // only candidates still requiring the model wait for the typing debounce.
    frenchTranslations = MainActor.assumeIsolated {
      SquirrelSentenceTranslator.french.cachedTranslations(for: texts)
    }
    NSApp.squirrelAppDelegate.panel?.setFrenchComments(frenchTranslations,
                                                       expectedCandidates: snapshot.candidates)
    guard texts.contains(where: { frenchTranslations[$0] == nil }) else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.frenchGeneration == generation,
            self.frenchSnapshot?.hasSameCandidateContext(as: snapshot) == true,
            let panel = NSApp.squirrelAppDelegate.panel, panel.inputController === self else { return }
      MainActor.assumeIsolated {
        let apply: ([String: String]) -> Void = { [weak self] translations in
          guard let self, self.frenchGeneration == generation,
                self.frenchSnapshot?.hasSameCandidateContext(as: snapshot) == true,
                let panel = NSApp.squirrelAppDelegate.panel, panel.inputController === self else { return }
          self.frenchTranslations.merge(translations.filter {
            texts.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
              $0.value.utf8.count <= 16384 && !$0.value.contains("\0")
          }, uniquingKeysWith: { _, new in new })
          panel.setFrenchComments(self.frenchTranslations, expectedCandidates: snapshot.candidates)
        }
        self.frenchRequestID = SquirrelSentenceTranslator.french.requestBatch(texts, progress: apply, completion: apply)
      }
    }
    frenchWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
  }

  func commitFrenchTranslation(for event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags
    guard let number = SquirrelSentenceSelection.frenchCandidateNumber(keyCode: event.keyCode,
      option: modifiers.contains(.option), shift: modifiers.contains(.shift),
      control: modifiers.contains(.control), command: modifiers.contains(.command),
      isKeyDown: event.type == .keyDown),
      rimeAPI.get_option(session, "english_gloss"), !rimeAPI.get_option(session, "ascii_mode"),
      client != nil, NSApp.squirrelAppDelegate.panel?.inputController === self else { return false }
    var context = RimeContext_stdbool.rimeStructInit()
    guard rimeAPI.get_context(session, &context) else { return false }
    let snapshot = makeSentenceSnapshot(from: context)
    let hasMenu = context.menu.num_candidates > 0
    _ = rimeAPI.free_context(&context)
    guard hasMenu else { return false }
    // Consume a missing/pending selection while a menu is open. In particular,
    // Ctrl+digit must never select unrelated Chinese or escape to the host app.
    guard let snapshot, frenchSnapshot?.hasSameCandidateContext(as: snapshot) == true,
          snapshot.candidates.indices.contains(number - 1),
          let translation = frenchTranslations[snapshot.candidates[number - 1]],
          !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          translation.utf8.count <= 16384, !translation.contains("\0") else { return true }

    // Lua has the actual segment boundaries, unlike the public Rime context.
    // Pass a one-shot, exact-context request to its existing safe commit path,
    // which preserves selected Chinese prefixes and unconverted input suffixes.
    let properties = ["fr_gloss_protocol": "1", "fr_gloss_input": snapshot.input,
      "fr_gloss_caret": String(snapshot.inputCaret), "fr_gloss_page": String(snapshot.page),
      "fr_gloss_number": String(number), "fr_gloss_candidate": snapshot.candidates[number - 1],
      "fr_gloss_translation": translation]
    for (key, value) in properties { rimeAPI.set_property(session, key, value) }
    defer { for key in properties.keys { rimeAPI.set_property(session, key, "") } }
    cancelSentencePreview()
    cancelFrenchPreview()
    clearChord()
    _ = processKey(UInt32(48 + number), modifiers: kControlMask.rawValue)
    return true
  }

  func makeSentenceSnapshot(from context: RimeContext_stdbool) -> SquirrelSentenceSnapshot? {
    guard let client, let input = rimeAPI.get_input(session) else { return nil }
    let count = Int(context.menu.num_candidates)
    var candidates: [String] = []
    var comments: [String] = []
    for index in 0..<count {
      candidates.append(context.menu.candidates[index].text.map { String(cString: $0) } ?? "")
      comments.append(context.menu.candidates[index].comment.map { String(cString: $0) } ?? "")
    }
    return SquirrelSentenceSnapshot(session: UInt64(session), client: ObjectIdentifier(client), schema: schemaId,
      input: String(cString: input), inputCaret: Int(rimeAPI.get_caret_pos(session)),
      preedit: context.composition.preedit.map { String(cString: $0) } ?? "",
      selectionStart: Int(context.composition.sel_start), selectionEnd: Int(context.composition.sel_end),
      preeditCaret: Int(context.composition.cursor_pos),
      commitPreview: context.commit_text_preview.map { String(cString: $0) } ?? "",
      page: Int(context.menu.page_no), candidates: candidates, comments: comments,
      highlighted: Int(context.menu.highlighted_candidate_index))
  }

  func commitSentenceTranslation(for event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags
    guard let number = SquirrelSentenceSelection.candidateNumber(keyCode: event.keyCode,
      option: modifiers.contains(.option), shift: modifiers.contains(.shift),
      control: modifiers.contains(.control), command: modifiers.contains(.command),
      isKeyDown: event.type == .keyDown),
      rimeAPI.get_option(session, "english_gloss"), !rimeAPI.get_option(session, "ascii_mode"),
      let client, NSApp.squirrelAppDelegate.panel?.inputController === self else { return false }
    var context = RimeContext_stdbool.rimeStructInit()
    guard rimeAPI.get_context(session, &context) else { return false }
    let snapshot = makeSentenceSnapshot(from: context)
    _ = rimeAPI.free_context(&context)
    guard let snapshot,
          let translation = sentenceSelection.translation(forCandidateNumber: number, in: snapshot) else { return false }

    cancelSentencePreview()
    clearChord()
    // Do not select a Chinese candidate or commit an English Rime candidate:
    // clearing the composition avoids learning the translation in the userdb.
    rimeAPI.clear_composition(session)
    // NSNotFound replaces only the current marked range, never the chat body.
    client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0),
                         replacementRange: .empty)
    preedit = ""
    selRange = NSRange(location: 0, length: 0)
    caretPos = 0
    commit(string: translation)
    return true
  }
}
