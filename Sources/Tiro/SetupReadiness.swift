struct SetupReadiness: Equatable {
    let microphoneAllowed: Bool
    let accessibilityAllowed: Bool
    let selectedModelKey: String
    let usableModelKeys: Set<String>

    var selectedModelReady: Bool { usableModelKeys.contains(selectedModelKey) }

    var canFinish: Bool {
        microphoneAllowed && accessibilityAllowed && selectedModelReady
    }
}

enum ModelInventoryStatus: Equatable {
    case loading
    case available
    case missing
    case unavailable

    var afterPreparationFailure: ModelInventoryStatus {
        self == .available ? .available : .unavailable
    }
}
