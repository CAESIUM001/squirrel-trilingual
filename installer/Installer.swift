// SPDX-License-Identifier: GPL-3.0-or-later
// Native per-user installation. Does not require Python on the recipient Mac.
import AppKit
import Carbon
import CryptoKit
import Foundation

enum InstallError: Error, CustomStringConvertible {
  case message(String)
  var description: String { switch self { case .message(let text): return text } }
}
let fm = FileManager.default
func fail(_ text: String) throws -> Never { throw InstallError.message(text) }
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
func safePath(_ path: URL, below root: URL) throws {
  guard path.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
    try fail("Path is outside the installation directory: \(path.path)")
  }
  var cursor = path
  while cursor.path != root.path {
    if let attributes = try? fm.attributesOfItem(atPath: cursor.path),
       attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      try fail("Refusing to replace or traverse a symbolic link: \(cursor.path)")
    }
    cursor.deleteLastPathComponent()
  }
}
@discardableResult
func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let text = String(data: data, encoding: .utf8) ?? ""
  guard allowFailure || process.terminationStatus == 0 else {
    try fail("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)): \(text)")
  }
  return text
}
func write(_ data: Data, to path: URL) throws {
  try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: path, options: .atomic)
}
func json(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
}

// Preserve the user's original YAML and comments. Only block maps are edited;
// unsupported ambiguous YAML fails before backups/mutations, never guessed.
struct YAML {
  var lines: [String]
  init(_ text: String) throws {
    lines = text.components(separatedBy: "\n")
    guard !text.contains("\0"), !lines.contains(where: {
      $0.prefix { $0 == " " || $0 == "\t" }.contains("\t")
    }) else { try fail("YAML indentation tabs/NUL are unsupported; original settings were left intact.") }
    if lines.last == "" { lines.removeLast() }
  }
  var text: String { lines.joined(separator: "\n") + "\n" }
  static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
  static func entry(_ line: String, at indent: Int) -> (String, String)? {
    guard Self.indent(line) == indent else { return nil }
    let body = String(line.dropFirst(indent))
    guard !body.hasPrefix("#"), !body.hasPrefix("-"), !body.isEmpty else { return nil }
    if let quote = body.first, quote == "\"" || quote == "'" {
      let remaining = body.dropFirst()
      guard let end = remaining.firstIndex(of: quote) else { return nil }
      let key = String(remaining[..<end])
      let suffix = remaining[remaining.index(after: end)...]
      guard suffix.first == ":" else { return nil }
      return (key, String(suffix.dropFirst()).trimmingCharacters(in: .whitespaces))
    }
    guard let colon = body.firstIndex(of: ":") else { return nil }
    return (String(body[..<colon]).trimmingCharacters(in: .whitespaces),
            String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
  }
  func bounds(_ key: String, in range: Range<Int>, indent: Int) throws -> Range<Int>? {
    let meaningful = range.filter {
      let text = lines[$0].trimmingCharacters(in: .whitespaces)
      return !text.isEmpty && !text.hasPrefix("#")
    }
    if let minimum = meaningful.map({ Self.indent(lines[$0]) }).min(), minimum != indent {
      try fail("YAML block maps must use two-space indentation; original settings were left intact.")
    }
    let matches = range.filter { Self.entry(lines[$0], at: indent)?.0 == key }
    guard matches.count <= 1 else { try fail("Duplicate YAML key \(key); original settings were left intact.") }
    guard let start = matches.first else { return nil }
    var end = start + 1
    while end < range.upperBound {
      let line = lines[end]
      if !line.trimmingCharacters(in: .whitespaces).isEmpty &&
          !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") && Self.indent(line) <= indent { break }
      end += 1
    }
    return start..<end
  }
  func value(_ path: [String]) throws -> [String]? {
    var range = 0..<lines.count
    for (depth, key) in path.enumerated() {
      guard let block = try bounds(key, in: range, indent: depth * 2) else { return nil }
      if depth == path.count - 1 { return Array(lines[block]) }
      let suffix = Self.entry(lines[block.lowerBound], at: depth * 2)!.1
      guard suffix.isEmpty || suffix.hasPrefix("#") else { try fail("YAML \(key) must be a block map; original settings were left intact.") }
      range = (block.lowerBound + 1)..<block.upperBound
    }
    return nil
  }
  mutating func set(_ path: [String], value: [String]) throws {
    guard !path.isEmpty else { return }
    var range = 0..<lines.count
    for (depth, key) in path.enumerated() {
      let indent = depth * 2
      if let block = try bounds(key, in: range, indent: indent) {
        if depth == path.count - 1 {
          lines.replaceSubrange(block, with: value.map { String(repeating: " ", count: indent) + $0 })
          return
        }
        let suffix = Self.entry(lines[block.lowerBound], at: indent)!.1
        guard suffix.isEmpty || suffix.hasPrefix("#") else { try fail("YAML \(key) must be a block map; original settings were left intact.") }
        range = (block.lowerBound + 1)..<block.upperBound
      } else {
        let position = range.upperBound
        if depth == path.count - 1 {
          lines.insert(contentsOf: value.map { String(repeating: " ", count: indent) + $0 }, at: position)
          return
        }
        lines.insert(String(repeating: " ", count: indent) + key + ":", at: position)
        range = (position + 1)..<(position + 1)
      }
    }
  }
}

func configurationPlan(rime: URL) throws -> [String: Data] {
  func read(_ name: String) throws -> String {
    let path = rime.appendingPathComponent(name)
    guard exists(path) else { return "" }
    return try String(contentsOf: path, encoding: .utf8)
  }
  var defaults = try YAML(read("default.custom.yaml"))
  var schemas = ["rime_ice"]
  let baseDefaults = try YAML(read("default.yaml"))
  if let block = try defaults.value(["patch", "schema_list"]) ?? baseDefaults.value(["schema_list"]) {
    let header = YAML.entry(block[0], at: YAML.indent(block[0]))!.1
    guard header.isEmpty || header.hasPrefix("#") else { try fail("Inline schema_list is unsupported; original settings were left intact.") }
    let regex = try NSRegularExpression(pattern: "^\\s*-\\s*schema:\\s*[\"']?([A-Za-z0-9_-]+)[\"']?\\s*(?:#.*)?$")
    for line in block.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
      let range = NSRange(line.startIndex..., in: line)
      guard let match = regex.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line) else {
        try fail("Unsupported schema_list entry; original settings were left intact.")
      }
      let value = String(line[name])
      if !schemas.contains(value) { schemas.append(value) }
    }
  }
  try defaults.set(["patch", "schema_list"], value: ["schema_list:"] + schemas.map { "  - schema: \($0)" })
  for (key, value) in [("menu/page_size", "9"), ("ascii_composer/switch_key/Shift_L", "commit_code"),
                       ("ascii_composer/switch_key/Shift_R", "commit_code")] {
    try defaults.set(["patch", key], value: ["\(key): \(value)"])
  }
  var style = try YAML(read("squirrel.custom.yaml"))
  for (key, value) in [("style/candidate_list_layout", "linear"), ("style/comment_placement", "below"),
                       ("style/stacked_comment_max_width", "220")] {
    try style.set(["patch", key], value: ["\(key): \(value)"])
  }
  var schemaText = try read("rime_ice.custom.yaml")
  let begin = "  # BEGIN rime-english-gloss (managed block)"
  let end = "  # END rime-english-gloss"
  if schemaText.contains(begin) || schemaText.contains(end) {
    guard schemaText.components(separatedBy: begin).count == 2,
          schemaText.components(separatedBy: end).count == 2,
          let first = schemaText.range(of: begin), let last = schemaText.range(of: end), first.lowerBound < last.lowerBound else {
      try fail("Damaged managed glossary block; original settings were left intact.")
    }
    schemaText.removeSubrange(first.lowerBound..<last.upperBound)
  }
  var schema = try YAML(schemaText)
  let managed: [(String, [String])] = [
    ("engine/processors/@before 0", ["\"engine/processors/@before 0\": lua_processor@*en_gloss*processor"]),
    ("engine/filters/@next", ["\"engine/filters/@next\": lua_filter@*en_gloss*filter"]),
    ("switches/@next", ["\"switches/@next\":", "  name: english_gloss", "  reset: 1", "  states: [\"译关\", \"英释\"]"]),
    ("en_gloss", ["en_gloss:", "  max_comment_chars: 22", "  show_pos: true", "  show_second: false"])]
  let marker = try schema.value(["patch", "squirrel_trilingual_installer"])
  for (key, value) in managed {
    if marker == nil, try schema.value(["patch", key]) != nil {
      try fail("Existing unmanaged \(key) conflicts with the extension; original settings were left intact.")
    }
    try schema.set(["patch", key], value: value)
  }
  try schema.set(["patch", "squirrel_trilingual_installer"], value: ["squirrel_trilingual_installer: 1"])
  var user = try YAML(read("user.yaml"))
  try user.set(["var", "previously_selected_schema"], value: ["previously_selected_schema: rime_ice"])
  return ["default.custom.yaml": Data(defaults.text.utf8), "squirrel.custom.yaml": Data(style.text.utf8),
          "rime_ice.custom.yaml": Data(schema.text.utf8), "user.yaml": Data(user.text.utf8)]
}

