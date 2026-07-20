import AppKit
import Testing
@testable import Tiro

@Suite(.serialized)
struct ModelManagementViewTests {
    @Test @MainActor
    func serviceRefusesToDeleteSelectedModel() async {
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        DictationModel.select(.coreMLCompact)

        let service = TiroService()
        service.startDelete(key: DictationModel.coreMLCompactKey)

        #expect(
            service.modelOperationError(for: DictationModel.coreMLCompactKey)
                == "Select another transcription model before deleting this one."
        )
    }

    @Test @MainActor
    func staleActivationCannotOverwriteNewerSelection() async throws {
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        let service = TiroService()
        try service.select(model: available[0])
        try service.select(model: available[1])

        try await service.activate(model: available[0])

        #expect(DictationModel.selected.key == available[1].key)
    }

    @Test @MainActor
    func changingTableSelectionDoesNotReenterItsDelegate() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }

        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        DictationModel.select(available[0])

        let view = ModelManagementView(service: TiroService())
        var changedModels: [String] = []
        view.onModelChanged = { changedModels.append($0.key) }
        view.apply(available.map { managedModel($0) })
        let table = try #require(firstSubview(of: NSTableView.self, in: view))

        table.selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        #expect(DictationModel.selected.key == available[1].key)
        #expect(changedModels == [available[1].key])
        #expect(table.selectedRow == 1)
        view.cancelWork()
    }

    @Test @MainActor
    func deletingSelectionFallsBackWithoutReenteringDelegate() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        DictationModel.select(available[0])

        let view = ModelManagementView(service: TiroService())
        var changedModels: [String] = []
        view.onModelChanged = { changedModels.append($0.key) }
        view.apply(available.map { managedModel($0) })
        changedModels.removeAll()

        view.apply([
            managedModel(available[0], usable: false, deleting: true),
            managedModel(available[1]),
        ])

        #expect(DictationModel.selected.key == available[1].key)
        #expect(changedModels == [available[1].key])
        view.cancelWork()
    }

    private func restoreSelection(
        _ selection: String?,
        in defaults: UserDefaults
    ) {
        if let selection {
            defaults.set(selection, forKey: "selectedModel")
        } else {
            defaults.removeObject(forKey: "selectedModel")
        }
    }

    @MainActor
    private func managedModel(
        _ model: DictationModel,
        usable: Bool = true,
        deleting: Bool = false
    ) -> ManagedModel {
        ManagedModel(
            key: model.key,
            installedSizeBytes: 1,
            installed: true,
            usable: usable,
            operation: deleting ? .deleting : nil,
            loaded: false,
            operationError: nil,
            downloadSpace: nil,
            state: "ready"
        )
    }

    @MainActor
    private func firstSubview<T: NSView>(
        of type: T.Type,
        in view: NSView
    ) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap {
            firstSubview(of: type, in: $0)
        }.first
    }
}
