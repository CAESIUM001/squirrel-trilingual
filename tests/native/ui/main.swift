import AppKit

_ = NSApplication.shared
let panel = SquirrelPanel(position: NSRect(x: 50, y: 300, width: 1, height: 20))
let config = SquirrelConfig()
panel.load(config: config, forDarkMode: false)
panel.load(config: config, forDarkMode: true)
let candidates = ["你好啊", "你好", "👋", "拟好", "你", "尼", "泥", "逆", "拟"]
let comments = ["int. hello", "int. hello", "int. hello", "", "pron. you", "n. nun", "n. mud", "adj. reverse", "v. plan"]
let content = panel.contentView!
let view = content.subviews.compactMap { $0 as? SquirrelView }.first!
var checks = 0
func check(_ ok: Bool, _ message: String) {
  if !ok { fatalError(message) }
  checks += 1
}
func snapshot(_ filename: String) {
  content.layoutSubtreeIfNeeded()
  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
  content.cacheDisplay(in: content.bounds, to: bitmap)
  try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "preview/\(filename).png"))
}
func checkClicks() {
  for (i, range) in view.candidateRanges.enumerated() {
    let box = view.contentRect(range: view.convert(range: range)!)
    for xFactor in [0.2, 0.8] {
      for yFactor in [0.2, 0.8] {
        let point = NSPoint(x: box.minX + box.width*xFactor + view.textView.textContainerInset.width + view.currentTheme.pagingOffset,
                            y: box.minY + box.height*yFactor + view.textView.textContainerInset.height)
        check(view.click(at: point).0 == i, "Candidate \(i) failed click at \(point)")
      }
    }
  }
}
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
             labels: [], highlighted: 0, page: 1, lastPage: false, update: true)
snapshot("native-stacked-words")
check(view.candidateRanges.count == 9, "nine candidates")
check(view.canPageUp && view.canPageDown, "native paging flags retained")
checkClicks()
let boxes = view.candidateRanges.map { view.contentRect(range: view.convert(range: $0)!) }
check(Set(boxes.map { $0.minY }).count == 1, "nine independent cells on same row")
let before = view.textContentStorage.attributedString!
panel.setSentenceComment("Wrong result", at: 0, expectedCandidates: ["stale"])
check(before.isEqual(to: view.textContentStorage.attributedString!), "stale sentence ignored")
panel.setSentenceComment("Tomorrow I will go to the library with my friends, then we will have dinner together.", at: 0, expectedCandidates: candidates)
snapshot("native-stacked-sentence")
check(view.hilightedIndex == 0, "selected candidate retained after async comment")
check(view.candidateRanges.count == 9, "nine candidates retained after async comment")
let afterBox = view.contentRect(range: view.convert(range: view.candidateRanges[0])!)
check(afterBox.width <= 220, "sentence width bounded")
check(afterBox.height > boxes[0].height, "long English wraps to more rows")
checkClicks()
func description(_ index: Int) -> String {
  let range = view.candidateRanges[index]
  let attachment = view.textContentStorage.attributedString!.attribute(.attachment, at: range.location, effectiveRange: nil) as! NSTextAttachment
  return attachment.image!.accessibilityDescription!
}
check(description(0).hasPrefix("1. 你好啊, 1. "), "same numeric label on both rows")
check(description(3) == "4. 拟好", "no orphan label when English is absent")
// French is an independent third row with the same candidate numbering.
let french = ["你好啊": "bonjour", "你好": "salut", "👋": "bonjour", "你": "toi", "尼": "religieuse", "泥": "boue", "逆": "inverse", "拟": "prévoir"]
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
             labels: [], highlighted: 0, page: 1, lastPage: false, update: true)
