import AppKit

@MainActor
final class DictationPreferencesView: NSStackView {
    private let modeControl = NSSegmentedControl(
        labels: DictationMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let punctuationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var selectedModel = DictationModel.selected

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
        refresh()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let preferences = DictationPreferences.current
        modeControl.selectedSegment = DictationMode.allCases.firstIndex(of: preferences.mode) ?? 0
        punctuationPicker.selectItem(at: PunctuationMode.allCases.firstIndex(of: preferences.punctuation) ?? 0)
        selectLanguage(DictationPreferences.language(for: selectedModel))
        updateAvailability()
    }

    func setModel(_ model: DictationModel) {
        selectedModel = model
        selectLanguage(DictationPreferences.language(for: model))
        updateAvailability()
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        modeControl.target = self
        modeControl.action = #selector(selectionChanged)
        modeControl.segmentStyle = .rounded
        modeControl.setAccessibilityLabel("Dictation mode")

        punctuationPicker.addItems(withTitles: PunctuationMode.allCases.map(\.title))
        punctuationPicker.target = self
        punctuationPicker.action = #selector(selectionChanged)
        punctuationPicker.setAccessibilityLabel("Punctuation")

        languagePicker.addItems(withTitles: DictationLanguage.allCases.map(\.title))
        languagePicker.target = self
        languagePicker.action = #selector(selectionChanged)
        languagePicker.setAccessibilityLabel("Language")

        let modeRow = row(label: "Mode", control: modeControl)
        let punctuationRow = row(label: "Punctuation", control: punctuationPicker)
        let languageRow = row(label: "Language", control: languagePicker)
        addArrangedSubview(modeRow)
        addArrangedSubview(punctuationRow)
        addArrangedSubview(languageRow)
        for row in [modeRow, punctuationRow, languageRow] {
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.textColor = .secondaryLabelColor
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let spacer = NSView()
        let row = NSStackView(views: [title, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func selectionChanged() {
        let modeIndex = max(0, modeControl.selectedSegment)
        let punctuationIndex = max(0, punctuationPicker.indexOfSelectedItem)
        let languageIndex = max(0, languagePicker.indexOfSelectedItem)
        guard DictationMode.allCases.indices.contains(modeIndex),
              PunctuationMode.allCases.indices.contains(punctuationIndex),
              DictationLanguage.allCases.indices.contains(languageIndex) else { return }
        DictationPreferences.save(
            mode: DictationMode.allCases[modeIndex],
            punctuation: PunctuationMode.allCases[punctuationIndex],
            language: DictationLanguage.allCases[languageIndex],
            model: selectedModel
        )
        updateAvailability()
    }

    private func updateAvailability() {
        punctuationPicker.isEnabled = DictationPreferences.current.mode == .standard
        for (index, item) in languagePicker.itemArray.enumerated() {
            let language = DictationLanguage.allCases[index]
            item.isEnabled = selectedModel.key == "qwen" || language == .auto || language == .english
        }
    }

    private func selectLanguage(_ language: DictationLanguage) {
        languagePicker.selectItem(at: DictationLanguage.allCases.firstIndex(of: language) ?? 0)
    }
}
