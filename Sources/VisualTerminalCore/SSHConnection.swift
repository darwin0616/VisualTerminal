import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// 指令執行時收到的資料
public enum SSHOutput: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    /// 指令結束（結束碼）；連線中斷時可能收不到
    case exit(Int32)
}

public enum SSHError: Error, LocalizedError, Sendable {
    case hostKeyRejected(fingerprint: String)
    case hostKeyChanged(previous: String, current: String)
    case authenticationFailed
    case connectionFailed(String)
    case channelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected(let fp): return "已拒絕信任這台伺服器（\(fp)）"
        case .hostKeyChanged(let prev, let cur):
            return "伺服器指紋和上次不同，為了安全已中止連線。\n上次：\(prev)\n這次：\(cur)\n如果伺服器確實重灌過，請先在設定中移除舊的指紋。"
        case .authenticationFailed: return "帳號或密碼錯誤"
        case .connectionFailed(let s): return "無法連線：\(s)"
        case .channelFailed(let s): return "無法執行指令：\(s)"
        }
    }
}

/// 一條 SSH 連線。用 `connect` 建立，`run` 執行指令（可以執行多次），用完 `close`。
public final class SSHConnection: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let username: String
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(host: String, port: Int, username: String, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.host = host
        self.port = port
        self.username = username
        self.group = group
        self.channel = channel
    }

    /// 連線並用密碼登入。
    /// - onUnknownHost：第一次連到這台伺服器時呼叫，回傳 true 表示使用者確認信任（指紋會記住）
    public static func connect(host: String, port: Int = 22, username: String, password: String,
                               knownHosts: KnownHosts = KnownHosts(),
                               onUnknownHost: @escaping @Sendable (HostKeyInfo) async -> Bool) async throws -> SSHConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let authFailed = Flag()
        let hostError = ErrorBox()
        let channelBox = ChannelBox()
        // 密碼被拒、沒有其他登入方式時，NIOSSH 不會自己關閉連線：由我們關閉，等待中的指令才會結束
        let userAuth = PasswordAuthDelegate(username: username, password: password, failed: authFailed) {
            channelBox.close()
        }
        let serverAuth = HostKeyDelegate(host: host, port: port, knownHosts: knownHosts, onUnknownHost: onUnknownHost,
                                         errorBox: hostError, channelBox: channelBox)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil))
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            try? await group.shutdownGracefully()
            throw SSHError.connectionFailed("連不到 \(host):\(port)。請確認 IP 與 Port 是否正確、伺服器是否開機並啟用 SSH，以及網路是否相通。")
        }
        channelBox.set(channel)
        if authFailed.value || hostError.error != nil { channel.close(promise: nil) }
        let connection = SSHConnection(host: host, port: port, username: username, group: group, channel: channel)
        // SSH 的驗證是在第一次開啟 channel 時才確定成功與否：先開一個無害的指令確認登入
        do {
            for try await _ in connection.run("true") {}
        } catch {
            await connection.close()
            if let e = hostError.error { throw e }
            if authFailed.value { throw SSHError.authenticationFailed }
            throw error
        }
        return connection
    }

    /// 在遠端執行一個指令（交給遠端的 shell 解析，所以使用者輸入要先經過 ShellQuote）。
    public func run(_ command: String) -> AsyncThrowingStream<SSHOutput, Error> {
        AsyncThrowingStream { continuation in
            let sshHandler = channel.pipeline.handler(type: NIOSSHHandler.self)
            sshHandler.whenFailure { continuation.finish(throwing: SSHError.channelFailed($0.localizedDescription)) }
            sshHandler.whenSuccess { [channel] handler in
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                handler.createChannel(promise, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHError.channelFailed("非預期的 channel 類型"))
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, continuation: continuation))
                    }
                }
                promise.futureResult.whenFailure { continuation.finish(throwing: SSHError.channelFailed($0.localizedDescription)) }
                continuation.onTermination = { reason in
                    if case .cancelled = reason {  // 使用者按停止：關閉這個指令的 channel
                        promise.futureResult.whenSuccess { $0.close(promise: nil) }
                    }
                }
            }
        }
    }

    /// 執行指令並收集全部輸出（簡單的查詢用）
    public func runCollecting(_ command: String) async throws -> (stdout: String, stderr: String, exitCode: Int32?) {
        var out = "", err = "", code: Int32?
        for try await event in run(command) {
            switch event {
            case .stdout(let s): out += s
            case .stderr(let s): err += s
            case .exit(let c): code = c
            }
        }
        return (out, err, code)
    }

    public func close() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - NIO handlers

final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    func set(_ c: Channel) { lock.withLock { channel = c } }
    func close() { lock.withLock { channel }?.close(promise: nil) }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var e: Error?
    var error: Error? { lock.withLock { e } }
    func set(_ error: Error) { lock.withLock { e = error } }
}

/// 只提供一次密碼；伺服器再次要求就代表密碼錯誤
final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var password: String?
    private let failed: Flag
    private let onExhausted: @Sendable () -> Void

    init(username: String, password: String, failed: Flag, onExhausted: @escaping @Sendable () -> Void) {
        self.username = username
        self.password = password
        self.failed = failed
        self.onExhausted = onExhausted
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.password), let pw = password else {
            failed.set()
            nextChallengePromise.succeed(nil)
            onExhausted()
            return
        }
        password = nil
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "",
                                                                   offer: .password(.init(password: pw))))
    }
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let knownHosts: KnownHosts
    let onUnknownHost: @Sendable (HostKeyInfo) async -> Bool
    let errorBox: ErrorBox
    let channelBox: ChannelBox

    init(host: String, port: Int, knownHosts: KnownHosts, onUnknownHost: @escaping @Sendable (HostKeyInfo) async -> Bool,
         errorBox: ErrorBox, channelBox: ChannelBox) {
        self.host = host
        self.port = port
        self.knownHosts = knownHosts
        self.onUnknownHost = onUnknownHost
        self.errorBox = errorBox
        self.channelBox = channelBox
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(host: host, port: port, openSSHKey: String(openSSHPublicKey: hostKey))
        switch knownHosts.status(of: info) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .changed(let previous):
            let e = SSHError.hostKeyChanged(previous: previous, current: info.fingerprint)
            errorBox.set(e)
            validationCompletePromise.fail(e)
            channelBox.close()  // 拒絕後 NIOSSH 不會自己關閉連線
        case .unknown:
            let ask = onUnknownHost
            let store = knownHosts
            let box = errorBox
            let channels = channelBox
            Task {
                if await ask(info) {
                    try? store.trust(info)
                    validationCompletePromise.succeed(())
                } else {
                    let e = SSHError.hostKeyRejected(fingerprint: info.fingerprint)
                    box.set(e)
                    validationCompletePromise.fail(e)
                    channels.close()
                }
            }
        }
    }
}

/// 一個 session channel：送出 exec 請求，把 stdout / stderr / 結束碼轉成 SSHOutput
final class ExecHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let continuation: AsyncThrowingStream<SSHOutput, Error>.Continuation
    private var finished = false

    init(command: String, continuation: AsyncThrowingStream<SSHOutput, Error>.Continuation) {
        self.command = command
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [continuation] in
            continuation.finish(throwing: SSHError.channelFailed($0.localizedDescription))
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec).whenFailure { [continuation] in
            continuation.finish(throwing: SSHError.channelFailed($0.localizedDescription))
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let text = String(buffer: buffer)
        switch message.type {
        case .channel: continuation.yield(.stdout(text))
        case .stdErr: continuation.yield(.stderr(text))
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            continuation.yield(.exit(Int32(status.exitStatus)))
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
