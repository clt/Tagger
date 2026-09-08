import Foundation

protocol AutoTaggingServicing: Sendable {
    func search(_ request: AutoTagSearchRequest) async throws -> AutoTagSearchOutcome
    func resolve(
        _ candidate: AutoTagCandidate,
        for request: AutoTagSearchRequest
    ) async throws -> AutoTagProposal
}

actor AutoTaggingService: AutoTaggingServicing {
    private let filenameInference: FilenameTagInference
    private let musicBrainz: any MusicBrainzSearching

    init(
        filenameInference: FilenameTagInference = FilenameTagInference(),
        musicBrainz: any MusicBrainzSearching = MusicBrainzClient()
    ) {
        self.filenameInference = filenameInference
        self.musicBrainz = musicBrainz
    }

    func search(_ request: AutoTagSearchRequest) async throws -> AutoTagSearchOutcome {
        let localCandidate = filenameInference.candidate(for: request)
        // Online search is explicit. A request without a seed is local-only.
        guard let seed = request.searchSeed else {
            return AutoTagSearchOutcome(
                candidates: localCandidate.map { [$0] } ?? [],
                warningMessage: nil
            )
        }

        do {
            let remoteCandidates = try await musicBrainz.search(seed: seed)
            return AutoTagSearchOutcome(
                candidates: (localCandidate.map { [$0] } ?? []) + remoteCandidates,
                warningMessage: remoteCandidates.isEmpty
                    ? "No MusicBrainz matches found. Try different search terms."
                    : nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let localCandidate else { throw error }
            return AutoTagSearchOutcome(
                candidates: [localCandidate],
                warningMessage: "MusicBrainz couldn’t be reached. The file-name suggestion is still available."
            )
        }
    }

    func resolve(
        _ candidate: AutoTagCandidate,
        for request: AutoTagSearchRequest
    ) async throws -> AutoTagProposal {
        switch candidate.reference {
        case .filename:
            return AutoTagProposal(candidate: candidate, values: candidate.preview)
        case .musicBrainz:
            return try await musicBrainz.resolve(candidate: candidate, request: request)
        }
    }
}
