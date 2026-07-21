import Foundation

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let pageURL: URL
    let draft: Bool
    let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case draft
        case prerelease
    }
}

enum UpdateCheckResult: Equatable {
    case updateAvailable(GitHubRelease)
    case current(GitHubRelease)
    case untaggedBuild(GitHubRelease)
}

enum UpdateCheckerError: LocalizedError {
    case invalidResponse
    case noRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an unexpected response."
        case .noRelease: return "No published Tiro release was found."
        }
    }
}

struct ReleaseVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let beta: Int?

    init?(_ tag: String) {
        let normalized = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let releaseParts = normalized.components(separatedBy: "-beta.")
        guard releaseParts.count <= 2 else { return nil }
        let core = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]),
              let minor = Int(core[1]),
              let patch = Int(core[2]) else { return nil }
        let beta: Int?
        if releaseParts.count == 2 {
            guard !releaseParts[1].isEmpty, let number = Int(releaseParts[1]) else { return nil }
            beta = number
        } else {
            beta = nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = beta
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore { return lhsCore.lexicographicallyPrecedes(rhsCore) }
        switch (lhs.beta, rhs.beta) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        default: return false
        }
    }
}

enum UpdateChecker {
    static func check(
        currentTag: String?,
        session: URLSession = .shared
    ) async throws -> UpdateCheckResult {
        var request = URLRequest(url: BuildFeatures.releasesAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tiro update checker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else { throw UpdateCheckerError.invalidResponse }
        return try result(currentTag: currentTag, data: data)
    }

    static func result(currentTag: String?, data: Data) throws -> UpdateCheckResult {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        let current = currentTag.flatMap(ReleaseVersion.init)
        let published = releases.compactMap { release -> (GitHubRelease, ReleaseVersion)? in
            guard !release.draft,
                  current == nil || current?.beta != nil || !release.prerelease,
                  let version = ReleaseVersion(release.tagName) else { return nil }
            return (release, version)
        }
        guard let (release, latest) = published.max(by: { $0.1 < $1.1 }) else {
            throw UpdateCheckerError.noRelease
        }
        guard let current else {
            return .untaggedBuild(release)
        }
        return latest > current ? .updateAvailable(release) : .current(release)
    }
}
