import AppKit

struct DictationShortcut: Codable, Equatable {
    enum ModifierKey: String, Codable, CaseIterable {
        case leftCommand
        case rightCommand
        case leftOption
        case rightOption
        case leftControl
        case rightControl
        case leftShift
        case rightShift

        var keyCode: UInt16 {
            switch self {
            case .leftCommand: 55
            case .rightCommand: 54
            case .leftOption: 58
            case .rightOption: 61
            case .leftControl: 59
            case .rightControl: 62
            case .leftShift: 56
            case .rightShift: 60
            }
        }

        var displayName: String {
            switch self {
            case .leftCommand: "Left Command"
            case .rightCommand: "Right Command"
            case .leftOption: "Left Option"
            case .rightOption: "Right Option"
            case .leftControl: "Left Control"
            case .rightControl: "Right Control"
            case .leftShift: "Left Shift"
            case .rightShift: "Right Shift"
            }
        }

        var eventFlag: CGEventFlags {
            switch self {
            case .leftCommand, .rightCommand: .maskCommand
            case .leftOption, .rightOption: .maskAlternate
            case .leftControl, .rightControl: .maskControl
            case .leftShift, .rightShift: .maskShift
            }
        }

        init?(keyCode: UInt16) {
            guard let modifier = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
            self = modifier
        }
    }

    struct Modifiers: OptionSet, Codable, Equatable {
        let rawValue: UInt8

        static let command = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let control = Self(rawValue: 1 << 2)
        static let shift = Self(rawValue: 1 << 3)

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        init(eventFlags: CGEventFlags) {
            var value: Self = []
            if eventFlags.contains(.maskCommand) { value.insert(.command) }
            if eventFlags.contains(.maskAlternate) { value.insert(.option) }
            if eventFlags.contains(.maskControl) { value.insert(.control) }
            if eventFlags.contains(.maskShift) { value.insert(.shift) }
            self = value
        }

        init(eventFlags: NSEvent.ModifierFlags) {
            let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
            var value: Self = []
            if flags.contains(.command) { value.insert(.command) }
            if flags.contains(.option) { value.insert(.option) }
            if flags.contains(.control) { value.insert(.control) }
            if flags.contains(.shift) { value.insert(.shift) }
            self = value
        }

        var displayNames: [String] {
            var names: [String] = []
            if contains(.control) { names.append("Control") }
            if contains(.option) { names.append("Option") }
            if contains(.shift) { names.append("Shift") }
            if contains(.command) { names.append("Command") }
            return names
        }
    }

    enum Key: Codable, Equatable {
        case modifier(ModifierKey)
        case ordinary(keyCode: UInt16, characters: String)
    }

    enum ValidationError: LocalizedError, Equatable {
        case modifiersRequired
        case reservedKey(String)
        case unsupportedKey(String)

        var errorDescription: String? {
            switch self {
            case .modifiersRequired:
                "Ordinary keys need at least one modifier."
            case let .reservedKey(name):
                "\(name) is reserved by macOS or Tiro."
            case let .unsupportedKey(name):
                "\(name) cannot be used as the dictation shortcut."
            }
        }
    }

    static let `default` = Self(key: .modifier(.rightCommand), modifiers: [])
    static let userDefaultsKey = "dictationShortcut"

    let key: Key
    let modifiers: Modifiers

    static func modifier(_ modifier: ModifierKey) -> Self {
        Self(key: .modifier(modifier), modifiers: [])
    }

    static func ordinary(keyCode: UInt16, modifiers: Modifiers, characters: String) -> Self {
        Self(key: .ordinary(keyCode: keyCode, characters: characters), modifiers: modifiers)
    }

    var displayName: String {
        switch key {
        case let .modifier(modifier):
            modifier.displayName
        case let .ordinary(keyCode, characters):
            (modifiers.displayNames + [Self.keyDisplayName(keyCode: keyCode, characters: characters)])
                .joined(separator: " + ")
        }
    }

    var validationError: ValidationError? {
        guard modifiers.rawValue & ~UInt8(0x0F) == 0 else {
            return .unsupportedKey("Unknown modifiers")
        }
        switch key {
        case .modifier:
            return modifiers.isEmpty ? nil : .unsupportedKey("Modified modifier keys")
        case let .ordinary(keyCode, characters):
            switch keyCode {
            case 53: return .reservedKey("Escape")
            case 57: return .unsupportedKey("Caps Lock")
            case 63: return .unsupportedKey("Fn")
            default: break
            }
            guard !modifiers.isEmpty else { return .modifiersRequired }

            let normalized = characters.lowercased()
            if modifiers.contains(.command), keyCode == 12 || normalized == "q" {
                return .reservedKey("Command-Q")
            }
            if modifiers.contains(.command), keyCode == 43 || normalized == "," {
                return .reservedKey("Command-comma")
            }
            if ModifierKey(keyCode: keyCode) != nil {
                return .unsupportedKey("Modifier keys")
            }
            return nil
        }
    }

    func validate() throws {
        if let validationError { throw validationError }
    }

    func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.userDefaultsKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let shortcut = try? JSONDecoder().decode(Self.self, from: data),
              shortcut.validationError == nil else { return .default }
        return shortcut
    }

    private static func keyDisplayName(keyCode: UInt16, characters: String) -> String {
        let specialKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 71: "Clear",
            76: "Enter", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
            109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
            116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End",
            120: "F2", 121: "Page Down", 122: "F1", 123: "Left Arrow",
            124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"
        ]
        if let name = specialKeys[keyCode] { return name }
        if characters == " " { return "Space" }
        if characters.isEmpty { return "Key \(keyCode)" }
        return characters.uppercased()
    }
}
