//
//  AdbClient.swift
//  iTorrent
//
//  Minimal ADB (Android Debug Bridge) client over TCP, enough to run shell
//  commands on an Android device that has network ADB enabled (port 5555).
//
//  Protocol: AOSP packages/modules/adb/protocol.txt. Every message is a
//  24-byte little-endian header (command, arg0, arg1, data_length,
//  data_check, magic) followed by an optional payload.
//
//  Authentication uses one RSA-2048 key pair that is generated once and kept
//  in the Keychain. The first time, the device shows "Allow USB debugging?"
//  and the user has to accept it on the TV.
//

import Foundation
import Network
import Security

nonisolated enum AdbError: LocalizedError {
    case unreachable(String)
    case timeout(String)
    case closed
    case key(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case let .unreachable(details):
            return String(localized: "adb.error.unreachable", defaultValue: "Can't reach the TV (\(details)). Check the IP address, that the TV is on and on the same Wi-Fi, and that iTorrent is allowed in Settings > Privacy & Security > Local Network.")
        case let .timeout(step):
            return String(localized: "adb.error.timeout", defaultValue: "Timed out: \(step).")
        case .closed:
            return String(localized: "adb.error.closed", defaultValue: "The TV closed the connection. If a prompt was shown on the TV, accept it (tick \"Always allow\") and try again.")
        case let .key(details):
            return String(localized: "adb.error.key", defaultValue: "Key error: \(details)")
        case let .protocolError(details):
            return String(localized: "adb.error.protocol", defaultValue: "ADB error: \(details)")
        }
    }
}

nonisolated final class AdbClient {
    enum Status {
        case connecting
        case waitingForApproval
        case connected
    }

    fileprivate enum Command: UInt32 {
        case cnxn = 0x4E58_4E43
        case auth = 0x4854_5541
        case open = 0x4E45_504F
        case okay = 0x5941_4B4F
        case wrte = 0x4554_5257
        case clse = 0x4553_4C43
    }

    fileprivate struct Message {
        var command: UInt32
        var arg0: UInt32
        var arg1: UInt32
        var payload: Data
    }

    private enum Auth {
        static let token: UInt32 = 1
        static let signature: UInt32 = 2
        static let rsaPublicKey: UInt32 = 3
    }

    private static let version: UInt32 = 0x0100_0000
    private static let maxPayload: UInt32 = 4096

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "itorrent.adb")
    private let host: String
    private var nextLocalId: UInt32 = 1
    private var timedOutStep: String?

    /// Called on a background queue.
    var onStatus: ((Status) -> Void)?

    init(host: String, port: UInt16 = 5555) {
        self.host = host
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        connection = NWConnection(host: .init(host), port: .init(rawValue: port) ?? 5555, using: .init(tls: nil, tcp: tcp))
    }

    deinit {
        connection.cancel()
    }

    func close() {
        connection.cancel()
    }

    // MARK: - Connect

    func connect() async throws {
        onStatus?(.connecting)
        try await withTimeout(5, String(localized: "adb.step.connect", defaultValue: "connecting to \(host)")) { [self] in
            try await openSocket()
        }

        let privateKey = try AdbKey.privateKey()
        try await send(.cnxn, Self.version, Self.maxPayload, Data("host::\0".utf8))

        var sentSignature = false
        var sentPublicKey = false
        while true {
            let timeout: Double = sentPublicKey ? 60 : 10
            let step = sentPublicKey
                ? String(localized: "adb.step.approval", defaultValue: "waiting for the prompt on the TV to be accepted")
                : String(localized: "adb.step.handshake", defaultValue: "ADB handshake")
            let message = try await withTimeout(timeout, step) { [self] in
                try await readMessage()
            }

            switch Command(rawValue: message.command) {
            case .cnxn:
                onStatus?(.connected)
                return
            case .auth where message.arg0 == Auth.token:
                if !sentSignature {
                    sentSignature = true
                    let signature = try AdbKey.sign(message.payload, with: privateKey)
                    try await send(.auth, Auth.signature, 0, signature)
                } else if !sentPublicKey {
                    // The device does not know our key yet: send it, the TV shows a prompt.
                    sentPublicKey = true
                    onStatus?(.waitingForApproval)
                    let publicKey = try AdbKey.androidPublicKey(for: privateKey)
                    try await send(.auth, Auth.rsaPublicKey, 0, publicKey)
                } else {
                    throw AdbError.closed
                }
            default:
                continue
            }
        }
    }

    // MARK: - Shell

    /// Runs `command` in a shell on the device and returns its output.
    func shell(_ command: String, timeout: Double = 15) async throws -> String {
        let localId = nextLocalId
        nextLocalId += 1

        let output = try await withTimeout(timeout, String(localized: "adb.step.command", defaultValue: "running the command")) { [self] in
            try await send(.open, localId, 0, Data("shell:\(command)\0".utf8))
            var remoteId: UInt32 = 0
            var output = Data()
            while true {
                let message = try await readMessage()
                guard message.arg1 == localId else { continue }
                switch Command(rawValue: message.command) {
                case .okay:
                    remoteId = message.arg0
                case .wrte:
                    remoteId = message.arg0
                    output.append(message.payload)
                    try await send(.okay, localId, remoteId, Data())
                case .clse:
                    if remoteId != 0 {
                        try? await send(.clse, localId, remoteId, Data())
                    }
                    return output
                default:
                    continue
                }
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

// MARK: - Socket
private extension AdbClient {
    func openSocket() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case let .waiting(error), let .failed(error):
                    resumed = true
                    self?.connection.cancel()
                    continuation.resume(throwing: AdbError.unreachable(error.localizedDescription))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: AdbError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data) async throws {
        var data = Data(capacity: 24 + payload.count)
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for value in [command.rawValue, arg0, arg1, UInt32(payload.count), checksum, command.rawValue ^ 0xFFFF_FFFF] {
            data.appendLittleEndian(value)
        }
        data.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AdbError.unreachable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readMessage() async throws -> Message {
        let header = try await receive(exactly: 24)
        let command = header.littleEndianUInt32(at: 0)
        let length = Int(header.littleEndianUInt32(at: 12))
        guard header.littleEndianUInt32(at: 20) == command ^ 0xFFFF_FFFF else {
            throw AdbError.protocolError("bad message header")
        }
        let payload = try await receive(exactly: length)
        return Message(command: command, arg0: header.littleEndianUInt32(at: 4), arg1: header.littleEndianUInt32(at: 8), payload: payload)
    }

    func receive(exactly length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: AdbError.unreachable(error.localizedDescription))
                } else if let data, data.count == length {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: AdbError.closed)
                } else {
                    continuation.resume(throwing: AdbError.protocolError("short read"))
                }
            }
        }
    }

    /// Runs `operation`, cancelling the connection if it takes longer than `seconds`.
    func withTimeout<T>(_ seconds: Double, _ step: String, _ operation: @escaping () async throws -> T) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    timedOutStep = step
                    connection.cancel() // makes the pending receive fail
                    throw AdbError.timeout(step)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw AdbError.closed }
                return result
            }
        } catch {
            if let timedOutStep { throw AdbError.timeout(timedOutStep) }
            throw error
        }
    }
}

