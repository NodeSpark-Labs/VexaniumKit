import Foundation
@_exported import CryptoKit
import CommonCrypto
import P256K
import libsecp256k1

// Resolve SHA256 ambiguity: use CryptoKit's SHA256 for all hashing in this module.
private typealias Hash256 = CryptoKit.SHA256

// MARK: - Base58 (Antelope RIPEMD160-checksum variant)

enum VexBase58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func encode(_ bytes: [UInt8]) -> String {
        var digits = [Int]()
        for byte in bytes {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 { digits.append(carry % 58); carry /= 58 }
        }
        let leadingOnes = String(repeating: "1", count: bytes.prefix(while: { $0 == 0 }).count)
        return leadingOnes + String(digits.reversed().map { alphabet[$0] })
    }

    static func decode(_ s: String) throws -> [UInt8] {
        var bytes = [Int]()
        for c in s.unicodeScalars {
            guard let val = alphabet.firstIndex(of: Character(c)) else {
                throw VexaniumError("Invalid Base58 character: \(c)")
            }
            var carry = val
            for i in 0..<bytes.count {
                carry += bytes[i] * 58
                bytes[i] = carry & 0xFF
                carry >>= 8
            }
            while carry > 0 { bytes.append(carry & 0xFF); carry >>= 8 }
        }
        let leadingZeros = s.prefix(while: { $0 == "1" }).count
        return [UInt8](repeating: 0, count: leadingZeros) + bytes.reversed().map { UInt8($0) }
    }

    /// 4-byte RIPEMD160 checksum. For K1 keys/sigs: RIPEMD160(data + keyType bytes) then first 4.
    static func checksum(_ data: [UInt8], keyType: String? = nil) -> [UInt8] {
        var input = data
        if let kt = keyType { input += Array(kt.utf8) }
        return Array(RIPEMD160.hash(input).prefix(4))
    }

    static func encodeCheck(_ data: [UInt8], keyType: String? = nil) -> String {
        encode(data + checksum(data, keyType: keyType))
    }

    static func decodeCheck(_ s: String, keyType: String? = nil) throws -> [UInt8] {
        let full = try decode(s)
        guard full.count > 4 else { throw VexaniumError("Base58Check payload too short") }
        let payload = Array(full.dropLast(4))
        guard Array(full.suffix(4)) == checksum(payload, keyType: keyType) else {
            throw VexaniumError("Base58 checksum mismatch for \(s)")
        }
        return payload
    }
}

// MARK: - VexaniumKey

public struct VexaniumKey: Sendable {
    public let privateKeyData: Data

    public init(privateKeyData: Data) {
        self.privateKeyData = privateKeyData
    }

    /// Compressed 33-byte public key.
    public var compressedPublicKeyData: Data {
        get throws {
            try P256K.Signing.PrivateKey(dataRepresentation: privateKeyData).publicKey.dataRepresentation
        }
    }

    /// "VEX" + Base58Check(compressed pubkey) — legacy Antelope public key format.
    public var publicKeyString: String {
        get throws {
            "VEX" + VexBase58.encodeCheck(Array(try compressedPublicKeyData))
        }
    }

    /// Legacy WIF (compressed, starts with "K" or "L").
    public var wif: String {
        let payload = [UInt8(0x80)] + Array(privateKeyData) + [0x01]
        let check = sha256d(payload)
        return VexBase58.encode(payload + Array(check.prefix(4)))
    }

    // MARK: - Import

    public static func fromWif(_ input: String) throws -> VexaniumKey {
        if input.hasPrefix("PVT_K1_") {
            return VexaniumKey(privateKeyData: Data(
                try VexBase58.decodeCheck(String(input.dropFirst(7)), keyType: "K1")
            ))
        }
        if input.first == "5" || input.first == "K" || input.first == "L" {
            let decoded = try VexBase58.decode(input)
            guard decoded.count >= 33 else { throw VexaniumError("WIF too short") }
            let withoutVersion = decoded.dropFirst()
            let withoutChecksum = withoutVersion.dropLast(4)
            let raw = (input.first == "K" || input.first == "L")
                ? withoutChecksum.dropLast()
                : withoutChecksum
            return VexaniumKey(privateKeyData: Data(raw))
        }
        let hex = input.hasPrefix("0x") ? String(input.dropFirst(2)) : input
        guard hex.count == 64, let data = Data(vexHex: hex) else {
            throw VexaniumError("Invalid WIF/hex private key")
        }
        return VexaniumKey(privateKeyData: data)
    }

