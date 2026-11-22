import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Menu bar icon: left click opens the tiles popover, right click (or Control-click) opens the app menu.
@MainActor
final class StatusController: NSObject {
    private let model: AppModel
    private let l10n: L10n
    private let item: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        self.l10n = L10n.shared
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        let root = PopoverView()
            .environmentObject(model)
            .environmentObject(l10n)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Hiding a device changes `custom`, which also decides whether the icon is filled.
        model.$devices
            .combineLatest(model.$connection, model.$custom, model.$sensors)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        updateIcon()
    }

    private func updateIcon() {
        let symbol = model.anyOn ? "powerplug.fill" : "powerplug"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Switch")
        image?.isTemplate = true
        guard let button = item.button else { return }
        button.image = image
        button.imagePosition = .imageLeft
        // Dim the icon while the hub can't be controlled.
        button.appearsDisabled = !(model.connection == .connected || model.connection == .unpaired)
        // A coloured dot next to the plug: red for a leak, orange for a low battery.
        if model.needsAttention {
            let color: NSColor = model.anyLeak ? .systemRed : .systemOrange
            button.attributedTitle = NSAttributedString(string: "●", attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 7),
                .baselineOffset: 3
            ])
            item.length = NSStatusItem.variableLength
        } else {
            button.title = ""
            item.length = NSStatusItem.squareLength
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        model.editing = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Menu

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        guard let button = item.button else { return }
        let menu = buildMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let title = NSMenuItem(title: "Switch \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let login = NSMenuItem(title: l10n.t("menu.login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let languageItem = NSMenuItem(title: l10n.t("menu.language"), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for lang in AppLanguage.allCases {
            let name = lang == .system ? l10n.t("lang.system") : (Strings.languageNames[lang] ?? lang.rawValue)
            let entry = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = lang.rawValue
            entry.state = l10n.language == lang ? .on : .off
            languages.addItem(entry)
            if lang == .system { languages.addItem(.separator()) }
        }
        languageItem.submenu = languages
        menu.addItem(languageItem)

        let log = NSMenuItem(title: l10n.t("menu.log"), action: #selector(showLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        if model.connection != .unpaired && model.connection != .pairing {
            menu.addItem(.separator())
            let unpair = NSMenuItem(title: l10n.t("menu.unpair"), action: #selector(confirmUnpair), keyEquivalent: "")
            unpair.target = self
            menu.addItem(unpair)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: l10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = AppLanguage(rawValue: raw) else { return }
        l10n.language = lang
    }

    @objc private func showLog() {
        let url = HelperClient.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    @objc private func confirmUnpair() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = l10n.t("unpair.title")
        alert.informativeText = l10n.t("unpair.text")
        alert.alertStyle = .warning
        alert.addButton(withTitle: l10n.t("unpair.confirm"))
        alert.addButton(withTitle: l10n.t("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            model.unpair()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
