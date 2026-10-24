import AppKit
final class SquirrelInputController {
  func page(up: Bool) -> Bool { true }
  func moveCaret(forward: Bool) -> Bool { true }
  func selectCandidate(_ index: Int) -> Bool { true }
}
final class SquirrelConfig {
  var strings = ["style/candidate_list_layout": "linear", "style/comment_placement": "below", "style/color_scheme": "test", "style/color_scheme_dark": "test", "style/font_face": "Avenir", "style/comment_font_face": "Avenir"]
  let doubles: [String: CGFloat] = ["style/font_point": 20, "style/comment_font_point": 14, "style/stacked_comment_max_width": 220, "style/border_height": 4, "style/border_width": 4, "style/corner_radius": 7, "style/line_spacing": 5]
  let bools = ["style/show_paging": true]
  func getString(_ key: String) -> String? { strings[key] }
  func getDouble(_ key: String) -> CGFloat? { doubles[key] }
  func getBool(_ key: String) -> Bool? { bools[key] }
  func getColor(_ key: String, inSpace: SquirrelTheme.RimeColorSpace) -> NSColor? {
    if key.hasSuffix("/back_color") { return NSColor(white: 0.2, alpha: 1) }
    if key.hasSuffix("/hilited_candidate_back_color") { return NSColor(white: 0.9, alpha: 1) }
    if key.hasSuffix("/hilited_candidate_text_color") { return .black }
    if key.hasSuffix("/hilited_comment_text_color") || key.hasSuffix("/hilited_label_color") { return .darkGray }
    if key.hasSuffix("/comment_text_color") || key.hasSuffix("/label_color") { return .lightGray }
    if key.hasSuffix("/candidate_text_color") { return .white }
    return nil
  }
}
