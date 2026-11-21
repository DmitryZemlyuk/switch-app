import Foundation
import SwiftUI

enum Connection: Equatable {
    case starting, unpaired, pairing, searching, connected, reconnecting, disconnected, helperFailed, nodeMissing
}

enum IconKind: String, Codable {
    case plug, light
}

struct Device: Identifiable, Equatable {
    let id: String
    var label: String
    var on: Bool
    var reachable: Bool
    var kind: IconKind
}

/// What the user changed for a device: stored per Matter endpoint id.
struct Customization: Codable, Equatable {
    var name: String?
    var icon: IconKind?
    var hidden: Bool?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connection: Connection = .starting
    @Published private(set) var devices: [Device] = []
    @Published private(set) var devicesLoaded = false
    @Published var editing = false
    @Published private(set) var errorKey: String?
    @Published private(set) var custom: [String: Customization] = [:]

    let helper: HelperClient
    private var errorClearTask: Task<Void, Never>?
    private static let customKey = "customizations"
    private static let maxNameLength = 24

    init() {
        helper = HelperClient()
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let saved = try? JSONDecoder().decode([String: Customization].self, from: data) {
            custom = saved
        }
        helper.onEvent = { [weak self] event in self?.handle(event) }
        helper.onCrash = { [weak self] in
            guard let self, self.connection != .unpaired else { return }
            self.connection = .helperFailed
        }
        helper.onNodeMissing = { [weak self] in self?.connection = .nodeMissing }
        helper.start()
    }

    /// Devices shown as tiles: everything the user has not hidden in edit mode.
    var visibleDevices: [Device] { devices.filter { !isHidden($0) } }

    var anyOn: Bool { visibleDevices.contains { $0.on } }

    var canControl: Bool { connection == .connected }

    // MARK: - Names and icons

    func defaultName(for device: Device) -> String {
        if !device.label.trimmingCharacters(in: .whitespaces).isEmpty { return device.label }
        let index = (devices.firstIndex { $0.id == device.id } ?? 0) + 1
        return L10n.shared.t("defaultName", index)
    }

    func displayName(for device: Device) -> String {
        if let name = custom[device.id]?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return defaultName(for: device)
    }

    func customName(for device: Device) -> String {
        custom[device.id]?.name ?? ""
    }

    func icon(for device: Device) -> IconKind {
        custom[device.id]?.icon ?? device.kind
    }

    func setName(_ name: String, for device: Device) {
        var entry = custom[device.id] ?? Customization()
        entry.name = String(name.prefix(Self.maxNameLength))
        custom[device.id] = entry
        saveCustom()
    }

    func setIcon(_ icon: IconKind, for device: Device) {
        var entry = custom[device.id] ?? Customization()
        entry.icon = icon
        custom[device.id] = entry
        saveCustom()
    }

    func isHidden(_ device: Device) -> Bool {
        custom[device.id]?.hidden ?? false
    }

    func setHidden(_ hidden: Bool, for device: Device) {
        var entry = custom[device.id] ?? Customization()
        entry.hidden = hidden
        custom[device.id] = entry
        saveCustom()
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }

    // MARK: - Actions

    func toggle(_ device: Device) {
        guard canControl, device.reachable,
              let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let target = !devices[index].on
        devices[index].on = target // optimistic; the helper confirms or reverts
        helper.send(["cmd": "set", "id": device.id, "on": target])
    }

    func pair(code: String) {
        errorKey = nil
        connection = .pairing
        helper.send(["cmd": "pair", "code": code])
    }

    func unpair() {
        editing = false
        helper.send(["cmd": "unpair"])
    }

    func refresh() {
        helper.send(["cmd": "refresh"])
    }

    // MARK: - Helper events

    private func handle(_ event: HelperEvent) {
        switch event.ev {
        case "state":
            apply(state: event.state ?? "")
        case "devices":
            devices = (event.devices ?? []).map {
                Device(id: $0.id, label: $0.label ?? "", on: $0.on, reachable: $0.reachable ?? true,
                       kind: IconKind(rawValue: $0.kind ?? "") ?? .plug)
            }
            devicesLoaded = true
            if devices.isEmpty { editing = false }
        case "update":
            if let id = event.id, let on = event.on, let index = devices.firstIndex(where: { $0.id == id }) {
                devices[index].on = on
            }
        case "error":
            handleError(code: event.code ?? "")
        default:
            break
        }
    }

    private func apply(state: String) {
        switch state {
        case "unpaired":
            connection = .unpaired
            devices = []
            devicesLoaded = false
            editing = false
        case "pairing": connection = .pairing
        case "searching": connection = .searching
        case "connected": connection = .connected
        case "reconnecting": connection = .reconnecting
        case "disconnected": connection = .disconnected
        default: break
        }
    }

    private func handleError(code: String) {
        switch code {
        case "start_failed":
            connection = .helperFailed
        case "bad_code", "pair_failed", "set_failed", "already_paired":
            show(errorKey: "err.\(code)")
            // These errors arrive without a state change: ask the helper where it really is.
            if connection == .pairing && code != "pair_failed" { refresh() }
        default:
            break // details are in the helper log
        }
    }

    private func show(errorKey key: String) {
        errorKey = key
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.errorKey = nil
        }
    }
}
