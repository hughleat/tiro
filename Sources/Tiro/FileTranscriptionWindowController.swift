import AppKit
import TiroRecognition
import UniformTypeIdentifiers

@MainActor
final class FileTranscriptionWindowController: NSWindowController, NSWindowDelegate {
    var onTranscriptionCompleted: (() -> Void)?
    var requestOperation: (() -> Bool)?
    var onOperationEnded: (() -> Void)?

    private let service: TiroService
    private let content = FileTranscriptionView()
    private var task: Task<Void, Never>?
    private var operationOwner = FileTranscriptionOperationOwner()

    init(service: TiroService) {
        self.service = service
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribe Audio"
        window.center()
        window.minSize = NSSize(width: 560, height: 400)
        window.setFrameAutosaveName("TiroFileTranscriptionWindow")
        super.init(window: window)
        window.delegate = self
        contentViewController = NSViewController()
        contentViewController?.view = content
        content.onChoose = { [weak self] in self?.chooseFile() }
        content.onCancel = { [weak self] in self?.cancel() }
        content.onCopy = { [weak self] in self?.copyResult() }
        content.onSave = { [weak self] in self?.saveResult() }
        content.onDrop = { [weak self] url in self?.transcribe(url) }
        content.configureSpeakerIdentification(modelKey: DictationModel.selected.key)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        cancelCurrentOperation(resetContent: false)
    }

    func transcribe(_ url: URL) {
        guard Self.isAudioFile(url) else {
            presentLocalError(FileTranscriptionError.unsupportedFile)
            return
        }
        cancelCurrentOperation(resetContent: true)
        guard requestOperation?() != false else {
            presentLocalError(FileTranscriptionError.busy)
            return
        }

        let model = DictationModel.selected
        let operationID = operationOwner.begin()
        showWindow(nil)
        content.configureSpeakerIdentification(modelKey: model.key)
        content.begin(fileName: url.lastPathComponent, modelName: model.name)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await service.transcribe(
                    audioURL: url,
                    model: model,
                    sourceFilename: url.lastPathComponent,
                    archiveAudio: false,
                    identifySpeakers: content.identifySpeakers
                )
                try Task.checkCancellation()
                guard operationOwner.owns(operationID) else { return }
                content.finish(
                    text: response.text,
                    segments: response.segments,
                    seconds: response.transcription_seconds
                )
                onTranscriptionCompleted?()
            } catch is CancellationError {
                guard operationOwner.owns(operationID) else { return }
                content.cancel()
            } catch {
                guard operationOwner.owns(operationID) else { return }
                content.fail(error.localizedDescription)
            }
            finishOperation(operationID)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio to Transcribe"
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url)
    }

    private func cancel() {
        cancelCurrentOperation(resetContent: true)
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content.resultText, forType: .string)
    }

    private func saveResult() {
        let panel = NSSavePanel()
        panel.title = "Save Transcription"
        panel.nameFieldStringValue = content.suggestedTextFileName
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        let accessory = ExportPanelAccessory(
            panel: panel,
            hasTimedSegments: content.resultSegments.contains {
                $0.endSeconds > $0.startSeconds
            }
        )
        panel.accessoryView = accessory.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try TranscriptExport.data(
                format: accessory.selectedFormat,
                text: content.resultText,
                segments: content.resultSegments
            )
            try data.write(to: url, options: .atomic)
        } catch {
            presentLocalError(error)
        }
    }

    private func cancelCurrentOperation(resetContent: Bool) {
        guard operationOwner.cancel() else { return }
        let currentTask = task
        task = nil
        currentTask?.cancel()
        if resetContent {
            content.cancel()
        }
        onOperationEnded?()
    }

    private func finishOperation(_ operationID: UUID) {
        guard operationOwner.finish(operationID) else { return }
        task = nil
        onOperationEnded?()
    }

    private func presentLocalError(_ error: Error) {
        showWindow(nil)
        window?.presentError(error)
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }
}

private enum FileTranscriptionError: LocalizedError {
    case unsupportedFile
    case busy

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "Choose an audio file in a format supported by macOS."
        case .busy:
            "Tiro is already recording or transcribing. Try this file again when it has finished."
        }
    }
}

@MainActor
private final class ExportPanelAccessory: NSObject {
    let view: NSView
    private(set) var selectedFormat = TranscriptExportFormat.text

    private weak var panel: NSSavePanel?
    private let formatButton = NSPopUpButton(
        frame: NSRect(x: 0, y: 0, width: 220, height: 26)
    )

    init(panel: NSSavePanel, hasTimedSegments: Bool) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, formatButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        view = stack
        super.init()

        formatButton.addItems(withTitles: TranscriptExportFormat.allCases.map(\.rawValue))
        formatButton.setAccessibilityLabel("Export format")
        formatButton.target = self
        formatButton.action = #selector(formatChanged)
        if !hasTimedSegments {
            formatButton.item(at: TranscriptExportFormat.allCases.firstIndex(of: .srt)!)?.isEnabled = false
            formatButton.item(at: TranscriptExportFormat.allCases.firstIndex(of: .vtt)!)?.isEnabled = false
        }
        updatePanel()
    }

    @objc private func formatChanged() {
        updatePanel()
    }

    private func updatePanel() {
        guard let panel,
              TranscriptExportFormat.allCases.indices.contains(formatButton.indexOfSelectedItem)
        else {
            return
        }
        selectedFormat = TranscriptExportFormat.allCases[formatButton.indexOfSelectedItem]
        let currentName = panel.nameFieldStringValue
        let stem = URL(fileURLWithPath: currentName)
            .deletingPathExtension()
            .lastPathComponent
        panel.allowedContentTypes = [
            UTType(filenameExtension: selectedFormat.fileExtension) ?? .data
        ]
        panel.nameFieldStringValue = "\(stem).\(selectedFormat.fileExtension)"
    }
}

