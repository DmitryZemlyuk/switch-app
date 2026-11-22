import Foundation

/// App languages. `.system` follows the macOS language list.
enum AppLanguage: String, CaseIterable {
    case system, uk, ru, en
}

/// All UI strings, keyed by language. Kept in code so the language can be switched live from the menu.
enum Strings {
    static let table: [AppLanguage: [String: String]] = [
        .ru: [
            "header": "Розетки",
            "edit": "Изменить",
            "done": "Готово",
            "state.on": "Включена",
            "state.off": "Выключена",
            "state.unreachable": "Нет связи",
            "status.starting": "Запускаю…",
            "status.connected": "Хаб подключён",
            "status.searching": "Ищу хаб…",
            "status.reconnecting": "Переподключаюсь…",
            "status.disconnected": "Хаб не отвечает – Mac в домашней сети?",
            "status.helperFailed": "Не удалось запустить Matter – пробую снова…",
            "status.nodeMissing": "Не найден Node.js",
            "node.help": "Switch работает на Node.js, установленном на этом Mac. Нужна версия 22.13 или новее. Установи её – приложение подхватит само.",
            "devices.loading": "Загружаю розетки…",
            "devices.none": "На хабе не нашлось розеток",
            "pair.title": "Подключение к хабу",
            "pair.steps": "В приложении Aqara Home открой хаб M1S → Matter → добавление в другую экосистему и введи код из 11 цифр. Mac должен быть в той же сети, что и хаб.",
            "pair.placeholder": "Код сопряжения",
            "pair.button": "Подключить",
            "pair.progress": "Подключаюсь к хабу… это может занять до минуты",
            "err.bad_code": "Это не похоже на код Matter – нужно 11 цифр",
            "err.pair_failed": "Не получилось подключиться. Проверь, что код свежий и Mac в той же сети, что и хаб.",
            "err.set_failed": "Розетка не ответила",
            "err.already_paired": "Хаб уже подключён",
            "edit.name": "Название",
            "state.onShort": "Вкл.",
            "state.offShort": "Выкл.",
            "unit.w": "Вт",
            "unit.kwh": "кВт·ч",
            "tab.plugs": "Розетки",
            "tab.sensors": "Датчики",
            "sensors.loading": "Загружаю датчики…",
            "sensors.none": "На хабе не нашлось датчиков",
            "sensor.leak": "Датчик протечки",
            "sensor.motion": "Датчик движения",
            "sensor.button": "Кнопка",
            "sensor.contact": "Датчик открытия",
            "leak.dry": "Сухо",
            "leak.wet": "Протечка!",
            "motion.now": "Движение сейчас",
            "motion.ago": "Движение %@",
            "motion.none": "Тихо",
            "button.ago": "Нажата %@",
            "button.none": "Ещё не нажимали",
            "contact.closed": "Закрыт",
            "contact.open": "Открыт",
            "battery.low": "Скоро сядет",
            "time.justNow": "только что",
            "edit.show": "Показывать в списке",
            "devices.allHidden": "Все устройства скрыты. Нажми «Изменить», чтобы вернуть.",
            "icon.plug": "Розетка",
            "icon.light": "Свет",
            "defaultName": "Розетка %d",
            "menu.login": "Открывать при входе",
            "menu.language": "Язык",
            "lang.system": "Как в системе",
            "menu.unpair": "Отвязать от хаба…",
            "menu.log": "Показать журнал",
            "menu.quit": "Выйти",
            "unpair.title": "Отвязать от хаба?",
            "unpair.text": "Switch перестанет управлять розетками. Чтобы подключить снова, понадобится новый код из Aqara Home.",
            "unpair.confirm": "Отвязать",
            "cancel": "Отмена"
        ],
        .uk: [
            "header": "Розетки",
            "edit": "Змінити",
            "done": "Готово",
            "state.on": "Увімкнена",
            "state.off": "Вимкнена",
            "state.unreachable": "Немає зв’язку",
            "status.starting": "Запускаю…",
            "status.connected": "Хаб підключено",
            "status.searching": "Шукаю хаб…",
            "status.reconnecting": "Перепідключаюся…",
            "status.disconnected": "Хаб не відповідає – Mac у домашній мережі?",
            "status.helperFailed": "Не вдалося запустити Matter – пробую знову…",
            "status.nodeMissing": "Не знайдено Node.js",
            "node.help": "Switch працює на Node.js, встановленому на цьому Mac. Потрібна версія 22.13 або новіша. Встанови її – застосунок підхопить сам.",
            "devices.loading": "Завантажую розетки…",
            "devices.none": "На хабі не знайшлося розеток",
            "pair.title": "Підключення до хабу",
            "pair.steps": "У застосунку Aqara Home відкрий хаб M1S → Matter → додавання до іншої екосистеми та введи код з 11 цифр. Mac має бути в тій самій мережі, що й хаб.",
            "pair.placeholder": "Код спарювання",
            "pair.button": "Підключити",
            "pair.progress": "Підключаюся до хабу… це може тривати до хвилини",
            "err.bad_code": "Це не схоже на код Matter – потрібно 11 цифр",
            "err.pair_failed": "Не вдалося підключитися. Перевір, що код свіжий і Mac у тій самій мережі, що й хаб.",
            "err.set_failed": "Розетка не відповіла",
            "err.already_paired": "Хаб уже підключено",
            "edit.name": "Назва",
            "state.onShort": "Увімк.",
            "state.offShort": "Вимк.",
            "unit.w": "Вт",
            "unit.kwh": "кВт·год",
            "tab.plugs": "Розетки",
            "tab.sensors": "Датчики",
            "sensors.loading": "Завантажую датчики…",
            "sensors.none": "На хабі не знайшлося датчиків",
            "sensor.leak": "Датчик протікання",
            "sensor.motion": "Датчик руху",
            "sensor.button": "Кнопка",
            "sensor.contact": "Датчик відкриття",
            "leak.dry": "Сухо",
            "leak.wet": "Протікання!",
            "motion.now": "Рух зараз",
            "motion.ago": "Рух %@",
            "motion.none": "Тихо",
            "button.ago": "Натиснута %@",
            "button.none": "Ще не натискали",
            "contact.closed": "Закрито",
            "contact.open": "Відкрито",
            "battery.low": "Скоро сяде",
            "time.justNow": "щойно",
            "edit.show": "Показувати у списку",
            "devices.allHidden": "Усі пристрої приховано. Натисни «Змінити», щоб повернути.",
            "icon.plug": "Розетка",
            "icon.light": "Світло",
            "defaultName": "Розетка %d",
            "menu.login": "Відкривати під час входу",
            "menu.language": "Мова",
            "lang.system": "Як у системі",
            "menu.unpair": "Відв’язати від хабу…",
            "menu.log": "Показати журнал",
            "menu.quit": "Вийти",
            "unpair.title": "Відв’язати від хабу?",
            "unpair.text": "Switch більше не керуватиме розетками. Щоб підключити знову, знадобиться новий код з Aqara Home.",
            "unpair.confirm": "Відв’язати",
            "cancel": "Скасувати"
        ],
        .en: [
            "header": "Plugs",
            "edit": "Edit",
            "done": "Done",
            "state.on": "On",
            "state.off": "Off",
            "state.unreachable": "No response",
            "status.starting": "Starting…",
            "status.connected": "Hub connected",
            "status.searching": "Looking for the hub…",
            "status.reconnecting": "Reconnecting…",
            "status.disconnected": "Hub not responding – is the Mac on your home network?",
            "status.helperFailed": "Couldn’t start Matter – retrying…",
            "status.nodeMissing": "Node.js not found",
            "node.help": "Switch runs on the Node.js installed on this Mac. Version 22.13 or newer is required. Install it and the app will pick it up automatically.",
            "devices.loading": "Loading plugs…",
            "devices.none": "No plugs found on the hub",
            "pair.title": "Connect to the hub",
            "pair.steps": "In Aqara Home, open Hub M1S → Matter → add to another ecosystem, then enter the 11-digit code. The Mac must be on the same network as the hub.",
            "pair.placeholder": "Pairing code",
            "pair.button": "Connect",
            "pair.progress": "Connecting to the hub… this can take up to a minute",
            "err.bad_code": "That doesn’t look like a Matter code – it should be 11 digits",
            "err.pair_failed": "Couldn’t connect. Make sure the code is fresh and the Mac is on the same network as the hub.",
            "err.set_failed": "The plug didn’t respond",
            "err.already_paired": "The hub is already connected",
            "edit.name": "Name",
            "state.onShort": "On",
            "state.offShort": "Off",
            "unit.w": "W",
            "unit.kwh": "kWh",
            "tab.plugs": "Plugs",
            "tab.sensors": "Sensors",
            "sensors.loading": "Loading sensors…",
            "sensors.none": "No sensors found on the hub",
            "sensor.leak": "Leak sensor",
            "sensor.motion": "Motion sensor",
            "sensor.button": "Button",
            "sensor.contact": "Contact sensor",
            "leak.dry": "Dry",
            "leak.wet": "Leak!",
            "motion.now": "Motion now",
            "motion.ago": "Motion %@",
            "motion.none": "No motion",
            "button.ago": "Pressed %@",
            "button.none": "Not pressed yet",
            "contact.closed": "Closed",
            "contact.open": "Open",
            "battery.low": "Low battery",
            "time.justNow": "just now",
            "edit.show": "Show in list",
            "devices.allHidden": "All devices are hidden. Click Edit to bring them back.",
            "icon.plug": "Plug",
            "icon.light": "Light",
            "defaultName": "Plug %d",
            "menu.login": "Open at Login",
            "menu.language": "Language",
            "lang.system": "System",
            "menu.unpair": "Unpair from Hub…",
            "menu.log": "Show Log",
            "menu.quit": "Quit",
            "unpair.title": "Unpair from the hub?",
            "unpair.text": "Switch will stop controlling your plugs. To connect again you’ll need a new code from Aqara Home.",
            "unpair.confirm": "Unpair",
            "cancel": "Cancel"
        ]
    ]

