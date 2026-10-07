//
//  TorNativeNetworkGuard.swift
//  Reynard
//

import Foundation

/// Gecko's SOCKS proxy prefs only cover Gecko's own networking. Native
/// URLSession / Data(contentsOf:) requests (search suggestions, favicons,
/// downloads, update checks, ...) go straight out through the system
/// resolver and leak both DNS and IP. Tor is mandatory, so this protocol
/// always fails native http(s) requests instead of letting them escape.
final class TorNativeNetworkGuard: URLProtocol {
    static func install() {
        URLProtocol.registerClass(TorNativeNetworkGuard.self)
    }

    /// URLProtocol.registerClass only covers URLSession.shared; sessions
    /// built from a custom configuration must opt in explicitly.
    static func guarded(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        var classes = configuration.protocolClasses ?? []
        classes.insert(TorNativeNetworkGuard.self, at: 0)
        configuration.protocolClasses = classes
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
