// 階段 02：連線後操作拼塊工作區並截圖（測試 SSH 伺服器 127.0.0.1:2222，tester / tester）
import XCTest

final class WorkspaceTour: XCTestCase {
    @MainActor
    func testWorkspaceTour() throws {
        // 中文輸入法會把自動輸入的字變成全形：暫時切到 ABC，結束後依 ID 切回原本的輸入法
        let restoreInput = InputSource.useABC()
        defer { restoreInput() }

        let app = XCUIApplication()
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        type("127.0.0.1", into: window.textFields.element(boundBy: 0))
        type("2222", into: window.textFields.element(boundBy: 1))
        type("tester", into: window.textFields.element(boundBy: 2))
        type("tester", into: window.secureTextFields.element(boundBy: 0))
        window.buttons["連線"].click()
        if app.buttons["信任並連線"].waitForExistence(timeout: 5) { app.buttons["信任並連線"].click() }

        let run = window.buttons["執行"]
        XCTAssertTrue(run.waitForExistence(timeout: 20), "沒有進入工作區")
        sleep(2)
        shot(window, "08-工作區（預設：容器清單）")
        run.click()
        sleep(3)
        shot(window, "09-執行容器清單")

        palette(window, "容器日誌").click()
        let picker = window.popUpButtons.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "沒有容器選單")
        picker.click()
        let item = app.menuItems["vt-sshd"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "容器選單沒有 vt-sshd")
        item.click()
        palette(window, "搜尋").click()
        type("Accepted", into: window.textFields.element(boundBy: 0))
        palette(window, "計算行數").click()
        sleep(1)
        shot(window, "10-組好管線：容器日誌→搜尋→計算行數")
        window.buttons["執行"].click()
        sleep(4)
        shot(window, "11-執行管線的結果")
    }

    @MainActor private func palette(_ window: XCUIElement, _ title: String) -> XCUIElement {
        window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor private func type(_ text: String, into field: XCUIElement) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        field.typeText(text)
    }

    @MainActor private func shot(_ element: XCUIElement, _ name: String) {
        XCUIApplication().activate()
        usleep(300_000)
        let a = XCTAttachment(screenshot: element.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
