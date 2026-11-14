import XCTest

/// SR-09.01 / SR-09.06: the app actually follows the injected system language,
/// rather than merely shipping a .lproj directory.
final class LocalizationSmokeTests: XCTestCase {
    private struct LocaleCase {
        let id: String
        let locale: String
        let anchors: [String]
    }

    private let cases = [
        LocaleCase(id: "zh-Hant", locale: "zh_TW", anchors: ["連線到 DSH", "工作階段", "設定"]),
        LocaleCase(id: "ja", locale: "ja_JP", anchors: ["DSH に接続", "セッション", "設定"]),
        LocaleCase(id: "ko", locale: "ko_KR", anchors: ["DSH에 연결", "세션", "설정"]),
        LocaleCase(id: "es", locale: "es_ES", anchors: ["Conectar con DSH", "Sesiones", "Configuración"]),
        LocaleCase(id: "pt-BR", locale: "pt_BR", anchors: ["Conectar ao DSH", "Sessões", "Ajustes"]),
        LocaleCase(id: "fr", locale: "fr_FR", anchors: ["Se connecter à DSH", "Sessions", "Réglages"]),
        LocaleCase(id: "de", locale: "de_DE", anchors: ["Mit DSH verbinden", "Sitzungen", "Einstellungen"]),
    ]

    func testEachShippedLocaleAppearsAtRuntime() {
        for item in cases {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(item.id))",
                "-AppleLocale", item.locale,
            ]
            app.launch()
            let found = item.anchors.contains { anchor in
                app.staticTexts[anchor].waitForExistence(timeout: 8)
                    || app.buttons[anchor].waitForExistence(timeout: 1)
            }
            XCTAssertTrue(found, "\(item.id) stayed on another language; anchors=\(item.anchors)")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = item.id
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
