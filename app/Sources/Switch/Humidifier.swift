import Foundation
import Security
import SwiftUI

// MARK: - Model

struct HumidifierState: Equatable {
    enum Water: String { case ok, low, open }

    var power: Bool
    var mode: Int? // 0 auto, 1–3 fan level
    var target: Int?
    var humidity: Int?
    var temperature: Double?
    var waterPercent: Int?
    var water: Water
    var fault: Int
}

struct HumidifierConfig: Equatable {
    var ip: String
    var deviceId: Int?
}

struct FoundHumidifier: Identifiable, Equatable {
    var id: String { ip }
    let ip: String
    let deviceId: Int
    let model: String?
    let token: String?

    var isHumidifier: Bool { model?.contains("humidifier") == true }
}

/// Where the humidifier's address lives (UserDefaults) and its key (Keychain).
enum HumidifierStore {
    private static let ipKey = "humidifierIP"
    private static let deviceKey = "humidifierDeviceId"
    private static let service = "io.github.dmitryzemlyuk.switch.humidifier"

    static func load() -> (HumidifierConfig, String)? {
        guard let ip = UserDefaults.standard.string(forKey: ipKey), let token = readToken() else { return nil }
        let device = UserDefaults.standard.object(forKey: deviceKey) as? Int
        return (HumidifierConfig(ip: ip, deviceId: device), token)
    }

    static func save(_ config: HumidifierConfig, token: String) {
        UserDefaults.standard.set(config.ip, forKey: ipKey)
        if let id = config.deviceId { UserDefaults.standard.set(id, forKey: deviceKey) }
        else { UserDefaults.standard.removeObject(forKey: deviceKey) }
        writeToken(token)
    }

    static func updateIP(_ ip: String) {
        UserDefaults.standard.set(ip, forKey: ipKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: ipKey)
        UserDefaults.standard.removeObject(forKey: deviceKey)
        SecItemDelete(query() as CFDictionary)
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "token"]
    }

    private static func readToken() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String) {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func isValidToken(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespaces)
        return t.count == 32 && t.allSatisfy { $0.isHexDigit }
    }

    static func isValidIP(_ value: String) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    @MainActor
    static func displayName(model: String?) -> String {
        switch model {
        case "zhimi.humidifier.ca4": return "Smartmi Evaporative Humidifier 2"
        case "zhimi.humidifier.ca1", "zhimi.humidifier.cb1": return "Smartmi Evaporative Humidifier"
        case let model?: return model
        case nil: return L10n.shared.t("hum.unknownDevice")
        }
    }
}

// MARK: - Views

/// The "Humidifier" tab: setup until a humidifier is connected, then the tiles (concept B).
struct HumidifierContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.humidifierConfigured {
            HumidifierPanel()
        } else {
            HumidifierSetup()
        }
    }
}

