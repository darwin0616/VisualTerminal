import Carbon

/// 測試期間暫時切到 ABC（中文輸入法會把自動輸入的字變成全形），結束後依 ID 切回原本的輸入法。
enum InputSource {
    static func currentID() -> String? {
        let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    @discardableResult
    static func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let src = list.first else { return false }
        return TISSelectInputSource(src) == noErr
    }

    /// 切到 ABC，回傳一個還原用的 closure
    static func useABC() -> () -> Void {
        let original = currentID()
        select("com.apple.keylayout.ABC")
        return { if let original { select(original) } }
    }
}
