import Foundation
import NIOCore

/// Custom SOCKS5 client handler with RFC 1929 username/password authentication.
///
/// NIOSOCKS in swift-nio-extras only implements unauthenticated SOCKS5; TailscaleKit's
/// loopback proxy requires username/password auth. This handler does the full
/// handshake (greeting → method selection → auth → CONNECT → response) in a single
/// state machine and fires a `SOCKSTunnelEstablishedEvent` when ready, then removes
/// itself from the pipeline.
///
/// Used in front of NIOSSHHandler when routing through Tailscale's embedded loopback.
final class SOCKS5AuthConnectHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// User event fired after CONNECT succeeds. Downstream handlers can listen for this
    /// to begin their own protocol (e.g., add NIOSSHHandler).
    struct EstablishedEvent: Sendable {}

    private enum State {
        case idle
        case sentGreeting
        case sentAuth
        case sentConnect
        case established
        case failed
    }

    private let username: String
    private let password: String
    private let targetHost: String
    private let targetPort: Int

    private var state: State = .idle
    private var cumulator: ByteBuffer

    init(
        username: String,
        password: String,
        targetHost: String,
        targetPort: Int,
        allocator: ByteBufferAllocator = .init()
    ) {
        self.username = username
        self.password = password
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.cumulator = allocator.buffer(capacity: 64)
    }

    // MARK: - Outbound start

    func channelActive(context: ChannelHandlerContext) {
        // Validate up front
        guard username.utf8.count <= 255 else {
            failHandshake(context: context, reason: "SOCKS5 username exceeds 255 bytes")
            return
        }
        guard password.utf8.count <= 255 else {
            failHandshake(context: context, reason: "SOCKS5 password exceeds 255 bytes")
            return
        }
        guard targetPort > 0, targetPort <= 65535 else {
            failHandshake(context: context, reason: "Invalid target port")
            return
        }

        // Greeting: VER=5, NMETHODS=1, METHODS=[0x02 username/password]
        var buf = context.channel.allocator.buffer(capacity: 3)
        buf.writeBytes([0x05, 0x01, 0x02])
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
        state = .sentGreeting
        context.fireChannelActive()
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        cumulator.writeBuffer(&inbound)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        loop: while state != .failed && state != .established {
            switch state {
            case .sentGreeting:
                // Expect: VER=5, METHOD
                guard cumulator.readableBytes >= 2 else { return }
                let bytes = cumulator.readBytes(length: 2)!
                guard bytes[0] == 0x05 else {
                    failHandshake(context: context, reason: "SOCKS5: bad greeting version 0x\(String(bytes[0], radix: 16))")
                    return
                }
                guard bytes[1] == 0x02 else {
                    if bytes[1] == 0xFF {
                        failHandshake(context: context, reason: "SOCKS5: server rejected username/password auth")
                    } else {
                        failHandshake(context: context, reason: "SOCKS5: server selected unexpected auth method 0x\(String(bytes[1], radix: 16))")
                    }
                    return
                }
                sendAuth(context: context)

            case .sentAuth:
                // Expect: VER=1, STATUS
                guard cumulator.readableBytes >= 2 else { return }
                let bytes = cumulator.readBytes(length: 2)!
                guard bytes[0] == 0x01 else {
                    failHandshake(context: context, reason: "SOCKS5 auth: bad version 0x\(String(bytes[0], radix: 16))")
                    return
                }
                guard bytes[1] == 0x00 else {
                    failHandshake(context: context, reason: "SOCKS5 auth: rejected (status 0x\(String(bytes[1], radix: 16)))")
                    return
                }
                sendConnect(context: context)

            case .sentConnect:
                // Expect: VER=5, REP, RSV=0, ATYP, BND.ADDR, BND.PORT
                guard cumulator.readableBytes >= 4 else { return }
                let header = cumulator.getBytes(at: cumulator.readerIndex, length: 4)!
                guard header[0] == 0x05 else {
                    failHandshake(context: context, reason: "SOCKS5 connect: bad version 0x\(String(header[0], radix: 16))")
                    return
                }
                let rep = header[1]
                guard rep == 0x00 else {
                    failHandshake(context: context, reason: connectErrorMessage(rep))
                    return
                }
                let atyp = header[3]
                let addrLen: Int
                switch atyp {
                case 0x01: addrLen = 4   // IPv4
                case 0x04: addrLen = 16  // IPv6
                case 0x03:
                    // Domain: first byte is length
                    guard cumulator.readableBytes >= 5 else { return }
                    let domainLen = cumulator.getBytes(at: cumulator.readerIndex + 4, length: 1)![0]
                    addrLen = 1 + Int(domainLen)
                default:
                    failHandshake(context: context, reason: "SOCKS5 connect: unknown ATYP 0x\(String(atyp, radix: 16))")
                    return
                }
                let totalLen = 4 + addrLen + 2  // header + addr + port
                guard cumulator.readableBytes >= totalLen else { return }
                cumulator.moveReaderIndex(forwardBy: totalLen)

                // Success — fire the event and forward any leftover bytes
                state = .established
                context.fireUserInboundEventTriggered(EstablishedEvent())

                if cumulator.readableBytes > 0 {
                    // Server may have coalesced bytes after the SOCKS reply (rare, but possible)
                    let leftover = cumulator.readSlice(length: cumulator.readableBytes)!
                    context.fireChannelRead(wrapInboundOut(leftover))
                }

                // Remove ourselves so subsequent reads/writes flow straight to the next handler
                context.pipeline.removeHandler(self, promise: nil)
                break loop

            case .idle, .established, .failed:
                break loop
            }
        }
    }

    // MARK: - Send helpers

    private func sendAuth(context: ChannelHandlerContext) {
        let userBytes = Array(username.utf8)
        let passBytes = Array(password.utf8)
        var buf = context.channel.allocator.buffer(capacity: 3 + userBytes.count + passBytes.count)
        buf.writeInteger(UInt8(0x01))                  // VER
        buf.writeInteger(UInt8(userBytes.count))       // ULEN
        buf.writeBytes(userBytes)                      // UNAME
        buf.writeInteger(UInt8(passBytes.count))       // PLEN
        buf.writeBytes(passBytes)                      // PASSWD
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
        state = .sentAuth
    }

    private func sendConnect(context: ChannelHandlerContext) {
        var buf = context.channel.allocator.buffer(capacity: 32)
        buf.writeInteger(UInt8(0x05))   // VER
        buf.writeInteger(UInt8(0x01))   // CMD = CONNECT
        buf.writeInteger(UInt8(0x00))   // RSV

        if let v4 = ipv4Bytes(targetHost) {
            buf.writeInteger(UInt8(0x01))   // ATYP = IPv4
            buf.writeBytes(v4)
        } else if let v6 = ipv6Bytes(targetHost) {
            buf.writeInteger(UInt8(0x04))   // ATYP = IPv6
            buf.writeBytes(v6)
        } else {
            // Hostname
            let hostBytes = Array(targetHost.utf8)
            guard hostBytes.count <= 255 else {
                failHandshake(context: context, reason: "SOCKS5: hostname exceeds 255 bytes")
                return
            }
            buf.writeInteger(UInt8(0x03))   // ATYP = domain
            buf.writeInteger(UInt8(hostBytes.count))
            buf.writeBytes(hostBytes)
        }

        buf.writeInteger(UInt16(targetPort))   // DST.PORT (network order — NIO writes big-endian by default)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
        state = .sentConnect
    }

    // MARK: - Failure

    private func failHandshake(context: ChannelHandlerContext, reason: String) {
        state = .failed
        context.fireErrorCaught(SOCKS5Error.handshakeFailed(reason))
        context.close(promise: nil)
    }

    private func connectErrorMessage(_ rep: UInt8) -> String {
        switch rep {
        case 0x01: return "SOCKS5 connect: general server failure"
        case 0x02: return "SOCKS5 connect: connection not allowed by ruleset"
        case 0x03: return "SOCKS5 connect: network unreachable"
        case 0x04: return "SOCKS5 connect: host unreachable"
        case 0x05: return "SOCKS5 connect: connection refused"
        case 0x06: return "SOCKS5 connect: TTL expired"
        case 0x07: return "SOCKS5 connect: command not supported"
        case 0x08: return "SOCKS5 connect: address type not supported"
        default:   return "SOCKS5 connect: unknown reply code 0x\(String(rep, radix: 16))"
        }
    }

    // MARK: - IP parsing

    private func ipv4Bytes(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private func ipv6Bytes(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}

/// Errors thrown by SOCKS5AuthConnectHandler.
enum SOCKS5Error: LocalizedError {
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .handshakeFailed(let reason):
            return reason
        }
    }
}

/// Bridges SOCKS5 establishment to SSH startup: listens for `SOCKS5AuthConnectHandler.EstablishedEvent`,
/// installs the NIOSSHHandler + AuthSuccessHandler, then removes itself.
///
/// Used in SSHManager's pipeline when routing through Tailscale's SOCKS5 loopback:
///   [ SOCKS5AuthConnectHandler, PostSOCKSUpgrader ]
/// becomes (after SOCKS handshake):
///   [ NIOSSHHandler, AuthSuccessHandler ]
import NIOSSH

final class PostSOCKSUpgrader: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let nioSSHHandler: NIOSSHHandler
    private let authWaiter: ChannelHandler

    init(nioSSHHandler: NIOSSHHandler, authWaiter: ChannelHandler) {
        self.nioSSHHandler = nioSSHHandler
        self.authWaiter = authWaiter
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SOCKS5AuthConnectHandler.EstablishedEvent {
            // Install SSH handlers BEFORE removing self so any leftover bytes
            // forwarded by the SOCKS handler land in the right place.
            let pipeline = context.pipeline
            pipeline.addHandlers([nioSSHHandler, authWaiter], position: .after(self))
                .flatMap { _ in
                    pipeline.removeHandler(self)
                }
                .whenFailure { error in
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }
}
