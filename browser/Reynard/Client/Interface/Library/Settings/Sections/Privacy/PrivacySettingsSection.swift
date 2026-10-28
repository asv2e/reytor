//
//  PrivacySettingsSection.swift
//  Reynard
//
//  Created by Minh Ton on 18/6/26.
//

import UIKit

struct PrivacySettingsSection {
    enum Row: CaseIterable {
        case securityLevel
        case sitePermissions
        case cookieData
        case httpsOnlyMode
        case dnsOverHTTPS
        case trackingProtection
        case contentBlocker
        case fingerprintingProtection
        case websiteIsolation
        case javaScript
        case torNetwork
        case antiXSS
        case amnesicMode
        case newIdentity
    }
    
    var rowCount: Int {
        return Row.allCases.count
    }
    
    func cell(at index: Int) -> UITableViewCell {
        guard Row.allCases.indices.contains(index) else {
            return UITableViewCell()
        }
        
        switch Row.allCases[index] {
        case .securityLevel:
            let cell = SettingsTableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Security Level", comment: "")
            cell.detailTextLabel?.text = Prefs.SecurityLevelPreferences.level.title
            cell.accessoryType = .disclosureIndicator
            return cell
        case .sitePermissions:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Website Permissions", comment: ""))
        case .cookieData:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Cookies & Site Data", comment: ""))
        case .httpsOnlyMode:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("HTTPS-Only Mode", tableName: "SettingsLocalizable", comment: ""))
        case .dnsOverHTTPS:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("DNS over HTTPS", tableName: "SettingsLocalizable", comment: ""))
        case .trackingProtection:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Tracking Protection", comment: ""))
        case .contentBlocker:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Content Blocker", comment: ""))
        case .fingerprintingProtection:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Fingerprinting Protection", tableName: "SettingsLocalizable", comment: ""))
        case .websiteIsolation:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Website Isolation", comment: ""))
        case .javaScript:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("JavaScript", comment: ""))
        case .torNetwork:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Tor Network", comment: ""))
        case .antiXSS:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Anti-XSS Protection", comment: ""))
        case .amnesicMode:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Amnesic Mode", comment: ""))
        case .newIdentity:
            return SettingsViewUtils.actionCell(title: NSLocalizedString("New Identity", comment: ""), tintColor: .systemRed)
        }
    }
    
    func selectRow(at index: Int, from viewController: UIViewController) {
        guard Row.allCases.indices.contains(index) else {
            return
        }
        
        switch Row.allCases[index] {
        case .securityLevel:
            let destination = SecurityLevelPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .sitePermissions:
            let destination = SitePermissionsViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .cookieData:
            let destination = CookieDataPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .httpsOnlyMode:
            let destination = HTTPSOnlyModePreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .dnsOverHTTPS:
            let destination = DNSOverHTTPSPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .trackingProtection:
            let destination = TrackingProtectionPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .contentBlocker:
            let destination = ContentBlockerPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .fingerprintingProtection:
            let destination = FingerprintingProtectionPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .websiteIsolation:
            let destination = WebsiteIsolationPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .javaScript:
            let destination = JavaScriptPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .torNetwork:
            let destination = TorPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .antiXSS:
            let destination = AntiXSSPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .amnesicMode:
            let destination = AmnesicPreferencesViewController()
            viewController.navigationController?.pushViewController(destination, animated: true)
        case .newIdentity:
            NewIdentityController.confirmAndStart(from: viewController)
        }
    }
}
