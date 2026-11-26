// 操作一遍目前的功能並截圖（連到本機測試 SSH 伺服器 127.0.0.1:2222，tester / tester）
import XCTest

final class ScreenshotTour: XCTestCase {
    @MainActor
    func testTour() throws {
        let app = XCUIApplication()
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        shot(window, "01-連線畫面")

        // 中文輸入法會把自動輸入的字變成全形：暫時切到 ABC，結束後依 ID 切回原本的輸入法
        let restoreInput = InputSource.useABC()
        defer { restoreInput() }
        let host = window.textFields.element(boundBy: 0)
        type("127.0.0.1", into: host)
        let port = window.textFields.element(boundBy: 1)
        type("2222", into: port)
        let user = window.textFields.element(boundBy: 2)
        type("tester", into: user)
        let pw = window.secureTextFields.element(boundBy: 0)
        type("wrong-password", into: pw)
        shot(window, "02-填寫表單")

        app.activate()
        window.buttons["連線"].click()
        let trust = app.buttons["信任並連線"]
        XCTAssertTrue(trust.waitForExistence(timeout: 15), "沒有出現指紋確認")
        sleep(1)
        shot(app.windows.firstMatch, "03-第一次連線的指紋確認")
        trust.click()

        XCTAssertTrue(window.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "密碼錯誤", "密碼錯誤")).firstMatch.waitForExistence(timeout: 15), "沒有顯示密碼錯誤")
        shot(window, "04-密碼錯誤")

        type("tester", into: pw)
        window.buttons["連線"].click()
        let test = window.buttons["測試：執行 uname -a"]
        XCTAssertTrue(test.waitForExistence(timeout: 15), "沒有進入已連線畫面")
        shot(window, "05-已連線")
        test.click()
        sleep(3)
        shot(window, "06-執行 uname -a")

        window.buttons["中斷連線"].click()
        XCTAssertTrue(window.buttons["連線"].waitForExistence(timeout: 10))
        sleep(1)
        shot(window, "07-中斷後：最近的伺服器")
    }

    /// 清空欄位後輸入
    @MainActor private func type(_ text: String, into field: XCUIElement) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        field.typeText(text)
    }

    @MainActor private func shot(_ element: XCUIElement, _ name: String) {
        XCUIApplication().activate()  // 確保 app 在最前面，截圖不會被其他視窗擋住
        usleep(300_000)
        let a = XCTAttachment(screenshot: element.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
