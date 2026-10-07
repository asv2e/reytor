//
//  BrowserViewController+TorSetup.swift
//  Reynard
//

import UIKit

private enum TorConnectPrompt {
    static var hasBeenShown = false
}

extension BrowserViewController {
    /// Tor is mandatory but never connects on its own, so bridges can be
    /// configured first. Asked once per launch while Tor is not connected.
    func presentTorConnectPromptIfNeeded() {
        guard !TorConnectPrompt.hasBeenShown,
              TorController.shared.state == .disabled,
              presentedViewController == nil else {
            return
        }
        TorConnectPrompt.hasBeenShown = true
        
        let alert = UIAlertController(
            title: NSLocalizedString("Connect to Tor", comment: ""),
            message: NSLocalizedString("All browsing goes through Tor, and pages won't load until it's connected. If your network blocks Tor, set up a bridge first.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Connect", comment: ""), style: .default) { _ in
            TorController.shared.connect()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Configure Bridges", comment: ""), style: .default) { [weak self] _ in
            self?.presentTorSetup()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Not Now", comment: ""), style: .cancel))
        present(alert, animated: true)
    }
    
    private func presentTorSetup() {
        let torPreferences = TorPreferencesViewController()
        torPreferences.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissTorSetup)
        )
        let navigationController = UINavigationController(rootViewController: torPreferences)
        navigationController.modalPresentationStyle = .pageSheet
        present(navigationController, animated: true)
    }
    
    @objc private func dismissTorSetup() {
        dismiss(animated: true)
    }
}
