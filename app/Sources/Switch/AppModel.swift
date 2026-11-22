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

enum SensorType: String {
    case leak, motion, button, contact
}

struct Battery: Equatable {
    let percent: Int?
    let level: String? // "ok", "warning", "critical"

    var isLow: Bool {
        if let percent { return percent <= 20 }
        return level == "warning" || level == "critical"
    }
}

struct Sensor: Identifiable, Equatable {
    let id: String
    var label: String
    var reachable: Bool
    var type: SensorType
    var active: Bool // leak detected, motion now, contact closed
    var battery: Battery?

    var isLeaking: Bool { type == .leak && active }
}

enum Tab: String {
    case plugs, sensors
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
    @Published private(set) var sensors: [Sensor] = []
    @Published private(set) var sensorsLoaded = false
    /// Last motion seen / last button press, per sensor id. Kept across launches.
    @Published private(set) var lastEvent: [String: Date] = [:]
    @Published var tab: Tab = .plugs {
        didSet {
            if tab != oldValue { editing = false }
            UserDefaults.standard.set(tab.rawValue, forKey: "tab")
        }
    }

    let helper: HelperClient
    private var errorClearTask: Task<Void, Never>?
    private static let customKey = "customizations"
    private static let eventsKey = "sensorEvents"
    private static let maxNameLength = 24

    init() {
        helper = HelperClient()
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let saved = try? JSONDecoder().decode([String: Customization].self, from: data) {
            custom = saved
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.eventsKey) as? [String: Double] {
            lastEvent = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
        tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .plugs
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

    var visibleSensors: [Sensor] { sensors.filter { !isHidden($0.id) } }

    /// A leak counts even on a hidden sensor: water is not something to miss.
    var anyLeak: Bool { sensors.contains { $0.isLeaking } }

    var anyLowBattery: Bool { visibleSensors.contains { $0.battery?.isLow == true } }

    var needsAttention: Bool { anyLeak || anyLowBattery }

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

    func isHidden(_ device: Device) -> Bool { isHidden(device.id) }

    func isHidden(_ id: String) -> Bool {
        custom[id]?.hidden ?? false
    }

    func setHidden(_ hidden: Bool, for device: Device) { setHidden(hidden, id: device.id) }

    func setHidden(_ hidden: Bool, id: String) {
        var entry = custom[id] ?? Customization()
        entry.hidden = hidden
        custom[id] = entry
        saveCustom()
    }

    // MARK: - Sensor names

    func defaultName(for sensor: Sensor) -> String {
        if !sensor.label.trimmingCharacters(in: .whitespaces).isEmpty { return sensor.label }
        let same = sensors.filter { $0.type == sensor.type }
        let base = L10n.shared.t("sensor.\(sensor.type.rawValue)")
        guard same.count > 1, let index = same.firstIndex(where: { $0.id == sensor.id }) else { return base }
        return "\(base) \(index + 1)"
    }

    func displayName(for sensor: Sensor) -> String {
        if let name = custom[sensor.id]?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return defaultName(for: sensor)
    }

    func customName(id: String) -> String {
        custom[id]?.name ?? ""
    }

    func setName(_ name: String, id: String) {
        var entry = custom[id] ?? Customization()
        entry.name = String(name.prefix(Self.maxNameLength))
        custom[id] = entry
        saveCustom()
    }

    private func recordEvent(_ id: String) {
        lastEvent[id] = Date()
        UserDefaults.standard.set(lastEvent.mapValues { $0.timeIntervalSince1970 }, forKey: Self.eventsKey)
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
        case "sensors":
            let incoming: [Sensor] = (event.sensors ?? []).compactMap { raw in
                guard let type = SensorType(rawValue: raw.type) else { return nil }
                let battery = raw.battery.map { Battery(percent: $0.percent, level: $0.level) }
                return Sensor(id: raw.id, label: raw.label ?? "", reachable: raw.reachable ?? true,
                              type: type, active: raw.active ?? false, battery: battery)
            }
            // Motion: remember when it was last seen (start and end of each movement).
            for sensor in incoming where sensor.type == .motion {
                let before = sensors.first { $0.id == sensor.id }?.active
                if sensor.active || before == true { recordEvent(sensor.id) }
            }
            sensors = incoming
            sensorsLoaded = true
            if tab == .sensors && sensors.isEmpty { editing = false }
        case "press":
            if let id = event.id { recordEvent(id) }
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
            sensors = []
            sensorsLoaded = false
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