let beforeFrench = view.textContentStorage.attributedString!
panel.setFrenchComments(["你好啊": "stale"], expectedCandidates: ["stale"])
check(beforeFrench.isEqual(to: view.textContentStorage.attributedString!), "stale French ignored")
panel.setFrenchComments(french, expectedCandidates: candidates)
snapshot("native-stacked-three-rows")
check(view.candidateRanges.count == 9, "nine candidates retained with French")
check(view.canPageUp && view.canPageDown, "paging retained with French")
check(view.hilightedIndex == 0, "highlight retained with French")
let threeRowBoxes = view.candidateRanges.map { view.contentRect(range: view.convert(range: $0)!) }
check(Set(threeRowBoxes.map { $0.minY }).count == 1, "three-row candidate cells share one horizontal row")
check(Set(threeRowBoxes.map { $0.height }).count == 1, "French rows have shared heights across candidates")
check(threeRowBoxes[0].height > boxes[0].height, "French adds a third row")
for i in candidates.indices {
  let prefix = "\(i+1). "
  let expected = prefix + candidates[i]
    + (comments[i].isEmpty ? "" : ", " + prefix + comments[i])
    + (french[candidates[i]].map { ", " + prefix + $0 } ?? "")
  check(description(i) == expected, "all three rows use the candidate's numeric prefix")
}
check(description(3) == "4. 拟好", "no orphan English or French label")
checkClicks()
let longFrench = "Demain, j’irai à la bibliothèque avec mes amis, puis nous dînerons ensemble après avoir terminé nos études."
var wrappedFrench = french
wrappedFrench[candidates[0]] = longFrench
panel.setFrenchComments(wrappedFrench, expectedCandidates: candidates)
snapshot("native-stacked-french-sentence")
let frenchSentenceBox = view.contentRect(range: view.convert(range: view.candidateRanges[0])!)
check(frenchSentenceBox.width <= 220, "long French respects the width bound")
check(frenchSentenceBox.height > threeRowBoxes[0].height, "long French wraps below English")
check(description(0).hasSuffix("1. " + longFrench), "wrapped French retains complete accessibility text")
checkClicks()
// A full candidate refresh clears old French, including an unchanged list.
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
             labels: [], highlighted: 0, page: 1, lastPage: false, update: true)
check(description(0) == "1. 你好啊, 1. int. hello", "full candidate update clears French")
let refreshedBox = view.contentRect(range: view.convert(range: view.candidateRanges[0])!)
check(refreshedBox.height == boxes[0].height, "two-row layout restored when French clears")
// Missing English never moves French into the second row.
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates,
             comments: Array(repeating: "", count: candidates.count), labels: [], highlighted: 0,
             page: 0, lastPage: true, update: true)
panel.setFrenchComments(french, expectedCandidates: candidates)
snapshot("native-stacked-french-without-english")
let frenchOnlyBox = view.contentRect(range: view.convert(range: view.candidateRanges[0])!)
check(frenchOnlyBox.height == threeRowBoxes[0].height, "empty English row retains its vertical space")
check(description(0) == "1. 你好啊, 1. bonjour", "empty English row has no orphan number")
config.strings["style/candidate_format"] = "[label]) [candidate] [comment]"
panel.load(config: config, forDarkMode: false)
panel.load(config: config, forDarkMode: true)
let customLabels = (10...18).map(String.init)
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
             labels: customLabels, highlighted: 0, page: 1, lastPage: false, update: true)
snapshot("native-stacked-custom-labels")
for i in candidates.indices {
  let expected = customLabels[i] + ") " + candidates[i]
    + (comments[i].isEmpty ? "" : ", " + customLabels[i] + ") " + comments[i])
  check(description(i) == expected, "custom label and configured delimiter retained on both rows")
}
panel.setFrenchComments(french, expectedCandidates: candidates)
snapshot("native-stacked-three-rows-custom-labels")
for i in candidates.indices {
  let prefix = customLabels[i] + ") "
  let expected = prefix + candidates[i]
    + (comments[i].isEmpty ? "" : ", " + prefix + comments[i])
    + (french[candidates[i]].map { ", " + prefix + $0 } ?? "")
  check(description(i) == expected, "custom labels and delimiter retained on all three rows")
}
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
             labels: ["asdfghjkl"], highlighted: 0, page: 0, lastPage: false, update: true)
check(description(0) == "a) 你好啊, a) int. hello", "single label string mapping retained")
panel.setFrenchComments(french, expectedCandidates: candidates)
check(description(0) == "a) 你好啊, a) int. hello, a) bonjour", "single label string mapping retained in French")
config.strings["style/candidate_format"] = "[candidate] [comment]"
panel.load(config: config, forDarkMode: false)
panel.load(config: config, forDarkMode: true)
panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: candidates, comments: comments,
             labels: [], highlighted: 0, page: 0, lastPage: false, update: true)
check(description(0) == "你好啊, int. hello", "label-free format does not invent numbers")
panel.setFrenchComments(french, expectedCandidates: candidates)
check(description(0) == "你好啊, int. hello, bonjour", "label-free French format does not invent numbers")
let result: [String: Any] = ["assertions": checks, "status": "passed", "word_panel_width": boxes.last!.maxX, "word_cell_height": boxes[0].height, "sentence_cell_width": afterBox.width, "sentence_cell_height": afterBox.height, "three_row_cell_height": threeRowBoxes[0].height, "french_sentence_cell_height": frenchSentenceBox.height]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