func inputStatus() -> [String: Any] {
  let bundle = "im.rime.inputmethod.Squirrel"
  let sources = TISCreateInputSourceList([kTISPropertyBundleID as String: bundle] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
  func string(_ source: TISInputSource, _ key: CFString) -> String {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }
  var enabled: [String] = []
  for source in sources {
    if let flag = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
       CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(flag).takeUnretainedValue()) {
      enabled.append(string(source, kTISPropertyInputSourceID))
    }
  }
  let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
  return ["enabled": enabled.sorted(), "selected": string(current, kTISPropertyInputSourceID)]
}
func stopSquirrel() throws {
  for app in NSRunningApplication.runningApplications(withBundleIdentifier: "im.rime.inputmethod.Squirrel") {
    _ = app.terminate()
    for _ in 0..<50 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
    guard app.isTerminated else { try fail("Squirrel did not stop; existing files were left intact.") }
  }
}
func activate(app: URL, helper: URL) throws {
  let executable = app.appendingPathComponent("Contents/MacOS/Squirrel").path
  _ = try run(executable, ["--register-input-source"])
  _ = try run("/usr/bin/open", ["-a", app.path])
  _ = try run(executable, ["--reload"])
  // Registration preserves an existing Hant-only choice. Selecting Hans also
  // enables it, so do this before waiting for the full-pinyin input source.
  _ = try run(executable, ["--select-input-source", "im.rime.inputmethod.Squirrel.Hans"], allowFailure: true)
  var stable = 0
  for attempt in 0..<30 {
    Thread.sleep(forTimeInterval: 2)
    let output = try run(helper.path, ["--input-status"])
    let status = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
    if (status["enabled"] as? [String] ?? []).contains("im.rime.inputmethod.Squirrel.Hans") {
      stable += 1
    } else {
      _ = try run(executable, ["--register-input-source"])
      _ = try run(executable, ["--select-input-source", "im.rime.inputmethod.Squirrel.Hans"], allowFailure: true)
      stable = 0
    }
    if attempt >= 14 && stable >= 3 { break }
    if attempt == 29 { try fail("Input-source registration did not stabilize; the backup is retained.") }
  }
  _ = try run(executable, ["--select-input-source", "im.rime.inputmethod.Squirrel.Hans"], allowFailure: true)
  let output = try run(helper.path, ["--input-status"])
  let status = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
  guard (status["enabled"] as? [String] ?? []).contains("im.rime.inputmethod.Squirrel.Hans") else {
    try fail("Squirrel is not enabled after registration.")
  }
  if status["selected"] as? String != "im.rime.inputmethod.Squirrel.Hans" {
    print("Squirrel is installed and enabled. Select 鼠须管 from the menu bar if macOS did not switch automatically.")
  }
}

