struct SetupReadiness: Equatable {
    let microphoneAllowed: Bool
    let accessibilityAllowed: Bool
    let installedModelKeys: Set<String>

    var hasInstalledModel: Bool { !installedModelKeys.isEmpty }

    var canFinish: Bool {
        microphoneAllowed && accessibilityAllowed && hasInstalledModel
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