struct HumidifierPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var state: HumidifierState? { model.humidifier }
    private var live: Bool { model.humidifierOnline == true && state != nil }
    private var on: Bool { state?.power == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                powerTile
                valueTile(title: l10n.t("hum.humidity"), icon: "humidity",
                          value: state?.humidity.map { "\($0)%" } ?? "–",
                          detail: model.humidifierTarget.map { l10n.t("hum.targetShort", "\($0)%") })
                valueTile(title: l10n.t("hum.temperature"), icon: "thermometer.medium",
                          value: state?.temperature.map { "\(l10n.number($0, fractionDigits: 1))°" } ?? "–",
                          detail: nil)
                waterTile
            }

            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { mode in
                    modeSegment(mode)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.chip(scheme)))
            .opacity(on && live ? 1 : 0.5)
            .disabled(!(on && live))

            HStack {
                Text(l10n.t("hum.target"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                stepButton("minus", label: l10n.t("hum.less")) { model.changeHumidifierTarget(by: -1) }
                Text(model.humidifierTarget.map { "\($0)%" } ?? "–")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 44)
                stepButton("plus", label: l10n.t("hum.more")) { model.changeHumidifierTarget(by: 1) }
            }
            .opacity(on && live ? 1 : 0.5)
            .disabled(!(on && live))
        }
    }

    private var powerTile: some View {
        Button {
            model.setHumidifierPower(!on)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 6)
                Text(l10n.t("hum.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(on ? l10n.t("hum.on") : l10n.t("hum.off"))
                    .font(.system(size: 11))
                    .opacity(0.88)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
            .foregroundStyle(on ? Color.white : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? Palette.plugOn : Palette.tileOff(scheme)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .disabled(!live)
        .opacity(live ? 1 : 0.55)
        .accessibilityLabel(l10n.t("hum.title"))
        .accessibilityValue(on ? l10n.t("hum.on") : l10n.t("hum.off"))
    }

    private func valueTile(title: String, icon: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.tileOff(scheme)))
        .opacity(live ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var waterTile: some View {
        let water = state?.water ?? .ok
        let percent = state?.waterPercent
        let text: String = {
            switch water {
            case .open: return l10n.t("hum.waterOpen")
            case .low: return l10n.t("hum.waterLow", percent.map { "\($0)%" } ?? "")
            case .ok: return percent.map { "\($0)%" } ?? "–"
            }
        }()
        let color: Color = water == .open ? Palette.alert(scheme) : (water == .low ? Palette.warning(scheme) : .primary)
        let fill: Color = water == .low ? .orange : Color(red: 0x0A / 255, green: 0x6C / 255, blue: 0xDB / 255)
        let fraction = water == .open ? 0 : Double(percent ?? 0) / 100

        return VStack(alignment: .leading, spacing: 0) {
            Label(l10n.t("hum.water"), systemImage: "drop")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(text)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.chip(scheme))
                    Capsule().fill(fill).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            .padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.tileOff(scheme)))
        .opacity(live ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private func modeSegment(_ mode: Int) -> some View {
        let selected = state?.mode == mode
        return Button {
            model.setHumidifierMode(mode)
        } label: {
            Text(l10n.t("hum.mode\(mode)"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .foregroundStyle(Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Palette.segmentOn(scheme) : Color.clear)
                        .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.chip(scheme)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .accessibilityLabel(label)
    }
}

/// Finds the humidifier on the LAN and takes its token from the local answer (custom firmware);
/// manual IP and token entry is the fallback.
struct HumidifierSetup: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    @State private var manual = false
    @State private var ip = ""
    @State private var token = ""
    @State private var tokenFor: [String: String] = [:] // per found device without a token

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.t("hum.setupTitle"))
                .font(.system(size: 13, weight: .semibold))
            Text(l10n.t("hum.setupText"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.findHumidifiers()
            } label: {
                HStack(spacing: 6) {
                    if model.humidifierSearching { ProgressView().controlSize(.small) }
                    Text(model.humidifierSearching ? l10n.t("hum.searching") : l10n.t("hum.find"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.humidifierSearching)

            if let found = model.foundHumidifiers {
                if found.isEmpty {
                    Text(l10n.t("hum.nothingFound"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(found) { device in
                        foundRow(device)
                    }
                }
            }

            DisclosureGroup(isExpanded: $manual) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(l10n.t("hum.ip"), text: $ip).textFieldStyle(.roundedBorder)
                    TextField(l10n.t("hum.token"), text: $token).textFieldStyle(.roundedBorder)
                    Button(l10n.t("hum.connect")) {
                        model.connectHumidifier(ip: ip.trimmingCharacters(in: .whitespaces),
                                                token: token.trimmingCharacters(in: .whitespaces).lowercased(),
                                                deviceId: nil)
                    }
                    .disabled(!HumidifierStore.isValidIP(ip) || !HumidifierStore.isValidToken(token))
                }
                .padding(.top, 6)
            } label: {
                Text(l10n.t("hum.manual")).font(.system(size: 11))
            }

            if let key = model.errorKey {
                Text(l10n.t(key))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func foundRow(_ device: FoundHumidifier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(HumidifierStore.displayName(model: device.model))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(device.ip)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let token = device.token {
                    Button(l10n.t("hum.connect")) {
                        model.connectHumidifier(ip: device.ip, token: token, deviceId: device.deviceId)
                    }
                }
            }
            if device.token == nil {
                Text(l10n.t("hum.noToken"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(l10n.t("hum.token"), text: Binding(
                        get: { tokenFor[device.ip] ?? "" },
                        set: { tokenFor[device.ip] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button(l10n.t("hum.connect")) {
                        model.connectHumidifier(ip: device.ip,
                                                token: (tokenFor[device.ip] ?? "").trimmingCharacters(in: .whitespaces).lowercased(),
                                                deviceId: device.deviceId)
                    }
                    .disabled(!HumidifierStore.isValidToken(tokenFor[device.ip] ?? ""))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.tileOff(scheme)))
        .opacity(device.isHumidifier || device.model == nil ? 1 : 0.6)
    }
}