    // MARK: - Sign

    /// Sign a 32-byte digest. Returns "SIG_K1_..." in Antelope format.
    public func sign(_ digest: Data) throws -> String {
        let digestBytes = Array(digest)
        let privBytes = Array(privateKeyData)
        let expectedPub = Array(try compressedPublicKeyData)
        let ctx = P256K.Context.rawRepresentation

        for attempt in 0..<30 {
            // Sign with optional extra entropy on retry
            var recSig = secp256k1_ecdsa_recoverable_signature()
            let ok: Int32
            if attempt == 0 {
                ok = secp256k1_ecdsa_sign_recoverable(ctx, &recSig, digestBytes, privBytes, nil, nil)
            } else {
                var extra = [UInt8](repeating: 0, count: 32)
                extra[31] = UInt8(attempt & 0xFF)
                extra[30] = UInt8((attempt >> 8) & 0xFF)
                ok = extra.withUnsafeBytes { extraPtr in
                    secp256k1_ecdsa_sign_recoverable(ctx, &recSig, digestBytes, privBytes, nil, extraPtr.baseAddress)
                }
            }
            guard ok != 0 else { continue }

            // Serialize to compact r||s + recid
            var compact = [UInt8](repeating: 0, count: 64)
            var recid = Int32(0)
            _ = secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &compact, &recid, &recSig)

            let r = Array(compact[0..<32])
            let s = Array(compact[32..<64])

            // Try both s and negated-s (low-S normalization)
            let sNeg = negateScalar(s)
            let candidates: [([UInt8], Int32)] = [
                (s, recid), (sNeg, recid ^ 1), (s, recid ^ 1), (sNeg, recid)
            ]
            for (sCand, rCand) in candidates {
                guard isEosioCanonical(r: r, s: sCand) else { continue }
                guard let recovered = recoverPublicKey(ctx: ctx, digest: digestBytes, r: r, s: sCand, recid: rCand),
                      recovered == expectedPub else { continue }

                var sigBytes = [UInt8](repeating: 0, count: 65)
                sigBytes[0] = UInt8(31 + rCand)
                sigBytes[1..<33] = r[0..<32]
                sigBytes[33..<65] = sCand[0..<32]
                return "SIG_K1_" + VexBase58.encodeCheck(sigBytes, keyType: "K1")
            }
        }
        throw VexaniumError("Failed to produce canonical EOSIO signature after 30 attempts")
    }
}

// MARK: - BIP32 / BIP39

public enum VexHD {
    /// Derive the Antelope signing key from a BIP39 mnemonic.
    /// HD path: m/44'/194'/0'/0/0
    public static func key(mnemonic: String, passphrase: String = "") throws -> VexaniumKey {
        let seed = try bip39Seed(mnemonic: mnemonic, passphrase: passphrase)
        return try deriveKey(seed: seed, path: [0x8000002C, 0x800000C2, 0x80000000, 0, 0])
    }

    public static func bip39Seed(mnemonic: String, passphrase: String = "") throws -> Data {
        let password = Data(mnemonic.precomposedStringWithCanonicalMapping.utf8)
        let salt = Data("mnemonic\(passphrase)".precomposedStringWithCanonicalMapping.utf8)
        return try pbkdf2SHA512(password: password, salt: salt, iterations: 2048, keyLength: 64)
    }

    public static func deriveKey(seed: Data, path: [UInt32]) throws -> VexaniumKey {
        var (privKey, chainCode) = masterKey(from: seed)
        for index in path {
            (privKey, chainCode) = try childKey(privKey: privKey, chainCode: chainCode, index: index)
        }
        return VexaniumKey(privateKeyData: privKey)
    }

