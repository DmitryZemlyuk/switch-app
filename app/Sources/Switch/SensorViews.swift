import SwiftUI

/// The "Sensors" tab: a row per sensor with its state and battery.
struct SensorsContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n

    var body: some View {
        if model.sensors.isEmpty {
            PlaceholderText(model.sensorsLoaded ? l10n.t("sensors.none") : l10n.t("sensors.loading"))
        } else if model.editing {
            VStack(spacing: 10) {
                ForEach(model.sensors) { sensor in
                    SensorEditCard(sensor: sensor)
                }
            }
        } else if model.visibleSensors.isEmpty {
            PlaceholderText(l10n.t("devices.allHidden"))
        } else {
            // Re-render every 30 s so "2 minutes ago" keeps counting while the popover is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 6) {
                    ForEach(model.visibleSensors) { sensor in
                        SensorRow(sensor: sensor, now: context.date)
                    }
                }
            }
        }
    }
}

struct SensorRow: View {
    let sensor: Sensor
    let now: Date

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(iconBackground)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName(for: sensor))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.system(size: 11, weight: sensor.isLeaking ? .semibold : .regular))
                    .foregroundStyle(sensor.isLeaking ? alertText : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let battery = sensor.battery {
                BatteryView(battery: battery)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(rowBackground))
        .opacity(sensor.reachable ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch sensor.type {
        case .leak: return "drop.fill"
        case .motion: return "figure.walk"
        case .button: return "circle.circle"
        case .contact: return "door.left.hand.closed"
        }
    }

    private var iconBackground: Color {
        if sensor.isLeaking { return Color(red: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255) }
        switch sensor.type {
        case .leak: return Color(red: 0x0A / 255, green: 0x6C / 255, blue: 0xDB / 255)
        case .motion: return Color(red: 0x7A / 255, green: 0x4B / 255, blue: 0xD6 / 255)
        case .button, .contact: return Color(red: 0x5F / 255, green: 0x6B / 255, blue: 0x7A / 255)
        }
    }

    private var rowBackground: Color {
        guard sensor.isLeaking else { return Palette.tileOff(scheme) }
        return scheme == .dark ? Color(red: 1, green: 69 / 255, blue: 58 / 255).opacity(0.18)
                               : Color(red: 0xFD / 255, green: 0xEC / 255, blue: 0xEC / 255)
    }

    private var alertText: Color {
        scheme == .dark ? Color(red: 1, green: 0x69 / 255, blue: 0x61 / 255)
                        : Color(red: 0xC4 / 255, green: 0x00 / 255, blue: 0x1A / 255)
    }

    private var status: String {
        if !sensor.reachable { return l10n.t("state.unreachable") }
        switch sensor.type {
        case .leak:
            return sensor.active ? l10n.t("leak.wet") : l10n.t("leak.dry")
        case .motion:
            if sensor.active { return l10n.t("motion.now") }
            if let date = model.lastEvent[sensor.id] { return l10n.t("motion.ago", l10n.relative(date, now: now)) }
            return l10n.t("motion.none")
        case .button:
            if let date = model.lastEvent[sensor.id] { return l10n.t("button.ago", l10n.relative(date, now: now)) }
            return l10n.t("button.none")
        case .contact:
            return sensor.active ? l10n.t("contact.closed") : l10n.t("contact.open")
        }
    }
}

/// Percentage plus a small battery glyph; red with "Low battery" at 20 % and below.
struct BatteryView: View {
    let battery: Battery

    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                if let percent = battery.percent {
                    Text("\(percent)%")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(battery.isLow ? lowColor : Color.secondary)
                }
                glyph
            }
            if battery.isLow {
                Text(l10n.t("battery.low"))
                    .font(.system(size: 10))
                    .foregroundStyle(lowColor)
            }
        }
        .fixedSize()
    }

    private var fraction: Double {
        if let percent = battery.percent { return Double(max(0, min(100, percent))) / 100 }
        switch battery.level {
        case "critical": return 0.1
        case "warning": return 0.25
        default: return 1
        }
    }

    private var glyph: some View {
        let color = battery.isLow ? lowColor : Color.secondary
        return HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: 20, height: 10)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, 14 * fraction), height: 5)
                    .padding(.leading, 3)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: 4)
        }
        .accessibilityHidden(true)
    }

    private var lowColor: Color {
        scheme == .dark ? Color(red: 1, green: 0x69 / 255, blue: 0x61 / 255)
                        : Color(red: 0xC4 / 255, green: 0x00 / 255, blue: 0x1A / 255)
    }
}

struct SensorEditCard: View {
    let sensor: Sensor

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("edit.name"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(
                model.defaultName(for: sensor),
                text: Binding(
                    get: { model.customName(id: sensor.id) },
                    set: { model.setName($0, id: sensor.id) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(model.isHidden(sensor.id))

            Toggle(isOn: Binding(
                get: { !model.isHidden(sensor.id) },
                set: { model.setHidden(!$0, id: sensor.id) }
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
