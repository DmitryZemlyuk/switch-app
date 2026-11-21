import SwiftUI

private enum Palette {
    static let plugOn = Color(red: 0x00 / 255, green: 0x60 / 255, blue: 0xC7 / 255)
    static let lightOn = Color(red: 0xA8 / 255, green: 0x5A / 255, blue: 0x00 / 255)
    static let accent = Color(red: 0x00 / 255, green: 0x7A / 255, blue: 0xFF / 255)

    static func tileOff(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.white
    }

    static func chip(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.connection == .unpaired || model.connection == .pairing {
                PairingView()
            } else {
                MainView()
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Main screen

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("header"))
                        .font(.system(size: 13, weight: .semibold))
                    StatusLine()
                }
                Spacer(minLength: 8)
                if !model.devices.isEmpty && model.connection != .nodeMissing {
                    Button(model.editing ? l10n.t("done") : l10n.t("edit")) {
                        model.editing.toggle()
                    }
                    .buttonStyle(PillButtonStyle(prominent: model.editing))
                }
            }

            if model.connection == .nodeMissing {
                Text(l10n.t("node.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Link("nodejs.org", destination: URL(string: "https://nodejs.org/")!)
                    .font(.system(size: 12))
            } else if model.devices.isEmpty {
                Text(model.devicesLoaded ? l10n.t("devices.none") : l10n.t("devices.loading"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if model.editing {
                VStack(spacing: 10) {
                    ForEach(model.devices) { device in
                        EditCard(device: device)
                    }
                }
            } else if model.visibleDevices.isEmpty {
                Text(l10n.t("devices.allHidden"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.visibleDevices) { device in
                        TileView(
                            device: device,
                            name: model.displayName(for: device),
                            icon: model.icon(for: device),
                            enabled: model.canControl && device.reachable
                        ) {
                            model.toggle(device)
                        }
                    }
                }
            }

            if let key = model.errorKey {
                Text(l10n.t(key))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusLine: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch model.connection {
        case .connected: return Color(red: 0x30 / 255, green: 0xA1 / 255, blue: 0x4E / 255)
        case .disconnected, .helperFailed, .nodeMissing: return .red
        default: return .orange
        }
    }

    private var text: String {
        switch model.connection {
        case .connected: return l10n.t("status.connected")
        case .searching, .pairing, .unpaired: return l10n.t("status.searching")
        case .reconnecting: return l10n.t("status.reconnecting")
        case .disconnected: return l10n.t("status.disconnected")
        case .helperFailed: return l10n.t("status.helperFailed")
        case .nodeMissing: return l10n.t("status.nodeMissing")
        case .starting: return l10n.t("status.starting")
        }
    }
}

struct TileView: View {
    let device: Device
    let name: String
    let icon: IconKind
    let enabled: Bool
    let action: () -> Void

    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle().fill(iconBackground)
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconForeground)
                }
                .frame(width: 30, height: 30)
                Spacer(minLength: 8)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(subForeground)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .leading)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: device.on)
        .accessibilityLabel(name)
        .accessibilityValue(status)
    }

    private var isOn: Bool { device.on }

    private var symbol: String {
        switch icon {
        case .plug: return isOn ? "powerplug.fill" : "powerplug"
        case .light: return isOn ? "lightbulb.fill" : "lightbulb"
        }
    }

    private var status: String {
        if !device.reachable { return l10n.t("state.unreachable") }
        return isOn ? l10n.t("state.on") : l10n.t("state.off")
    }

    private var background: Color {
        guard isOn else { return Palette.tileOff(scheme) }
        return icon == .light ? Palette.lightOn : Palette.plugOn
    }

    private var foreground: Color { isOn ? .white : .primary }
    private var subForeground: Color { isOn ? Color.white.opacity(0.88) : .secondary }
    private var iconBackground: Color { isOn ? Color.white.opacity(0.22) : Palette.chip(scheme) }
    private var iconForeground: Color { isOn ? .white : .secondary }
}

// MARK: - Edit mode

struct EditCard: View {
    let device: Device

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    private var hidden: Bool { model.isHidden(device) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("edit.name"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(
                model.defaultName(for: device),
                text: Binding(
                    get: { model.customName(for: device) },
                    set: { model.setName($0, for: device) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(hidden)

            Picker("", selection: Binding(
                get: { model.icon(for: device) },
                set: { model.setIcon($0, for: device) }
            )) {
                Text("\(Image(systemName: "powerplug")) \(l10n.t("icon.plug"))").tag(IconKind.plug)
                Text("\(Image(systemName: "lightbulb")) \(l10n.t("icon.light"))").tag(IconKind.light)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(hidden)

            Toggle(isOn: Binding(
                get: { !model.isHidden(device) },
                set: { model.setHidden(!$0, for: device) }
            )) {
                Text(l10n.t("edit.show"))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.tileOff(scheme)))
    }
}

// MARK: - Pairing

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @State private var code = ""

    private var pairing: Bool { model.connection == .pairing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.t("pair.title"))
                .font(.system(size: 13, weight: .semibold))
            Text(l10n.t("pair.steps"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(l10n.t("pair.placeholder"), text: $code)
                .textFieldStyle(.roundedBorder)
                .disabled(pairing)
                .onSubmit(submit)
            if pairing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.t("pair.progress"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let key = model.errorKey {
                Text(l10n.t(key))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: submit) {
                Text(l10n.t("pair.button")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pairing || code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !pairing, !trimmed.isEmpty else { return }
        model.pair(code: trimmed)
    }
}

// MARK: - Styles

struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(Capsule().fill(prominent ? Palette.accent : Palette.chip(scheme)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
