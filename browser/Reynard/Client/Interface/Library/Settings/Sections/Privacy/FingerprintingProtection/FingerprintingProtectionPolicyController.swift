//
//  FingerprintingProtectionPolicyController.swift
//  Reynard
//
//  Created by Minh Ton on 13/9/26.
//

import GeckoView
import UIKit

extension Notification.Name {
    static let fingerprintingProtectionDidChange = Notification.Name("FingerprintingProtectionDidChange")
}

enum FingerprintingProtectionPolicyController {
    /// Whether the web content area should be letterboxed.
    static var isLetterboxingActive: Bool {
        let preferences = Prefs.FingerprintingProtectionPreferences.self
        return preferences.enabled && preferences.letterboxingEnabled
    }
    
    /// Rounds the available web content size down to a small set of
    /// standard sizes, so the page's window dimensions reveal only a
    /// coarse bucket instead of the device's exact screen/window size.
    /// Bigger windows use coarser steps, which keeps the number of
    /// distinct sizes (and so the fingerprinting surface) small.
    static func letterboxedSize(for size: CGSize) -> CGSize {
        func bucket(_ length: CGFloat) -> CGFloat {
            let step: CGFloat = length <= 600 ? 50 : (length <= 1200 ? 100 : 200)
            return max(step, (length / step).rounded(.down) * step)
        }
        return CGSize(width: min(size.width, bucket(size.width)), height: min(size.height, bucket(size.height)))
    }
    
    /// Applies Tor Browser-style "Resist Fingerprinting" protections.
    ///
    /// When enabled, this spoofs several commonly-fingerprinted signals (screen
    /// dimensions via letterboxing, timezone, locale, hardware concurrency, etc.)
    /// so that Reynard's users are harder to distinguish from one another, the
    /// same strategy used by Tor Browser to blend users into a common anonymity
    /// set instead of just blocking known trackers.
    static func applyFingerprintingProtection() {
        let preferences = Prefs.FingerprintingProtectionPreferences.self
        let isEnabled = preferences.enabled
        
        GeckoRuntime.setDefaultPrefs([
            // Core resist-fingerprinting mode: spoofs timezone (UTC), locale,
            // hardware concurrency, canvas/audio/font enumeration, and more.
            "privacy.resistFingerprinting": isEnabled,
            
            // Rounds the reported window/content dimensions to a fixed set of
            // "letterboxed" buckets instead of the device's real size, exactly
            // like Tor Browser's window resizing protection.
            "privacy.resistFingerprinting.letterboxing": isEnabled && preferences.letterboxingEnabled,
            
            // WebRTC can leak a device's local/public IP addresses even through
            // a proxy or VPN, so Tor Browser disables it outright.
            // Tor is mandatory, so WebRTC stays off no matter what this
            // toggle says (it would otherwise undo TorProxyPolicyController).
            "media.peerconnection.enabled": !Prefs.TorPreferences.enabled && !(isEnabled && preferences.blocksWebRTC),
            
            // Reports a single, generic "en-US" language instead of the user's
            // real locale preferences, matching Tor Browser's default of not
            // revealing locale via Accept-Language.
            "privacy.spoof_english": isEnabled && preferences.spoofsAcceptLanguage ? 2 : 0,
        ])
        
        NotificationCenter.default.post(name: .fingerprintingProtectionDidChange, object: nil)
    }
}
