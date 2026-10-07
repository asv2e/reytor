//
//  TorPreferencesViewController.swift
//  Reynard
//
//  Created by Minh Ton on 13/9/26.
//

import GeckoView
import UIKit

final class TorPreferencesViewController: SettingsTableViewController {
    private enum Row: CaseIterable, Equatable {
        case status
        case connect
        case cancel
        case newCircuit
        case bridges
    }
    
    private var displayedRows: [Row] {
        var rows: [Row] = [.status]
        switch TorController.shared.state {
        case .disabled, .failed:
            rows.append(.connect)
        case .bootstrapping:
            rows.append(.cancel)
        case .connected:
            rows.append(.newCircuit)
        }
        rows.append(.bridges)
        return rows
    }
    
    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Tor Network", comment: "")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionStateDidChange),
            name: .torConnectionStateDidChange,
            object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayedRows.count
    }
    
    override func sectionText(for section: Int) -> SettingsSectionText {
        return SettingsSectionText(
            footerTitle: NSLocalizedString("All browsing is routed through the Tor network and this can't be turned off. Tor doesn't connect automatically: set up bridges first if your network blocks Tor, then tap Connect. Pages won't load until Tor is connected.", comment: "")
        )
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard displayedRows.indices.contains(indexPath.row) else {
            return UITableViewCell()
        }
        
        switch displayedRows[indexPath.row] {
        case .status:
            let cell = SettingsTableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Status", comment: "")
            cell.detailTextLabel?.text = statusDescription
            cell.selectionStyle = .none
            return cell
        case .connect:
            return SettingsViewUtils.actionCell(title: NSLocalizedString("Connect", comment: ""), tintColor: nil)
        case .cancel:
            return SettingsViewUtils.actionCell(title: NSLocalizedString("Cancel", comment: ""), tintColor: nil)
        case .newCircuit:
            return SettingsViewUtils.actionCell(title: NSLocalizedString("New Tor Circuit", comment: ""), tintColor: nil)
        case .bridges:
            let cell = SettingsTableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Bridges", comment: "")
            cell.detailTextLabel?.text = Prefs.TorPreferences.usesBridges
                ? NSLocalizedString("On", comment: "")
                : NSLocalizedString("Off", comment: "")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard displayedRows.indices.contains(indexPath.row) else {
            return
        }
        
        switch displayedRows[indexPath.row] {
        case .connect:
            TorController.shared.connect()
        case .cancel:
            TorController.shared.disconnect()
        case .newCircuit:
            TorController.shared.requestNewIdentity()
        case .bridges:
            let destination = TorBridgesPreferencesViewController()
            navigationController?.pushViewController(destination, animated: true)
        case .status:
            break
        }
    }
    
    private var statusDescription: String {
        switch TorController.shared.state {
        case .disabled:
            return NSLocalizedString("Not Connected", comment: "")
        case .bootstrapping(let percent):
            return String(format: NSLocalizedString("Connecting… %d%%", comment: ""), percent)
        case .connected:
            return NSLocalizedString("Connected", comment: "")
        case .failed:
            return NSLocalizedString("Connection Failed", comment: "")
        }
    }
    
    @objc private func connectionStateDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
        }
    }
}