    /// Native names shown in the language menu.
    static let languageNames: [AppLanguage: String] = [.uk: "Українська", .ru: "Русский", .en: "English"]
}

@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
    }

    /// The concrete language in use after resolving `.system`.
    var resolved: AppLanguage {
        if language != .system { return language }
        for code in Locale.preferredLanguages {
            let prefix = String(code.prefix(2))
            if let lang = AppLanguage(rawValue: prefix), lang != .system { return lang }
        }
        return .en
    }

    func t(_ key: String) -> String {
        Strings.table[resolved]?[key] ?? Strings.table[.en]?[key] ?? key
    }

    func t(_ key: String, _ number: Int) -> String {
        String(format: t(key), number)
    }

    func t(_ key: String, _ text: String) -> String {
        t(key).replacingOccurrences(of: "%@", with: text)
    }

    /// A number with the app language's decimal separator.
    func number(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: resolved.rawValue)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "38 W", or "3.4 W" below 10 W.
    func watts(_ value: Double) -> String {
        "\(number(value, fractionDigits: value < 10 && value > 0 ? 1 : 0)) \(t("unit.w"))"
    }

    /// "0.42 kWh"; one decimal from 100 kWh up so long-running counters still fit on a tile.
    func kWh(_ value: Double) -> String {
        "\(number(value, fractionDigits: value < 100 ? 2 : 1)) \(t("unit.kwh"))"
    }

    /// "2 minutes ago" in the app language; "just now" for the last minute.
    func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return t("time.justNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: resolved.rawValue)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