func install(payload: URL, home: URL, activateInput: Bool, helper: URL) throws {
  let app = home.appendingPathComponent("Library/Input Methods/Squirrel.app")
  let rime = home.appendingPathComponent("Library/Rime")
  let support = home.appendingPathComponent("Library/Application Support/Squirrel Trilingual")
  for path in [app, rime, support] { try safePath(path, below: home) }
  let sourceApp = payload.appendingPathComponent("Squirrel.app")
  let sourceRime = payload.appendingPathComponent("Rime")
  guard exists(sourceApp.appendingPathComponent("Contents/MacOS/Squirrel")),
        exists(sourceRime.appendingPathComponent("rime_ice.schema.yaml")),
        exists(sourceRime.appendingPathComponent("lua/en_gloss.lua")),
        exists(sourceRime.appendingPathComponent("en_gloss/glossary-en.tsv")) else { try fail("Installer payload is incomplete.") }
  _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", sourceApp.path])
  let plan = try configurationPlan(rime: rime)
  for name in plan.keys { try safePath(rime.appendingPathComponent(name), below: home) }
  let sourceFiles = try fm.subpathsOfDirectory(atPath: sourceRime.path).sorted()
  for name in sourceFiles { try safePath(rime.appendingPathComponent(name), below: home) }
  let temporary = fm.temporaryDirectory.appendingPathComponent("squirrel-trilingual-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: temporary) }
  let stagedApp = temporary.appendingPathComponent("Squirrel.app")
  _ = try run("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
  _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
  if activateInput { try stopSquirrel() }
  let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
  let backup = support.appendingPathComponent("Backups/" + stamp)
  try fm.createDirectory(at: backup, withIntermediateDirectories: true)
  let hadRime = exists(rime), hadApp = exists(app)
  if hadRime { _ = try run("/usr/bin/ditto", [rime.path, backup.appendingPathComponent("Rime").path]) }
  if hadApp { _ = try run("/usr/bin/ditto", [app.path, backup.appendingPathComponent("Squirrel.app").path]) }
  try write(try json(["format": 1, "created": stamp, "home": home.path, "rime_existed": hadRime,
                     "app_existed": hadApp, "profile": "rime_ice"]), to: backup.appendingPathComponent("manifest.json"))
  do {
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)
    // Keep all existing user data and custom source dictionaries. Only extension
    // implementation/data are upgraded; custom.tsv is explicitly user-owned.
    for name in sourceFiles {
      let source = sourceRime.appendingPathComponent(name), destination = rime.appendingPathComponent(name)
      var isDirectory: ObjCBool = false
      _ = fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
      if isDirectory.boolValue { try fm.createDirectory(at: destination, withIntermediateDirectories: true); continue }
      let managed = name == "lua/en_gloss.lua" || (name.hasPrefix("en_gloss/") && name != "en_gloss/custom.tsv")
      if !exists(destination) || managed { try write(Data(contentsOf: source), to: destination) }
    }
    for (name, data) in plan { try write(data, to: rime.appendingPathComponent(name)) }
    try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
    if exists(app) { try fm.removeItem(at: app) }
    try fm.moveItem(at: stagedApp, to: app)
    if activateInput {
      _ = try run(app.appendingPathComponent("Contents/MacOS/rime_deployer").path,
                  ["--build", rime.path, app.appendingPathComponent("Contents/SharedSupport").path,
                   rime.appendingPathComponent("build").path])
      try activate(app: app, helper: helper)
      let setup = payload.appendingPathComponent("Translation Setup.app")
      if exists(setup) { _ = try run("/usr/bin/open", ["-a", setup.path], allowFailure: true) }
    }
    try write(try json(["backup": backup.path, "profile": "rime_ice", "activated": activateInput]),
              to: support.appendingPathComponent("last-install.json"))
  } catch {
    let installationError = error
    do {
      if activateInput { try stopSquirrel() }
      if exists(app) { try fm.removeItem(at: app) }
      if hadApp { _ = try run("/usr/bin/ditto", [backup.appendingPathComponent("Squirrel.app").path, app.path]) }
      if exists(rime) { try fm.removeItem(at: rime) }
      if hadRime { _ = try run("/usr/bin/ditto", [backup.appendingPathComponent("Rime").path, rime.path]) }
      if activateInput && hadApp { _ = try run("/usr/bin/open", ["-a", app.path]) }
    } catch {
      try fail("Installation failed: \(installationError). Automatic recovery also failed: \(error). The original backup is retained at \(backup.path); no successful recovery is claimed.")
    }
    try fail("Installation failed and the previous files were restored. Backup: \(backup.path). \(installationError)")
  }
  print("Installed full-pinyin Chinese / English / French input. Backup: \(backup.path)")
}

do {
  var arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--input-status"] {
    print(String(data: try json(inputStatus()), encoding: .utf8)!)
  } else {
    func option(_ name: String) throws -> String? {
      guard let index = arguments.firstIndex(of: name) else { return nil }
      guard index + 1 < arguments.count else { try fail("Missing value for \(name)") }
      let value = arguments[index + 1]
      arguments.removeSubrange(index...index + 1)
      return value
    }
    let payloadPath = try option("--payload")
    let testHome = try option("--home")
    let noActivate = arguments.contains("--no-activate")
    arguments.removeAll { $0 == "--no-activate" || $0 == "--install" }
    guard arguments.isEmpty, let payloadPath else { try fail("Usage: SquirrelInstaller --install --payload DIRECTORY [--home TEMP_HOME --no-activate]") }
    let realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
    let requestedHome = testHome.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? realHome
    let home = requestedHome.resolvingSymlinksInPath().standardizedFileURL
    if testHome != nil {
      let attributes = try? fm.attributesOfItem(atPath: requestedHome.path)
      let temporaryRoots = [URL(fileURLWithPath: "/private/tmp"), fm.temporaryDirectory].map {
        $0.resolvingSymlinksInPath().standardizedFileURL.path
      }
      guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink,
            noActivate, home != realHome,
            temporaryRoots.contains(where: { home.path.hasPrefix($0 + "/") }) else {
        try fail("An alternate home is allowed only under the temporary directory with --no-activate.")
      }
    } else if noActivate { try fail("--no-activate requires an isolated temporary --home.") }
    if !noActivate && getuid() == 0 { try fail("Run this helper as the logged-in user, not root.") }
    try install(payload: URL(fileURLWithPath: payloadPath), home: home, activateInput: !noActivate,
                helper: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
  }
} catch {
  fputs("Squirrel installer: \(error)\n", stderr)
  exit(1)
}
