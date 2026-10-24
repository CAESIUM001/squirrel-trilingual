//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var frenchComments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = NSVisualEffectView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.blendingMode = .behindWindow
    back.material = .hudWindow
    back.state = .active
    back.wantsLayer = true
    back.layer?.mask = view.shape
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    self.contentView = contentView
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    maxHeight = 0
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int, page: Int, lastPage: Bool, update: Bool) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.frenchComments = []
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    var candidateRanges = [NSRange]()
    let stackedLines = theme.commentBelow && linear && !vertical
      ? stackedCandidateLines(candidates: candidates, comments: comments, frenchComments: frenchComments, labels: labels, highlighted: index, theme: theme)
      : []
    for i in 0..<candidates.count {
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = i == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = i == index ? theme.commentHighlightedAttrs : theme.commentAttrs

      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && i < labels.count {
          labels[i]
        } else if labels.count == 1 && i < labels.first!.count {
          // custom: A. B. C...
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: i)])
        } else {
          // default: 1. 2. 3...
          "\(i+1)"
        }
      } else {
        ""
      }

      let candidate = candidates[i].precomposedStringWithCanonicalMapping
      let comment = comments[i].precomposedStringWithCanonicalMapping

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location+1, length: convertedRange.length-1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length-1))
      }

      let lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
      if i > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      if i < stackedLines.count {
        line.setAttributedString(stackedLines[i])
        line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))
      }

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: candidateRanges, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange, canPageUp: page > 0, canPageDown: !lastPage)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  // Apply an asynchronous sentence result only to the candidate list that
  // requested it. The caller additionally owns request cancellation/generation.
  func setSentenceComment(_ text: String, at candidateIndex: Int, expectedCandidates: [String]) {
    guard candidates == expectedCandidates, candidateIndex >= 0,
          candidateIndex < candidates.count else { return }
    while comments.count < candidates.count { comments.append("") }
    comments[candidateIndex] = text
    let storedCursorIndex = cursorIndex
    update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates,
           comments: comments, labels: labels, highlighted: index, page: page,
           lastPage: lastPage, update: false)
    cursorIndex = storedCursorIndex
  }

  // Translation results are keyed by the original candidate, so duplicate
  // candidates share a result without changing their labels or click targets.
  func setFrenchComments(_ translations: [String: String], expectedCandidates: [String]) {
    guard candidates == expectedCandidates else { return }
    frenchComments = candidates.map { translations[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    let storedCursorIndex = cursorIndex
    update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates,
           comments: comments, labels: labels, highlighted: index, page: page,
           lastPage: lastPage, update: false)
    cursorIndex = storedCursorIndex
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  // NSTextAttachment makes each multilingual item one indivisible layout unit.
  // The surrounding native text layout still wraps rows, draws highlights,
  // positions the panel at the caret, and exposes the same candidate ranges.
  func stackedCandidateLines(candidates: [String], comments: [String], frenchComments: [String], labels: [String], highlighted: Int,
                             theme: SquirrelTheme) -> [NSAttributedString] {
    struct Cell {
      let titleLabel: NSAttributedString
      let titleBody: NSAttributedString
      let commentLabel: NSAttributedString
      let commentBody: NSAttributedString
      let frenchLabel: NSAttributedString
      let frenchBody: NSAttributedString
      let bodyOffset: CGFloat
      let width: CGFloat
      let titleHeight: CGFloat
      let commentHeight: CGFloat
      let frenchHeight: CGFloat
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 1
    let cells = candidates.enumerated().map { i, candidate -> Cell in
      var attrs = i == highlighted ? theme.highlightedAttrs : theme.attrs
      var labelAttrs = i == highlighted ? theme.labelHighlightedAttrs : theme.labelAttrs
      var commentAttrs = i == highlighted ? theme.commentHighlightedAttrs : theme.commentAttrs
      // Row placement is explicit inside the cell; inline baseline offsets do
      // not apply here. Keep translations smaller when the theme omits a size.
      for key in [NSAttributedString.Key.baselineOffset] {
        attrs.removeValue(forKey: key)
        labelAttrs.removeValue(forKey: key)
        commentAttrs.removeValue(forKey: key)
      }
      commentAttrs[.font] = theme.commentFont.withSize(min(theme.commentFont.pointSize, theme.font.pointSize * 0.78))
      attrs[.paragraphStyle] = paragraph
      labelAttrs[.paragraphStyle] = paragraph
      commentAttrs[.paragraphStyle] = paragraph
      let label: String
      if labels.count > 1 && i < labels.count {
        label = labels[i]
      } else if labels.count == 1 && i < labels[0].count {
        label = String(labels[0][labels[0].index(labels[0].startIndex, offsetBy: i)])
      } else {
        label = "\(i+1)"
      }
      let template = theme.candidateFormat.replacingOccurrences(of: "[comment]", with: "")
        .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
      let title = NSMutableAttributedString(string: template, attributes: labelAttrs)
      for range in title.string.ranges(of: /\[candidate\]/) {
        title.addAttributes(attrs, range: convert(range: range, in: title.string))
      }
      title.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: title.length))
      title.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: title.length))
      // Use the configured label prefix verbatim on every row. Separate label
      // and body columns align both starts at different font sizes and keep
      // wrapped translations out of the label column.
      let prefixTemplate = template.range(of: "[candidate]").map { String(template[..<$0.lowerBound]) } ?? ""
      let prefix = prefixTemplate.contains("[label]")
        ? prefixTemplate.replacingOccurrences(of: "[label]", with: label) : ""
      let prefixLength = prefix.utf16.count
      let titleLabel = title.attributedSubstring(from: NSRange(location: 0, length: prefixLength))
      let titleBody = title.attributedSubstring(from: NSRange(location: prefixLength, length: title.length-prefixLength))
      let commentText = i < comments.count ? comments[i] : ""
      var commentLabelAttrs = labelAttrs
      commentLabelAttrs[.font] = commentAttrs[.font]
      let commentLabel = NSAttributedString(string: commentText.isEmpty ? "" : prefix, attributes: commentLabelAttrs)
      let commentBody = NSAttributedString(string: commentText, attributes: commentAttrs)
      let frenchText = i < frenchComments.count ? frenchComments[i] : ""
      let frenchLabel = NSAttributedString(string: frenchText.isEmpty ? "" : prefix, attributes: commentLabelAttrs)
      let frenchBody = NSAttributedString(string: frenchText, attributes: commentAttrs)
      let bodyOffset = ceil(max(titleLabel.size().width, commentLabel.size().width, frenchLabel.size().width))
      let naturalWidth = bodyOffset + max(titleBody.size().width, commentBody.size().width, frenchBody.size().width)
      let width = ceil(min(theme.stackedCommentMaxWidth, max(1, naturalWidth)))
      let constraint = NSSize(width: max(1, width-bodyOffset), height: .greatestFiniteMagnitude)
      let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
      let titleHeight = ceil(max(titleLabel.size().height, titleBody.boundingRect(with: constraint, options: options).height))
      let commentHeight = commentBody.length == 0 ? 0
        : ceil(max(commentLabel.size().height, commentBody.boundingRect(with: constraint, options: options).height))
      let frenchHeight = frenchBody.length == 0 ? 0
        : ceil(max(frenchLabel.size().height, frenchBody.boundingRect(with: constraint, options: options).height))
      return Cell(titleLabel: titleLabel, titleBody: titleBody, commentLabel: commentLabel, commentBody: commentBody,
                  frenchLabel: frenchLabel, frenchBody: frenchBody, bodyOffset: bodyOffset, width: width,
                  titleHeight: titleHeight, commentHeight: commentHeight, frenchHeight: frenchHeight)
    }
    // Equal cell heights align Chinese titles and their translations across the
    // row, including candidates without a translation and wrapped long text.
    let titleHeight = cells.map(\.titleHeight).max() ?? 0
    let frenchHeight = cells.map(\.frenchHeight).max() ?? 0
    // Preserve the English slot when only French is available. French always
    // occupies the third row rather than moving up into the English row.
    let translationFont = theme.commentFont.withSize(min(theme.commentFont.pointSize, theme.font.pointSize * 0.78))
    let reservedEnglishHeight = frenchHeight > 0
      ? ceil(NSAttributedString(string: "Ag", attributes: [.font: translationFont]).size().height) : 0
    let commentHeight = max(cells.map(\.commentHeight).max() ?? 0, reservedEnglishHeight)
    let englishGap: CGFloat = commentHeight > 0 ? 3 : 0
    let frenchGap: CGFloat = frenchHeight > 0 ? 3 : 0
    let englishY = frenchHeight + frenchGap
    let titleY = englishY + commentHeight + englishGap
    let height = titleHeight + titleY
    return cells.map { cell in
      let size = NSSize(width: cell.width, height: height)
      let image = NSImage(size: size, flipped: false) { _ in
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bodyWidth = max(1, cell.width-cell.bodyOffset)
        cell.titleLabel.draw(with: NSRect(x: 0, y: titleY, width: cell.bodyOffset, height: titleHeight), options: options)
        cell.titleBody.draw(with: NSRect(x: cell.bodyOffset, y: titleY, width: bodyWidth, height: titleHeight), options: options)
        cell.commentLabel.draw(with: NSRect(x: 0, y: englishY+commentHeight-cell.commentHeight, width: cell.bodyOffset, height: cell.commentHeight), options: options)
        cell.commentBody.draw(with: NSRect(x: cell.bodyOffset, y: englishY+commentHeight-cell.commentHeight, width: bodyWidth, height: cell.commentHeight), options: options)
        cell.frenchLabel.draw(with: NSRect(x: 0, y: frenchHeight-cell.frenchHeight, width: cell.bodyOffset, height: cell.frenchHeight), options: options)
        cell.frenchBody.draw(with: NSRect(x: cell.bodyOffset, y: frenchHeight-cell.frenchHeight, width: bodyWidth, height: cell.frenchHeight), options: options)
        return true
      }
      image.accessibilityDescription = cell.titleLabel.string + cell.titleBody.string
        + (cell.commentBody.length > 0 ? ", " + cell.commentLabel.string + cell.commentBody.string : "")
        + (cell.frenchBody.length > 0 ? ", " + cell.frenchLabel.string + cell.frenchBody.string : "")
      let attachment = NSTextAttachment()
      attachment.image = image
      attachment.bounds = NSRect(origin: .zero, size: size)
      return NSAttributedString(attachment: attachment)
    }
  }

  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    // Break line if the text is too long, based on screen size.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)

    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
    if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
        (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
      if contentRect.width >= maxHeight {
        maxHeight = contentRect.width
      } else {
        contentRect.size.width = maxHeight
        view.textContainer.size = NSSize(width: maxHeight, height: maxTextHeight)
      }
    }

    if vertical {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.height + theme.edgeInset.height * 2),
                              height: min(0.95 * screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset)

      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if position.midY / screenRect.height >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.width + theme.edgeInset.width * 2),
                              height: min(0.95 * screenRect.height, contentRect.height + theme.edgeInset.height * 2))
      panelRect.size.width += theme.pagingOffset
      panelRect.origin = NSPoint(x: position.minX - theme.pagingOffset, y: position.minY - SquirrelTheme.offsetHeight - panelRect.height)
    }
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      if vertical {
        panelRect.origin.y = screenRect.minY
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = screenRect.minY
    }
    self.setFrame(panelRect, display: true)

    // rotate the view, the core in vertical mode!
    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }
    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    view.frame = contentView!.bounds
    view.textView.frame = contentView!.bounds
    view.textView.frame.size.width -= theme.pagingOffset
    view.textView.frame.origin.x += theme.pagingOffset
    view.textView.textContainerInset = theme.edgeInset

    if theme.translucency {
      back.frame = contentView!.bounds
      back.frame.size.width += theme.pagingOffset
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    invalidateShadow()
    orderFront(nil)
    // voila!
  }

  func show(status message: String) {
    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }
}
