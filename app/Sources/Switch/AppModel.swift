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
    var watts: Double? // nil when the device has no power meter
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
    case plugs, sensors, humidifier
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
    /// What the last button press was: "single", "double", "long" or "multi:<count>".
    @Published private(set) var lastPress: [String: String] = [:]
    /// Devices currently blinking after "Identify".
    @Published private(set) var identifying: Set<String> = []
    // Humidifier
    @Published private(set) var humidifierConfigured = false
    @Published private(set) var humidifier: HumidifierState?
    @Published private(set) var humidifierOnline: Bool?
    @Published private(set) var humidifierSearching = false
    @Published private(set) var foundHumidifiers: [FoundHumidifier]?
    /// Target shown while the user taps − / +; sent after a short pause.
    @Published private(set) var pendingTarget: Int?
    private var targetTask: Task<Void, Never>?

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
    private static let pressKey = "lastPress"
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
        lastPress = UserDefaults.standard.dictionary(forKey: Self.pressKey) as? [String: String] ?? [:]
        helper.onEvent = { [weak self] event in self?.handle(event) }
        helper.onCrash = { [weak self] in
            guard let self else { return }
            self.humidifierSearching = false
            self.humidifierDumping = false
            if self.humidifierConfigured { self.humidifierOnline = false }
            guard self.connection != .unpaired else { return }
            self.connection = .helperFailed
        }
        helper.onNodeMissing = { [weak self] in self?.connection = .nodeMissing }
        helper.onStart = { [weak self] in self?.sendHumidifierConfig() }
        humidifierConfigured = HumidifierStore.load() != nil
        helper.start()
    }

    /// Devices shown as tiles: everything the user has not hidden in edit mode.
    var visibleDevices: [Device] { devices.filter { !isHidden($0) } }

    var anyOn: Bool { visibleDevices.contains { $0.on } }

    var visibleSensors: [Sensor] { sensors.filter { !isHidden($0.id) } }

    /// A leak counts even on a hidden sensor: water is not something to miss.
    var anyLeak: Bool { sensors.contains { $0.isLeaking } }

    var anyLowBattery: Bool { visibleSensors.contains { $0.battery?.isLow == true } }

    var sensorsNeedAttention: Bool { anyLeak || anyLowBattery }

    /// Red: humidifier opened or reporting a fault. Orange: low water.
    var humidifierAlert: Bool {
        guard humidifierConfigured, let h = humidifier, humidifierOnline == true else { return false }
        return h.water == .open || h.fault != 0
    }

    var humidifierWarning: Bool {
        guard humidifierConfigured, let h = humidifier, humidifierOnline == true else { return false }
        return h.water == .low
    }

    var needsAttention: Bool { sensorsNeedAttention || humidifierAlert || humidifierWarning }

    /// Whether the menu bar dot should be red rather than orange.
    var attentionIsAlert: Bool { anyLeak || humidifierAlert }

    var humidifierTarget: Int? { pendingTarget ?? humidifier?.target }

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
        if !target, devices[index].watts != nil { devices[index].watts = 0 } // a switched-off plug draws nothing
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

    // MARK: - Humidifier actions

    private func sendHumidifierConfig() {
        guard let stored = HumidifierStore.load() else { return }
        let (config, token) = stored
        var message: [String: Any] = ["cmd": "humidifier.connect", "ip": config.ip, "token": token]
        if let id = config.deviceId { message["deviceId"] = id }
        helper.send(message)
    }

    func findHumidifiers() {
        humidifierSearching = true
        foundHumidifiers = nil
        errorKey = nil
        helper.send(["cmd": "humidifier.find"])
    }

    func connectHumidifier(ip: String, token: String, deviceId: Int?) {
        guard HumidifierStore.isValidIP(ip), HumidifierStore.isValidToken(token) else { return }
        HumidifierStore.save(HumidifierConfig(ip: ip, deviceId: deviceId), token: token)
        humidifierConfigured = true
        humidifier = nil
        humidifierOnline = nil
        foundHumidifiers = nil
        sendHumidifierConfig()
    }

    /// Diagnostics: the helper writes every property the humidifier answers into the log.
    @Published private(set) var humidifierDumping = false
    /// Called when a dump has been written, to show the log.
    var onHumidifierDumped: (() -> Void)?

    func dumpHumidifier() {
        guard humidifierOnline == true, !humidifierDumping else { return }
        humidifierDumping = true
        helper.send(["cmd": "humidifier.dump"])
    }

    func forgetHumidifier() {
        helper.send(["cmd": "humidifier.disconnect"])
        HumidifierStore.clear()
        humidifierConfigured = false
        humidifier = nil
        humidifierOnline = nil
        pendingTarget = nil
    }

    func setHumidifierPower(_ on: Bool) {
        guard humidifierOnline == true else { return }
        humidifier?.power = on
        helper.send(["cmd": "humidifier.set", "prop": "power", "value": on])
    }

    func setHumidifierMode(_ mode: Int) {
        guard humidifierOnline == true, (0...3).contains(mode) else { return }
        humidifier?.mode = mode
        helper.send(["cmd": "humidifier.set", "prop": "mode", "value": mode])
    }

    /// − / + taps change the number at once and send it 0.6 s after the last tap.
    func changeHumidifierTarget(by delta: Int) {
        guard humidifierOnline == true, let current = humidifierTarget else { return }
        let value = min(80, max(30, current + delta))
        pendingTarget = value
        targetTask?.cancel()
        targetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.helper.send(["cmd": "humidifier.set", "prop": "target", "value": value])
            self.humidifier?.target = value
            // Keep showing the new value until the device reports it.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, self.pendingTarget == value { self.pendingTarget = nil }
        }
    }

    /// Makes the device blink for a few seconds so it can be found.
    func identify(id: String) {
        guard canControl, !identifying.contains(id) else { return }
        identifying.insert(id)
        helper.send(["cmd": "identify", "id": id])
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.identifying.remove(id)
        }
    }

    // MARK: - Helper events

    private func handle(_ event: HelperEvent) {
        switch event.ev {
        case "state":
            apply(state: event.state ?? "")
        case "devices":
            devices = (event.devices ?? []).map {
                Device(id: $0.id, label: $0.label ?? "", on: $0.on, reachable: $0.reachable ?? true,
                       kind: IconKind(rawValue: $0.kind ?? "") ?? .plug, watts: $0.watts)
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
        case "power":
            guard let id = event.id, let index = devices.firstIndex(where: { $0.id == id }) else { break }
            if let watts = event.watts, devices[index].watts != watts { devices[index].watts = watts }
        case "humidifier":
            if let raw = event.humidifier {
                humidifier = HumidifierState(
                    power: raw.power, mode: raw.mode, target: raw.target, humidity: raw.humidity,
                    temperature: raw.temperature, waterPercent: raw.waterPercent,
                    water: HumidifierState.Water(rawValue: raw.water) ?? .ok, fault: raw.fault ?? 0)
                humidifierOnline = true
            }
        case "humidifier.online":
            humidifierOnline = event.online
        case "humidifier.dumped":
            humidifierDumping = false
            onHumidifierDumped?()
        case "humidifier.device":
            if let id = event.deviceId { HumidifierStore.updateDeviceId(id) }
        case "humidifier.moved":
            if let ip = event.ip { HumidifierStore.updateIP(ip) }
        case "humidifier.found":
            humidifierSearching = false
            foundHumidifiers = (event.found ?? []).map {
                FoundHumidifier(ip: $0.ip, deviceId: $0.deviceId, model: $0.model, token: $0.token)
            }
            .sorted { ($0.isHumidifier ? 0 : 1, $0.ip) < ($1.isHumidifier ? 0 : 1, $1.ip) }
        case "press":
            guard let id = event.id else { break }
            let kind = event.kind ?? "single"
            lastPress[id] = kind == "multi" ? "multi:\(max(3, event.count ?? 3))" : kind
            UserDefaults.standard.set(lastPress, forKey: Self.pressKey)
            recordEvent(id)
        case "update":
            if let id = event.id, let on = event.on, let index = devices.firstIndex(where: { $0.id == id }) {
                devices[index].on = on
                // Don't keep showing the last load until the meter's next report arrives.
                if !on, devices[index].watts != nil { devices[index].watts = 0 }
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
        case "humidifier_dump_failed":
            humidifierDumping = false
        case "humidifier_set_failed":
            show(errorKey: "err.humidifier_set_failed")
        case "humidifier_bad_config":
            show(errorKey: "err.humidifier_bad_config")
        case "identify_failed":
            identifying.removeAll() // nothing is blinking: don't keep saying so
            show(errorKey: "err.identify_failed")
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