// MARK: - Key
/// The app's ADB key pair. The private key never leaves the Keychain.
nonisolated enum AdbKey {
    private static let tag = Data("itorrent.adb.rsa".utf8)

    static func privateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
            return item as! SecKey // swiftlint:disable:this force_cast
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw AdbError.key(error?.takeRetainedValue().localizedDescription ?? "can't create key")
        }
        return key
    }

    /// PKCS#1 v1.5 signature where the 20-byte token is used as the SHA-1 digest.
    static func sign(_ token: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) else {
            throw AdbError.key(error?.takeRetainedValue().localizedDescription ?? "can't sign")
        }
        return signature as Data
    }

    /// Public key in Android's format: base64 of the 524-byte RSAPublicKey
    /// struct, then " name", then a terminating zero.
    static func androidPublicKey(for privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw AdbError.key(error?.takeRetainedValue().localizedDescription ?? "can't read public key")
        }

        let modulus = try modulusLimbs(fromPKCS1: [UInt8](der))
        var data = Data(capacity: 524)
        data.appendLittleEndian(UInt32(modulus.count))
        data.appendLittleEndian(n0inv(modulus[0]))
        modulus.forEach { data.appendLittleEndian($0) }
        rr(modulus).forEach { data.appendLittleEndian($0) }
        data.appendLittleEndian(UInt32(65537))

        return Data("\(data.base64EncodedString()) iTorrent@iPhone\0".utf8)
    }

    /// Reads the modulus from a PKCS#1 RSAPublicKey (SEQUENCE { INTEGER n, INTEGER e })
    /// and returns it as 64 little-endian 32-bit words.
    private static func modulusLimbs(fromPKCS1 der: [UInt8]) throws -> [UInt32] {
        var index = 0
        func byte() throws -> UInt8 {
            guard index < der.count else { throw AdbError.key("bad public key") }
            defer { index += 1 }
            return der[index]
        }
        func length() throws -> Int {
            let first = try byte()
            guard first & 0x80 != 0 else { return Int(first) }
            var value = 0
            for _ in 0 ..< Int(first & 0x7F) {
                value = value << 8 | Int(try byte())
            }
            return value
        }

        guard try byte() == 0x30 else { throw AdbError.key("bad public key") }
        _ = try length()
        guard try byte() == 0x02 else { throw AdbError.key("bad public key") }
        let count = try length()
        guard index + count <= der.count else { throw AdbError.key("bad public key") }
        var bigEndian = Array(der[index ..< index + count])
        while bigEndian.count > 256, bigEndian.first == 0 {
            bigEndian.removeFirst()
        }
        guard bigEndian.count == 256 else { throw AdbError.key("unexpected key size") }

        let littleEndian = Array(bigEndian.reversed())
        return (0 ..< 64).map { word in
            (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(littleEndian[word * 4 + $1]) << (8 * $1) }
        }
    }

    /// -(n^-1) mod 2^32, from the lowest word of the (odd) modulus.
    private static func n0inv(_ n0: UInt32) -> UInt32 {
        var inverse = n0 // correct to 3 bits for odd numbers, Newton doubles it each step
        for _ in 0 ..< 5 {
            inverse = inverse &* (2 &- n0 &* inverse)
        }
        return 0 &- inverse
    }

    /// (2^2048)^2 mod n, by doubling 1 a total of 4096 times modulo n.
    private static func rr(_ n: [UInt32]) -> [UInt32] {
        var r = [UInt32](repeating: 0, count: n.count)
        r[0] = 1
        for _ in 0 ..< n.count * 32 * 2 {
            var carry: UInt32 = 0
            for i in r.indices {
                let next = r[i] >> 31
                r[i] = r[i] << 1 | carry
                carry = next
            }
            if carry != 0 || !isLess(r, n) {
                var borrow: UInt64 = 0
                for i in r.indices {
                    let difference = UInt64(r[i]) &- UInt64(n[i]) &- borrow
                    r[i] = UInt32(truncatingIfNeeded: difference)
                    borrow = difference >> 63
                }
            }
        }
        return r
    }

    private static func isLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in a.indices.reversed() where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }
}

// MARK: - Helpers
private nonisolated extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
