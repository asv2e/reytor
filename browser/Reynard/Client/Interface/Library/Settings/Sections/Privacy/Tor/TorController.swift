//
//  TorController.swift
//  Reynard
//
//  Created by Minh Ton on 13/9/26.
//

import Foundation

enum TorConnectionState: Equatable {
    case disabled
    case bootstrapping(percent: Int)
    case connected
    case failed(String)
}

/// Owns the lifecycle of the embedded Arti Tor client and keeps Gecko's
/// proxy prefs (via TorProxyPolicyController) in sync with it. A single
/// shared instance is used since there's only ever one Tor client for the
/// whole app, mirroring how TrackingProtectionPolicyController etc. operate
/// on the single shared GeckoRuntime.
final class TorController {
    static let shared = TorController()
    
    // Arbitrary local port for the embedded SOCKS forwarder. Not
    // user-configurable since nothing outside this process ever connects
    // to it.
    private let socksPort: UInt16 = 19_050
    
    private(set) var state: TorConnectionState = .disabled {
        didSet {
            guard state != oldValue else { return }
            applyProxyForCurrentState()
            NotificationCenter.default.post(name: .torConnectionStateDidChange, object: self)
        }
    }
    
    private init() {}
    
    /// Called once at app startup (from RuntimePreferences). Tor is
    /// mandatory but doesn't connect on its own, so bridges can be set up
    /// first; until the user connects, the proxy stays blocked.
    func applyStartupState() {
        TorProxyPolicyController.applyBlocked()
    }
    
    /// Starts Tor if it isn't already running or connecting.
    func connect() {
        switch state {
        case .disabled, .failed:
            start()
        case .bootstrapping, .connected:
            break
        }
    }
    
    /// Stops Tor (e.g. to cancel a connection attempt and edit bridges).
    /// Traffic stays blocked, it never falls back to direct.
    func disconnect() {
        guard state != .disabled else { return }
        stop()
    }
    
    /// Tor-level half of "New Identity": discards the current client's
    /// circuits so subsequent connections take a fresh path. No-ops if Tor
    /// isn't enabled - NewIdentityController still clears cookies/history
    /// either way.
    func requestNewIdentity() {
        guard Prefs.TorPreferences.enabled else { return }
        ArtiTorClient.shared.requestNewIdentity()
    }

    /// Narrower than requestNewIdentity: fresh circuits for one site's
    /// hostname only, leaving every other open tab's circuits alone.
    func requestNewCircuit(forHost host: String) {
        guard Prefs.TorPreferences.enabled else { return }
        ArtiTorClient.shared.requestNewCircuit(forHost: host)
    }
    
    /// Restarts the Arti client so a bridge-configuration change takes
    /// effect. Bridges are only read at client startup (arti_start refuses
    /// to reconfigure an already-running client), so this is the only way
    /// to apply an edit made while Tor is already connected. No-ops if Tor
    /// isn't currently enabled - the new config will simply be picked up
    /// next time it's turned on.
    func reconnect() {
        guard state != .disabled else { return }
        stop()
        start()
    }
    
    private func start() {
        state = .bootstrapping(percent: 0)
        
        guard let directories = Self.prepareDirectories() else {
            state = .failed(NSLocalizedString("Couldn't create local storage for Tor.", comment: ""))
            return
        }
        
        let bridgeLines = Prefs.TorPreferences.usesBridges ? Prefs.TorPreferences.bridgeLines : ""
        let (obfs4Port, snowflakePort) = Self.startPluggableTransportsIfNeeded(for: bridgeLines)
        
        ArtiTorClient.shared.start(
            withStateDirectory: directories.state,
            cacheDirectory: directories.cache,
            socksPort: socksPort,
            bridgeLines: bridgeLines.isEmpty ? nil : bridgeLines,
            obfs4ProxyPort: obfs4Port,
            snowflakeProxyPort: snowflakePort
        ) { [weak self] kind, percent, message in
            self?.handleEvent(kind: kind, percent: percent, message: message)
        }
    }
    
    private func stop() {
        ArtiTorClient.shared.stop()
        PluggableTransportController.stopObfs4()
        PluggableTransportController.stopSnowflake()
        state = .disabled
    }
    
    /// Starts whichever of IPtProxy's transports the configured bridge
    /// lines actually need (skips ones already covered - obfs4/snowflake
    /// keep running across a reconnect rather than restarting), and
    /// returns their local ports (0 = not needed / failed to start, in
    /// which case arti_start will skip that transport's bridge lines
    /// rather than failing outright).
    private static func startPluggableTransportsIfNeeded(for bridgeLines: String) -> (obfs4: UInt16, snowflake: UInt16) {
        var needsObfs4 = false
        var snowflakeBridgeLine: String?
        
        for rawLine in bridgeLines.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            let tokens = line.split(separator: " ")
            guard tokens.count > 1 else {
                continue
            }
            switch tokens[1].lowercased() {
            case "obfs4":
                needsObfs4 = true
            case "snowflake":
                snowflakeBridgeLine = line
            default:
                break
            }
        }
        
        let obfs4Port = needsObfs4 ? (PluggableTransportController.startObfs4() ?? 0) : 0
        let snowflakePort = snowflakeBridgeLine != nil
            ? (PluggableTransportController.startSnowflake(bridgeLine: snowflakeBridgeLine) ?? 0)
            : 0
        
        return (obfs4Port, snowflakePort)
    }
    
    private func handleEvent(kind: ArtiTorEventKind, percent: Int, message: String?) {
        // Late events from a client that was just stopped/cancelled must
        // not move us back to bootstrapping or connected.
        guard state != .disabled else { return }
        switch kind {
        case .bootstrapProgress:
            state = .bootstrapping(percent: percent)
        case .connected:
            state = .connected
        case .error:
            state = .failed(message ?? NSLocalizedString("Unknown Tor error", comment: ""))
        case .stopped:
            // Only clobber an error state with .disabled if the user
            // actually turned Tor off - otherwise keep the failure visible
            // instead of quietly reporting "disabled".
            if !Prefs.TorPreferences.enabled {
                state = .disabled
            }
        @unknown default:
            break
        }
    }
    
    private func applyProxyForCurrentState() {
        switch state {
        case .disabled, .bootstrapping, .failed:
            TorProxyPolicyController.applyBlocked()
        case .connected:
            TorProxyPolicyController.applyConnected(socksPort: socksPort)
        }
    }
    
    private static func prepareDirectories() -> (state: String, cache: String)? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stateURL = appSupport.appendingPathComponent("Tor/state", isDirectory: true)
        let cacheURL = appSupport.appendingPathComponent("Tor/cache", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stateURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return (stateURL.path, cacheURL.path)
    }
}
