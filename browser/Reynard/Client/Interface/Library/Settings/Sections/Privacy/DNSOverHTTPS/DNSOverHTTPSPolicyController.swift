//
//  DNSOverHTTPSPolicyController.swift
//  Reynard
//
//  Created by Minh Ton on 4/9/26.
//

import GeckoView

enum DNSOverHTTPSPolicyController {
    static func applyDNSOverHTTPS() {
        let preferences = Prefs.DNSOverHTTPSPreferences.self
        let selectedProviderURL = preferences.provider.url ?? preferences.customProviderURL
        
        GeckoRuntime.setDefaultPrefs([
            "doh-rollout.enabled": true,
            // Any DoH settings change re-runs this; keep DoH off while Tor
            // is enabled so it can't undo TorProxyPolicyController's override.
            "network.trr.mode": Prefs.TorPreferences.enabled
                ? DNSOverHTTPSProtectionLevel.noProtection.rawValue
                : preferences.protectionLevel.rawValue,
            "network.trr.uri": selectedProviderURL,
            "network.trr.default_provider_uri": SecureDNSProvider.cloudflare.url ?? "",
            "network.trr.excluded-domains": preferences.exceptions.joined(separator: ","),
        ])
    }
}
