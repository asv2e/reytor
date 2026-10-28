//
//  NewIdentityController.swift
//  Reynard
//
//  Created by Minh Ton on 13/9/26.
//

import GeckoView
import UIKit

/// Implements Tor Browser's "New Identity" feature: closes every open tab and
/// purges cookies, site data, cache, and history so that subsequent browsing
/// can't be linked back to the previous session by a website or anyone with
/// access to the device.
enum NewIdentityController {
    static func confirmAndStart(from viewController: UIViewController) {
        AlertPresenter.show(
            title: NSLocalizedString("New Identity", comment: ""),
            message: NSLocalizedString("This will close all tabs and clear your browsing history, cookies, and cache. Websites won't be able to link your next visit to this session. This action cannot be undone.", comment: ""),
            buttons: [
                AlertPresenter.Button(
                    title: NSLocalizedString("New Identity", comment: "Destructive button"),
                    style: .destructive
                ) { [weak viewController] in
                    guard let viewController else {
                        return
                    }
                    start(from: viewController)
                },
                AlertPresenter.Button(title: NSLocalizedString("Cancel", comment: "")),
            ]
        )
    }
    
    private static func start(from viewController: UIViewController) {
        guard let browserViewController = LibrarySharedUtils.resolvedBrowserViewController(from: viewController) else {
            return
        }
        
        browserViewController.tabManager.removeAllTabs(mode: .regular)
        browserViewController.tabManager.removeAllTabs(mode: .private)
        browserViewController.tabManager.createTab(selecting: true, mode: .regular)
        
        // Closing tabs above may have filed them under "recently closed",
        // which would let the old session be restored.
        TabManagementStore.shared.clearRecentlyClosedTabs()
        HistoryStore.shared.clearVisits(since: nil)
        FaviconStore.shared.clearCache()
        
        // Tor-level half of New Identity: build fresh circuits so this new
        // session doesn't share a path (and therefore an exit node) with
        // whatever was just cleared. No-op if Tor isn't enabled.
        TorController.shared.requestNewIdentity()
        
        Task {
            try? await GeckoStorageController.clearHistory(since: nil)
            try? await GeckoStorageController.clearData(
                flags: GeckoStorageClearFlags.cookies | GeckoStorageClearFlags.authSessions
            )
            try? await GeckoStorageController.clearData(flags: GeckoStorageClearFlags.domStorages)
            try? await GeckoStorageController.clearData(flags: GeckoStorageClearFlags.allCaches)
        }
    }
}
