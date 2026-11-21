import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        status = StatusController(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.helper.stop()
    }
}

@main
enum SwitchMain {
    @MainActor
    static func main() {
        // Writing to the helper after it died must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
