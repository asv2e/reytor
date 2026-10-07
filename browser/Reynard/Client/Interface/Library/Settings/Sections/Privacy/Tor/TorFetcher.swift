//
//  TorFetcher.swift
//  Reynard
//

import Foundation
import GeckoView

/// Fetches a URL into a temporary file through Gecko's own network stack,
/// so it goes through the Tor SOCKS proxy with remote DNS like all other
/// browsing traffic. Native URLSession requests can't be used for this:
/// they'd resolve DNS and connect outside Tor (see TorNativeNetworkGuard).
enum TorFetcher {
    struct FetchError: LocalizedError {
        let errorDescription: String?
    }
    
    /// Supplies a live Gecko session to run the fetch through. Set by the
    /// browser view controller.
    static var sessionProvider: (() -> GeckoSession?)?
    
    /// Returns a temporary file holding the response body. The caller owns
    /// the file and should move or remove it.
    @MainActor
    static func fetch(_ url: URL) async throws -> URL {
        guard TorController.shared.state == .connected else {
            throw FetchError(errorDescription: NSLocalizedString("Tor isn't connected yet.", comment: ""))
        }
        guard let session = sessionProvider?() else {
            throw FetchError(errorDescription: NSLocalizedString("The browser isn't ready yet.", comment: ""))
        }
        return try await session.savePDF(from: url.absoluteString)
    }
}
