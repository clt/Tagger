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
    private let coverArt: any CoverArtFetching

    init(
        filenameInference: FilenameTagInference = FilenameTagInference(),
        musicBrainz: any MusicBrainzSearching = MusicBrainzClient(),
        coverArt: any CoverArtFetching = CoverArtArchiveClient()
    ) {
        self.filenameInference = filenameInference
        self.musicBrainz = musicBrainz
        self.coverArt = coverArt
    }

    func search(_ request: AutoTagSearchRequest) async throws -> AutoTagSearchOutcome {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            return AutoTagSearchOutcome(
                candidates: (localCandidate.map { [$0] } ?? []) + remoteCandidates,
                warningMessage: remoteCandidates.isEmpty
                    ? "No MusicBrainz matches found. Try different search terms."
                    : nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
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
        try Task.checkCancellation()
        switch candidate.reference {
        case .filename:
            return AutoTagProposal(candidate: candidate, values: candidate.preview)
        case .musicBrainz(_, let releaseID):
            var proposal = try await musicBrainz.resolve(candidate: candidate, request: request)
            try Task.checkCancellation()
            guard let releaseID else { return proposal }

            do {
                proposal.artwork = try await coverArt.frontCover(forReleaseID: releaseID)
                try Task.checkCancellation()
                if proposal.artwork == nil {
                    proposal.artworkMessage = "No front cover is available for this release."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                proposal.artworkMessage = "Cover art couldn’t be loaded. \(error.localizedDescription) Text tag suggestions are still available."
            }
            return proposal
        }
    }
}