    private static func masterKey(from seed: Data) -> (Data, Data) {
        let hmac = Data(CryptoKit.HMAC<CryptoKit.SHA512>.authenticationCode(
            for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))
        ))
        return (hmac.prefix(32), hmac.suffix(32))
    }

    private static func childKey(privKey: Data, chainCode: Data, index: UInt32) throws -> (Data, Data) {
        var data = Data()
        if index >= 0x80000000 {
            data.append(0x00)
            data.append(contentsOf: privKey)
        } else {
            let pub = try P256K.Signing.PrivateKey(dataRepresentation: privKey).publicKey.dataRepresentation
            data.append(contentsOf: pub)
        }
        data.append(contentsOf: withUnsafeBytes(of: index.bigEndian, Array.init))
        let hmac = Data(CryptoKit.HMAC<CryptoKit.SHA512>.authenticationCode(
            for: data, using: SymmetricKey(data: chainCode)
        ))
        let il = Array(hmac.prefix(32))
        let ir = hmac.suffix(32)
        // child key = (parentKey + il) mod n via secp256k1_ec_seckey_tweak_add
        let tweaked = try P256K.Signing.PrivateKey(dataRepresentation: privKey).add(il)
        return (tweaked.dataRepresentation, Data(ir))
    }
}

// MARK: - Signing digest

public func vexSigningDigest(chainId: String, packedTx: [UInt8]) throws -> Data {
    guard let chainIdBytes = Data(vexHex: chainId), chainIdBytes.count == 32 else {
        throw VexaniumError("chainId must be a 64-char hex string (32 bytes)")
    }
    var msg = chainIdBytes
    msg.append(contentsOf: packedTx)
    msg.append(contentsOf: [UInt8](repeating: 0, count: 32))
    return Data(Hash256.hash(data: msg))
}

// MARK: - EOSIO canonical check

private func isEosioCanonical(r: [UInt8], s: [UInt8]) -> Bool {
    guard r.count >= 2, s.count >= 2 else { return false }
    return (r[0] & 0x80) == 0 && !(r[0] == 0 && (r[1] & 0x80) == 0) &&
           (s[0] & 0x80) == 0 && !(s[0] == 0 && (s[1] & 0x80) == 0)
}

// MARK: - Low-S normalization

private let secp256k1N: [UInt8] = [
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,
    0xBA,0xAE,0xDC,0xE6,0xAF,0x48,0xA0,0x3B,0xBF,0xD2,0x5E,0x8C,0xD0,0x36,0x41,0x41
]

func negateScalar(_ s: [UInt8]) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 32)
    var borrow: Int = 0
    for i in stride(from: 31, through: 0, by: -1) {
        let diff = Int(secp256k1N[i]) - Int(s[i]) - borrow
        result[i] = UInt8(bitPattern: Int8(truncatingIfNeeded: diff))
        borrow = diff < 0 ? 1 : 0
    }
    return result
}

// MARK: - Public key recovery (C API)

private func recoverPublicKey(ctx: OpaquePointer, digest: [UInt8], r: [UInt8], s: [UInt8], recid: Int32) -> [UInt8]? {
    guard recid >= 0 && recid <= 3 else { return nil }
    var recSig = secp256k1_ecdsa_recoverable_signature()
    let compact = r + s
    guard secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &recSig, compact, recid) != 0 else { return nil }
    var pubkey = secp256k1_pubkey()
    guard secp256k1_ecdsa_recover(ctx, &pubkey, &recSig, digest) != 0 else { return nil }
    var pubkeyBytes = [UInt8](repeating: 0, count: 33)
    var pubkeyLen = 33
    guard secp256k1_ec_pubkey_serialize(ctx, &pubkeyBytes, &pubkeyLen, &pubkey, UInt32(SECP256K1_EC_COMPRESSED)) != 0 else { return nil }
    return pubkeyBytes
}

// MARK: - Utilities

public extension Data {
    init?(vexHex hex: String) {
        let h = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard h.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(h.count / 2)
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let byte = UInt8(h[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }

    var vexHex: String { map { String(format: "%02x", $0) }.joined() }
}

private func sha256d(_ data: [UInt8]) -> [UInt8] {
    let first = Data(Hash256.hash(data: data))
    return Array(Hash256.hash(data: first))
}

// MARK: - PBKDF2 (BIP39 seed derivation)

func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
    var derived = Data(count: keyLength)
    let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
        password.withUnsafeBytes { passPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    UInt32(iterations),
                    derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
    }
    guard status == kCCSuccess else { throw VexaniumError("PBKDF2 failed: \(status)") }
    return derived
}
