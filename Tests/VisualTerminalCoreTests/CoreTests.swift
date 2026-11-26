import Foundation
import Testing
@testable import VisualTerminalCore

@Suite struct ShellQuoteTests {
    /// 交給真正的 /bin/sh 解析，確認還原後和原字串完全相同（沒有被當成指令執行）
    static func roundTrip(_ s: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + ShellQuote.quote(s)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [
        "error", "Error 404", "it's", "a'b'c", "$(touch /tmp/x)", "`id`", "a; rm -rf ~", "x && y", "a | b", "*.log",
        "~/file", "\\n", "line1\nline2", "中文 錯誤", "\"quoted\"", "--help", "", "  spaces  ", "$HOME", "a\\'b",
    ])
    func roundTripsThroughShell(_ s: String) throws {
        #expect(try Self.roundTrip(s) == s)
    }

    @Test func safeStringsStayReadable() {
        #expect(ShellQuote.quote("wms-cs-api") == "wms-cs-api")
        #expect(ShellQuote.quote("/var/log/app.log") == "/var/log/app.log")
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.command("grep", ["-i", "error; ls"]) == "grep -i 'error; ls'")
    }
}

@Suite struct KnownHostsTests {
    @Test func trustAndDetectChange() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kh-\(UUID().uuidString).json")
        let kh = KnownHosts(url: url)
        let key1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        let key2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA0pvBd5ULrvBPUr2klwI/Lr1eyfC6S0zkV4RAxrq4kd"
        let info = HostKeyInfo(host: "Example.com", port: 22, openSSHKey: key1)
        #expect(kh.status(of: info) == .unknown)
        try kh.trust(info)
        #expect(KnownHosts(url: url).status(of: HostKeyInfo(host: "example.com", port: 22, openSSHKey: key1)) == .trusted)
        #expect(kh.status(of: HostKeyInfo(host: "example.com", port: 2222, openSSHKey: key1)) == .unknown)
        if case .changed = kh.status(of: HostKeyInfo(host: "example.com", port: 22, openSSHKey: key2)) {} else {
            Issue.record("指紋改變沒有被偵測到")
        }
        #expect(info.fingerprint.hasPrefix("SHA256:"))
    }
}
