import Foundation

/// 把使用者輸入的文字安全地放進遠端 shell 指令。
///
/// 拼塊裡使用者可以輸入搜尋字串、檔名等，這些都要經過 `ShellQuote.quote` 再組進指令，
/// 否則像 `error; rm -rf ~` 這樣的輸入會在遠端伺服器上被當成第二個指令執行。
public enum ShellQuote {
    /// 用單引號包起來；內容中的單引號改寫成 `'\''`。結果在 sh / bash / zsh 中都代表原本的字串。
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0)) }) {
            return s  // 只含安全字元時不加引號，讓指令比較好讀
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 組合指令名稱與參數（每個參數都會經過 quote）
    public static func command(_ name: String, _ args: [String]) -> String {
        ([name] + args.map(quote)).joined(separator: " ")
    }
}
