//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit
import CoreServices

final class SquirrelInstaller {
  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "im.rime.inputmethod.Squirrel.Hans"
    case hant = "im.rime.inputmethod.Squirrel.Hant"
  }
  // Registration can change the TIS list; always obtain fresh references.
  private var inputSources: [String: TISInputSource] {
    var inputSources = [String: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      // print("[DEBUG] Examining input source: \(sourceID)")
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }

  struct RegistrationResult: Codable {
    let protocolVersion: Int
    let success: Bool
    let appPath: String
    let launchServicesStatus: OSStatus
    let textInputSourceStatus: OSStatus?
    let modeRestoreStatuses: [String: OSStatus]
    let selectionRestoreStatus: OSStatus?
    let registeredModes: [String]
    let enabledModesBefore: [String]
    let expectedEnabledModes: [String]
    let enabledModesAfter: [String]
    let selectedSourceBefore: String?
    let selectedSourceAfter: String?
  }

  func enabledModes() -> [InputMode] {
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in getInputSource(modes: InputMode.allCases) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        enabledModes.insert(mode)
      }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  func register() -> RegistrationResult {
    let enabledBefore = Set(enabledModes())
    // Replacing the bundle can temporarily remove its old TIS records. An
    // empty snapshot is recovery/fresh-install state, not a request to disable it.
    let expectedEnabled: Set<InputMode> = enabledBefore.isEmpty ? [.primary] : enabledBefore
    let selectedBefore = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let selectedIDBefore = sourceID(selectedBefore)
    let appURL = SquirrelApp.appDir
    // Refresh even when the mode is enabled: its LaunchServices executable
    // mapping may have been displaced by a build with the same bundle ID.
    let launchStatus = LSRegisterURL(appURL as CFURL, true)
    let inputStatus: OSStatus? = launchStatus == noErr ? TISRegisterInputSource(appURL as CFURL) : nil
    var restored = [String: OSStatus]()
    var selectionStatus: OSStatus?
    if launchStatus == noErr, inputStatus == noErr {
      for _ in 0..<40 {
        let modes = getInputSource(modes: InputMode.allCases)
        for (mode, source) in modes {
          guard let actualEnabled = getBool(for: source, key: kTISPropertyInputSourceIsEnabled) else { continue }
          let wantedEnabled = expectedEnabled.contains(mode)
          if wantedEnabled != actualEnabled, restored[mode.rawValue] != noErr {
            restored[mode.rawValue] = wantedEnabled ? TISEnableInputSource(source) : TISDisableInputSource(source)
          }
        }
        if modes.count == InputMode.allCases.count, Set(enabledModes()) == expectedEnabled { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      }
      let selectedNow = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
      if sourceID(selectedNow) != selectedIDBefore, let selectedBefore {
        selectionStatus = TISSelectInputSource(selectedBefore)
        for _ in 0..<40 {
          if sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()) == selectedIDBefore { break }
          RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
      }
    }
    let registered = getInputSource(modes: InputMode.allCases).keys.map(\.rawValue).sorted()
    let enabledAfter = Set(enabledModes())
    let selectedIDAfter = sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
    let succeeded = launchStatus == noErr && inputStatus == noErr
      && restored.values.allSatisfy { $0 == noErr }
      && (selectionStatus == nil || selectionStatus == noErr)
      && registered.count == InputMode.allCases.count
      && enabledAfter == expectedEnabled && selectedIDAfter == selectedIDBefore
    return RegistrationResult(protocolVersion: 1, success: succeeded, appPath: appURL.path,
      launchServicesStatus: launchStatus, textInputSourceStatus: inputStatus,
      modeRestoreStatuses: restored, selectionRestoreStatus: selectionStatus,
      registeredModes: registered, enabledModesBefore: enabledBefore.map(\.rawValue).sorted(),
      expectedEnabledModes: expectedEnabled.map(\.rawValue).sorted(),
      enabledModesAfter: enabledAfter.map(\.rawValue).sorted(),
      selectedSourceBefore: selectedIDBefore, selectedSourceAfter: selectedIDAfter)
  }

  private func sourceID(_ source: TISInputSource?) -> String? {
    guard let source else { return nil }
    let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    return unsafeBitCast(value, to: CFString?.self) as String?
  }

  func enable(modes: [InputMode] = []) {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled Squirrel method(s): \(enabledInputModes.map { $0.rawValue })")
      // keep user's manually enabled input modes.
      return
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    for (mode, inputSource) in getInputSource(modes: modesToEnable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  func select(mode: InputMode? = nil) {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return
      }
    }
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
         let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
         let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected),
         enabled && selectable && !selected {
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      } else {
        print("Failed to select \(mode.rawValue)")
      }
    }
  }

  func disable(modes: [InputMode] = []) {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        let error = TISDisableInputSource(inputSource)
        print("Disable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  private func getInputSource(modes: [InputMode]) -> [InputMode: TISInputSource] {
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = inputSources[mode.rawValue] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }
}