struct FileTranscriptionOperationOwner {
    private var operationID: UUID?

    mutating func begin() -> UUID {
        precondition(operationID == nil)
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }

    func owns(_ operationID: UUID) -> Bool {
        self.operationID == operationID
    }

    mutating func finish(_ operationID: UUID) -> Bool {
        guard owns(operationID) else { return false }
        self.operationID = nil
        return true
    }

    mutating func cancel() -> Bool {
        guard operationID != nil else { return false }
        operationID = nil
        return true
    }
}

@MainActor
private final class FileTranscriptionView: NSView {
    var onChoose: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDrop: ((URL) -> Void)?

    var resultText: String { textView.string }
    private(set) var resultSegments: [TranscriptSegment] = []
    var suggestedTextFileName: String {
        let stem = currentFileName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        return "\(stem ?? "transcription").txt"
    }

    private let titleLabel = NSTextField(labelWithString: "Drop an audio file here")
    private let detailLabel = NSTextField(labelWithString: "or choose a file from your Mac")
    private let chooseButton = NSButton(title: "Choose Audio...", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let saveButton = NSButton(title: "Export...", target: nil, action: nil)
    private let identifySpeakersButton = NSButton(
        checkboxWithTitle: "Identify speakers",
        target: nil,
        action: nil
    )
    private let textView = NSTextView()
    private var currentFileName: String?
    private var dragActive = false
    private var speakerIdentificationAvailable = true

    var identifySpeakers: Bool { identifySpeakersButton.state == .on }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        buildContent()
        showEmptyState()
    }

    required init?(coder: NSCoder) { nil }

    func configureSpeakerIdentification(modelKey: String) {
        speakerIdentificationAvailable = modelKey != DictationModel.appleSpeechKey
        if !speakerIdentificationAvailable {
            identifySpeakersButton.state = .off
        }
        identifySpeakersButton.isEnabled = speakerIdentificationAvailable
    }

    func begin(fileName: String, modelName: String) {
        currentFileName = fileName
        titleLabel.stringValue = "Transcribing \(fileName)"
        detailLabel.stringValue = modelName
        textView.string = ""
        progress.isHidden = false
        progress.startAnimation(nil)
        cancelButton.isHidden = false
        copyButton.isHidden = true
        saveButton.isHidden = true
        chooseButton.isEnabled = false
        identifySpeakersButton.isEnabled = false
        needsDisplay = true
    }

    func finish(text: String, segments: [TranscriptSegment], seconds: Double) {
        titleLabel.stringValue = currentFileName ?? "Transcription"
        detailLabel.stringValue = String(format: "Completed in %.1f seconds", seconds)
        textView.string = text
        resultSegments = segments
        progress.stopAnimation(nil)
        progress.isHidden = true
        cancelButton.isHidden = true
        copyButton.isHidden = text.isEmpty
        saveButton.isHidden = text.isEmpty
        chooseButton.isEnabled = true
        identifySpeakersButton.isEnabled = speakerIdentificationAvailable
        window?.makeFirstResponder(textView)
        announce("Transcription complete")
    }

    func fail(_ message: String) {
        titleLabel.stringValue = "Transcription failed"
        detailLabel.stringValue = message
        textView.string = ""
        resultSegments = []
        progress.stopAnimation(nil)
        progress.isHidden = true
        cancelButton.isHidden = true
        copyButton.isHidden = true
        saveButton.isHidden = true
        chooseButton.isEnabled = true
        identifySpeakersButton.isEnabled = speakerIdentificationAvailable
        announce("Transcription failed. \(message)")
    }

    func cancel() {
        progress.stopAnimation(nil)
        showEmptyState()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedAudioURL(from: sender) != nil else { return [] }
        dragActive = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragActive = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragActive = false
        needsDisplay = true
        guard let url = droppedAudioURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard dragActive else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
        path.lineWidth = 3
        path.stroke()
    }

    private func buildContent() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping

        chooseButton.target = self
        chooseButton.action = #selector(choose)
        chooseButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        saveButton.target = self
        saveButton.action = #selector(savePressed)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.setAccessibilityLabel("Transcription progress")

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: 320)
        textView.setAccessibilityLabel("Transcription result")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView

        let status = NSStackView(views: [progress, titleLabel, NSView()])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 8

        identifySpeakersButton.toolTip = "Requires Speaker Identification in Models settings."
        let actions = NSStackView(views: [
            chooseButton,
            identifySpeakersButton,
            NSView(),
            cancelButton,
            copyButton,
            saveButton
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [status, detailLabel, scroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File transcription")

        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }

    private func showEmptyState() {
        currentFileName = nil
        titleLabel.stringValue = "Drop an audio file here"
        detailLabel.stringValue = "or choose a file from your Mac"
        textView.string = ""
        resultSegments = []
        progress.isHidden = true
        cancelButton.isHidden = true
        copyButton.isHidden = true
        saveButton.isHidden = true
        chooseButton.isEnabled = true
        identifySpeakersButton.isEnabled = speakerIdentificationAvailable
    }

    private func droppedAudioURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.audio.identifier]
        ]
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]
        guard urls?.count == 1 else { return nil }
        return urls?.first
    }

    @objc private func choose() { onChoose?() }
    @objc private func cancelPressed() { onCancel?() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func savePressed() { onSave?() }
}
